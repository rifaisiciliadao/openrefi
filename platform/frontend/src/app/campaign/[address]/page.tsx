"use client";

import { useState, use } from "react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import type { Address } from "viem";
import { parseUnits } from "viem";
import { useCampaignData } from "@/contracts/hooks";
import { BuyPanel } from "@/components/BuyPanel";

type Tab = "invest" | "stake" | "harvest" | "info";
const TAB_KEYS: Tab[] = ["invest", "stake", "harvest", "info"];

const STATES = ["funding", "active", "buyback", "ended"] as const;

export default function CampaignDetail({
  params,
}: {
  params: Promise<{ address: string }>;
}) {
  const { address } = use(params);
  const t = useTranslations("detail");
  const [activeTab, setActiveTab] = useState<Tab>("invest");

  const campaignAddress = address as Address;
  const isValidAddress = /^0x[a-fA-F0-9]{40}$/.test(campaignAddress);

  // Read campaign state on-chain
  const { data: campaignData } = useCampaignData(
    isValidAddress ? campaignAddress : undefined,
  );

  // campaignData order: producer, pricePerToken, minCap, maxCap, currentSupply,
  // fundingDeadline, state, campaignToken, stakingVault, harvestManager
  const pricePerToken = (campaignData?.[1]?.result as bigint) ?? parseUnits("0.144", 18);
  const stateIdx = (campaignData?.[6]?.result as number) ?? 0;
  const hasOnChainData = !!campaignData?.[0]?.result;

  return (
    <>
      <section
        className="relative w-full h-72 flex items-end px-8 lg:px-16 pb-12 bg-cover bg-center overflow-hidden"
        style={{
          backgroundImage:
            "url('https://images.unsplash.com/photo-1445264755075-ed80e91f9404?w=1600&q=80')",
        }}
      >
        <div className="absolute inset-0 bg-gradient-to-t from-black/80 via-black/40 to-transparent" />
        <div className="relative z-10 w-full max-w-7xl mx-auto flex flex-col gap-4">
          <nav className="flex text-white/70 text-xs font-semibold uppercase tracking-wider">
            <Link href="/">{t("breadcrumb")}</Link>
            <span className="mx-2">/</span>
            <span className="text-white">Ferrara Olive Grove</span>
          </nav>
          <div className="flex items-center justify-between flex-wrap gap-4">
            <div>
              <h1 className="text-5xl md:text-6xl font-extrabold tracking-tight text-white leading-tight">
                Ferrara Olive Grove
              </h1>
              <p className="text-white/90 mt-2">
                Ferrara Family Farm · Sicily
              </p>
            </div>
            <span className="inline-flex items-center px-4 py-2 rounded-full bg-primary-fixed text-on-primary-fixed-variant text-xs font-semibold uppercase tracking-wider backdrop-blur-md">
              Funding
            </span>
          </div>
        </div>
      </section>

      <div className="sticky top-16 z-40 bg-surface/90 backdrop-blur-md border-b border-outline-variant/15">
        <div className="max-w-7xl mx-auto px-8 lg:px-16 flex gap-8">
          {TAB_KEYS.map((key) => (
            <button
              key={key}
              onClick={() => setActiveTab(key)}
              className={`py-4 text-base font-semibold transition-colors border-b-2 ${
                activeTab === key
                  ? "text-primary border-primary"
                  : "text-on-surface-variant border-transparent hover:text-on-surface"
              }`}
            >
              {t(`tabs.${key}`)}
            </button>
          ))}
        </div>
      </div>

      <div className="max-w-7xl mx-auto px-8 lg:px-16 py-12 flex flex-col lg:flex-row gap-12 items-start">
        <div className="w-full lg:w-[65%] flex flex-col gap-6">
          {activeTab === "invest" && (
            <>
              <FundingProgressCard
                currentSupply={(campaignData?.[4]?.result as bigint) ?? 0n}
                maxCap={(campaignData?.[3]?.result as bigint) ?? 0n}
                minCap={(campaignData?.[2]?.result as bigint) ?? 0n}
                pricePerToken={pricePerToken}
                fundingDeadline={
                  (campaignData?.[5]?.result as bigint) ?? 0n
                }
                hasOnChainData={hasOnChainData}
              />

              {hasOnChainData ? (
                <BuyPanel
                  campaignAddress={campaignAddress}
                  pricePerToken={pricePerToken}
                  currentState={stateIdx}
                />
              ) : (
                <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15 text-center text-sm text-on-surface-variant">
                  {t("buy.demoNotice")}
                </div>
              )}
            </>
          )}

          {activeTab === "stake" && <StakingPanel />}
          {activeTab === "harvest" && <HarvestPanel />}
          {activeTab === "info" && <InfoPanel address={address} />}
        </div>

        <div className="w-full lg:w-[35%] sticky top-36 flex flex-col gap-4">
          <StatsCard />
          <TokensAcceptedCard />
          <ProducerCard />
        </div>
      </div>
    </>
  );
}

