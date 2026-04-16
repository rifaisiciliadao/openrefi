"use client";

import { useTranslations } from "next-intl";

export function Footer() {
  const t = useTranslations("footer");
  const year = new Date().getFullYear();

  return (
    <footer className="bg-slate-950 w-full mt-20">
      <div className="flex flex-col md:flex-row justify-between items-center px-8 py-12 max-w-7xl mx-auto">
        <div className="mb-6 md:mb-0 text-center md:text-left">
          <span className="text-lg font-bold text-white tracking-tight">
            GrowFi
          </span>
          <p className="text-sm text-slate-400 mt-2">{t("tagline", { year })}</p>
        </div>
        <div className="flex flex-wrap justify-center md:justify-end gap-x-8 gap-y-4">
          {(["docs", "github", "discord", "terms", "privacy"] as const).map(
            (key) => (
              <a
                key={key}
                href="#"
                className="text-sm text-slate-400 hover:text-green-400 transition-colors"
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
