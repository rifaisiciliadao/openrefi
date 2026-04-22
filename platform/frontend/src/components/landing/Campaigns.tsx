"use client";

import { useMemo } from "react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { formatUnits } from "viem";
import { useInView } from "@/lib/landing/useInView";
import { useSubgraphCampaigns, type SubgraphCampaign } from "@/lib/subgraph";
import { useCampaignMetadata } from "@/lib/metadata";

type CampaignState = "funding" | "active" | "ended";

function StateBadge({
  state,
  label,
}: {
  state: CampaignState;
  label: string;
}) {
  const style =
    state === "funding"
      ? {
          bg: "rgba(255,255,255,0.96)",
          color: "#005320",
          border: "rgba(0,83,32,0.28)",
        }
      : state === "active"
        ? {
            bg: "rgba(0,0,0,0.82)",
            color: "#ffffff",
            border: "rgba(255,255,255,0.22)",
          }
        : {
            bg: "rgba(255,255,255,0.88)",
            color: "#4a4a4a",
            border: "rgba(0,0,0,0.12)",
          };

  return (
    <span
      className="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-[10px] font-bold tracking-[0.14em] uppercase backdrop-blur-md"
      style={{
        background: style.bg,
        color: style.color,
        borderColor: style.border,
        fontFamily: "var(--font-header)",
      }}
    >
      {state === "active" && (
        <span
          className="animate-subtle-pulse inline-block h-1.5 w-1.5 rounded-full"
          style={{ background: "#7ffc97" }}
        />
      )}
      {state === "funding" && (
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
      )}
      {label}
    </span>
  );
}

function toCampaignState(s: SubgraphCampaign["state"]): CampaignState {
  if (s === "Active") return "active";
  if (s === "Ended") return "ended";
  return "funding";
}

