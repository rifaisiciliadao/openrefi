"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { formatUnits, type Address } from "viem";
import { useReadContract } from "wagmi";
import {
  useCampaignInvestors,
  useBatchProducerProfiles,
} from "@/lib/subgraph";
import { erc20Abi } from "@/contracts/erc20";

/**
 * Social-recognition widget for the Invest tab: lists all wallets that
 * bought into the campaign, sorted by size, with links to their producer
 * profile (if they ever registered one via ProducerRegistry).
 *
 * Reads:
 *   - `useCampaignInvestors` folds `Purchase` events per buyer.
 *   - `useBatchProducerProfiles` resolves wallet → display name in one
 *     subgraph round-trip; anonymous buyers keep their shortened address.
 *   - campaignToken.symbol() for the suffix label.
 */
export function InvestorList({
  campaignAddress,
  campaignToken,
  currentSupply,
}: {
  campaignAddress: string;
  campaignToken: Address;
  currentSupply: bigint;
}) {
  const { data: symbolRaw } = useReadContract({
    address: campaignToken,
    abi: erc20Abi,
    functionName: "symbol",
  });
  const campaignSymbol = (symbolRaw as string | undefined) ?? "CAMP";
  const t = useTranslations("detail.investors");
  const { data: investors, isLoading } = useCampaignInvestors(campaignAddress);
  const addresses = (investors ?? []).map((i) => i.buyer);
  const { data: profiles } = useBatchProducerProfiles(addresses);

  if (isLoading) {
    return (
      <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-6">
        <div className="h-4 w-32 rounded bg-surface-container-high animate-pulse mb-4" />
        <div className="space-y-3">
          {[0, 1, 2].map((i) => (
            <div key={i} className="flex items-center gap-3">
              <div className="w-9 h-9 rounded-full bg-surface-container-high animate-pulse" />
              <div className="flex-1 space-y-1.5">
                <div className="h-3 w-40 rounded bg-surface-container-high animate-pulse" />
                <div className="h-2.5 w-24 rounded bg-surface-container-high animate-pulse" />
              </div>
              <div className="h-4 w-16 rounded bg-surface-container-high animate-pulse" />
            </div>
          ))}
        </div>
      </div>
    );
  }

  const list = investors ?? [];
  if (list.length === 0) {
    return (
      <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-6 text-center">
        <div className="text-3xl mb-2">🌱</div>
        <h3 className="text-sm font-semibold text-on-surface mb-1">
          {t("emptyTitle")}
        </h3>
        <p className="text-xs text-on-surface-variant">{t("emptyBody")}</p>
      </div>
    );
  }

  const top = list.slice(0, 25);
  const truncated = list.length > top.length;

  return (
    <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-6">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-bold text-on-surface uppercase tracking-wider">
          {t("title")}
        </h3>
        <span className="text-xs text-on-surface-variant">
          {t("count", { count: list.length })}
        </span>
      </div>

      <ol className="space-y-2">
        {top.map((inv, i) => {
          const profile = profiles?.get(inv.buyer.toLowerCase());
          const displayName =
            profile?.name ??
            `${inv.buyer.slice(0, 6)}…${inv.buyer.slice(-4)}`;
          const sharePct =
            currentSupply > 0n
              ? Number((inv.totalTokens * 10000n) / currentSupply) / 100
              : 0;
          return (
            <li
              key={inv.buyer}
              className="border-b border-outline-variant/10 last:border-0"
            >
              <Link
                href={`/producer/${inv.buyer}`}
                className="flex items-center gap-3 py-3 -mx-2 px-2 rounded-lg hover:bg-surface-container-low transition-colors"
              >
                <div className="text-xs font-mono text-on-surface-variant w-6 shrink-0 text-right">
                  {i + 1}
                </div>
                {profile?.avatar ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img
                    src={profile.avatar}
                    alt={displayName}
                    className="w-9 h-9 rounded-full object-cover border border-outline-variant/15 shrink-0"
                  />
                ) : (
                  <div className="w-9 h-9 rounded-full bg-primary-fixed text-on-primary-fixed-variant flex items-center justify-center text-[11px] font-bold shrink-0">
                    {inv.buyer.slice(2, 4).toUpperCase()}
                  </div>
                )}
                <div className="flex-1 min-w-0">
                  <div className="text-sm font-semibold text-on-surface truncate">
                    {displayName}
                    {profile?.name && (
                      <svg
                        width="10"
                        height="10"
                        viewBox="0 0 16 16"
                        className="inline-block ml-1 mb-0.5 text-primary"
                        fill="currentColor"
                        aria-label="verified"
                      >
                        <path d="M8 0a8 8 0 100 16A8 8 0 008 0zm3.78 6.28l-4.5 4.5a.75.75 0 01-1.06 0l-2-2a.75.75 0 011.06-1.06L6.75 9.19l3.97-3.97a.75.75 0 011.06 1.06z" />
                      </svg>
                    )}
                  </div>
                  <div className="text-[11px] text-on-surface-variant">
                    {t("sharePct", {
                      pct: sharePct.toLocaleString(undefined, {
                        maximumFractionDigits: 2,
                      }),
                    })}{" "}
                    · {t("txCount", { count: inv.purchaseCount })}
                  </div>
                </div>
                <div className="text-right shrink-0">
                  <div className="text-sm font-bold text-on-surface whitespace-nowrap">
                    {Number(
                      formatUnits(inv.totalTokens, 18),
                    ).toLocaleString(undefined, { maximumFractionDigits: 0 })}{" "}
                    <span className="text-xs text-on-surface-variant">
                      ${campaignSymbol}
                    </span>
                  </div>
                </div>
              </Link>
            </li>
          );
        })}
      </ol>

      {truncated && (
        <p className="text-[11px] text-on-surface-variant text-center mt-3">
          {t("truncated", { shown: top.length, total: list.length })}
        </p>
      )}
    </div>
  );
}
