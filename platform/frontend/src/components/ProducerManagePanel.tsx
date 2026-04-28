"use client";

import { useState, useMemo } from "react";
import { useTranslations } from "next-intl";
import { useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { formatUnits, parseUnits, zeroAddress, type Address } from "viem";
import { abis, getAddresses, CHAIN_ID } from "@/contracts";
import {
  KNOWN_TOKENS,
  PRICING_MODE_ENUM,
  resolveTokenAddress,
} from "@/contracts/tokens";
import { erc20Abi } from "@/contracts/erc20";
import { useCampaignSeasons, type SubgraphSeason } from "@/lib/subgraph";
import { fetchSnapshot, generateMerkleTree } from "@/lib/api";
import { Spinner } from "./Spinner";
import { useTxNotify } from "@/lib/useTxNotify";
import { waitForTx } from "@/lib/waitForTx";

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
          {t("parametersTitle")}
        </h3>
        <ParametersEditor
          campaignAddress={campaignAddress}
          currentState={currentState}
        />
      </section>

      <section className="mt-8">
        <h3 className="text-sm font-bold text-on-surface-variant uppercase tracking-wider mb-4">
          Producer Collateral
        </h3>
        <CollateralSection
          campaignAddress={campaignAddress}
          currentState={currentState}
        />
      </section>

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
      const r = await waitForTx(hash);
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
      const r = await waitForTx(hash);
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

  // Live on-chain read of the current season struct: the subgraph lags by a
  // few seconds after endSeason, so relying on `seasons[...]` from props would
  // keep the "End Season" button visible until Goldsky indexes the event.
  // The contract read is instant; we refetch it after every lifecycle tx.
  //
  // Season struct layout (StakingVault.sol):
  //   0: startTime            (uint256)
  //   1: endTime              (uint256)
  //   2: totalYieldMinted     (uint256)
  //   3: rewardPerTokenAtEnd  (uint256)
  //   4: totalYieldOwed       (uint256)
  //   5: active               (bool)
  //   6: existed              (bool)
  const { data: currentSeasonOnChain, refetch: refetchCurrentSeason } =
    useReadContract({
      address: stakingVault,
      abi: abis.StakingVault as never,
      functionName: "seasons",
      args: currentSeasonId > 0n ? [currentSeasonId] : undefined,
      query: { enabled: currentSeasonId > 0n, refetchInterval: 15_000 },
    }) as {
      data:
        | readonly [
            bigint, // 0 startTime
            bigint, // 1 endTime
            bigint, // 2 totalYieldMinted
            bigint, // 3 rewardPerTokenAtEnd
            bigint, // 4 totalYieldOwed
            boolean, // 5 active
            boolean, // 6 existed
          ]
        | undefined;
      refetch: () => void;
    };
  const hasActiveSeason = !!currentSeasonOnChain?.[5];
  const onChainStartTs = currentSeasonOnChain?.[0]
    ? Number(currentSeasonOnChain[0])
    : 0;

  // Live reads of supply + caps: activateCampaign reverts with
  // MinCapNotReached when currentSupply < minCap, so the producer needs to
  // see the real gap before clicking (the on-chain check is the truth; the
  // subgraph would be stale right after a buy).
  const { data: capsData, refetch: refetchCaps } = useReadContracts({
    contracts: [
      { address: campaignAddress, abi: campaignAbi, functionName: "currentSupply" },
      { address: campaignAddress, abi: campaignAbi, functionName: "minCap" },
      { address: campaignAddress, abi: campaignAbi, functionName: "maxCap" },
    ] as never,
    query: { refetchInterval: 15_000 },
  });
  type MaybeCapResult = { result?: unknown };
  const capResults = (capsData ?? []) as readonly MaybeCapResult[];
  const currentSupply =
    (capResults[0]?.result as bigint | undefined) ?? 0n;
  const minCap = (capResults[1]?.result as bigint | undefined) ?? 0n;
  const maxCap = (capResults[2]?.result as bigint | undefined) ?? 0n;
  const minCapReached = minCap > 0n && currentSupply >= minCap;
  const capProgress =
    minCap > 0n ? Number((currentSupply * 100n) / minCap) : 0;

  // Suggest ending the season once its on-chain duration has elapsed, so
  // the producer knows it's time to report harvest.
  const nowTs = Math.floor(Date.now() / 1000);
  const seasonElapsed =
    hasActiveSeason &&
    onChainStartTs > 0 &&
    BigInt(nowTs - onChainStartTs) >= seasonDuration;

  const [pendingAction, setPendingAction] = useState<
    | null
    | { action: "activate" | "startSeason" | "endSeason" | "endCampaign"; phase: "sig" | "chain" }
  >(null);

  const runAction = async (
    action: "activate" | "startSeason" | "endSeason" | "endCampaign",
    args: Parameters<typeof writeContractAsync>[0],
  ) => {
    setPendingAction({ action, phase: "sig" });
    try {
      const hash = await writeContractAsync(args);
      setPendingAction({ action, phase: "chain" });
      const r = await waitForTx(hash);
      if (r.status !== "success") throw new Error("Transaction reverted");
      onChange();
      refetchSeasonId();
      refetchCurrentSeason();
      refetchCaps();
      notify.success(tx(`${action}Confirmed`), hash);
    } catch (err) {
      // Toast (via useTxNotify) surfaces the user-friendly message; raw
      // viem revert dumps inline are unreadable ("+Qrw") and we drop them.
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
    /** False = render the button disabled with `blockedHint` explaining why. */
    canRun: boolean;
    /** Shown when `canRun === false` — tells the producer what to do next. */
    blockedHint?: string;
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
      canRun: minCapReached,
      blockedHint: t("actions.activateBlocked", {
        progress: Math.min(capProgress, 100),
        current: Number(formatUnits(currentSupply, 18)).toLocaleString(
          undefined,
          { maximumFractionDigits: 0 },
        ),
        min: Number(formatUnits(minCap, 18)).toLocaleString(undefined, {
          maximumFractionDigits: 0,
        }),
      }),
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
      canRun: true,
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
      canRun: true,
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
      canRun: true,
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
            const disabled = anyBusy || !a.canRun;
            const hintText =
              !a.canRun && a.blockedHint ? a.blockedHint : a.hint;
            return (
              <div key={a.action} className="flex flex-col gap-1">
                <button
                  onClick={() => runAction(a.action, a.args)}
                  disabled={disabled}
                  className={`h-11 rounded-full font-semibold text-sm hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2 px-4 ${variantClass(a.variant)}`}
                >
                  {isBusy && <Spinner size={14} />}
                  {label}
                </button>
                {hintText && (
                  <p className="text-[11px] text-on-surface-variant px-1">
                    {hintText}
                  </p>
                )}
              </div>
            );
          })}
      </div>
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
      const r = await waitForTx(hash);
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
  // Dust tolerance: the 6→18 decimal conversion inside HarvestManager floors
  // poolPortion to the nearest 1e12 wei-in-18-dec (== 1 USDC-wei in 6-dec),
  // so a producer who fully covers the net pool can still be short by up to
  // ~1 USDC-wei due to the protocol-fee rounding. Treat anything within 1e12
  // of the target as fully deposited in the UI. Matches HarvestPanel.
  const DUST_18 = 10n ** 12n;
  const fullyDeposited =
    !noCommitmentsYet && usdcDeposited18 + DUST_18 >= usdcOwed18;
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
      const ar = await waitForTx(approveHash);
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
      const dr = await waitForTx(depositHash);
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
  // report went through — and surface the numbers they just reported so
  // they can double-check the tx did what they intended (total value, total
  // product units, Merkle root, claim window).
  if (noCommitmentsYet) {
    const reportedValueUsd = season.totalHarvestValueUSD
      ? Number(formatUnits(BigInt(season.totalHarvestValueUSD), 18))
      : null;
    const reportedProductUnits = season.totalProductUnits
      ? Number(formatUnits(BigInt(season.totalProductUnits), 18))
      : null;
    const claimStart = season.claimStart ? Number(season.claimStart) : null;
    const claimEnd = season.claimEnd ? Number(season.claimEnd) : null;
    const depositDeadline = season.usdcDeadline
      ? Number(season.usdcDeadline)
      : null;
    const fmtDate = (ts: number | null) =>
      ts ? new Date(ts * 1000).toLocaleString() : "—";
    const shortRoot = (r: string | null) =>
      r ? `${r.slice(0, 10)}…${r.slice(-8)}` : "—";
    return (
      <div className="bg-surface-container-low rounded-xl p-5 border border-outline-variant/15">
        <div className="flex items-start justify-between mb-4">
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

        {(reportedValueUsd !== null ||
          reportedProductUnits !== null ||
          claimStart !== null ||
          depositDeadline !== null) && (
          <dl className="grid grid-cols-2 gap-x-4 gap-y-2 text-xs border-t border-outline-variant/15 pt-4">
            {reportedValueUsd !== null && (
              <>
                <dt className="text-on-surface-variant">
                  {t("reported.totalValue")}
                </dt>
                <dd className="text-right font-semibold text-on-surface">
                  $
                  {reportedValueUsd.toLocaleString(undefined, {
                    maximumFractionDigits: 2,
                  })}
                </dd>
              </>
            )}
            {reportedProductUnits !== null && (
              <>
                <dt className="text-on-surface-variant">
                  {t("reported.totalUnits")}
                </dt>
                <dd className="text-right font-semibold text-on-surface">
                  {reportedProductUnits.toLocaleString(undefined, {
                    maximumFractionDigits: 2,
                  })}
                </dd>
              </>
            )}
            {claimStart !== null && claimEnd !== null && (
              <>
                <dt className="text-on-surface-variant">
                  {t("reported.claimWindow")}
                </dt>
                <dd className="text-right font-semibold text-on-surface">
                  {fmtDate(claimStart)} → {fmtDate(claimEnd)}
                </dd>
              </>
            )}
            {depositDeadline !== null && (
              <>
                <dt className="text-on-surface-variant">
                  {t("reported.depositDeadline")}
                </dt>
                <dd className="text-right font-semibold text-on-surface">
                  {fmtDate(depositDeadline)}
                </dd>
              </>
            )}
            {season.merkleRoot && (
              <>
                <dt className="text-on-surface-variant">
                  {t("reported.merkleRoot")}
                </dt>
                <dd className="text-right font-mono text-[10px] text-on-surface">
                  {shortRoot(season.merkleRoot)}
                </dd>
              </>
            )}
          </dl>
        )}
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

/**
 * Producer-only inline editor for the 3 campaign parameters the Campaign.sol
 * contract allows to mutate post-deploy: funding deadline, minCap, maxCap.
 *
 *   - setFundingDeadline: Funding-only; extend-only (guard-rails enforced on
 *     both sides — UI disables non-extending values so the tx doesn't waste
 *     gas reverting `DeadlineNotExtended`).
 *   - setMinCap: Funding-only; > currentSupply, ≤ maxCap.
 *   - setMaxCap: Funding or Active; ≥ currentSupply + outstanding queue.
 *
 * Each field submits its own tx (so one mistake doesn't lose the others).
 */
function ParametersEditor({
  campaignAddress,
  currentState,
}: {
  campaignAddress: Address;
  currentState: number;
}) {
  const t = useTranslations("detail.manage.parameters");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { writeContractAsync } = useWriteContract();

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: campaignAddress, abi: campaignAbi, functionName: "fundingDeadline" },
      { address: campaignAddress, abi: campaignAbi, functionName: "minCap" },
      { address: campaignAddress, abi: campaignAbi, functionName: "maxCap" },
      { address: campaignAddress, abi: campaignAbi, functionName: "currentSupply" },
    ] as never,
    query: { refetchInterval: 20_000 },
  });
  type MaybeResult = { result?: unknown };
  const rows = (data ?? []) as readonly MaybeResult[];
  const onChainDeadline =
    (rows[0]?.result as bigint | undefined) ?? 0n;
  const onChainMinCap = (rows[1]?.result as bigint | undefined) ?? 0n;
  const onChainMaxCap = (rows[2]?.result as bigint | undefined) ?? 0n;
  const onChainSupply = (rows[3]?.result as bigint | undefined) ?? 0n;

  const [deadlineInput, setDeadlineInput] = useState("");
  const [minCapInput, setMinCapInput] = useState("");
  const [maxCapInput, setMaxCapInput] = useState("");
  const [pending, setPending] = useState<
    null | "deadline" | "minCap" | "maxCap"
  >(null);

  const currentDeadlineIso = onChainDeadline
    ? new Date(Number(onChainDeadline) * 1000).toISOString().slice(0, 10)
    : "";
  const currentMinCapStr = Number(formatUnits(onChainMinCap, 18)).toString();
  const currentMaxCapStr = Number(formatUnits(onChainMaxCap, 18)).toString();

  const deadlineDisabled = currentState !== 0;
  const minCapDisabled = currentState !== 0;
  const maxCapDisabled = currentState !== 0 && currentState !== 1;

  const run = async (
    kind: "deadline" | "minCap" | "maxCap",
    args: Parameters<typeof writeContractAsync>[0],
  ) => {
    setPending(kind);
    try {
      const hash = await writeContractAsync(args);
      const r = await waitForTx(hash);
      if (r.status !== "success") throw new Error("Transaction reverted");
      await refetch();
      if (kind === "deadline") setDeadlineInput("");
      if (kind === "minCap") setMinCapInput("");
      if (kind === "maxCap") setMaxCapInput("");
      notify.success(
        tx(
          kind === "deadline"
            ? "setFundingDeadlineConfirmed"
            : kind === "minCap"
              ? "setMinCapConfirmed"
              : "setMaxCapConfirmed",
        ),
        hash,
      );
    } catch (err) {
      notify.error(
        tx(
          kind === "deadline"
            ? "setFundingDeadlineFailed"
            : kind === "minCap"
              ? "setMinCapFailed"
              : "setMaxCapFailed",
        ),
        err,
      );
    } finally {
      setPending(null);
    }
  };

  const submitDeadline = () => {
    if (!deadlineInput) return;
    const ts = BigInt(Math.floor(new Date(deadlineInput).getTime() / 1000));
    run("deadline", {
      address: campaignAddress,
      abi: campaignAbi,
      functionName: "setFundingDeadline",
      args: [ts],
    });
  };
  const submitMinCap = () => {
    if (!minCapInput || Number(minCapInput) <= 0) return;
    run("minCap", {
      address: campaignAddress,
      abi: campaignAbi,
      functionName: "setMinCap",
      args: [parseUnits(minCapInput, 18)],
    });
  };
  const submitMaxCap = () => {
    if (!maxCapInput || Number(maxCapInput) <= 0) return;
    run("maxCap", {
      address: campaignAddress,
      abi: campaignAbi,
      functionName: "setMaxCap",
      args: [parseUnits(maxCapInput, 18)],
    });
  };

  const stateKey =
    (["funding", "active", "buyback", "ended"] as const)[currentState] ??
    "funding";
  const stateLabel = t(`states.${stateKey}`);

  return (
    <div className="bg-surface-container-low rounded-xl p-5 border border-outline-variant/15 space-y-4">
      <p className="text-xs text-on-surface-variant">{t("subtitle")}</p>

      <ParamField
        label={t("fundingDeadline")}
        current={currentDeadlineIso || "—"}
        hint={
          deadlineDisabled
            ? t("deadlineDisabledHint", { state: stateLabel })
            : t("deadlineHint")
        }
        disabled={deadlineDisabled}
      >
        <div className="flex gap-2">
          <input
            type="date"
            value={deadlineInput}
            onChange={(e) => setDeadlineInput(e.target.value)}
            disabled={deadlineDisabled}
            className="input flex-1"
          />
          <button
            type="button"
            onClick={submitDeadline}
            disabled={deadlineDisabled || !deadlineInput || pending !== null}
            className="regen-gradient text-white rounded-full px-4 h-10 text-xs font-semibold disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
          >
            {pending === "deadline" && <Spinner size={12} />}
            {pending === "deadline" ? t("saving") : t("save")}
          </button>
        </div>
      </ParamField>

      <ParamField
        label={t("minCap")}
        current={
          currentMinCapStr + " $" + t("tokensSuffix")
        }
        hint={
          minCapDisabled
            ? t("minCapDisabledHint", { state: stateLabel })
            : t("minCapHint", {
                supply: Number(
                  formatUnits(onChainSupply, 18),
                ).toLocaleString(undefined, { maximumFractionDigits: 0 }),
              })
        }
        disabled={minCapDisabled}
      >
        <div className="flex gap-2">
          <input
            type="number"
            value={minCapInput}
            onChange={(e) => setMinCapInput(e.target.value)}
            placeholder={currentMinCapStr}
            disabled={minCapDisabled}
            className="input flex-1"
            min="0"
          />
          <button
            type="button"
            onClick={submitMinCap}
            disabled={minCapDisabled || !minCapInput || pending !== null}
            className="regen-gradient text-white rounded-full px-4 h-10 text-xs font-semibold disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
          >
            {pending === "minCap" && <Spinner size={12} />}
            {pending === "minCap" ? t("saving") : t("save")}
          </button>
        </div>
      </ParamField>

      <ParamField
        label={t("maxCap")}
        current={
          currentMaxCapStr + " $" + t("tokensSuffix")
        }
        hint={
          maxCapDisabled
            ? t("maxCapDisabledHint", { state: stateLabel })
            : t("maxCapHint", {
                supply: Number(
                  formatUnits(onChainSupply, 18),
                ).toLocaleString(undefined, { maximumFractionDigits: 0 }),
              })
        }
        disabled={maxCapDisabled}
      >
        <div className="flex gap-2">
          <input
            type="number"
            value={maxCapInput}
            onChange={(e) => setMaxCapInput(e.target.value)}
            placeholder={currentMaxCapStr}
            disabled={maxCapDisabled}
            className="input flex-1"
            min="0"
          />
          <button
            type="button"
            onClick={submitMaxCap}
            disabled={maxCapDisabled || !maxCapInput || pending !== null}
            className="regen-gradient text-white rounded-full px-4 h-10 text-xs font-semibold disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
          >
            {pending === "maxCap" && <Spinner size={12} />}
            {pending === "maxCap" ? t("saving") : t("save")}
          </button>
        </div>
      </ParamField>
    </div>
  );
}

