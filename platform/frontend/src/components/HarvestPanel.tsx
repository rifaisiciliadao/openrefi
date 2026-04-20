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
import { useCampaignSeasons, type SubgraphSeason } from "@/lib/subgraph";
import { fetchMerkleProof } from "@/lib/api";
import { useQuery } from "@tanstack/react-query";
import { useTxNotify } from "@/lib/useTxNotify";

interface Props {
  campaignAddress: Address;
  harvestManager: Address;
  yieldToken: Address;
}

const harvestAbi = abis.HarvestManager as never;

export function HarvestPanel({
  campaignAddress,
  harvestManager,
  yieldToken,
}: Props) {
  const t = useTranslations("detail.harvest");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { address: user, isConnected } = useAccount();

  const [pending, setPending] = useState<{
    kind: "approve" | "redeem" | "claim";
    phase: "sig" | "chain";
  } | null>(null);
  const [txError, setTxError] = useState<string | null>(null);

  const { writeContractAsync } = useWriteContract();

  // Subgraph: list of seasons
  const { data: seasons, refetch: refetchSeasons } =
    useCampaignSeasons(campaignAddress);

  // User's YIELD balance
  const { data: yieldBalanceRaw, refetch: refetchBalance } = useReadContract({
    address: yieldToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: user ? [user] : undefined,
    query: { enabled: !!user, refetchInterval: 15_000 },
  }) as { data: bigint | undefined; refetch: () => void };
  const yieldBalance = yieldBalanceRaw ?? 0n;

  // Yield token symbol so we don't show a generic $YIELD label
  const { data: yieldSymbolRaw } = useReadContract({
    address: yieldToken,
    abi: erc20Abi,
    functionName: "symbol",
  });
  const yieldSymbol = (yieldSymbolRaw as string | undefined) ?? "YIELD";

  const runTx = async (
    kind: "approve" | "redeem" | "claim",
    args: Parameters<typeof writeContractAsync>[0],
  ) => {
    setTxError(null);
    setPending({ kind, phase: "sig" });
    try {
      const hash = await writeContractAsync(args);
      setPending({ kind, phase: "chain" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("Transaction reverted on-chain");
      void refetchSeasons();
      void refetchBalance();
      notify.success(tx(`${harvestKey(args)}Confirmed`), hash);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!/user (rejected|denied)/i.test(msg)) setTxError(msg);
      notify.error(tx(`${harvestKey(args)}Failed`), err);
      console.error(err);
    } finally {
      setPending(null);
    }
  };

  function harvestKey(args: Parameters<typeof writeContractAsync>[0]) {
    const fn = (args as { functionName?: string }).functionName;
    if (fn === "redeemUSDC") return "commit" as const;
    if (fn === "redeemProduct") return "redeemProduct" as const;
    if (fn === "claimUSDC") return "claimUsdc" as const;
    return "approval" as const;
  }

  const pendingKind = pending?.kind ?? null;

  // Two separate lists so we can render "waiting for producer to report"
  // cards alongside the active redemption ones — holders need to see
  // seasons they staked in even before the producer rendiconta.
  const sortedSeasons = [...(seasons ?? [])].sort(
    (a, b) => Number(b.seasonId) - Number(a.seasonId),
  );
  const reportedSeasons = sortedSeasons.filter((s) => s.reported);
  const unreportedSeasons = sortedSeasons.filter(
    (s) => !s.reported && !s.active,
  );

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <h2 className="text-2xl font-bold tracking-tight text-on-surface mb-2">
        {t("title")}
      </h2>
      <p className="text-sm text-on-surface-variant mb-6">{t("subtitle")}</p>

      {/* User balance */}
      <div className="bg-surface-container-low rounded-xl p-5 mb-6 border border-outline-variant/15">
        <div className="flex justify-between items-center">
          <span className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("yourBalance")}
          </span>
          <span className="text-2xl font-bold text-primary">
            {Number(formatUnits(yieldBalance, 18)).toFixed(4)} ${yieldSymbol}
          </span>
        </div>
      </div>

      {/* Seasons */}
      {!seasons || seasons.length === 0 ? (
        <p className="text-sm text-on-surface-variant text-center py-8">
          {t("noSeasons")}
        </p>
      ) : reportedSeasons.length === 0 && unreportedSeasons.length === 0 ? (
        <p className="text-sm text-on-surface-variant text-center py-8">
          {t("noReportedYet")}
        </p>
      ) : (
        <div className="space-y-4">
          {unreportedSeasons.map((season) => (
            <UnreportedSeasonCard key={season.id} season={season} />
          ))}
          {reportedSeasons.map((season) => (
            <SeasonCard
              key={season.id}
              season={season}
              harvestManager={harvestManager}
              user={user}
              userYieldBalance={yieldBalance}
              isConnected={isConnected}
              pendingKind={pendingKind}
              campaignAddress={campaignAddress}
              onRedeemUSDC={(yieldAmount) =>
                runTx("redeem", {
                  address: harvestManager,
                  abi: harvestAbi,
                  functionName: "redeemUSDC",
                  args: [BigInt(season.seasonId), yieldAmount],
                })
              }
              onClaimUSDC={() =>
                runTx("claim", {
                  address: harvestManager,
                  abi: harvestAbi,
                  functionName: "claimUSDC",
                  args: [BigInt(season.seasonId)],
                })
              }
              onRedeemProduct={(yieldAmount, proof) =>
                runTx("redeem", {
                  address: harvestManager,
                  abi: harvestAbi,
                  functionName: "redeemProduct",
                  args: [BigInt(season.seasonId), yieldAmount, proof],
                })
              }
            />
          ))}
        </div>
      )}
    </div>
  );
}