function FundingProgressCard({
  currentSupply,
  maxCap,
  minCap,
  pricePerToken,
  fundingDeadline,
  hasOnChainData,
}: {
  currentSupply: bigint;
  maxCap: bigint;
  minCap: bigint;
  pricePerToken: bigint;
  fundingDeadline: bigint;
  hasOnChainData: boolean;
}) {
  const t = useTranslations("detail.funding");

  // Mock fallback values
  const DEMO = { raised: 190_800, target: 284_400, pct: 67, daysLeft: 23 };

  let raisedNum = DEMO.raised;
  let targetNum = DEMO.target;
  let pct = DEMO.pct;
  let daysLeft = DEMO.daysLeft;

  if (hasOnChainData && maxCap > 0n) {
    // tokens × pricePerToken / 1e18 = USD (both 18 dec)
    const raisedUsd =
      (currentSupply * pricePerToken) / 10n ** 18n / 10n ** 18n;
    const targetUsd = (maxCap * pricePerToken) / 10n ** 18n / 10n ** 18n;
    raisedNum = Number(raisedUsd);
    targetNum = Number(targetUsd);
    pct = maxCap > 0n ? Number((currentSupply * 100n) / maxCap) : 0;
    const now = Math.floor(Date.now() / 1000);
    const delta = Number(fundingDeadline) - now;
    daysLeft = delta > 0 ? Math.ceil(delta / 86400) : 0;
  }

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <h2 className="text-base font-semibold text-on-surface mb-6">
        {t("title")}
      </h2>
      <div className="flex justify-between items-end mb-4">
        <div>
          <span className="text-3xl font-bold tracking-tight text-on-surface">
            €{raisedNum.toLocaleString()}
          </span>
          <span className="text-base text-on-surface-variant ml-2">
            {t("raised")}
          </span>
        </div>
        <div className="text-right">
          <span className="text-sm text-on-surface-variant">
            {t("target", { amount: `€${targetNum.toLocaleString()}` })}
          </span>
        </div>
      </div>
      <div className="w-full h-2 bg-surface-container-high rounded-full overflow-hidden">
        <div
          className="h-full bg-primary rounded-full transition-all duration-700"
          style={{ width: `${Math.min(pct, 100)}%` }}
        />
      </div>
      <div className="mt-4 flex justify-between items-center">
        <span className="text-xs font-semibold uppercase tracking-wider text-primary">
          {t("completed", { pct })}
        </span>
        <span className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
          {t("daysLeft", { days: daysLeft })}
        </span>
      </div>
    </div>
  );
}

function StakingPanel() {
  const t = useTranslations("detail.stake");
  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <h2 className="text-2xl font-bold tracking-tight text-on-surface mb-2">
        {t("title")}
      </h2>
      <p className="text-sm text-on-surface-variant mb-6">{t("subtitle")}</p>

      <div className="space-y-4">
        <div className="bg-surface-container-low rounded-xl p-5 border border-outline-variant/15">
          <div className="flex justify-between items-start mb-4">
            <div>
              <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
                {t("position", { id: 1 })}
              </div>
              <div className="text-2xl font-bold text-on-surface">
                5,000 $CAMP
              </div>
            </div>
            <div className="text-right">
              <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
                {t("yieldAccrued")}
              </div>
              <div className="text-2xl font-bold text-primary">
                142.38 $YIELD
              </div>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4 mb-4 pt-4 border-t border-outline-variant/15">
            <div>
              <div className="text-xs text-on-surface-variant">
                {t("stakeDate")}
              </div>
              <div className="text-sm font-semibold text-on-surface">
                Jan 15, 2026
              </div>
            </div>
            <div>
              <div className="text-xs text-on-surface-variant">
                {t("unstakePenalty")}
              </div>
              <div className="text-sm font-semibold text-error">23%</div>
            </div>
          </div>

          <div className="flex gap-2">
            <button className="flex-1 bg-primary text-white rounded-full py-2.5 text-sm font-semibold hover:opacity-90 transition">
              {t("claim")}
            </button>
            <button className="flex-1 bg-surface-container-high text-on-surface rounded-full py-2.5 text-sm font-semibold hover:bg-surface-container-highest transition">
              {t("restake")}
            </button>
            <button className="flex-1 bg-transparent border border-outline-variant text-on-surface-variant rounded-full py-2.5 text-sm font-semibold hover:bg-surface-container-low transition">
              {t("unstake")}
            </button>
          </div>
        </div>

        <button className="w-full border-2 border-dashed border-outline-variant rounded-xl p-6 text-sm font-semibold text-on-surface-variant hover:border-primary hover:bg-surface-container-low transition">
          {t("newStake")}
        </button>
      </div>
    </div>
  );
}

