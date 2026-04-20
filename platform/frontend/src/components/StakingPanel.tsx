"use client";

import { useState, useMemo } from "react";
import { useTranslations } from "next-intl";
import {
  useAccount,
  useReadContract,
  useReadContracts,
  useWriteContract,
} from "wagmi";
import { waitForTransactionReceipt } from "@wagmi/core";
import { formatUnits, parseUnits, type Address } from "viem";
import { abis } from "@/contracts";
import { config } from "@/app/providers";
import { erc20Abi } from "@/contracts/erc20";
import { Spinner } from "./Spinner";
import { useTxNotify } from "@/lib/useTxNotify";

interface Props {
  campaignToken: Address;
  stakingVault: Address;
  yieldToken: Address;
  seasonDuration: bigint; // in seconds
}

type Position = {
  id: bigint;
  amount: bigint;
  startTime: bigint;
  seasonId: bigint;
  active: boolean;
  earned: bigint;
};

const stakingAbi = abis.StakingVault as never;
const tokenAbi = abis.CampaignToken as never;

export function StakingPanel({
  campaignToken,
  stakingVault,
  yieldToken,
  seasonDuration,
}: Props) {
  const t = useTranslations("detail.stake");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { address: user, isConnected } = useAccount();

  type TxPhase = "sig" | "chain";
  const [pending, setPending] = useState<{
    kind: "approve" | "stake" | "claim" | "unstake" | "restake";
    phase: TxPhase;
  } | null>(null);
  const [stakeAmount, setStakeAmount] = useState("");
  const [txError, setTxError] = useState<string | null>(null);

  const { writeContractAsync } = useWriteContract();

  // 1) Load position IDs for the user
  const { data: positionIds, refetch: refetchIds } = useReadContract({
    address: stakingVault,
    abi: stakingAbi,
    functionName: "getPositions",
    args: user ? [user] : undefined,
    query: { enabled: !!user, refetchInterval: 10_000 },
  }) as { data: bigint[] | undefined; refetch: () => void };

  // 2) For each id, read position struct + earned
  const positionContracts = useMemo(() => {
    if (!positionIds) return [];
    return positionIds.flatMap((id) => [
      { address: stakingVault, abi: stakingAbi, functionName: "positions", args: [id] },
      { address: stakingVault, abi: stakingAbi, functionName: "earned", args: [id] },
    ]);
  }, [positionIds, stakingVault]);

  const { data: positionData, refetch: refetchPositions } = useReadContracts({
    contracts: positionContracts as never,
    query: { enabled: positionContracts.length > 0, refetchInterval: 10_000 },
  });

  const positions: Position[] = useMemo(() => {
    if (!positionIds || !positionData) return [];
    type MaybeResult = { result?: unknown };
    const results = positionData as readonly MaybeResult[];
    return positionIds
      .map((id, i) => {
        const posResult = results[i * 2]?.result as
          | readonly [Address, bigint, bigint, bigint, bigint, boolean]
          | undefined;
        const earned = (results[i * 2 + 1]?.result as bigint) ?? 0n;
        if (!posResult) return null;
        return {
          id,
          amount: posResult[1],
          startTime: posResult[2],
          seasonId: posResult[4],
          active: posResult[5],
          earned,
        };
      })
      .filter((p): p is Position => p !== null && p.active);
  }, [positionIds, positionData]);

  // 3) User token balance + allowance
  const { data: balAllow, refetch: refetchBalAllow } = useReadContracts({
    contracts: user
      ? [
          { address: campaignToken, abi: erc20Abi, functionName: "balanceOf", args: [user] },
          {
            address: campaignToken,
            abi: erc20Abi,
            functionName: "allowance",
            args: [user, stakingVault],
          },
          { address: campaignToken, abi: erc20Abi, functionName: "symbol" },
        ]
      : [],
    query: { enabled: !!user },
  });

  const balance = (balAllow?.[0]?.result as bigint) ?? 0n;
  const allowance = (balAllow?.[1]?.result as bigint) ?? 0n;
  const symbol = (balAllow?.[2]?.result as string) ?? "CAMP";

  // Yield token symbol — what stakers earn (e.g. "OIL" instead of generic $YIELD)
  const { data: yieldSymbolRaw } = useReadContract({
    address: yieldToken,
    abi: erc20Abi,
    functionName: "symbol",
  });
  const yieldSymbol = (yieldSymbolRaw as string | undefined) ?? "YIELD";

  // 4) Current season for restake eligibility + active-season guard
  const { data: currentSeasonId } = useReadContract({
    address: stakingVault,
    abi: stakingAbi,
    functionName: "currentSeasonId",
  }) as { data: bigint | undefined };

  // Season struct layout: (seasonId, startTime, endTime, active, ...).
  // Pre-flight check avoids submitting stake txs that will revert with
  // NoActiveSeason — the contract rejects stakes when no season is running.
  const { data: currentSeasonData, isLoading: seasonLoading } = useReadContract(
    {
      address: stakingVault,
      abi: stakingAbi,
      functionName: "seasons",
      args:
        currentSeasonId !== undefined && currentSeasonId > 0n
          ? [currentSeasonId]
          : undefined,
      query: { enabled: currentSeasonId !== undefined && currentSeasonId > 0n },
    },
  ) as {
    data: readonly [bigint, bigint, bigint, boolean, ...unknown[]] | undefined;
    isLoading: boolean;
  };
  const seasonActive =
    currentSeasonId !== undefined &&
    currentSeasonId > 0n &&
    !!currentSeasonData?.[3];
  // Don't flash the "no active season" banner during the initial fetch.
  // Wait until currentSeasonId is resolved AND the seasons() read has
  // settled before declaring there's no active season.
  const seasonDataResolved =
    currentSeasonId !== undefined &&
    (currentSeasonId === 0n || !seasonLoading);
  const showNoSeasonBanner = seasonDataResolved && !seasonActive;


  const stakeAmountWei = useMemo(() => {
    if (!stakeAmount || Number(stakeAmount) <= 0) return 0n;
    try {
      return parseUnits(stakeAmount, 18);
    } catch {
      return 0n;
    }
  }, [stakeAmount]);

  const needsApproval = stakeAmountWei > 0n && allowance < stakeAmountWei;
  // StakingVault.stake() reverts with TooManyPositions once a user holds
  // 50 active positions. Guard against it so the tx doesn't revert.
  const MAX_POSITIONS_PER_USER = 50;
  const activePositionCount = positions.filter((p) => p.active).length;
  const tooManyPositions = activePositionCount >= MAX_POSITIONS_PER_USER;
  const canStake =
    isConnected &&
    stakeAmountWei > 0n &&
    stakeAmountWei <= balance &&
    seasonActive &&
    !tooManyPositions;

  /**
   * Imperative tx flow: sig → chain → refetch → done. Each stage updates
   * `pending` so the button shows an accurate label + spinner throughout.
   * If the wallet signature or the on-chain receipt fails, we surface the
   * error (except for "user rejected" which stays silent).
   */
  const runTx = async (
    kind: "approve" | "stake" | "claim" | "unstake" | "restake",
    args: Parameters<typeof writeContractAsync>[0],
  ) => {
    setTxError(null);
    setPending({ kind, phase: "sig" });
    try {
      const hash = await writeContractAsync(args);
      setPending({ kind, phase: "chain" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("Transaction reverted on-chain");
      refetchIds();
      refetchPositions();
      refetchBalAllow();
      if (kind === "stake") setStakeAmount("");
      notify.success(tx(`${successKey(kind)}Confirmed`), hash);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!/user (rejected|denied)/i.test(msg)) setTxError(msg);
      notify.error(tx(`${successKey(kind)}Failed`), err);
      console.error(err);
    } finally {
      setPending(null);
    }
  };

  function successKey(kind: "approve" | "stake" | "claim" | "unstake" | "restake") {
    if (kind === "approve") return "approval" as const;
    if (kind === "claim") return "claimYield" as const;
    return kind;
  }

  const pendingKind = pending?.kind ?? null;

  const handleApprove = () =>
    runTx("approve", {
      address: campaignToken,
      abi: erc20Abi,
      functionName: "approve",
      args: [stakingVault, stakeAmountWei],
    });

  const handleStake = () =>
    runTx("stake", {
      address: stakingVault,
      abi: stakingAbi,
      functionName: "stake",
      args: [stakeAmountWei],
    });

  const handleClaim = (positionId: bigint) =>
    runTx("claim", {
      address: stakingVault,
      abi: stakingAbi,
      functionName: "claimYield",
      args: [positionId],
    });

  const handleUnstake = (positionId: bigint) =>
    runTx("unstake", {
      address: stakingVault,
      abi: stakingAbi,
      functionName: "unstake",
      args: [positionId],
    });

  const handleRestake = (positionId: bigint) =>
    runTx("restake", {
      address: stakingVault,
      abi: stakingAbi,
      functionName: "restake",
      args: [positionId],
    });

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <h2 className="text-2xl font-bold tracking-tight text-on-surface mb-2">
        {t("title")}
      </h2>
      <p className="text-sm text-on-surface-variant mb-6">
        {t("subtitleTokens", { stake: symbol, yield: yieldSymbol })}
      </p>

      {showNoSeasonBanner && (
        <div className="bg-amber-50 border border-amber-200 rounded-xl p-4 mb-6 flex items-start gap-3">
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
            <div className="font-semibold text-amber-900 text-sm">
              {t("noActiveSeason")}
            </div>
            <p className="text-xs text-amber-800 mt-0.5">
              {t("noActiveSeasonHint")}
            </p>
          </div>
        </div>
      )}

      {txError && (
        <div className="bg-red-50 border border-red-200 text-error rounded-xl p-3 mb-4 text-xs break-words">
          {txError}
        </div>
      )}

      {/* New stake form */}
      <div className="bg-surface-container-low rounded-xl p-5 mb-6 border border-outline-variant/15">
        <div className="flex justify-between items-center mb-2">
          <label className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("newStakeAmount")}
          </label>
          <button
            onClick={() => setStakeAmount(formatUnits(balance, 18))}
            className="text-xs text-on-surface-variant hover:text-primary transition-colors"
          >
            {t("availableBalance", {
              amount: Number(formatUnits(balance, 18)).toFixed(2),
              symbol,
            })}
          </button>
        </div>
        <div className="flex justify-between items-center mb-3">
          <input
            type="number"
            value={stakeAmount}
            onChange={(e) => setStakeAmount(e.target.value)}
            placeholder="0.00"
            className="bg-transparent border-none outline-none text-3xl font-bold text-on-surface w-full p-0 focus:ring-0"
          />
          <div className="bg-surface-container-highest rounded-full px-3 py-1 ml-2">
            <span className="text-sm font-semibold text-on-surface">
              ${symbol}
            </span>
          </div>
        </div>
        {needsApproval ? (
          <button
            onClick={handleApprove}
            disabled={!canStake || pendingKind !== null}
            className="w-full regen-gradient text-white rounded-xl h-12 font-semibold hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
          >
            {pendingKind === "approve" && <Spinner size={18} />}
            {pendingKind === "approve"
              ? t("approving")
              : t("approveToStake", { symbol })}
          </button>
        ) : (
          <button
            onClick={handleStake}
            disabled={!canStake || pendingKind !== null}
            className="w-full regen-gradient text-white rounded-xl h-12 font-semibold hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
          >
            {pendingKind === "stake" && <Spinner size={18} />}
            {pendingKind === "stake"
              ? t("staking")
              : !isConnected
                ? t("connectFirst")
                : stakeAmountWei > balance
                  ? t("insufficientBalance")
                  : t("newStake")}
          </button>
        )}
      </div>

      {/* Existing positions */}
      {positions.length === 0 ? (
        <p className="text-sm text-on-surface-variant text-center py-8">
          {t("noPositions")}
        </p>
      ) : (
        <div className="space-y-3">
          {positions.map((pos) => (
            <PositionCard
              key={String(pos.id)}
              pos={pos}
              symbol={symbol}
              yieldSymbol={yieldSymbol}
              seasonDuration={seasonDuration}
              currentSeasonId={currentSeasonId}
              pendingKind={pendingKind}
              onClaim={() => handleClaim(pos.id)}
              onUnstake={() => handleUnstake(pos.id)}
              onRestake={() => handleRestake(pos.id)}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function PositionCard({
  pos,
  symbol,
  yieldSymbol,
  seasonDuration,
  currentSeasonId,
  pendingKind,
  onClaim,
  onUnstake,
  onRestake,
}: {
  pos: Position;
  symbol: string;
  yieldSymbol: string;
  seasonDuration: bigint;
  currentSeasonId: bigint | undefined;
  pendingKind: string | null;
  onClaim: () => void;
  onUnstake: () => void;
  onRestake: () => void;
}) {
  const t = useTranslations("detail.stake");

  const now = BigInt(Math.floor(Date.now() / 1000));
  const elapsed = now - pos.startTime;
  const penaltyPct =
    seasonDuration > 0n && elapsed < seasonDuration
      ? Math.max(0, 100 - Number((elapsed * 100n) / seasonDuration))
      : 0;

  const stakeDate = new Date(Number(pos.startTime) * 1000).toLocaleDateString();
  const isStalePosition =
    currentSeasonId !== undefined && pos.seasonId !== currentSeasonId;

  const locked = pendingKind !== null;

  return (
    <div className="bg-surface-container-low rounded-xl p-5 border border-outline-variant/15">
      <div className="flex justify-between items-start mb-4">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            {t("position", { id: String(pos.id) })}
          </div>
          <div className="text-2xl font-bold text-on-surface">
            {Number(formatUnits(pos.amount, 18)).toLocaleString()} ${symbol}
          </div>
        </div>
        <div className="text-right">
          <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            {t("yieldAccrued")}
          </div>
          <div className="text-2xl font-bold text-primary">
            {Number(formatUnits(pos.earned, 18)).toFixed(4)} ${yieldSymbol}
          </div>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-4 mb-4 pt-4 border-t border-outline-variant/15 text-sm">
        <div>
          <div className="text-xs text-on-surface-variant">
            {t("stakeDate")}
          </div>
          <div className="font-semibold text-on-surface">{stakeDate}</div>
        </div>
        <div>
          <div className="text-xs text-on-surface-variant">
            {t("unstakePenalty")}
          </div>
          <div className={`font-semibold ${penaltyPct > 0 ? "text-error" : "text-primary"}`}>
            {penaltyPct}%
          </div>
        </div>
        <div>
          <div className="text-xs text-on-surface-variant">
            {t("positionSeason")}
          </div>
          <div className="font-semibold text-on-surface">
            #{String(pos.seasonId)}
            {isStalePosition && (
              <span className="ml-1 text-xs text-on-surface-variant">
                ({t("oldSeason")})
              </span>
            )}
          </div>
        </div>
      </div>

      <div className="flex gap-2">
        <button
          onClick={onClaim}
          disabled={locked || pos.earned === 0n}
          className="flex-1 bg-primary text-white rounded-full py-2.5 text-sm font-semibold hover:opacity-90 transition disabled:opacity-40 disabled:cursor-not-allowed flex items-center justify-center gap-2"
        >
          {pendingKind === "claim" && <Spinner size={14} />}
          {pendingKind === "claim" ? t("claiming") : t("claim")}
        </button>
        {isStalePosition && (
          <button
            onClick={onRestake}
            disabled={locked}
            className="flex-1 bg-surface-container-high text-on-surface rounded-full py-2.5 text-sm font-semibold hover:bg-surface-container-highest transition disabled:opacity-40 disabled:cursor-not-allowed flex items-center justify-center gap-2"
          >
            {pendingKind === "restake" && <Spinner size={14} />}
            {pendingKind === "restake" ? t("restaking") : t("restake")}
          </button>
        )}
        <button
          onClick={onUnstake}
          disabled={locked}
          className="flex-1 bg-transparent border border-outline-variant text-on-surface-variant rounded-full py-2.5 text-sm font-semibold hover:bg-surface-container-low transition disabled:opacity-40 disabled:cursor-not-allowed flex items-center justify-center gap-2"
        >
          {pendingKind === "unstake" && <Spinner size={14} />}
          {pendingKind === "unstake" ? t("unstaking") : t("unstake")}
        </button>
      </div>
    </div>
  );
}
