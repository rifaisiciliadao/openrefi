"use client";

import { useState, useMemo } from "react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { formatUnits } from "viem";
import {
  CampaignCard,
  CampaignCardSkeleton,
  type CampaignState,
} from "@/components/CampaignCard";
import { useSubgraphCampaigns, useGlobalStats } from "@/lib/subgraph";
import { getAddresses } from "@/contracts";

type FilterKey = "all" | "funding" | "active" | "ended";
const FILTER_KEYS: FilterKey[] = ["all", "funding", "active", "ended"];

// No image fallback here — CampaignCard renders a branded gradient
// placeholder when `image` is empty, so unrelated stock photos don't
// appear on campaigns without metadata.
const PLACEHOLDER_IMAGE = "";

export default function Home() {
  const t = useTranslations("home");
  const [filter, setFilter] = useState<FilterKey>("all");
  const { factory } = getAddresses();
  const factoryDeployed =
    factory !== "0x0000000000000000000000000000000000000000";

  const { data: onChainCampaigns, isLoading } = useSubgraphCampaigns();
  const { data: stats } = useGlobalStats();

  const campaigns = useMemo(() => {
    if (!onChainCampaigns) return [];

    const toState = (s: string): CampaignState =>
      s === "Active" ? "active" : s === "Ended" ? "ended" : "funding";

    const pricePerTokenUsd = (wei: string) =>
      Number(formatUnits(BigInt(wei), 18));
    const pctFilled = (supply: string, cap: string) => {
      const c = BigInt(cap);
      return c === 0n ? 0 : Number((BigInt(supply) * 100n) / c);
    };
    const daysToDeadline = (deadline: string) => {
      const delta = Number(deadline) - Math.floor(Date.now() / 1000);
      return delta > 0 ? Math.ceil(delta / 86400) : 0;
    };

    return onChainCampaigns.map((c) => ({
      address: c.id,
      name: `Campaign ${c.id.slice(0, 8)}…`,
      producer: c.producer,
      location: "",
      image: PLACEHOLDER_IMAGE,
      state: toState(c.state),
      progress: pctFilled(c.currentSupply, c.maxCap),
      yieldRate:
        Math.round(
          Number(formatUnits(BigInt(c.currentYieldRate), 18)) * 10,
        ) / 10,
      deadline: String(daysToDeadline(c.fundingDeadline)),
      pricePerToken: pricePerTokenUsd(c.pricePerToken),
      metadataURI: c.metadataURI,
      metadataVersion: c.metadataVersion,
    }));
  }, [onChainCampaigns]);

  const filteredCampaigns =
    filter === "all" ? campaigns : campaigns.filter((c) => c.state === filter);

  const totalRaisedUsd = useMemo(() => {
    if (!onChainCampaigns) return 0;
    const sumWei = onChainCampaigns.reduce(
      (acc, c) => acc + BigInt(c.totalRaised),
      0n,
    );
    return Number(formatUnits(sumWei, 18));
  }, [onChainCampaigns]);

  return (
    <>
      <section className="max-w-7xl mx-auto px-4 md:px-8 pt-28 md:pt-32 pb-16 md:pb-20 flex flex-col items-center text-center">
        <div className="inline-flex items-center gap-2 bg-primary-fixed text-on-primary-fixed-variant px-4 py-1.5 rounded-full text-xs font-semibold tracking-wider uppercase mb-8">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
            <path d="M17 8C8 10 5.9 16.17 3.82 21.34l1.89.66.95-2.3c.48.17.98.3 1.34.3C19 20 22 3 22 3c-1 2-8 2.25-13 3.25S2 11.5 2 13.5s1.75 3.75 1.75 3.75C7 8 17 8 17 8z" />
          </svg>
          <span>{t("badge")}</span>
        </div>

        <h1 className="text-4xl sm:text-5xl md:text-6xl font-extrabold tracking-tight leading-tight mb-6 max-w-4xl text-on-surface">
          {t("titleLine1")} {t("titleLine2")}{" "}
          <span
            className="bg-clip-text text-transparent"
            style={{
              backgroundImage:
                "linear-gradient(135deg, #006b2c 0%, #00873a 100%)",
            }}
          >
            {t("titleHighlight")}
          </span>
        </h1>

        <p className="text-base md:text-lg text-on-surface-variant leading-relaxed max-w-2xl mb-10">
          {t("subtitle")}
        </p>

        <div className="flex flex-col sm:flex-row gap-4">
          <a
            href="#campaigns"
            className="regen-gradient text-white px-8 py-3 rounded-full text-xs font-semibold tracking-widest uppercase shadow-lg shadow-primary/20 hover:opacity-90 transition"
          >
            {t("ctaExplore")}
          </a>
          <Link
            href="/create"
            className="bg-transparent border border-outline-variant text-primary px-8 py-3 rounded-full text-xs font-semibold tracking-widest uppercase hover:bg-surface-container-low transition"
          >
            {t("ctaCreate")}
          </Link>
        </div>

        {!factoryDeployed && (
          <div className="mt-8 text-xs text-on-surface-variant bg-surface-container-low rounded-full px-4 py-2 border border-outline-variant/30">
            ⚠ {t("demoNotice")}
          </div>
        )}
      </section>

      <section className="max-w-5xl mx-auto px-4 md:px-8 mb-16 md:mb-20">
        <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-6 md:p-8 grid grid-cols-2 md:grid-cols-4 gap-6 md:gap-8 text-center relative overflow-hidden">
          <div className="absolute inset-0 bg-primary-fixed/5 pointer-events-none" />
          {[
            {
              value: String(stats?.campaignCount ?? onChainCampaigns?.length ?? 0),
              label: t("stats.campaigns"),
              color: "text-on-surface",
            },
            {
              value: `$${Math.round(totalRaisedUsd).toLocaleString()}`,
              label: t("stats.raised"),
              color: "text-on-surface",
            },
            {
              value: String(stats?.userCount ?? 0),
              label: t("stats.investors"),
              color: "text-on-surface",
            },
            {
              value: campaigns.length
                ? `${(
                    campaigns.reduce((a, c) => a + c.yieldRate, 0) /
                    campaigns.length
                  ).toFixed(1)}x`
                : "—",
              label: t("stats.avgYield"),
              color: "text-primary",
            },
          ].map((stat) => (
            <div key={stat.label} className="flex flex-col relative z-10">
              <span className={`text-2xl md:text-3xl font-bold mb-1 ${stat.color}`}>
                {stat.value}
              </span>
              <span className="text-[11px] md:text-xs font-semibold tracking-wider uppercase text-on-surface-variant leading-tight">
                {stat.label}
              </span>
            </div>
          ))}
        </div>
      </section>

      <section id="campaigns" className="max-w-7xl mx-auto px-4 md:px-8 pb-20 md:pb-24">
        <div className="flex flex-col md:flex-row justify-between md:items-end mb-8 md:mb-12 gap-4">
          <div>
            <h2 className="text-2xl md:text-3xl font-bold tracking-tight text-on-surface mb-2">
              {t("featured.title")}
            </h2>
            <p className="text-sm md:text-base text-on-surface-variant">
              {t("featured.subtitle")}
            </p>
          </div>

          <div className="flex gap-1 bg-surface-container-low p-1 rounded-full -mx-4 md:mx-0 px-4 md:px-1 overflow-x-auto no-scrollbar self-start md:self-auto">
            {FILTER_KEYS.map((key) => (
              <button
                key={key}
                onClick={() => setFilter(key)}
                className={`px-4 h-11 inline-flex items-center rounded-full text-xs font-semibold tracking-wider uppercase transition-all whitespace-nowrap ${
                  filter === key
                    ? "bg-surface-container-lowest text-on-surface shadow-sm"
                    : "text-on-surface-variant hover:text-on-surface"
                }`}
              >
                {t(`filters.${key}`)}
              </button>
            ))}
          </div>
        </div>

        {isLoading ? (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
            {Array.from({ length: 6 }).map((_, i) => (
              <CampaignCardSkeleton key={i} />
            ))}
          </div>
        ) : filteredCampaigns.length === 0 ? (
          <div className="bg-surface-container-lowest rounded-2xl border border-dashed border-outline-variant/40 py-16 px-8 text-center">
            <div className="text-4xl mb-4">🌱</div>
            <h3 className="text-lg font-semibold text-on-surface mb-2">
              {t("emptyTitle")}
            </h3>
            <p className="text-sm text-on-surface-variant mb-6 max-w-md mx-auto">
              {t("emptyBody")}
            </p>
            <Link
              href="/create"
              className="inline-block regen-gradient text-white px-6 py-3 rounded-full text-xs font-semibold tracking-widest uppercase shadow-lg shadow-primary/20 hover:opacity-90 transition"
            >
              {t("ctaCreate")}
            </Link>
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
            {filteredCampaigns.map((campaign) => (
              <CampaignCard key={campaign.address} {...campaign} />
            ))}
          </div>
        )}
      </section>
    </>
  );
}
