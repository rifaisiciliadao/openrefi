"use client";

import { useEffect, useState } from "react";
import { useSearchParams, useRouter, usePathname } from "next/navigation";
import { useTranslations } from "next-intl";
import { useAccount } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useInviteGate } from "@/lib/inviteGate";
import { useInviteModal } from "@/lib/inviteModal";
import { requestInvite } from "@/lib/api";
import { Spinner } from "@/components/Spinner";

type SubmitState =
  | { kind: "idle" }
  | { kind: "submitting" }
  | { kind: "ok" }
  | { kind: "err"; message: string };

/**
 * Same content as the previous inline `InviteSection`, but rendered inside
 * a centered modal dialog. The modal is mounted once at the root of the
 * landing page and is opened by:
 *  - the "Sei un coltivatore sintropico?" `CreateCampaignCard` on the
 *    Campaigns section (when the user isn't approved yet)
 *  - the "Richiedi invito" links in the landing `<Nav>` and the in-app
 *    `<Header>` (which navigate to `/?openInvite=1` so the auto-open
 *    effect below catches the query param)
 *  - the `<InviteGate>` wrapper on `/create`, which redirects to
 *    `/?gated=1&reason=<connect|request|pending|rejected>` — the modal
 *    auto-opens and the `reason` selects the right banner copy.
 */
export function InviteModal() {
  const t = useTranslations("landing.invite");
  const { open, openModal, closeModal } = useInviteModal();
  const { state, address, email: storedEmail, telegram: storedTelegram, refresh } =
    useInviteGate();
  const { address: wagmiAddress } = useAccount();
  const params = useSearchParams();
  const router = useRouter();
  const pathname = usePathname();

  const [email, setEmail] = useState("");
  const [telegram, setTelegram] = useState("");
  const [submit, setSubmit] = useState<SubmitState>({ kind: "idle" });

  // Auto-open from query string. Strip the param after consuming it so
  // refresh / share-of-URL don't re-trigger the modal forever.
  useEffect(() => {
    const gated = params.get("gated") === "1";
    const explicit = params.get("openInvite") === "1";
    if (!gated && !explicit) return;
    openModal();
    const next = new URLSearchParams(params.toString());
    next.delete("openInvite");
    next.delete("gated");
    // keep `reason` for one render so the banner shows; remove on next paint
    const url = next.toString() ? `${pathname}?${next.toString()}` : pathname;
    router.replace(url, { scroll: false });
  }, [params, openModal, router, pathname]);

  // ESC closes the modal.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") closeModal();
    };
    window.addEventListener("keydown", onKey);
    document.documentElement.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.documentElement.style.overflow = "";
    };
  }, [open, closeModal]);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!wagmiAddress) return;
    setSubmit({ kind: "submitting" });
    try {
      await requestInvite({ email, ethAddress: wagmiAddress, telegram });
      setSubmit({ kind: "ok" });
      setEmail("");
      setTelegram("");
      await refresh();
    } catch (err) {
      setSubmit({
        kind: "err",
        message: err instanceof Error ? err.message : t("requestErr"),
      });
    }
  }

  if (!open) return null;

  const reason = params.get("reason");
  const banner =
    reason === "connect"
      ? t("bannerConnect")
      : reason === "request"
        ? t("bannerNeeded")
        : reason === "pending"
          ? t("bannerPending")
          : reason === "rejected"
            ? t("bannerRejected")
            : null;

  return (
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center px-4 py-8"
      role="dialog"
      aria-modal="true"
    >
      <button
        type="button"
        aria-label="Close"
        onClick={closeModal}
        className="absolute inset-0 bg-black/55 backdrop-blur-sm"
      />
      <div
        className="relative z-10 w-full max-w-2xl max-h-[calc(100vh-4rem)] overflow-y-auto rounded-2xl bg-white p-6 shadow-[0_24px_64px_-12px_rgba(0,0,0,0.45)] sm:p-10"
      >
        <button
          type="button"
          onClick={closeModal}
          aria-label="Close"
          className="absolute right-4 top-4 flex h-9 w-9 items-center justify-center rounded-full text-[#4a4a4a] transition-colors hover:bg-black/5 hover:text-black"
        >
          <svg
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2.2"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <path d="M6 6l12 12M18 6L6 18" />
          </svg>
        </button>

        <InviteModalBody
          state={state}
          address={address}
          storedEmail={storedEmail}
          storedTelegram={storedTelegram}
          wagmiAddress={wagmiAddress}
          email={email}
          telegram={telegram}
          setEmail={setEmail}
          setTelegram={setTelegram}
          submit={submit}
          onSubmit={onSubmit}
          banner={banner}
        />
      </div>
    </div>
  );
}

