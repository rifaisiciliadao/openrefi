"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { readContract } from "@wagmi/core";
import { config as wagmiConfig } from "@/app/providers";
import {
  parseUnits,
  formatUnits,
  decodeEventLog,
  zeroAddress,
  type Address,
} from "viem";
import { abis, getAddresses, CHAIN_ID } from "@/contracts";
import { erc20Abi } from "@/contracts/erc20";
import {
  KNOWN_TOKENS,
  PRICING_MODE_ENUM,
  resolveTokenAddress,
} from "@/contracts/tokens";
import { uploadImage, uploadMetadata } from "@/lib/api";
import { findCampaignByName } from "@/lib/subgraph";
import { waitForTx } from "@/lib/waitForTx";
import { productUnitLabel } from "@/lib/productUnit";
import { useTxNotify } from "@/lib/useTxNotify";
import { Spinner } from "@/components/Spinner";

const USDC_DECIMALS = 6;
const MOCK_USDC_MINT_AMOUNT = 10_000n * 10n ** BigInt(USDC_DECIMALS); // 10,000 mUSDC

/** MockUSDC exposes a permissionless mint for testers — testnet faucet. */
const mockUsdcMintAbi = [
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
] as const;
import Link from "next/link";
import { txUrl } from "@/lib/explorer";

type FormData = {
  name: string;
  description: string;
  location: string;
  productType: string;
  imageFile: File | null;
  imagePreview: string | null;
  pricePerToken: string;
  minCapTrees: string;
  maxCapTrees: string;
  fundingDeadline: string;
  seasonDuration: string;
  minProductClaim: string;
  /** Producer's expected annual harvest value in whole USD (e.g. "5000" → $5,000/yr). */
  expectedAnnualHarvestUsd: string;
  /** Producer's expected annual harvest in product units (e.g. "1000" → 1000 L of oil/yr). */
  expectedAnnualHarvest: string;
  /** Calendar year of the first reportable harvest (e.g. "2027"). */
  firstHarvestYear: string;
  /** Number of harvests the producer pre-funds via lockCollateral. 0 = no commitment. */
  coverageHarvests: string;
  /** Whole-USD amount the producer will lockCollateral right after deploy. "0" or "" = skip. */
  initialCollateralUsd: string;
  tokenSymbol: string;
  yieldName: string;
  yieldSymbol: string;
  acceptedTokens: Array<{
    /** KNOWN_TOKENS.symbol — the UI only offers tokens from the curated list. */
    symbol: string;
    /**
     * Human-friendly rate the producer enters:
     *  - fixed mode: how many payment-token units per 1 campaign token (e.g. "0.144" USDC).
     *  - oracle mode: unused (pulled from Chainlink feed); we keep it for UI consistency.
     */
    humanRate: string;
  }>;
};

const STEP_KEYS = ["info", "params", "payments", "collateral", "confirm"] as const;
const PRODUCT_KEYS = [
  "olive-oil",
  "citrus",
  "wine",
  "honey",
  "nuts",
  "other",
] as const;

