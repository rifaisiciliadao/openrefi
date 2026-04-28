"use client";

import { useState, useMemo } from "react";
import { useTranslations } from "next-intl";
import {
  useAccount,
  useReadContract,
  useReadContracts,
  useWriteContract,
} from "wagmi";
import { parseUnits, formatUnits, type Address } from "viem";
import { abis, getAddresses } from "@/contracts";
import { erc20Abi } from "@/contracts/erc20";
import { Spinner } from "./Spinner";
import { useTxNotify } from "@/lib/useTxNotify";
import { waitForTx } from "@/lib/waitForTx";

type AcceptedTokenInfo = {
  address: Address;
  symbol: string;
  pricingMode: number;        // 0 = Fixed, 1 = Oracle
  fixedRate: bigint;
  decimals: number;
};

interface Props {
  campaignAddress: Address;
  campaignToken: Address;       // ERC20 address — read symbol from here
  pricePerToken: bigint;        // 18 decimals — USD price
  currentSupply: bigint;        // 18 decimals — tokens already sold
  maxCap: bigint;               // 18 decimals — hard cap
  currentState: number;         // 0 = Funding, 1 = Active, 2 = Buyback, 3 = Ended
  /** Expected annual harvest USD (18-dec). */
  annualHarvestUsd18: bigint;
  /** Calendar year of the first reportable harvest (e.g. 2027). */
  firstHarvestYear: bigint;
}

/**
 * Tx lifecycle — every write follows: sig → chain → done.
 *   *-sig: waiting for the wallet popup / user signature.
 *   *-chain: tx submitted, waiting for block confirmation.
 * Spinner stays visible during both phases; success fires only when the
 * on-chain receipt lands and matches the SPECIFIC tx that just ran.
 */
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

/**
 * MockUSDC exposes a permissionless `mint(address to, uint256 amount)` so
 * testers can grab 1,000 mUSDC directly from the buy panel without needing
 * the CLI. This is testnet-only — will render nothing in prod.
 */