function LiveCampaignCard({
  campaign,
  revealDelay,
  inView,
}: {
  campaign: SubgraphCampaign;
  revealDelay: number;
  inView: boolean;
}) {
  const t = useTranslations("landing.campaigns");
  const { data: meta } = useCampaignMetadata(
    campaign.metadataURI,
    campaign.metadataVersion,
  );

  const state = toCampaignState(campaign.state);
  const progress = (() => {
    const cap = BigInt(campaign.maxCap);
    return cap === 0n
      ? 0
      : Number((BigInt(campaign.currentSupply) * 100n) / cap);
  })();
  const totalRaisedUsd = Number(formatUnits(BigInt(campaign.totalRaised), 18));
  const maxCapUsd =
    Number(formatUnits(BigInt(campaign.maxCap), 18)) *
    Number(formatUnits(BigInt(campaign.pricePerToken), 18));
  const progressLabel = `$${Math.round(totalRaisedUsd).toLocaleString()} / $${Math.round(
    maxCapUsd,
  ).toLocaleString()}`;

  const displayName = meta?.name ?? `Campaign ${campaign.id.slice(0, 8)}…`;
  const product = meta?.productType ?? "";
  const location = meta?.location ?? "";
  const imageUrl = meta?.image ?? undefined;
  const fallbackHueA = "#2d5a36";
  const fallbackHueB = "#84a66b";

  const yieldRate =
    Number(formatUnits(BigInt(campaign.currentYieldRate), 18)).toFixed(1) + "×";

  return (
    <Link
      href={`/campaign/${campaign.id}`}
      className={`reveal reveal-delay-${revealDelay} ${inView ? "in-view" : ""} card-glow group relative flex flex-col overflow-hidden rounded-2xl transition-all duration-500 hover:-translate-y-2 hover:shadow-[0_24px_56px_-12px_rgba(0,0,0,0.22)]`}
      style={{
        border: "1px solid rgba(255,255,255,0.7)",
        background: "rgba(255,255,255,0.85)",
        backdropFilter: "blur(14px) saturate(1.1)",
        WebkitBackdropFilter: "blur(14px) saturate(1.1)",
        boxShadow:
          "0 1px 0 0 rgba(255,255,255,0.8) inset, 0 8px 24px -10px rgba(0,0,0,0.1)",
      }}
    >
      <div
        className="relative h-56 overflow-hidden"
        style={{
          background: imageUrl
            ? "#4052d4"
            : `linear-gradient(135deg, ${fallbackHueA} 0%, ${fallbackHueB} 100%)`,
        }}
      >
        {imageUrl ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={imageUrl}
            alt={displayName}
            className="h-full w-full object-cover transition-transform duration-[1200ms] ease-out group-hover:scale-[1.08]"
            fetchPriority="high"
            decoding="async"
          />
        ) : (
          <div
            className="absolute inset-0 animate-slow-pan"
            style={{
              backgroundImage:
                "radial-gradient(circle at 30% 20%, rgba(255,255,255,0.25) 0%, transparent 50%), radial-gradient(circle at 80% 80%, rgba(0,0,0,0.25) 0%, transparent 60%)",
              mixBlendMode: "overlay",
            }}
          />
        )}

        {imageUrl && (
          <div
            className="pointer-events-none absolute inset-0"
            style={{
              background:
                "linear-gradient(180deg, rgba(0,0,0,0.32) 0%, rgba(0,0,0,0) 38%, rgba(0,0,0,0) 62%, rgba(0,0,0,0.6) 100%)",
            }}
          />
        )}

        <div className="absolute left-4 top-4">
          <StateBadge state={state} label={t(`stateLabel.${state}`)} />
        </div>
        <div className="absolute bottom-4 right-4 text-right">
          <span
            className="font-display text-[10px] tracking-[0.15em] uppercase"
            style={{ color: "rgba(255,255,255,0.94)" }}
          >
            {t("expectedYield")}
          </span>
          <div
            className="font-display text-4xl leading-none"
            style={{ color: "#ffffff" }}
          >
            {yieldRate}
          </div>
        </div>
      </div>

      <div className="flex flex-1 flex-col p-6">
        <h3
          className="font-display text-2xl leading-tight"
          style={{ color: "#000000" }}
        >
          {displayName}
        </h3>
        {(product || location) && (
          <div
            className="mt-1 flex items-center gap-2 text-sm"
            style={{ color: "#4a4a4a" }}
          >
            {product && <span>{product}</span>}
            {product && location && <span>·</span>}
            {location && <span>{location}</span>}
          </div>
        )}

        <div
          className="mt-6 flex items-center justify-between text-xs font-bold tracking-wider uppercase"
          style={{
            color: "#4a4a4a",
            fontFamily: "var(--font-header)",
          }}
        >
          <span>{t("progress")}</span>
          <span style={{ color: "#000000" }}>{progress}%</span>
        </div>
        <div
          className="mt-2 h-[3px] w-full overflow-hidden rounded-full"
          style={{ background: "#f0f0f0" }}
        >
          <div
            className="h-full rounded-full transition-all duration-700 group-hover:brightness-110"
            style={{
              width: `${progress}%`,
              background:
                state === "ended"
                  ? "#b5b5b5"
                  : "linear-gradient(90deg, #006b2c 0%, #00873a 100%)",
            }}
          />
        </div>
        <div
          className="mt-2 text-xs"
          style={{
            color: "#4a4a4a",
            fontFamily: "var(--font-header)",
            fontWeight: 700,
          }}
        >
          {progressLabel}
        </div>

        <div
          className="mt-6 flex items-center justify-between border-t pt-4 text-xs"
          style={{ borderColor: "#eaeaea", color: "#4a4a4a" }}
        >
          <span
            className="truncate max-w-[55%]"
            style={{ fontFamily: "var(--font-header)", fontWeight: 700 }}
          >
            {campaign.producer.slice(0, 6)}…{campaign.producer.slice(-4)}
          </span>
          <span
            className="inline-flex items-center gap-1 transition-transform duration-300 group-hover:translate-x-1"
            style={{
              color: "#000000",
              fontFamily: "var(--font-header)",
              fontWeight: 700,
            }}
          >
            {state === "funding" ? t("ctaFund") : t("ctaView")}
            <svg
              width="12"
              height="12"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <path d="M5 12h14M13 5l7 7-7 7" />
            </svg>
          </span>
        </div>
      </div>
    </Link>
  );
}