export default function CreateCampaign() {
  const t = useTranslations("create");
  const [step, setStep] = useState(1);
  // Form starts fully empty — the producer fills everything from scratch.
  // Sensible suggestions live in the input placeholders, not in committed
  // state, so a half-distracted user doesn't accidentally ship "OLIVE / Olive
  // Oil / 0.144" if they don't actually mean those.
  const [form, setForm] = useState<FormData>({
    name: "",
    description: "",
    location: "",
    productType: "",
    imageFile: null,
    imagePreview: null,
    pricePerToken: "",
    minCapTrees: "",
    maxCapTrees: "",
    fundingDeadline: "",
    seasonDuration: "",
    minProductClaim: "",
    expectedAnnualHarvestUsd: "",
    expectedAnnualHarvest: "",
    firstHarvestYear: "",
    coverageHarvests: "",
    initialCollateralUsd: "",
    tokenSymbol: "",
    yieldName: "",
    yieldSymbol: "",
    acceptedTokens: [],
  });

  /**
   * Campaign creation is a multi-tx flow. Rather than chain useEffects on
   * receipt hashes (race-prone), we run the whole thing sequentially in a
   * single async handler and tick through the status enum at each stage.
   * Phases ending in -sig wait for the wallet popup; -chain wait for the
   * receipt. Each writeContract revert or wallet rejection surfaces here.
   */
  const [status, setStatus] = useState<
    | { kind: "idle" }
    | { kind: "uploading-image" }
    | { kind: "uploading-metadata" }
    | { kind: "creating-sig" }
    | { kind: "creating-chain" }
    | { kind: "registering-sig"; campaign: Address }
    | { kind: "registering-chain"; campaign: Address }
    | {
        kind: "whitelisting-sig";
        campaign: Address;
        index: number;
        total: number;
      }
    | {
        kind: "whitelisting-chain";
        campaign: Address;
        index: number;
        total: number;
      }
    | { kind: "collateral-approve-sig"; campaign: Address }
    | { kind: "collateral-approve-chain"; campaign: Address }
    | { kind: "collateral-lock-sig"; campaign: Address }
    | { kind: "collateral-lock-chain"; campaign: Address }
    | {
        kind: "success";
        campaign: Address;
        createTx: `0x${string}`;
        registryTx?: `0x${string}`;
        whitelistedCount: number;
      }
    | { kind: "error"; error: string }
  >({ kind: "idle" });

  const { address: connectedAddress, isConnected } = useAccount();
  const { factory, registry } = getAddresses();
  const factoryDeployed =
    factory !== "0x0000000000000000000000000000000000000000";
  const registryDeployed =
    registry !== "0x0000000000000000000000000000000000000000";

  const { writeContractAsync } = useWriteContract();

  const update = <K extends keyof FormData>(key: K, value: FormData[K]) => {
    setForm((f) => ({ ...f, [key]: value }));
  };

  const next = () => setStep((s) => Math.min(5, s + 1));
  const prev = () => setStep((s) => Math.max(1, s - 1));

  // Per-step validation. Avanti is disabled until every required field on
  // the current step is filled. Cheap derived check, runs every render.
  const isStepValid = (() => {
    if (step === 1) {
      return (
        form.name.trim().length > 0 &&
        form.tokenSymbol.trim().length > 0 &&
        form.yieldName.trim().length > 0 &&
        form.yieldSymbol.trim().length > 0 &&
        form.description.trim().length > 0 &&
        !!form.imageFile &&
        form.location.trim().length > 0 &&
        form.productType.length > 0
      );
    }
    if (step === 2) {
      const pos = (s: string) => Number(s) > 0;
      return (
        pos(form.pricePerToken) &&
        pos(form.minCapTrees) &&
        pos(form.maxCapTrees) &&
        Number(form.maxCapTrees) >= Number(form.minCapTrees) &&
        form.fundingDeadline.length > 0 &&
        pos(form.seasonDuration) &&
        pos(form.minProductClaim) &&
        pos(form.expectedAnnualHarvestUsd) &&
        pos(form.expectedAnnualHarvest) &&
        Number(form.firstHarvestYear) >= 2025 &&
        Number(form.coverageHarvests) >= 0
      );
    }
    if (step === 3) {
      // At least one row, and each row has a usable rate. Stablecoins derive
      // their rate from `pricePerToken` (humanRate is unused, see the JSX
      // branch below); oracle tokens read from a Chainlink feed; only
      // fixed-rate non-stable tokens require an explicit humanRate.
      return (
        form.acceptedTokens.length > 0 &&
        form.acceptedTokens.every((t) => {
          if (!t.symbol) return false;
          const known = KNOWN_TOKENS.find((k) => k.symbol === t.symbol);
          if (!known) return false;
          if (known.stableUsd) return Number(form.pricePerToken) > 0;
          if (known.defaultMode === "oracle") {
            return !!known.oracleFeed[CHAIN_ID];
          }
          return Number(t.humanRate) > 0;
        })
      );
    }
    if (step === 4) {
      // Collateral step is fully optional — empty / 0 means "skip", any positive
      // number is a commit. Negative numbers / NaN block.
      const v = Number(form.initialCollateralUsd || "0");
      return Number.isFinite(v) && v >= 0;
    }
    return true; // step 5 = review, always allowed
  })();

  const maxCap = Number(form.maxCapTrees || 0) * 1000;
  const minCap = Number(form.minCapTrees || 0) * 1000;

  const handleImageSelect = (file: File) => {
    const preview = URL.createObjectURL(file);
    setForm((f) => ({ ...f, imageFile: file, imagePreview: preview }));
  };

  const deployBusy =
    status.kind === "uploading-image" ||
    status.kind === "uploading-metadata" ||
    status.kind === "creating-sig" ||
    status.kind === "creating-chain" ||
    status.kind === "registering-sig" ||
    status.kind === "registering-chain" ||
    status.kind === "whitelisting-sig" ||
    status.kind === "whitelisting-chain" ||
    status.kind === "collateral-approve-sig" ||
    status.kind === "collateral-approve-chain" ||
    status.kind === "collateral-lock-sig" ||
    status.kind === "collateral-lock-chain";

  const handleDeploy = async () => {
    if (!isConnected) {
      setStatus({ kind: "error", error: t("status.errorWallet") });
      return;
    }
    if (!factoryDeployed) {
      setStatus({ kind: "error", error: t("status.errorFactory") });
      return;
    }
    if (!form.imageFile) {
      setStatus({ kind: "error", error: t("status.errorImage") });
      return;
    }
    if (!form.fundingDeadline) {
      setStatus({ kind: "error", error: t("status.errorDeadline") });
      return;
    }

    // Pre-flight name uniqueness — kill duplicate-name campaigns before
    // we burn any signatures. We had a regression where a producer
    // double-clicked through a stuck wallet popup and ended up with 3
    // identical "Olive IGP Sicily" campaigns; the discovery list became
    // useless. Off-chain check (subgraph + metadata JSON), so this is
    // best-effort — bypassable by raw factory.createCampaign callers,
    // but the demo flow goes through /create so it's enough.
    try {
      const collision = await findCampaignByName(form.name);
      if (collision) {
        setStatus({
          kind: "error",
          error: t("status.errorDuplicateName", { name: form.name }),
        });
        return;
      }
    } catch (err) {
      // If the subgraph is briefly unreachable we don't want to block a
      // legitimate first deploy. Log + continue rather than hard-fail —
      // worst case the producer races with the empty-state and we get
      // one duplicate, vs. nothing-deployable when the subgraph hiccups.
      console.warn("findCampaignByName failed, continuing:", err);
    }

    // Pre-flight: if the producer asked to lock collateral right after
    // deploy, we need that USDC actually sitting in their wallet. Check
    // BEFORE we burn any signatures — without this, the createCampaign +
    // setMetadata + addAcceptedToken txs all succeed and only the very
    // last lockCollateral reverts with ERC20InsufficientBalance, leaving
    // the producer with a deployed-but-unfunded campaign and a wallet
    // signature graveyard. Cheap balance read, infinitely cheaper than
    // shipping 5+ txs and discovering the rug at the end.
    const collateralUsd = Number(form.initialCollateralUsd || "0");
    if (collateralUsd > 0) {
      const required6 = parseUnits(form.initialCollateralUsd, USDC_DECIMALS);
      try {
        const balance = (await readContract(wagmiConfig, {
          address: getAddresses().usdc,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [connectedAddress!],
        })) as bigint;
        if (balance < required6) {
          setStatus({
            kind: "error",
            error: t("status.errorInsufficientBalance", {
              required: collateralUsd.toLocaleString(),
              actual: (Number(balance) / 1e6).toLocaleString(undefined, {
                maximumFractionDigits: 2,
              }),
            }),
          });
          return;
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        setStatus({ kind: "error", error: msg });
        return;
      }
    }

    try {
      // ── 1. Upload image + metadata JSON to DO Spaces ──────────────────
      setStatus({ kind: "uploading-image" });
      const image = await uploadImage(form.imageFile);

      setStatus({ kind: "uploading-metadata" });
      const metadata = await uploadMetadata({
        name: form.name,
        description: form.description,
        location: form.location,
        productType: form.productType,
        imageUrl: image.url,
      });

      // ── 2. createCampaign: wallet sign → on-chain confirmation ────────
      setStatus({ kind: "creating-sig" });
      const deadline = Math.floor(
        new Date(form.fundingDeadline).getTime() / 1000,
      );
      const annualHarvestUsd =
        BigInt(form.expectedAnnualHarvestUsd || "0") * 10n ** 18n;
      const annualHarvestQty =
        BigInt(form.expectedAnnualHarvest || "0") * 10n ** 18n;
      const firstHarvestYear = BigInt(form.firstHarvestYear || "0");
      const coverage = BigInt(form.coverageHarvests || "0");

      const createHash = await writeContractAsync({
        address: factory,
        abi: abis.CampaignFactory as never,
        functionName: "createCampaign",
        args: [
          {
            producer: connectedAddress!,
            tokenName: form.name,
            tokenSymbol: form.tokenSymbol,
            yieldName: form.yieldName,
            yieldSymbol: form.yieldSymbol,
            pricePerToken: parseUnits(form.pricePerToken, 18),
            minCap: BigInt(minCap) * 10n ** 18n,
            maxCap: BigInt(maxCap) * 10n ** 18n,
            fundingDeadline: BigInt(deadline),
            seasonDuration: BigInt(Number(form.seasonDuration) * 86400),
            minProductClaim: BigInt(form.minProductClaim) * 10n ** 18n,
            expectedAnnualHarvestUsd: annualHarvestUsd,
            expectedAnnualHarvest: annualHarvestQty,
            firstHarvestYear: firstHarvestYear,
            coverageHarvests: coverage,
          },
        ],
      });
      setStatus({ kind: "creating-chain" });
      const createReceipt = await waitForTx(createHash);
      if (createReceipt.status !== "success") {
        throw new Error("createCampaign reverted on-chain");
      }

      // Decode the CampaignCreated event to get the new campaign address
      const factoryAbi = abis.CampaignFactory as readonly unknown[];
      let newCampaign: Address | undefined;
      for (const log of createReceipt.logs) {
        try {
          const decoded = decodeEventLog({
            abi: factoryAbi,
            data: log.data,
            topics: log.topics,
          });
          if (decoded.eventName === "CampaignCreated") {
            newCampaign = (decoded.args as { campaign: Address }).campaign;
            break;
          }
        } catch {
          // not a factory event
        }
      }
      if (!newCampaign) {
        throw new Error("Campaign address not found in tx logs");
      }

      // ── 3. setMetadata on the CampaignRegistry (mandatory now) ────────
      let registryHash: `0x${string}` | undefined;
      if (registryDeployed) {
        setStatus({ kind: "registering-sig", campaign: newCampaign });
        registryHash = await writeContractAsync({
          address: registry,
          abi: abis.CampaignRegistry as never,
          functionName: "setMetadata",
          args: [newCampaign, metadata.url],
        });
        setStatus({ kind: "registering-chain", campaign: newCampaign });
        const r = await waitForTx(registryHash);
        if (r.status !== "success") {
          throw new Error("setMetadata reverted on-chain");
        }
      }

      // ── 4. addAcceptedToken for each token the producer selected ──────
      const total = form.acceptedTokens.length;
      let whitelistedCount = 0;
      for (let i = 0; i < total; i++) {
        const entry = form.acceptedTokens[i];
        const known = KNOWN_TOKENS.find((k) => k.symbol === entry.symbol);
        if (!known) continue;

        const tokenAddress = resolveTokenAddress(known, CHAIN_ID);
        const pricingMode = PRICING_MODE_ENUM[known.defaultMode];
        // For 1:1-USD stablecoins we skip the per-token humanRate input and
        // derive the rate straight from pricePerToken — same number, just
        // re-scaled to the stablecoin's decimals (e.g. 0.144 USD → 144_000
        // for 6-dec USDC, → 144e15 for 18-dec DAI).
        const rateSource =
          known.defaultMode === "fixed" && known.stableUsd
            ? form.pricePerToken
            : entry.humanRate || "0";
        const fixedRate =
          known.defaultMode === "fixed"
            ? parseUnits(rateSource, known.decimals)
            : 0n;
        const oracleFeed =
          known.defaultMode === "oracle"
            ? (known.oracleFeed[CHAIN_ID] ?? zeroAddress)
            : zeroAddress;

        if (known.defaultMode === "fixed" && fixedRate === 0n) {
          console.warn(`Invalid rate for ${known.symbol}, skipping`);
          continue;
        }
        if (known.defaultMode === "oracle" && oracleFeed === zeroAddress) {
          console.warn(`Missing Chainlink feed for ${known.symbol}, skipping`);
          continue;
        }

        setStatus({
          kind: "whitelisting-sig",
          campaign: newCampaign,
          index: i,
          total,
        });
        try {
          const hash = await writeContractAsync({
            address: newCampaign,
            abi: abis.Campaign as never,
            functionName: "addAcceptedToken",
            args: [tokenAddress, pricingMode, fixedRate, oracleFeed],
          });
          setStatus({
            kind: "whitelisting-chain",
            campaign: newCampaign,
            index: i,
            total,
          });
          const r = await waitForTx(hash);
          if (r.status === "success") {
            whitelistedCount += 1;
          } else {
            console.warn(`addAcceptedToken reverted for ${known.symbol}`);
          }
        } catch (err) {
          console.warn(
            `addAcceptedToken failed for ${known.symbol}:`,
            err instanceof Error ? err.message : err,
          );
        }
      }

      // ── 5. Optional collateral lock ──────────────────────────────────
      // If the producer entered a positive amount in step 4, fire two extra
      // signatures: approve(factoryUsdc, campaign, amount) → lockCollateral.
      // factory.usdc on Base Sepolia = mUSDC mock; on mainnet = USDC. The
      // contract guards Funding|Active state — fresh-deployed campaigns are
      // Funding, so this always succeeds path-wise.
      const collateralUsd = Number(form.initialCollateralUsd || "0");
      if (collateralUsd > 0) {
        const { usdc: usdcAddr } = getAddresses();
        const collateralAmount = parseUnits(
          form.initialCollateralUsd,
          USDC_DECIMALS,
        );

        setStatus({ kind: "collateral-approve-sig", campaign: newCampaign });
        const approveHash = await writeContractAsync({
          address: usdcAddr,
          abi: erc20Abi,
          functionName: "approve",
          args: [newCampaign, collateralAmount],
        });
        setStatus({ kind: "collateral-approve-chain", campaign: newCampaign });
        const ar = await waitForTx(approveHash);
        if (ar.status !== "success") {
          throw new Error("collateral approve reverted on-chain");
        }

        setStatus({ kind: "collateral-lock-sig", campaign: newCampaign });
        const lockHash = await writeContractAsync({
          address: newCampaign,
          abi: abis.Campaign as never,
          functionName: "lockCollateral",
          args: [collateralAmount],
        });
        setStatus({ kind: "collateral-lock-chain", campaign: newCampaign });
        const lr = await waitForTx(lockHash);
        if (lr.status !== "success") {
          throw new Error("lockCollateral reverted on-chain");
        }
      }

      // ── 6. Done ───────────────────────────────────────────────────────
      setStatus({
        kind: "success",
        campaign: newCampaign,
        createTx: createHash,
        registryTx: registryHash,
        whitelistedCount,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (/user (rejected|denied)/i.test(msg)) {
        setStatus({ kind: "idle" });
      } else {
        setStatus({ kind: "error", error: msg });
      }
    }
  };

  return (
    <div className="max-w-[1440px] mx-auto px-4 md:px-8 pt-28 pb-20 md:pb-24 flex flex-col lg:flex-row gap-10 md:gap-16">
      <div className="flex-1 lg:w-3/5 min-w-0">
        <div className="mb-10 md:mb-12 flex items-center justify-between relative">
          <div className="absolute left-0 top-4 w-full h-0.5 bg-surface-container-high -z-10" />
          <div
            className="absolute left-0 top-4 h-0.5 bg-primary -z-10 transition-all duration-500"
            style={{ width: `${((step - 1) / 3) * 100}%` }}
          />
          {STEP_KEYS.map((key, i) => {
            const n = i + 1;
            return (
              <div
                key={key}
                className="flex flex-col items-center gap-2 bg-surface px-1"
              >
                <div
                  className={`w-8 h-8 rounded-full flex items-center justify-center font-bold text-sm transition-colors ${
                    step >= n
                      ? "bg-primary text-white"
                      : "bg-surface-container-highest text-on-surface-variant"
                  }`}
                >
                  {n}
                </div>
                <span
                  className={`text-[11px] md:text-sm transition-colors text-center leading-tight ${
                    step === n
                      ? "font-semibold text-on-surface"
                      : "text-on-surface-variant"
                  }`}
                >
                  {t(`steps.${key}`)}
                </span>
              </div>
            );
          })}
        </div>

        {step === 1 && (
          <>
            <div className="mb-10">
              <h1 className="text-2xl md:text-3xl font-bold tracking-tight text-on-surface mb-2">
                {t("step1.title")}
              </h1>
              <p className="text-on-surface-variant">{t("step1.subtitle")}</p>
            </div>

            <div className="space-y-6">
              <Field label={t("step1.name")}>
                <input
                  type="text"
                  value={form.name}
                  onChange={(e) => update("name", e.target.value)}
                  placeholder={t("step1.namePlaceholder")}
                  className="input"
                />
              </Field>

              <Field label={t("step1.symbol")} hint={t("step1.symbolHint")}>
                <input
                  type="text"
                  value={form.tokenSymbol}
                  onChange={(e) =>
                    update(
                      "tokenSymbol",
                      e.target.value.toUpperCase().slice(0, 8),
                    )
                  }
                  placeholder="OLIVE"
                  className="input uppercase"
                  maxLength={8}
                />
              </Field>

              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                <Field
                  label={t("step1.yieldName")}
                  hint={t("step1.yieldNameHint")}
                >
                  <input
                    type="text"
                    value={form.yieldName}
                    onChange={(e) => update("yieldName", e.target.value)}
                    placeholder={t("step1.yieldNamePlaceholder")}
                    className="input"
                  />
                </Field>

                <Field
                  label={t("step1.yieldSymbol")}
                  hint={t("step1.yieldSymbolHint", {
                    stake: form.tokenSymbol || "CAMP",
                    yield: form.yieldSymbol || "YIELD",
                  })}
                >
                  <input
                    type="text"
                    value={form.yieldSymbol}
                    onChange={(e) =>
                      update(
                        "yieldSymbol",
                        e.target.value.toUpperCase().slice(0, 8),
                      )
                    }
                    placeholder="OIL"
                    className="input uppercase"
                    maxLength={8}
                  />
                </Field>
              </div>

              <Field label={t("step1.description")}>
                <textarea
                  rows={4}
                  value={form.description}
                  onChange={(e) => update("description", e.target.value)}
                  placeholder={t("step1.descriptionPlaceholder")}
                  className="input"
                />
              </Field>

              <Field label={t("step1.image")}>
                <label className="block relative cursor-pointer">
                  <input
                    type="file"
                    accept="image/*"
                    className="hidden"
                    onChange={(e) => {
                      const file = e.target.files?.[0];
                      if (file) handleImageSelect(file);
                    }}
                  />
                  {form.imagePreview ? (
                    <div className="relative h-48 rounded-xl overflow-hidden border border-outline-variant/15">
                      <img
                        src={form.imagePreview}
                        alt="Preview"
                        className="w-full h-full object-cover"
                      />
                      <div className="absolute inset-0 bg-black/0 hover:bg-black/30 transition flex items-center justify-center text-white opacity-0 hover:opacity-100">
                        {t("step1.imageReplace")}
                      </div>
                    </div>
                  ) : (
                    <div className="border-2 border-dashed border-outline-variant rounded-xl bg-surface-container-low p-10 flex flex-col items-center justify-center text-center hover:bg-surface-container-highest transition-colors">
                      <svg
                        width="40"
                        height="40"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="currentColor"
                        strokeWidth="1.5"
                        className="text-on-surface-variant mb-4"
                      >
                        <path
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5"
                        />
                      </svg>
                      <p className="text-sm font-medium text-on-surface">
                        {t("step1.imageDrop")}
                      </p>
                      <p className="text-xs text-on-surface-variant mt-1">
                        {t("step1.imageHint")}
                      </p>
                    </div>
                  )}
                </label>
              </Field>

              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                <Field label={t("step1.location")}>
                  <input
                    type="text"
                    value={form.location}
                    onChange={(e) => update("location", e.target.value)}
                    placeholder={t("step1.locationPlaceholder")}
                    className="input"
                  />
                </Field>

                <Field label={t("step1.productType")}>
                  <select
                    value={form.productType}
                    onChange={(e) => update("productType", e.target.value)}
                    className="input appearance-none"
                  >
                    <option value="">{t("step1.selectProduct")}</option>
                    {PRODUCT_KEYS.map((key) => (
                      <option key={key} value={key}>
                        {t(`step1.products.${key}`)}
                      </option>
                    ))}
                  </select>
                </Field>
              </div>
            </div>
          </>
        )}

        {step === 2 && (
          <>
            <div className="mb-10">
              <h1 className="text-2xl md:text-3xl font-bold tracking-tight text-on-surface mb-2">
                {t("step2.title")}
              </h1>
              <p className="text-on-surface-variant">{t("step2.subtitle")}</p>
            </div>

            <div className="space-y-6">
              <div className="grid grid-cols-2 gap-6">
                <Field label={t("step2.price")} hint={t("step2.priceHint")}>
                  <input
                    type="number"
                    step="0.001"
                    value={form.pricePerToken}
                    onChange={(e) => update("pricePerToken", e.target.value)}
                    placeholder="0.144"
                    className="input"
                  />
                </Field>
                <Field
                  label={t("step2.seasonDuration")}
                  hint={t("step2.seasonDurationHint")}
                >
                  <input
                    type="number"
                    min="365"
                    value={form.seasonDuration}
                    onChange={(e) => update("seasonDuration", e.target.value)}
                    placeholder="365"
                    className="input"
                  />
                </Field>
              </div>

              <div className="grid grid-cols-2 gap-6">
                <Field
                  label={t("step2.minCap")}
                  hint={t("step2.minCapHint")}
                >
                  <input
                    type="number"
                    value={form.minCapTrees}
                    onChange={(e) => update("minCapTrees", e.target.value)}
                    placeholder="50"
                    className="input"
                  />
                </Field>
                <Field
                  label={t("step2.maxCap")}
                  hint={t("step2.maxCapHint", { total: maxCap.toLocaleString() })}
                >
                  <input
                    type="number"
                    value={form.maxCapTrees}
                    onChange={(e) => update("maxCapTrees", e.target.value)}
                    placeholder="200"
                    className="input"
                  />
                </Field>
              </div>

              <div className="grid grid-cols-2 gap-6">
                <Field label={t("step2.deadline")}>
                  <input
                    type="date"
                    value={form.fundingDeadline}
                    onChange={(e) => update("fundingDeadline", e.target.value)}
                    className="input"
                  />
                </Field>
                <Field
                  label={t("step2.minProduct")}
                  hint={t("step2.minProductHint")}
                >
                  <input
                    type="number"
                    value={form.minProductClaim}
                    onChange={(e) => update("minProductClaim", e.target.value)}
                    placeholder="5"
                    className="input"
                  />
                </Field>
              </div>

              {/* v3 — annual harvest commitment (USD + product qty) + first harvest year + coverage */}
              <div className="grid grid-cols-2 gap-6">
                <Field
                  label={t("step2.expectedAnnualHarvestUsd")}
                  hint={t("step2.expectedAnnualHarvestUsdHint")}
                >
                  <div className="relative">
                    {/* Single right-side adornment showing both the currency
                        and the period — reads "$ / YR" together. Earlier the
                        $ sat on the left as a separate adornment which felt
                        disjointed and crowded the digits on some renderings. */}
                    <input
                      type="text"
                      inputMode="numeric"
                      pattern="[0-9,]*"
                      value={
                        form.expectedAnnualHarvestUsd === ""
                          ? ""
                          : Number(
                              form.expectedAnnualHarvestUsd,
                            ).toLocaleString("en-US")
                      }
                      onChange={(e) => {
                        // Strip non-digits before storing → keeps the form
                        // value submission-ready (BigInt below) while the
                        // display stays comma-separated.
                        const raw = e.target.value.replace(/[^\d]/g, "");
                        update("expectedAnnualHarvestUsd", raw);
                      }}
                      placeholder="5,000"
                      className="input pr-20 font-semibold tabular-nums"
                    />
                    <span className="absolute inset-y-0 right-0 w-20 flex items-center justify-center border-l border-outline-variant/15 text-[11px] font-semibold uppercase tracking-wider text-on-surface-variant pointer-events-none">
                      $ / YR
                    </span>
                  </div>
                </Field>
                <Field
                  label={t("step2.expectedAnnualHarvestQty", {
                    unit: productUnitLabel(form.productType),
                  })}
                  hint={t("step2.expectedAnnualHarvestQtyHint", {
                    unit: productUnitLabel(form.productType),
                  })}
                >
                  <div className="relative">
                    <input
                      type="number"
                      min="1"
                      step="1"
                      value={form.expectedAnnualHarvest}
                      onChange={(e) =>
                        update("expectedAnnualHarvest", e.target.value)
                      }
                      placeholder="250"
                      className="input pr-16 font-semibold tabular-nums"
                    />
                    <span className="absolute inset-y-0 right-0 flex items-center pr-4 pl-3 border-l border-outline-variant/15 text-[11px] font-semibold uppercase tracking-wider text-on-surface-variant pointer-events-none">
                      {productUnitLabel(form.productType)} / yr
                    </span>
                  </div>
                </Field>
              </div>

              <Field
                label={t("step2.firstHarvestYear")}
                hint={t("step2.firstHarvestYearHint")}
              >
                <input
                  type="number"
                  min="2025"
                  max="2100"
                  step="1"
                  value={form.firstHarvestYear}
                  onChange={(e) =>
                    update("firstHarvestYear", e.target.value)
                  }
                  placeholder={String(new Date().getFullYear() + 2)}
                  className="input"
                />
              </Field>

              <Field
                label={t("step2.coverageHarvests")}
                hint={(() => {
                  const maxRaise =
                    Number(form.maxCapTrees) *
                    1000 *
                    Number(form.pricePerToken);
                  const annual = Number(form.expectedAnnualHarvestUsd);
                  const payback =
                    annual > 0 && maxRaise > 0
                      ? Math.ceil(maxRaise / annual)
                      : "—";
                  return t("step2.coverageHarvestsHint", { payback });
                })()}
              >
                <input
                  type="number"
                  min="0"
                  step="1"
                  value={form.coverageHarvests}
                  onChange={(e) => update("coverageHarvests", e.target.value)}
                  placeholder="0"
                  className="input"
                />
              </Field>

              {/* Feasibility summary — derives bps + payback + price/unit */}
              <FeasibilitySummary
                maxCapTrees={form.maxCapTrees}
                pricePerToken={form.pricePerToken}
                annualHarvestUsd={form.expectedAnnualHarvestUsd}
                annualHarvestQty={form.expectedAnnualHarvest}
                productType={form.productType}
                firstHarvestYear={form.firstHarvestYear}
                coverageHarvests={form.coverageHarvests}
              />
            </div>
          </>
        )}

        {step === 3 && (
          <>
            <div className="mb-10">
              <h1 className="text-2xl md:text-3xl font-bold tracking-tight text-on-surface mb-2">
                {t("step3.title")}
              </h1>
              <p className="text-on-surface-variant">{t("step3.subtitle")}</p>
            </div>

            <div className="space-y-4">
              {form.acceptedTokens.map((token, i) => {
                const known = KNOWN_TOKENS.find((k) => k.symbol === token.symbol);
                const selectedSymbols = new Set(
                  form.acceptedTokens.map((tk, idx) =>
                    idx === i ? null : tk.symbol,
                  ),
                );
                const isOracle = known?.defaultMode === "oracle";
                const isStableUsd = known?.stableUsd === true;

                return (
                  <div
                    key={i}
                    className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-6"
                  >
                    <div className="flex items-center justify-between mb-4">
                      <div className="flex items-center gap-3">
                        <div className="w-10 h-10 rounded-full bg-primary-fixed text-on-primary-fixed-variant flex items-center justify-center font-bold text-sm">
                          {token.symbol.slice(0, 2)}
                        </div>
                        <div>
                          <div className="font-semibold text-on-surface">
                            {known?.name ?? token.symbol}
                          </div>
                          <div className="text-xs text-on-surface-variant">
                            {isOracle ? t("step3.oracle") : t("step3.fixed")}
                          </div>
                        </div>
                      </div>
                      {form.acceptedTokens.length > 1 && (
                        <button
                          onClick={() =>
                            update(
                              "acceptedTokens",
                              form.acceptedTokens.filter((_, idx) => idx !== i),
                            )
                          }
                          className="text-error text-sm hover:underline"
                        >
                          {t("step3.remove")}
                        </button>
                      )}
                    </div>

                    <div className="grid grid-cols-2 gap-4">
                      <Field label={t("step3.token")}>
                        <select
                          value={token.symbol}
                          onChange={(e) => {
                            const copy = [...form.acceptedTokens];
                            copy[i] = { ...copy[i], symbol: e.target.value };
                            update("acceptedTokens", copy);
                          }}
                          className="input"
                        >
                          {KNOWN_TOKENS.map((k) => {
                            const alreadyUsed = selectedSymbols.has(k.symbol);
                            const disabled = !k.enabled || alreadyUsed;
                            return (
                              <option
                                key={k.symbol}
                                value={k.symbol}
                                disabled={disabled}
                              >
                                {k.symbol} — {k.name}
                                {!k.enabled ? ` (${t("step3.comingSoon")})` : ""}
                              </option>
                            );
                          })}
                        </select>
                      </Field>
                      {isStableUsd ? (
                        <Field label={t("step3.fixedRate")}>
                          <div className="input bg-surface-container flex items-center justify-between text-sm text-on-surface-variant">
                            <span className="font-mono text-on-surface">
                              {form.pricePerToken || "0"} {token.symbol}
                            </span>
                            <span className="text-xs">
                              {t("step3.stablecoinAutoSync")}
                            </span>
                          </div>
                        </Field>
                      ) : !isOracle ? (
                        <Field
                          label={t("step3.fixedRate")}
                          hint={t("step3.fixedRateHint", {
                            symbol: token.symbol,
                          })}
                        >
                          <input
                            type="number"
                            step="0.000001"
                            value={token.humanRate}
                            onChange={(e) => {
                              const copy = [...form.acceptedTokens];
                              copy[i] = {
                                ...copy[i],
                                humanRate: e.target.value,
                              };
                              update("acceptedTokens", copy);
                            }}
                            className="input"
                            placeholder="0.144"
                          />
                        </Field>
                      ) : (
                        <Field label={t("step3.oracleFeed")}>
                          <div className="input bg-surface-container flex items-center text-xs font-mono text-on-surface-variant">
                            {known?.oracleFeed[CHAIN_ID] ??
                              t("step3.noFeedOnChain")}
                          </div>
                        </Field>
                      )}
                    </div>
                  </div>
                );
              })}

              {(() => {
                const used = new Set(form.acceptedTokens.map((t) => t.symbol));
                const nextAvailable = KNOWN_TOKENS.find(
                  (k) => k.enabled && !used.has(k.symbol),
                );
                if (!nextAvailable) return null;
                return (
                  <button
                    onClick={() =>
                      update("acceptedTokens", [
                        ...form.acceptedTokens,
                        { symbol: nextAvailable.symbol, humanRate: "" },
                      ])
                    }
                    className="w-full border-2 border-dashed border-outline-variant rounded-2xl p-4 text-sm font-semibold text-on-surface-variant hover:bg-surface-container-low hover:border-primary transition"
                  >
                    {t("step3.addToken")}
                  </button>
                );
              })()}

              <p className="text-xs text-on-surface-variant px-2">
                {t("step3.signatureNotice")}
              </p>
            </div>
          </>
        )}

        {step === 4 && (
          <>
            <div className="mb-10">
              <h1 className="text-2xl md:text-3xl font-bold tracking-tight text-on-surface mb-2">
                {t("step4.title")}
              </h1>
              <p className="text-sm text-on-surface-variant">
                {t("step4.subtitle")}
              </p>
            </div>

            <CollateralStep
              annualHarvestUsd={form.expectedAnnualHarvestUsd}
              coverageHarvests={form.coverageHarvests}
              maxCapTrees={form.maxCapTrees}
              pricePerToken={form.pricePerToken}
              firstHarvestYear={form.firstHarvestYear}
              value={form.initialCollateralUsd}
              onChange={(v) => update("initialCollateralUsd", v)}
            />
          </>
        )}

        {step === 5 && status.kind === "success" && (
          <DeploySuccessScreen
            campaign={status.campaign}
            createTx={status.createTx}
            name={form.name}
          />
        )}

        {step === 5 && status.kind !== "success" && (
          <>
            <div className="mb-10">
              <h1 className="text-2xl md:text-3xl font-bold tracking-tight text-on-surface mb-2">
                {t("step5.title")}
              </h1>
              <p className="text-on-surface-variant">{t("step5.subtitle")}</p>
            </div>

            <div className="space-y-4">
              <ReviewSection title={t("step5.sections.info")}>
                <ReviewRow label={t("step5.rows.name")} value={form.name || "—"} />
                <ReviewRow
                  label={t("step5.rows.symbol")}
                  value={form.tokenSymbol}
                />
                <ReviewRow
                  label={t("step5.rows.location")}
                  value={form.location || "—"}
                />
                <ReviewRow
                  label={t("step5.rows.productType")}
                  value={
                    form.productType
                      ? t(`step1.products.${form.productType}` as never)
                      : "—"
                  }
                />
              </ReviewSection>

              <ReviewSection title={t("step5.sections.tokenomics")}>
                <ReviewRow
                  label={t("step5.rows.price")}
                  value={`$${form.pricePerToken}`}
                />
                <ReviewRow
                  label={t("step5.rows.minCap")}
                  value={t("step5.rows.trees", {
                    count: form.minCapTrees,
                    tokens: minCap.toLocaleString(),
                  })}
                />
                <ReviewRow
                  label={t("step5.rows.maxCap")}
                  value={t("step5.rows.trees", {
                    count: form.maxCapTrees,
                    tokens: maxCap.toLocaleString(),
                  })}
                />
                <ReviewRow
                  label={t("step5.rows.deadline")}
                  value={form.fundingDeadline || "—"}
                />
                <ReviewRow
                  label={t("step5.rows.season")}
                  value={t("step5.rows.days", { count: form.seasonDuration })}
                />
                <ReviewRow
                  label={t("step5.rows.minProduct")}
                  value={t("step5.rows.units", {
                    count: form.minProductClaim,
                  })}
                />
              </ReviewSection>

              <p className="text-xs text-on-surface-variant px-2 mt-2">
                {t("step5.notice")}
              </p>

              {status.kind === "uploading-image" && (
                <StatusBox kind="info">
                  {t("status.uploadingImage")}
                </StatusBox>
              )}
              {status.kind === "uploading-metadata" && (
                <StatusBox kind="info">
                  {t("status.uploadingMetadata")}
                </StatusBox>
              )}
              {status.kind === "creating-sig" && (
                <StatusBox kind="info">{t("status.confirmTx")}</StatusBox>
              )}
              {status.kind === "creating-chain" && (
                <StatusBox kind="info">{t("status.waitingTx")}</StatusBox>
              )}
              {status.kind === "registering-sig" && (
                <StatusBox kind="info">{t("status.signMetadata")}</StatusBox>
              )}
              {status.kind === "registering-chain" && (
                <StatusBox kind="info">
                  {t("status.linkingMetadata")}
                </StatusBox>
              )}
              {(status.kind === "whitelisting-sig" ||
                status.kind === "whitelisting-chain") && (
                <StatusBox kind="info">
                  {status.kind === "whitelisting-sig"
                    ? t("status.whitelistingSig", {
                        index: status.index + 1,
                        total: status.total,
                      })
                    : t("status.whitelisting", {
                        index: status.index + 1,
                        total: status.total,
                      })}
                </StatusBox>
              )}
              {status.kind === "collateral-approve-sig" && (
                <StatusBox kind="info">
                  {t("status.collateralApproveSig")}
                </StatusBox>
              )}
              {status.kind === "collateral-approve-chain" && (
                <StatusBox kind="info">
                  {t("status.collateralApproveChain")}
                </StatusBox>
              )}
              {status.kind === "collateral-lock-sig" && (
                <StatusBox kind="info">
                  {t("status.collateralLockSig")}
                </StatusBox>
              )}
              {status.kind === "collateral-lock-chain" && (
                <StatusBox kind="info">
                  {t("status.collateralLockChain")}
                </StatusBox>
              )}
              {status.kind === "error" && (
                <StatusBox kind="error">{status.error}</StatusBox>
              )}
            </div>
          </>
        )}

        {status.kind !== "success" && (
          <div className="flex items-center justify-between gap-4 pt-8 mt-8 border-t border-surface-container-high">
            <button
              onClick={prev}
              disabled={step === 1}
              className="px-6 py-3 text-on-surface-variant hover:text-on-surface font-semibold transition disabled:opacity-30 disabled:cursor-not-allowed"
            >
              {t("actions.back")}
            </button>

            {step < 5 ? (
              <button
                onClick={next}
                disabled={!isStepValid}
                className="regen-gradient text-white px-8 py-3 rounded-full font-semibold hover:opacity-90 transition shadow-lg shadow-primary/20 disabled:opacity-50 disabled:cursor-not-allowed disabled:shadow-none"
              >
                {t("actions.next")}
              </button>
            ) : (
              <button
                onClick={handleDeploy}
                disabled={deployBusy || !isConnected}
                className="regen-gradient text-white px-8 py-3 rounded-full font-semibold hover:opacity-90 transition shadow-lg shadow-primary/20 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {!isConnected
                  ? t("actions.connect")
                  : deployBusy
                    ? t("actions.inProgress")
                    : t("actions.deploy")}
              </button>
            )}
          </div>
        )}
      </div>

      <div className="lg:w-2/5 mt-12 lg:mt-0">
        <div className="sticky top-28">
          <h3 className="text-xs font-bold text-on-surface-variant tracking-widest uppercase mb-6">
            {t("preview.title")}
          </h3>

          <div className="bg-surface-container-lowest rounded-2xl overflow-hidden border border-outline-variant/15 shadow-lg">
            <div className="relative h-48 bg-surface-container-low">
              {form.imagePreview ? (
                <img
                  src={form.imagePreview}
                  alt="Preview"
                  className="absolute inset-0 w-full h-full object-cover"
                />
              ) : (
                <div className="absolute inset-0 flex items-center justify-center text-on-surface-variant/30">
                  <svg
                    width="48"
                    height="48"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="1"
                  >
                    <rect width="18" height="18" x="3" y="3" rx="2" />
                    <circle cx="9" cy="9" r="2" />
                    <path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21" />
                  </svg>
                </div>
              )}
              <div className="absolute top-4 left-4 bg-primary-fixed text-on-primary-fixed-variant px-3 py-1 rounded-full text-xs font-semibold tracking-wide uppercase">
                {/* re-use state label from home namespace */}
                Funding
              </div>
            </div>
            <div className="p-6">
              <h4 className="text-lg font-bold text-on-surface mb-2 truncate">
                {form.name || t("preview.empty")}
              </h4>
              <p className="text-sm text-on-surface-variant mb-6 line-clamp-2">
                {form.description || t("preview.emptyDescription")}
              </p>
              <div className="space-y-2 mb-4">
                <div className="flex justify-between text-sm">
                  <span className="font-semibold text-on-surface">$ 0</span>
                  <span className="text-on-surface-variant">
                    {form.maxCapTrees
                      ? `${t("preview.target")}: $${(
                          maxCap * Number(form.pricePerToken || 0)
                        ).toLocaleString()}`
                      : `${t("preview.target")}: $ —`}
                  </span>
                </div>
                <div className="h-1.5 w-full bg-surface-container-high rounded-full" />
                <div className="text-xs text-on-surface-variant text-right">
                  {t("preview.completed", { pct: 0 })}
                </div>
              </div>
              <div className="flex justify-between items-center py-4 border-t border-surface-container-low">
                <div>
                  <span className="block text-xs text-on-surface-variant uppercase tracking-wide">
                    {t("preview.tokenPrice")}
                  </span>
                  <span className="font-semibold text-on-surface">
                    ${form.pricePerToken || "—"}
                  </span>
                </div>
                <div className="text-right">
                  <span className="block text-xs text-on-surface-variant uppercase tracking-wide">
                    {t("preview.maxSupply")}
                  </span>
                  <span className="font-semibold text-primary">
                    {maxCap ? maxCap.toLocaleString() : "—"}
                  </span>
                </div>
              </div>
            </div>
          </div>

          <div className="mt-6 bg-primary-fixed/20 rounded-xl p-4 flex items-start gap-3 border border-primary/20">
            <svg
              className="text-primary shrink-0"
              width="20"
              height="20"
              viewBox="0 0 24 24"
              fill="currentColor"
            >
              <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z" />
            </svg>
            <p className="text-sm text-on-surface-variant">
              {t("preview.hint")}
            </p>
          </div>
        </div>
      </div>

      <style jsx global>{`
        .input {
          width: 100%;
          padding: 0.75rem 1rem;
          background: var(--color-surface-container-low);
          border: 1px solid rgb(189 202 186 / 0.15);
          border-radius: 0.75rem;
          color: var(--color-on-surface);
          font-size: 0.9375rem;
          transition: all 0.15s;
          outline: none;
        }
        .input:focus {
          border-color: var(--color-primary);
          box-shadow: 0 0 0 3px rgb(0 107 44 / 0.1);
        }
        .input::placeholder {
          color: rgb(62 74 61 / 0.5);
        }
      `}</style>
    </div>
  );
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <div>
      <label className="block text-sm font-semibold text-on-surface mb-2">
        {label}
      </label>
      {children}
      {hint && <p className="text-xs text-on-surface-variant mt-1.5">{hint}</p>}
    </div>
  );
}

function ReviewSection({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-6">
      <h3 className="text-sm font-bold text-on-surface-variant tracking-widest uppercase mb-4">
        {title}
      </h3>
      <div className="space-y-2">{children}</div>
    </div>
  );
}

function ReviewRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between items-baseline py-1.5 border-b border-surface-container-low last:border-0">
      <span className="text-sm text-on-surface-variant">{label}</span>
      <span className="text-sm font-semibold text-on-surface">{value}</span>
    </div>
  );
}

