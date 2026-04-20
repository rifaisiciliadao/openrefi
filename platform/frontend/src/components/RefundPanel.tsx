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
import { formatUnits, type Address } from "viem";
import { abis } from "@/contracts";
import { config } from "@/app/providers";
import { erc20Abi } from "@/contracts/erc20";
import { Spinner } from "./Spinner";
import { useTxNotify } from "@/lib/useTxNotify";

interface Props {
  campaignAddress: Address;
  campaignToken: Address;
  /** Campaign.state enum — 0=Funding, 1=Active, 2=Buyback, 3=Ended */
  currentState: number;
}

const campaignAbi = abis.Campaign as never;

/**
 * Failed-campaign refund panel. Renders when `currentState === 2` (Buyback):
 * the campaign hit its funding deadline without reaching min cap, so every
 * buyer is entitled to their original payment back. Each accepted token
 * needs its own `buyback(token)` call because the contract tracks per-token
 * purchase amounts (the buyer may have paid in multiple tokens).
 *
 * The refund burns the proportional $CAMPAIGN the user got at buy time.
 */
export function RefundPanel({
  campaignAddress,
  campaignToken,
  currentState,
}: Props) {
  const t = useTranslations("detail.refund");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { address: user, isConnected } = useAccount();
  const { writeContractAsync } = useWriteContract();

  // Read the accepted tokens list — same payment tokens from which the
  // user might have purchased. Some entries may have 0 refundable amount.
  const { data: acceptedTokensRaw } = useReadContract({
    address: campaignAddress,
    abi: campaignAbi,
    functionName: "getAcceptedTokens",
  }) as { data: Address[] | undefined };

  // For each payment token: the user's refundable amount + token symbol + decimals.
  const perTokenContracts = useMemo(() => {
    if (!acceptedTokensRaw || !user) return [];
    return acceptedTokensRaw.flatMap((addr) => [
      {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "purchases",
        args: [user, addr],
      },
      { address: addr, abi: erc20Abi, functionName: "symbol" },
      { address: addr, abi: erc20Abi, functionName: "decimals" },
    ]);
  }, [acceptedTokensRaw, user, campaignAddress]);

  const { data: perTokenData, refetch: refetchRefundable } =
    useReadContracts({
      contracts: perTokenContracts as never,
      query: { enabled: perTokenContracts.length > 0, refetchInterval: 15_000 },
    });

  // User's current $CAMPAIGN balance — the contract burns their full stake
  // at refund time, so we display what they'll lose.
  const { data: campaignBalanceRaw, refetch: refetchBalance } = useReadContract(
    {
      address: campaignToken,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: user ? [user] : undefined,
      query: { enabled: !!user, refetchInterval: 15_000 },
    },
  ) as { data: bigint | undefined; refetch: () => void };

  const { data: campaignSymbolRaw } = useReadContract({
    address: campaignToken,
    abi: erc20Abi,
    functionName: "symbol",
  });
  const campSymbol = (campaignSymbolRaw as string | undefined) ?? "CAMP";

  type MaybeResult = { result?: unknown };
  const results = (perTokenData ?? []) as readonly MaybeResult[];

  const refundables = useMemo(() => {
    if (!acceptedTokensRaw) return [];
    return acceptedTokensRaw.map((addr, i) => {
      const amount = (results[i * 3]?.result as bigint | undefined) ?? 0n;
      const symbol = (results[i * 3 + 1]?.result as string | undefined) ?? "?";
      const decimals = (results[i * 3 + 2]?.result as number | undefined) ?? 18;
      return { address: addr, amount, symbol, decimals };
    });
  }, [acceptedTokensRaw, results]);

  const [pending, setPending] = useState<{
    token: Address;
    phase: "sig" | "chain";
  } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [successHash, setSuccessHash] = useState<`0x${string}` | null>(null);

  const handleRefund = async (token: Address) => {
    setError(null);
    setSuccessHash(null);
    setPending({ token, phase: "sig" });
    try {
      const hash = await writeContractAsync({
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "buyback",
        args: [token],
      });
      setPending({ token, phase: "chain" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("Refund reverted");
      await refetchRefundable();
      await refetchBalance();
      setSuccessHash(hash);
      notify.success(tx("buybackConfirmed"), hash);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!/user (rejected|denied)/i.test(msg)) setError(msg);
      notify.error(tx("buybackFailed"), err);
      console.error(err);
    } finally {
      setPending(null);
    }
  };

  // Nothing to refund at all? (wallet never bought, or already fully refunded)
  const hasAnything = refundables.some((r) => r.amount > 0n);
  const campaignBalance = campaignBalanceRaw ?? 0n;

  // Don't render for non-buyback states (the caller gates this anyway, but
  // defensive: avoid silently claiming state mismatch was user intent).
  if (currentState !== 2) return null;

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <div className="flex items-start gap-3 mb-4">
        <svg
          width="24"
          height="24"
          viewBox="0 0 24 24"
          fill="currentColor"
          className="text-amber-600 shrink-0"
        >
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z" />
        </svg>
        <div>
          <h2 className="text-2xl font-bold tracking-tight text-on-surface">
            {t("title")}
          </h2>
          <p className="text-sm text-on-surface-variant mt-1">
            {t("subtitle")}
          </p>
        </div>
      </div>

      {!isConnected ? (
        <div className="text-center text-sm text-on-surface-variant py-8">
          {t("connectFirst")}
        </div>
      ) : !hasAnything ? (
        <div className="bg-surface-container-low rounded-xl p-6 text-center text-sm text-on-surface-variant">
          {t("nothingToRefund")}
        </div>
      ) : (
        <>
          <div className="bg-surface-container-low rounded-xl p-4 mb-4 flex justify-between items-center text-sm">
            <span className="font-semibold text-on-surface-variant uppercase tracking-wider text-xs">
              {t("willBurn")}
            </span>
            <span className="font-bold text-on-surface">
              {Number(formatUnits(campaignBalance, 18)).toLocaleString(
                undefined,
                { maximumFractionDigits: 2 },
              )}{" "}
              ${campSymbol}
            </span>
          </div>

          <div className="space-y-3">
            {refundables
              .filter((r) => r.amount > 0n)
              .map((r) => {
                const isBusy = pending?.token === r.address;
                const label = isBusy
                  ? pending.phase === "sig"
                    ? t("refundSig")
                    : t("refundChain")
                  : t("refundCta", {
                      amount: Number(
                        formatUnits(r.amount, r.decimals),
                      ).toLocaleString(undefined, {
                        maximumFractionDigits: 2,
                      }),
                      symbol: r.symbol,
                    });
                return (
                  <div
                    key={r.address}
                    className="bg-surface-container-low rounded-xl p-4 flex justify-between items-center gap-4"
                  >
                    <div>
                      <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
                        {t("refundable")}
                      </div>
                      <div className="text-xl font-bold text-on-surface">
                        {Number(
                          formatUnits(r.amount, r.decimals),
                        ).toLocaleString(undefined, {
                          maximumFractionDigits: 2,
                        })}{" "}
                        {r.symbol}
                      </div>
                    </div>
                    <button
                      onClick={() => handleRefund(r.address)}
                      disabled={pending !== null}
                      className="regen-gradient text-white rounded-full px-5 h-10 font-semibold text-sm hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
                    >
                      {isBusy && <Spinner size={14} />}
                      {label}
                    </button>
                  </div>
                );
              })}
          </div>

          <p className="mt-4 text-xs text-on-surface-variant">
            {t("refundNote")}
          </p>
        </>
      )}

      {error && (
        <div className="mt-4 bg-red-50 border border-red-200 text-error rounded-lg p-3 text-xs break-words">
          {error}
        </div>
      )}
      {successHash && (
        <div className="mt-4 bg-primary-fixed/30 text-primary border border-primary/30 rounded-lg p-3 text-xs">
          {t("refundConfirmed")}{" "}
          <a
            href={`https://sepolia.basescan.org/tx/${successHash}`}
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

/**
 * CTA to flip a campaign from Funding → Buyback once the deadline has
 * elapsed without reaching min cap. Permissionless — anyone can call it,
 * since the refund path is the buyers' only recourse. Renders only when
 * the conditions are actually met (prevents a failed tx on state mismatch).
 */
export function TriggerBuybackCta({
  campaignAddress,
  currentState,
  currentSupply,
  minCap,
  fundingDeadline,
  onTriggered,
}: {
  campaignAddress: Address;
  currentState: number;
  currentSupply: bigint;
  minCap: bigint;
  fundingDeadline: bigint;
  onTriggered?: () => void;
}) {
  const t = useTranslations("detail.refund");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { writeContractAsync } = useWriteContract();

  const [pending, setPending] = useState<"sig" | "chain" | null>(null);
  const [error, setError] = useState<string | null>(null);

  const now = BigInt(Math.floor(Date.now() / 1000));
  const canTrigger =
    currentState === 0 && now >= fundingDeadline && currentSupply < minCap;

  if (!canTrigger) return null;

  const handleTrigger = async () => {
    setError(null);
    setPending("sig");
    try {
      const hash = await writeContractAsync({
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "triggerBuyback",
      });
      setPending("chain");
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("triggerBuyback reverted");
      onTriggered?.();
      notify.success(tx("triggerBuybackConfirmed"), hash);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!/user (rejected|denied)/i.test(msg)) setError(msg);
      notify.error(tx("triggerBuybackFailed"), err);
      console.error(err);
    } finally {
      setPending(null);
    }
  };

  return (
    <div className="bg-amber-50 border border-amber-200 rounded-xl p-4">
      <div className="flex items-start justify-between gap-3 mb-3">
        <div>
          <div className="font-bold text-amber-900 text-sm mb-1">
            {t("triggerTitle")}
          </div>
          <p className="text-xs text-amber-800">{t("triggerBody")}</p>
        </div>
      </div>
      <button
        onClick={handleTrigger}
        disabled={pending !== null}
        className="bg-amber-900 text-white rounded-full h-10 px-5 font-semibold text-sm hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
      >
        {pending && <Spinner size={14} />}
        {pending === "sig"
          ? t("triggerSig")
          : pending === "chain"
            ? t("triggerChain")
            : t("triggerCta")}
      </button>
      {error && (
        <div className="mt-2 bg-red-50 border border-red-200 text-error rounded-lg p-2 text-xs break-words">
          {error}
        </div>
      )}
    </div>
  );
}
