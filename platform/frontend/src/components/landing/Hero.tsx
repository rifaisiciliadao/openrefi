"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { Nav } from "./Nav";
import { useCountUp } from "@/lib/landing/useCountUp";

type StatCardProps = {
  index: number;
  headline: string;
  kicker: string;
  note: string;
  counter?: {
    to: number;
    suffix?: string;
    prefix?: string;
  };
};

function StatCard({ index, headline, kicker, note, counter }: StatCardProps) {
  const [started, setStarted] = useState(false);
  useEffect(() => {
    const t = window.setTimeout(() => setStarted(true), 700 + index * 120);
    return () => window.clearTimeout(t);
  }, [index]);

  const count = useCountUp({
    to: counter?.to ?? 0,
    duration: 1600,
    active: Boolean(counter) && started,
  });

  const display = counter
    ? `${counter.prefix ?? ""}${count.formatted}${counter.suffix ?? ""}`
    : headline;

  return (
    <div
      className="animate-fade-rise-delay-3 card-glow shimmer-host group relative flex flex-col items-center rounded-2xl px-4 py-6 text-center transition-all duration-400 hover:-translate-y-1.5"
      style={{
        animationDelay: `${0.6 + index * 0.1}s`,
        background: "rgba(255,255,255,0.72)",
        border: "1px solid rgba(255,255,255,0.75)",
        backdropFilter: "blur(18px) saturate(1.12)",
        WebkitBackdropFilter: "blur(18px) saturate(1.12)",
        boxShadow:
          "0 1px 0 0 rgba(255,255,255,0.9) inset, 0 8px 28px -10px rgba(0,0,0,0.14)",
      }}
    >
      <span
        className="pointer-events-none absolute inset-0 rounded-2xl opacity-0 transition-opacity duration-400 group-hover:opacity-100"
        style={{
          background:
            "radial-gradient(circle at 50% 0%, rgba(0,135,58,0.14) 0%, transparent 70%)",
        }}
      />
      <span
        className="font-display text-3xl leading-none transition-transform duration-400 group-hover:scale-[1.06] sm:text-4xl md:text-5xl"
        style={{ color: "#000000" }}
      >
        {display}
      </span>
      <span
        className="mt-2 text-[11px] font-bold tracking-[0.16em] uppercase"
        style={{ color: "#1a1a1a", fontFamily: "var(--font-header)" }}
      >
        {kicker}
      </span>
      <span
        className="mt-2 max-w-[22ch] text-[11px] leading-snug opacity-0 transition-opacity duration-400 group-hover:opacity-100"
        style={{ color: "#4a4a4a" }}
      >
        {note}
      </span>
    </div>
  );
}

