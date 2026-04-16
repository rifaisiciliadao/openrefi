"use client";

import { useState, useEffect, useMemo } from "react";
import { useTranslations } from "next-intl";
import {
  useAccount,
  useReadContract,
  useReadContracts,
  useWriteContract,
  useWaitForTransactionReceipt,
  useChainId,
} from "wagmi";
import { parseUnits, formatUnits, type Address } from "viem";
import { abis, getAddresses } from "@/contracts";
import { erc20Abi } from "@/contracts/erc20";

type AcceptedTokenInfo = {
  address: Address;
  symbol: string;
  pricingMode: number;        // 0 = Fixed, 1 = Oracle
  fixedRate: bigint;
  decimals: number;
};

interface Props {
  campaignAddress: Address;
  pricePerToken: bigint;       // 18 decimals — USD price
  currentState: number;         // 0 = Funding, 1 = Active, 2 = Buyback, 3 = Ended
}

type TxStatus =
  | { kind: "idle" }
  | { kind: "approving" }
  | { kind: "buying" }
  | { kind: "success"; hash: `0x${string}` }
  | { kind: "error"; message: string };

const campaignAbi = abis.Campaign as never;

export function BuyPanel({ campaignAddress, pricePerToken, currentState }: Props) {
  const t = useTranslations("detail.buy");
  const chainId = useChainId();
  const { address: user, isConnected } = useAccount();

  // 1) Read accepted tokens list from the campaign
  const { data: acceptedTokenAddresses } = useReadContract({
    address: campaignAddress,
    abi: campaignAbi,
    functionName: "getAcceptedTokens",
  }) as { data: Address[] | undefined };

  // 2) For each accepted token, read tokenConfig + ERC20 symbol/decimals
  const tokenConfigContracts = useMemo(() => {
    if (!acceptedTokenAddresses) return [];
    return acceptedTokenAddresses.flatMap((addr) => [
      {
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "tokenConfigs",
        args: [addr],
      },
      { address: addr, abi: erc20Abi, functionName: "symbol" },
      { address: addr, abi: erc20Abi, functionName: "decimals" },
    ]);
  }, [acceptedTokenAddresses, campaignAddress]);

  const { data: tokenConfigs } = useReadContracts({
    contracts: tokenConfigContracts as never,
    query: { enabled: tokenConfigContracts.length > 0 },
  });

  // Assemble token info array
  const tokens: AcceptedTokenInfo[] = useMemo(() => {
    if (!acceptedTokenAddresses || !tokenConfigs) return [];
    return acceptedTokenAddresses.map((addr, i) => {
      const cfgResult = tokenConfigs[i * 3];
      const symResult = tokenConfigs[i * 3 + 1];
      const decResult = tokenConfigs[i * 3 + 2];

      // tokenConfigs returns (PricingMode, uint256 fixedRate, address oracleFeed, bool active)
      const cfg = cfgResult?.result as
        | [number, bigint, Address, boolean]
        | undefined;

      return {
        address: addr,
        symbol: (symResult?.result as string) ?? "???",
        pricingMode: cfg?.[0] ?? 0,
        fixedRate: cfg?.[1] ?? 0n,
        decimals: (decResult?.result as number) ?? 18,
      };
    });
  }, [acceptedTokenAddresses, tokenConfigs]);

  // Selected token (default: first)
  const [selectedIdx, setSelectedIdx] = useState(0);
  const selected = tokens[selectedIdx];

  const [payAmount, setPayAmount] = useState("1000");

  // 3) Compute quote via view function `getPrice`
  const parsedAmount = useMemo(() => {
    if (!selected || !payAmount || Number(payAmount) <= 0) return 0n;
    try {
      return parseUnits(payAmount, selected.decimals);
    } catch {
      return 0n;
    }
  }, [payAmount, selected]);

  // For fixed-rate tokens we can compute tokensOut locally:
  // tokensOut = paymentAmount * 1e18 / fixedRate
  const tokensOutEstimate = useMemo(() => {
    if (!selected || parsedAmount === 0n) return 0n;
    if (selected.pricingMode === 0 && selected.fixedRate > 0n) {
      return (parsedAmount * 10n ** 18n) / selected.fixedRate;
    }
    // For oracle we'd call getPrice view — skipping for MVP, fallback to estimation
    if (pricePerToken > 0n) {
      return (parsedAmount * 10n ** 18n) / pricePerToken;
    }
    return 0n;
  }, [selected, parsedAmount, pricePerToken]);

  // 4) Read user balance + allowance
  const { data: balanceAllowance, refetch: refetchBalanceAllowance } =
    useReadContracts({
      contracts: selected && user
        ? [
            {
              address: selected.address,
              abi: erc20Abi,
              functionName: "balanceOf",
              args: [user],
            },
            {
              address: selected.address,
              abi: erc20Abi,
              functionName: "allowance",
              args: [user, campaignAddress],
            },
          ]
        : [],
      query: { enabled: !!selected && !!user },
    });

  const balance = (balanceAllowance?.[0]?.result as bigint) ?? 0n;
  const allowance = (balanceAllowance?.[1]?.result as bigint) ?? 0n;
  const needsApproval = parsedAmount > 0n && allowance < parsedAmount;

  // 5) Tx state
  const [status, setStatus] = useState<TxStatus>({ kind: "idle" });
  const { writeContractAsync } = useWriteContract();
  const [pendingHash, setPendingHash] = useState<`0x${string}` | undefined>();
  const receipt = useWaitForTransactionReceipt({ hash: pendingHash });

  // When an approval tx confirms, refetch and reset state to idle so user can click Buy
  useEffect(() => {
    if (receipt.isSuccess && status.kind === "approving") {
      void refetchBalanceAllowance();
      setStatus({ kind: "idle" });
    }
    if (receipt.isSuccess && status.kind === "buying" && pendingHash) {
      setStatus({ kind: "success", hash: pendingHash });
    }
  }, [receipt.isSuccess, status.kind, pendingHash, refetchBalanceAllowance]);

  const canInteract =
    isConnected &&
    selected &&
    parsedAmount > 0n &&
    (currentState === 0 || currentState === 1) &&
    status.kind === "idle";

  const hasEnoughBalance = balance >= parsedAmount;

  const handleApprove = async () => {
    if (!selected) return;
    try {
      setStatus({ kind: "approving" });
      const hash = await writeContractAsync({
        address: selected.address,
        abi: erc20Abi,
        functionName: "approve",
        args: [campaignAddress, parsedAmount],
      });
      setPendingHash(hash);
    } catch (err) {
      setStatus({
        kind: "error",
        message: err instanceof Error ? err.message : String(err),
      });
    }
  };

  const handleBuy = async () => {
    if (!selected) return;
    try {
      setStatus({ kind: "buying" });
      const hash = await writeContractAsync({
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "buy",
        args: [selected.address, parsedAmount],
      });
      setPendingHash(hash);
    } catch (err) {
      setStatus({
        kind: "error",
        message: err instanceof Error ? err.message : String(err),
      });
    }
  };

  const ctaLabel = !isConnected
    ? t("connectFirst")
    : !selected
      ? t("noToken")
      : currentState !== 0 && currentState !== 1
        ? t("notBuyable")
        : !hasEnoughBalance
          ? t("insufficientBalance")
          : status.kind === "approving"
            ? t("approving")
            : status.kind === "buying"
              ? t("buying")
              : needsApproval
                ? t("approve", { token: selected.symbol })
                : t("cta");

  const onClick = needsApproval ? handleApprove : handleBuy;

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <h2 className="text-2xl font-bold tracking-tight text-on-surface mb-2">
        {t("title")}
      </h2>
      <p className="text-sm text-on-surface-variant mb-6">{t("subtitle")}</p>

      {tokens.length === 0 ? (
        <div className="text-sm text-on-surface-variant py-8 text-center">
          {t("noTokensConfigured")}
        </div>
      ) : (
        <>
          <div className="flex gap-3 mb-6">
            {tokens.map((tok, i) => (
              <button
                key={tok.address}
                onClick={() => setSelectedIdx(i)}
                className={`flex-1 py-4 px-4 rounded-xl flex flex-col items-center justify-center gap-1 border-2 transition-all ${
                  selectedIdx === i
                    ? "bg-primary-fixed/30 border-primary"
                    : "bg-surface-container-low border-outline-variant/15 hover:border-outline-variant/40"
                }`}
              >
                <span className="font-semibold text-on-surface">
                  {tok.symbol}
                </span>
                <span className="text-xs text-on-surface-variant">
                  {tok.pricingMode === 0 ? t("fixed") : t("oracle")}
                </span>
              </button>
            ))}
          </div>

          <div className="flex flex-col gap-2 relative">
            <div className="bg-surface-container-low rounded-xl p-4 border border-outline-variant/15">
              <div className="flex justify-between items-center mb-2">
                <label className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
                  {t("youPay")}
                </label>
                <button
                  onClick={() =>
                    selected &&
                    setPayAmount(formatUnits(balance, selected.decimals))
                  }
                  className="text-xs text-on-surface-variant hover:text-primary transition-colors"
                >
                  {t("balance", {
                    amount: selected
                      ? Number(formatUnits(balance, selected.decimals)).toFixed(
                          2,
                        )
                      : "0",
                    token: selected?.symbol ?? "",
                  })}
                </button>
              </div>
              <div className="flex justify-between items-center">
                <input
                  type="number"
                  value={payAmount}
                  onChange={(e) => setPayAmount(e.target.value)}
                  className="bg-transparent border-none outline-none text-3xl font-bold text-on-surface w-full p-0 focus:ring-0"
                  placeholder="0.00"
                />
                <div className="bg-surface-container-highest rounded-full px-3 py-1 ml-2">
                  <span className="text-sm font-semibold text-on-surface">
                    {selected?.symbol}
                  </span>
                </div>
              </div>
            </div>

            <div className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 w-10 h-10 bg-surface rounded-full flex items-center justify-center border border-outline-variant/15 z-10 shadow-sm">
              <svg
                width="20"
                height="20"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                className="text-on-surface-variant"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  d="M19.5 13.5L12 21m0 0l-7.5-7.5M12 21V3"
                />
              </svg>
            </div>

            <div className="bg-surface-container-low rounded-xl p-4 border border-outline-variant/15">
              <label className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant block mb-2">
                {t("youReceive")}
              </label>
              <div className="flex justify-between items-center">
                <span className="text-3xl font-bold text-on-surface">
                  {Number(formatUnits(tokensOutEstimate, 18)).toLocaleString(
                    undefined,
                    { maximumFractionDigits: 2 },
                  )}
                </span>
                <div className="bg-primary-fixed rounded-full px-3 py-1 ml-2 flex items-center gap-1.5">
                  <span className="w-2 h-2 bg-primary rounded-full" />
                  <span className="text-sm font-semibold text-on-primary-fixed-variant">
                    $CAMP
                  </span>
                </div>
              </div>
              <div className="text-right mt-1">
                <span className="text-sm text-on-surface-variant">
                  {t("priceInfo", {
                    price: Number(formatUnits(pricePerToken, 18)).toFixed(3),
                  })}
                </span>
              </div>
            </div>
          </div>

          <button
            onClick={onClick}
            disabled={!canInteract || !hasEnoughBalance}
            className="w-full mt-6 regen-gradient text-white rounded-xl h-14 font-bold text-base hover:shadow-xl hover:shadow-primary/20 transition-all disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {ctaLabel}
          </button>

          {status.kind === "error" && (
            <div className="mt-4 bg-red-50 text-error border border-red-200 rounded-xl p-3 text-xs break-words">
              {status.message}
            </div>
          )}
          {status.kind === "success" && (
            <div className="mt-4 bg-primary-fixed/30 text-primary border border-primary/30 rounded-xl p-3 text-sm font-medium">
              {t("purchaseConfirmed")}{" "}
              <a
                href={`https://sepolia.arbiscan.io/tx/${status.hash}`}
                target="_blank"
                rel="noreferrer"
                className="underline"
              >
                {t("viewTx")}
              </a>
            </div>
          )}

          <div className="mt-4 flex items-start gap-2 text-xs text-on-surface-variant">
            <svg
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              className="shrink-0 mt-0.5"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M9 12.75L11.25 15 15 9.75"
              />
            </svg>
            <span>{t("escrow")}</span>
          </div>
        </>
      )}
    </div>
  );
}
