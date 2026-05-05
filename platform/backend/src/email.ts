import { Resend } from "resend";

export type EmailKind =
  | "request_received"
  | "approved"
  | "rejected"
  | "admin_notify";

export interface EmailPayload {
  to: string;
  kind: EmailKind;
  data: {
    appUrl?: string;
    notes?: string | null;
    ethAddress?: string;
    /** Set on `admin_notify` to surface the requester's email + telegram. */
    requesterEmail?: string;
    telegram?: string;
  };
}

export interface EmailResult {
  delivered: boolean;
  id?: string;
  error?: string;
}

export interface EmailSender {
  send(payload: EmailPayload): Promise<EmailResult>;
}

interface RenderedEmail {
  subject: string;
  html: string;
  text: string;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function shellHtml(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>${escapeHtml(title)}</title>
</head>
<body style="margin:0;padding:0;background:#f6f7f4;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#1a2e1f;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f6f7f4;padding:32px 0;">
    <tr><td align="center">
      <table width="560" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:14px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,0.04);">
        <tr><td style="padding:28px 36px 0 36px;">
          <div style="font-size:20px;font-weight:700;color:#2e6b3a;letter-spacing:-0.01em;">GrowFi</div>
          <div style="font-size:13px;color:#6b7d6f;margin-top:2px;">Syntropic agroforestry · onchain</div>
        </td></tr>
        <tr><td style="padding:24px 36px 36px 36px;font-size:15px;line-height:1.55;">
          ${body}
        </td></tr>
        <tr><td style="background:#f0f2ed;padding:18px 36px;font-size:12px;color:#6b7d6f;">
          GrowFi · Rifai Sicilia DAO · <a href="https://rifaisicilia.com" style="color:#2e6b3a;">rifaisicilia.com</a>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>`;
}

export function renderEmail(payload: EmailPayload): RenderedEmail {
  const appUrl = payload.data.appUrl ?? "https://growfi.app";
  switch (payload.kind) {
    case "request_received": {
      const subject = "We received your GrowFi invite request";
      const body = `
        <h1 style="font-size:22px;margin:0 0 14px 0;font-weight:700;">Invite request received</h1>
        <p>Thanks for asking to join the GrowFi private beta. We'll review your request shortly.</p>
        <p>While GrowFi is in private beta, we're onboarding a small number of producers, stakers, and consumers to test the full lifecycle. You'll get a personal invite code by email as soon as your request is approved.</p>
        <p style="color:#6b7d6f;font-size:13px;margin-top:24px;">If this wasn't you, you can ignore this message and we won't contact you again.</p>
      `;
      return {
        subject,
        html: shellHtml(subject, body),
        text: [
          "Thanks for asking to join the GrowFi private beta.",
          "We'll review your request and email you back with an invite code as soon as it's approved.",
          "If this wasn't you, ignore this message.",
        ].join("\n\n"),
      };
    }
    case "approved": {
      const addr = payload.data.ethAddress ?? "";
      const addrBlock = addr
        ? `<div style="margin:18px 0;padding:14px 18px;background:#f0f7ee;border-radius:10px;border:1px solid #cfe5cd;font-family:'SFMono-Regular',Consolas,monospace;font-size:14px;letter-spacing:0.02em;color:#1f5e2a;text-align:center;word-break:break-all;">${escapeHtml(addr)}</div>`
        : "";
      const subject = "You're in — your GrowFi access is live";
      const body = `
        <h1 style="font-size:22px;margin:0 0 14px 0;font-weight:700;">You're in.</h1>
        <p>Your GrowFi invite has been approved. Access is bound to the wallet you submitted:</p>
        ${addrBlock}
        <p style="text-align:center;margin:22px 0;">
          <a href="${escapeHtml(appUrl)}" style="display:inline-block;padding:12px 22px;background:#2e6b3a;color:#fff;border-radius:10px;text-decoration:none;font-weight:600;">Open GrowFi →</a>
        </p>
        <p>Open the app and click <strong>Connect Wallet</strong> with the address above. The platform will recognise it automatically — no code to paste, nothing to share.</p>
        <p style="color:#6b7d6f;font-size:13px;margin-top:24px;">Questions? Reach us on Telegram or reply to this email.</p>
      `;
      return {
        subject,
        html: shellHtml(subject, body),
        text: [
          "Your GrowFi invite has been approved.",
          addr ? `Approved wallet: ${addr}` : "",
          `Open the app: ${appUrl}`,
          "Click Connect Wallet with the approved address. We recognise it automatically.",
        ]
          .filter(Boolean)
          .join("\n\n"),
      };
    }
    case "admin_notify": {
      const reqEmail = payload.data.requesterEmail ?? "";
      const addr = payload.data.ethAddress ?? "";
      const tg = payload.data.telegram ?? "";
      const tgHandle = tg.startsWith("@") ? tg.slice(1) : tg;
      const tgLink =
        tgHandle && /^[A-Za-z][A-Za-z0-9_]{3,31}$/.test(tgHandle)
          ? `https://t.me/${escapeHtml(tgHandle)}`
          : null;
      const tgDisplay = tg || "—";
      const subject = `New invite request — ${reqEmail || addr}`;
      const body = `
        <h1 style="font-size:20px;margin:0 0 14px 0;font-weight:700;">New invite request</h1>
        <p style="margin:0 0 14px 0;color:#5a6a5d;font-size:13px;">A wallet just asked for access. Approve or reject from the admin dashboard.</p>
        <table cellpadding="0" cellspacing="0" style="width:100%;border-collapse:collapse;font-size:13px;">
          <tr>
            <td style="padding:8px 0;color:#6b7d6f;width:120px;">Email</td>
            <td style="padding:8px 0;font-weight:600;"><a href="mailto:${escapeHtml(reqEmail)}" style="color:#2e6b3a;">${escapeHtml(reqEmail)}</a></td>
          </tr>
          <tr>
            <td style="padding:8px 0;color:#6b7d6f;border-top:1px solid #eef0ec;">Wallet</td>
            <td style="padding:8px 0;border-top:1px solid #eef0ec;font-family:'SFMono-Regular',Consolas,monospace;font-size:12px;word-break:break-all;">${escapeHtml(addr)}</td>
          </tr>
          <tr>
            <td style="padding:8px 0;color:#6b7d6f;border-top:1px solid #eef0ec;">Telegram</td>
            <td style="padding:8px 0;border-top:1px solid #eef0ec;font-weight:600;">${
              tgLink
                ? `<a href="${tgLink}" style="color:#2e6b3a;">${escapeHtml(tg)}</a>`
                : escapeHtml(tgDisplay)
            }</td>
          </tr>
        </table>
      `;
      return {
        subject,
        html: shellHtml(subject, body),
        text: [
          "New invite request",
          `Email:    ${reqEmail}`,
          `Wallet:   ${addr}`,
          `Telegram: ${tgDisplay}`,
        ].join("\n"),
      };
    }
    case "rejected": {
      const note = payload.data.notes
        ? `<p style="background:#fdf3f0;border-radius:10px;padding:14px 18px;border:1px solid #f1d4cb;color:#7c2d20;">${escapeHtml(payload.data.notes)}</p>`
        : "";
      const subject = "GrowFi invite request update";
      const body = `
        <h1 style="font-size:22px;margin:0 0 14px 0;font-weight:700;">About your invite request</h1>
        <p>Thanks for the interest. We can't onboard you to the GrowFi private beta at this time.</p>
        ${note}
        <p>This isn't a permanent decision — we keep capacity tight while we test the full lifecycle. You can re-apply later when the beta opens up.</p>
      `;
      return {
        subject,
        html: shellHtml(subject, body),
        text: [
          "Thanks for the interest.",
          "We can't onboard you to the GrowFi private beta right now.",
          payload.data.notes ?? "",
          "This isn't permanent. You can re-apply later when the beta opens up.",
        ]
          .filter(Boolean)
          .join("\n\n"),
      };
    }
  }
}

export interface ResendSenderOptions {
  apiKey: string;
  from: string;
  appUrl?: string;
}

export function buildResendSender({
  apiKey,
  from,
  appUrl,
}: ResendSenderOptions): EmailSender {
  const client = new Resend(apiKey);
  return {
    async send(payload) {
      const rendered = renderEmail({
        ...payload,
        data: { appUrl, ...payload.data },
      });
      const res = await client.emails.send({
        from,
        to: payload.to,
        subject: rendered.subject,
        html: rendered.html,
        text: rendered.text,
      });
      if (res.error) {
        return { delivered: false, error: res.error.message };
      }
      return { delivered: true, id: res.data?.id };
    },
  };
}

export function buildNoopSender(log?: (p: EmailPayload) => void): EmailSender {
  return {
    async send(payload) {
      log?.(payload);
      return { delivered: false, error: "email disabled (no RESEND_API_KEY)" };
    },
  };
}