/**
 * Full-screen confirmation after createCampaign lands on-chain. Replaces
 * the entire step-4 review (not a banner below it) so the producer gets
 * one clear next action — "Vai alla campagna" — instead of a wall of
 * tx hashes and an implicit scroll-to-find-the-link.
 */
function DeploySuccessScreen({
  campaign,
  createTx,
  name,
}: {
  campaign: Address;
  createTx: `0x${string}`;
  name: string;
}) {
  const t = useTranslations("create.success");
  return (
    <div className="py-16 flex flex-col items-center text-center max-w-xl mx-auto">
      <div className="w-20 h-20 rounded-full regen-gradient flex items-center justify-center mb-6 shadow-lg shadow-primary/30">
        <svg
          width="40"
          height="40"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="3"
          strokeLinecap="round"
          strokeLinejoin="round"
          className="text-white"
        >
          <path d="M20 6 9 17l-5-5" />
        </svg>
      </div>

      <h1 className="text-3xl md:text-4xl font-bold tracking-tight text-on-surface mb-3">
        {t("title")}
      </h1>
      <p className="text-on-surface-variant mb-10 max-w-md">
        {t("body", { name: name || t("defaultName") })}
      </p>

      <Link
        href={`/campaign/${campaign}`}
        className="regen-gradient text-white rounded-full h-14 px-10 text-base font-semibold hover:opacity-90 transition shadow-lg shadow-primary/20 flex items-center gap-3 mb-4"
      >
        {t("cta")}
        <svg
          width="20"
          height="20"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2.2"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M5 12h14M13 5l7 7-7 7" />
        </svg>
      </Link>

      <a
        href={txUrl(createTx)}
        target="_blank"
        rel="noreferrer"
        className="text-xs text-on-surface-variant hover:text-primary underline"
      >
        {t("viewOnExplorer")}
      </a>
    </div>
  );
}

