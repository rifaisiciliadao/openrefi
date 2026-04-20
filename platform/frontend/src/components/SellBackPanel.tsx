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
  campaignAddress: Address;
  campaignToken: Address;
  /** Campaign.state enum — 0=Funding, 1=Active, 2=Buyback, 3=Ended */
  currentState: number;
}

const campaignAbi = abis.Campaign as never;
const MAX_ORDERS_PER_USER = 50;

/**
 * Sell-back queue UI — lets holders queue their $CAMPAIGN to be refunded
 * by the next incoming buyers during Active state. Each new `buy()` fills
 * the head of this FIFO queue first (in `_fillSellBackQueue`), so the
 * earlier you queue, the sooner you get your payment token back.
 *
 * Rendered only during Active (contract reverts otherwise). The user first
 * approves the campaign to pull their $CAMPAIGN, then calls sellBack(amount).
 * Cancel returns any remaining unfilled queue entries.
 */
export function SellBackPanel({
  campaignAddress,
  campaignToken,
  currentState,
}: Props) {
  const t = useTranslations("detail.sellBack");
  const tx = useTranslations("tx");
  const notify = useTxNotify();
  const { address: user, isConnected } = useAccount();
  const { writeContractAsync } = useWriteContract();

  const [amount, setAmount] = useState("");
  const [pending, setPending] = useState<{
    kind: "approve" | "sellBack" | "cancel";
    phase: "sig" | "chain";
  } | null>(null);
  const [error, setError] = useState<string | null>(null);

  // User balance + allowance to the campaign + pending sell-back + open order count.
  const { data: userData, refetch } = useReadContracts({
    contracts: user
      ? [
          { address: campaignToken, abi: erc20Abi, functionName: "balanceOf", args: [user] },
          {
            address: campaignToken,
            abi: erc20Abi,
            functionName: "allowance",
            args: [user, campaignAddress],
          },
          {
            address: campaignAddress,
            abi: campaignAbi,
            functionName: "pendingSellBack",
            args: [user],
          },
          {
            address: campaignAddress,
            abi: campaignAbi,
            functionName: "openSellBackCount",
            args: [user],
          },
        ]
      : [],
    query: { enabled: !!user, refetchInterval: 15_000 },
  });

  const { data: symbolRaw } = useReadContract({
    address: campaignToken,
    abi: erc20Abi,
    functionName: "symbol",
  });
  const campSymbol = (symbolRaw as string | undefined) ?? "CAMP";

  const balance = (userData?.[0]?.result as bigint | undefined) ?? 0n;
  const allowance = (userData?.[1]?.result as bigint | undefined) ?? 0n;
  const pendingQueued =
    (userData?.[2]?.result as bigint | undefined) ?? 0n;
  const openOrderCount = Number(
    (userData?.[3]?.result as bigint | undefined) ?? 0n,
  );

  const parsedAmount = useMemo(() => {
    if (!amount || Number(amount) <= 0) return 0n;
    try {
      return parseUnits(amount, 18);
    } catch {
      return 0n;
    }
  }, [amount]);

  const needsApproval = parsedAmount > 0n && allowance < parsedAmount;
  const tooManyOrders = openOrderCount >= MAX_ORDERS_PER_USER;
  const canSubmit =
    isConnected &&
    currentState === 1 &&
    parsedAmount > 0n &&
    parsedAmount <= balance &&
    !tooManyOrders;

  const handleError = (err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    if (!/user (rejected|denied)/i.test(msg)) setError(msg);
    console.error(err);
  };

  const handleApprove = async () => {
    setError(null);
    setPending({ kind: "approve", phase: "sig" });
    try {
      const hash = await writeContractAsync({
        address: campaignToken,
        abi: erc20Abi,
        functionName: "approve",
        args: [campaignAddress, parsedAmount],
      });
      setPending({ kind: "approve", phase: "chain" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("Approve reverted");
      await refetch();
      notify.success(tx("approvalConfirmed"), hash);
    } catch (err) {
      handleError(err);
      notify.error(tx("approvalFailed"), err);
    } finally {
      setPending(null);
    }
  };

  const handleSellBack = async () => {
    setError(null);
    setPending({ kind: "sellBack", phase: "sig" });
    try {
      const hash = await writeContractAsync({
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "sellBack",
        args: [parsedAmount],
      });
      setPending({ kind: "sellBack", phase: "chain" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("sellBack reverted");
      setAmount("");
      await refetch();
      notify.success(tx("sellBackConfirmed"), hash);
    } catch (err) {
      handleError(err);
      notify.error(tx("sellBackFailed"), err);
    } finally {
      setPending(null);
    }
  };

  const handleCancel = async () => {
    setError(null);
    setPending({ kind: "cancel", phase: "sig" });
    try {
      const hash = await writeContractAsync({
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "cancelSellBack",
      });
      setPending({ kind: "cancel", phase: "chain" });
      const r = await waitForTransactionReceipt(config, { hash });
      if (r.status !== "success") throw new Error("cancelSellBack reverted");
      await refetch();
      notify.success(tx("cancelSellBackConfirmed"), hash);
    } catch (err) {
      handleError(err);
      notify.error(tx("cancelSellBackFailed"), err);
    } finally {
      setPending(null);
    }
  };

  // Don't render unless Active — sellBack reverts from any other state.
  if (currentState !== 1) return null;

  // Don't render anything if the user has no balance AND no pending queue.
  if (!isConnected) return null;
  if (balance === 0n && pendingQueued === 0n) return null;

  const submitBusy =
    pending?.kind === "approve" || pending?.kind === "sellBack";
  const submitLabel = needsApproval
    ? pending?.kind === "approve" && pending.phase === "sig"
      ? t("approvingSig")
      : pending?.kind === "approve" && pending.phase === "chain"
        ? t("approvingChain")
        : t("approveCta", { symbol: campSymbol })
    : pending?.kind === "sellBack" && pending.phase === "sig"
      ? t("sellBackSig")
      : pending?.kind === "sellBack" && pending.phase === "chain"
        ? t("sellBackChain")
        : t("sellBackCta");

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-6 border border-outline-variant/15">
      <h3 className="text-lg font-bold tracking-tight text-on-surface mb-1">
        {t("title")}
      </h3>
      <p className="text-xs text-on-surface-variant mb-4">{t("subtitle")}</p>

      {/* Pending queue summary + cancel */}
      {pendingQueued > 0n && (
        <div className="bg-surface-container-low rounded-xl p-4 mb-4 flex items-center justify-between gap-4">
          <div>
            <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
              {t("pendingInQueue")}
            </div>
            <div className="text-lg font-bold text-on-surface">
              {Number(formatUnits(pendingQueued, 18)).toLocaleString(undefined, {
                maximumFractionDigits: 2,
              })}{" "}
              ${campSymbol}
            </div>
            <div className="text-[11px] text-on-surface-variant mt-0.5">
              {t("openOrders", { count: openOrderCount })}
            </div>
          </div>
          <button
            onClick={handleCancel}
            disabled={pending !== null}
            className="bg-surface-container text-on-surface border border-outline-variant/30 rounded-full px-4 h-9 text-xs font-semibold hover:bg-surface-container-high transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-1.5"
          >
            {pending?.kind === "cancel" && <Spinner size={12} />}
            {pending?.kind === "cancel" && pending.phase === "sig"
              ? t("cancelSig")
              : pending?.kind === "cancel" && pending.phase === "chain"
                ? t("cancelChain")
                : t("cancelCta")}
          </button>
        </div>
      )}

      {/* Request form — hidden if user has no $CAMPAIGN to sell back */}
      {balance > 0n && (
        <div className="bg-surface-container-low rounded-xl p-4">
          <div className="flex justify-between items-center mb-2">
            <label className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
              {t("amountLabel")}
            </label>
            <button
              onClick={() => setAmount(formatUnits(balance, 18))}
              className="text-xs text-on-surface-variant hover:text-primary transition-colors"
              disabled={submitBusy}
            >
              {t("balance", {
                amount: Number(formatUnits(balance, 18)).toFixed(2),
                symbol: campSymbol,
              })}
            </button>
          </div>
          <div className="flex items-center gap-2 mb-3">
            <input
              type="number"
              step="0.01"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder="0.00"
              disabled={submitBusy}
              className="flex-1 bg-transparent border-none outline-none text-2xl font-bold text-on-surface p-0"
            />
            <span className="text-sm font-semibold text-on-surface-variant">
              ${campSymbol}
            </span>
          </div>
          {tooManyOrders && (
            <div className="bg-red-50 border border-red-200 text-error rounded-lg p-2 mb-3 text-xs">
              {t("tooManyOrders", { max: MAX_ORDERS_PER_USER })}
            </div>
          )}
          <button
            onClick={needsApproval ? handleApprove : handleSellBack}
            disabled={!canSubmit || pending !== null}
            className="w-full regen-gradient text-white rounded-full h-11 font-semibold text-sm hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
          >
            {submitBusy && <Spinner size={14} />}
            {submitLabel}
          </button>
          <p className="text-[11px] text-on-surface-variant mt-2">
            {t("note")}
          </p>
        </div>
      )}

      {error && (
        <div className="mt-3 bg-red-50 border border-red-200 text-error rounded-lg p-3 text-xs break-words">
          {error}
        </div>
      )}
    </div>
  );
}
