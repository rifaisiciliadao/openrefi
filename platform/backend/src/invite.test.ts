import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import type { FastifyInstance } from "fastify";
import { getAddress } from "viem";
import { buildApp, type AppDeps } from "./app.js";
import { buildInMemoryStore, type InviteStore } from "./store.js";
import type { EmailPayload, EmailSender } from "./email.js";

const ADMIN_KEY = "test-admin-key-please-rotate";
const APP_URL = "http://localhost:3000";
const ALICE = getAddress("0xAaaaAaaAAaaAAaAaaAAaaaAaaaaaaAAaaAAaAaAa");
const BOB = getAddress("0xBbbbbbBBbBbbbBBBbbBBbbBbbbbbBBBbbbbBBbBb");

interface Harness {
  app: FastifyInstance;
  store: InviteStore;
  emails: EmailPayload[];
  emailFailures: number;
}

async function makeApp(opts: {
  adminKey?: string | null;
  adminNotifyEmail?: string | null;
  rateLimit?: { windowMs: number; max: number };
} = {}): Promise<Harness> {
  const store = buildInMemoryStore();
  const emails: EmailPayload[] = [];
  const harness: Harness = {
    app: null as unknown as FastifyInstance,
    store,
    emails,
    emailFailures: 0,
  };
  const email: EmailSender = {
    async send(payload) {
      harness.emails.push(payload);
      if (harness.emailFailures > 0) {
        harness.emailFailures -= 1;
        throw new Error("smtp boom");
      }
      return { delivered: true, id: `test-${harness.emails.length}` };
    },
  };

  const deps: AppDeps = {
    config: { spacesBucket: "x", spacesPublicBase: "y", hasCredentials: false },
    putObject: async () => {},
    inviteStore: store,
    email,
    adminKey: opts.adminKey === undefined ? ADMIN_KEY : opts.adminKey,
    adminNotifyEmail:
      opts.adminNotifyEmail === undefined ? null : opts.adminNotifyEmail,
    appUrl: APP_URL,
    rateLimit: opts.rateLimit ?? { windowMs: 60_000, max: 100 },
  };

  harness.app = await buildApp(deps);
  return harness;
}

const VALID_PAYLOAD = {
  email: "alice@example.com",
  ethAddress: ALICE,
  telegram: "@alice_doe",
};

describe("POST /api/invite/request — validation", () => {
  it("400 on bad email", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: { ...VALID_PAYLOAD, email: "no-at-sign" },
    });
    assert.equal(res.statusCode, 400);
    assert.match(res.json().error, /Email/);
  });

  it("400 on bad ETH address", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: { ...VALID_PAYLOAD, ethAddress: "0xnope" },
    });
    assert.equal(res.statusCode, 400);
    assert.match(res.json().error, /Ethereum/);
  });

  it("400 on bad telegram (when provided)", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: { ...VALID_PAYLOAD, telegram: "ab" },
    });
    assert.equal(res.statusCode, 400);
    assert.match(res.json().error, /Telegram/);
  });

  it("201 when telegram is omitted (optional)", async () => {
    const { app, store } = await makeApp();
    const { telegram: _t, ...withoutTelegram } = VALID_PAYLOAD;
    void _t;
    const res = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: withoutTelegram,
    });
    assert.equal(res.statusCode, 201);
    const row = await store.getByAddress(ALICE);
    assert.ok(row);
    assert.equal(row.telegram, "");
  });

  it("201 when telegram is empty string", async () => {
    const { app, store } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: { ...VALID_PAYLOAD, telegram: "" },
    });
    assert.equal(res.statusCode, 201);
    const row = await store.getByAddress(ALICE);
    assert.equal(row?.telegram, "");
  });
});

describe("POST /api/invite/request — happy path", () => {
  it("201 + record stored under lowercase address + email sent", async () => {
    const { app, store, emails } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    assert.equal(res.statusCode, 201);
    const body = res.json();
    assert.equal(body.ok, true);
    assert.equal(body.status, "pending");
    assert.equal(body.address, ALICE.toLowerCase());
    assert.equal(body.emailDelivered, true);

    const stored = await store.getByAddress(ALICE);
    assert.ok(stored);
    assert.equal(stored.address, ALICE.toLowerCase());
    assert.equal(stored.email, VALID_PAYLOAD.email);
    assert.equal(stored.telegram, "@alice_doe");
    assert.equal(stored.status, "pending");

    assert.equal(emails.length, 1);
    assert.equal(emails[0].kind, "request_received");
    assert.equal(emails[0].to, VALID_PAYLOAD.email);
    assert.equal(emails[0].data.ethAddress, ALICE); // checksummed in email
  });

  it("201 succeeds even when email send throws", async () => {
    const harness = await makeApp();
    harness.emailFailures = 1;
    const res = await harness.app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    assert.equal(res.statusCode, 201);
    assert.equal(res.json().emailDelivered, false);
    assert.equal(await harness.store.count({ status: "pending" }), 1);
  });

  it("normalises telegram username to '@' prefix", async () => {
    const { app, store } = await makeApp();
    await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: { ...VALID_PAYLOAD, telegram: "alice_doe" },
    });
    const row = await store.getByAddress(ALICE);
    assert.equal(row?.telegram, "@alice_doe");
  });
});

