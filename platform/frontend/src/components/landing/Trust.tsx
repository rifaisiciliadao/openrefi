"use client";

import { useTranslations } from "next-intl";
import { useInView } from "@/lib/landing/useInView";

const ITEM_COUNT = 4;

export function Trust() {
  const t = useTranslations("landing.trust");
  const { ref, inView } = useInView<HTMLDivElement>();

  return (
    <section
      id="trust"
      className="glass-section-dark relative w-full py-32 md:py-40"
      style={{
        color: "#ffffff",
        borderTop: "1px solid rgba(255,255,255,0.08)",
      }}
    >
      <div ref={ref} className="mx-auto max-w-7xl px-6 md:px-8">
        <div className="grid grid-cols-1 gap-16 md:grid-cols-12">
          <div className="md:col-span-5">
            <span
              className={`reveal ${inView ? "in-view" : ""} mb-6 inline-block text-xs font-bold tracking-[0.18em] uppercase`}
              style={{
                color: "rgba(255,255,255,0.7)",
                fontFamily: "var(--font-header)",
              }}
            >
              {t("kicker")}
            </span>
            <h2
              className={`reveal reveal-delay-1 ${inView ? "in-view" : ""} font-display text-4xl sm:text-5xl md:text-6xl`}
              style={{ color: "#ffffff", lineHeight: "1.02" }}
            >
              {t("title1")} <em>{t("title2")}</em>
            </h2>
            <p
              className={`reveal reveal-delay-2 ${inView ? "in-view" : ""} mt-8 max-w-md text-lg leading-relaxed`}
              style={{ color: "rgba(255,255,255,0.86)" }}
            >
              {t("intro")}
            </p>

            <div
              className={`reveal reveal-delay-3 ${inView ? "in-view" : ""} mt-10 flex flex-wrap gap-3`}
            >
              <a
                href="https://github.com/rifaisiciliadao/growfi"
                target="_blank"
                rel="noopener noreferrer"
                className="group inline-flex items-center gap-2 rounded-full border border-white/25 px-6 py-2.5 text-sm font-bold text-white transition-all duration-300 hover:-translate-y-0.5 hover:bg-white/10"
                style={{ fontFamily: "var(--font-header)" }}
              >
                <svg
                  width="16"
                  height="16"
                  viewBox="0 0 24 24"
                  fill="currentColor"
                >
                  <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0024 12c0-6.63-5.37-12-12-12z" />
                </svg>
                {t("ghBtn")}
              </a>
              <a
                href="#"
                className="group inline-flex items-center gap-2 rounded-full border border-white/25 px-6 py-2.5 text-sm font-bold text-white transition-all duration-300 hover:-translate-y-0.5 hover:bg-white/10"
                style={{ fontFamily: "var(--font-header)" }}
              >
                {t("docsBtn")}
                <svg
                  width="14"
                  height="14"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2.2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  className="transition-transform duration-300 group-hover:-translate-y-0.5 group-hover:translate-x-0.5"
                >
                  <path d="M7 17L17 7M17 7H8M17 7v9" />
                </svg>
              </a>
              <a
                href="#"
                className="inline-flex items-center gap-2 rounded-full bg-white px-6 py-2.5 text-sm font-bold text-black transition-all duration-300 hover:scale-[1.03] hover:shadow-[0_12px_32px_-8px_rgba(255,255,255,0.3)]"
                style={{ fontFamily: "var(--font-header)" }}
              >
                {t("contractBtn")}
              </a>
            </div>
          </div>

          <div className="md:col-span-7">
            <dl className="grid grid-cols-1 gap-0 sm:grid-cols-2">
              {Array.from({ length: ITEM_COUNT }).map((_, i) => (
                <div
                  key={i}
                  className={`reveal reveal-delay-${Math.min(i + 1, 6)} ${inView ? "in-view" : ""} group relative flex flex-col py-8 transition-colors duration-400 hover:bg-white/[0.04] md:py-10`}
                  style={{
                    borderTop:
                      i === 0 || i === 1
                        ? "1px solid rgba(255,255,255,0.14)"
                        : "none",
                    borderLeft:
                      i % 2 === 1
                        ? "1px solid rgba(255,255,255,0.14)"
                        : "none",
                    borderBottom: "1px solid rgba(255,255,255,0.14)",
                    paddingLeft: i % 2 === 1 ? "2rem" : 0,
                    paddingRight: i % 2 === 0 ? "2rem" : 0,
                  }}
                >
                  <dt
                    className="text-xs font-bold tracking-[0.18em] uppercase"
                    style={{
                      color: "rgba(255,255,255,0.7)",
                      fontFamily: "var(--font-header)",
                    }}
                  >
                    {t(`items.${i}.label`)}
                  </dt>
                  <dd
                    className="font-display mt-3 text-4xl sm:text-5xl"
                    style={{ color: "#ffffff" }}
                  >
                    {t(`items.${i}.value`)}
                  </dd>
                  <p
                    className="mt-4 max-w-xs text-base leading-relaxed"
                    style={{ color: "rgba(255,255,255,0.82)" }}
                  >
                    {t(`items.${i}.detail`)}
                  </p>
                </div>
              ))}
            </dl>

            <div
              className={`reveal reveal-delay-5 ${inView ? "in-view" : ""} mt-10 rounded-2xl border p-8 transition-all duration-400 hover:border-white/25`}
              style={{
                borderColor: "rgba(255,255,255,0.14)",
                background:
                  "linear-gradient(135deg, rgba(0,107,44,0.24) 0%, rgba(0,135,58,0.06) 100%)",
              }}
            >
              <div className="flex items-start gap-4">
                <div
                  className="flex h-12 w-12 shrink-0 items-center justify-center rounded-full"
                  style={{ background: "rgba(127,252,151,0.16)" }}
                >
                  <svg
                    width="22"
                    height="22"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="#7ffc97"
                    strokeWidth="1.8"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  >
                    <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
                    <path d="M9 12l2 2 4-4" />
                  </svg>
                </div>
                <div>
                  <h3
                    className="font-display text-xl"
                    style={{ color: "#ffffff" }}
                  >
                    {t("escrowTitle1")} <em>{t("escrowTitle2")}</em>
                  </h3>
                  <p
                    className="mt-2 text-base leading-relaxed"
                    style={{ color: "rgba(255,255,255,0.86)" }}
                  >
                    {t("escrowBody")}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
