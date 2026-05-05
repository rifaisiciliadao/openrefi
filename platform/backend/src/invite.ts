import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { isAddress, getAddress } from "viem";
import type {
  InviteIndexItem,
  InviteRow,
  InviteStatus,
  InviteStore,
} from "./store.js";
import type { EmailSender } from "./email.js";

export interface InviteDeps {
  store: InviteStore;
  email: EmailSender;
  adminKey: string | null;
  rateLimit: { windowMs: number; max: number };
  appUrl: string;
  /** Inbox notified on every new invite request. Null disables the fan-out. */
  adminNotifyEmail: string | null;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const TELEGRAM_RE = /^@?[A-Za-z][A-Za-z0-9_]{3,31}$/;

function publicView(row: InviteRow) {
  return {
    id: row.id,
    address: row.address,
    email: row.email,
    telegram: row.telegram,
    status: row.status,
    notes: row.notes,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

function summaryView(item: InviteIndexItem) {
  return {
    id: item.id,
    address: item.address,
    email: item.email,
    telegram: item.telegram,
    status: item.status,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  };
}

function getClientIp(req: FastifyRequest): string | null {
  const fwd = req.headers["x-forwarded-for"];
  if (typeof fwd === "string" && fwd.length > 0) {
    return fwd.split(",")[0].trim();
  }
  return req.ip ?? null;
}

function requireAdmin(
  req: FastifyRequest,
  reply: FastifyReply,
  expected: string | null,
): boolean {
  if (!expected) {
    reply
      .status(503)
      .send({ error: "Admin API disabled (ADMIN_API_KEY non impostata)" });
    return false;
  }
  const got = req.headers["x-admin-key"];
  if (typeof got !== "string" || got !== expected) {
    reply.status(401).send({ error: "Unauthorized" });
    return false;
  }
  return true;
}

function parseAddress(raw: string, reply: FastifyReply): string | null {
  const lower = raw.trim().toLowerCase();
  if (!isAddress(lower)) {
    reply.status(400).send({ error: "Indirizzo Ethereum non valido" });
    return null;
  }
  return lower;
}

export function registerInviteRoutes(
  app: FastifyInstance,
  deps: InviteDeps,
): void {
  const { store, email, adminKey, rateLimit, appUrl, adminNotifyEmail } = deps;

  app.post<{
    Body: { email?: string; ethAddress?: string; telegram?: string };
  }>("/api/invite/request", async (req, reply) => {
    const body = req.body ?? {};
    const email_ = (body.email ?? "").trim();
    const ethRaw = (body.ethAddress ?? "").trim();
    const telegramRaw = (body.telegram ?? "").trim();

    if (!EMAIL_RE.test(email_)) {
      return reply.status(400).send({ error: "Email non valida" });
    }
    if (!isAddress(ethRaw)) {
      return reply.status(400).send({ error: "Indirizzo Ethereum non valido" });
    }
    // Telegram is optional. Validate the format only if the producer filled it in.
    if (telegramRaw && !TELEGRAM_RE.test(telegramRaw)) {
      return reply.status(400).send({
        error: "Username Telegram non valido (es. @username, 4-32 char)",
      });
    }

    // Use checksummed display in emails, but always store + key by lowercase
    // so wallet-connect lookups land on the right object regardless of case.
    const checksummed = getAddress(ethRaw);
    const lower = checksummed.toLowerCase();
    const telegram = telegramRaw
      ? telegramRaw.startsWith("@")
        ? telegramRaw
        : `@${telegramRaw}`
      : "";
    const ip = getClientIp(req);

    if (ip) {
      const since = Date.now() - rateLimit.windowMs;
      const recent = await store.countRecentByIp(ip, since);
      if (recent >= rateLimit.max) {
        return reply.status(429).send({
          error: "Troppe richieste. Riprova più tardi.",
        });
      }
    }

    const existing = await store.findActiveByEmailOrAddress(email_, lower);
    if (existing) {
      if (existing.status === "approved") {
        return reply.status(409).send({
          error:
            "Questo wallet è già approvato. Connetti il wallet per accedere.",
          status: "approved",
        });
      }
      return reply.status(409).send({
        error: "Hai già una richiesta in attesa di approvazione.",
        status: "pending",
      });
    }

    const row = await store.insertRequest({
      address: lower,
      email: email_,
      telegram,
      ip,
    });

    let mail: { delivered: boolean; error?: string } = { delivered: false };
    try {
      mail = await email.send({
        to: email_,
        kind: "request_received",
        data: { appUrl, ethAddress: checksummed },
      });
    } catch (err) {
      app.log.error({ err }, "request email failed");
      mail = {
        delivered: false,
        error: err instanceof Error ? err.message : String(err),
      };
    }

    if (adminNotifyEmail) {
      // Best-effort: a failed admin notification must NEVER bounce the user's
      // request. Surface it in the logs only.
      email
        .send({
          to: adminNotifyEmail,
          kind: "admin_notify",
          data: {
            appUrl,
            ethAddress: checksummed,
            requesterEmail: email_,
            telegram,
          },
        })
        .catch((err) => app.log.error({ err }, "admin notify email failed"));
    }

    return reply.status(201).send({
      ok: true,
      status: row.status,
      address: row.address,
      emailDelivered: mail.delivered,
    });
  });

  /**
   * Wallet-connect access check. Single GET on invites/<address>.json so the
   * frontend can ask "does this wallet have access?" the moment a user
   * connects, without scanning anything.
   */
  app.get<{ Querystring: { address?: string } }>(
    "/api/invite/check",
    async (req, reply) => {
      const raw = (req.query.address ?? "").trim();
      if (!raw) {
        return reply.send({ status: "none" });
      }
      const lower = parseAddress(raw, reply);
      if (lower === null) return;
      const row = await store.getByAddress(lower);
      if (!row) return reply.send({ status: "none", address: lower });
      return reply.send({
        status: row.status,
        address: row.address,
        email: row.email,
        telegram: row.telegram,
      });
    },
  );

  app.get<{
    Querystring: { status?: string; limit?: string; offset?: string };
  }>("/api/admin/invites", async (req, reply) => {
    if (!requireAdmin(req, reply, adminKey)) return;
    const status = (req.query.status ?? "all") as InviteStatus | "all";
    const limit = Math.max(1, Math.min(500, Number(req.query.limit ?? 100)));
    const offset = Math.max(0, Number(req.query.offset ?? 0));
    const items = await store.list({ status, limit, offset });
    const total = await store.count({ status });
    return reply.send({ total, items: items.map(summaryView) });
  });

  app.post<{ Params: { address: string } }>(
    "/api/admin/invites/:address/approve",
    async (req, reply) => {
      if (!requireAdmin(req, reply, adminKey)) return;
      const lower = parseAddress(req.params.address, reply);
      if (lower === null) return;
      const existing = await store.getByAddress(lower);
      if (!existing) {
        return reply.status(404).send({ error: "Invito non trovato" });
      }
      const updated =
        existing.status === "approved" ? existing : await store.approve(lower);
      if (!updated) return reply.status(500).send({ error: "Approvazione fallita" });

      let mail: { delivered: boolean; error?: string } = { delivered: false };
      try {
        mail = await email.send({
          to: updated.email,
          kind: "approved",
          data: { appUrl, ethAddress: getAddress(updated.address) },
        });
      } catch (err) {
        app.log.error({ err }, "approval email failed");
        mail = {
          delivered: false,
          error: err instanceof Error ? err.message : String(err),
        };
      }
      return reply.send({
        invite: publicView(updated),
        emailDelivered: mail.delivered,
        emailError: mail.error,
      });
    },
  );

  app.post<{
    Params: { address: string };
    Body: { notes?: string; notify?: boolean };
  }>("/api/admin/invites/:address/reject", async (req, reply) => {
    if (!requireAdmin(req, reply, adminKey)) return;
    const lower = parseAddress(req.params.address, reply);
    if (lower === null) return;
    const existing = await store.getByAddress(lower);
    if (!existing) return reply.status(404).send({ error: "Invito non trovato" });

    const notes = req.body?.notes ?? null;
    const updated = await store.reject(lower, notes);
    if (!updated) return reply.status(500).send({ error: "Rifiuto fallito" });

    let mail: { delivered: boolean; error?: string } = { delivered: false };
    if (req.body?.notify !== false) {
      try {
        mail = await email.send({
          to: updated.email,
          kind: "rejected",
          data: {
            appUrl,
            ethAddress: getAddress(updated.address),
            notes,
          },
        });
      } catch (err) {
        app.log.error({ err }, "rejection email failed");
        mail = {
          delivered: false,
          error: err instanceof Error ? err.message : String(err),
        };
      }
    }
    return reply.send({
      invite: publicView(updated),
      emailDelivered: mail.delivered,
      emailError: mail.error,
    });
  });

  app.delete<{ Params: { address: string } }>(
    "/api/admin/invites/:address",
    async (req, reply) => {
      if (!requireAdmin(req, reply, adminKey)) return;
      const lower = parseAddress(req.params.address, reply);
      if (lower === null) return;
      const ok = await store.remove(lower);
      if (!ok) return reply.status(404).send({ error: "Invito non trovato" });
      return reply.send({ ok: true });
    },
  );
}
