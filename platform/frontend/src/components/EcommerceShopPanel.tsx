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

type TxStatus =
  | { kind: "idle" }
  | { kind: "mint-sig" | "mint-chain" }
  | { kind: "approve-sig" | "approve-chain" }
  | { kind: "draft" }
  | { kind: "buy-sig" | "buy-chain" }
  | { kind: "receipt" }
  | { kind: "success"; hash: `0x${string}`; emailDelivered: boolean }
  | { kind: "error"; message: string };

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

  const items = catalog?.items ?? [];
  const [selectedSku, setSelectedSku] = useState<`0x${string}` | null>(null);
  const selectedItem = useMemo(() => {
    if (items.length === 0) return null;
    const current = selectedSku
      ? items.find((item) => item.skuId.toLowerCase() === selectedSku.toLowerCase())
      : null;
    return current ?? items[0];
  }, [items, selectedSku]);

  const [quantity, setQuantity] = useState("1");
  const quantityBig = useMemo(() => {
    if (!/^[0-9]+$/.test(quantity)) return 0n;
    const parsed = BigInt(quantity);
    return parsed > 0n ? parsed : 0n;
  }, [quantity]);

  const { data: skuRaw, refetch: refetchSku } = useReadContract({
    address: campaignAddress,
    abi: ecommerceModuleAbi,
    functionName: "sku",
    args: selectedItem ? [selectedItem.skuId] : undefined,
    query: {
      enabled: Boolean(selectedItem),
      refetchInterval: 15_000,
    },
  });
  const sku = readSku(skuRaw);

  const { data: quoteRaw } = useReadContract({
    address: campaignAddress,
    abi: ecommerceModuleAbi,
    functionName: "quoteSku",
    args: selectedItem && quantityBig > 0n ? [selectedItem.skuId, quantityBig] : undefined,
    query: { enabled: Boolean(selectedItem && quantityBig > 0n) },
  });
  const quote = Array.isArray(quoteRaw)
    ? {
        gross: (quoteRaw[0] as bigint | undefined) ?? 0n,
        protocolFee: (quoteRaw[1] as bigint | undefined) ?? 0n,
        repayment: (quoteRaw[2] as bigint | undefined) ?? 0n,
        producerNet: (quoteRaw[3] as bigint | undefined) ?? 0n,
      }
    : { gross: 0n, protocolFee: 0n, repayment: 0n, producerNet: 0n };

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
  const selectedProductName = selectedItem
    ? localizedText(
        selectedItem.name,
        (selectedItem as Record<string, unknown>).nameI18n,
        locale,
        shortHash(selectedItem.skuId),
        { [DEMO_PRODUCT_NAME]: t("defaultProductName") },
      )
    : "";

  const busy = status.kind !== "idle" && status.kind !== "success" && status.kind !== "error";
  const needsApproval = quote.gross > 0n && allowance < quote.gross;
  const canBuy =
    isConnected &&
    currentState === 1 &&
    selectedItem &&
    sku?.exists &&
    sku.active &&
    quantityBig > 0n &&
    quantityBig <= sku.inventory &&
    quote.gross > 0n &&
    balance >= quote.gross &&
    /\S+@\S+\.\S+/.test(email) &&
    fullName.trim().length > 1 &&
    shipping.trim().length > 4 &&
    !busy;

  const buttonLabel = !isConnected
    ? t("connect")
    : currentState !== 1
      ? t("inactiveCampaign")
      : !selectedItem
        ? t("empty")
        : !sku?.exists
          ? t("skuMissing")
          : !sku.active
            ? t("skuInactive")
            : quantityBig > (sku?.inventory ?? 0n)
              ? t("soldOut")
              : balance < quote.gross
                ? t("insufficientUsdc")
                : busy
                  ? t(status.kind)
                  : needsApproval
                    ? t("approveAndBuy")
                    : t("checkout");

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
    if (!user || !selectedItem || !sku || quote.gross === 0n) return;
    try {
      if (needsApproval) {
        setStatus({ kind: "approve-sig" });
        const approveHash = await writeContractAsync({
          address: usdc,
          abi: erc20Abi,
          functionName: "approve",
          args: [campaignAddress, quote.gross],
        });
        setStatus({ kind: "approve-chain" });
        const approveReceipt = await waitForTx(approveHash);
        if (approveReceipt.status !== "success") throw new Error("USDC approval reverted");
      }

      setStatus({ kind: "draft" });
      const draft = await createEcommerceOrderDraft({
        campaign: campaignAddress,
        buyer: user,
        skuId: selectedItem.skuId,
        quantity: quantityBig.toString(),
        customer: { email: email.trim().toLowerCase(), name: fullName.trim() },
        fulfillment: { notes: shipping.trim() },
        checkout: {
          gross: quote.gross.toString(),
          protocolFee: quote.protocolFee.toString(),
          repaymentAllocated: quote.repayment.toString(),
          producerNet: quote.producerNet.toString(),
        },
        metadata: { productName: selectedProductName || selectedItem.skuId },
      });

      setStatus({ kind: "buy-sig" });
      const buyHash = await writeContractAsync({
        address: campaignAddress,
        abi: ecommerceModuleAbi,
        functionName: "buySku",
        args: [selectedItem.skuId, quantityBig, draft.orderHash],
      });
      setStatus({ kind: "buy-chain" });
      const buyReceipt = await waitForTx(buyHash);
      if (buyReceipt.status !== "success") throw new Error("Ecommerce purchase reverted");

      setStatus({ kind: "receipt" });
      const receipt = await sendEcommercePurchaseReceipt({
        email: email.trim().toLowerCase(),
        campaignName,
        productName: selectedProductName || selectedItem.skuId,
        quantity: quantityBig.toString(),
        paymentAmount: formatUsdc(quote.gross),
        paymentToken: "USDC",
        protocolFee: formatUsdc(quote.protocolFee),
        repaymentAllocated: formatUsdc(quote.repayment),
        producerNet: formatUsdc(quote.producerNet),
        orderHash: draft.orderHash,
        txHash: buyHash,
        txUrl: txUrl(buyHash),
        buyer: user,
        shippingSummary: shipping.trim(),
      });

      await Promise.all([refetchSku(), refetchBalance()]);
      notify.success(t("purchaseConfirmed"), buyHash);
      setStatus({ kind: "success", hash: buyHash, emailDelivered: receipt.emailDelivered });
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
  if (!catalogURI || !activeCatalog || items.length === 0 || !selectedItem) {
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
    <div className="rounded-2xl border border-outline-variant/15 bg-surface-container-lowest p-5 md:p-8">
      <div className="mb-6 flex flex-wrap items-start justify-between gap-4">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.16em] text-primary">{t("eyebrow")}</p>
          <h2 className="mt-1 text-2xl font-bold tracking-tight text-on-surface">
            {catalogTitle}
          </h2>
          <p className="mt-2 max-w-2xl text-sm text-on-surface-variant">
            {catalogDescription}
          </p>
        </div>
        <div className="rounded-full bg-primary-fixed px-3 py-1 text-xs font-bold text-on-primary-fixed-variant">
          {activeCatalog.repaymentAllocationBps > 0
            ? t("repaymentSplit", { pct: activeCatalog.repaymentAllocationBps / 100 })
            : t("directSplit")}
        </div>
      </div>

      <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_320px]">
        <div className="grid content-start gap-3">
          {items.map((item) => {
            const active = item.skuId === selectedItem.skuId;
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
              <button
                key={item.skuId}
                onClick={() => setSelectedSku(item.skuId)}
                className={`grid gap-4 rounded-xl border p-4 text-left transition md:grid-cols-[104px_1fr] ${
                  active
                    ? "border-primary bg-primary-fixed/20"
                    : "border-outline-variant/15 bg-surface-container-low hover:border-primary/30"
                }`}
              >
                <div className="h-24 overflow-hidden rounded-lg bg-surface-container-high">
                  {item.image ? (
                    <img src={item.image} alt="" className="h-full w-full object-cover" />
                  ) : (
                    <div className="flex h-full items-center justify-center text-xs text-on-surface-variant">
                      {t("noImage")}
                    </div>
                  )}
                </div>
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <h3 className="font-bold text-on-surface">{itemName}</h3>
                    {active && sku?.exists && (
                      <span className="text-sm font-bold text-primary">
                        ${formatUsdc(sku.priceUsdc)}
                      </span>
                    )}
                  </div>
                  <p className="mt-1 line-clamp-2 text-sm text-on-surface-variant">
                    {itemDescription}
                  </p>
                  {active && sku?.exists && (
                    <div className="mt-3 flex flex-wrap gap-2 text-xs text-on-surface-variant">
                      <span>{t("inventory", { count: sku.inventory.toString() })}</span>
                      <span>·</span>
                      <span>{t("sold", { count: sku.sold.toString() })}</span>
                    </div>
                  )}
                </div>
              </button>
            );
          })}
        </div>

        <aside className="rounded-xl border border-outline-variant/15 bg-surface-container-low p-4">
          <h3 className="text-sm font-bold uppercase tracking-wider text-on-surface-variant">
            {t("cart")}
          </h3>

          <div className="mt-4 space-y-3">
            <label className="block">
              <span className="mb-1 block text-xs font-semibold text-on-surface-variant">{t("quantity")}</span>
              <input
                type="number"
                min="1"
                step="1"
                value={quantity}
                onChange={(e) => setQuantity(e.target.value)}
                className="w-full rounded-lg border border-outline-variant/15 bg-surface-container-lowest px-3 py-2 text-sm outline-none focus:border-primary/60"
              />
            </label>
            <label className="block">
              <span className="mb-1 block text-xs font-semibold text-on-surface-variant">{t("email")}</span>
              <input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@example.com"
                className="w-full rounded-lg border border-outline-variant/15 bg-surface-container-lowest px-3 py-2 text-sm outline-none focus:border-primary/60"
              />
            </label>
            <label className="block">
              <span className="mb-1 block text-xs font-semibold text-on-surface-variant">{t("name")}</span>
              <input
                type="text"
                value={fullName}
                onChange={(e) => setFullName(e.target.value)}
                className="w-full rounded-lg border border-outline-variant/15 bg-surface-container-lowest px-3 py-2 text-sm outline-none focus:border-primary/60"
              />
            </label>
            <label className="block">
              <span className="mb-1 block text-xs font-semibold text-on-surface-variant">{t("shipping")}</span>
              <textarea
                rows={3}
                value={shipping}
                onChange={(e) => setShipping(e.target.value)}
                className="w-full rounded-lg border border-outline-variant/15 bg-surface-container-lowest px-3 py-2 text-sm outline-none focus:border-primary/60"
              />
            </label>
          </div>

          <div className="mt-5 space-y-2 border-t border-outline-variant/15 pt-4 text-sm">
            <Line label={t("gross")} value={`${formatUsdc(quote.gross)} USDC`} />
            <Line label={t("protocolFee")} value={`${formatUsdc(quote.protocolFee)} USDC`} />
            <Line label={t("repayment")} value={`${formatUsdc(quote.repayment)} USDC`} />
            <Line label={t("growerNet")} value={`${formatUsdc(quote.producerNet)} USDC`} strong />
          </div>

          <div className="mt-4 flex items-center justify-between text-xs text-on-surface-variant">
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
            onClick={handleCheckout}
            disabled={!canBuy}
            className="mt-4 flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-on-surface text-surface text-sm font-bold transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {busy && <Spinner size={16} />}
            {buttonLabel}
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
        </aside>
      </div>
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