function StatusBox({
  kind,
  children,
}: {
  kind: "info" | "success" | "error";
  children: React.ReactNode;
}) {
  const styles = {
    info: "bg-primary-fixed/20 text-primary border-primary/20",
    success: "bg-primary-fixed/30 text-primary-container border-primary/30",
    error: "bg-red-50 text-error border-red-200",
  };
  return (
    <div
      className={`rounded-xl p-4 text-sm font-medium border ${styles[kind]}`}
    >
      {children}
    </div>
  );
}

/**
 * FeasibilitySummary — surfaces the implied economics so the producer sees
 * upfront whether their commitment makes sense. Derives:
 *   maxRaise          = maxCapTrees * 1000 * pricePerToken
 *   bps               = annual / maxRaise * 10_000
 *   harvestsToRepay   = ceil(maxRaise / annual)
 *   recommendedColl   = annual * coverageHarvests
 *   coverageEnd       = firstHarvestYear + coverageHarvests - 1
 *   paybackEnd        = firstHarvestYear + harvestsToRepay - 1
 */
function FeasibilitySummary({
  maxCapTrees,
  pricePerToken,
  annualHarvestUsd,
  annualHarvestQty,
  productType,
  firstHarvestYear,
  coverageHarvests,
}: {
  maxCapTrees: string;
  pricePerToken: string;
  annualHarvestUsd: string;
  annualHarvestQty: string;
  productType: string;
  firstHarvestYear: string;
  coverageHarvests: string;
}) {
  const maxRaise = Number(maxCapTrees) * 1000 * Number(pricePerToken);
  const annual = Number(annualHarvestUsd);
  const annualQty = Number(annualHarvestQty);
  const firstYear = Number(firstHarvestYear);
  const cov = Number(coverageHarvests);
  const unit = productUnitLabel(productType);

  if (!(maxRaise > 0 && annual > 0 && firstYear > 0)) return null;

  const yieldPct = (annual / maxRaise) * 100;
  const harvestsToRepay = Math.ceil(maxRaise / annual);
  const recommendedColl = annual * cov;
  const paybackEnd = firstYear + harvestsToRepay - 1;
  const coverageEnd = cov > 0 ? firstYear + cov - 1 : null;
  const pricePerUnit = annualQty > 0 ? annual / annualQty : null;

  const fmt$ = (n: number) =>
    `$${n.toLocaleString(undefined, { maximumFractionDigits: 0 })}`;

  return (
    <div className="rounded-xl border border-primary/30 bg-primary-fixed/30 p-4 mt-2 space-y-3">
      <div className="text-xs font-bold uppercase tracking-wider text-primary">
        Feasibility
      </div>
      <div className="grid grid-cols-2 gap-3 text-sm">
        <Row label="Max raise" value={fmt$(maxRaise)} />
        <Row
          label="Implied yield"
          value={`${yieldPct.toFixed(yieldPct < 1 ? 2 : 1)}%/yr`}
        />
        {pricePerUnit !== null && (
          <Row
            label={`Price per ${unit}`}
            value={`$${pricePerUnit.toLocaleString(undefined, { maximumFractionDigits: pricePerUnit < 10 ? 2 : 0 })}`}
          />
        )}
        <Row
          label="Payback"
          value={`${harvestsToRepay} harvests (${firstYear}–${paybackEnd})`}
        />
        {cov > 0 && (
          <Row
            label="Coverage"
            value={`${cov} harvests (${firstYear}–${coverageEnd})`}
          />
        )}
        {cov > 0 && (
          <Row label="Recommended collateral" value={fmt$(recommendedColl)} />
        )}
      </div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-[10px] uppercase tracking-wider text-on-surface-variant mb-0.5">
        {label}
      </div>
      <div className="font-bold text-on-surface">{value}</div>
    </div>
  );
}