/**
 * Compact placeholder for a season that has ended but hasn't been reported
 * yet by the producer. Holders that staked during this season need to know
 * their $YIELD is waiting — they just can't act on it until the producer
 * reports the harvest.
 */
function UnreportedSeasonCard({ season }: { season: SubgraphSeason }) {
  const t = useTranslations("detail.harvest");
  const endTs = season.endTime ? new Date(Number(season.endTime) * 1000) : null;
  return (
    <div className="bg-surface-container-low rounded-xl p-5 border border-outline-variant/15">
      <div className="flex items-start justify-between mb-2">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            {t("seasonLabel", { id: season.seasonId })}
          </div>
          <div className="text-lg font-bold text-on-surface">
            {t("awaitingReport")}
          </div>
        </div>
        <span className="inline-flex items-center px-3 py-1 rounded-full text-[11px] font-semibold uppercase tracking-wider bg-amber-100 text-amber-900">
          {t("awaitingReportBadge")}
        </span>
      </div>
      <p className="text-xs text-on-surface-variant">
        {endTs
          ? t("awaitingReportEnded", { date: endTs.toLocaleDateString() })
          : t("awaitingReportHint")}
      </p>
    </div>
  );
}

function SeasonCard({
  season,
  harvestManager,
  campaignAddress,
  user,
  userYieldBalance,
  isConnected,
  pendingKind,
  onRedeemUSDC,
  onClaimUSDC,
  onRedeemProduct,
}: {
  season: SubgraphSeason;
  harvestManager: Address;
  campaignAddress: Address;
  user: Address | undefined;
  userYieldBalance: bigint;
  isConnected: boolean;
  pendingKind: string | null;
  onRedeemUSDC: (yieldAmount: bigint) => void;
  onClaimUSDC: () => void;
  onRedeemProduct: (yieldAmount: bigint, proof: `0x${string}`[]) => void;
}) {
  const t = useTranslations("detail.harvest");
  const [redeemAmount, setRedeemAmount] = useState("");

  // Read this user's claim status for this season
  const { data: claimRaw } = useReadContracts({
    contracts: user
      ? [
          {
            address: harvestManager,
            abi: harvestAbi,
            functionName: "claims",
            args: [BigInt(season.seasonId), user],
          },
        ]
      : [],
    query: { enabled: !!user, refetchInterval: 15_000 },
  });

  // claims returns (claimed, redemptionType, amount, usdcAmount, usdcClaimed)
  const claim = claimRaw?.[0]?.result as
    | readonly [boolean, number, bigint, bigint, bigint]
    | undefined;
  const hasClaimed = claim?.[0] ?? false;
  const usdcOwed = claim?.[3] ?? 0n;
  const usdcAlreadyClaimed = claim?.[4] ?? 0n;

  const now = Math.floor(Date.now() / 1000);
  const claimOpen =
    season.claimStart &&
    season.claimEnd &&
    now >= Number(season.claimStart) &&
    now <= Number(season.claimEnd);

  const depositOpen =
    season.usdcDeadline && now <= Number(season.usdcDeadline);

  // For pro-rata USDC: how much USDC this claim is entitled to right now,
  // given current deposits.
  const usdcDeposited = BigInt(season.usdcDeposited);
  const usdcOwedTotal = BigInt(season.usdcOwed);
  const entitled =
    usdcOwedTotal > 0n && usdcDeposited > 0n
      ? (usdcOwed * usdcDeposited) / usdcOwedTotal
      : 0n;
  const claimable = entitled > usdcAlreadyClaimed ? entitled - usdcAlreadyClaimed : 0n;

  const redeemAmountWei = useMemo(() => {
    if (!redeemAmount || Number(redeemAmount) <= 0) return 0n;
    try {
      return parseUnits(redeemAmount, 18);
    } catch {
      return 0n;
    }
  }, [redeemAmount]);

  const canRedeem =
    isConnected &&
    !hasClaimed &&
    claimOpen &&
    redeemAmountWei > 0n &&
    redeemAmountWei <= userYieldBalance;

  // Hide the entire card when the user has nothing to do here: no commit
  // on file AND no YIELD to redeem. Cleans up the harvest tab for people
  // who never staked into this season.
  if (!hasClaimed && userYieldBalance === 0n && !claimOpen) {
    return null;
  }

  return (
    <div className="bg-surface-container-low rounded-xl p-5 border border-outline-variant/15">
      <div className="flex justify-between items-start mb-4">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            {t("seasonLabel", { id: season.seasonId })}
          </div>
          <div className="text-lg font-bold text-on-surface">
            {season.totalProductUnits
              ? `${Number(formatUnits(BigInt(season.totalProductUnits), 18)).toLocaleString()} ${t("units")}`
              : "—"}
          </div>
        </div>
        <div className="text-right">
          <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            {t("holderPool")}
          </div>
          <div className="text-lg font-bold text-primary">
            $
            {Number(
              formatUnits(BigInt(season.holderPool ?? "0"), 18),
            ).toLocaleString()}
          </div>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-3 mb-4 pt-4 border-t border-outline-variant/15 text-xs">
        <div>
          <div className="text-on-surface-variant">{t("claimWindow")}</div>
          <div className="font-semibold text-on-surface">
            {claimOpen ? t("open") : t("closed")}
          </div>
        </div>
        <div>
          <div className="text-on-surface-variant">{t("usdcDeposited")}</div>
          <div className="font-semibold text-on-surface">
            {Number(formatUnits(usdcDeposited, 18)).toLocaleString()} /
            {" "}
            {Number(formatUnits(usdcOwedTotal, 18)).toLocaleString()}
          </div>
        </div>
        <div>
          <div className="text-on-surface-variant">{t("depositWindow")}</div>
          <div className="font-semibold text-on-surface">
            {depositOpen ? t("open") : t("closed")}
          </div>
        </div>
      </div>

      {/* Redeem flow (step 1) */}
      {!hasClaimed && claimOpen && (
        <div className="mb-3">
          <div className="flex justify-between items-center mb-2">
            <label className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
              {t("redeemYieldForUsdc")}
            </label>
            <button
              onClick={() =>
                setRedeemAmount(formatUnits(userYieldBalance, 18))
              }
              className="text-xs text-on-surface-variant hover:text-primary transition-colors"
            >
              {t("balanceYield", {
                amount: Number(formatUnits(userYieldBalance, 18)).toFixed(2),
              })}
            </button>
          </div>
          <div className="flex gap-2">
            <input
              type="number"
              value={redeemAmount}
              onChange={(e) => setRedeemAmount(e.target.value)}
              placeholder="0.00"
              className="flex-1 bg-surface-container rounded-lg px-3 py-2 text-sm border border-outline-variant/15 outline-none focus:border-primary/50"
            />
            <button
              onClick={() => onRedeemUSDC(redeemAmountWei)}
              disabled={!canRedeem || pendingKind !== null}
              className="regen-gradient text-white rounded-lg px-4 py-2 text-sm font-semibold hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {pendingKind === "redeem" ? t("redeeming") : t("redeemUSDC")}
            </button>
          </div>
          {!claimOpen && (
            <p className="text-xs text-on-surface-variant mt-1">
              {t("claimWindowClosed")}
            </p>
          )}
        </div>
      )}

      {/* Commitment lifecycle — shown once the user has committed a claim */}
      {hasClaimed && claim?.[1] === 2 /* RedemptionType.USDC */ && (
        <UsdcClaimTimeline
          usdcCommitted={usdcOwed}
          usdcAlreadyClaimed={usdcAlreadyClaimed}
          seasonUsdcDeposited={usdcDeposited}
          seasonUsdcOwed={usdcOwedTotal}
          entitled={entitled}
          claimable={claimable}
          usdcDeadline={season.usdcDeadline}
          pendingKind={pendingKind}
          onClaim={onClaimUSDC}
        />
      )}
      {hasClaimed && claim?.[1] === 1 /* RedemptionType.Product */ && (
        <div className="pt-3 border-t border-outline-variant/15 text-sm text-on-surface">
          ✓ {t("productClaimed")}
        </div>
      )}

      {/* Product redemption (requires merkle proof) */}
      {!hasClaimed && claimOpen && season.merkleRoot && user && (
        <ProductRedemption
          campaignAddress={campaignAddress}
          seasonId={season.seasonId}
          user={user}
          userYieldBalance={userYieldBalance}
          pendingKind={pendingKind}
          onRedeem={onRedeemProduct}
        />
      )}
    </div>
  );
}

