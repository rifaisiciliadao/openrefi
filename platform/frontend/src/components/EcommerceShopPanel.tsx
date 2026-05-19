"use client";

import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";
import {
  useAccount,
  useReadContract,
  useReadContracts,
  useWriteContract,
} from "wagmi";
import { formatUnits, keccak256, parseUnits, toBytes, zeroAddress, type Address } from "viem";
import { getAddresses } from "@/contracts";
import { erc20Abi } from "@/contracts/erc20";
import {
  ECOMMERCE_MODULE_KIND,
  ECOMMERCE_MODULE_TYPE,
  ecommerceModuleAbi,
} from "@/contracts/ecommerce";
import { campaignModuleHostAbi } from "@/contracts/repayment";
import {
  createEcommerceOrderDraft,
  sendEcommercePurchaseReceipt,
  uploadEcommerceCatalog,
  type EcommerceCatalog,
  type EcommerceCatalogItem,
} from "@/lib/api";
import { txUrl } from "@/lib/explorer";
import { waitForTx } from "@/lib/waitForTx";
import { useTxNotify } from "@/lib/useTxNotify";
import { Spinner } from "./Spinner";

const USDC_DECIMALS = 6;
const DEMO_CATALOG_TITLE = "Campaign shop";
const DEMO_CATALOG_DESCRIPTION = "On-chain checkout for products reserved from this campaign.";
const DEMO_PRODUCT_NAME = "Extra virgin olive oil 500ml";
const DEMO_PRODUCT_DESCRIPTION = "Cold-pressed Sicilian olive oil reserved from the campaign shop.";
const DEMO_PRODUCT_DESCRIPTION_ALT = "Cold-pressed Sicilian olive oil, reserved from the campaign shop.";
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

type SkuView = {
  priceUsdc: bigint;
  inventory: bigint;
  sold: bigint;
  active: boolean;
  exists: boolean;
};

type QuoteView = {
  gross: bigint;
  protocolFee: bigint;
  repayment: bigint;
  producerNet: bigint;
};

type TxStatus =
  | { kind: "idle" }
  | { kind: "mint-sig" | "mint-chain"; current?: number; total?: number }
  | { kind: "approve-sig" | "approve-chain"; current?: number; total?: number }
  | { kind: "draft"; current?: number; total?: number }
  | { kind: "buy-sig" | "buy-chain"; current?: number; total?: number }
  | { kind: "receipt" }
  | { kind: "success"; hash: `0x${string}`; emailDelivered: boolean }
  | { kind: "error"; message: string };

const ZERO_QUOTE: QuoteView = {
  gross: 0n,
  protocolFee: 0n,
  repayment: 0n,
  producerNet: 0n,
};

function readSku(raw: unknown): SkuView | null {
  if (!raw) return null;
  if (Array.isArray(raw)) {
    return {
      priceUsdc: (raw[0] as bigint | undefined) ?? 0n,
      inventory: (raw[1] as bigint | undefined) ?? 0n,
      sold: (raw[2] as bigint | undefined) ?? 0n,
      active: Boolean(raw[3]),
      exists: Boolean(raw[4]),
    };
  }
  const r = raw as Partial<SkuView>;
  return {
    priceUsdc: r.priceUsdc ?? 0n,
    inventory: r.inventory ?? 0n,
    sold: r.sold ?? 0n,
    active: Boolean(r.active),
    exists: Boolean(r.exists),
  };
}

function readQuote(raw: unknown): QuoteView {
  if (!Array.isArray(raw)) return ZERO_QUOTE;
  return {
    gross: (raw[0] as bigint | undefined) ?? 0n,
    protocolFee: (raw[1] as bigint | undefined) ?? 0n,
    repayment: (raw[2] as bigint | undefined) ?? 0n,
    producerNet: (raw[3] as bigint | undefined) ?? 0n,
  };
}

function addQuotes(a: QuoteView, b: QuoteView): QuoteView {
  return {
    gross: a.gross + b.gross,
    protocolFee: a.protocolFee + b.protocolFee,
    repayment: a.repayment + b.repayment,
    producerNet: a.producerNet + b.producerNet,
  };
}

function cartKey(skuId: string): string {
  return skuId.toLowerCase();
}

function inventoryLimit(sku: SkuView | null): number {
  if (!sku?.exists || !sku.active) return 0;
  if (sku.inventory > BigInt(Number.MAX_SAFE_INTEGER)) return Number.MAX_SAFE_INTEGER;
  return Number(sku.inventory);
}