function ParamField({
  label,
  current,
  hint,
  disabled,
  children,
}: {
  label: string;
  current: string;
  hint: string;
  disabled?: boolean;
  children: React.ReactNode;
}) {
  return (
    <div
      className={`rounded-lg border border-outline-variant/10 p-4 ${disabled ? "bg-surface-container/30 opacity-70" : "bg-surface-container-lowest"}`}
    >
      <div className="flex items-center justify-between mb-2 text-xs">
        <span className="font-semibold uppercase tracking-wider text-on-surface-variant">
          {label}
        </span>
        <span className="font-mono text-on-surface">{current}</span>
      </div>
      {children}
      <p className="text-[11px] text-on-surface-variant mt-2">{hint}</p>
    </div>
  );
}

/**
 * CollateralSection — producer-only widget to lock USDC into the pre-paid
 * yield reserve. State guards mirror Campaign.lockCollateral: Funding or
 * Active only; never Buyback / Ended. There is no withdraw path on chain.
 */
function CollateralSection({
  campaignAddress,
  currentState,
}: {
  campaignAddress: Address;
  currentState: number;
}) {
  const usdcAddress = getAddresses(CHAIN_ID).usdc as Address;
  const { writeContractAsync } = useWriteContract();
  const notify = useTxNotify();
  const [amount, setAmount] = useState("");
  const [phase, setPhase] = useState<
    "idle" | "approving-sig" | "approving-chain" | "locking-sig" | "locking-chain"
  >("idle");

  const { data: campaignReads, refetch: refetchCampaign } = useReadContracts({
    contracts: [
      {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "collateralLocked",
      },
      {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "collateralDrawn",
      },
      {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "coverageHarvests",
      },
      {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "expectedYearlyReturnBps",
      },
    ],
  });

  const locked6 = (campaignReads?.[0]?.result as bigint | undefined) ?? 0n;
  const drawn6 = (campaignReads?.[1]?.result as bigint | undefined) ?? 0n;
  const coverage = (campaignReads?.[2]?.result as bigint | undefined) ?? 0n;
  const yearlyBps = (campaignReads?.[3]?.result as bigint | undefined) ?? 0n;

  const lockAllowed = currentState === 0 || currentState === 1; // Funding | Active
  const parsed = (() => {
    if (!amount) return 0n;
    try {
      return parseUnits(amount, USDC_DECIMALS);
    } catch {
      return 0n;
    }
  })();

  const handleLock = async () => {
    if (!lockAllowed || parsed === 0n) return;
    try {
      // Approve full amount to the campaign so safeTransferFrom inside lockCollateral works.
      setPhase("approving-sig");
      const approveHash = await writeContractAsync({
        address: usdcAddress,
        abi: erc20Abi,
        functionName: "approve",
        args: [campaignAddress, parsed],
      });
      setPhase("approving-chain");
      const r1 = await waitForTx(approveHash);
      if (r1.status !== "success") throw new Error("approve reverted");

      setPhase("locking-sig");
      const lockHash = await writeContractAsync({
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "lockCollateral",
        args: [parsed],
      });
      setPhase("locking-chain");
      const r2 = await waitForTx(lockHash);
      if (r2.status !== "success") throw new Error("lockCollateral reverted");

      notify.success("Collateral locked", lockHash);
      setAmount("");
      await refetchCampaign();
      setPhase("idle");
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!/user (rejected|denied)/i.test(msg)) {
        notify.error("Lock collateral failed", err);
      }
      setPhase("idle");
    }
  };

  const lockedNum = Number(locked6) / 1e6;
  const drawnNum = Number(drawn6) / 1e6;
  const freeNum = Math.max(0, lockedNum - drawnNum);
  const harvestsToRepay =
    yearlyBps > 0n ? Math.ceil(10_000 / Number(yearlyBps)) : null;

  const inFlight = phase !== "idle";

  return (
    <div className="rounded-xl border border-outline-variant/15 p-4 space-y-4 bg-surface-container-lowest">
      <p className="text-xs text-on-surface-variant">
        Pre-fund the first {coverage.toString()}{" "}
        {Number(coverage) === 1 ? "harvest" : "harvests"} of holder yield as a
        guarantee. The lock is one-way — there is no withdrawal path on chain.
        Anyone can call <code>settleSeasonShortfall(seasonId)</code> after each
        season's <code>usdcDeadline</code> to draw from the reserve.
        {harvestsToRepay !== null && (
          <>
            {" "}Investor-side payback at this yield ≈ {harvestsToRepay} harvests.
          </>
        )}
      </p>

      <div className="grid grid-cols-3 gap-3">
        <CollateralStat label="Locked" value={`$${lockedNum.toLocaleString(undefined, { maximumFractionDigits: 2 })}`} />
        <CollateralStat label="Drawn" value={`$${drawnNum.toLocaleString(undefined, { maximumFractionDigits: 2 })}`} />
        <CollateralStat label="Free" value={`$${freeNum.toLocaleString(undefined, { maximumFractionDigits: 2 })}`} />
      </div>

      <div className="flex gap-3 items-end">
        <label className="flex-1">
          <span className="text-[11px] font-semibold uppercase tracking-wider text-on-surface-variant">
            Add USDC
          </span>
          <div className="relative mt-1">
            <span className="absolute left-3 top-1/2 -translate-y-1/2 text-sm text-on-surface-variant">
              $
            </span>
            <input
              type="number"
              min="0"
              step="100"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              disabled={!lockAllowed || inFlight}
              className="input pl-7"
              placeholder="0"
            />
          </div>
        </label>
        <button
          onClick={handleLock}
          disabled={!lockAllowed || inFlight || parsed === 0n}
          className="bg-primary text-on-primary rounded-xl h-12 px-6 font-semibold text-sm disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
        >
          {inFlight && <Spinner size={14} />}
          {phase === "approving-sig" || phase === "approving-chain"
            ? "Approving…"
            : phase === "locking-sig" || phase === "locking-chain"
              ? "Locking…"
              : "Lock"}
        </button>
      </div>
      {!lockAllowed && (
        <p className="text-[11px] text-error">
          Collateral can only be locked while the campaign is Funding or Active.
        </p>
      )}
    </div>
  );
}

function CollateralStat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-[10px] font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
        {label}
      </div>
      <div className="text-sm font-bold text-on-surface">{value}</div>
    </div>
  );
}