/**
 * Post-commit USDC lifecycle for a single season claim. Four phases:
 *
 *   1. Committed       — $YIELD burned, usdcAmount registered on-chain.
 *   2. Producer deposit — waiting for producer USDC; progress driven by
 *                         season.usdcDeposited / season.usdcOwed.
 *   3. Claimable       — enough USDC sits in the pool for this user to
 *                         withdraw pro-rata; Claim button active.
 *   4. Fulfilled       — usdcClaimed >= usdcCommitted (minus dust).
 *
 * The timeline mirrors what the subgraph sees (Claim.fulfilled flag +
 * Season.usdcDeposited/usdcOwed) so producer + holder are always in sync.
 */
function UsdcClaimTimeline({
  usdcCommitted,
  usdcAlreadyClaimed,
  seasonUsdcDeposited,
  seasonUsdcOwed,
  entitled,
  claimable,
  usdcDeadline,
  pendingKind,
  onClaim,
}: {
  usdcCommitted: bigint;
  usdcAlreadyClaimed: bigint;
  seasonUsdcDeposited: bigint;
  seasonUsdcOwed: bigint;
  entitled: bigint;
  claimable: bigint;
  usdcDeadline: string | null;
  pendingKind: string | null;
  onClaim: () => void;
}) {
  const t = useTranslations("detail.harvest");

  const depositPct =
    seasonUsdcOwed > 0n
      ? Number((seasonUsdcDeposited * 100n) / seasonUsdcOwed)
      : 0;
  // Dust tolerance: claimUSDC transfers whole 6-dec USDC-wei, so the 18-dec
  // usdcClaimed can lag usdcAmount by up to (1 USDC-wei × 1e12) per claim.
  // Treat anything within 1e12 (= 1 USDC-wei in 18-dec) as fully paid.
  const DUST_18 = 10n ** 12n;
  const fulfilled =
    usdcCommitted > 0n && usdcAlreadyClaimed + DUST_18 >= usdcCommitted;
  const fullyDeposited = seasonUsdcOwed > 0n && seasonUsdcDeposited >= seasonUsdcOwed;

  // Phase indicator — which dot is currently "active"
  const phase: 1 | 2 | 3 | 4 = fulfilled
    ? 4
    : claimable > 0n
      ? 3
      : fullyDeposited
        ? 3
        : 2;

  const deadlineDate = usdcDeadline
    ? new Date(Number(usdcDeadline) * 1000)
    : null;
  const now = Math.floor(Date.now() / 1000);
  const daysToDeadline = usdcDeadline
    ? Math.max(0, Math.ceil((Number(usdcDeadline) - now) / 86400))
    : null;
  const pastDeadline =
    usdcDeadline !== null && now > Number(usdcDeadline);
  const depositShortfall = !fullyDeposited && pastDeadline;

  return (
    <div className="pt-4 border-t border-outline-variant/15 space-y-4">
      {/* Headline state */}
      <div className="flex justify-between items-start">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            {fulfilled ? t("timeline.fulfilled") : t("timeline.yourEntitlement")}
          </div>
          <div className="text-2xl font-bold text-on-surface">
            ${Number(formatUnits(usdcCommitted, 18)).toFixed(2)}
          </div>
          <div className="text-xs text-on-surface-variant mt-0.5">
            {t("timeline.claimedSoFar", {
              amount: Number(formatUnits(usdcAlreadyClaimed, 18)).toFixed(2),
              total: Number(formatUnits(usdcCommitted, 18)).toFixed(2),
            })}
          </div>
        </div>
        <StatusBadge phase={phase} />
      </div>

      {/* Four-dot timeline */}
      <div className="relative pt-2">
        <div className="flex items-center justify-between">
          {[1, 2, 3, 4].map((p) => (
            <div key={p} className="flex flex-col items-center gap-1 z-10">
              <div
                className={`w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold border-2 transition-colors ${
                  phase >= p
                    ? "bg-primary border-primary text-white"
                    : "bg-surface-container-low border-outline-variant/30 text-on-surface-variant"
                }`}
              >
                {phase > p ? "✓" : p}
              </div>
              <span
                className={`text-[10px] font-semibold uppercase tracking-wider text-center max-w-[80px] ${
                  phase >= p ? "text-on-surface" : "text-on-surface-variant"
                }`}
              >
                {t(`timeline.phase${p}`)}
              </span>
            </div>
          ))}
        </div>
        {/* Connector line */}
        <div className="absolute top-[calc(0.5rem+0.875rem)] left-[10%] right-[10%] h-0.5 bg-surface-container-high -z-0">
          <div
            className="h-full bg-primary transition-all duration-700"
            style={{ width: `${((phase - 1) / 3) * 100}%` }}
          />
        </div>
      </div>

      {/* Shortfall banner: deposit window closed and producer under-delivered */}
      {depositShortfall && (
        <div className="bg-red-50 border border-red-200 rounded-xl p-3 text-xs text-error">
          ⚠ {t("timeline.shortfall")}
        </div>
      )}

      {/* Producer deposit progress — only meaningful in phase 2 */}
      {!fulfilled && (
        <div className="bg-surface-container-low rounded-xl p-3 border border-outline-variant/15">
          <div className="flex justify-between items-center text-xs mb-2">
            <span className="font-semibold text-on-surface-variant uppercase tracking-wider">
              {t("timeline.producerDeposit")}
            </span>
            <span className="font-semibold text-on-surface">
              ${Number(formatUnits(seasonUsdcDeposited, 18)).toLocaleString()} /
              ${Number(formatUnits(seasonUsdcOwed, 18)).toLocaleString()}
            </span>
          </div>
          <div className="w-full h-1.5 bg-surface-container-high rounded-full overflow-hidden">
            <div
              className="h-full bg-primary rounded-full transition-all duration-700"
              style={{ width: `${Math.min(depositPct, 100)}%` }}
            />
          </div>
          {deadlineDate && daysToDeadline !== null && (
            <div className="text-[11px] text-on-surface-variant mt-1.5">
              {daysToDeadline > 0
                ? t("timeline.depositDeadline", {
                    date: deadlineDate.toLocaleDateString(),
                    days: daysToDeadline,
                  })
                : t("timeline.depositDeadlinePassed", {
                    date: deadlineDate.toLocaleDateString(),
                  })}
            </div>
          )}
        </div>
      )}

      {/* Claim action */}
      {!fulfilled && (
        <div className="flex justify-between items-center">
          <div>
            <div className="text-xs text-on-surface-variant">
              {t("timeline.claimableNow")}
            </div>
            <div className="text-lg font-bold text-primary">
              ${Number(formatUnits(claimable, 18)).toFixed(2)}
            </div>
            {entitled > claimable + usdcAlreadyClaimed + 1n && (
              <div className="text-[11px] text-on-surface-variant">
                {t("timeline.entitledTotal", {
                  amount: Number(formatUnits(entitled, 18)).toFixed(2),
                })}
              </div>
            )}
          </div>
          <button
            onClick={onClaim}
            disabled={claimable === 0n || pendingKind !== null}
            className="regen-gradient text-white rounded-full px-6 py-2.5 text-sm font-semibold hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {pendingKind === "claim" ? t("claiming") : t("claimUSDC")}
          </button>
        </div>
      )}
      {fulfilled && (
        <div className="flex items-center gap-2 text-sm text-primary font-semibold">
          <svg
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="currentColor"
            className="shrink-0"
          >
            <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" />
          </svg>
          {t("timeline.fullyPaid", {
            amount: Number(formatUnits(usdcCommitted, 18)).toFixed(2),
          })}
        </div>
      )}
    </div>
  );
}

