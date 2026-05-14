import type { FastifyInstance, FastifyRequest } from "fastify";
import type { EmailSender } from "./email.js";

export interface InvestorDeps {
  email: EmailSender;
  notifyEmail: string | null;
  appUrl: string;
  rateLimit: { windowMs: number; max: number };
}

interface InvestorRequestBody {
  name?: string;
  email?: string;
  company?: string;
  role?: string;
  message?: string;
  website?: string;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function getClientIp(req: FastifyRequest): string | null {
  const fwd = req.headers["x-forwarded-for"];
  if (typeof fwd === "string" && fwd.length > 0) {
    return fwd.split(",")[0].trim();
  }
  return req.ip ?? null;
}

function clean(value: string | undefined, max: number): string {
  return (value ?? "").trim().replace(/\s+/g, " ").slice(0, max);
}

function cleanMessage(value: string | undefined): string {
  return (value ?? "").trim().slice(0, 2_000);
}

export function registerInvestorRoutes(
  app: FastifyInstance,
  deps: InvestorDeps,
): void {
  const { email, notifyEmail, appUrl, rateLimit } = deps;
  const recentByIp = new Map<string, number[]>();

  app.post<{ Body: InvestorRequestBody }>(
    "/api/investors/request",
    async (req, reply) => {
      const body = req.body ?? {};

      if ((body.website ?? "").trim()) {
        return reply.send({ ok: true, emailDelivered: true });
      }

      if (!notifyEmail) {
        return reply.status(503).send({ error: "Investor inbox not configured" });
      }

      const name = clean(body.name, 120);
      const requesterEmail = clean(body.email, 180).toLowerCase();
      const company = clean(body.company, 160);
      const role = clean(body.role, 160);
      const message = cleanMessage(body.message);

      if (name.length < 2) {
        return reply.status(400).send({ error: "Nome obbligatorio" });
      }
      if (!EMAIL_RE.test(requesterEmail)) {
        return reply.status(400).send({ error: "Email non valida" });
      }
      if (message.length < 12) {
        return reply.status(400).send({
          error: "Scrivi almeno una breve nota sul tipo di confronto richiesto",
        });
      }

      const ip = getClientIp(req);
      if (ip) {
        const since = Date.now() - rateLimit.windowMs;
        const hits = (recentByIp.get(ip) ?? []).filter((ts) => ts >= since);
        if (hits.length >= rateLimit.max) {
          return reply.status(429).send({
            error: "Troppe richieste. Riprova più tardi.",
          });
        }
        hits.push(Date.now());
        recentByIp.set(ip, hits);
      }

      let mail: { delivered: boolean; error?: string };
      try {
        mail = await email.send({
          to: notifyEmail,
          kind: "investor_request",
          data: {
            appUrl,
            investorName: name,
            requesterEmail,
            company,
            role,
            message,
            source: `${appUrl}/investors`,
          },
        });
      } catch (err) {
        app.log.error({ err }, "investor request email failed");
        return reply.status(502).send({
          error: "Unable to send investor request right now",
        });
      }

      if (!mail.delivered) {
        app.log.error(
          { error: mail.error },
          "investor request email was not delivered",
        );
        return reply.status(502).send({
          error: "Unable to send investor request right now",
        });
      }

      return reply.status(201).send({
        ok: true,
        emailDelivered: true,
      });
    },
  );
}
