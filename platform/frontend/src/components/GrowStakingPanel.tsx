"use client";

import { useMemo, useState } from "react";
import { useAccount, useReadContracts, useWriteContract } from "wagmi";
import { formatUnits, parseUnits, type Address } from "viem";
import { useTranslations } from "next-intl";
import { abis, getAddresses } from "@/contracts";
import { erc20Abi } from "@/contracts/erc20";
import { Spinner } from "./Spinner";
import { useTxNotify } from "@/lib/useTxNotify";
import { waitForTx } from "@/lib/waitForTx";

const growTokenAbi = abis.GrowToken as never;
const stakingPoolAbi = abis.GrowStakingPool as never;

type Tab = "stake" | "withdraw";

type TxStatus =
  | { kind: "idle" }
  | { kind: "approving-sig" }
  | { kind: "approving-chain" }
  | { kind: "submitting-sig" }
  | { kind: "submitting-chain" }
  | { kind: "claiming-sig" }
  | { kind: "claiming-chain" }
  | { kind: "success"; hash: `0x${string}` }
  | { kind: "error"; message: string };

const RAMP_DURATION_S = 365 * 24 * 60 * 60;

/**
 * Stake GROW, earn USDC. Time-in-pool multiplier ramps continuously from 1.0×
 * to 2.0× over 365 days. Any withdraw resets the streak.
 *
 * Reads via batched useReadContracts (10s refetch):
 *   - GROW balance + allowance to staking pool
 *   - balanceOf in pool, effectiveBalanceOf, multiplierBps stored
 *   - previewMultiplier (live, not yet applied)
 *   - streakStartAt for the countdown to the cap
 *   - earned (pending USDC)
 *   - rewardRate, periodFinish (so we can show "rewards over X days")
 *
 * Writes:
 *   - approve(GROW → stakingPool, amount)
 *   - stake(amount) | withdraw(amount) | claim()
 */
