"use client";

import { useState, use } from "react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import {
  useAccount,
  useReadContracts,
  useWriteContract,
} from "wagmi";
import { waitForTransactionReceipt } from "@wagmi/core";
import { useQueryClient } from "@tanstack/react-query";
import type { Address } from "viem";
import { formatUnits } from "viem";
import { useCampaignData } from "@/contracts/hooks";
import { abis, getAddresses } from "@/contracts";
import { config } from "@/app/providers";
import { erc20Abi } from "@/contracts/erc20";
import { useSubgraphCampaign, useSubgraphProducer } from "@/lib/subgraph";
import { useTxNotify } from "@/lib/useTxNotify";
import { useCampaignMetadata, useProducerProfile } from "@/lib/metadata";
import { uploadImage, uploadMetadata } from "@/lib/api";
import { BuyPanel } from "@/components/BuyPanel";
import { StakingPanel } from "@/components/StakingPanel";
import { HarvestPanel } from "@/components/HarvestPanel";
import { ProducerManagePanel } from "@/components/ProducerManagePanel";
import { RefundPanel, TriggerBuybackCta } from "@/components/RefundPanel";
import { SellBackPanel } from "@/components/SellBackPanel";
import { ActivateCtaBanner } from "@/components/ActivateCtaBanner";
import { Spinner } from "@/components/Spinner";

const STATE_LABELS = ["funding", "active", "buyback", "ended"] as const;

type Tab = "invest" | "stake" | "harvest" | "info" | "manage";
const TAB_KEYS: Tab[] = ["invest", "stake", "harvest", "info"];
// Manage tab is appended dynamically when the connected wallet is the producer.

