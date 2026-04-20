"use client";

import { useState, useMemo } from "react";
import { useTranslations } from "next-intl";
import { useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { waitForTransactionReceipt } from "@wagmi/core";
import { formatUnits, parseUnits, zeroAddress, type Address } from "viem";
import { abis, getAddresses, CHAIN_ID } from "@/contracts";
import {
  KNOWN_TOKENS,
  PRICING_MODE_ENUM,
  resolveTokenAddress,
} from "@/contracts/tokens";
import { config } from "@/app/providers";
import { erc20Abi } from "@/contracts/erc20";
import { useCampaignSeasons, type SubgraphSeason } from "@/lib/subgraph";
import { fetchSnapshot, generateMerkleTree } from "@/lib/api";
import { Spinner } from "./Spinner";
import { useTxNotify } from "@/lib/useTxNotify";

const campaignAbi = abis.Campaign as never;

interface Props {
  campaignAddress: Address;
  harvestManager: Address;
  stakingVault: Address;
  /** Campaign.state enum — 0=Funding, 1=Active, 2=Buyback, 3=Ended */
  currentState: number;
  minProductClaim: bigint;
  seasonDuration: bigint;
}

const harvestAbi = abis.HarvestManager as never;
const USDC_DECIMALS = 6;

/**
 * Producer-only dashboard for post-harvest ops. The innovative part of
 * GrowFi is the coordinated commit/deposit/claim dance between holder and
 * producer — here the producer sees their side of it:
 *
 *   - Every reported season's USDC shortfall (owed − deposited)
 *   - Deposit deadline countdown
 *   - One-tap approve + depositUSDC with exact remainingDepositGross pre-filled
 *
 * Season lifecycle controls (start/end season, report harvest) will land
 * in a follow-up — this first slice focuses on the actual payment step
 * that holders are waiting on.
 */
export function ProducerManagePanel({
  campaignAddress,
  harvestManager,
  stakingVault,
  currentState,
  minProductClaim,
  seasonDuration,
}: Props) {
  const t = useTranslations("detail.manage");
  const { data: seasons, refetch: refetchSeasons } =
    useCampaignSeasons(campaignAddress);

  // Show all reported seasons, not only those with outstanding USDC: the
  // producer wants feedback even when nobody has committed yet ("harvest
  // reported, no claims pending") per REDEEM_2STEP §Producer state machine.
  const reportedSeasons = (seasons ?? []).filter((s) => s.reported);
  // Seasons that ended but haven't been reported yet — producer action
  // required before any holder can redeem product or USDC.
  const pendingReport = (seasons ?? []).filter(
    (s) => !s.active && !s.reported,
  );

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <div className="mb-6">
        <h2 className="text-2xl font-bold tracking-tight text-on-surface mb-2">
          {t("title")}
        </h2>
        <p className="text-sm text-on-surface-variant">{t("subtitle")}</p>
      </div>

      <LifecycleSection
        campaignAddress={campaignAddress}
        stakingVault={stakingVault}
        currentState={currentState}
        seasons={seasons ?? []}
        seasonDuration={seasonDuration}
        onChange={() => refetchSeasons()}
      />

      {pendingReport.length > 0 && (
        <section className="mt-8">
          <h3 className="text-sm font-bold text-on-surface-variant uppercase tracking-wider mb-4">
            {t("pendingReportTitle")}
          </h3>
          <div className="space-y-4">
            {pendingReport.map((season) => (
              <ReportHarvestCard
                key={season.id}
                campaignAddress={campaignAddress}
                harvestManager={harvestManager}
                season={season}
                minProductClaim={minProductClaim}
                onReported={() => refetchSeasons()}
              />
            ))}
          </div>
        </section>
      )}

      <section className="mt-8">
        <h3 className="text-sm font-bold text-on-surface-variant uppercase tracking-wider mb-4">
          {t("acceptedTokensTitle")}
        </h3>
        <AcceptedTokensManager campaignAddress={campaignAddress} />
      </section>

      <section className="mt-8">
        <h3 className="text-sm font-bold text-on-surface-variant uppercase tracking-wider mb-4">
          {t("usdcObligationsTitle")}
        </h3>
        {reportedSeasons.length === 0 ? (
          <div className="bg-surface-container-low rounded-xl p-6 text-center text-sm text-on-surface-variant">
            {t("noObligations")}
          </div>
        ) : (
          <div className="space-y-4">
            {reportedSeasons.map((season) => (
              <ObligationCard
                key={season.id}
                season={season}
                harvestManager={harvestManager}
              />
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

/**
 * Let the producer add or remove payment tokens after the campaign is
 * already live. Reads getAcceptedTokens + tokenConfigs to render the
 * current whitelist, each entry has a Remove button. Add form picks from
 * KNOWN_TOKENS (same curated list used in /create) and signs
 * addAcceptedToken. Both flows use the imperative sig→chain pattern.
 */
function AcceptedTokensManager({
  campaignAddress,
}: {
  campaignAddress: Address;
}) {
  const t = useTranslations("detail.manage.tokens");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { writeContractAsync } = useWriteContract();

  const { data: acceptedAddresses, refetch: refetchAccepted } = useReadContract(
    {
      address: campaignAddress,
      abi: campaignAbi,
      functionName: "getAcceptedTokens",
      query: { refetchInterval: 20_000 },
    },
  ) as { data: Address[] | undefined; refetch: () => void };

  const symbolContracts = useMemo(() => {
    if (!acceptedAddresses) return [];
    return acceptedAddresses.flatMap((addr) => [
      { address: addr, abi: erc20Abi, functionName: "symbol" },
      {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "tokenConfigs",
        args: [addr],
      },
    ]);
  }, [acceptedAddresses, campaignAddress]);

  const { data: symbolData } = useReadContracts({
    contracts: symbolContracts as never,
    query: { enabled: symbolContracts.length > 0 },
  });

  type MaybeResult = { result?: unknown };
  const results = (symbolData ?? []) as readonly MaybeResult[];

  const accepted = useMemo(() => {
    if (!acceptedAddresses) return [];
    return acceptedAddresses.map((addr, i) => {
      const symbol = (results[i * 2]?.result as string | undefined) ?? "?";
      // tokenConfigs returns (PricingMode, fixedRate, oracleFeed, paymentDecimals, active)
      const cfg = results[i * 2 + 1]?.result as
        | readonly [number, bigint, Address, number, boolean]
        | undefined;
      const pricingMode = cfg?.[0] ?? 0;
      return { address: addr, symbol, pricingMode };
    });
  }, [acceptedAddresses, results]);

  const usedSymbols = new Set(
    accepted.map((a) => {
      const match = KNOWN_TOKENS.find(
        (k) => resolveLower(k) === a.address.toLowerCase(),
      );
      return match?.symbol ?? "";
    }),
  );
  const nextAvailable = KNOWN_TOKENS.find(
    (k) => k.enabled && !usedSymbols.has(k.symbol),
  );

  const [addSymbol, setAddSymbol] = useState<string>(
    nextAvailable?.symbol ?? "",
  );
  const [addRate, setAddRate] = useState("");
  const [pending, setPending] = useState<
    | null
    | { kind: "add"; phase: "sig" | "chain" }
    | { kind: "remove"; token: Address; phase: "sig" | "chain" }
  >(null);
  const [error, setError] = useState<string | null>(null);

  const handleError = (err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    if (!/user (rejected|denied)/i.test(msg)) setError(msg);
    console.error(err);
  };

  const handleRemove = async (token: Address) => {
    setError(null);
    setPending({ kind: "remove", token, phase: "sig" });
    try {
      const hash = await writeContractAsync({
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "removeAcceptedToken",
        args: [token],
      });
      setPending({ kind: "remove", token, phase: "chain" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("remove reverted");
      await refetchAccepted();
      notify.success(tx("removeTokenConfirmed"), hash);
    } catch (err) {
      handleError(err);
      notify.error(tx("removeTokenFailed"), err);
    } finally {
      setPending(null);
    }
  };

  const handleAdd = async () => {
    setError(null);
    const known = KNOWN_TOKENS.find((k) => k.symbol === addSymbol);
    if (!known) return;
    try {
      const tokenAddress = resolveTokenAddress(known, CHAIN_ID);
      const pricingMode = PRICING_MODE_ENUM[known.defaultMode];
      const fixedRate =
        known.defaultMode === "fixed"
          ? parseUnits(addRate || "0", known.decimals)
          : 0n;
      const oracleFeed =
        known.defaultMode === "oracle"
          ? (known.oracleFeed[CHAIN_ID] ?? zeroAddress)
          : zeroAddress;
      if (known.defaultMode === "fixed" && fixedRate === 0n) {
        throw new Error(t("rateRequired", { symbol: known.symbol }));
      }
      if (known.defaultMode === "oracle" && oracleFeed === zeroAddress) {
        throw new Error(t("noOracleFeed", { symbol: known.symbol }));
      }

      setPending({ kind: "add", phase: "sig" });
      const hash = await writeContractAsync({
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "addAcceptedToken",
        args: [tokenAddress, pricingMode, fixedRate, oracleFeed],
      });
      setPending({ kind: "add", phase: "chain" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("add reverted");
      setAddRate("");
      await refetchAccepted();
      notify.success(tx("addTokenConfirmed"), hash);
    } catch (err) {
      handleError(err);
      notify.error(tx("addTokenFailed"), err);
    } finally {
      setPending(null);
    }
  };

  const selectedKnown = KNOWN_TOKENS.find((k) => k.symbol === addSymbol);
  const isOracle = selectedKnown?.defaultMode === "oracle";
  const addBusy = pending?.kind === "add";

  return (
    <div className="space-y-3">
      {accepted.length === 0 ? (
        <div className="bg-surface-container-low rounded-xl p-4 text-sm text-on-surface-variant">
          {t("empty")}
        </div>
      ) : (
        accepted.map((tok) => {
          const removing =
            pending?.kind === "remove" && pending.token === tok.address;
          return (
            <div
              key={tok.address}
              className="bg-surface-container-low rounded-xl p-4 flex items-center justify-between gap-4"
            >
              <div className="flex items-center gap-3 min-w-0">
                <div className="w-8 h-8 rounded-full bg-primary-fixed flex items-center justify-center shrink-0">
                  <span className="text-xs font-bold text-on-primary-fixed-variant">
                    {tok.symbol.slice(0, 2)}
                  </span>
                </div>
                <div className="min-w-0">
                  <div className="text-sm font-semibold text-on-surface">
                    {tok.symbol}
                  </div>
                  <div className="text-[11px] text-on-surface-variant">
                    {tok.pricingMode === 1 ? t("oracle") : t("fixed")}
                    <span className="mx-1">·</span>
                    <span className="font-mono">
                      {tok.address.slice(0, 6)}…{tok.address.slice(-4)}
                    </span>
                  </div>
                </div>
              </div>
              <button
                onClick={() => handleRemove(tok.address)}
                disabled={pending !== null}
                className="bg-red-50 text-error border border-red-200 rounded-full px-3 h-9 text-xs font-semibold hover:bg-red-100 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-1.5"
              >
                {removing && <Spinner size={12} />}
                {removing && pending.phase === "sig"
                  ? t("removeSig")
                  : removing && pending.phase === "chain"
                    ? t("removeChain")
                    : t("remove")}
              </button>
            </div>
          );
        })
      )}

      {nextAvailable && (
        <div className="bg-surface-container-low rounded-xl p-4 border border-outline-variant/15">
          <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-3">
            {t("addTitle")}
          </div>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3 mb-3">
            <select
              value={addSymbol}
              onChange={(e) => setAddSymbol(e.target.value)}
              disabled={addBusy}
              className="bg-surface-container rounded-lg px-3 py-2 text-sm border border-outline-variant/15 outline-none focus:border-primary/50"
            >
              {KNOWN_TOKENS.map((k) => {
                const alreadyUsed = usedSymbols.has(k.symbol);
                return (
                  <option
                    key={k.symbol}
                    value={k.symbol}
                    disabled={!k.enabled || alreadyUsed}
                  >
                    {k.symbol} — {k.name}
                    {!k.enabled ? ` (${t("comingSoon")})` : ""}
                    {alreadyUsed ? ` (${t("alreadyAdded")})` : ""}
                  </option>
                );
              })}
            </select>
            {!isOracle ? (
              <input
                type="number"
                step="0.000001"
                value={addRate}
                onChange={(e) => setAddRate(e.target.value)}
                placeholder={t("ratePlaceholder", { symbol: addSymbol })}
                disabled={addBusy}
                className="bg-surface-container rounded-lg px-3 py-2 text-sm border border-outline-variant/15 outline-none focus:border-primary/50"
              />
            ) : (
              <div className="bg-surface-container rounded-lg px-3 py-2 text-xs font-mono text-on-surface-variant flex items-center">
                {selectedKnown?.oracleFeed[CHAIN_ID] ??
                  t("noFeedOnChain")}
              </div>
            )}
          </div>
          <button
            onClick={handleAdd}
            disabled={pending !== null || (!isOracle && !addRate)}
            className="regen-gradient text-white rounded-full h-10 px-5 text-sm font-semibold hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
          >
            {addBusy && <Spinner size={14} />}
            {addBusy && pending.phase === "sig"
              ? t("addSig")
              : addBusy && pending.phase === "chain"
                ? t("addChain")
                : t("addCta")}
          </button>
        </div>
      )}

      {error && (
        <div className="bg-red-50 border border-red-200 text-error rounded-lg p-3 text-xs break-words">
          {error}
        </div>
      )}
    </div>
  );
}

function resolveLower(token: (typeof KNOWN_TOKENS)[number]): string {
  const addr = token.addresses[CHAIN_ID];
  return addr ? addr.toLowerCase() : "";
}

/**
 * Lifecycle controls — one row per action the producer can take right now.
 * Buttons are gated by:
 *   - current campaign state (Funding / Active / Buyback / Ended)
 *   - whether a season is currently running (from StakingVault.currentSeasonId
 *     combined with seasons[id].active)
 * Each action uses the same imperative sig→chain→refetch pattern as the rest
 * of the app so the producer never sees a stuck spinner.
 */
function LifecycleSection({
  campaignAddress,
  stakingVault,
  currentState,
  seasons,
  seasonDuration,
  onChange,
}: {
  campaignAddress: Address;
  stakingVault: Address;
  currentState: number;
  seasons: SubgraphSeason[];
  seasonDuration: bigint;
  onChange: () => void;
}) {
  const t = useTranslations("detail.manage");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { writeContractAsync } = useWriteContract();

  const { data: currentSeasonIdRaw, refetch: refetchSeasonId } =
    useReadContract({
      address: stakingVault,
      abi: abis.StakingVault as never,
      functionName: "currentSeasonId",
      query: { refetchInterval: 15_000 },
    }) as { data: bigint | undefined; refetch: () => void };

  const currentSeasonId = currentSeasonIdRaw ?? 0n;
  const currentSeason = seasons.find(
    (s) => BigInt(s.seasonId) === currentSeasonId,
  );
  const hasActiveSeason = !!currentSeason?.active;

  // Suggest ending the season once its on-chain duration has elapsed, so
  // the producer knows it's time to report harvest.
  const seasonStartTs = currentSeason?.startTime
    ? Number(currentSeason.startTime)
    : 0;
  const nowTs = Math.floor(Date.now() / 1000);
  const seasonElapsed =
    hasActiveSeason &&
    seasonStartTs > 0 &&
    BigInt(nowTs - seasonStartTs) >= seasonDuration;

  const [pendingAction, setPendingAction] = useState<
    | null
    | { action: "activate" | "startSeason" | "endSeason" | "endCampaign"; phase: "sig" | "chain" }
  >(null);
  const [error, setError] = useState<string | null>(null);

  const runAction = async (
    action: "activate" | "startSeason" | "endSeason" | "endCampaign",
    args: Parameters<typeof writeContractAsync>[0],
  ) => {
    setError(null);
    setPendingAction({ action, phase: "sig" });
    try {
      const hash = await writeContractAsync(args);
      setPendingAction({ action, phase: "chain" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("Transaction reverted");
      onChange();
      refetchSeasonId();
      notify.success(tx(`${action}Confirmed`), hash);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!/user (rejected|denied)/i.test(msg)) setError(msg);
      notify.error(tx(`${action}Failed`), err);
      console.error(err);
    } finally {
      setPendingAction(null);
    }
  };

  const busyAction = pendingAction?.action ?? null;
  const anyBusy = pendingAction !== null;

  const stateKey =
    (["funding", "active", "buyback", "ended"] as const)[currentState] ??
    "funding";

  const nextSeasonId = currentSeasonId + 1n;

  const actions: Array<{
    action: "activate" | "startSeason" | "endSeason" | "endCampaign";
    label: string;
    sigLabel: string;
    chainLabel: string;
    show: boolean;
    args: Parameters<typeof writeContractAsync>[0];
    variant: "primary" | "outline" | "danger";
    hint?: string;
  }> = [
    {
      action: "activate",
      label: t("actions.activate"),
      sigLabel: t("actions.activateSig"),
      chainLabel: t("actions.activateChain"),
      show: currentState === 0,
      variant: "primary",
      hint: t("actions.activateHint"),
      args: {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "activateCampaign",
      },
    },
    {
      action: "startSeason",
      label: t("actions.startSeason", { id: nextSeasonId.toString() }),
      sigLabel: t("actions.startSeasonSig"),
      chainLabel: t("actions.startSeasonChain"),
      show: currentState === 1 && !hasActiveSeason,
      variant: "primary",
      hint: t("actions.startSeasonHint"),
      args: {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "startSeason",
        args: [nextSeasonId],
      },
    },
    {
      action: "endSeason",
      label: t("actions.endSeason", { id: currentSeasonId.toString() }),
      sigLabel: t("actions.endSeasonSig"),
      chainLabel: t("actions.endSeasonChain"),
      show: currentState === 1 && hasActiveSeason,
      variant: seasonElapsed ? "primary" : "outline",
      hint: seasonElapsed
        ? t("actions.endSeasonHintReady")
        : t("actions.endSeasonHintEarly"),
      args: {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "endSeason",
      },
    },
    {
      action: "endCampaign",
      label: t("actions.endCampaign"),
      sigLabel: t("actions.endCampaignSig"),
      chainLabel: t("actions.endCampaignChain"),
      show: currentState === 1,
      variant: "danger",
      hint: t("actions.endCampaignHint"),
      args: {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "endCampaign",
      },
    },
  ];

  const variantClass = (v: "primary" | "outline" | "danger") =>
    v === "primary"
      ? "regen-gradient text-white"
      : v === "danger"
        ? "bg-red-50 text-error border border-red-200"
        : "bg-surface-container-low text-on-surface border border-outline-variant/30";

  return (
    <div className="bg-surface-container-low rounded-xl p-5 border border-outline-variant/15">
      <div className="flex items-center justify-between mb-4">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            {t("campaignState")}
          </div>
          <div className="flex items-center gap-3">
            <div className="text-lg font-bold text-on-surface">
              {t(`states.${stateKey}`)}
            </div>
            {hasActiveSeason && (
              <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-[11px] font-semibold uppercase tracking-wider bg-primary-fixed text-on-primary-fixed-variant">
                {t("seasonRunning", { id: currentSeasonId.toString() })}
              </span>
            )}
            {!hasActiveSeason && currentSeasonId > 0n && currentState === 1 && (
              <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-[11px] font-semibold uppercase tracking-wider bg-surface-container-high text-on-surface-variant">
                {t("lastSeason", { id: currentSeasonId.toString() })}
              </span>
            )}
          </div>
        </div>
        <a
          href={`https://sepolia.basescan.org/address/${campaignAddress}`}
          target="_blank"
          rel="noreferrer"
          className="text-xs text-primary font-semibold hover:underline whitespace-nowrap"
        >
          {t("viewOnScan")} →
        </a>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {actions
          .filter((a) => a.show)
          .map((a) => {
            const isBusy = busyAction === a.action;
            const phase = pendingAction?.phase;
            const label = isBusy
              ? phase === "sig"
                ? a.sigLabel
                : a.chainLabel
              : a.label;
            return (
              <div key={a.action} className="flex flex-col gap-1">
                <button
                  onClick={() => runAction(a.action, a.args)}
                  disabled={anyBusy}
                  className={`h-11 rounded-full font-semibold text-sm hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2 px-4 ${variantClass(a.variant)}`}
                >
                  {isBusy && <Spinner size={14} />}
                  {label}
                </button>
                {a.hint && (
                  <p className="text-[11px] text-on-surface-variant px-1">
                    {a.hint}
                  </p>
                )}
              </div>
            );
          })}
      </div>

      {error && (
        <div className="mt-3 bg-red-50 border border-red-200 text-error rounded-lg p-3 text-xs break-words">
          {error}
        </div>
      )}
    </div>
  );
}

/**
 * Report-harvest workflow. Fetches a snapshot of every YIELD holder at
 * season-end, generates a Merkle tree for product redemption, then signs
 * HarvestManager.reportHarvest. Producer can re-fetch the snapshot (in
 * case indexing was behind) and override totalValueUSD / totalProductUnits
 * before committing.
 */
function ReportHarvestCard({
  campaignAddress,
  harvestManager,
  season,
  minProductClaim,
  onReported,
}: {
  campaignAddress: Address;
  harvestManager: Address;
  season: SubgraphSeason;
  minProductClaim: bigint;
  onReported: () => void;
}) {
  const t = useTranslations("detail.manage");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { writeContractAsync } = useWriteContract();

  const [totalValueUSD, setTotalValueUSD] = useState("");
  const [totalProductUnits, setTotalProductUnits] = useState("");

  const [stage, setStage] = useState<
    | { kind: "idle" }
    | { kind: "snapshot" }
    | { kind: "merkle" }
    | { kind: "report-sig" }
    | { kind: "report-chain" }
    | { kind: "success"; hash: `0x${string}` }
    | { kind: "error"; message: string }
  >({ kind: "idle" });
  const [snapshotInfo, setSnapshotInfo] = useState<{
    holderCount: number;
    totalYield: string;
  } | null>(null);

  const busy =
    stage.kind === "snapshot" ||
    stage.kind === "merkle" ||
    stage.kind === "report-sig" ||
    stage.kind === "report-chain";

  const handleReport = async () => {
    try {
      if (!totalValueUSD || Number(totalValueUSD) <= 0) {
        throw new Error(t("errors.valueRequired"));
      }
      if (!totalProductUnits || Number(totalProductUnits) <= 0) {
        throw new Error(t("errors.unitsRequired"));
      }

      // 1. Pull live snapshot of YIELD holders at season close.
      setStage({ kind: "snapshot" });
      const snap = await fetchSnapshot(campaignAddress, season.seasonId);
      setSnapshotInfo({
        holderCount: snap.holders.length,
        totalYield: snap.totalYield,
      });
      if (snap.holders.length === 0) {
        throw new Error(t("errors.noHolders"));
      }

      // 2. Build a Merkle tree scoped to this season → root for reportHarvest.
      setStage({ kind: "merkle" });
      const productUnitsWei = parseUnits(totalProductUnits, 18);
      const merkle = await generateMerkleTree({
        campaign: campaignAddress,
        seasonId: season.seasonId,
        totalProductUnits: productUnitsWei.toString(),
        holders: snap.holders,
        minProductClaim: minProductClaim.toString(),
      });

      // 3. reportHarvest on-chain.
      setStage({ kind: "report-sig" });
      const valueUsdWei = parseUnits(totalValueUSD, 18);
      const hash = await writeContractAsync({
        address: harvestManager,
        abi: abis.HarvestManager as never,
        functionName: "reportHarvest",
        args: [
          BigInt(season.seasonId),
          valueUsdWei,
          merkle.root,
          productUnitsWei,
        ],
      });

      setStage({ kind: "report-chain" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") {
        throw new Error("reportHarvest reverted");
      }

      setStage({ kind: "success", hash });
      onReported();
      notify.success(tx("reportHarvestConfirmed"), hash);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (/user (rejected|denied)/i.test(msg)) {
        setStage({ kind: "idle" });
      } else {
        setStage({ kind: "error", message: msg });
        notify.error(tx("reportHarvestFailed"), err);
      }
    }
  };

  const stageLabel =
    stage.kind === "snapshot"
      ? t("report.fetchingSnapshot")
      : stage.kind === "merkle"
        ? t("report.generatingMerkle")
        : stage.kind === "report-sig"
          ? t("report.reportSig")
          : stage.kind === "report-chain"
            ? t("report.reportChain")
            : t("report.cta");

  return (
    <div className="bg-surface-container-low rounded-xl p-5 border border-outline-variant/15">
      <div className="flex items-start justify-between mb-3">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            {t("seasonLabel", { id: season.seasonId })}
          </div>
          <div className="text-lg font-bold text-on-surface">
            {t("report.title")}
          </div>
        </div>
        <span className="inline-flex items-center px-3 py-1 rounded-full text-[11px] font-semibold uppercase tracking-wider bg-amber-100 text-amber-900">
          {t("report.unreported")}
        </span>
      </div>

      <p className="text-xs text-on-surface-variant mb-4">
        {t("report.subtitle")}
      </p>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-3 mb-3">
        <div className="bg-surface-container rounded-xl p-3">
          <label className="text-[11px] font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("report.totalValueUSD")}
          </label>
          <div className="flex items-center gap-1 mt-1">
            <span className="text-xl font-bold text-on-surface">$</span>
            <input
              type="number"
              step="0.01"
              value={totalValueUSD}
              onChange={(e) => setTotalValueUSD(e.target.value)}
              placeholder="0"
              disabled={busy}
              className="flex-1 bg-transparent border-none outline-none text-xl font-bold text-on-surface p-0"
            />
          </div>
          <p className="text-[11px] text-on-surface-variant mt-1">
            {t("report.totalValueUSDHint")}
          </p>
        </div>
        <div className="bg-surface-container rounded-xl p-3">
          <label className="text-[11px] font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("report.totalProductUnits")}
          </label>
          <input
            type="number"
            step="0.01"
            value={totalProductUnits}
            onChange={(e) => setTotalProductUnits(e.target.value)}
            placeholder="0"
            disabled={busy}
            className="w-full mt-1 bg-transparent border-none outline-none text-xl font-bold text-on-surface p-0"
          />
          <p className="text-[11px] text-on-surface-variant mt-1">
            {t("report.totalProductUnitsHint")}
          </p>
        </div>
      </div>

      {snapshotInfo && (
        <div className="bg-primary-fixed/20 border border-primary/20 rounded-lg p-3 mb-3 text-xs text-on-surface">
          {t("report.snapshotPreview", {
            holders: snapshotInfo.holderCount,
            yield: Number(
              formatUnits(BigInt(snapshotInfo.totalYield), 18),
            ).toLocaleString(undefined, { maximumFractionDigits: 2 }),
          })}
        </div>
      )}

      <button
        onClick={handleReport}
        disabled={busy}
        className="w-full regen-gradient text-white rounded-full h-11 font-semibold text-sm hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
      >
        {busy && <Spinner size={16} />}
        {stageLabel}
      </button>

      {stage.kind === "error" && (
        <div className="mt-3 bg-red-50 border border-red-200 text-error rounded-lg p-3 text-xs break-words">
          {stage.message}
        </div>
      )}
      {stage.kind === "success" && (
        <div className="mt-3 bg-primary-fixed/30 text-primary border border-primary/30 rounded-lg p-3 text-xs">
          {t("report.confirmed")}{" "}
          <a
            href={`https://sepolia.basescan.org/tx/${stage.hash}`}
            target="_blank"
            rel="noreferrer"
            className="underline font-semibold"
          >
            {t("viewTx")}
          </a>
        </div>
      )}
    </div>
  );
}

function ObligationCard({
  season,
  harvestManager,
}: {
  season: SubgraphSeason;
  harvestManager: Address;
}) {
  const t = useTranslations("detail.manage");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { usdc: usdcAddress } = getAddresses();
  const { writeContractAsync } = useWriteContract();

  const [amount, setAmount] = useState("");
  const [stage, setStage] = useState<
    | { kind: "idle" }
    | { kind: "approving-sig" }
    | { kind: "approving-chain" }
    | { kind: "depositing-sig" }
    | { kind: "depositing-chain" }
    | { kind: "success"; hash: `0x${string}` }
    | { kind: "error"; message: string }
  >({ kind: "idle" });

  // Subgraph values are 18-dec internal scale; raw USDC is 6-dec.
  const usdcDeposited18 = BigInt(season.usdcDeposited);
  const usdcOwed18 = BigInt(season.usdcOwed);
  const noCommitmentsYet = usdcOwed18 === 0n;
  const depositPct =
    usdcOwed18 > 0n ? Number((usdcDeposited18 * 100n) / usdcOwed18) : 0;
  const fullyDeposited = !noCommitmentsYet && usdcDeposited18 >= usdcOwed18;
  const shortfall18 =
    usdcOwed18 > usdcDeposited18 ? usdcOwed18 - usdcDeposited18 : 0n;

  // Live view: gross USDC (6-dec) the producer still needs to push to
  // fully cover usdcOwed after the 2% fee split.
  const { data: remainingGrossRaw, refetch: refetchRemaining } =
    useReadContract({
      address: harvestManager,
      abi: harvestAbi,
      functionName: "remainingDepositGross",
      args: [BigInt(season.seasonId)],
      query: { refetchInterval: 15_000 },
    }) as { data: bigint | undefined; refetch: () => void };
  const remainingGross = remainingGrossRaw ?? 0n;

  const parsedAmount = useMemo(() => {
    if (!amount || Number(amount) <= 0) return 0n;
    try {
      return parseUnits(amount, USDC_DECIMALS);
    } catch {
      return 0n;
    }
  }, [amount]);

  const now = Math.floor(Date.now() / 1000);
  const deadline = season.usdcDeadline ? Number(season.usdcDeadline) : null;
  const daysLeft =
    deadline !== null ? Math.max(0, Math.ceil((deadline - now) / 86400)) : null;
  const pastDeadline = deadline !== null && now > deadline;

  const handleError = (err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    if (/user (rejected|denied)/i.test(msg)) {
      setStage({ kind: "idle" });
    } else {
      setStage({ kind: "error", message: msg });
    }
  };

  const handleDeposit = async () => {
    try {
      // 1. Approve the HarvestManager to pull `parsedAmount` of USDC
      setStage({ kind: "approving-sig" });
      const approveHash = await writeContractAsync({
        address: usdcAddress,
        abi: erc20Abi,
        functionName: "approve",
        args: [harvestManager, parsedAmount],
      });
      setStage({ kind: "approving-chain" });
      const ar = await waitForTransactionReceipt(config, { hash: approveHash });
      if (ar.status !== "success") throw new Error("Approve reverted");
      notify.success(tx("approvalConfirmed"), approveHash);

      // 2. depositUSDC
      setStage({ kind: "depositing-sig" });
      const depositHash = await writeContractAsync({
        address: harvestManager,
        abi: harvestAbi,
        functionName: "depositUSDC",
        args: [BigInt(season.seasonId), parsedAmount],
      });
      setStage({ kind: "depositing-chain" });
      const dr = await waitForTransactionReceipt(config, {
        hash: depositHash,
      });
      if (dr.status !== "success") throw new Error("Deposit reverted");

      await refetchRemaining();
      setAmount("");
      setStage({ kind: "success", hash: depositHash });
      notify.success(tx("depositUsdcConfirmed"), depositHash);
    } catch (err) {
      handleError(err);
      notify.error(tx("depositUsdcFailed"), err);
    }
  };

  const busy =
    stage.kind === "approving-sig" ||
    stage.kind === "approving-chain" ||
    stage.kind === "depositing-sig" ||
    stage.kind === "depositing-chain";

  const stageLabel =
    stage.kind === "approving-sig"
      ? t("approvingSig")
      : stage.kind === "approving-chain"
        ? t("approvingChain")
        : stage.kind === "depositing-sig"
          ? t("depositingSig")
          : stage.kind === "depositing-chain"
            ? t("depositingChain")
            : t("depositCta");

  // Reported-but-no-commits: producer has nothing to deposit yet, but we
  // still want to surface the season on the dashboard so they know the
  // report went through.
  if (noCommitmentsYet) {
    return (
      <div className="bg-surface-container-low rounded-xl p-5 border border-outline-variant/15">
        <div className="flex items-start justify-between">
          <div>
            <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
              {t("seasonLabel", { id: season.seasonId })}
            </div>
            <div className="text-lg font-bold text-on-surface">
              {t("reportedNoCommits")}
            </div>
            <p className="text-xs text-on-surface-variant mt-1">
              {t("reportedNoCommitsHint")}
            </p>
          </div>
          <span className="inline-flex items-center px-3 py-1 rounded-full text-[11px] font-semibold uppercase tracking-wider bg-surface-container-high text-on-surface-variant">
            {t("reportedBadge")}
          </span>
        </div>
      </div>
    );
  }

  return (
    <div className="bg-surface-container-low rounded-xl p-5 border border-outline-variant/15">
      {/* Shortfall banner: window closed and producer under-delivered */}
      {pastDeadline && !fullyDeposited && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-3 mb-4 text-xs text-error flex items-start gap-2">
          <span className="shrink-0">⚠</span>
          <span>
            {t("shortfallBanner", {
              amount: Number(
                formatUnits(shortfall18, 18),
              ).toLocaleString(undefined, { maximumFractionDigits: 2 }),
            })}
          </span>
        </div>
      )}

      <div className="flex items-start justify-between mb-4">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            {t("seasonLabel", { id: season.seasonId })}
          </div>
          <div className="text-lg font-bold text-on-surface">
            {fullyDeposited
              ? t("obligationSettled")
              : t("obligationOwed", {
                  amount: Number(
                    formatUnits(usdcOwed18 - usdcDeposited18, 18),
                  ).toLocaleString(undefined, { maximumFractionDigits: 2 }),
                })}
          </div>
        </div>
        {fullyDeposited ? (
          <span className="inline-flex items-center px-3 py-1 rounded-full text-[11px] font-semibold uppercase tracking-wider bg-primary-fixed text-on-primary-fixed-variant">
            ✓ {t("settled")}
          </span>
        ) : pastDeadline ? (
          <span className="inline-flex items-center px-3 py-1 rounded-full text-[11px] font-semibold uppercase tracking-wider bg-red-100 text-error">
            {t("deadlinePassed")}
          </span>
        ) : (
          <span className="inline-flex items-center px-3 py-1 rounded-full text-[11px] font-semibold uppercase tracking-wider bg-amber-100 text-amber-900">
            {t("awaitingDeposit")}
          </span>
        )}
      </div>

      {/* Deposit progress */}
      <div className="mb-4">
        <div className="flex justify-between items-center text-xs mb-2">
          <span className="font-semibold text-on-surface-variant uppercase tracking-wider">
            {t("depositProgress")}
          </span>
          <span className="font-semibold text-on-surface">
            ${Number(formatUnits(usdcDeposited18, 18)).toLocaleString()} / $
            {Number(formatUnits(usdcOwed18, 18)).toLocaleString()}
          </span>
        </div>
        <div className="w-full h-2 bg-surface-container-high rounded-full overflow-hidden">
          <div
            className="h-full bg-primary rounded-full transition-all duration-700"
            style={{ width: `${Math.min(depositPct, 100)}%` }}
          />
        </div>
        {deadline !== null && (
          <div className="text-[11px] text-on-surface-variant mt-1.5">
            {pastDeadline
              ? t("deadlinePassedDate", {
                  date: new Date(deadline * 1000).toLocaleDateString(),
                })
              : t("deadlineIn", {
                  date: new Date(deadline * 1000).toLocaleDateString(),
                  days: daysLeft ?? 0,
                })}
          </div>
        )}
      </div>

      {!fullyDeposited && (
        <>
          <div className="bg-surface-container rounded-xl p-4 mb-3">
            <div className="flex justify-between items-center mb-2">
              <label className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
                {t("depositAmount")}
              </label>
              <button
                onClick={() =>
                  setAmount(formatUnits(remainingGross, USDC_DECIMALS))
                }
                className="text-xs text-primary font-semibold hover:underline"
                disabled={busy || remainingGross === 0n}
              >
                {t("fillMax", {
                  amount: Number(
                    formatUnits(remainingGross, USDC_DECIMALS),
                  ).toLocaleString(undefined, { maximumFractionDigits: 2 }),
                })}
              </button>
            </div>
            <div className="flex items-center gap-2">
              <input
                type="number"
                step="0.01"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                placeholder="0.00"
                disabled={busy}
                className="flex-1 bg-transparent border-none outline-none text-2xl font-bold text-on-surface p-0"
              />
              <span className="text-sm font-semibold text-on-surface-variant">
                USDC
              </span>
            </div>
            <p className="text-[11px] text-on-surface-variant mt-2">
              {t("feeNote")}
            </p>
          </div>

          <button
            onClick={handleDeposit}
            disabled={busy || parsedAmount === 0n}
            className="w-full regen-gradient text-white rounded-full h-11 font-semibold text-sm hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
          >
            {busy && <Spinner size={16} />}
            {stageLabel}
          </button>

          {stage.kind === "error" && (
            <div className="mt-3 bg-red-50 border border-red-200 text-error rounded-lg p-3 text-xs break-words">
              {stage.message}
            </div>
          )}
          {stage.kind === "success" && (
            <div className="mt-3 bg-primary-fixed/30 text-primary border border-primary/30 rounded-lg p-3 text-xs">
              {t("depositConfirmed")}{" "}
              <a
                href={`https://sepolia.basescan.org/tx/${stage.hash}`}
                target="_blank"
                rel="noreferrer"
                className="underline font-semibold"
              >
                {t("viewTx")}
              </a>
            </div>
          )}
        </>
      )}
    </div>
  );
}
