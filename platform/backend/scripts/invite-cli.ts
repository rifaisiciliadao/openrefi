#!/usr/bin/env tsx
/**
 * Admin CLI for the GrowFi invite gate.
 *
 * Reads:
 *   ADMIN_API_KEY  — required, the X-Admin-Key shared with the backend
 *   BACKEND_URL    — defaults to https://growfi-test-m9s8u.ondigitalocean.app
 *
 * Usage:
 *   tsx scripts/invite-cli.ts <command> [args]
 *   npm run invite -- <command> [args]
 *
 * Commands:
 *   list [pending|approved|rejected|all]      Default: pending
 *   check <address>                           Quick wallet status lookup (public endpoint)
 *   add <address> <email> [telegram]          Submit a new invite request
 *   approve <address>                         Approve + email the wallet
 *   reject <address> [notes]                  Reject (notify by default)
 *   reject <address> [notes] --silent         Reject without sending email
 *   delete <address>                          Hard-delete the record
 *   onboard <address> <email> [telegram]      add + approve in one go (the most common
 *                                             admin pattern: pre-whitelist a wallet)
 */

import { isAddress } from "viem";

const BACKEND_URL = process.env.BACKEND_URL || "https://growfi-test-m9s8u.ondigitalocean.app";
const ADMIN_API_KEY = process.env.ADMIN_API_KEY;

const C = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  cyan: "\x1b[36m",
};

function die(msg: string, code = 1): never {
  console.error(`${C.red}✗${C.reset} ${msg}`);
  process.exit(code);
}

function ok(msg: string) {
  console.log(`${C.green}✓${C.reset} ${msg}`);
}

function info(msg: string) {
  console.log(`${C.cyan}→${C.reset} ${msg}`);
}

function header(msg: string) {
  console.log(`\n${C.bold}${msg}${C.reset}`);
}

function requireAdminKey(): string {
  if (!ADMIN_API_KEY) {
    die(
      "ADMIN_API_KEY env var is required. " +
        "Run: ADMIN_API_KEY=<key> tsx scripts/invite-cli.ts <cmd>",
    );
  }
  return ADMIN_API_KEY;
}

function requireAddress(addr: string | undefined, what = "address"): string {
  if (!addr) die(`Missing ${what}`);
  if (!isAddress(addr.toLowerCase())) die(`Invalid ${what}: ${addr}`);
  return addr.toLowerCase();
}

interface Invite {
  id: number;
  address: string;
  email: string;
  telegram: string;
  status: "pending" | "approved" | "rejected";
  notes?: string | null;
  createdAt: number;
  updatedAt: number;
}

async function call<T>(path: string, init: RequestInit = {}, withAuth = true): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...((init.headers as Record<string, string>) ?? {}),
  };
  if (withAuth) headers["X-Admin-Key"] = requireAdminKey();
  const res = await fetch(`${BACKEND_URL}${path}`, { ...init, headers });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg =
      (data && typeof data === "object" && "error" in data
        ? String((data as { error: unknown }).error)
        : null) || `HTTP ${res.status}`;
    die(`${path} → ${msg}`);
  }
  return data as T;
}

function shortAddr(a: string): string {
  return `${a.slice(0, 8)}…${a.slice(-6)}`;
}

function fmtTs(ts: number): string {
  return new Date(ts).toISOString().slice(0, 19).replace("T", " ");
}

function statusBadge(s: Invite["status"]): string {
  if (s === "approved") return `${C.green}● approved${C.reset}`;
  if (s === "rejected") return `${C.red}● rejected${C.reset}`;
  return `${C.yellow}● pending${C.reset} `;
}

function printRow(r: Invite) {
  const tg = r.telegram || `${C.dim}—${C.reset}`;
  console.log(
    `  ${statusBadge(r.status)}  ${C.bold}#${r.id}${C.reset}  ${shortAddr(r.address)}  ${r.email.padEnd(36)} ${tg}`,
  );
  console.log(`    ${C.dim}${fmtTs(r.createdAt)} → ${fmtTs(r.updatedAt)}${r.notes ? ` · ${r.notes}` : ""}${C.reset}`);
}

// ---- commands ----

async function cmdList(filter: string | undefined) {
  const status = (filter ?? "pending").toLowerCase();
  if (!["pending", "approved", "rejected", "all"].includes(status)) {
    die(`Invalid status: ${status}. Use pending|approved|rejected|all.`);
  }
  const r = await call<{ total: number; items: Invite[] }>(
    `/api/admin/invites?status=${status}`,
  );
  header(`${r.total} invite(s) — status=${status} — backend ${BACKEND_URL}`);
  if (r.items.length === 0) {
    console.log(`  ${C.dim}(none)${C.reset}`);
    return;
  }
  r.items.forEach(printRow);
}