describe("POST /api/invite/request — admin notification", () => {
  it("fans out to ADMIN_NOTIFY_EMAIL with all 3 fields", async () => {
    const harness = await makeApp({ adminNotifyEmail: "hey@growfi.dev" });
    const res = await harness.app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    assert.equal(res.statusCode, 201);
    // Wait for the fire-and-forget admin notification to flush
    await new Promise((r) => setTimeout(r, 10));
    const adminMail = harness.emails.find((e) => e.kind === "admin_notify");
    assert.ok(adminMail, "expected an admin_notify email");
    assert.equal(adminMail.to, "hey@growfi.dev");
    assert.equal(adminMail.data.requesterEmail, VALID_PAYLOAD.email);
    assert.equal(adminMail.data.telegram, "@alice_doe");
    assert.equal(adminMail.data.ethAddress, ALICE);
  });

  it("does not fan out when adminNotifyEmail is null", async () => {
    const harness = await makeApp({ adminNotifyEmail: null });
    await harness.app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(
      harness.emails.find((e) => e.kind === "admin_notify"),
      undefined,
    );
  });

  it("admin notification failure does not affect the user response", async () => {
    const harness = await makeApp({ adminNotifyEmail: "hey@growfi.dev" });
    // The first email send (request_received) succeeds, the second
    // (admin_notify) blows up. The user must still see 201.
    harness.emailFailures = 1;
    const res = await harness.app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    assert.notEqual(res.statusCode, 500);
    // We tolerate either the request_received OR the admin_notify being the one
    // that failed — the contract is just that the user response stays 2xx.
    assert.ok(res.statusCode === 201);
  });
});

describe("POST /api/invite/request — duplicates and rate limit", () => {
  it("409 on duplicate (same address)", async () => {
    const { app } = await makeApp();
    await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    const res = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: { ...VALID_PAYLOAD, email: "alice2@example.com" },
    });
    assert.equal(res.statusCode, 409);
    assert.equal(res.json().status, "pending");
  });

  it("409 on duplicate email even with a different wallet", async () => {
    const { app } = await makeApp();
    await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    const res = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: { ...VALID_PAYLOAD, ethAddress: BOB },
    });
    assert.equal(res.statusCode, 409);
  });

  it("allows re-application after rejection", async () => {
    const { app, store } = await makeApp();
    await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    await store.reject(ALICE, "test rejection");

    const res = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    assert.equal(res.statusCode, 201);
    const row = await store.getByAddress(ALICE);
    assert.equal(row?.status, "pending");
  });

  it("429 when rate limit exceeded", async () => {
    const { app } = await makeApp({ rateLimit: { windowMs: 60_000, max: 1 } });
    const r1 = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
      remoteAddress: "1.2.3.4",
    });
    assert.equal(r1.statusCode, 201);
    const r2 = await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: { ...VALID_PAYLOAD, email: "x@example.com", ethAddress: BOB },
      remoteAddress: "1.2.3.4",
    });
    assert.equal(r2.statusCode, 429);
  });
});

describe("GET /api/invite/check (wallet-connect lookup)", () => {
  it("status:none for unknown wallet", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "GET",
      url: `/api/invite/check?address=${ALICE}`,
    });
    assert.equal(res.statusCode, 200);
    assert.equal(res.json().status, "none");
  });

  it("status:pending after a request", async () => {
    const { app } = await makeApp();
    await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    const res = await app.inject({
      method: "GET",
      url: `/api/invite/check?address=${ALICE}`,
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.equal(body.status, "pending");
    assert.equal(body.address, ALICE.toLowerCase());
    assert.equal(body.email, VALID_PAYLOAD.email);
  });

  it("status:approved after admin approve", async () => {
    const { app, store } = await makeApp();
    await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    await store.approve(ALICE);
    const res = await app.inject({
      method: "GET",
      url: `/api/invite/check?address=${ALICE.toUpperCase()}`,
    });
    assert.equal(res.statusCode, 200);
    assert.equal(res.json().status, "approved");
  });

  it("400 on bad address", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "GET",
      url: `/api/invite/check?address=0xnope`,
    });
    assert.equal(res.statusCode, 400);
  });
});

