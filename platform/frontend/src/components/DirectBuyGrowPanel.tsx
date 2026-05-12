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

type StableOption = {
  address: Address;
  symbol: string;
  decimals: number;
};

type TxStatus =
  | { kind: "idle" }
  | { kind: "approving-sig" }
  | { kind: "approving-chain" }
  | { kind: "buying-sig" }
  | { kind: "buying-chain" }
  | { kind: "minting-sig" }
  | { kind: "minting-chain" }
  | { kind: "success"; hash: `0x${string}` }
  | { kind: "error"; message: string };

const growTokenAbi = abis.GrowToken as never;
const growTreasuryAbi = abis.GrowTreasury as never;

/// Both MockUSDC and MockStablecoin expose `mint(address, uint256)` permissionlessly
/// on testnet/anvil. Constructor revert on mainnet chain ids guards production.
const mockMintAbi = [
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

/**
 * GROW direct-buy panel.
 *
 * Reads:
 *  - Treasury.intrinsicFloorPrice (USD-18 per circulating GROW)
 *  - Token.markupBps + Token.referencePrice (fallback path)
 *  - Token.saleActive (kill switch)
 *  - Per-stablecoin: Treasury.getStablecoinPriceUsd18 (live Chainlink)
 *
 * Writes (2 sigs):
 *  - ERC20.approve(GROW token, paymentAmount)
 *  - GrowToken.buy(paymentToken, paymentAmount, maxPriceAccepted)
 *
 * The depeg banner fires when getStablecoinPriceUsd18 reverts — buy stays
 * disabled until the user picks a healthy stablecoin (or the multisig
 * removes the depegged one from the allowlist).
 */
export function DirectBuyGrowPanel() {
  const t = useTranslations("grow.buy");
  const { address: account, isConnected } = useAccount();
  const a = getAddresses();
  const notify = useTxNotify();
  const { writeContractAsync } = useWriteContract();

  /// Faucet visible on testnets where the stablecoins are MockUSDC/MockStablecoin
  /// (public mint). Mainnet stablecoins do NOT have public mint, so the button
  /// is gated. Allow: anvil (31337), Base Sepolia (84532), ETH Sepolia (11155111).
  const chainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID || 84532);
  const faucetEnabled = chainId === 31337 || chainId === 84532 || chainId === 11155111;

  const stableOptions = useMemo<StableOption[]>(() => {
    const out: StableOption[] = [];
    if (a.usdc) out.push({ address: a.usdc, symbol: "USDC", decimals: 6 });
    if (a.usdt) out.push({ address: a.usdt, symbol: "USDT", decimals: 6 });
    if (a.dai) out.push({ address: a.dai, symbol: "DAI", decimals: 18 });
    return out;
  }, [a.usdc, a.usdt, a.dai]);

  const [selectedSym, setSelectedSym] = useState<string>(
    stableOptions[0]?.symbol ?? "USDC",
  );
  const [paymentInput, setPaymentInput] = useState<string>("100");
  const [tx, setTx] = useState<TxStatus>({ kind: "idle" });

  const selected =
    stableOptions.find((s) => s.symbol === selectedSym) ?? stableOptions[0];

  // Quote & balance reads
  const { data: reads, refetch } = useReadContracts({
    query: { enabled: Boolean(a.growToken && a.growTreasury && selected) },
    contracts: [
      {
        abi: growTreasuryAbi,
        address: a.growTreasury as Address,
        functionName: "intrinsicFloorPrice",
      },
      {
        abi: growTokenAbi,
        address: a.growToken as Address,
        functionName: "markupBps",
      },
      {
        abi: growTokenAbi,
        address: a.growToken as Address,
        functionName: "referencePrice",
      },
      {
        abi: growTokenAbi,
        address: a.growToken as Address,
        functionName: "saleActive",
      },
      {
        abi: growTreasuryAbi,
        address: a.growTreasury as Address,
        functionName: "getStablecoinPriceUsd18",
        args: selected ? [selected.address] : undefined,
      },
      {
        abi: erc20Abi,
        address: selected?.address as Address,
        functionName: "balanceOf",
        args: account ? [account] : undefined,
      },
      {
        abi: erc20Abi,
        address: selected?.address as Address,
        functionName: "allowance",
        args: account ? [account, a.growToken as Address] : undefined,
      },
    ],
  });

  const floor = (reads?.[0]?.result as bigint | undefined) ?? 0n;
  const markupBps = (reads?.[1]?.result as bigint | undefined) ?? 1_000n;
  const referencePrice = (reads?.[2]?.result as bigint | undefined) ?? 0n;
  const saleActive = (reads?.[3]?.result as boolean | undefined) ?? false;
  const stablePrice = reads?.[4]; // result | error
  const balance = (reads?.[5]?.result as bigint | undefined) ?? 0n;
  const allowance = (reads?.[6]?.result as bigint | undefined) ?? 0n;

  const stableDepegged = Boolean(stablePrice?.error);
  const livePriceUsd18 = (stablePrice?.result as bigint | undefined) ?? 0n;

  const refPrice = floor > 0n ? floor : referencePrice;
  const salePrice = useMemo(() => {
    if (refPrice === 0n) return 0n;
    return (refPrice * (10_000n + markupBps)) / 10_000n;
  }, [refPrice, markupBps]);

  const paymentAmount = useMemo(() => {
    if (!selected || !paymentInput) return 0n;
    try {
      return parseUnits(paymentInput, selected.decimals);
    } catch {
      return 0n;
    }
  }, [paymentInput, selected]);

  // growOut = paymentAmount × scale × livePriceUsd18 / salePrice
  // scale = 10^(18 - decimals) for stablecoins.
  const growOut = useMemo(() => {
    if (
      !selected ||
      paymentAmount === 0n ||
      salePrice === 0n ||
      livePriceUsd18 === 0n
    )
      return 0n;
    const scale = 10n ** BigInt(18 - selected.decimals);
    return (paymentAmount * scale * livePriceUsd18) / salePrice;
  }, [paymentAmount, salePrice, livePriceUsd18, selected]);

  const needsApproval = paymentAmount > 0n && allowance < paymentAmount;
  const insufficientBalance = paymentAmount > 0n && balance < paymentAmount;

  const isBusy = tx.kind !== "idle" && tx.kind !== "success" && tx.kind !== "error";

  async function handleMint() {
    if (!account || !selected || !faucetEnabled) return;
    try {
      setTx({ kind: "minting-sig" });
      const amount = selected.decimals === 6 ? 10_000n * 10n ** 6n : 10_000n * 10n ** 18n;
      const hash = await writeContractAsync({
        abi: mockMintAbi,
        address: selected.address,
        functionName: "mint",
        args: [account, amount],
      });
      setTx({ kind: "minting-chain" });
      await waitForTx(hash);
      notify.success(`Minted 10,000 ${selected.symbol}`, hash);
      setTx({ kind: "idle" });
      refetch();
    } catch (err) {
      const message =
        (err as Error).message?.split("\n")[0] ?? "Transaction failed";
      if (/user (rejected|denied)/i.test(message)) {
        setTx({ kind: "idle" });
        return;
      }
      notify.error("Mint failed", message);
      setTx({ kind: "error", message });
    }
  }

  async function handleBuy() {
    if (
      !account ||
      !selected ||
      !a.growToken ||
      paymentAmount === 0n ||
      stableDepegged
    )
      return;

    try {
      if (needsApproval) {
        setTx({ kind: "approving-sig" });
        const approveHash = await writeContractAsync({
          abi: erc20Abi,
          address: selected.address,
          functionName: "approve",
          args: [a.growToken, paymentAmount],
        });
        setTx({ kind: "approving-chain" });
        await waitForTx(approveHash);
      }

      // Slippage cap: accept up to +5% beyond current salePrice
      const maxPriceAccepted = (salePrice * 10_500n) / 10_000n;

      setTx({ kind: "buying-sig" });
      const buyHash = await writeContractAsync({
        abi: growTokenAbi,
        address: a.growToken as Address,
        functionName: "buy",
        args: [selected.address, paymentAmount, maxPriceAccepted],
      });
      setTx({ kind: "buying-chain" });
      await waitForTx(buyHash);
      notify.success("Bought GROW", buyHash);
      setTx({ kind: "success", hash: buyHash });
      refetch();
    } catch (err) {
      const message =
        (err as Error).message?.split("\n")[0] ?? "Transaction failed";
      if (/user (rejected|denied)/i.test(message)) {
        setTx({ kind: "idle" });
        return;
      }
      notify.error("Buy failed", message);
      setTx({ kind: "error", message });
    }
  }

  if (!a.growToken || !a.growTreasury) {
    return (
      <div className="rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
        {t("notDeployed")}
      </div>
    );
  }

  const markupPct = Number(markupBps) / 100;

  return (
    <div className="rounded-xl border border-zinc-200 bg-white p-6 shadow-sm">
      <h2 className="mb-1 text-xl font-semibold text-zinc-900">{t("title")}</h2>
      <p className="mb-4 text-sm text-zinc-500">{t("blurb")}</p>

      {!saleActive && (
        <div className="mb-4 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
          {t("salePaused")}
        </div>
      )}

      {/* Quote header — only Sale price (floor lives in the page-level stat strip) */}
      <div className="mb-4 rounded-lg border border-zinc-200 bg-zinc-50 p-3 text-sm">
        <div className="text-xs uppercase tracking-wide text-zinc-500">
          {t("salePrice")}
        </div>
        <div className="font-mono text-zinc-900">
          {salePrice === 0n ? "—" : `$${formatUnits(salePrice, 18)}`}
        </div>
      </div>

      {/* Stablecoin selector */}
      <div className="mb-1 flex items-baseline justify-between">
        <label className="block text-xs uppercase tracking-wide text-zinc-500">
          {t("payWith")}
        </label>
        {faucetEnabled && isConnected && selected && (
          <button
            type="button"
            onClick={handleMint}
            disabled={
              tx.kind === "minting-sig" || tx.kind === "minting-chain"
            }
            className="text-xs font-medium text-emerald-700 hover:underline disabled:cursor-not-allowed disabled:text-zinc-400"
          >
            {tx.kind === "minting-sig"
              ? t("confirmInWallet")
              : tx.kind === "minting-chain"
                ? t("minting")
                : t("mintFaucet", { symbol: selected.symbol })}
          </button>
        )}
      </div>
      <div className="mb-3 flex gap-2">
        {stableOptions.map((s) => (
          <button
            key={s.symbol}
            type="button"
            onClick={() => setSelectedSym(s.symbol)}
            className={`rounded-lg px-3 py-2 text-sm font-medium transition ${
              selectedSym === s.symbol
                ? "bg-emerald-600 text-white"
                : "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
            }`}
          >
            {s.symbol}
          </button>
        ))}
      </div>

      {/* Depeg banner */}
      {stableDepegged && selected && (
        <div className="mb-3 rounded-lg border border-rose-300 bg-rose-50 p-3 text-sm text-rose-900">
          {t("depegged", { symbol: selected.symbol })}
        </div>
      )}

      {/* Amount input */}
      <label className="mb-1 block text-xs uppercase tracking-wide text-zinc-500">
        {t("youPay")}
      </label>
      <div className="mb-3 flex items-stretch gap-2">
        <input
          type="text"
          inputMode="decimal"
          value={paymentInput}
          onChange={(e) => setPaymentInput(e.target.value)}
          placeholder="0.00"
          className="w-full rounded-lg border border-zinc-300 px-3 py-2 font-mono text-lg focus:border-emerald-600 focus:outline-none"
        />
        <div className="flex w-20 items-center justify-center rounded-lg bg-zinc-100 text-sm font-medium text-zinc-600">
          {selected?.symbol}
        </div>
      </div>
      <div className="mb-4 flex justify-between text-xs text-zinc-500">
        <span>
          {t("balance")}:{" "}
          <span className="font-mono">
            {selected ? formatUnits(balance, selected.decimals) : "—"}
          </span>
        </span>
        {insufficientBalance && (
          <span className="text-rose-600">{t("insufficientBalance")}</span>
        )}
      </div>

      {/* You receive */}
      <div className="mb-4 rounded-lg border border-emerald-200 bg-emerald-50 p-3">
        <div className="text-xs uppercase tracking-wide text-emerald-700">
          {t("youReceive")}
        </div>
        <div className="font-mono text-2xl text-emerald-900">
          {growOut === 0n ? "—" : Number(formatUnits(growOut, 18)).toFixed(4)}
        </div>
        <div className="text-xs text-emerald-700">$GROW</div>
      </div>

      <button
        type="button"
        onClick={handleBuy}
        disabled={
          !isConnected ||
          !saleActive ||
          stableDepegged ||
          isBusy ||
          paymentAmount === 0n ||
          insufficientBalance ||
          salePrice === 0n
        }
        className="flex w-full items-center justify-center gap-2 rounded-lg bg-emerald-600 px-4 py-3 text-sm font-semibold text-white transition hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300"
      >
        {isBusy && <Spinner />}
        {!isConnected
          ? t("connectWallet")
          : tx.kind === "approving-sig"
            ? t("approvingSig")
            : tx.kind === "approving-chain"
              ? t("approvingChain")
              : tx.kind === "buying-sig"
                ? t("buyingSig")
                : tx.kind === "buying-chain"
                  ? t("buyingChain")
                  : needsApproval && selected
                    ? t("approveAndBuy", { symbol: selected.symbol })
                    : t("buyButton")}
      </button>

      {tx.kind === "error" && (
        <p className="mt-2 text-xs text-rose-600">{tx.message}</p>
      )}
    </div>
  );
}