export default function CampaignDetail({
  params,
}: {
  params: Promise<{ address: string }>;
}) {
  const { address } = use(params);
  const t = useTranslations("detail");
  const tHome = useTranslations("home");
  const [activeTab, setActiveTab] = useState<Tab>("invest");

  const campaignAddress = address as Address;
  const isValidAddress = /^0x[a-fA-F0-9]{40}$/.test(campaignAddress);

  // Read campaign state on-chain
  const { data: campaignData } = useCampaignData(
    isValidAddress ? campaignAddress : undefined,
  );

  // campaignData order: producer, pricePerToken, minCap, maxCap, currentSupply,
  // fundingDeadline, state, campaignToken, stakingVault, harvestManager
  type MaybeResult = { result?: unknown };
  const cd = campaignData as readonly MaybeResult[] | undefined;
  const pricePerToken = (cd?.[1]?.result as bigint | undefined) ?? 0n;
  const stateIdx = (cd?.[6]?.result as number | undefined) ?? 0;
  const hasOnChainData = !!cd?.[0]?.result;
  const stateKey = STATE_LABELS[stateIdx] ?? "funding";

  // Off-chain metadata: subgraph → registry URI → fetch JSON.
  const { data: sgCampaign } = useSubgraphCampaign(
    isValidAddress ? campaignAddress : undefined,
  );
  const { data: metadata } = useCampaignMetadata(
    sgCampaign?.metadataURI,
    sgCampaign?.metadataVersion,
  );

  // Producer-only recovery: show the "Link metadata" banner when the
  // CampaignRegistry has no URI for this campaign. Happens when the create
  // flow's setMetadata step was rejected or missed before we made it mandatory.
  const { address: connected } = useAccount();
  const producerAddress = cd?.[0]?.result as Address | undefined;
  const isProducerViewing =
    !!connected &&
    !!producerAddress &&
    connected.toLowerCase() === producerAddress.toLowerCase();
  const metadataMissing =
    !!sgCampaign && (!sgCampaign.metadataURI || sgCampaign.metadataURI === "");

  const displayName =
    metadata?.name ||
    (isValidAddress
      ? `Campaign ${campaignAddress.slice(0, 6)}…${campaignAddress.slice(-4)}`
      : "Campaign");
  const displayLocation = metadata?.location ?? "";
  const heroImage = metadata?.image || null;
  const heroStyle = heroImage
    ? { backgroundImage: `url('${heroImage}')` }
    : {
        backgroundImage:
          "linear-gradient(135deg, #bde4b7 0%, #7bc17a 50%, #2d6a2e 100%)",
      };

  return (
    <>
      <section
        className="relative w-full h-72 flex items-end px-8 lg:px-16 pb-12 bg-cover bg-center overflow-hidden"
        style={heroStyle}
      >
        <div className="absolute inset-0 bg-gradient-to-t from-black/80 via-black/40 to-transparent" />
        <div className="relative z-10 w-full max-w-7xl mx-auto flex flex-col gap-4">
          <nav className="flex text-white/70 text-xs font-semibold uppercase tracking-wider">
            <Link href="/">{t("breadcrumb")}</Link>
            <span className="mx-2">/</span>
            <span className="text-white">{displayName}</span>
          </nav>
          <div className="flex items-center justify-between flex-wrap gap-4">
            <div>
              <h1 className="text-5xl md:text-6xl font-extrabold tracking-tight text-white leading-tight">
                {displayName}
              </h1>
              {displayLocation && (
                <p className="text-white/90 mt-2">{displayLocation}</p>
              )}
            </div>
            <span className="inline-flex items-center px-4 py-2 rounded-full bg-primary-fixed text-on-primary-fixed-variant text-xs font-semibold uppercase tracking-wider backdrop-blur-md">
              {tHome(
                stateKey === "buyback"
                  ? "state.ended"
                  : (`state.${stateKey}` as "state.funding" | "state.active" | "state.ended"),
              )}
            </span>
          </div>
        </div>
      </section>

      <div className="sticky top-16 z-40 bg-surface/90 backdrop-blur-md border-b border-outline-variant/15">
        <div className="max-w-7xl mx-auto px-8 lg:px-16 flex gap-8">
          {[
            ...TAB_KEYS,
            ...(isProducerViewing ? (["manage"] as Tab[]) : []),
          ].map((key) => (
            <button
              key={key}
              onClick={() => setActiveTab(key)}
              className={`py-4 text-base font-semibold transition-colors border-b-2 ${
                activeTab === key
                  ? "text-primary border-primary"
                  : "text-on-surface-variant border-transparent hover:text-on-surface"
              } ${key === "manage" ? "text-primary" : ""}`}
            >
              {t(`tabs.${key}`)}
            </button>
          ))}
        </div>
      </div>

      {isProducerViewing && hasOnChainData && (
        <div className="max-w-7xl mx-auto px-8 lg:px-16 pt-6">
          <ActivateCtaBanner
            campaignAddress={campaignAddress}
            currentState={stateIdx}
            currentSupply={(cd?.[4]?.result as bigint | undefined) ?? 0n}
            minCap={(cd?.[2]?.result as bigint | undefined) ?? 0n}
            isProducerViewing={isProducerViewing}
          />
        </div>
      )}

      {isProducerViewing && metadataMissing && (
        <div className="max-w-7xl mx-auto px-8 lg:px-16 pt-6">
          <LinkMetadataBanner
            campaignAddress={campaignAddress}
            currentName={displayName}
          />
        </div>
      )}

      <div className="max-w-7xl mx-auto px-8 lg:px-16 py-12 flex flex-col lg:flex-row gap-12 items-start">
        <div className="w-full lg:w-[65%] flex flex-col gap-6">
          {activeTab === "invest" && (
            <>
              <FundingProgressCard
                currentSupply={(cd?.[4]?.result as bigint | undefined) ?? 0n}
                maxCap={(cd?.[3]?.result as bigint | undefined) ?? 0n}
                minCap={(cd?.[2]?.result as bigint | undefined) ?? 0n}
                pricePerToken={pricePerToken}
                fundingDeadline={
                  (cd?.[5]?.result as bigint | undefined) ?? 0n
                }
                hasOnChainData={hasOnChainData}
              />

              {hasOnChainData && (
                <TriggerBuybackCta
                  campaignAddress={campaignAddress}
                  currentState={stateIdx}
                  currentSupply={
                    (cd?.[4]?.result as bigint | undefined) ?? 0n
                  }
                  minCap={(cd?.[2]?.result as bigint | undefined) ?? 0n}
                  fundingDeadline={
                    (cd?.[5]?.result as bigint | undefined) ?? 0n
                  }
                />
              )}

              {!hasOnChainData ? (
                <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15 text-center text-sm text-on-surface-variant">
                  {t("buy.demoNotice")}
                </div>
              ) : stateIdx === 2 ? (
                <RefundPanel
                  campaignAddress={campaignAddress}
                  campaignToken={
                    (cd?.[7]?.result as Address | undefined) ??
                    "0x0000000000000000000000000000000000000000"
                  }
                  currentState={stateIdx}
                />
              ) : (
                <>
                  <BuyPanel
                    campaignAddress={campaignAddress}
                    campaignToken={
                      (cd?.[7]?.result as Address | undefined) ??
                      "0x0000000000000000000000000000000000000000"
                    }
                    pricePerToken={pricePerToken}
                    currentSupply={
                      (cd?.[4]?.result as bigint | undefined) ?? 0n
                    }
                    maxCap={(cd?.[3]?.result as bigint | undefined) ?? 0n}
                    currentState={stateIdx}
                  />
                  <SellBackPanel
                    campaignAddress={campaignAddress}
                    campaignToken={
                      (cd?.[7]?.result as Address | undefined) ??
                      "0x0000000000000000000000000000000000000000"
                    }
                    currentState={stateIdx}
                  />
                </>
              )}
            </>
          )}

          {activeTab === "stake" && hasOnChainData && sgCampaign && (
            <StakingPanel
              campaignToken={sgCampaign.campaignToken as Address}
              stakingVault={sgCampaign.stakingVault as Address}
              yieldToken={sgCampaign.yieldToken as Address}
              seasonDuration={BigInt(sgCampaign.seasonDuration)}
            />
          )}
          {activeTab === "harvest" && hasOnChainData && sgCampaign && (
            <HarvestPanel
              campaignAddress={campaignAddress}
              harvestManager={sgCampaign.harvestManager as Address}
              yieldToken={sgCampaign.yieldToken as Address}
            />
          )}
          {activeTab === "info" && (
            <InfoPanel
              address={address}
              description={metadata?.description}
              location={displayLocation}
              createdAtBlock={sgCampaign?.createdAtBlock}
            />
          )}
          {activeTab === "manage" &&
            isProducerViewing &&
            hasOnChainData &&
            sgCampaign && (
              <ProducerManagePanel
                campaignAddress={campaignAddress}
                harvestManager={sgCampaign.harvestManager as Address}
                stakingVault={sgCampaign.stakingVault as Address}
                currentState={stateIdx}
                minProductClaim={BigInt(sgCampaign.minProductClaim)}
                seasonDuration={BigInt(sgCampaign.seasonDuration)}
              />
            )}
        </div>

        <div className="w-full lg:w-[35%] sticky top-36 flex flex-col gap-4">
          <StatsCard
            pricePerToken={pricePerToken}
            maxCap={(cd?.[3]?.result as bigint | undefined) ?? 0n}
            currentSupply={(cd?.[4]?.result as bigint | undefined) ?? 0n}
            currentYieldRate={
              sgCampaign ? BigInt(sgCampaign.currentYieldRate) : 0n
            }
          />
          <TokensAcceptedCard
            campaignAddress={isValidAddress ? campaignAddress : undefined}
          />
          <ProducerCard
            producer={(sgCampaign?.producer as Address) ?? undefined}
          />
        </div>
      </div>
    </>
  );
}