interface BodyProps {
  state: ReturnType<typeof useInviteGate>["state"];
  address: string | null;
  storedEmail: string | null;
  storedTelegram: string | null;
  wagmiAddress: string | undefined;
  email: string;
  telegram: string;
  setEmail: (v: string) => void;
  setTelegram: (v: string) => void;
  submit: SubmitState;
  onSubmit: (e: React.FormEvent) => Promise<void>;
  banner: string | null;
}

function InviteModalBody({
  state,
  address,
  storedEmail,
  storedTelegram,
  wagmiAddress,
  email,
  telegram,
  setEmail,
  setTelegram,
  submit,
  onSubmit,
  banner,
}: BodyProps) {
  const t = useTranslations("landing.invite");

  if (state === "approved") {
    return (
      <div className="text-center">
        <span className="inline-flex items-center gap-2 rounded-full border border-black/10 bg-white/85 px-4 py-1.5 text-xs font-bold tracking-[0.1em] text-[#1f5e2a] uppercase">
          <span
            className="inline-block h-2 w-2 rounded-full"
            style={{ background: "#00873a" }}
          />
          {t("activeKicker")}
        </span>
        <h2
          className="font-display mt-5 text-3xl text-black sm:text-4xl"
          style={{ lineHeight: "1.05" }}
        >
          {t("activeTitle")}
        </h2>
        <p className="mt-3 text-base text-[#1a1a1a]">{t("activeBody")}</p>
        {address && (
          <p className="mx-auto mt-2 max-w-md break-all font-mono text-xs text-[#6b7d6f]">
            {address}
          </p>
        )}
      </div>
    );
  }

  if (state === "pending") {
    return (
      <div className="text-center">
        <span className="inline-flex items-center gap-2 rounded-full border border-amber-300 bg-amber-50 px-4 py-1.5 text-xs font-bold tracking-[0.1em] text-amber-900 uppercase">
          {t("pendingKicker")}
        </span>
        <h2
          className="font-display mt-5 text-3xl text-black sm:text-4xl"
          style={{ lineHeight: "1.05" }}
        >
          {t("pendingTitle")}
        </h2>
        <p className="mt-3 text-base text-[#1a1a1a]">{t("pendingBody")}</p>
        {address && (
          <div className="mx-auto mt-4 max-w-md rounded-xl bg-[#f6f7f4] p-3 text-xs text-[#1a1a1a]">
            <div className="break-all font-mono">{address}</div>
            {storedEmail && <div className="mt-1">{storedEmail}</div>}
            {storedTelegram && (
              <div className="mt-1 text-[#2e6b3a]">{storedTelegram}</div>
            )}
          </div>
        )}
      </div>
    );
  }

  if (state === "rejected") {
    return (
      <div className="text-center">
        <span className="inline-flex items-center gap-2 rounded-full border border-red-200 bg-red-50 px-4 py-1.5 text-xs font-bold tracking-[0.1em] text-red-900 uppercase">
          {t("rejectedKicker")}
        </span>
        <h2
          className="font-display mt-5 text-3xl text-black sm:text-4xl"
          style={{ lineHeight: "1.05" }}
        >
          {t("rejectedTitle")}
        </h2>
        <p className="mt-3 text-base text-[#1a1a1a]">{t("rejectedBody")}</p>
      </div>
    );
  }

  return (
    <>
      <div className="text-center">
        <span
          className="text-[11px] font-bold tracking-[0.18em] uppercase"
          style={{ color: "#2e6b3a", fontFamily: "var(--font-header)" }}
        >
          {t("kicker")}
        </span>
        <h2
          className="font-display mt-3 text-3xl text-black sm:text-4xl"
          style={{ lineHeight: "1.05" }}
        >
          {t("title1")} <em>{t("title2")}</em>
        </h2>
        <p className="mx-auto mt-4 max-w-xl text-sm leading-relaxed text-[#1a1a1a] sm:text-base">
          {t("intro")}
        </p>
        {banner && (
          <p className="mx-auto mt-4 max-w-xl rounded-2xl border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900">
            {banner}
          </p>
        )}
      </div>

      <div className="mt-8 rounded-2xl border border-black/8 bg-[#fafaf8] p-6 sm:p-8">
        {!wagmiAddress ? (
          <div className="text-center">
            <h3
              className="text-lg font-bold text-black"
              style={{ fontFamily: "var(--font-header)" }}
            >
              {t("connectTitle")}
            </h3>
            <p className="mt-2 text-sm text-[#4a4a4a]">{t("connectBody")}</p>
            <div className="mt-6 flex justify-center">
              <ConnectButton.Custom>
                {({ openConnectModal }) => (
                  <button
                    type="button"
                    onClick={openConnectModal}
                    className="rounded-full bg-black px-8 py-3 text-sm font-bold text-white transition-opacity hover:opacity-90"
                    style={{ fontFamily: "var(--font-header)" }}
                  >
                    {t("connectCta")}
                  </button>
                )}
              </ConnectButton.Custom>
            </div>
          </div>
        ) : state === "loading" ? (
          <div className="flex items-center justify-center py-10">
            <Spinner />
          </div>
        ) : (
          <form onSubmit={onSubmit}>
            <h3
              className="text-lg font-bold text-black"
              style={{ fontFamily: "var(--font-header)" }}
            >
              {t("requestTitle")}
            </h3>
            <p className="mt-1 text-sm text-[#4a4a4a]">{t("requestBody")}</p>

            <div className="mt-5 rounded-xl border border-black/10 bg-white px-4 py-3 text-xs">
              <div className="font-semibold uppercase tracking-[0.06em] text-[#6b7d6f]">
                {t("fieldEth")}
              </div>
              <div className="mt-1 break-all font-mono text-[#1a1a1a]">
                {wagmiAddress}
              </div>
            </div>

            <label className="mt-4 block text-xs font-semibold tracking-[0.06em] uppercase text-[#1a1a1a]">
              {t("fieldEmail")}
            </label>
            <input
              type="email"
              required
              autoComplete="email"
              placeholder="you@example.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="mt-1.5 w-full rounded-xl border border-black/10 bg-white px-4 py-2.5 text-sm text-black focus:border-[#2e6b3a] focus:outline-none focus:ring-1 focus:ring-[#2e6b3a]"
            />

            <label className="mt-4 block text-xs font-semibold tracking-[0.06em] uppercase text-[#1a1a1a]">
              {t("fieldTelegram")}{" "}
              <span className="text-[#6b7d6f]">{t("optional")}</span>
            </label>
            <input
              type="text"
              spellCheck={false}
              placeholder="@username"
              value={telegram}
              onChange={(e) => setTelegram(e.target.value)}
              className="mt-1.5 w-full rounded-xl border border-black/10 bg-white px-4 py-2.5 text-sm text-black focus:border-[#2e6b3a] focus:outline-none focus:ring-1 focus:ring-[#2e6b3a]"
            />
            <p className="mt-1 text-xs text-[#6b7d6f]">{t("telegramHint")}</p>

            <button
              type="submit"
              disabled={submit.kind === "submitting" || submit.kind === "ok"}
              className="mt-6 inline-flex w-full items-center justify-center gap-2 rounded-full bg-black px-6 py-3 text-sm font-bold text-white transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-60"
              style={{ fontFamily: "var(--font-header)" }}
            >
              {submit.kind === "submitting" && <Spinner />}
              {submit.kind === "ok" ? t("requestSent") : t("requestSubmit")}
            </button>

            {submit.kind === "ok" && (
              <p className="mt-3 rounded-xl bg-green-50 px-3 py-2 text-sm text-green-900">
                {t("requestOk")}
              </p>
            )}
            {submit.kind === "err" && (
              <p className="mt-3 rounded-xl bg-red-50 px-3 py-2 text-sm text-red-900">
                {submit.message}
              </p>
            )}
          </form>
        )}
      </div>
    </>
  );
}