/**
 * CollateralStep — optional pre-funding of the yield reserve right after
 * deploy. Recommended amount = annualHarvestUsd × coverageHarvests; setting
 * it to 0 (or leaving empty) skips the lock and the producer can still add
 * collateral later from /campaign/[address]?tab=manage. The actual approve +
 * lockCollateral happens in handleDeploy AFTER createCampaign + setMetadata
 * + addAcceptedToken complete.
 */
function CollateralStep({
  annualHarvestUsd,
  coverageHarvests,
  maxCapTrees,
  pricePerToken,
  firstHarvestYear,
  value,
  onChange,
}: {
  annualHarvestUsd: string;
  coverageHarvests: string;
  maxCapTrees: string;
  pricePerToken: string;
  firstHarvestYear: string;
  value: string;
  onChange: (v: string) => void;
}) {
  const t = useTranslations("create.step4");
  const tBuy = useTranslations("detail.buy");
  const tTx = useTranslations("tx");
  const annual = Number(annualHarvestUsd || "0");
  const cov = Number(coverageHarvests || "0");
  const recommended = annual * cov;
  const firstYear = Number(firstHarvestYear || "0");
  const coverageEnd = cov > 0 && firstYear > 0 ? firstYear + cov - 1 : null;
  const maxRaise =
    Number(maxCapTrees || "0") * 1000 * Number(pricePerToken || "0");
  const yieldPct = annual > 0 && maxRaise > 0 ? (annual / maxRaise) * 100 : 0;

  const { address: user } = useAccount();
  const { writeContractAsync } = useWriteContract();
  const notify = useTxNotify();
  const [minting, setMinting] = useState(false);

  const { usdc: usdcAddress } = getAddresses();

  /**
   * Live mUSDC balance read for the connected wallet. Refetches every 8s
   * so a fresh mint via the faucet button surfaces in the cap without
   * a manual reload. Used as a hard ceiling on the input — entering a
   * number > balance is silently clamped, and the parent's `isStepValid`
   * gate (in the outer component) blocks "Avanti" when value > balance.
   */
  const { data: balanceRaw, refetch: refetchBalance } = useReadContract({
    address: usdcAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: user ? [user] : undefined,
    query: { enabled: !!user, refetchInterval: 8_000 },
  });
  const balance6 = (balanceRaw as bigint | undefined) ?? 0n;
  const balanceUsd = Number(balance6) / 1e6;
  const enteredUsd = Number(value || "0");
  // The user can type any digit string; we display whatever they typed
  // but the parent state has been clamped via onChange below. So this
  // is just a safety net for stale UI flashes.
  const overBalance = enteredUsd > balanceUsd;

  const handleMint = async () => {
    if (!user) return;
    try {
      setMinting(true);
      const hash = await writeContractAsync({
        address: usdcAddress,
        abi: mockUsdcMintAbi,
        functionName: "mint",
        args: [user, MOCK_USDC_MINT_AMOUNT],
      });
      const r = await waitForTx(hash);
      if (r.status !== "success") throw new Error("mint reverted");
      notify.success(tTx("mintConfirmed"), hash);
      await refetchBalance();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!/user (rejected|denied)/i.test(msg)) {
        notify.error(tTx("mintFailed"), err);
      }
    } finally {
      setMinting(false);
    }
  };

  const fmt$ = (n: number) =>
    `$${n.toLocaleString(undefined, { maximumFractionDigits: 0 })}`;

  return (
    <div className="space-y-6">
      {/* Recap of what they committed in step 2 — sets the context for the
          recommended amount below. Helps the producer see the link between
          coverage horizon and lock size. */}
      {annual > 0 && (
        <div className="rounded-xl border border-primary/30 bg-primary-fixed/30 p-4 grid grid-cols-2 gap-3 text-sm">
          <Row label={t("commitmentLabel")} value={`${fmt$(annual)} / yr`} />
          <Row
            label={t("yieldLabel")}
            value={`${yieldPct.toFixed(yieldPct < 1 ? 2 : 1)}%/yr`}
          />
          {cov > 0 && coverageEnd !== null ? (
            <Row
              label={t("coverageLabel")}
              value={`${cov} (${firstYear}–${coverageEnd})`}
            />
          ) : (
            <Row label={t("coverageLabel")} value={t("noCoverage")} />
          )}
          {recommended > 0 && (
            <Row
              label={t("recommendedLabel")}
              value={fmt$(recommended)}
            />
          )}
        </div>
      )}

      <div>
        <div className="flex justify-between items-center mb-2 gap-2">
          <label className="block text-sm font-semibold text-on-surface">
            {t("amount")}
          </label>
          <div className="flex items-center gap-2">
            {/* Live wallet balance — clickable as a Max shortcut. Floors to
                whole USD because the input is whole-dollar (USDC has 6 dec
                but we don't want to ship "0.999999" via comma-strip). */}
            {user && (
              <button
                type="button"
                onClick={() =>
                  onChange(String(Math.floor(balanceUsd)))
                }
                className="text-xs text-on-surface-variant hover:text-primary transition-colors"
                title={t("useMax")}
              >
                {t("balance", {
                  amount: balanceUsd.toLocaleString(undefined, {
                    maximumFractionDigits: 2,
                  }),
                })}
              </button>
            )}
            {/* Testnet faucet — mints 10k mUSDC directly from this step so
                the producer can fund the lockCollateral tx without leaving
                /create. On mainnet getAddresses().usdc is the real USDC and
                the call would revert (no public mint), so the button
                surfaces only when the chain is the Sepolia mock. */}
            {user && CHAIN_ID === 84532 && (
              <button
                type="button"
                onClick={handleMint}
                disabled={minting}
                title={tBuy("mintHint")}
                className="text-xs font-semibold text-primary hover:bg-primary-fixed/30 px-2 py-1 rounded-full transition-colors disabled:opacity-50 flex items-center gap-1"
              >
                {minting ? <Spinner size={12} /> : <span>+</span>}
                {tBuy("mint", { amount: "10,000" })}
              </button>
            )}
          </div>
        </div>
        <div className="relative">
          {/* Right-side combined adornment "$ USDC" — mirrors the harvest
              USD input pattern on step 2 ($ / YR) and removes the left $
              that crowded the digits. */}
          <input
            type="text"
            inputMode="numeric"
            pattern="[0-9,]*"
            value={
              !value || value === "0"
                ? ""
                : Number(value).toLocaleString("en-US")
            }
            onChange={(e) => {
              const raw = e.target.value.replace(/[^\d]/g, "");
              // Hard-cap at the wallet balance — entering a higher number
              // would only produce a guaranteed lockCollateral revert at
              // submit time. Cheaper to clamp at the keystroke.
              const n = Number(raw || "0");
              const capped =
                user && n > balanceUsd
                  ? String(Math.floor(balanceUsd))
                  : raw;
              onChange(capped || "0");
            }}
            placeholder="0"
            className={`input pr-24 font-semibold tabular-nums ${overBalance ? "border-error" : ""}`}
          />
          <span className="absolute inset-y-0 right-0 w-24 flex items-center justify-center border-l border-outline-variant/15 text-[11px] font-semibold uppercase tracking-wider text-on-surface-variant pointer-events-none">
            $ USDC
          </span>
        </div>
        {overBalance ? (
          <p className="text-xs text-error mt-1.5">
            {t("overBalance", {
              amount: balanceUsd.toLocaleString(undefined, {
                maximumFractionDigits: 2,
              }),
            })}
          </p>
        ) : (
          <p className="text-xs text-on-surface-variant mt-1.5">
            {recommended > 0
              ? t("amountHint", {
                  recommended: fmt$(recommended),
                  annual: annual.toLocaleString(),
                  coverage: cov.toString(),
                })
              : t("amountHintNoCoverage")}
          </p>
        )}
      </div>

      {/* Quick-pick chip for the recommended amount — clamps at balance so
          a producer with insufficient mUSDC can't blindly "Use recommended"
          and then watch the lockCollateral tx revert. */}
      {recommended > 0 && (
        <button
          type="button"
          onClick={() =>
            onChange(String(Math.min(recommended, Math.floor(balanceUsd))))
          }
          disabled={!user || balanceUsd <= 0}
          className="text-xs font-semibold text-primary hover:underline disabled:opacity-50 disabled:no-underline disabled:cursor-not-allowed"
        >
          {t("useRecommended", {
            amount: fmt$(Math.min(recommended, Math.floor(balanceUsd))),
          })}
        </button>
      )}

      <div className="rounded-xl border border-outline-variant/15 bg-surface-container-lowest p-4 space-y-2">
        <p className="text-xs text-on-surface-variant">{t("skipNote")}</p>
        {Number(value || "0") > 0 && (
          <p className="text-xs text-on-surface-variant">
            <span className="font-semibold text-on-surface">
              {t("extraSignaturesLabel")}:
            </span>{" "}
            {t("extraSignatures")}
          </p>
        )}
      </div>
    </div>
  );
}
