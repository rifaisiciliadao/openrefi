import { describe, it } from "node:test";
import assert from "node:assert/strict";
import type { FastifyInstance } from "fastify";
import { buildApp, type AppDeps } from "./app.js";
import type { EmailPayload, EmailSender } from "./email.js";

const APP_URL = "http://localhost:3000";

interface Harness {
  app: FastifyInstance;
  emails: EmailPayload[];
  emailFailures: number;
}

async function makeApp(opts: {
  investorNotifyEmail?: string | null;
  rateLimit?: { windowMs: number; max: number };
} = {}): Promise<Harness> {
  const emails: EmailPayload[] = [];
  const harness: Harness = {
    app: null as unknown as FastifyInstance,
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
      return { delivered: true, id: `investor-${harness.emails.length}` };
    },
  };

  const deps: AppDeps = {
    config: { spacesBucket: "x", spacesPublicBase: "y", hasCredentials: false },
    putObject: async () => {},
    email,
    adminNotifyEmail: "admin@growfi.dev",
    investorNotifyEmail:
      opts.investorNotifyEmail === undefined
        ? "investors@growfi.dev"
        : opts.investorNotifyEmail,
    appUrl: APP_URL,
    rateLimit: opts.rateLimit ?? { windowMs: 60_000, max: 100 },
  };

  harness.app = await buildApp(deps);
  return harness;
}

const VALID_PAYLOAD = {
  name: "Ada Lovelace",
  email: "ada@example.com",
  company: "Analytical Capital",
  role: "Partner",
  message: "I would like to review the seed round and book a demo.",
};

describe("POST /api/investors/request — validation", () => {
  it("400 on bad email", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/investors/request",
      payload: { ...VALID_PAYLOAD, email: "not-email" },
    });
    assert.equal(res.statusCode, 400);
    assert.match(res.json().error, /Email/);
  });

  it("400 on short message", async () => {
    const { app } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/investors/request",
      payload: { ...VALID_PAYLOAD, message: "hi" },
    });
    assert.equal(res.statusCode, 400);
    assert.match(res.json().error, /nota/);
  });

  it("silently accepts honeypot spam without sending email", async () => {
    const { app, emails } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/investors/request",
      payload: { ...VALID_PAYLOAD, website: "https://spam.example" },
    });
    assert.equal(res.statusCode, 200);
    assert.equal(emails.length, 0);
  });
});

describe("POST /api/investors/request — happy path", () => {
  it("sends a notification to the investor inbox", async () => {
    const { app, emails } = await makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/api/investors/request",
      payload: VALID_PAYLOAD,
    });
    assert.equal(res.statusCode, 201);
    assert.equal(res.json().ok, true);
    assert.equal(res.json().emailDelivered, true);
    assert.equal(emails.length, 1);
    assert.equal(emails[0].to, "investors@growfi.dev");
    assert.equal(emails[0].kind, "investor_request");
    assert.equal(emails[0].data.requesterEmail, "ada@example.com");
    assert.equal(emails[0].data.company, "Analytical Capital");
    assert.equal(emails[0].data.source, `${APP_URL}/investors`);
  });

  it("503 when the inbox is disabled", async () => {
    const { app } = await makeApp({ investorNotifyEmail: null });
    const res = await app.inject({
      method: "POST",
      url: "/api/investors/request",
      payload: VALID_PAYLOAD,
    });
    assert.equal(res.statusCode, 503);
  });

  it("502 when the notification email cannot be delivered", async () => {
    const harness = await makeApp();
    harness.emailFailures = 1;
    const res = await harness.app.inject({
      method: "POST",
      url: "/api/investors/request",
      payload: VALID_PAYLOAD,
    });
    assert.equal(res.statusCode, 502);
    assert.match(res.json().error, /Unable to send/);
    assert.equal(harness.emails.length, 1);
  });

  it("429 when the IP exceeds the request budget", async () => {
    const { app } = await makeApp({ rateLimit: { windowMs: 60_000, max: 1 } });
    const first = await app.inject({
      method: "POST",
      url: "/api/investors/request",
      headers: { "x-forwarded-for": "203.0.113.10" },
      payload: VALID_PAYLOAD,
    });
    assert.equal(first.statusCode, 201);

    const second = await app.inject({
      method: "POST",
      url: "/api/investors/request",
      headers: { "x-forwarded-for": "203.0.113.10" },
      payload: { ...VALID_PAYLOAD, email: "grace@example.com" },
    });
    assert.equal(second.statusCode, 429);
  });
});