export function Hero() {
  const t = useTranslations("landing.hero");
  return (
    <section id="home" className="relative min-h-screen w-full overflow-hidden">
      <div
        aria-hidden
        className="animate-float-wide pointer-events-none absolute left-[-10%] top-[10%] h-72 w-72 rounded-full"
        style={{
          background:
            "radial-gradient(circle, rgba(127,252,151,0.22) 0%, transparent 70%)",
          filter: "blur(40px)",
        }}
      />
      <div
        aria-hidden
        className="animate-float-wide pointer-events-none absolute right-[-8%] top-[40%] h-80 w-80 rounded-full"
        style={{
          background:
            "radial-gradient(circle, rgba(0,135,58,0.18) 0%, transparent 70%)",
          filter: "blur(48px)",
          animationDelay: "4s",
        }}
      />

      <div className="relative z-10 flex flex-col">
        <Nav />
        <div
          className="flex flex-col items-center justify-center px-6 pb-40 text-center"
          style={{ paddingTop: "calc(8rem - 75px)" }}
        >
          <span className="animate-fade-rise mb-8 inline-block">
            <span className="animate-float-soft inline-flex items-center gap-2 rounded-full border border-black/10 bg-white/85 px-4 py-1.5 text-xs font-bold tracking-[0.1em] text-[#1f2d1f] uppercase backdrop-blur-md shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
              <span className="relative inline-block h-1.5 w-1.5">
                <span
                  className="absolute inset-0 rounded-full"
                  style={{ background: "#00873a" }}
                />
                <span
                  className="animate-live-ring absolute inset-0 rounded-full"
                  style={{ background: "#00873a" }}
                />
              </span>
              {t("badge")}
            </span>
          </span>

          <h1
            className="animate-fade-rise font-display max-w-7xl text-5xl sm:text-7xl md:text-8xl"
            style={{
              color: "#000000",
              lineHeight: "0.95",
              textShadow: "0 1px 0 rgba(255,255,255,0.4)",
            }}
          >
            {t("titleA")} <em>{t("titleLand")}</em>
            <br className="hidden sm:block" /> {t("titleB")}{" "}
            <em>{t("titleYield")}</em>
          </h1>

          <p
            className="animate-fade-rise-delay mt-8 max-w-2xl text-lg leading-relaxed sm:text-xl"
            style={{
              color: "#0f0f0f",
              textShadow: "0 1px 0 rgba(255,255,255,0.4)",
            }}
          >
            {t("subtitle1")}{" "}
            <span
              style={{
                fontFamily: "var(--font-header)",
                fontWeight: 700,
                color: "#000000",
              }}
            >
              {t("subtitleHighlight")}
            </span>{" "}
            {t("subtitle2")}
          </p>

          <div className="animate-fade-rise-delay-2 mt-12 flex flex-col items-center gap-3 sm:flex-row sm:gap-5">
            <a
              href="#campaigns"
              className="shimmer-host group relative inline-flex items-center gap-2 rounded-full bg-black px-14 py-5 text-base font-bold text-white shadow-[0_8px_24px_-8px_rgba(0,0,0,0.4)] transition-all duration-300 hover:scale-[1.03] hover:shadow-[0_16px_40px_-10px_rgba(0,0,0,0.55)]"
              style={{ fontFamily: "var(--font-header)" }}
            >
              <span className="relative z-10 inline-flex items-center gap-2">
                {t("ctaFund")}
                <svg
                  width="16"
                  height="16"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  className="transition-transform duration-300 group-hover:translate-x-1"
                >
                  <path d="M5 12h14M13 5l7 7-7 7" />
                </svg>
              </span>
            </a>
            <a
              href="#how"
              className="shimmer-host shimmer-host-dark inline-flex items-center gap-2 rounded-full border border-black/15 bg-white/70 px-10 py-5 text-base font-bold text-black backdrop-blur-md transition-all duration-300 hover:bg-white"
              style={{ fontFamily: "var(--font-header)" }}
            >
              {t("ctaHow")}
            </a>
          </div>

          <div className="mt-20 grid w-full max-w-5xl grid-cols-2 gap-3 sm:grid-cols-4 sm:gap-4">
            <StatCard
              index={0}
              headline="100%"
              kicker={t("statOnchain")}
              note={t("statOnchainNote")}
              counter={{ to: 100, suffix: "%" }}
            />
            <StatCard
              index={1}
              headline="1–5×"
              kicker={t("statYield")}
              note={t("statYieldNote")}
            />
            <StatCard
              index={2}
              headline="2%"
              kicker={t("statFee")}
              note={t("statFeeNote")}
              counter={{ to: 2, suffix: "%" }}
            />
            <StatCard
              index={3}
              headline="123+"
              kicker={t("statTests")}
              note={t("statTestsNote")}
              counter={{ to: 123, suffix: "+" }}
            />
          </div>

          <div
            className="animate-fade-rise-delay-3 mt-16 flex flex-col items-center gap-3 opacity-70"
            style={{ animationDelay: "1.2s" }}
          >
            <span
              className="text-[10px] tracking-[0.3em] uppercase"
              style={{
                color: "#1a1a1a",
                fontFamily: "var(--font-header)",
                fontWeight: 700,
              }}
            >
              {t("scroll")}
            </span>
            <span
              className="relative inline-block h-10 w-[1px]"
              style={{
                background:
                  "linear-gradient(to bottom, transparent, #1a1a1a 35%, transparent)",
              }}
            />
          </div>
        </div>
      </div>
    </section>
  );
}