export function GrowStakingPanel() {
  const t = useTranslations("grow.stake");
  const { address: account, isConnected } = useAccount();
  const a = getAddresses();
  const notify = useTxNotify();
  const { writeContractAsync } = useWriteContract();

  const [tab, setTab] = useState<Tab>("stake");
  const [amountInput, setAmountInput] = useState<string>("");
  const [tx, setTx] = useState<TxStatus>({ kind: "idle" });

  const enabled = Boolean(a.growToken && a.growStakingPool);

  const { data: reads, refetch } = useReadContracts({
    query: { enabled, refetchInterval: 10_000 },
    contracts: [
      {
        abi: erc20Abi,
        address: a.growToken as Address,
        functionName: "balanceOf",
        args: account ? [account] : undefined,
      },
      {
        abi: erc20Abi,
        address: a.growToken as Address,
        functionName: "allowance",
        args: account ? [account, a.growStakingPool as Address] : undefined,
      },
      {
        abi: stakingPoolAbi,
        address: a.growStakingPool as Address,
        functionName: "balanceOf",
        args: account ? [account] : undefined,
      },
      {
        abi: stakingPoolAbi,
        address: a.growStakingPool as Address,
        functionName: "multiplierBps",
        args: account ? [account] : undefined,
      },
      {
        abi: stakingPoolAbi,
        address: a.growStakingPool as Address,
        functionName: "previewMultiplier",
        args: account ? [account] : undefined,
      },
      {
        abi: stakingPoolAbi,
        address: a.growStakingPool as Address,
        functionName: "streakStartAt",
        args: account ? [account] : undefined,
      },
      {
        abi: stakingPoolAbi,
        address: a.growStakingPool as Address,
        functionName: "earned",
        args: account ? [account] : undefined,
      },
      {
        abi: stakingPoolAbi,
        address: a.growStakingPool as Address,
        functionName: "rewardRate",
      },
      {
        abi: stakingPoolAbi,
        address: a.growStakingPool as Address,
        functionName: "periodFinish",
      },
      {
        abi: stakingPoolAbi,
        address: a.growStakingPool as Address,
        functionName: "totalStaked",
      },
    ],
  });

  const growBalance = (reads?.[0]?.result as bigint | undefined) ?? 0n;
  const allowance = (reads?.[1]?.result as bigint | undefined) ?? 0n;
  const staked = (reads?.[2]?.result as bigint | undefined) ?? 0n;
  const storedMul = (reads?.[3]?.result as bigint | undefined) ?? 0n;
  const liveMul = (reads?.[4]?.result as bigint | undefined) ?? 0n;
  const streakStart = (reads?.[5]?.result as bigint | undefined) ?? 0n;
  const earned = (reads?.[6]?.result as bigint | undefined) ?? 0n;
  const rewardRate = (reads?.[7]?.result as bigint | undefined) ?? 0n;
  const periodFinish = (reads?.[8]?.result as bigint | undefined) ?? 0n;
  const totalStaked = (reads?.[9]?.result as bigint | undefined) ?? 0n;

  const amount = useMemo(() => {
    if (!amountInput) return 0n;
    try {
      return parseUnits(amountInput, 18);
    } catch {
      return 0n;
    }
  }, [amountInput]);

  const needsApproval = tab === "stake" && amount > 0n && allowance < amount;
  const insufficient =
    tab === "stake" ? amount > growBalance : amount > staked;

  const liveMulPct = Number(liveMul) / 100; // bps → percent
  const storedMulPct = Number(storedMul) / 100;

  const secondsUntilCap = useMemo(() => {
    if (streakStart === 0n) return RAMP_DURATION_S;
    const elapsed = Math.floor(Date.now() / 1000) - Number(streakStart);
    return Math.max(0, RAMP_DURATION_S - elapsed);
  }, [streakStart]);

  const periodSecondsLeft = useMemo(() => {
    const now = Math.floor(Date.now() / 1000);
    return Math.max(0, Number(periodFinish) - now);
  }, [periodFinish]);

  const isBusy =
    tx.kind !== "idle" && tx.kind !== "success" && tx.kind !== "error";

  async function handleStakeOrWithdraw() {
    if (!account || amount === 0n || !a.growToken || !a.growStakingPool) return;
    try {
      if (tab === "stake" && needsApproval) {
        setTx({ kind: "approving-sig" });
        const approveHash = await writeContractAsync({
          abi: erc20Abi,
          address: a.growToken as Address,
          functionName: "approve",
          args: [a.growStakingPool, amount],
        });
        setTx({ kind: "approving-chain" });
        await waitForTx(approveHash);
      }

      setTx({ kind: "submitting-sig" });
      const hash = await writeContractAsync({
        abi: stakingPoolAbi,
        address: a.growStakingPool as Address,
        functionName: tab === "stake" ? "stake" : "withdraw",
        args: [amount],
      });
      setTx({ kind: "submitting-chain" });
      await waitForTx(hash);
      notify.success(tab === "stake" ? "Staked" : "Withdrawn", hash);
      setTx({ kind: "success", hash });
      setAmountInput("");
      refetch();
    } catch (err) {
      const message =
        (err as Error).message?.split("\n")[0] ?? "Transaction failed";
      if (/user (rejected|denied)/i.test(message)) {
        setTx({ kind: "idle" });
        return;
      }
      notify.error(`${tab === "stake" ? "Stake" : "Withdraw"} failed`, message);
      setTx({ kind: "error", message });
    }
  }

  async function handleClaim() {
    if (!account || !a.growStakingPool) return;
    try {
      setTx({ kind: "claiming-sig" });
      const hash = await writeContractAsync({
        abi: stakingPoolAbi,
        address: a.growStakingPool as Address,
        functionName: "claim",
      });
      setTx({ kind: "claiming-chain" });
      await waitForTx(hash);
      notify.success("Claimed USDC", hash);
      setTx({ kind: "success", hash });
      refetch();
    } catch (err) {
      const message =
        (err as Error).message?.split("\n")[0] ?? "Transaction failed";
      if (/user (rejected|denied)/i.test(message)) {
        setTx({ kind: "idle" });
        return;
      }
      notify.error("Claim failed", message);
      setTx({ kind: "error", message });
    }
  }

  if (!a.growStakingPool || !a.growToken) {
    return (
      <div className="rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
        {t("notDeployed")}
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-zinc-200 bg-white p-6 shadow-sm">
      <div className="mb-1 flex items-baseline justify-between">
        <h2 className="text-xl font-semibold text-zinc-900">{t("title")}</h2>
        <span className="text-xs text-zinc-500">
          {t("totalStaked", {
            amount: Number(formatUnits(totalStaked, 18)).toFixed(2),
          })}
        </span>
      </div>
      <p className="mb-4 text-sm text-zinc-500">{t("blurb")}</p>

      {/* Multiplier */}
      <div className="mb-4 grid grid-cols-3 gap-3 rounded-lg border border-zinc-200 bg-zinc-50 p-3 text-sm">
        <div>
          <div className="text-xs uppercase tracking-wide text-zinc-500">
            {t("multiplier")}
          </div>
          <div className="font-mono text-emerald-700">
            {staked === 0n ? "—" : `${(liveMulPct / 100).toFixed(2)}×`}
          </div>
          {storedMul !== liveMul && staked > 0n && (
            <div className="mt-1 text-[10px] text-zinc-500">
              {t("multiplierStored", {
                value: (storedMulPct / 100).toFixed(2),
              })}
            </div>
          )}
        </div>
        <div>
          <div className="text-xs uppercase tracking-wide text-zinc-500">
            {t("timeToCap")}
          </div>
          <div className="font-mono text-zinc-900">
            {staked === 0n
              ? "—"
              : secondsUntilCap === 0
                ? t("max")
                : `${Math.ceil(secondsUntilCap / 86400)}d`}
          </div>
        </div>
        <div>
          <div className="text-xs uppercase tracking-wide text-zinc-500">
            {t("pendingUsdc")}
          </div>
          <div className="font-mono text-zinc-900">
            {Number(formatUnits(earned, 6)).toFixed(4)}
          </div>
          {rewardRate > 0n && periodSecondsLeft > 0 && (
            <div className="mt-1 text-[10px] text-zinc-500">
              {t("distEndsIn", {
                days: Math.ceil(periodSecondsLeft / 86400),
              })}
            </div>
          )}
        </div>
      </div>

      {/* Tabs */}
      <div className="mb-3 flex gap-1 rounded-lg bg-zinc-100 p-1 text-sm font-medium">
        <button
          type="button"
          onClick={() => {
            setTab("stake");
            setAmountInput("");
          }}
          className={`flex-1 rounded-md px-3 py-2 transition ${
            tab === "stake"
              ? "bg-white text-zinc-900 shadow-sm"
              : "text-zinc-500"
          }`}
        >
          {t("stakeTab")}
        </button>
        <button
          type="button"
          onClick={() => {
            setTab("withdraw");
            setAmountInput("");
          }}
          className={`flex-1 rounded-md px-3 py-2 transition ${
            tab === "withdraw"
              ? "bg-white text-zinc-900 shadow-sm"
              : "text-zinc-500"
          }`}
        >
          {t("withdrawTab")}
        </button>
      </div>

      {tab === "withdraw" && staked > 0n && (
        <div className="mb-3 rounded-lg border border-amber-300 bg-amber-50 p-3 text-xs text-amber-900">
          {t("withdrawWarning")}
        </div>
      )}

      <label className="mb-1 block text-xs uppercase tracking-wide text-zinc-500">
        {tab === "stake" ? t("amountToStake") : t("amountToWithdraw")}
      </label>
      <div className="mb-3 flex items-stretch gap-2">
        <input
          type="text"
          inputMode="decimal"
          value={amountInput}
          onChange={(e) => setAmountInput(e.target.value)}
          placeholder="0.00"
          className="w-full rounded-lg border border-zinc-300 px-3 py-2 font-mono text-lg focus:border-emerald-600 focus:outline-none"
        />
        <button
          type="button"
          onClick={() =>
            setAmountInput(
              tab === "stake"
                ? formatUnits(growBalance, 18)
                : formatUnits(staked, 18),
            )
          }
          className="rounded-lg bg-zinc-100 px-3 text-xs font-medium text-zinc-700 hover:bg-zinc-200"
        >
          {t("max")}
        </button>
      </div>
      <div className="mb-4 flex justify-between text-xs text-zinc-500">
        <span>
          {t("wallet")}:{" "}
          <span className="font-mono">
            {Number(formatUnits(growBalance, 18)).toFixed(4)}
          </span>{" "}
          $GROW
        </span>
        <span>
          {t("stakedLabel")}:{" "}
          <span className="font-mono">
            {Number(formatUnits(staked, 18)).toFixed(4)}
          </span>{" "}
          $GROW
        </span>
      </div>
      {insufficient && (
        <p className="mb-2 text-xs text-rose-600">
          {tab === "stake" ? t("insufficientBalance") : t("insufficientStaked")}
        </p>
      )}

      <button
        type="button"
        onClick={handleStakeOrWithdraw}
        disabled={!isConnected || isBusy || amount === 0n || insufficient}
        className="mb-2 flex w-full items-center justify-center gap-2 rounded-lg bg-emerald-600 px-4 py-3 text-sm font-semibold text-white transition hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300"
      >
        {isBusy && tx.kind !== "claiming-sig" && tx.kind !== "claiming-chain" && (
          <Spinner />
        )}
        {!isConnected
          ? t("connectWallet")
          : tx.kind === "approving-sig"
            ? t("approveGrow")
            : tx.kind === "approving-chain"
              ? t("approvingChain")
              : tx.kind === "submitting-sig"
                ? t("submittingSig")
                : tx.kind === "submitting-chain"
                  ? t("submittingChain")
                  : tab === "stake"
                    ? needsApproval
                      ? t("approveAndStake")
                      : t("stakeButton")
                    : t("withdrawButton")}
      </button>

      <button
        type="button"
        onClick={handleClaim}
        disabled={!isConnected || isBusy || earned === 0n}
        className="flex w-full items-center justify-center gap-2 rounded-lg border border-emerald-600 bg-white px-4 py-2.5 text-sm font-semibold text-emerald-700 transition hover:bg-emerald-50 disabled:cursor-not-allowed disabled:border-zinc-300 disabled:text-zinc-400"
      >
        {(tx.kind === "claiming-sig" || tx.kind === "claiming-chain") && (
          <Spinner />
        )}
        {tx.kind === "claiming-sig"
          ? t("claimSig")
          : tx.kind === "claiming-chain"
            ? t("claimingChain")
            : earned === 0n
              ? t("nothingToClaim")
              : t("claim", {
                  amount: Number(formatUnits(earned, 6)).toFixed(4),
                })}
      </button>

      {tx.kind === "error" && (
        <p className="mt-2 text-xs text-rose-600">{tx.message}</p>
      )}
    </div>
  );
}