const mockUsdcMintAbi = [
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

const campaignAbi = abis.Campaign as never;

const MOCK_USDC_DECIMALS = 6;
const MOCK_USDC_MINT_AMOUNT = 10_000n * 10n ** BigInt(MOCK_USDC_DECIMALS); // 10,000 mUSDC

export function BuyPanel({
  campaignAddress,
  campaignToken,
  pricePerToken,
  currentSupply,
  maxCap,
  currentState,
  annualHarvestUsd18,
  firstHarvestYear,
}: Props) {
  const t = useTranslations("detail.buy");
  const { address: user, isConnected } = useAccount();
  const { usdc: mockUsdcAddress } = getAddresses();

  // Real campaign token symbol (no more hardcoded "$CAMP" / "$CAMPAIGN")
  const { data: campaignSymbolRaw } = useReadContract({
    address: campaignToken,
    abi: erc20Abi,
    functionName: "symbol",
  });
  const campSymbol = (campaignSymbolRaw as string | undefined) ?? "CAMP";

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
    type MaybeResult = { result?: unknown };
    const results = tokenConfigs as readonly MaybeResult[];
    return acceptedTokenAddresses.map((addr, i) => {
      const cfgResult = results[i * 3];
      const symResult = results[i * 3 + 1];
      const decResult = results[i * 3 + 2];

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
  // Then clamp to remainingCap — the contract will auto-crop and refund any
  // payment overshoot (Campaign.buy() line 309), so we mirror that here.
  const remainingCap = maxCap > currentSupply ? maxCap - currentSupply : 0n;

  const rawTokensOut = useMemo(() => {
    if (!selected || parsedAmount === 0n) return 0n;
    if (selected.pricingMode === 0 && selected.fixedRate > 0n) {
      return (parsedAmount * 10n ** 18n) / selected.fixedRate;
    }
    if (pricePerToken > 0n) {
      return (parsedAmount * 10n ** 18n) / pricePerToken;
    }
    return 0n;
  }, [selected, parsedAmount, pricePerToken]);

  const tokensOutEstimate =
    remainingCap > 0n && rawTokensOut > remainingCap
      ? remainingCap
      : rawTokensOut;

  // If we had to clamp, compute the effective payment (what the contract
  // will actually pull from the user after auto-refunding the overshoot).
  const effectivePayment = useMemo(() => {
    if (!selected || tokensOutEstimate === 0n) return 0n;
    if (selected.pricingMode === 0 && selected.fixedRate > 0n) {
      return (tokensOutEstimate * selected.fixedRate) / 10n ** 18n;
    }
    if (pricePerToken > 0n) {
      return (tokensOutEstimate * pricePerToken) / 10n ** 18n;
    }
    return parsedAmount;
  }, [selected, tokensOutEstimate, pricePerToken, parsedAmount]);
  const isClamped = tokensOutEstimate < rawTokensOut && rawTokensOut > 0n;

  // Funding fee preview — mirrors the contract's integer-division math
  // (FUNDING_FEE_BPS = 300). Shown as a subtle breakdown under the "You Receive"
  // card so the buyer knows exactly how much hits the campaign vs. the protocol.
  const grossPayment = isClamped ? effectivePayment : parsedAmount;
  const fundingFee = (grossPayment * 300n) / 10_000n;
  const netToCampaign = grossPayment - fundingFee;

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
  const requiredPayment = isClamped ? effectivePayment : parsedAmount;
  const needsApproval = requiredPayment > 0n && allowance < requiredPayment;

  // Tx state — imperative flow in each handler, no receipt useEffect races.
  const [status, setStatus] = useState<TxStatus>({ kind: "idle" });
  const { writeContractAsync } = useWriteContract();
  const notify = useTxNotify();
  const tx = useTranslations("tx");

  // Boundary checks from the contract: contract.buy() reverts if
  //   currentSupply >= maxCap (MaxCapReached). Pre-check it so users see
  //   a clear banner instead of a mysterious "execution reverted".
  const maxCapReached = maxCap > 0n && currentSupply >= maxCap;

  const canInteract =
    isConnected &&
    selected &&
    parsedAmount > 0n &&
    (currentState === 0 || currentState === 1) &&
    !maxCapReached &&
    status.kind === "idle";

  const hasEnoughBalance = balance >= requiredPayment;

  const handleError = (err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    if (/user (rejected|denied)/i.test(msg)) {
      setStatus({ kind: "idle" });
    } else {
      setStatus({ kind: "error", message: msg });
    }
  };

  const handleApprove = async () => {
    if (!selected) return;
    try {
      setStatus({ kind: "approving-sig" });
      const approvalAmount = isClamped ? effectivePayment : parsedAmount;
      const hash = await writeContractAsync({
        address: selected.address,
        abi: erc20Abi,
        functionName: "approve",
        args: [campaignAddress, approvalAmount],
      });
      setStatus({ kind: "approving-chain" });
      const r = await waitForTx(hash);
      if (r.status !== "success") throw new Error("Approval reverted");
      await refetchBalanceAllowance();
      notify.success(tx("approvalConfirmed"), hash);
      setStatus({ kind: "idle" });
    } catch (err) {
      handleError(err);
      notify.error(tx("approvalFailed"), err);
    }
  };

  const handleMintMockUsdc = async () => {
    if (!user) return;
    try {
      setStatus({ kind: "minting-sig" });
      const hash = await writeContractAsync({
        address: mockUsdcAddress,
        abi: mockUsdcMintAbi,
        functionName: "mint",
        args: [user, MOCK_USDC_MINT_AMOUNT],
      });
      setStatus({ kind: "minting-chain" });
      const r = await waitForTx(hash);
      if (r.status !== "success") throw new Error("Mint reverted");
      await refetchBalanceAllowance();
      notify.success(tx("mintConfirmed"), hash);
      setStatus({ kind: "idle" });
    } catch (err) {
      handleError(err);
      notify.error(tx("mintFailed"), err);
    }
  };

  const handleBuy = async () => {
    if (!selected) return;
    try {
      setStatus({ kind: "buying-sig" });
      const hash = await writeContractAsync({
        address: campaignAddress,
        abi: campaignAbi,
        functionName: "buy",
        args: [selected.address, requiredPayment],
      });
      setStatus({ kind: "buying-chain" });
      const r = await waitForTx(hash);
      if (r.status !== "success") {
        throw new Error("Purchase reverted on-chain");
      }
      notify.success(tx("buyConfirmed"), hash);
      setStatus({ kind: "success", hash });
    } catch (err) {
      handleError(err);
      notify.error(tx("buyFailed"), err);
    }
  };

  const inFlight =
    status.kind === "approving-sig" ||
    status.kind === "approving-chain" ||
    status.kind === "buying-sig" ||
    status.kind === "buying-chain" ||
    status.kind === "minting-sig" ||
    status.kind === "minting-chain";

  const inFlightLabel =
    status.kind === "approving-sig"
      ? t("approvingSig")
      : status.kind === "approving-chain"
        ? t("approvingChain")
        : status.kind === "buying-sig"
          ? t("buyingSig")
          : status.kind === "buying-chain"
            ? t("buyingChain")
            : status.kind === "minting-sig"
              ? t("mintingSig")
              : t("mintingChain");

  const ctaLabel = !isConnected
    ? t("connectFirst")
    : !selected
      ? t("noToken")
      : currentState !== 0 && currentState !== 1
        ? t("notBuyable")
        : maxCapReached
          ? t("maxCapReached")
          : !hasEnoughBalance
            ? t("insufficientBalance")
            : inFlight
              ? inFlightLabel
              : needsApproval
                ? t("approve", { token: selected.symbol })
                : t("cta", { symbol: campSymbol });

  const onClick = needsApproval ? handleApprove : handleBuy;

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-8 border border-outline-variant/15">
      <h2 className="text-2xl font-bold tracking-tight text-on-surface mb-2">
        {t("title")}
      </h2>
      <p className="text-sm text-on-surface-variant mb-6">{t("subtitle")}</p>

      {maxCapReached && (
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
              {t("maxCapReachedTitle")}
            </div>
            <p className="text-xs text-amber-800 mt-0.5">
              {t("maxCapReachedHint")}
            </p>
          </div>
        </div>
      )}

      {!maxCapReached &&
        maxCap > 0n &&
        remainingCap > 0n &&
        remainingCap < maxCap / 10n && (
          <div className="bg-primary-fixed/20 border border-primary/20 rounded-xl p-3 mb-6 text-xs text-primary">
            {t("remainingCap", {
              amount: Number(formatUnits(remainingCap, 18)).toLocaleString(
                undefined,
                { maximumFractionDigits: 0 },
              ),
              symbol: campSymbol,
            })}
          </div>
        )}

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
              <div className="flex justify-between items-center mb-2 gap-2">
                <label className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
                  {t("youPay")}
                </label>
                <div className="flex items-center gap-2">
                  {selected &&
                    user &&
                    selected.address.toLowerCase() ===
                      mockUsdcAddress.toLowerCase() && (
                      <button
                        onClick={handleMintMockUsdc}
                        disabled={status.kind !== "idle"}
                        className="text-xs font-semibold text-primary hover:bg-primary-fixed/30 px-2 py-1 rounded-full transition-colors disabled:opacity-50 flex items-center gap-1"
                        title={t("mintHint")}
                      >
                        {status.kind === "minting-sig" ||
                        status.kind === "minting-chain" ? (
                          <Spinner size={12} />
                        ) : (
                          <span>+</span>
                        )}
                        {t("mint", { amount: "10,000" })}
                      </button>
                    )}
                  <button
                    onClick={() =>
                      selected &&
                      setPayAmount(formatUnits(balance, selected.decimals))
                    }
                    className="inline-flex items-center min-h-[32px] px-2 -mx-2 text-xs text-on-surface-variant hover:text-primary transition-colors"
                  >
                    {t("balance", {
                      amount: selected
                        ? Number(
                            formatUnits(balance, selected.decimals),
                          ).toFixed(2)
                        : "0",
                      token: selected?.symbol ?? "",
                    })}
                  </button>
                </div>
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
                    ${campSymbol}
                  </span>
                </div>
              </div>
              <div className="text-right mt-1">
                <span className="text-sm text-on-surface-variant">
                  {t("priceInfo", {
                    symbol: campSymbol,
                    price: Number(formatUnits(pricePerToken, 18)).toFixed(3),
                  })}
                </span>
              </div>
              {isClamped && selected && (
                <div className="mt-3 pt-3 border-t border-outline-variant/15 text-xs text-on-surface-variant">
                  {t("clampedToCap", {
                    tokens: Number(
                      formatUnits(tokensOutEstimate, 18),
                    ).toLocaleString(undefined, { maximumFractionDigits: 2 }),
                    tokenSymbol: campSymbol,
                    payment: Number(
                      formatUnits(effectivePayment, selected.decimals),
                    ).toLocaleString(undefined, { maximumFractionDigits: 2 }),
                    paymentSymbol: selected.symbol,
                  })}
                </div>
              )}
              {selected && fundingFee > 0n && (
                <div className="mt-3 pt-3 border-t border-outline-variant/15 text-xs text-on-surface-variant space-y-1">
                  <div>
                    {t("feeBreakdown", {
                      fee: Number(
                        formatUnits(fundingFee, selected.decimals),
                      ).toLocaleString(undefined, { maximumFractionDigits: 4 }),
                      net: Number(
                        formatUnits(netToCampaign, selected.decimals),
                      ).toLocaleString(undefined, { maximumFractionDigits: 2 }),
                      symbol: selected.symbol,
                    })}
                  </div>
                  <div className="text-[10px] opacity-70">
                    {t("feeBreakdownHint")}
                  </div>
                </div>
              )}
            </div>
          </div>

          {/* v3 — Expected return panel. Driven by the buyer's actual gross
              payment (NOT a separate input), so the numbers update as the
              user types in the YOU PAY field above. Hidden when the campaign
              has no yearly-return commitment (pre-v3) or no input yet. */}
          {annualHarvestUsd18 > 0n && grossPayment > 0n && selected && (
            <BuyExpectedReturn
              netToCampaign={netToCampaign}
              annualHarvestUsd18={annualHarvestUsd18}
              firstHarvestYear={firstHarvestYear}
              maxCap={maxCap}
              pricePerToken={pricePerToken}
              decimals={selected.decimals}
              symbol={selected.symbol}
            />
          )}

          <button
            onClick={onClick}
            disabled={!canInteract || !hasEnoughBalance}
            className="w-full mt-6 regen-gradient text-white rounded-xl h-14 font-bold text-base hover:shadow-xl hover:shadow-primary/20 transition-all disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
          >
            {inFlight && <Spinner size={18} />}
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
                href={`https://sepolia.basescan.org/tx/${status.hash}`}
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
            <span>
              {currentState === 0 ? t("escrowFunding") : t("escrowActive")}
            </span>
          </div>
        </>
      )}
    </div>
  );
}

