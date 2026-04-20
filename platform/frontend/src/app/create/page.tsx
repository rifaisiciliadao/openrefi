"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { useAccount, useWriteContract } from "wagmi";
import { parseUnits, decodeEventLog, zeroAddress, type Address } from "viem";
import { abis, getAddresses, CHAIN_ID } from "@/contracts";
import {
  KNOWN_TOKENS,
  PRICING_MODE_ENUM,
  resolveTokenAddress,
} from "@/contracts/tokens";
import { uploadImage, uploadMetadata } from "@/lib/api";
import { waitForTx } from "@/lib/waitForTx";
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

const STEP_KEYS = ["info", "params", "payments", "confirm"] as const;
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
  const [form, setForm] = useState<FormData>({
    name: "",
    description: "",
    location: "",
    productType: "",
    imageFile: null,
    imagePreview: null,
    pricePerToken: "0.144",
    minCapTrees: "50",
    maxCapTrees: "200",
    fundingDeadline: "",
    seasonDuration: "365",
    minProductClaim: "5",
    tokenSymbol: "OLIVE",
    yieldName: "Olive Oil",
    yieldSymbol: "OIL",
    acceptedTokens: [{ symbol: "mUSDC", humanRate: "0.144" }],
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

  const next = () => setStep((s) => Math.min(4, s + 1));
  const prev = () => setStep((s) => Math.max(1, s - 1));

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
    status.kind === "whitelisting-chain";

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

      // ── 5. Done ───────────────────────────────────────────────────────
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
                    className="input"
                  />
                </Field>
              </div>
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

        {step === 4 && status.kind === "success" && (
          <DeploySuccessScreen
            campaign={status.campaign}
            createTx={status.createTx}
            name={form.name}
          />
        )}

        {step === 4 && status.kind !== "success" && (
          <>
            <div className="mb-10">
              <h1 className="text-2xl md:text-3xl font-bold tracking-tight text-on-surface mb-2">
                {t("step4.title")}
              </h1>
              <p className="text-on-surface-variant">{t("step4.subtitle")}</p>
            </div>

            <div className="space-y-4">
              <ReviewSection title={t("step4.sections.info")}>
                <ReviewRow label={t("step4.rows.name")} value={form.name || "—"} />
                <ReviewRow
                  label={t("step4.rows.symbol")}
                  value={form.tokenSymbol}
                />
                <ReviewRow
                  label={t("step4.rows.location")}
                  value={form.location || "—"}
                />
                <ReviewRow
                  label={t("step4.rows.productType")}
                  value={
                    form.productType
                      ? t(`step1.products.${form.productType}` as never)
                      : "—"
                  }
                />
              </ReviewSection>

              <ReviewSection title={t("step4.sections.tokenomics")}>
                <ReviewRow
                  label={t("step4.rows.price")}
                  value={`$${form.pricePerToken}`}
                />
                <ReviewRow
                  label={t("step4.rows.minCap")}
                  value={t("step4.rows.trees", {
                    count: form.minCapTrees,
                    tokens: minCap.toLocaleString(),
                  })}
                />
                <ReviewRow
                  label={t("step4.rows.maxCap")}
                  value={t("step4.rows.trees", {
                    count: form.maxCapTrees,
                    tokens: maxCap.toLocaleString(),
                  })}
                />
                <ReviewRow
                  label={t("step4.rows.deadline")}
                  value={form.fundingDeadline || "—"}
                />
                <ReviewRow
                  label={t("step4.rows.season")}
                  value={t("step4.rows.days", { count: form.seasonDuration })}
                />
                <ReviewRow
                  label={t("step4.rows.minProduct")}
                  value={t("step4.rows.units", {
                    count: form.minProductClaim,
                  })}
                />
              </ReviewSection>

              <p className="text-xs text-on-surface-variant px-2 mt-2">
                {t("step4.notice")}
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

            {step < 4 ? (
              <button
                onClick={next}
                className="regen-gradient text-white px-8 py-3 rounded-full font-semibold hover:opacity-90 transition shadow-lg shadow-primary/20"
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