/**
 * Recovery UI: producer forgot to (or failed to) sign `setMetadata` during
 * the create flow, so the CampaignRegistry has no URI → card + hero show
 * the raw address. Here the producer re-uploads the image + metadata JSON
 * and signs setMetadata; on confirmation we invalidate the subgraph query
 * so the page re-renders with the new name/image.
 */
function LinkMetadataBanner({
  campaignAddress,
  currentName,
}: {
  campaignAddress: Address;
  currentName: string;
}) {
  const t = useTranslations("detail.linkMetadata");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { registry } = getAddresses();
  const queryClient = useQueryClient();
  const { writeContractAsync } = useWriteContract();

  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [location, setLocation] = useState("");
  const [imageFile, setImageFile] = useState<File | null>(null);
  const [imagePreview, setImagePreview] = useState<string | null>(null);
  const [stage, setStage] = useState<
    | { kind: "idle" }
    | { kind: "uploading" }
    | { kind: "signing" }
    | { kind: "confirming" }
    | { kind: "indexing" }
    | { kind: "error"; message: string }
  >({ kind: "idle" });

  const handleImage = (file: File) => {
    setImageFile(file);
    setImagePreview(URL.createObjectURL(file));
  };

  const handleSubmit = async () => {
    if (!name.trim()) {
      setStage({ kind: "error", message: t("nameRequired") });
      return;
    }
    try {
      setStage({ kind: "uploading" });
      let imageUrl: string | undefined;
      if (imageFile) {
        const up = await uploadImage(imageFile);
        imageUrl = up.url;
      }
      const meta = await uploadMetadata({
        name: name.trim(),
        description: description.trim(),
        location: location.trim(),
        productType: "",
        imageUrl,
      });

      setStage({ kind: "signing" });
      const hash = await writeContractAsync({
        address: registry,
        abi: abis.CampaignRegistry as never,
        functionName: "setMetadata",
        args: [campaignAddress, meta.url],
      });
      setStage({ kind: "confirming" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("setMetadata reverted");
      notify.success(tx("setMetadataConfirmed"), hash);

      // Poll subgraph until it picks up the new metadataURI, then close.
      setStage({ kind: "indexing" });
      const start = Date.now();
      while (Date.now() - start < 60_000) {
        await queryClient.invalidateQueries({
          queryKey: ["subgraph", "campaign", campaignAddress.toLowerCase()],
        });
        await new Promise((r) => setTimeout(r, 3_000));
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (/user (rejected|denied)/i.test(msg)) {
        setStage({ kind: "idle" });
      } else {
        setStage({ kind: "error", message: msg });
        notify.error(tx("setMetadataFailed"), err);
      }
    }
  };

  const busy =
    stage.kind === "uploading" ||
    stage.kind === "signing" ||
    stage.kind === "confirming" ||
    stage.kind === "indexing";

  const statusText =
    stage.kind === "uploading"
      ? t("uploading")
      : stage.kind === "signing"
        ? t("signing")
        : stage.kind === "confirming"
          ? t("confirming")
          : stage.kind === "indexing"
            ? t("indexing")
            : t("submit");

  return (
    <div className="bg-amber-50 border border-amber-200 rounded-2xl p-6">
      <div className="flex items-start gap-3 mb-4">
        <svg
          width="20"
          height="20"
          viewBox="0 0 24 24"
          fill="currentColor"
          className="text-amber-600 shrink-0 mt-0.5"
        >
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z" />
        </svg>
        <div>
          <h3 className="font-bold text-amber-900 mb-1">{t("title")}</h3>
          <p className="text-sm text-amber-800">
            {t("body", { name: currentName })}
          </p>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder={t("namePlaceholder")}
          disabled={busy}
          className="px-3 py-2 rounded-lg border border-amber-300 bg-white text-sm focus:outline-none focus:border-amber-500 disabled:opacity-50"
        />
        <input
          type="text"
          value={location}
          onChange={(e) => setLocation(e.target.value)}
          placeholder={t("locationPlaceholder")}
          disabled={busy}
          className="px-3 py-2 rounded-lg border border-amber-300 bg-white text-sm focus:outline-none focus:border-amber-500 disabled:opacity-50"
        />
      </div>

      <textarea
        rows={3}
        value={description}
        onChange={(e) => setDescription(e.target.value)}
        placeholder={t("descriptionPlaceholder")}
        disabled={busy}
        className="w-full px-3 py-2 rounded-lg border border-amber-300 bg-white text-sm focus:outline-none focus:border-amber-500 disabled:opacity-50 mb-4"
      />

      <label className="block mb-4">
        <span className="block text-xs font-semibold text-amber-900 mb-1 uppercase tracking-wider">
          {t("image")}
        </span>
        <input
          type="file"
          accept="image/*"
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) handleImage(f);
          }}
          disabled={busy}
          className="text-sm"
        />
        {imagePreview && (
          <img
            src={imagePreview}
            alt=""
            className="mt-2 h-24 rounded-lg object-cover border border-amber-200"
          />
        )}
      </label>

      {stage.kind === "error" && (
        <div className="mb-3 text-sm text-error break-words">
          {stage.message}
        </div>
      )}

      <button
        onClick={handleSubmit}
        disabled={busy || !name.trim()}
        className="regen-gradient text-white px-6 py-2.5 rounded-full font-semibold text-sm hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
      >
        {busy && <Spinner size={16} />}
        {statusText}
      </button>
    </div>
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

  let raisedNum = 0;
  let targetNum = 0;
  let minCapNum = 0;
  let pct = 0;
  let minCapPct = 0;
  let daysLeft = 0;
  let softCapReached = false;

  if (hasOnChainData && maxCap > 0n) {
    // tokens × pricePerToken / 1e18 = USD (both 18 dec)
    const raisedUsd =
      (currentSupply * pricePerToken) / 10n ** 18n / 10n ** 18n;
    const targetUsd = (maxCap * pricePerToken) / 10n ** 18n / 10n ** 18n;
    const minCapUsd = (minCap * pricePerToken) / 10n ** 18n / 10n ** 18n;
    raisedNum = Number(raisedUsd);
    targetNum = Number(targetUsd);
    minCapNum = Number(minCapUsd);
    pct = maxCap > 0n ? Number((currentSupply * 100n) / maxCap) : 0;
    minCapPct = maxCap > 0n ? Number((minCap * 100n) / maxCap) : 0;
    softCapReached = currentSupply >= minCap;
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
      {/*
        Two-layer progress bar: background track + filled primary + a
        vertical tick marking the min cap (soft cap). Investors immediately
        see how close the campaign is to being viable — below the tick the
        campaign can still fail and refund; above it auto-activates.
      */}
      <div className="relative w-full h-2 bg-surface-container-high rounded-full overflow-hidden">
        <div
          className="h-full bg-primary rounded-full transition-all duration-700"
          style={{ width: `${Math.min(pct, 100)}%` }}
        />
        {minCapNum > 0 && minCapPct < 100 && (
          <div
            className="absolute top-[-3px] bottom-[-3px] w-0.5"
            style={{
              left: `${minCapPct}%`,
              backgroundColor: softCapReached ? "#006b2c" : "#3e4a3d",
              opacity: 0.7,
            }}
            title={`min cap €${minCapNum.toLocaleString()}`}
          />
        )}
      </div>
      {minCapNum > 0 && (
        <div
          className="relative mt-1 h-3 text-[10px] font-semibold uppercase tracking-wider text-on-surface-variant"
          aria-hidden="true"
        >
          <span
            className="absolute -translate-x-1/2 whitespace-nowrap"
            style={{
              left: `${Math.max(4, Math.min(96, minCapPct))}%`,
              color: softCapReached ? "#006b2c" : undefined,
            }}
          >
            {softCapReached ? "✓ " : ""}
            {t("minCapMarker", {
              amount: `€${minCapNum.toLocaleString()}`,
            })}
          </span>
        </div>
      )}
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

function InfoPanel({
  address,
  description,
  location,
  createdAtBlock,
}: {
  address: string;
  description?: string;
  location?: string;
  createdAtBlock?: string;
}) {
  const t = useTranslations("detail.info");
  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <h2 className="text-2xl font-bold tracking-tight text-on-surface mb-6">
        {t("title")}
      </h2>
      <div className="space-y-4 text-sm text-on-surface-variant leading-relaxed">
        {description ? (
          <p className="whitespace-pre-line">{description}</p>
        ) : (
          <p>{t("about")}</p>
        )}
        {location && (
          <p className="text-on-surface font-medium">📍 {location}</p>
        )}
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
          {createdAtBlock && (
            <div>
              <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
                {t("block")}
              </div>
              <div className="text-sm text-on-surface">
                {Number(createdAtBlock).toLocaleString()}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function StatsCard({
  pricePerToken,
  maxCap,
  currentSupply,
  currentYieldRate,
}: {
  pricePerToken: bigint;
  maxCap: bigint;
  currentSupply: bigint;
  currentYieldRate: bigint;
}) {
  const t = useTranslations("detail.sidebar");

  const priceUsd = Number(formatUnits(pricePerToken, 18));
  const maxCapNum = Number(formatUnits(maxCap, 18));
  const soldNum = Number(formatUnits(currentSupply, 18));
  const yieldRate =
    Math.round(Number(formatUnits(currentYieldRate, 18)) * 10) / 10;

  const fmtNum = (n: number) => {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
    return n.toFixed(0);
  };

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-6 border border-outline-variant/15">
      <h3 className="text-sm font-semibold text-on-surface mb-4">
        {t("stats")}
      </h3>
      <div className="grid grid-cols-2 gap-4 mb-4">
        <Stat
          label={t("tokenPrice")}
          value={priceUsd > 0 ? `€${priceUsd.toFixed(3)}` : "—"}
        />
        <Stat
          label={t("maxSupply")}
          value={maxCapNum > 0 ? `${fmtNum(maxCapNum)} $CAMP` : "—"}
        />
        <Stat
          label={t("tokensSold")}
          value={soldNum > 0 ? fmtNum(soldNum) : "0"}
        />
      </div>

      <div className="pt-4 border-t border-outline-variant/15">
        <div className="flex justify-between items-end mb-3">
          <span className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("yieldRate")}
          </span>
          <span className="text-2xl font-bold text-primary">
            {yieldRate > 0 ? `${yieldRate}x` : "—"}
          </span>
        </div>

        <div className="relative h-2 bg-surface-container-high rounded-full overflow-hidden mb-2">
          <div
            className="absolute inset-y-0 left-0 regen-gradient rounded-full"
            style={{
              width: `${Math.max(0, Math.min(100, ((yieldRate - 1) / 4) * 100))}%`,
            }}
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

function TokensAcceptedCard({
  campaignAddress,
}: {
  campaignAddress: Address | undefined;
}) {
  const t = useTranslations("detail.sidebar");
  const campaignAbi = abis.Campaign as never;

  const { data: acceptedTokens } = useReadContracts({
    contracts: campaignAddress
      ? [
          {
            address: campaignAddress,
            abi: campaignAbi,
            functionName: "getAcceptedTokens",
          },
        ]
      : [],
    query: { enabled: !!campaignAddress },
  });

  const tokens = (acceptedTokens?.[0]?.result as Address[] | undefined) ?? [];

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-6 border border-outline-variant/15">
      <h3 className="text-sm font-semibold text-on-surface mb-4">
        {t("acceptedTokens")}
      </h3>
      {tokens.length === 0 ? (
        <div className="text-xs text-on-surface-variant py-2">
          {t("noTokens")}
        </div>
      ) : (
        <div className="space-y-3">
          {tokens.map((addr) => (
            <TokenRow
              key={addr}
              tokenAddress={addr}
              campaignAddress={campaignAddress!}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function TokenRow({
  tokenAddress,
  campaignAddress,
}: {
  tokenAddress: Address;
  campaignAddress: Address;
}) {
  const t = useTranslations("detail.sidebar");
  const campaignAbi = abis.Campaign as never;

  const { data } = useReadContracts({
    contracts: [
      { address: tokenAddress, abi: erc20Abi, functionName: "symbol" },
      {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "tokenConfigs",
        args: [tokenAddress],
      },
    ],
  });

  const symbol = (data?.[0]?.result as string | undefined) ?? "—";
  // tokenConfigs returns TokenConfig struct: (pricingMode, paymentDecimals, fixedRate, oracleFeed, active)
  const cfg = data?.[1]?.result as
    | readonly [number, number, bigint, Address, boolean]
    | undefined;
  const isOracle = cfg ? cfg[0] === 1 : false;
  const live = isOracle;

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
          <div className="text-xs text-on-surface-variant">
            {isOracle ? "Oracle" : "Fixed"}
          </div>
        </div>
      </div>
      {live && (
        <div className="text-xs text-primary font-semibold flex items-center gap-1">
          <span className="w-1.5 h-1.5 rounded-full bg-primary animate-pulse" />
          {t("live")}
        </div>
      )}
    </div>
  );
}

function ProducerCard({ producer }: { producer?: Address }) {
  const t = useTranslations("detail.sidebar");
  const { data: sgProducer } = useSubgraphProducer(producer);
  const { data: profile } = useProducerProfile(
    sgProducer?.profileURI,
    sgProducer?.version,
  );

  const name = profile?.name;
  const location = profile?.location;
  const avatar = profile?.avatar;
  const short = producer
    ? `${producer.slice(0, 6)}…${producer.slice(-4)}`
    : "";

  const initials = (name ?? short).slice(0, 2).toUpperCase();

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-6 border border-outline-variant/15">
      <h3 className="text-sm font-semibold text-on-surface mb-4">
        {t("producer")}
      </h3>
      <div className="flex items-center gap-4 mb-4">
        {avatar ? (
          <img
            src={avatar}
            alt={name ?? short}
            className="w-12 h-12 rounded-full object-cover shrink-0"
          />
        ) : (
          <div className="w-12 h-12 rounded-full bg-primary flex items-center justify-center text-white font-bold shrink-0">
            {initials}
          </div>
        )}
        <div className="min-w-0">
          <div className="flex items-center gap-1.5">
            <span className="font-semibold text-on-surface truncate">
              {name ?? short}
            </span>
            {profile && (
              <svg
                width="16"
                height="16"
                viewBox="0 0 24 24"
                fill="currentColor"
                className="text-primary shrink-0"
              >
                <path d="M12 2L4 5v6.09c0 5.05 3.41 9.76 8 10.91 4.59-1.15 8-5.86 8-10.91V5l-8-3zm-2 15l-4-4 1.41-1.41L10 14.17l6.59-6.59L18 9l-8 8z" />
              </svg>
            )}
          </div>
          {location && (
            <div className="text-sm text-on-surface-variant mt-0.5 truncate">
              {location}
            </div>
          )}
        </div>
      </div>
      {producer && (
        <Link
          href={`/producer/${producer}`}
          className="w-full py-2 flex items-center justify-center gap-2 text-primary text-sm font-semibold hover:bg-surface-container-low rounded-lg transition"
        >
          {t("viewProfile")} →
        </Link>
      )}
    </div>
  );
}