function HarvestPanel() {
  const t = useTranslations("detail.harvest");
  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <h2 className="text-2xl font-bold tracking-tight text-on-surface mb-2">
        {t("title")}
      </h2>
      <p className="text-sm text-on-surface-variant mb-6">{t("subtitle")}</p>

      <div className="grid grid-cols-2 gap-4 mb-6">
        <button className="bg-primary-fixed/30 border-2 border-primary rounded-xl p-6 text-left hover:shadow-lg transition">
          <div className="text-3xl mb-3">🫒</div>
          <div className="font-semibold text-on-surface mb-1">
            {t("product")}
          </div>
          <div className="text-sm text-on-surface-variant">
            {t("productDesc")}
          </div>
          <div className="mt-3 text-xl font-bold text-primary">50 L</div>
        </button>
        <button className="bg-surface-container-low border-2 border-outline-variant/15 rounded-xl p-6 text-left hover:border-outline-variant transition">
          <div className="text-3xl mb-3">💰</div>
          <div className="font-semibold text-on-surface mb-1">{t("usdc")}</div>
          <div className="text-sm text-on-surface-variant">
            {t("usdcDesc")}
          </div>
          <div className="mt-3 text-xl font-bold text-on-surface">
            €685.30
          </div>
        </button>
      </div>

      <div className="bg-surface-container-low rounded-xl p-5 mb-6 border border-outline-variant/15">
        <div className="flex items-center justify-between text-sm mb-4">
          <span className="font-semibold text-on-surface">
            {t("redemptionStatus")}
          </span>
          <span className="text-primary font-semibold">
            {t("step", { current: 1, total: 2 })}
          </span>
        </div>
        <div className="space-y-3">
          <div className="flex items-center gap-3">
            <div className="w-6 h-6 rounded-full bg-primary flex items-center justify-center">
              <svg
                width="12"
                height="12"
                viewBox="0 0 24 24"
                fill="none"
                stroke="white"
                strokeWidth="3"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  d="M4.5 12.75l6 6 9-13.5"
                />
              </svg>
            </div>
            <span className="text-sm text-on-surface">
              {t("declareIntent")}
            </span>
          </div>
          <div className="flex items-center gap-3">
            <div className="w-6 h-6 rounded-full border-2 border-outline-variant" />
            <span className="text-sm text-on-surface-variant">
              {t("confirmDelivery")}
            </span>
          </div>
        </div>
      </div>

      <button className="w-full regen-gradient text-white rounded-xl h-14 font-bold text-base hover:shadow-xl hover:shadow-primary/20 transition-all">
        {t("confirm")}
      </button>
    </div>
  );
}

function InfoPanel({ address }: { address: string }) {
  const t = useTranslations("detail.info");
  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <h2 className="text-2xl font-bold tracking-tight text-on-surface mb-6">
        {t("title")}
      </h2>
      <div className="space-y-4 text-sm text-on-surface-variant leading-relaxed">
        <p>{t("about")}</p>
        <p>{t("tokens")}</p>

        <div className="grid grid-cols-2 gap-4 pt-4 border-t border-outline-variant/15">
          <div>
            <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
              {t("contract")}
            </div>
            <div className="font-mono text-xs text-on-surface break-all">
              {address}
            </div>
          </div>
          <div>
            <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
              {t("block")}
            </div>
            <div className="text-sm text-on-surface">18,245,632</div>
          </div>
        </div>

        <div className="pt-4">
          <a
            href="#"
            className="inline-flex items-center gap-2 text-primary font-semibold hover:underline"
          >
            {t("dmrv")}
          </a>
        </div>
      </div>
    </div>
  );
}

