"use client";

import { useTranslations } from "next-intl";

/**
 * /grow flywheel — 2×2 cyclic diagram explaining how participation feeds the
 * Treasury, the Treasury feeds the campaigns, the campaigns feed back yield,
 * and the yield feeds $GROW stakers — closing the loop.
 *
 * Reading order: top-left → top-right → bottom-right → bottom-left → loops back.
 * The clockwise SVG arrow in the centre reinforces the direction.
 */
export function Flywheel() {
  const t = useTranslations("grow.flywheel");

  const steps = [
    {
      n: "01",
      title: t("s1.title"),
      body: t("s1.body"),
      // Top-left.
      pos: "tl" as const,
    },
    {
      n: "02",
      title: t("s2.title"),
      body: t("s2.body"),
      pos: "tr" as const,
    },
    {
      n: "03",
      title: t("s3.title"),
      body: t("s3.body"),
      pos: "br" as const,
    },
    {
      n: "04",
      title: t("s4.title"),
      body: t("s4.body"),
      pos: "bl" as const,
    },
  ];

  return (
    <section className="mt-16 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm md:p-10">
      <header className="mb-8 text-center">
        <p className="text-xs uppercase tracking-[0.2em] text-emerald-700">
          {t("eyebrow")}
        </p>
        <h2 className="mt-2 text-2xl font-bold tracking-tight text-zinc-900 md:text-3xl">
          {t("title")}
        </h2>
        <p className="mx-auto mt-3 max-w-2xl text-sm text-zinc-600 md:text-base">
          {t("subtitle")}
        </p>
      </header>

      {/* Grid + central icon overlay. The icon is decorative and hidden on small screens. */}
      <div className="relative grid grid-cols-1 gap-4 md:grid-cols-2 md:gap-6">
        {steps.map((s) => (
          <article
            key={s.n}
            className={`relative rounded-xl border border-zinc-200 bg-zinc-50 p-5 transition hover:border-emerald-300 hover:bg-white ${
              s.pos === "br" ? "md:col-start-2 md:row-start-2" : ""
            } ${s.pos === "bl" ? "md:col-start-1 md:row-start-2" : ""} ${
              s.pos === "tr" ? "md:col-start-2 md:row-start-1" : ""
            }`}
          >
            <div className="mb-2 flex items-center gap-3">
              <span className="flex h-8 w-8 items-center justify-center rounded-full bg-emerald-600 text-xs font-bold text-white">
                {s.n}
              </span>
              <h3 className="text-base font-semibold text-zinc-900 md:text-lg">
                {s.title}
              </h3>
            </div>
            <p className="text-sm leading-relaxed text-zinc-600">{s.body}</p>
          </article>
        ))}

        {/* Centre flywheel ring — only visible on md+ where the 2×2 grid is symmetric. */}
        <div
          aria-hidden
          className="pointer-events-none absolute left-1/2 top-1/2 hidden -translate-x-1/2 -translate-y-1/2 md:block"
        >
          <svg
            width="80"
            height="80"
            viewBox="0 0 80 80"
            className="text-emerald-600"
          >
            {/* outer ring */}
            <circle
              cx="40"
              cy="40"
              r="34"
              fill="white"
              stroke="currentColor"
              strokeWidth="2"
              opacity="0.4"
            />
            {/* clockwise arrow */}
            <path
              d="M 40 14 A 26 26 0 1 1 16 50"
              fill="none"
              stroke="currentColor"
              strokeWidth="3"
              strokeLinecap="round"
            />
            <path
              d="M 16 50 L 14 42 L 22 46 Z"
              fill="currentColor"
            />
            <text
              x="40"
              y="46"
              textAnchor="middle"
              fontSize="11"
              fontWeight="700"
              fill="currentColor"
              className="font-mono"
            >
              FLY
            </text>
          </svg>
        </div>
      </div>

      <p className="mt-8 text-center text-xs text-zinc-500">{t("footnote")}</p>
    </section>
  );
}