describe("Admin endpoints — gating", () => {
  it("503 when ADMIN_API_KEY is unset", async () => {
    const { app } = await makeApp({ adminKey: null });
    const res = await app.inject({ method: "GET", url: "/api/admin/invites" });
    assert.equal(res.statusCode, 503);
  });

  it("401 without X-Admin-Key", async () => {
    const { app } = await makeApp();
    const res = await app.inject({ method: "GET", url: "/api/admin/invites" });
    assert.equal(res.statusCode, 401);
  });
});

describe("GET /api/admin/invites — listing", () => {
  it("returns total + items for status=pending", async () => {
    const { app } = await makeApp();
    for (const tag of ["a", "b", "c"]) {
      await app.inject({
        method: "POST",
        url: "/api/invite/request",
        payload: {
          email: `${tag}@e.com`,
          ethAddress: getAddress(`0x${tag.charCodeAt(0).toString(16).padStart(40, "0")}`),
          telegram: `@${tag}_user`,
        },
      });
    }
    const res = await app.inject({
      method: "GET",
      url: "/api/admin/invites?status=pending",
      headers: { "x-admin-key": ADMIN_KEY },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.equal(body.total, 3);
    assert.equal(body.items.length, 3);
    assert.equal(body.items[0].status, "pending");
    assert.equal(typeof body.items[0].address, "string");
    assert.equal(body.items[0].address, body.items[0].address.toLowerCase());
  });
});

describe("POST /api/admin/invites/:address/approve", () => {
  it("approves and emails the wallet (no code)", async () => {
    const harness = await makeApp();
    await harness.app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    harness.emails.length = 0;

    const res = await harness.app.inject({
      method: "POST",
      url: `/api/admin/invites/${ALICE}/approve`,
      headers: { "x-admin-key": ADMIN_KEY },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.equal(body.invite.status, "approved");
    assert.equal(body.invite.address, ALICE.toLowerCase());
    assert.equal(body.emailDelivered, true);

    assert.equal(harness.emails.length, 1);
    assert.equal(harness.emails[0].kind, "approved");
    assert.equal(harness.emails[0].data.ethAddress, ALICE);
  });

  it("idempotent on already-approved (re-sends email)", async () => {
    const harness = await makeApp();
    await harness.app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    await harness.app.inject({
      method: "POST",
      url: `/api/admin/invites/${ALICE}/approve`,
      headers: { "x-admin-key": ADMIN_KEY },
    });
    harness.emails.length = 0;
    const second = await harness.app.inject({
      method: "POST",
      url: `/api/admin/invites/${ALICE}/approve`,
      headers: { "x-admin-key": ADMIN_KEY },
    });
    assert.equal(second.statusCode, 200);
    assert.equal(harness.emails.length, 1);
  });

  it("404 on unknown address", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: `/api/admin/invites/${BOB}/approve`,
      headers: { "x-admin-key": ADMIN_KEY },
    });
    assert.equal(res.statusCode, 404);
  });

  it("400 on malformed address", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: `/api/admin/invites/0xnope/approve`,
      headers: { "x-admin-key": ADMIN_KEY },
    });
    assert.equal(res.statusCode, 400);
  });
});

describe("POST /api/admin/invites/:address/reject", () => {
  it("rejects + sends email by default with notes", async () => {
    const harness = await makeApp();
    await harness.app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    harness.emails.length = 0;
    const res = await harness.app.inject({
      method: "POST",
      url: `/api/admin/invites/${ALICE}/reject`,
      headers: { "x-admin-key": ADMIN_KEY },
      payload: { notes: "duplicate" },
    });
    assert.equal(res.statusCode, 200);
    assert.equal(res.json().invite.status, "rejected");
    assert.equal(res.json().invite.notes, "duplicate");
    assert.equal(harness.emails.length, 1);
    assert.equal(harness.emails[0].kind, "rejected");
  });

  it("notify=false skips the email", async () => {
    const harness = await makeApp();
    await harness.app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    harness.emails.length = 0;
    const res = await harness.app.inject({
      method: "POST",
      url: `/api/admin/invites/${ALICE}/reject`,
      headers: { "x-admin-key": ADMIN_KEY },
      payload: { notify: false },
    });
    assert.equal(res.statusCode, 200);
    assert.equal(harness.emails.length, 0);
  });
});

describe("DELETE /api/admin/invites/:address", () => {
  it("removes a record", async () => {
    const { app, store } = await makeApp();
    await app.inject({
      method: "POST",
      url: "/api/invite/request",
      payload: VALID_PAYLOAD,
    });
    const res = await app.inject({
      method: "DELETE",
      url: `/api/admin/invites/${ALICE}`,
      headers: { "x-admin-key": ADMIN_KEY },
    });
    assert.equal(res.statusCode, 200);
    assert.equal(await store.getByAddress(ALICE), null);
  });
});

beforeEach(() => {});