function CreateCampaignCard({
  revealDelay,
  inView,
}: {
  revealDelay: number;
  inView: boolean;
}) {
  const t = useTranslations("landing.campaigns");

  return (
    <Link
      href="/create"
      className={`reveal reveal-delay-${revealDelay} ${inView ? "in-view" : ""} group relative flex min-h-[460px] flex-col items-center justify-center overflow-hidden rounded-2xl p-8 text-center transition-all duration-500 hover:-translate-y-2`}
      style={{
        border: "1.5px dashed rgba(0,107,44,0.35)",
        background:
          "linear-gradient(135deg, rgba(0,107,44,0.05) 0%, rgba(127,252,151,0.12) 100%)",
        backdropFilter: "blur(14px) saturate(1.1)",
        WebkitBackdropFilter: "blur(14px) saturate(1.1)",
      }}
    >
      <span
        className="pointer-events-none absolute inset-0 rounded-2xl opacity-0 transition-opacity duration-500 group-hover:opacity-100"
        style={{
          background:
            "radial-gradient(circle at 50% 50%, rgba(0,135,58,0.12) 0%, transparent 70%)",
        }}
      />
      <div
        className="flex h-16 w-16 items-center justify-center rounded-full transition-transform duration-500 group-hover:scale-110"
        style={{
          background: "linear-gradient(135deg, #006b2c 0%, #00873a 100%)",
          boxShadow: "0 8px 24px -8px rgba(0,135,58,0.5)",
        }}
      >
        <svg
          width="28"
          height="28"
          viewBox="0 0 24 24"
          fill="none"
          stroke="#ffffff"
          strokeWidth="2.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M12 5v14M5 12h14" />
        </svg>
      </div>
      <h3
        className="font-display mt-6 text-2xl leading-tight"
        style={{ color: "#000000" }}
      >
        {t("createTitle")}
      </h3>
      <p
        className="mt-3 max-w-xs text-sm leading-relaxed"
        style={{ color: "#1a1a1a" }}
      >
        {t("createBody")}
      </p>
      <span
        className="mt-8 inline-flex items-center gap-2 rounded-full bg-black px-6 py-3 text-sm font-bold text-white transition-all duration-300 group-hover:scale-[1.04] group-hover:shadow-[0_12px_28px_-8px_rgba(0,0,0,0.4)]"
        style={{ fontFamily: "var(--font-header)" }}
      >
        {t("createCta")}
        <svg
          width="14"
          height="14"
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
    </Link>
  );
}

export function Campaigns() {
  const t = useTranslations("landing.campaigns");
  const { ref, inView } = useInView<HTMLDivElement>();
  const { data: onChainCampaigns } = useSubgraphCampaigns();

  const live = useMemo(
    () => onChainCampaigns ?? [],
    [onChainCampaigns],
  );

  return (
    <section
      id="campaigns"
      className="glass-section relative w-full py-32 md:py-40"
      style={{
        borderTop: "1px solid rgba(255,255,255,0.5)",
        boxShadow: "inset 0 1px 0 rgba(255,255,255,0.6)",
      }}
    >
      <div ref={ref} className="mx-auto max-w-7xl px-6 md:px-8">
        <div className="mb-16 flex flex-col items-start justify-between gap-6 md:mb-20 md:flex-row md:items-end">
          <div className="max-w-2xl">
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

          <div
            className={`reveal reveal-delay-3 ${inView ? "in-view" : ""} flex shrink-0 gap-1 rounded-full border p-1`}
            style={{ borderColor: "#eaeaea", background: "#fafafa" }}
          >
            {(["all", "funding", "active", "closed"] as const).map((k, i) => (
              <button
                key={k}
                className="rounded-full px-4 py-2 text-xs tracking-wider uppercase transition-colors"
                style={{
                  background: i === 0 ? "#ffffff" : "transparent",
                  color: i === 0 ? "#000000" : "#4a4a4a",
                  boxShadow: i === 0 ? "0 1px 2px rgba(0,0,0,0.04)" : "none",
                  fontFamily: "var(--font-header)",
                  fontWeight: 700,
                }}
              >
                {t(`filters.${k}`)}
              </button>
            ))}
          </div>
        </div>

        <div className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {live.map((c, i) => (
            <LiveCampaignCard
              key={c.id}
              campaign={c}
              revealDelay={Math.min(i + 1, 6)}
              inView={inView}
            />
          ))}
          <CreateCampaignCard
            revealDelay={Math.min(live.length + 1, 6)}
            inView={inView}
          />
        </div>
      </div>
    </section>
  );
}