function StatusBadge({ phase }: { phase: 1 | 2 | 3 | 4 }) {
  const t = useTranslations("detail.harvest");
  const map = {
    1: { label: t("timeline.statusCommitted"), cls: "bg-amber-100 text-amber-900" },
    2: {
      label: t("timeline.statusAwaitingDeposit"),
      cls: "bg-amber-100 text-amber-900",
    },
    3: { label: t("timeline.statusClaimable"), cls: "bg-primary text-white" },
    4: {
      label: t("timeline.statusFulfilled"),
      cls: "bg-primary-fixed text-on-primary-fixed-variant",
    },
  };
  const { label, cls } = map[phase];
  return (
    <span
      className={`inline-flex items-center px-3 py-1 rounded-full text-[11px] font-semibold uppercase tracking-wider ${cls}`}
    >
      {label}
    </span>
  );
}

function ProductRedemption({
  campaignAddress,
  seasonId,
  user,
  userYieldBalance,
  pendingKind,
  onRedeem,
}: {
  campaignAddress: Address;
  seasonId: string;
  user: Address;
  userYieldBalance: bigint;
  pendingKind: string | null;
  onRedeem: (yieldAmount: bigint, proof: `0x${string}`[]) => void;
}) {
  const t = useTranslations("detail.harvest");

  const { data: proofData, isLoading } = useQuery({
    queryKey: ["merkle-proof", campaignAddress, seasonId, user?.toLowerCase()],
    enabled: !!user,
    queryFn: () => fetchMerkleProof(campaignAddress, seasonId, user),
    retry: 1,
    staleTime: Infinity,
  });

  if (isLoading) {
    return (
      <div className="mt-3 pt-3 border-t border-outline-variant/15 text-xs text-on-surface-variant">
        {t("checkingProductEligibility")}
      </div>
    );
  }

  if (!proofData) {
    return (
      <div className="mt-3 pt-3 border-t border-outline-variant/15 text-xs text-on-surface-variant">
        🫒 {t("notEligibleForProduct")}
      </div>
    );
  }

  const productAmount = BigInt(proofData.productAmount);

  return (
    <div className="mt-3 pt-3 border-t border-outline-variant/15">
      <div className="flex items-center justify-between mb-3">
        <div>
          <div className="text-xs text-on-surface-variant">
            {t("productEntitlement")}
          </div>
          <div className="text-lg font-bold text-primary">
            🫒{" "}
            {Number(formatUnits(productAmount, 18)).toLocaleString(undefined, {
              maximumFractionDigits: 2,
            })}{" "}
            {t("units")}
          </div>
        </div>
        <button
          onClick={() => onRedeem(userYieldBalance, proofData.proof)}
          disabled={userYieldBalance === 0n || pendingKind !== null}
          className="bg-primary text-white rounded-full px-5 py-2 text-sm font-semibold hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {pendingKind === "redeem" ? t("redeeming") : t("redeemProduct")}
        </button>
      </div>
      <p className="text-xs text-on-surface-variant">
        {t("productRedeemNote")}
      </p>
    </div>
  );
}
