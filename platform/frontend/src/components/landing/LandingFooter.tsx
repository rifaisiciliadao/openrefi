"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { LandingLogo } from "./LandingLogo";
import { useInView } from "@/lib/landing/useInView";

export function LandingFooter() {
  const t = useTranslations("landing.footer");
  const { ref, inView } = useInView<HTMLDivElement>();

  const COLS: {
    title: string;
    links: { label: string; href: string; external?: boolean; internal?: boolean }[];
  }[] = [
    {
      title: t("colProduct"),
      links: [
        { label: t("linkHow"), href: "#how" },
        { label: t("linkCampaigns"), href: "#campaigns" },
        { label: t("linkProducers"), href: "/create", internal: true },
        { label: t("linkPortfolio"), href: "/portfolio", internal: true },
      ],
    },
    {
      title: t("colProtocol"),
      links: [
        { label: t("linkDocs"), href: "#" },
        { label: t("linkContracts"), href: "#" },
        { label: t("linkSubgraph"), href: "#" },
        { label: t("linkAudit"), href: "#" },
      ],
    },
    {
      title: t("colCommunity"),
      links: [
        {
          label: t("linkGithub"),
          href: "https://github.com/rifaisiciliadao/growfi",
          external: true,
        },
        { label: t("linkDiscord"), href: "#" },
        { label: t("linkTwitter"), href: "#" },
        { label: t("linkNewsletter"), href: "#" },
      ],
    },
  ];

  return (
    <footer
      className="glass-section relative w-full"
      style={{
        borderTop: "1px solid rgba(255,255,255,0.5)",
        boxShadow: "inset 0 1px 0 rgba(255,255,255,0.6)",
      }}
    >
      <div ref={ref} className="mx-auto max-w-7xl px-6 py-20 md:px-8">
        <div className="grid grid-cols-1 gap-16 md:grid-cols-12">
          <div className={`reveal ${inView ? "in-view" : ""} md:col-span-5`}>
            <LandingLogo />
            <p
              className="font-display mt-6 max-w-sm text-2xl leading-snug"
              style={{ color: "#000000" }}
            >
              {t("tagline1")} <em>{t("tagline2")}</em>
            </p>
            <p
              className="mt-6 max-w-sm text-base leading-relaxed"
              style={{ color: "#1a1a1a" }}
            >
              {t("about")}
            </p>
          </div>

          <div className="md:col-span-7 grid grid-cols-2 gap-8 sm:grid-cols-3">
            {COLS.map((col, ci) => (
              <div
                key={col.title}
                className={`reveal reveal-delay-${ci + 1} ${inView ? "in-view" : ""}`}
              >
                <h4
                  className="mb-5 text-xs font-bold tracking-[0.18em] uppercase"
                  style={{ color: "#000000", fontFamily: "var(--font-header)" }}
                >
                  {col.title}
                </h4>
                <ul className="flex flex-col gap-3">
                  {col.links.map((link) => (
                    <li key={link.label}>
                      {link.internal ? (
                        <Link
                          href={link.href}
                          className="text-base transition-colors text-[#4a4a4a] hover:text-black"
                        >
                          {link.label}
                        </Link>
                      ) : (
                        <a
                          href={link.href}
                          target={link.external ? "_blank" : undefined}
                          rel={link.external ? "noopener noreferrer" : undefined}
                          className="text-base transition-colors text-[#4a4a4a] hover:text-black"
                        >
                          {link.label}
                        </a>
                      )}
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </div>

        <div
          className="mt-16 flex flex-col items-start justify-between gap-4 border-t pt-8 md:flex-row md:items-center"
          style={{ borderColor: "#eaeaea" }}
        >
          <p className="text-xs" style={{ color: "#4a4a4a" }}>
            {t("copy", { year: new Date().getFullYear() })}
          </p>
          <div className="flex gap-6 text-xs" style={{ color: "#4a4a4a" }}>
            <a href="#" className="transition-colors hover:text-black">
              {t("terms")}
            </a>
            <a href="#" className="transition-colors hover:text-black">
              {t("privacy")}
            </a>
            <a href="#" className="transition-colors hover:text-black">
              {t("contact")}
            </a>
          </div>
        </div>
      </div>
    </footer>
  );
}