function formatUsdc(value: bigint): string {
  return Number(formatUnits(value, USDC_DECIMALS)).toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

function shortHash(value: string): string {
  return `${value.slice(0, 8)}…${value.slice(-6)}`;
}

function localizedText(
  value: string | null | undefined,
  translations: unknown,
  locale: string,
  fallback: string,
  legacy: Record<string, string> = {},
): string {
  if (translations && typeof translations === "object" && !Array.isArray(translations)) {
    const localized = (translations as Record<string, unknown>)[locale];
    if (typeof localized === "string" && localized.trim()) return localized.trim();
  }

  const raw = typeof value === "string" ? value.trim() : "";
  return legacy[raw] ?? (raw || fallback);
}

export function EcommerceShopPanel({
  campaignAddress,
  currentState,
  campaignName,
}: {
  campaignAddress: Address;
  currentState: number;
  campaignName: string;
}) {
  const t = useTranslations("detail.ecommerce");
  const tx = useTranslations("tx");
  const locale = useLocale();
  const notify = useTxNotify();
  const { address: user, isConnected } = useAccount();
  const { usdc } = getAddresses();
  const { writeContractAsync } = useWriteContract();

  const { data: catalogURI } = useReadContract({
    address: campaignAddress,
    abi: ecommerceModuleAbi,
    functionName: "catalogURI",
    query: { refetchInterval: 20_000 },
  }) as { data?: string };

  const { data: catalog, isLoading: catalogLoading } = useQuery({
    queryKey: ["ecommerce-catalog", catalogURI],
    enabled: Boolean(catalogURI),
    queryFn: async (): Promise<EcommerceCatalog> => {
      const res = await fetch(catalogURI!, { cache: "no-store" });
      if (!res.ok) throw new Error(`Catalog fetch failed: ${res.status}`);
      return res.json();
    },
  });

  const items = useMemo(() => catalog?.items ?? [], [catalog?.items]);
  const [cart, setCart] = useState<Record<string, number>>({});
  const [cartOpen, setCartOpen] = useState(false);
  const [checkoutOpen, setCheckoutOpen] = useState(false);

  const { data: skuReads, refetch: refetchSkus } = useReadContracts({
    contracts: items.map((item) => ({
      address: campaignAddress,
      abi: ecommerceModuleAbi,
      functionName: "sku",
      args: [item.skuId] as const,
    })),
    query: {
      enabled: items.length > 0,
      refetchInterval: 15_000,
    },
  });

  const skuById = useMemo(() => {
    const map = new Map<string, SkuView | null>();
    items.forEach((item, index) => {
      map.set(cartKey(item.skuId), readSku(skuReads?.[index]?.result));
    });
    return map;
  }, [items, skuReads]);

  const cartLines = useMemo(
    () =>
      items
        .map((item) => {
          const quantity = cart[cartKey(item.skuId)] ?? 0;
          const sku = skuById.get(cartKey(item.skuId)) ?? null;
          return { item, sku, quantity, quantityBig: BigInt(quantity) };
        })
        .filter((line) => line.quantity > 0),
    [items, cart, skuById],
  );

  const pricedCartLines = useMemo(
    () =>
      cartLines.filter(
        (line) =>
          line.sku?.exists &&
          line.sku.active &&
          line.quantityBig > 0n &&
          line.quantityBig <= line.sku.inventory,
      ),
    [cartLines],
  );

  const { data: quoteReads, refetch: refetchQuotes } = useReadContracts({
    contracts: pricedCartLines.map((line) => ({
      address: campaignAddress,
      abi: ecommerceModuleAbi,
      functionName: "quoteSku",
      args: [line.item.skuId, line.quantityBig] as const,
    })),
    query: {
      enabled: pricedCartLines.length > 0,
      refetchInterval: 15_000,
    },
  });

  const quoteById = useMemo(() => {
    const map = new Map<string, QuoteView>();
    pricedCartLines.forEach((line, index) => {
      map.set(cartKey(line.item.skuId), readQuote(quoteReads?.[index]?.result));
    });
    return map;
  }, [pricedCartLines, quoteReads]);

  const { data: balanceAllowance, refetch: refetchBalance } = useReadContracts({
    contracts:
      user && usdc !== zeroAddress
        ? [
            { address: usdc, abi: erc20Abi, functionName: "balanceOf", args: [user] },
            {
              address: usdc,
              abi: erc20Abi,
              functionName: "allowance",
              args: [user, campaignAddress],
            },
          ]
        : [],
    query: { enabled: Boolean(user && usdc !== zeroAddress), refetchInterval: 15_000 },
  });
  const balance = (balanceAllowance?.[0]?.result as bigint | undefined) ?? 0n;
  const allowance = (balanceAllowance?.[1]?.result as bigint | undefined) ?? 0n;

  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [shipping, setShipping] = useState("");
  const [status, setStatus] = useState<TxStatus>({ kind: "idle" });

  const busy = status.kind !== "idle" && status.kind !== "success" && status.kind !== "error";
  const cartRows = useMemo(
    () =>
      cartLines.map((line) => {
        const name = localizedText(
          line.item.name,
          (line.item as Record<string, unknown>).nameI18n,
          locale,
          shortHash(line.item.skuId),
          { [DEMO_PRODUCT_NAME]: t("defaultProductName") },
        );
        const description = localizedText(
          line.item.description,
          (line.item as Record<string, unknown>).descriptionI18n,
          locale,
          line.item.skuId,
          {
            [DEMO_PRODUCT_DESCRIPTION]: t("defaultProductDescription"),
            [DEMO_PRODUCT_DESCRIPTION_ALT]: t("defaultProductDescription"),
          },
        );
        return {
          ...line,
          name,
          description,
          quote: quoteById.get(cartKey(line.item.skuId)) ?? ZERO_QUOTE,
        };
      }),
    [cartLines, locale, quoteById, t],
  );
  const totals = cartRows.reduce((acc, row) => addQuotes(acc, row.quote), ZERO_QUOTE);
  const cartQuantity = cartRows.reduce((acc, row) => acc + row.quantity, 0);
  const cartInvalid = cartRows.some(
    (row) => !row.sku?.exists || !row.sku.active || row.quantityBig > (row.sku?.inventory ?? 0n),
  );
  const quotesReady =
    pricedCartLines.length === 0 ||
    pricedCartLines.every((line) => quoteById.has(cartKey(line.item.skuId)));
  const needsApproval = totals.gross > 0n && allowance < totals.gross;
  const canOpenCheckout =
    currentState === 1 &&
    cartRows.length > 0 &&
    !cartInvalid &&
    quotesReady &&
    totals.gross > 0n &&
    !busy;
  const canBuy =
    isConnected &&
    currentState === 1 &&
    cartRows.length > 0 &&
    !cartInvalid &&
    quotesReady &&
    totals.gross > 0n &&
    balance >= totals.gross &&
    /\S+@\S+\.\S+/.test(email) &&
    fullName.trim().length > 1 &&
    shipping.trim().length > 4 &&
    !busy;

  const checkoutLabel = !isConnected
    ? t("connect")
    : currentState !== 1
      ? t("inactiveCampaign")
      : cartRows.length === 0
        ? t("cartEmpty")
        : cartInvalid
          ? t("cartLocked")
          : !quotesReady
            ? t("quotesLoading")
            : balance < totals.gross
              ? t("insufficientUsdc")
              : busy
                ? "current" in status && status.current && "total" in status && status.total && status.total > 1
                  ? t("processingStep", {
                      action: t(status.kind),
                      current: status.current,
                      total: status.total,
                    })
                  : t(status.kind)
                : needsApproval
                  ? t("approveAndPlaceOrder")
                  : t("placeOrder");

  const setCartQuantity = (skuId: string, nextQuantity: number, maxQuantity: number) => {
    setCart((current) => {
      const key = cartKey(skuId);
      const quantity = Math.max(0, Math.min(nextQuantity, maxQuantity));
      const next = { ...current };
      if (quantity === 0) {
        delete next[key];
      } else {
        next[key] = quantity;
      }
      return next;
    });
  };

  const handleMintUsdc = async () => {
    if (!user) return;
    try {
      setStatus({ kind: "mint-sig" });
      const hash = await writeContractAsync({
        address: usdc,
        abi: mockUsdcMintAbi,
        functionName: "mint",
        args: [user, 10_000n * 10n ** 6n],
      });
      setStatus({ kind: "mint-chain" });
      const receipt = await waitForTx(hash);
      if (receipt.status !== "success") throw new Error("mUSDC mint reverted");
      await refetchBalance();
      notify.success(tx("mintConfirmed"), hash);
      setStatus({ kind: "idle" });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setStatus(/user (rejected|denied)/i.test(message) ? { kind: "idle" } : { kind: "error", message });
      notify.error(tx("mintFailed"), err);
    }
  };

  const handleCheckout = async () => {
    if (!user || !canBuy) return;
    const rows = cartRows;
    const orderTotals = totals;
    try {
      if (needsApproval) {
        setStatus({ kind: "approve-sig" });
        const approveHash = await writeContractAsync({
          address: usdc,
          abi: erc20Abi,
          functionName: "approve",
          args: [campaignAddress, orderTotals.gross],
        });
        setStatus({ kind: "approve-chain" });
        const approveReceipt = await waitForTx(approveHash);
        if (approveReceipt.status !== "success") throw new Error("USDC approval reverted");
      }

      const purchases: Array<{
        row: (typeof rows)[number];
        draft: Awaited<ReturnType<typeof createEcommerceOrderDraft>>;
        hash: `0x${string}`;
      }> = [];

      for (const [index, row] of rows.entries()) {
        const step = index + 1;
        setStatus({ kind: "draft", current: step, total: rows.length });
        const draft = await createEcommerceOrderDraft({
          campaign: campaignAddress,
          buyer: user,
          skuId: row.item.skuId,
          quantity: row.quantityBig.toString(),
          customer: { email: email.trim().toLowerCase(), name: fullName.trim() },
          fulfillment: { notes: shipping.trim() },
          checkout: {
            gross: row.quote.gross.toString(),
            protocolFee: row.quote.protocolFee.toString(),
            repaymentAllocated: row.quote.repayment.toString(),
            producerNet: row.quote.producerNet.toString(),
          },
          metadata: {
            productName: row.name || row.item.skuId,
            cartSize: rows.length,
            cartTotalGross: orderTotals.gross.toString(),
          },
        });

        setStatus({ kind: "buy-sig", current: step, total: rows.length });
        const buyHash = await writeContractAsync({
          address: campaignAddress,
          abi: ecommerceModuleAbi,
          functionName: "buySku",
          args: [row.item.skuId, row.quantityBig, draft.orderHash],
        });
        setStatus({ kind: "buy-chain", current: step, total: rows.length });
        const buyReceipt = await waitForTx(buyHash);
        if (buyReceipt.status !== "success") throw new Error("Ecommerce purchase reverted");
        purchases.push({ row, draft, hash: buyHash });
      }

      const lastPurchase = purchases[purchases.length - 1];
      if (!lastPurchase) throw new Error("No purchase was executed");

      setStatus({ kind: "receipt" });
      const receipt = await sendEcommercePurchaseReceipt({
        email: email.trim().toLowerCase(),
        campaignName,
        productName:
          rows.length === 1
            ? rows[0].name || rows[0].item.skuId
            : t("receiptProductSummary", { count: rows.length }),
        quantity: cartQuantity.toString(),
        lineItems: rows.map((row) => ({
          productName: row.name || row.item.skuId,
          quantity: row.quantityBig.toString(),
        })),
        paymentAmount: formatUsdc(orderTotals.gross),
        paymentToken: "USDC",
        protocolFee: formatUsdc(orderTotals.protocolFee),
        repaymentAllocated: formatUsdc(orderTotals.repayment),
        producerNet: formatUsdc(orderTotals.producerNet),
        orderHash: lastPurchase.draft.orderHash,
        txHash: lastPurchase.hash,
        txUrl: txUrl(lastPurchase.hash),
        buyer: user,
        shippingSummary: shipping.trim(),
      });

      await Promise.all([refetchSkus(), refetchQuotes(), refetchBalance()]);
      notify.success(t("purchaseConfirmed"), lastPurchase.hash);
      setCart({});
      setCartOpen(false);
      setCheckoutOpen(false);
      setStatus({ kind: "success", hash: lastPurchase.hash, emailDelivered: receipt.emailDelivered });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setStatus(/user (rejected|denied)/i.test(message) ? { kind: "idle" } : { kind: "error", message });
      notify.error(t("purchaseFailed"), err);
    }
  };

  if (catalogLoading) {
    return (
      <div className="rounded-2xl border border-outline-variant/15 bg-surface-container-lowest p-8">
        <Spinner size={18} /> <span className="ml-2 text-sm">{t("loading")}</span>
      </div>
    );
  }

  const activeCatalog = catalog;
  if (!catalogURI || !activeCatalog || items.length === 0) {
    return (
      <div className="rounded-2xl border border-outline-variant/15 bg-surface-container-lowest p-8 text-sm text-on-surface-variant">
        {t("emptyCatalog")}
      </div>
    );
  }

  const catalogTitle = localizedText(
    activeCatalog.title,
    (activeCatalog as unknown as Record<string, unknown>).titleI18n,
    locale,
    t("title"),
    {
      [DEMO_CATALOG_TITLE]: t("title"),
      "Shop this harvest": t("title"),
    },
  );
  const catalogDescription = localizedText(
    activeCatalog.description,
    (activeCatalog as unknown as Record<string, unknown>).descriptionI18n,
    locale,
    t("subtitle"),
    {
      [DEMO_CATALOG_DESCRIPTION]: t("subtitle"),
    },
  );

  return (
    <div className="rounded-[28px] border border-outline-variant/15 bg-[#fffdf7] p-4 shadow-[0_24px_80px_rgba(20,35,24,0.07)] md:p-6">
      <div className="mb-6 flex flex-wrap items-start justify-between gap-4 border-b border-outline-variant/10 pb-5">
        <div className="max-w-2xl">
          <p className="text-xs font-bold uppercase text-primary">{t("eyebrow")}</p>
          <h2 className="mt-2 text-2xl font-bold text-on-surface md:text-3xl">{catalogTitle}</h2>
          <p className="mt-2 text-sm leading-6 text-on-surface-variant">{catalogDescription}</p>
        </div>
        <div className="flex items-center gap-3">
          <div className="rounded-full border border-primary/20 bg-primary-fixed px-4 py-2 text-xs font-bold text-on-primary-fixed-variant">
            {activeCatalog.repaymentAllocationBps > 0
              ? t("repaymentSplit", { pct: activeCatalog.repaymentAllocationBps / 100 })
              : t("directSplit")}
          </div>
          <button
            type="button"
            onClick={() => setCartOpen(true)}
            className="flex h-11 items-center gap-3 rounded-full border border-outline-variant/15 bg-white px-4 text-sm font-bold text-on-surface shadow-[0_8px_20px_rgba(20,35,24,0.08)] transition hover:border-primary/30"
            aria-label={t("openCart")}
          >
            <span>{t("cart")}</span>
            <span className="flex h-7 min-w-7 items-center justify-center rounded-full bg-on-surface px-2 text-xs font-bold text-surface">
              {cartQuantity}
            </span>
          </button>
        </div>
      </div>

      <div className="grid content-start gap-4 [grid-template-columns:repeat(auto-fit,minmax(min(100%,260px),1fr))]">
          {items.map((item) => {
            const sku = skuById.get(cartKey(item.skuId)) ?? null;
            const max = inventoryLimit(sku);
            const quantity = cart[cartKey(item.skuId)] ?? 0;
            const itemName = localizedText(
              item.name,
              (item as Record<string, unknown>).nameI18n,
              locale,
              shortHash(item.skuId),
              { [DEMO_PRODUCT_NAME]: t("defaultProductName") },
            );
            const itemDescription = localizedText(
              item.description,
              (item as Record<string, unknown>).descriptionI18n,
              locale,
              item.skuId,
              {
                [DEMO_PRODUCT_DESCRIPTION]: t("defaultProductDescription"),
                [DEMO_PRODUCT_DESCRIPTION_ALT]: t("defaultProductDescription"),
              },
            );
            return (
              <article
                key={item.skuId}
                className="flex min-h-[430px] flex-col overflow-hidden rounded-2xl border border-outline-variant/15 bg-white shadow-[0_12px_36px_rgba(20,35,24,0.06)]"
              >
                <div className="aspect-[4/3] bg-surface-container-high">
                  {item.image ? (
                    <img src={item.image} alt="" className="h-full w-full object-cover" />
                  ) : (
                    <div className="flex h-full items-center justify-center text-xs text-on-surface-variant">
                      {t("noImage")}
                    </div>
                  )}
                </div>
                <div className="flex flex-1 flex-col gap-5 p-4">
                  <div className="flex-1">
                    <div className="grid gap-2">
                      <h3 className="text-lg font-bold leading-tight text-on-surface">{itemName}</h3>
                      {sku?.exists && (
                        <span className="w-fit rounded-full bg-primary-fixed px-3 py-1 text-sm font-bold text-on-primary-fixed-variant">
                          ${formatUsdc(sku.priceUsdc)}
                        </span>
                      )}
                    </div>
                    <p className="mt-2 line-clamp-3 text-sm leading-6 text-on-surface-variant">
                      {itemDescription}
                    </p>
                  </div>

                  <div>
                    <div className="mb-3 flex flex-wrap items-center justify-between gap-2 text-xs text-on-surface-variant">
                      <span>{sku?.exists ? t("inventory", { count: sku.inventory.toString() }) : t("skuMissing")}</span>
                      {sku?.exists && <span>{t("sold", { count: sku.sold.toString() })}</span>}
                    </div>
                    {quantity > 0 ? (
                      <div className="grid h-12 grid-cols-[48px_1fr_48px] overflow-hidden rounded-full border border-outline-variant/15 bg-surface-container-lowest">
                        <button
                          type="button"
                          onClick={() => setCartQuantity(item.skuId, quantity - 1, max)}
                          className="flex items-center justify-center text-lg font-bold text-on-surface transition hover:bg-surface-container disabled:opacity-40"
                          aria-label={t("decreaseQty")}
                          disabled={busy}
                        >
                          −
                        </button>
                        <div className="flex items-center justify-center text-sm font-bold text-on-surface">
                          {quantity}
                        </div>
                        <button
                          type="button"
                          onClick={() => setCartQuantity(item.skuId, quantity + 1, max)}
                          className="flex items-center justify-center text-lg font-bold text-on-surface transition hover:bg-surface-container disabled:opacity-40"
                          aria-label={t("increaseQty")}
                          disabled={busy || quantity >= max}
                        >
                          +
                        </button>
                      </div>
                    ) : (
                      <button
                        type="button"
                        onClick={() => {
                          setCartQuantity(item.skuId, 1, max);
                          setCartOpen(true);
                        }}
                        disabled={busy || max === 0}
                        className="flex h-12 w-full items-center justify-center rounded-full bg-on-surface px-5 text-sm font-bold text-surface transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-45"
                      >
                        {max === 0 ? t("soldOut") : t("addToCart")}
                      </button>
                    )}
                  </div>
                </div>
              </article>
            );
          })}
      </div>

      {cartOpen && (
        <div className="fixed inset-0 z-50">
          <button
            type="button"
            aria-label={t("closeCart")}
            onClick={() => setCartOpen(false)}
            className="absolute inset-0 bg-black/35 backdrop-blur-[2px]"
          />
          <aside className="absolute right-0 top-0 flex h-dvh w-full max-w-[450px] flex-col bg-white shadow-[0_30px_110px_rgba(0,0,0,0.28)]">
            <div className="border-b border-outline-variant/15 px-5 py-5">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <h3 className="text-2xl font-bold text-on-surface">{t("cart")}</h3>
                  <p className="mt-1 text-sm text-on-surface-variant">
                    {cartQuantity > 0 ? t("cartCount", { count: cartQuantity }) : t("cartDrawerSubtitle")}
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => setCartOpen(false)}
                  className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-outline-variant/15 text-lg font-bold text-on-surface transition hover:bg-surface-container"
                  aria-label={t("closeCart")}
                >
                  ×
                </button>
              </div>
            </div>

            <div className="flex-1 overflow-auto px-5 py-5">
              {cartRows.length === 0 ? (
                <div className="rounded-2xl border border-dashed border-outline-variant/25 bg-surface-container-lowest p-5 text-sm text-on-surface-variant">
                  {t("cartEmptyHint")}
                </div>
              ) : (
                <div className="space-y-4">
                  {cartRows.map((row) => (
                    <div key={row.item.skuId} className="rounded-2xl border border-outline-variant/12 bg-surface-container-lowest p-3">
                      <div className="flex items-start gap-3">
                        <div className="h-16 w-16 shrink-0 overflow-hidden rounded-xl bg-surface-container-high">
                          {row.item.image ? (
                            <img src={row.item.image} alt="" className="h-full w-full object-cover" />
                          ) : (
                            <div className="flex h-full items-center justify-center text-[10px] text-on-surface-variant">
                              {t("noImage")}
                            </div>
                          )}
                        </div>
                        <div className="min-w-0 flex-1">
                          <div className="font-bold leading-snug text-on-surface">{row.name}</div>
                          <div className="mt-1 text-xs leading-5 text-on-surface-variant">
                            <div>{t("quantity")}: {row.quantity}</div>
                            <div>{t("lineTotal")}: {formatUsdc(row.quote.gross)} USDC</div>
                          </div>
                        </div>
                        <button
                          type="button"
                          onClick={() => setCartQuantity(row.item.skuId, 0, 0)}
                          className="rounded-full px-2 py-1 text-xs font-bold text-on-surface-variant transition hover:bg-surface-container hover:text-on-surface"
                          disabled={busy}
                        >
                          {t("remove")}
                        </button>
                      </div>
                      <div className="mt-3 grid h-10 grid-cols-[40px_1fr_40px] overflow-hidden rounded-full border border-outline-variant/15 bg-white">
                        <button
                          type="button"
                          onClick={() => setCartQuantity(row.item.skuId, row.quantity - 1, inventoryLimit(row.sku))}
                          className="flex items-center justify-center text-base font-bold text-on-surface transition hover:bg-surface-container disabled:opacity-40"
                          aria-label={t("decreaseQty")}
                          disabled={busy}
                        >
                          −
                        </button>
                        <div className="flex items-center justify-center text-sm font-bold text-on-surface">
                          {row.quantity}
                        </div>
                        <button
                          type="button"
                          onClick={() => setCartQuantity(row.item.skuId, row.quantity + 1, inventoryLimit(row.sku))}
                          className="flex items-center justify-center text-base font-bold text-on-surface transition hover:bg-surface-container disabled:opacity-40"
                          aria-label={t("increaseQty")}
                          disabled={busy || row.quantity >= inventoryLimit(row.sku)}
                        >
                          +
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>

            <div className="border-t border-outline-variant/15 bg-white px-5 py-5 shadow-[0_-18px_40px_rgba(20,35,24,0.08)]">
              <div className="space-y-2 text-sm">
                <Line label={t("gross")} value={`${formatUsdc(totals.gross)} USDC`} />
                <Line label={t("protocolFee")} value={`${formatUsdc(totals.protocolFee)} USDC`} />
                <Line label={t("repayment")} value={`${formatUsdc(totals.repayment)} USDC`} />
                <Line label={t("growerNet")} value={`${formatUsdc(totals.producerNet)} USDC`} strong />
              </div>

              <div className="mt-4 flex flex-wrap items-center justify-between gap-2 text-xs text-on-surface-variant">
                <button
                  onClick={handleMintUsdc}
                  disabled={!user || busy}
                  className="font-semibold text-primary disabled:opacity-50"
                >
                  {t("mintUsdc")}
                </button>
                <span>{t("balance", { amount: formatUsdc(balance) })}</span>
              </div>

              <button
                onClick={() => setCheckoutOpen(true)}
                disabled={!canOpenCheckout}
                className="mt-4 flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-on-surface text-surface text-sm font-bold transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {t("reviewCheckout")}
              </button>

              {status.kind === "error" && (
                <div className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-xs text-error">
                  {status.message}
                </div>
              )}
              {status.kind === "success" && (
                <div className="mt-3 rounded-lg border border-primary/25 bg-primary-fixed/25 p-3 text-xs text-primary">
                  <div className="font-bold">{t("success")}</div>
                  <a href={txUrl(status.hash)} target="_blank" rel="noreferrer" className="underline">
                    {t("viewTx")}
                  </a>
                  <div className="mt-1 text-on-surface-variant">
                    {status.emailDelivered ? t("emailDelivered") : t("emailPending")}
                  </div>
                </div>
              )}
            </div>
          </aside>
        </div>
      )}

      {checkoutOpen && (
        <div className="fixed inset-0 z-[60] flex items-end justify-center bg-black/45 p-3 backdrop-blur-sm md:items-center md:p-6">
          <div className="grid max-h-[92vh] w-full max-w-5xl overflow-hidden rounded-[28px] bg-white shadow-[0_32px_120px_rgba(0,0,0,0.24)] md:grid-cols-[minmax(0,1fr)_360px]">
            <div className="overflow-auto p-5 md:p-7">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <p className="text-xs font-bold uppercase text-primary">{t("checkout")}</p>
                  <h3 className="mt-1 text-2xl font-bold text-on-surface">{t("checkoutTitle")}</h3>
                  <p className="mt-2 max-w-xl text-sm leading-6 text-on-surface-variant">
                    {t("checkoutSubtitle")}
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => setCheckoutOpen(false)}
                  disabled={busy}
                  className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-outline-variant/15 text-lg font-bold text-on-surface transition hover:bg-surface-container disabled:opacity-40"
                  aria-label={t("closeCheckout")}
                >
                  ×
                </button>
              </div>

              <div className="mt-6 grid gap-4">
                <label className="block">
                  <span className="mb-1 block text-xs font-bold uppercase text-on-surface-variant">{t("email")}</span>
                  <input
                    type="email"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    placeholder="you@example.com"
                    className="h-12 w-full rounded-xl border border-outline-variant/15 bg-surface-container-lowest px-4 text-sm outline-none focus:border-primary/60"
                  />
                </label>
                <label className="block">
                  <span className="mb-1 block text-xs font-bold uppercase text-on-surface-variant">{t("name")}</span>
                  <input
                    type="text"
                    value={fullName}
                    onChange={(e) => setFullName(e.target.value)}
                    className="h-12 w-full rounded-xl border border-outline-variant/15 bg-surface-container-lowest px-4 text-sm outline-none focus:border-primary/60"
                  />
                </label>
                <label className="block">
                  <span className="mb-1 block text-xs font-bold uppercase text-on-surface-variant">{t("deliveryDetails")}</span>
                  <textarea
                    rows={5}
                    value={shipping}
                    onChange={(e) => setShipping(e.target.value)}
                    className="w-full rounded-xl border border-outline-variant/15 bg-surface-container-lowest px-4 py-3 text-sm outline-none focus:border-primary/60"
                  />
                </label>
              </div>

              <div className="mt-5 rounded-2xl border border-primary/20 bg-primary-fixed/20 p-4 text-sm leading-6 text-on-primary-fixed-variant">
                {t("checkoutNote")}
              </div>
            </div>

            <div className="border-t border-outline-variant/15 bg-surface-container-low p-5 md:border-l md:border-t-0 md:p-6">
              <h4 className="text-sm font-bold uppercase text-on-surface-variant">{t("orderSummary")}</h4>
              <div className="mt-4 space-y-3">
                {cartRows.map((row) => (
                  <div key={row.item.skuId} className="flex items-start justify-between gap-3 text-sm">
                    <div className="min-w-0">
                      <div className="font-bold text-on-surface">{row.name}</div>
                      <div className="text-xs text-on-surface-variant">
                        {row.quantity} × {formatUsdc(row.sku?.priceUsdc ?? 0n)} USDC
                      </div>
                    </div>
                    <div className="shrink-0 font-bold text-on-surface">
                      {formatUsdc(row.quote.gross)} USDC
                    </div>
                  </div>
                ))}
              </div>
              <div className="mt-5 space-y-2 border-t border-outline-variant/15 pt-4 text-sm">
                <Line label={t("gross")} value={`${formatUsdc(totals.gross)} USDC`} />
                <Line label={t("protocolFee")} value={`${formatUsdc(totals.protocolFee)} USDC`} />
                <Line label={t("repayment")} value={`${formatUsdc(totals.repayment)} USDC`} />
                <Line label={t("growerNet")} value={`${formatUsdc(totals.producerNet)} USDC`} strong />
              </div>
              <button
                onClick={handleCheckout}
                disabled={!canBuy}
                className="mt-5 flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-on-surface text-sm font-bold text-surface transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {busy && <Spinner size={16} />}
                {checkoutLabel}
              </button>
              {status.kind === "error" && (
                <div className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-xs text-error">
                  {status.message}
                </div>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function Line({
  label,
  value,
  strong = false,
}: {
  label: string;
  value: string;
  strong?: boolean;
}) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="text-on-surface-variant">{label}</span>
      <span className={strong ? "font-bold text-on-surface" : "text-on-surface"}>{value}</span>
    </div>
  );
}

export function EcommerceModuleManager({ campaignAddress }: { campaignAddress: Address }) {
  const t = useTranslations("detail.manage.ecommerce");
  const notify = useTxNotify();
  const { ecommerceImpl } = getAddresses();
  const { writeContractAsync } = useWriteContract();

  const [skuKey, setSkuKey] = useState("olive-oil-500ml");
  const [productName, setProductName] = useState(() => t("defaultProductName"));
  const [description, setDescription] = useState(() => t("defaultProductDescription"));
  const [image, setImage] = useState("");
  const [price, setPrice] = useState("18");
  const [inventory, setInventory] = useState("100");
  const [repaymentBps, setRepaymentBps] = useState("1000");
  const [protocolFeeBps, setProtocolFeeBps] = useState("0");
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const { data: slotData, refetch: refetchSlot } = useReadContract({
    address: campaignAddress,
    abi: campaignModuleHostAbi,
    functionName: "moduleSlot",
    args: [ECOMMERCE_MODULE_TYPE],
    query: { refetchInterval: 20_000 },
  });
  const slot = slotData as readonly [Address, `0x${string}`, string, bigint, boolean] | undefined;
  const isAttached = (slot?.[0] ?? zeroAddress) !== zeroAddress;
  const isEnabled = Boolean(slot?.[4]);
  const hasImpl = Boolean(ecommerceImpl && ecommerceImpl !== zeroAddress);

  const { data: reads, refetch: refetchReads } = useReadContracts({
    contracts: isAttached
      ? [
          { address: campaignAddress, abi: ecommerceModuleAbi, functionName: "catalogURI" },
          { address: campaignAddress, abi: ecommerceModuleAbi, functionName: "protocolFeeBps" },
          { address: campaignAddress, abi: ecommerceModuleAbi, functionName: "repaymentAllocationBps" },
          { address: campaignAddress, abi: ecommerceModuleAbi, functionName: "grossSales" },
          { address: campaignAddress, abi: ecommerceModuleAbi, functionName: "repaymentAllocated" },
        ]
      : [],
    query: { enabled: isAttached, refetchInterval: 20_000 },
  });

  const catalogURI = (reads?.[0]?.result as string | undefined) ?? "";
  const currentProtocolFee = Number((reads?.[1]?.result as number | bigint | undefined) ?? 0);
  const currentRepayment = Number((reads?.[2]?.result as number | bigint | undefined) ?? 0);
  const grossSales = (reads?.[3]?.result as bigint | undefined) ?? 0n;
  const repaymentAllocated = (reads?.[4]?.result as bigint | undefined) ?? 0n;

  const skuId = useMemo(() => keccak256(toBytes(skuKey.trim() || "sku")), [skuKey]);

  const refresh = async () => {
    await Promise.all([refetchSlot(), refetchReads()]);
  };

  const handlePublish = async () => {
    setError(null);
    try {
      if (!hasImpl || !ecommerceImpl) throw new Error(t("implMissing"));
      if (!productName.trim()) throw new Error(t("nameRequired"));
      const priceUsdc = parseUnits(price || "0", USDC_DECIMALS);
      const inventoryUnits = BigInt(inventory || "0");
      const repayment = Number(repaymentBps || "0");
      const protocolFee = Number(protocolFeeBps || "0");
      if (priceUsdc === 0n || inventoryUnits === 0n) throw new Error(t("skuRequired"));

      setPending(t("uploading"));
      const catalog = await uploadEcommerceCatalog({
        campaign: campaignAddress,
        title: DEMO_CATALOG_TITLE,
        description: DEMO_CATALOG_DESCRIPTION,
        repaymentAllocationBps: repayment,
        items: [
          {
            skuId,
            name: productName.trim(),
            description: description.trim(),
            image: image.trim() || undefined,
            unit: "unit",
          } as EcommerceCatalogItem,
        ],
      });

      if (!isAttached) {
        setPending(t("attachSig"));
        const attachHash = await writeContractAsync({
          address: campaignAddress,
          abi: campaignModuleHostAbi,
          functionName: "attachModule",
          args: [
            ECOMMERCE_MODULE_TYPE,
            ECOMMERCE_MODULE_KIND,
            ecommerceImpl,
            "growfi://ecommerce/v1",
          ],
        });
        setPending(t("attachChain"));
        const attachReceipt = await waitForTx(attachHash);
        if (attachReceipt.status !== "success") throw new Error("attachModule reverted");

        setPending(t("initializeSig"));
        const initHash = await writeContractAsync({
          address: campaignAddress,
          abi: ecommerceModuleAbi,
          functionName: "initializeEcommerceByProducer",
          args: [protocolFee, catalog.url],
        });
        setPending(t("initializeChain"));
        const initReceipt = await waitForTx(initHash);
        if (initReceipt.status !== "success") throw new Error("initializeEcommerceByProducer reverted");
      } else {
        setPending(t("catalogSig"));
        const catalogHash = await writeContractAsync({
          address: campaignAddress,
          abi: ecommerceModuleAbi,
          functionName: "setCatalogURI",
          args: [catalog.url],
        });
        setPending(t("catalogChain"));
        const catalogReceipt = await waitForTx(catalogHash);
        if (catalogReceipt.status !== "success") throw new Error("setCatalogURI reverted");

        if (currentProtocolFee !== protocolFee) {
          setPending(t("feeSig"));
          const feeHash = await writeContractAsync({
            address: campaignAddress,
            abi: ecommerceModuleAbi,
            functionName: "setProtocolFeeBps",
            args: [protocolFee],
          });
          setPending(t("feeChain"));
          const feeReceipt = await waitForTx(feeHash);
          if (feeReceipt.status !== "success") throw new Error("setProtocolFeeBps reverted");
        }
      }

      setPending(t("repaymentSig"));
      const repaymentHash = await writeContractAsync({
        address: campaignAddress,
        abi: ecommerceModuleAbi,
        functionName: "setRepaymentAllocationBps",
        args: [repayment],
      });
      setPending(t("repaymentChain"));
      const repaymentReceipt = await waitForTx(repaymentHash);
      if (repaymentReceipt.status !== "success") throw new Error("setRepaymentAllocationBps reverted");

      setPending(t("skuSig"));
      const skuHash = await writeContractAsync({
        address: campaignAddress,
        abi: ecommerceModuleAbi,
        functionName: "setSku",
        args: [skuId, priceUsdc, inventoryUnits, true],
      });
      setPending(t("skuChain"));
      const skuReceipt = await waitForTx(skuHash);
      if (skuReceipt.status !== "success") throw new Error("setSku reverted");

      await refresh();
      notify.success(t("published"), skuHash);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      if (!/user (rejected|denied)/i.test(message)) setError(message);
      notify.error(t("publishFailed"), err);
    } finally {
      setPending(null);
    }
  };

  return (
    <div className="space-y-4 rounded-xl border border-outline-variant/15 bg-surface-container-low p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <span className={`h-2 w-2 rounded-full ${isAttached && isEnabled ? "bg-emerald-500" : "bg-outline"}`} />
            <div className="text-sm font-bold text-on-surface">
              {isAttached ? t("statusAttached") : t("statusMissing")}
            </div>
          </div>
          <p className="mt-1 text-xs text-on-surface-variant">
            {isAttached ? t("attachedHint") : t("missingHint")}
          </p>
        </div>
        {isAttached && (
          <div className="text-right text-xs text-on-surface-variant">
            <div>{t("grossSales", { amount: formatUsdc(grossSales) })}</div>
            <div>{t("repaymentAllocated", { amount: formatUsdc(repaymentAllocated) })}</div>
          </div>
        )}
      </div>

      <div className="grid gap-3 md:grid-cols-2">
        <label className="block">
          <span className="mb-1 block text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("skuKey")}
          </span>
          <input
            value={skuKey}
            onChange={(e) => setSkuKey(e.target.value)}
            className="w-full rounded-lg border border-outline-variant/15 bg-surface-container px-3 py-2 text-sm outline-none focus:border-primary/50"
          />
        </label>
        <label className="block">
          <span className="mb-1 block text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("productName")}
          </span>
          <input
            value={productName}
            onChange={(e) => setProductName(e.target.value)}
            className="w-full rounded-lg border border-outline-variant/15 bg-surface-container px-3 py-2 text-sm outline-none focus:border-primary/50"
          />
        </label>
        <label className="block md:col-span-2">
          <span className="mb-1 block text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("description")}
          </span>
          <textarea
            rows={2}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full rounded-lg border border-outline-variant/15 bg-surface-container px-3 py-2 text-sm outline-none focus:border-primary/50"
          />
        </label>
        <label className="block md:col-span-2">
          <span className="mb-1 block text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("image")}
          </span>
          <input
            value={image}
            onChange={(e) => setImage(e.target.value)}
            placeholder="https://…"
            className="w-full rounded-lg border border-outline-variant/15 bg-surface-container px-3 py-2 text-sm outline-none focus:border-primary/50"
          />
        </label>
        <label className="block">
          <span className="mb-1 block text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("price")}
          </span>
          <input
            type="number"
            min="0"
            step="0.000001"
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            className="w-full rounded-lg border border-outline-variant/15 bg-surface-container px-3 py-2 text-sm outline-none focus:border-primary/50"
          />
        </label>
        <label className="block">
          <span className="mb-1 block text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("inventory")}
          </span>
          <input
            type="number"
            min="1"
            step="1"
            value={inventory}
            onChange={(e) => setInventory(e.target.value)}
            className="w-full rounded-lg border border-outline-variant/15 bg-surface-container px-3 py-2 text-sm outline-none focus:border-primary/50"
          />
        </label>
        <label className="block">
          <span className="mb-1 block text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("protocolFee")}
          </span>
          <input
            type="number"
            min="0"
            max="1000"
            step="1"
            value={protocolFeeBps}
            onChange={(e) => setProtocolFeeBps(e.target.value)}
            className="w-full rounded-lg border border-outline-variant/15 bg-surface-container px-3 py-2 text-sm outline-none focus:border-primary/50"
          />
          <span className="mt-1 block text-[11px] text-on-surface-variant">
            {t("currentBps", { value: currentProtocolFee })}
          </span>
        </label>
        <label className="block">
          <span className="mb-1 block text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("repaymentBps")}
          </span>
          <input
            type="number"
            min="0"
            max="10000"
            step="1"
            value={repaymentBps}
            onChange={(e) => setRepaymentBps(e.target.value)}
            className="w-full rounded-lg border border-outline-variant/15 bg-surface-container px-3 py-2 text-sm outline-none focus:border-primary/50"
          />
          <span className="mt-1 block text-[11px] text-on-surface-variant">
            {t("currentBps", { value: currentRepayment })}
          </span>
        </label>
      </div>

      {catalogURI && (
        <div className="break-all rounded-lg bg-surface-container px-3 py-2 text-xs text-on-surface-variant">
          {t("catalog")}: {catalogURI}
        </div>
      )}
      {!hasImpl && <div className="text-xs text-error">{t("implMissing")}</div>}
      {error && <div className="break-words text-xs text-error">{error}</div>}

      <button
        onClick={handlePublish}
        disabled={Boolean(pending) || !hasImpl}
        className="inline-flex h-10 items-center justify-center gap-2 rounded-full bg-on-surface px-5 text-sm font-bold text-surface transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
      >
        {pending && <Spinner size={14} />}
        {pending ?? (isAttached ? t("updateCta") : t("enableCta"))}
      </button>
    </div>
  );
}
