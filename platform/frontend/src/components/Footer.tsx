"use client";

import { useTranslations } from "next-intl";

export function Footer() {
  const t = useTranslations("footer");
  const year = new Date().getFullYear();

  return (
    <footer className="bg-slate-950 w-full mt-20">
      <div className="flex flex-col md:flex-row justify-between items-center px-4 md:px-8 py-10 md:py-12 max-w-7xl mx-auto gap-6 md:gap-0">
        <div className="text-center md:text-left">
          <span className="text-lg font-bold text-white tracking-tight">
            GrowFi
          </span>
          <p className="text-sm text-slate-400 mt-2">{t("tagline", { year })}</p>
        </div>
        <div className="flex flex-wrap justify-center md:justify-end gap-x-2 gap-y-1">
          {(["docs", "github", "discord", "terms", "privacy"] as const).map(
            (key) => (
              <a
                key={key}
                href="#"
                className="inline-flex items-center min-h-[44px] px-3 text-sm text-slate-400 hover:text-green-400 transition-colors"
              >
                {t(key)}
              </a>
            ),
          )}
        </div>
      </div>
    </footer>
  );
}