function StatsCard() {
  const t = useTranslations("detail.sidebar");
  return (
    <div className="bg-surface-container-lowest rounded-2xl p-6 border border-outline-variant/15">
      <h3 className="text-sm font-semibold text-on-surface mb-4">
        {t("stats")}
      </h3>
      <div className="grid grid-cols-2 gap-4 mb-4">
        <Stat label={t("tokenPrice")} value="€0.144" />
        <Stat label={t("maxSupply")} value="2M $CAMP" />
        <Stat label={t("tokensSold")} value="1.32M" />
        <Stat label={t("investors")} value="234" />
      </div>

      <div className="pt-4 border-t border-outline-variant/15">
        <div className="flex justify-between items-end mb-3">
          <span className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("yieldRate")}
          </span>
          <span className="text-2xl font-bold text-primary">3.8x</span>
        </div>

        <div className="relative h-2 bg-surface-container-high rounded-full overflow-hidden mb-2">
          <div
            className="absolute inset-y-0 left-0 regen-gradient rounded-full"
            style={{ width: `${((3.8 - 1) / 4) * 100}%` }}
          />
        </div>
        <div className="flex justify-between text-xs text-on-surface-variant">
          <span>1x</span>
          <span>3x</span>
          <span>5x</span>
        </div>
        <p className="text-xs text-on-surface-variant mt-2">{t("yieldHint")}</p>
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
        {label}
      </div>
      <div className="text-base font-semibold text-on-surface">{value}</div>
    </div>
  );
}

function TokensAcceptedCard() {
  const t = useTranslations("detail.sidebar");
  return (
    <div className="bg-surface-container-lowest rounded-2xl p-6 border border-outline-variant/15">
      <h3 className="text-sm font-semibold text-on-surface mb-4">
        {t("acceptedTokens")}
      </h3>
      <div className="space-y-3">
        <TokenRow symbol="USDC" mode="Fixed" rate="$0.144" />
        <TokenRow symbol="WETH" mode="Oracle" rate="$3,245.00" live />
      </div>
    </div>
  );
}

function TokenRow({
  symbol,
  mode,
  rate,
  live,
}: {
  symbol: string;
  mode: string;
  rate: string;
  live?: boolean;
}) {
  const t = useTranslations("detail.sidebar");
  return (
    <div className="flex items-center justify-between p-3 rounded-xl bg-surface-container-low">
      <div className="flex items-center gap-3">
        <div className="w-8 h-8 rounded-full bg-primary-fixed flex items-center justify-center">
          <span className="text-xs font-bold text-on-primary-fixed-variant">
            {symbol.slice(0, 2)}
          </span>
        </div>
        <div>
          <div className="text-sm font-semibold text-on-surface">{symbol}</div>
          <div className="text-xs text-on-surface-variant">{mode}</div>
        </div>
      </div>
      <div className="text-right">
        <div className="text-sm font-semibold text-on-surface">{rate}</div>
        {live && (
          <div className="text-xs text-primary font-semibold flex items-center gap-1 justify-end">
            <span className="w-1.5 h-1.5 rounded-full bg-primary animate-pulse" />
            {t("live")}
          </div>
        )}
      </div>
    </div>
  );
}

function ProducerCard() {
  const t = useTranslations("detail.sidebar");
  return (
    <div className="bg-surface-container-lowest rounded-2xl p-6 border border-outline-variant/15">
      <h3 className="text-sm font-semibold text-on-surface mb-4">
        {t("producer")}
      </h3>
      <div className="flex items-center gap-4 mb-4">
        <div className="w-12 h-12 rounded-full bg-primary flex items-center justify-center text-white font-bold shrink-0">
          FF
        </div>
        <div>
          <div className="flex items-center gap-1.5">
            <span className="font-semibold text-on-surface">
              Ferrara Family Farm
            </span>
            <svg
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="currentColor"
              className="text-primary"
            >
              <path d="M12 2L4 5v6.09c0 5.05 3.41 9.76 8 10.91 4.59-1.15 8-5.86 8-10.91V5l-8-3zm-2 15l-4-4 1.41-1.41L10 14.17l6.59-6.59L18 9l-8 8z" />
            </svg>
          </div>
          <div className="flex items-center gap-1 mt-0.5">
            <span className="text-sm text-on-surface-variant">Sicily, Italy</span>
          </div>
        </div>
      </div>
      <button className="w-full py-2 flex items-center justify-center gap-2 text-primary text-sm font-semibold hover:bg-surface-container-low rounded-lg transition">
        {t("viewReport")}
      </button>
    </div>
  );
}
