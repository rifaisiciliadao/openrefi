import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { renderEmail, type EmailPayload } from "./email.js";

const APP = "https://growfi.example/app";
const ADDR = "0xAaaaAaaAAaaAAaAaaAAaaaAaaaaaaAAaaAAaAaAa";

const REQUEST_RECEIVED: EmailPayload = {
  to: "alice@example.com",
  kind: "request_received",
  data: { appUrl: APP, ethAddress: ADDR },
};

describe("renderEmail · request_received", () => {
  it("subject + plain text are non-empty", () => {
    const r = renderEmail(REQUEST_RECEIVED);
    assert.ok(r.subject.length > 5);
    assert.ok(r.text.length > 30);
  });

  it("html includes brand kicker and footer link", () => {
    const r = renderEmail(REQUEST_RECEIVED);
    assert.match(r.html, /GrowFi/);
    assert.match(r.html, /Rifai Sicilia/);
    assert.match(r.html, /rifaisicilia\.com/);
  });
});

describe("renderEmail · approved", () => {
  it("html surfaces the approved wallet address", () => {
    const r = renderEmail({
      to: "alice@example.com",
      kind: "approved",
      data: { ethAddress: ADDR, appUrl: APP },
    });
    assert.match(r.html, /Open GrowFi/);
    assert.match(r.html, new RegExp(ADDR));
    assert.match(r.text, /Approved wallet: 0xAaaa/);
    assert.match(r.html, /Connect Wallet/);
  });

  it("escapes pathological strings (defence in depth)", () => {
    const r = renderEmail({
      to: "alice@example.com",
      kind: "approved",
      data: { ethAddress: "<script>x</script>", appUrl: APP },
    });
    assert.doesNotMatch(r.html, /<script>x<\/script>/);
    assert.match(r.html, /&lt;script&gt;x&lt;\/script&gt;/);
  });

  it("subject is concise and absolute", () => {
    const r = renderEmail({
      to: "alice@example.com",
      kind: "approved",
      data: { ethAddress: ADDR, appUrl: APP },
    });
    assert.equal(r.subject, "You're in — your GrowFi access is live");
  });
});

describe("renderEmail · admin_notify", () => {
  it("renders cleanly when telegram is empty", () => {
    const r = renderEmail({
      to: "hey@growfi.dev",
      kind: "admin_notify",
      data: {
        requesterEmail: "alice@example.com",
        ethAddress: ADDR,
        telegram: "",
      },
    });
    assert.match(r.html, /alice@example\.com/);
    assert.doesNotMatch(r.html, /t\.me/);
    assert.match(r.text, /Telegram: —/);
  });

  it("subject names the requester + body lists email/wallet/telegram", () => {
    const r = renderEmail({
      to: "hey@growfi.dev",
      kind: "admin_notify",
      data: {
        requesterEmail: "alice@example.com",
        ethAddress: ADDR,
        telegram: "@alice_doe",
      },
    });
    assert.match(r.subject, /alice@example\.com/);
    assert.match(r.html, /alice@example\.com/);
    assert.match(r.html, new RegExp(ADDR));
    assert.match(r.html, /@alice_doe/);
    assert.match(r.html, /https:\/\/t\.me\/alice_doe/);
    assert.match(r.text, /alice@example\.com/);
    assert.match(r.text, /@alice_doe/);
  });
});

describe("renderEmail · rejected", () => {
  it("includes the optional admin note when present", () => {
    const r = renderEmail({
      to: "alice@example.com",
      kind: "rejected",
      data: { notes: "duplicate of #14" },
    });
    assert.match(r.html, /duplicate of #14/);
    assert.match(r.text, /duplicate of #14/);
  });

  it("renders without a note", () => {
    const r = renderEmail({
      to: "alice@example.com",
      kind: "rejected",
      data: {},
    });
    assert.match(r.html, /can't onboard you/);
  });
});