/**
 * BuyExpectedReturn — inline projection of the buyer's expected per-harvest
 * USDC yield based on their share of the maxRaise. Math:
 *
 *   buyerShare        = netToCampaign / maxRaise            (ratio in [0,1])
 *   yieldPerHarvest   = buyerShare × annualHarvestUsd       (USDC/yr at full)
 *   harvestsToRepay   = ⌈maxRaise / annualHarvestUsd⌉
 *   paybackEnd        = firstHarvestYear + harvestsToRepay - 1
 *
 * The producer commits an absolute USD figure (different products = different
 * unit prices), so the math is "your fraction of the campaign × producer's
 * total commitment per year". The 3% funding fee is excluded from the
 * principal — only the NET goes to the campaign and earns yield.
 *
 * Returns are framed as a perpetual income stream: payback at year N, every
 * harvest after that is pure profit. We label "payback" rather than "total
 * return after N years" to avoid the wrong impression of a fixed horizon.
 */
function BuyExpectedReturn({
  netToCampaign,
  annualHarvestUsd18,
  firstHarvestYear,
  maxCap,
  pricePerToken,
  decimals,
  symbol,
}: {
  netToCampaign: bigint;
  annualHarvestUsd18: bigint;
  firstHarvestYear: bigint;
  maxCap: bigint;
  pricePerToken: bigint;
  decimals: number;
  symbol: string;
}) {
  const principalNet = Number(formatUnits(netToCampaign, decimals));
  const annual = Number(annualHarvestUsd18) / 1e18;
  const maxRaise = (Number(maxCap) / 1e18) * (Number(pricePerToken) / 1e18);
  const firstYear = Number(firstHarvestYear);

  if (annual <= 0 || maxRaise <= 0) return null;

  const buyerShare = Math.min(1, principalNet / maxRaise);
  const yieldPerHarvest = buyerShare * annual;
  const harvestsToRepay = Math.ceil(maxRaise / annual);
  const paybackEnd = firstYear + harvestsToRepay - 1;
  const impliedPct = (annual / maxRaise) * 100;

  const fmt = (n: number) =>
    n >= 100
      ? n.toLocaleString(undefined, { maximumFractionDigits: 0 })
      : n.toLocaleString(undefined, { maximumFractionDigits: 2 });

  return (
    <div className="bg-surface-container-low rounded-xl p-4 border border-outline-variant/15 mt-4 space-y-3">
      <div className="flex items-baseline justify-between">
        <span className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
          Expected return
        </span>
        <span className="text-[11px] text-on-surface-variant">
          @ {impliedPct.toFixed(impliedPct < 1 ? 2 : 1)}%/yr
        </span>
      </div>
      <div className="grid grid-cols-2 gap-4">
        <div>
          <div className="text-[10px] font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            Per harvest
          </div>
          <div className="text-2xl font-bold text-on-surface">
            {fmt(yieldPerHarvest)} {symbol}
          </div>
          {firstYear > 0 && (
            <div className="text-[10px] text-on-surface-variant mt-0.5">
              first in {firstYear}
            </div>
          )}
        </div>
        <div>
          <div className="text-[10px] font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
            Payback
          </div>
          <div className="text-2xl font-bold text-primary">
            {harvestsToRepay} yrs
          </div>
          {firstYear > 0 && (
            <div className="text-[10px] text-on-surface-variant mt-0.5">
              by {paybackEnd}
            </div>
          )}
        </div>
      </div>
      <p className="text-[10px] text-on-surface-variant">
        Every harvest after payback is pure profit — the campaign is a
        perpetual income stream, not a fixed-term bond.
      </p>
    </div>
  );
}