async function cmdCheck(addrRaw: string | undefined) {
  const addr = requireAddress(addrRaw);
  const r = await call<{ status: string; address?: string; email?: string; telegram?: string }>(
    `/api/invite/check?address=${addr}`,
    {},
    /*withAuth*/ false,
  );
  header(`Wallet ${shortAddr(addr)}`);
  console.log(`  status   ${r.status}`);
  if (r.email) console.log(`  email    ${r.email}`);
  if (r.telegram) console.log(`  telegram ${r.telegram}`);
}

async function cmdAdd(args: string[]) {
  const addr = requireAddress(args[0]);
  const email = args[1];
  const telegram = args[2] ?? "";
  if (!email) die("Missing email. Usage: add <address> <email> [telegram]");
  info(`Submitting request for ${email} (${shortAddr(addr)})…`);
  const r = await call<{ ok: boolean; status: string; address: string; emailDelivered: boolean }>(
    "/api/invite/request",
    {
      method: "POST",
      body: JSON.stringify({ ethAddress: addr, email, telegram }),
    },
    /*withAuth*/ false,
  );
  ok(`Request stored — status=${r.status} · email sent=${r.emailDelivered}`);
  return r.address;
}

async function cmdApprove(addrRaw: string | undefined) {
  const addr = requireAddress(addrRaw);
  info(`Approving ${shortAddr(addr)}…`);
  const r = await call<{ invite: Invite; emailDelivered: boolean; emailError?: string }>(
    `/api/admin/invites/${addr}/approve`,
    { method: "POST", body: "{}" },
  );
  ok(
    `${r.invite.email} approved · email sent=${r.emailDelivered}` +
      (r.emailError ? ` · email error: ${r.emailError}` : ""),
  );
}

async function cmdReject(args: string[]) {
  const addr = requireAddress(args[0]);
  const silent = args.includes("--silent");
  const notes = args.slice(1).filter((a) => a !== "--silent").join(" ") || null;
  info(`Rejecting ${shortAddr(addr)}…`);
  const r = await call<{ invite: Invite; emailDelivered: boolean }>(
    `/api/admin/invites/${addr}/reject`,
    {
      method: "POST",
      body: JSON.stringify({ notes, notify: !silent }),
    },
  );
  ok(`${r.invite.email} rejected · email sent=${r.emailDelivered}`);
}

async function cmdDelete(addrRaw: string | undefined) {
  const addr = requireAddress(addrRaw);
  await call<{ ok: boolean }>(`/api/admin/invites/${addr}`, { method: "DELETE" });
  ok(`Deleted ${shortAddr(addr)}`);
}

async function cmdOnboard(args: string[]) {
  const addr = await cmdAdd(args);
  await cmdApprove(addr);
}

function help() {
  console.log(`${C.bold}GrowFi invite admin${C.reset}  ${C.dim}backend ${BACKEND_URL}${C.reset}\n`);
  console.log("Usage: invite-cli <command> [args]\n");
  const lines: [string, string][] = [
    ["list [filter]", "list invites (default: pending)"],
    ["check <address>", "wallet-connect status (public)"],
    ["add <addr> <email> [tg]", "submit a new request"],
    ["approve <address>", "approve + email the wallet"],
    ["reject <addr> [notes] [--silent]", "reject (silent skips email)"],
    ["delete <address>", "hard-delete the record"],
    ["onboard <addr> <email> [tg]", "add + approve in one go"],
  ];
  for (const [cmd, desc] of lines) {
    console.log(`  ${C.cyan}${cmd.padEnd(34)}${C.reset} ${desc}`);
  }
  console.log(`\nEnv: ${C.bold}ADMIN_API_KEY${C.reset} (required), ${C.bold}BACKEND_URL${C.reset} (optional).\n`);
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  switch (cmd) {
    case "list":
      return cmdList(args[0]);
    case "check":
      return cmdCheck(args[0]);
    case "add":
      await cmdAdd(args);
      return;
    case "approve":
      return cmdApprove(args[0]);
    case "reject":
      return cmdReject(args);
    case "delete":
    case "rm":
      return cmdDelete(args[0]);
    case "onboard":
      return cmdOnboard(args);
    case "help":
    case "--help":
    case "-h":
    case undefined:
      help();
      return;
    default:
      die(`Unknown command: ${cmd}. Run 'invite-cli help'.`);
  }
}

main().catch((err) => die(err instanceof Error ? err.message : String(err)));
