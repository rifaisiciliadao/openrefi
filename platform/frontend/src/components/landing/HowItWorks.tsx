"use client";

import { useTranslations } from "next-intl";
import { useInView } from "@/lib/landing/useInView";

const STEP_NUMBERS = ["01", "02", "03", "04", "05"];
const RAILS = ["usdc", "campaign", "yield", "grow"];
const RAIL_STYLES = {
  usdc: "bg-[#0f766e]",
  campaign: "bg-[#061b31]",
  yield: "bg-[#00873a]",
  grow: "bg-[#f59e0b]",
} as const;

export function HowItWorks() {
  const t = useTranslations("landing.how");
  const { ref, inView } = useInView<HTMLDivElement>();

  return (
    <section
      id="how"
      className="relative isolate w-full overflow-hidden bg-[#f7f8f1] py-28 md:py-36"
      style={{
        borderTop: "1px solid rgba(6,27,49,0.08)",
        boxShadow: "inset 0 1px 0 rgba(255,255,255,0.78)",
      }}
    >
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 -z-10 opacity-[0.18]"
        style={{
          backgroundImage:
            "linear-gradient(rgba(6,27,49,0.12) 1px, transparent 1px), linear-gradient(90deg, rgba(6,27,49,0.1) 1px, transparent 1px)",
          backgroundSize: "72px 72px",
        }}
      />

      <div ref={ref} className="mx-auto max-w-7xl px-6 md:px-8">
        <div className="grid gap-12 md:grid-cols-[0.86fr_1.14fr] md:items-end">
          <div>
            <span
              className={`reveal ${inView ? "in-view" : ""} mb-6 inline-block text-xs font-bold uppercase tracking-[0.18em]`}
              style={{ color: "#1f5132", fontFamily: "var(--font-header)" }}
            >
              {t("kicker")}
            </span>
            <h2
              className={`reveal reveal-delay-1 ${inView ? "in-view" : ""} font-display text-4xl sm:text-5xl md:text-6xl`}
              style={{ color: "#061b31", lineHeight: "1.02" }}
            >
              {t("title1")} <em>{t("title2")}</em>
            </h2>
          </div>
          <p
            className={`reveal reveal-delay-2 ${inView ? "in-view" : ""} max-w-2xl text-lg leading-relaxed md:justify-self-end`}
            style={{ color: "#30445d" }}
          >
            {t("intro")}
          </p>
        </div>

        <div className="mt-16 grid gap-12 lg:grid-cols-[0.72fr_1.28fr] lg:gap-16">
          <aside
            className={`reveal reveal-delay-2 ${inView ? "in-view" : ""} lg:sticky lg:top-24 lg:self-start`}
          >
            <div className="border-y border-[#cfdcca] py-7">
              <p
                className="text-xs font-bold uppercase tracking-[0.18em]"
                style={{ color: "#1f5132", fontFamily: "var(--font-header)" }}
              >
                {t("ledger.kicker")}
              </p>
              <h3
                className="font-display mt-3 text-3xl leading-tight"
                style={{ color: "#061b31" }}
              >
                {t("ledger.title")}
              </h3>
              <p className="mt-4 text-base leading-7 text-[#42556e]">
                {t("ledger.body")}
              </p>
            </div>

            <div className="mt-7 space-y-4">
              {RAILS.map((rail) => (
                <div key={rail} className="grid grid-cols-[72px_1fr] items-center gap-4">
                  <div
                    className="text-xs font-bold uppercase tracking-[0.14em] text-[#061b31]"
                    style={{ fontFamily: "var(--font-header)" }}
                  >
                    {t(`rails.${rail}.label`)}
                  </div>
                  <div className="h-px bg-[#cfdcca]">
                    <span
                      className={`block h-[3px] w-1/2 -translate-y-px ${RAIL_STYLES[rail as keyof typeof RAIL_STYLES]}`}
                    />
                  </div>
                  <div />
                  <p className="text-sm leading-6 text-[#64748d]">
                    {t(`rails.${rail}.body`)}
                  </p>
                </div>
              ))}
            </div>
          </aside>

          <ol className="relative border-t border-[#cfdcca]">
            {STEP_NUMBERS.map((n, i) => (
              <li
                key={n}
                className={`reveal reveal-delay-${Math.min(i + 1, 6)} ${inView ? "in-view" : ""} grid grid-cols-[58px_1fr] gap-5 border-b border-[#cfdcca] py-8 md:grid-cols-[76px_1fr_150px] md:gap-8 md:py-9`}
              >
                <div
                  className="font-display text-2xl leading-none text-[#061b31] md:text-3xl"
                  aria-hidden="true"
                >
                  {n}
                </div>
                <div>
                  <p
                    className="text-xs font-bold uppercase tracking-[0.18em]"
                    style={{
                      color: "#1f7a3c",
                      fontFamily: "var(--font-header)",
                    }}
                  >
                    {t(`steps.${i}.signal`)}
                  </p>
                  <h3 className="font-display mt-3 text-2xl leading-tight text-[#061b31] sm:text-3xl">
                    {t(`steps.${i}.title`)}
                  </h3>
                  <p className="mt-4 max-w-2xl text-base leading-7 text-[#42556e]">
                    {t(`steps.${i}.body`)}
                  </p>
                </div>
                <div className="hidden items-start justify-end md:flex">
                  <span className="rounded-full border border-[#cfdcca] bg-white/70 px-3 py-1 text-xs font-bold uppercase tracking-[0.12em] text-[#30445d]">
                    {t(`steps.${i}.asset`)}
                  </span>
                </div>
              </li>
            ))}
          </ol>
        </div>

        <div className="mt-16 grid gap-8 border-y border-[#cfdcca] py-10 md:grid-cols-[0.8fr_1.2fr] md:items-center">
          <div className={`reveal reveal-delay-3 ${inView ? "in-view" : ""}`}>
            <p
              className="text-xs font-bold uppercase tracking-[0.18em]"
              style={{ color: "#1f5132", fontFamily: "var(--font-header)" }}
            >
              {t("grow.kicker")}
            </p>
            <h3 className="font-display mt-3 text-3xl leading-tight text-[#061b31] md:text-4xl">
              {t("grow.title")}
            </h3>
            <p className="mt-4 max-w-xl text-base leading-7 text-[#42556e]">
              {t("grow.body")}
            </p>
          </div>

          <div className="grid gap-3 sm:grid-cols-3">
            {["treasury", "staking", "floor"].map((item, i) => (
              <div
                key={item}
                className={`reveal reveal-delay-${Math.min(i + 4, 6)} ${inView ? "in-view" : ""} border-l border-[#cfdcca] pl-5`}
              >
                <p
                  className="text-xs font-bold uppercase tracking-[0.16em]"
                  style={{ color: "#1f7a3c", fontFamily: "var(--font-header)" }}
                >
                  {t(`grow.items.${item}.label`)}
                </p>
                <p className="mt-2 text-sm leading-6 text-[#42556e]">
                  {t(`grow.items.${item}.body`)}
                </p>
              </div>
            ))}
          </div>
        </div>

        <div className="mt-12 flex flex-col items-start gap-8 md:flex-row md:items-center md:justify-between">
          <p
            className={`reveal ${inView ? "in-view" : ""} max-w-xl text-base leading-relaxed`}
            style={{ color: "#42556e" }}
          >
            {t("tail")}
          </p>
          <div className="flex flex-wrap gap-3">
            <a
              href="#campaigns"
              className={`reveal reveal-delay-2 ${inView ? "in-view" : ""} group inline-flex shrink-0 items-center gap-2 rounded-full bg-[#061b31] px-7 py-3.5 text-sm font-bold text-white transition-all duration-300 hover:-translate-y-0.5 hover:shadow-[0_14px_34px_-18px_rgba(6,27,49,0.8)]`}
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
            </a>
            <a
              href="/grow"
              className={`reveal reveal-delay-3 ${inView ? "in-view" : ""} inline-flex shrink-0 items-center rounded-full border border-[#b8c9b4] bg-white/70 px-7 py-3.5 text-sm font-bold text-[#061b31] transition-all duration-300 hover:-translate-y-0.5 hover:bg-white`}
              style={{ fontFamily: "var(--font-header)" }}
            >
              {t("grow.cta")}
            </a>
          </div>
        </div>
      </div>
    </section>
  );
}
