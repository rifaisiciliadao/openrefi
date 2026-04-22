"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { useInView } from "@/lib/landing/useInView";

const STEP_NUMBERS = ["01", "02", "03", "04", "05"];

export function HowItWorks() {
  const t = useTranslations("landing.how");
  const { ref, inView } = useInView<HTMLDivElement>();

  return (
    <section
      id="how"
      className="glass-section relative w-full py-32 md:py-40"
      style={{
        borderTop: "1px solid rgba(255,255,255,0.5)",
        boxShadow: "inset 0 1px 0 rgba(255,255,255,0.6)",
      }}
    >
      <div ref={ref} className="mx-auto max-w-7xl px-6 md:px-8">
        <div className="mb-20 max-w-3xl">
          <span
            className={`reveal ${inView ? "in-view" : ""} mb-6 inline-block text-xs font-bold tracking-[0.18em] uppercase`}
            style={{ color: "#1a1a1a", fontFamily: "var(--font-header)" }}
          >
            {t("kicker")}
          </span>
          <h2
            className={`reveal reveal-delay-1 ${inView ? "in-view" : ""} font-display text-4xl sm:text-5xl md:text-6xl`}
            style={{ color: "#000000", lineHeight: "1.02" }}
          >
            {t("title1")} <em>{t("title2")}</em>
          </h2>
          <p
            className={`reveal reveal-delay-2 ${inView ? "in-view" : ""} mt-6 max-w-xl text-lg leading-relaxed`}
            style={{ color: "#1a1a1a" }}
          >
            {t("intro")}
          </p>
        </div>

        <ol className="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-5 lg:gap-3">
          {STEP_NUMBERS.map((n, i) => (
            <li
              key={n}
              className={`reveal reveal-delay-${Math.min(i + 1, 6)} ${inView ? "in-view" : ""} group relative flex flex-col rounded-2xl p-6 transition-all duration-500 hover:-translate-y-1`}
              style={{
                background: "rgba(255,255,255,0.68)",
                border: "1px solid rgba(255,255,255,0.7)",
                backdropFilter: "blur(14px) saturate(1.1)",
                WebkitBackdropFilter: "blur(14px) saturate(1.1)",
                boxShadow:
                  "0 1px 0 0 rgba(255,255,255,0.8) inset, 0 6px 20px -8px rgba(0,0,0,0.08)",
              }}
            >
              <span
                className="font-display inline-flex h-8 w-8 items-center justify-center rounded-full text-xs transition-all duration-300 group-hover:scale-110"
                style={{
                  color: "#ffffff",
                  background:
                    "linear-gradient(135deg, #006b2c 0%, #00873a 100%)",
                  boxShadow: "0 2px 8px -2px rgba(0,135,58,0.4)",
                }}
              >
                {n}
              </span>
              <h3
                className="font-display mt-5 text-xl leading-tight transition-transform duration-300 group-hover:translate-x-0.5"
                style={{ color: "#000000" }}
              >
                {t(`steps.${i}.title`)}
              </h3>
              <p
                className="mt-3 text-base leading-relaxed"
                style={{ color: "#1a1a1a" }}
              >
                {t(`steps.${i}.body`)}
              </p>
              <span
                className="absolute bottom-0 left-0 h-[2px] w-0 rounded-full transition-all duration-500 group-hover:w-full"
                style={{
                  background:
                    "linear-gradient(90deg, #006b2c 0%, #00873a 100%)",
                }}
              />
            </li>
          ))}
        </ol>

        <div className="mt-20 flex flex-col items-start gap-6 border-t border-[#eaeaea] pt-10 md:flex-row md:items-center md:justify-between">
          <p
            className={`reveal ${inView ? "in-view" : ""} max-w-xl text-base leading-relaxed`}
            style={{ color: "#1a1a1a" }}
          >
            {t("tail")}
          </p>
          <Link
            href="/create"
            className={`reveal reveal-delay-2 ${inView ? "in-view" : ""} group inline-flex shrink-0 items-center gap-2 rounded-full bg-black px-8 py-3.5 text-sm font-bold text-white transition-all duration-300 hover:scale-[1.03] hover:shadow-[0_12px_32px_-8px_rgba(0,0,0,0.4)]`}
            style={{ fontFamily: "var(--font-header)" }}
          >
            {t("ctaSee")}
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
          </Link>
        </div>
      </div>
    </section>
  );
}
