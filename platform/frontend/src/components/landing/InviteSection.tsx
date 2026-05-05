"use client";

import { useEffect, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useAccount } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useInviteGate } from "@/lib/inviteGate";
import { requestInvite } from "@/lib/api";
import { Spinner } from "@/components/Spinner";

type SubmitState =
  | { kind: "idle" }
  | { kind: "submitting" }
  | { kind: "ok" }
  | { kind: "err"; message: string };

export function InviteSection() {
  const t = useTranslations("landing.invite");
  const { state, address, email: storedEmail, telegram: storedTelegram, refresh } =
    useInviteGate();
  const { address: wagmiAddress } = useAccount();
  const params = useSearchParams();
  const sectionRef = useRef<HTMLElement | null>(null);

  const [email, setEmail] = useState("");
  const [telegram, setTelegram] = useState("");
  const [submit, setSubmit] = useState<SubmitState>({ kind: "idle" });

  useEffect(() => {
    if (params.get("gated") === "1" && sectionRef.current) {
      sectionRef.current.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  }, [params]);

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

  // ---- Approved view ----
  if (state === "approved") {
    return (
      <section
        ref={sectionRef}
        id="invite"
        className="glass-section relative px-6 py-16"
      >
        <div className="mx-auto max-w-3xl text-center">
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
          <p className="mx-auto mt-2 max-w-md break-all font-mono text-xs text-[#6b7d6f]">
            {address}
          </p>
        </div>
      </section>
    );
  }

  // ---- Pending view ----
  if (state === "pending") {
    return (
      <section
        ref={sectionRef}
        id="invite"
        className="glass-section relative px-6 py-16"
      >
        <div className="mx-auto max-w-3xl text-center">
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
          <div className="mx-auto mt-4 max-w-md rounded-xl bg-white/80 p-3 text-xs text-[#1a1a1a]">
            <div className="break-all font-mono">{address}</div>
            {storedEmail && <div className="mt-1">{storedEmail}</div>}
            {storedTelegram && (
              <div className="mt-1 text-[#2e6b3a]">{storedTelegram}</div>
            )}
          </div>
        </div>
      </section>
    );
  }

  // ---- Rejected view ----
  if (state === "rejected") {
    return (
      <section
        ref={sectionRef}
        id="invite"
        className="glass-section relative px-6 py-16"
      >
        <div className="mx-auto max-w-3xl text-center">
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
      </section>
    );
  }

  // ---- Default: connect / request ----
  return (
    <section
      ref={sectionRef}
      id="invite"
      className="glass-section relative px-6 py-20"
    >
      <div className="mx-auto max-w-4xl">
        <div className="text-center">
          <span
            className="text-[11px] font-bold tracking-[0.18em] uppercase"
            style={{ color: "#2e6b3a", fontFamily: "var(--font-header)" }}
          >
            {t("kicker")}
          </span>
          <h2
            className="font-display mt-3 text-4xl text-black sm:text-5xl"
            style={{ lineHeight: "1.05" }}
          >
            {t("title1")} <em>{t("title2")}</em>
          </h2>
          <p className="mx-auto mt-5 max-w-2xl text-base leading-relaxed text-[#1a1a1a] sm:text-lg">
            {t("intro")}
          </p>
          {banner && (
            <p className="mx-auto mt-5 max-w-xl rounded-2xl border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900">
              {banner}
            </p>
          )}
        </div>

        <div className="mt-12 rounded-2xl border border-black/8 bg-white/95 p-6 shadow-[0_4px_18px_-8px_rgba(0,0,0,0.12)] sm:p-10">
          {!wagmiAddress ? (
            // No wallet connected
            <div className="text-center">
              <h3
                className="text-lg font-bold text-black"
                style={{ fontFamily: "var(--font-header)" }}
              >
                {t("connectTitle")}
              </h3>
              <p className="mt-2 text-sm text-[#4a4a4a]">
                {t("connectBody")}
              </p>
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
            // Wallet connected, no record yet → request form
            <form onSubmit={onSubmit}>
              <h3
                className="text-lg font-bold text-black"
                style={{ fontFamily: "var(--font-header)" }}
              >
                {t("requestTitle")}
              </h3>
              <p className="mt-1 text-sm text-[#4a4a4a]">{t("requestBody")}</p>

              <div className="mt-5 rounded-xl border border-black/10 bg-[#f6f7f4] px-4 py-3 text-xs">
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
                {t("fieldTelegram")} <span className="text-[#6b7d6f]">{t("optional")}</span>
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
      </div>
    </section>
  );
}
