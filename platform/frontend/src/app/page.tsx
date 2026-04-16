"use client";

import { useState } from "react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { CampaignCard, type CampaignState } from "@/components/CampaignCard";
import { useCampaignsList } from "@/contracts/hooks";
import { getAddresses } from "@/contracts";

type FilterKey = "all" | "funding" | "active" | "ended";

const MOCK_CAMPAIGNS: Array<{
  address: string;
  name: string;
  producer: string;
  location: string;
  image: string;
  state: CampaignState;
  progress: number;
  yieldRate: number;
  deadline?: string;
  stakers?: number;
}> = [
  {
    address: "0x1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a01",
    name: "Ferrara Olive Grove",
    producer: "Ferrara Family Farm",
    location: "Sicily",
    image:
      "https://images.unsplash.com/photo-1445264755075-ed80e91f9404?w=800&q=80",
    state: "funding",
    progress: 67,
    yieldRate: 3.8,
    deadline: "23",
  },
  {
    address: "0x2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b12",
    name: "Catania Citrus Orchard",
    producer: "Catania Citrus Co",
    location: "Sicily",
    image:
      "https://images.unsplash.com/photo-1557800636-894a64c1696f?w=800&q=80",
    state: "active",
    progress: 100,
    yieldRate: 2.4,
    stakers: 847,
  },
  {
    address: "0x3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c23",
    name: "Etna Vineyard",
    producer: "Etna Vineyards",
    location: "Sicily",
    image:
      "https://images.unsplash.com/photo-1566903451935-7e8833aefabe?w=800&q=80",
    state: "funding",
    progress: 34,
    yieldRate: 4.6,
    deadline: "45",
  },
  {
    address: "0x4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d34",
    name: "Agrigento Almond Grove",
    producer: "Agrigento Almonds",
    location: "Sicily",
    image:
      "https://images.unsplash.com/photo-1615485290382-441e4d049cb5?w=800&q=80",
    state: "active",
    progress: 100,
    yieldRate: 1.8,
    stakers: 412,
  },
  {
    address: "0x5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e45",
    name: "Bronte Hazelnut Farm",
    producer: "Bronte Hazelnuts",
    location: "Sicily",
    image:
      "https://images.unsplash.com/photo-1606923829579-0cb981a83e2e?w=800&q=80",
    state: "funding",
    progress: 82,
    yieldRate: 2.9,
    deadline: "8",
  },
  {
    address: "0x6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f56",
    name: "Nebrodi Chestnut Grove",
    producer: "Nebrodi Chestnuts",
    location: "Sicily",
    image:
      "https://images.unsplash.com/photo-1444392061186-9fc38f84f726?w=800&q=80",
    state: "ended",
    progress: 100,
    yieldRate: 0,
  },
];

const FILTER_KEYS: FilterKey[] = ["all", "funding", "active", "ended"];

export default function Home() {
  const t = useTranslations("home");
  const [filter, setFilter] = useState<FilterKey>("all");
  const { factory } = getAddresses();
  const factoryDeployed =
    factory !== "0x0000000000000000000000000000000000000000";

  const { data: onChainCampaigns } = useCampaignsList();
  const hasOnChainData =
    factoryDeployed && onChainCampaigns && onChainCampaigns.length > 0;

  const campaigns = hasOnChainData
    ? onChainCampaigns.map((addr) => ({
        address: addr,
        name: `Campaign ${addr.slice(0, 6)}`,
        producer: "On-chain",
        location: "—",
        image:
          "https://images.unsplash.com/photo-1445264755075-ed80e91f9404?w=800&q=80",
        state: "funding" as CampaignState,
        progress: 0,
        yieldRate: 5,
        deadline: "",
      }))
    : MOCK_CAMPAIGNS;

  const filteredCampaigns =
    filter === "all" ? campaigns : campaigns.filter((c) => c.state === filter);

  return (
    <>
      <section className="max-w-7xl mx-auto px-8 pt-32 pb-20 flex flex-col items-center text-center">
        <div className="inline-flex items-center gap-2 bg-primary-fixed text-on-primary-fixed-variant px-4 py-1.5 rounded-full text-xs font-semibold tracking-wider uppercase mb-8">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
            <path d="M17 8C8 10 5.9 16.17 3.82 21.34l1.89.66.95-2.3c.48.17.98.3 1.34.3C19 20 22 3 22 3c-1 2-8 2.25-13 3.25S2 11.5 2 13.5s1.75 3.75 1.75 3.75C7 8 17 8 17 8z" />
          </svg>
          <span>{t("badge")}</span>
        </div>

        <h1 className="text-5xl md:text-6xl font-extrabold tracking-tight leading-tight mb-6 max-w-4xl text-on-surface">
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

      <section className="max-w-5xl mx-auto px-8 mb-20">
        <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-8 grid grid-cols-2 md:grid-cols-4 gap-8 text-center relative overflow-hidden">
          <div className="absolute inset-0 bg-primary-fixed/5 pointer-events-none" />
          {[
            {
              value: String(hasOnChainData ? onChainCampaigns.length : 12),
              label: t("stats.campaigns"),
              color: "text-on-surface",
            },
            { value: "€284,500", label: t("stats.raised"), color: "text-on-surface" },
            { value: "1,847", label: t("stats.investors"), color: "text-on-surface" },
            { value: "4.2x", label: t("stats.avgYield"), color: "text-primary" },
          ].map((stat) => (
            <div key={stat.label} className="flex flex-col relative z-10">
              <span className={`text-3xl font-bold mb-1 ${stat.color}`}>
                {stat.value}
              </span>
              <span className="text-xs font-semibold tracking-wider uppercase text-on-surface-variant">
                {stat.label}
              </span>
            </div>
          ))}
        </div>
      </section>

      <section id="campaigns" className="max-w-7xl mx-auto px-8 pb-24">
        <div className="flex flex-col md:flex-row justify-between items-end mb-12">
          <div>
            <h2 className="text-3xl font-bold tracking-tight text-on-surface mb-2">
              {t("featured.title")}
            </h2>
            <p className="text-base text-on-surface-variant">
              {t("featured.subtitle")}
            </p>
          </div>

          <div className="flex gap-2 mt-6 md:mt-0 bg-surface-container-low p-1 rounded-full">
            {FILTER_KEYS.map((key) => (
              <button
                key={key}
                onClick={() => setFilter(key)}
                className={`px-4 py-2 rounded-full text-xs font-semibold tracking-wider uppercase transition-all ${
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

        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
          {filteredCampaigns.map((campaign) => (
            <CampaignCard key={campaign.address} {...campaign} />
          ))}
        </div>

        {filteredCampaigns.length === 0 && (
          <div className="text-center py-16 text-on-surface-variant">
            {t("empty")}
          </div>
        )}
      </section>
    </>
  );
}
