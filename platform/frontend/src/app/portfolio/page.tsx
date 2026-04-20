"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { useAccount, useReadContracts } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { formatUnits, type Address } from "viem";
import { useMemo } from "react";
import { useUserPortfolio, type UserPortfolio } from "@/lib/subgraph";
import { useCampaignMetadata } from "@/lib/metadata";
import { erc20Abi } from "@/contracts/erc20";
import { RefreshButton } from "@/components/RefreshButton";

export default function Portfolio() {
  const t = useTranslations("portfolio");
  const tHome = useTranslations("home");
  const { address: user, isConnected } = useAccount();

  const { data: portfolio, isLoading, refetch } = useUserPortfolio(user);

  if (!isConnected) {
    return <PortfolioConnectPrompt />;
  }

  return (
    <div className="max-w-7xl mx-auto px-4 md:px-8 pt-28 pb-20">
      <div className="flex items-start justify-between gap-4 mb-2">
        <h1 className="text-3xl md:text-4xl font-bold tracking-tight text-on-surface">
          {t("title")}
        </h1>
        <RefreshButton
          onClick={() => refetch()}
          label={t("refresh")}
          className="mt-2 shrink-0"
        />
      </div>
      <p className="text-on-surface-variant mb-10 font-mono text-xs md:text-sm break-all">
        {user}
      </p>

      {isLoading && (
        <p className="text-on-surface-variant">{t("loading")}</p>
      )}

      {portfolio && (
        <>
          <Summary portfolio={portfolio} />
          <Section title={t("positionsTitle")}>
            {portfolio.positions.length === 0 ? (
              <EmptyState text={t("noPositions")} />
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                {portfolio.positions.map((pos) => (
                  <PositionCard key={pos.id} position={pos} />
                ))}
              </div>
            )}
          </Section>

          <Section title={t("purchasesTitle")}>
            {portfolio.purchases.length === 0 ? (
              <EmptyState text={t("noPurchases")} />
            ) : (
              <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 overflow-x-auto">
                <table className="w-full text-sm min-w-[560px]">
                  <thead className="bg-surface-container-low">
                    <tr className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
                      <th className="text-left px-6 py-3">
                        {t("col.campaign")}
                      </th>
                      <th className="text-right px-6 py-3">
                        {t("col.paid")}
                      </th>
                      <th className="text-right px-6 py-3">
                        {t("col.received")}
                      </th>
                      <th className="text-right px-6 py-3">
                        {t("col.date")}
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {portfolio.purchases.map((p) => (
                      <tr
                        key={p.id}
                        className="border-t border-outline-variant/15"
                      >
                        <td className="px-6 py-3">
                          <Link
                            href={`/campaign/${p.campaign.id}`}
                            className="text-primary hover:underline font-mono text-xs"
                          >
                            {p.campaign.id.slice(0, 8)}…
                            {p.campaign.id.slice(-4)}
                          </Link>
                        </td>
                        <td className="px-6 py-3 text-right font-mono text-xs">
                          {p.paymentToken.slice(0, 6)}…
                        </td>
                        <td className="px-6 py-3 text-right font-semibold text-on-surface">
                          {Number(
                            formatUnits(BigInt(p.campaignTokensOut), 18),
                          ).toLocaleString(undefined, {
                            maximumFractionDigits: 2,
                          })}{" "}
                          $CAMP
                        </td>
                        <td className="px-6 py-3 text-right text-on-surface-variant">
                          {new Date(
                            Number(p.timestamp) * 1000,
                          ).toLocaleDateString()}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Section>

          <Section title={t("claimsTitle")}>
            {portfolio.claims.length === 0 ? (
              <EmptyState text={t("noClaims")} />
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {portfolio.claims.map((c) => (
                  <ClaimCard key={c.id} claim={c} />
                ))}
              </div>
            )}
          </Section>
        </>
      )}
    </div>
  );
}

function PortfolioConnectPrompt() {
  const t = useTranslations("portfolio");
  return (
    <div className="max-w-3xl mx-auto px-4 md:px-8 pt-24 md:pt-32 pb-24 text-center">
      <div className="relative mx-auto mb-10 w-36 h-36 md:w-44 md:h-44">
        {/* Pulsing halo rings */}
        <span className="absolute inset-0 rounded-full bg-primary-fixed/50 animate-ping" />
        <span
          className="absolute inset-2 rounded-full bg-primary-fixed/40 animate-ping"
          style={{ animationDelay: "0.6s" }}
        />
        <span
          className="absolute inset-4 rounded-full bg-primary-fixed/30 animate-ping"
          style={{ animationDelay: "1.2s" }}
        />
        <div className="absolute inset-6 rounded-full regen-gradient flex items-center justify-center shadow-2xl shadow-primary/40">
          <svg
            width="48"
            height="48"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.8"
            strokeLinecap="round"
            strokeLinejoin="round"
            className="text-white"
            aria-hidden
          >
            <path d="M21 12V7a2 2 0 0 0-2-2H5a2 2 0 0 0 0 4h15a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7" />
            <circle cx="17" cy="12" r="1.2" fill="currentColor" />
          </svg>
        </div>
      </div>

      <h1 className="text-3xl md:text-5xl font-extrabold tracking-tight text-on-surface mb-4">
        {t("title")}
      </h1>
      <p className="text-base md:text-lg text-on-surface-variant mb-10 max-w-xl mx-auto leading-relaxed">
        {t("connectWallet")}
      </p>

      <ConnectButton.Custom>
        {({ openConnectModal, mounted }) => (
          <button
            type="button"
            onClick={openConnectModal}
            disabled={!mounted}
            className="regen-gradient text-white h-14 px-10 rounded-full text-sm font-semibold tracking-widest uppercase shadow-lg shadow-primary/25 hover:opacity-90 transition inline-flex items-center gap-3 disabled:opacity-60"
          >
            <svg
              width="20"
              height="20"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden
            >
              <path d="M21 12V7a2 2 0 0 0-2-2H5a2 2 0 0 0 0 4h15a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7" />
              <circle cx="17" cy="12" r="1.3" fill="currentColor" />
            </svg>
            {t("connectCta")}
          </button>
        )}
      </ConnectButton.Custom>

      <div className="mt-14 grid grid-cols-1 sm:grid-cols-3 gap-4 max-w-2xl mx-auto">
        {(["positions", "purchases", "claims"] as const).map((k) => (
          <div
            key={k}
            className="bg-surface-container-lowest border border-outline-variant/15 rounded-2xl p-5"
          >
            <div className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-1">
              {t(`preview.${k}.label`)}
            </div>
            <div className="text-sm text-on-surface">
              {t(`preview.${k}.hint`)}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="mb-12">
      <h2 className="text-xl font-bold text-on-surface mb-4">{title}</h2>
      {children}
    </section>
  );
}

function EmptyState({ text }: { text: string }) {
  return (
    <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-8 text-center text-sm text-on-surface-variant">
      {text}
    </div>
  );
}

function Summary({ portfolio }: { portfolio: UserPortfolio }) {
  const t = useTranslations("portfolio");

  const { totalPurchasedUSD, totalStaked, totalYieldClaimed, totalUsdcClaimable } =
    useMemo(() => {
      const toUsd = (tokens: string, pricePerToken: string) =>
        (BigInt(tokens) * BigInt(pricePerToken)) / 10n ** 18n;

      const purchased = portfolio.purchases.reduce(
        (acc, p) => acc + toUsd(p.campaignTokensOut, p.campaign.pricePerToken),
        0n,
      );

      const staked = portfolio.positions.reduce(
        (acc, pos) => acc + BigInt(pos.amount),
        0n,
      );

      const yieldClaimed = portfolio.positions.reduce(
        (acc, pos) => acc + BigInt(pos.yieldClaimed),
        0n,
      );

      // USDC claimable = pending USDC redemptions scaled by pro-rata deposits
      const usdcClaimable = portfolio.claims.reduce((acc, c) => {
        if (c.redemptionType !== "usdc") return acc;
        const owed = BigInt(c.usdcAmount);
        const deposited = BigInt(c.season.usdcDeposited);
        const totalOwed = BigInt(c.season.usdcOwed);
        if (owed === 0n || totalOwed === 0n) return acc;
        const entitled = (owed * deposited) / totalOwed;
        const claimed = BigInt(c.usdcClaimed);
        return acc + (entitled > claimed ? entitled - claimed : 0n);
      }, 0n);

      return {
        totalPurchasedUSD: purchased,
        totalStaked: staked,
        totalYieldClaimed: yieldClaimed,
        totalUsdcClaimable: usdcClaimable,
      };
    }, [portfolio]);

  const stats = [
    {
      label: t("summary.invested"),
      value: `$${Number(formatUnits(totalPurchasedUSD, 18)).toLocaleString(undefined, { maximumFractionDigits: 2 })}`,
    },
    {
      label: t("summary.staked"),
      value: `${Number(formatUnits(totalStaked, 18)).toLocaleString(undefined, { maximumFractionDigits: 2 })} $CAMP`,
    },
    {
      label: t("summary.yieldClaimed"),
      value: `${Number(formatUnits(totalYieldClaimed, 18)).toLocaleString(undefined, { maximumFractionDigits: 2 })} $YIELD`,
      color: "text-primary",
    },
    {
      label: t("summary.usdcClaimable"),
      value: `$${Number(formatUnits(totalUsdcClaimable, 18)).toFixed(2)}`,
      color: "text-primary",
    },
  ];

  return (
    <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-5 md:p-8 mb-10 md:mb-12 grid grid-cols-2 md:grid-cols-4 gap-5 md:gap-8">
      {stats.map((s) => (
        <div key={s.label} className="min-w-0">
          <div className="text-[11px] md:text-xs font-semibold uppercase tracking-wider text-on-surface-variant mb-2 leading-tight">
            {s.label}
          </div>
          <div className={`text-xl md:text-2xl font-bold break-words ${s.color ?? "text-on-surface"}`}>
            {s.value}
          </div>
        </div>
      ))}
    </div>
  );
}

function PositionCard({
  position,
}: {
  position: UserPortfolio["positions"][number];
}) {
  const t = useTranslations("portfolio");
  const { address: user } = useAccount();

  const { data: metadata } = useCampaignMetadata(
    position.campaign.metadataURI,
    position.campaign.metadataVersion,
  );

  // Read current earned + campaignToken balance for quick totals
  const { data: reads } = useReadContracts({
    contracts: user
      ? [
          {
            address: position.campaign.stakingVault as Address,
            abi: [
              {
                type: "function",
                name: "earned",
                stateMutability: "view",
                inputs: [{ type: "uint256" }],
                outputs: [{ type: "uint256" }],
              },
            ] as const,
            functionName: "earned",
            args: [BigInt(position.positionId)],
          },
          {
            address: position.campaign.campaignToken as Address,
            abi: erc20Abi,
            functionName: "balanceOf",
            args: [user],
          },
        ]
      : [],
    query: { enabled: !!user, refetchInterval: 15_000 },
  });

  const earned = (reads?.[0]?.result as bigint) ?? 0n;
  const heldTokens = (reads?.[1]?.result as bigint) ?? 0n;

  return (
    <Link
      href={`/campaign/${position.campaign.id}`}
      className="block bg-surface-container-lowest rounded-2xl border border-outline-variant/15 overflow-hidden hover:-translate-y-1 transition-transform"
    >
      {metadata?.image && (
        <div className="h-32 bg-surface-container-low overflow-hidden">
          <img
            src={metadata.image}
            alt={metadata.name ?? ""}
            className="w-full h-full object-cover"
          />
        </div>
      )}
      <div className="p-5">
        <h3 className="font-semibold text-on-surface mb-3 truncate">
          {metadata?.name ??
            `Campaign ${position.campaign.id.slice(0, 6)}…${position.campaign.id.slice(-4)}`}
        </h3>
        <div className="grid grid-cols-2 gap-3 text-sm">
          <div>
            <div className="text-xs text-on-surface-variant">
              {t("pos.position")}
            </div>
            <div className="font-semibold text-on-surface">
              #{position.positionId}
            </div>
          </div>
          <div>
            <div className="text-xs text-on-surface-variant">
              {t("pos.staked")}
            </div>
            <div className="font-semibold text-on-surface">
              {Number(formatUnits(BigInt(position.amount), 18)).toLocaleString(
                undefined,
                { maximumFractionDigits: 2 },
              )}
            </div>
          </div>
          <div>
            <div className="text-xs text-on-surface-variant">
              {t("pos.earnedNow")}
            </div>
            <div className="font-semibold text-primary">
              {Number(formatUnits(earned, 18)).toFixed(4)} $YIELD
            </div>
          </div>
          <div>
            <div className="text-xs text-on-surface-variant">
              {t("pos.heldOutside")}
            </div>
            <div className="font-semibold text-on-surface">
              {Number(formatUnits(heldTokens, 18)).toLocaleString(undefined, {
                maximumFractionDigits: 2,
              })}
            </div>
          </div>
        </div>
      </div>
    </Link>
  );
}

function ClaimCard({ claim }: { claim: UserPortfolio["claims"][number] }) {
  const t = useTranslations("portfolio");

  const owed = BigInt(claim.usdcAmount);
  const deposited = BigInt(claim.season.usdcDeposited);
  const totalOwed = BigInt(claim.season.usdcOwed);
  const entitled =
    totalOwed > 0n && deposited > 0n ? (owed * deposited) / totalOwed : 0n;
  const claimed = BigInt(claim.usdcClaimed);
  const claimable = entitled > claimed ? entitled - claimed : 0n;

  // Same 4-phase state machine as HarvestPanel's UsdcClaimTimeline, with
  // the 1 USDC-wei dust tolerance for the 6↔18 decimal rounding.
  const DUST_18 = 10n ** 12n;
  const fulfilled = owed > 0n && claimed + DUST_18 >= owed;
  const fullyDeposited = totalOwed > 0n && deposited >= totalOwed;
  const phase: 1 | 2 | 3 | 4 = fulfilled
    ? 4
    : claimable > 0n || fullyDeposited
      ? 3
      : 2;
  const depositPct =
    totalOwed > 0n ? Number((deposited * 100n) / totalOwed) : 0;

  const isProduct = claim.redemptionType === "product";

  return (
    <Link
      href={`/campaign/${claim.campaign.id}`}
      className="block bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-5 hover:-translate-y-1 transition-transform"
    >
      <div className="flex justify-between items-start mb-3">
        <div>
          <div className="text-xs uppercase tracking-wider text-on-surface-variant">
            {t("claim.season", { id: claim.season.seasonId })}
          </div>
          <div className="font-mono text-xs text-on-surface mt-0.5">
            {claim.campaign.id.slice(0, 8)}…{claim.campaign.id.slice(-4)}
          </div>
        </div>
        {isProduct ? (
          <span className="px-3 py-1 rounded-full text-[11px] font-semibold uppercase tracking-wider bg-secondary-container text-white">
            {t("claim.productBadge")}
          </span>
        ) : (
          <ClaimStatusBadge phase={phase} />
        )}
      </div>

      {isProduct ? (
        <div className="pt-3 border-t border-outline-variant/15">
          <div className="text-xs text-on-surface-variant">
            {t("claim.productAmount")}
          </div>
          <div className="font-semibold text-primary text-lg">
            {Number(
              formatUnits(BigInt(claim.productAmount), 18),
            ).toLocaleString(undefined, { maximumFractionDigits: 2 })}{" "}
            {t("claim.units")}
          </div>
        </div>
      ) : (
        <div className="pt-3 border-t border-outline-variant/15 space-y-3">
          <div className="flex justify-between items-end">
            <div>
              <div className="text-[11px] text-on-surface-variant uppercase tracking-wider">
                {fulfilled
                  ? t("claim.fulfilledLabel")
                  : t("claim.yourEntitlement")}
              </div>
              <div className="text-xl font-bold text-on-surface">
                ${Number(formatUnits(owed, 18)).toFixed(2)}
              </div>
              <div className="text-[11px] text-on-surface-variant">
                {t("claim.receivedSoFar", {
                  amount: Number(formatUnits(claimed, 18)).toFixed(2),
                })}
              </div>
            </div>
            {!fulfilled && claimable > 0n && (
              <div className="text-right">
                <div className="text-[11px] text-on-surface-variant uppercase tracking-wider">
                  {t("claim.claimable")}
                </div>
                <div className="text-lg font-bold text-primary">
                  ${Number(formatUnits(claimable, 18)).toFixed(2)}
                </div>
              </div>
            )}
          </div>

          {!fulfilled && (
            <div>
              <div className="flex justify-between items-center text-[10px] text-on-surface-variant mb-1">
                <span className="uppercase tracking-wider">
                  {t("claim.producerDeposit")}
                </span>
                <span>
                  ${Number(formatUnits(deposited, 18)).toFixed(0)} / $
                  {Number(formatUnits(totalOwed, 18)).toFixed(0)}
                </span>
              </div>
              <div className="w-full h-1 bg-surface-container-high rounded-full overflow-hidden">
                <div
                  className="h-full bg-primary rounded-full transition-all duration-700"
                  style={{ width: `${Math.min(depositPct, 100)}%` }}
                />
              </div>
            </div>
          )}
        </div>
      )}
    </Link>
  );
}

function ClaimStatusBadge({ phase }: { phase: 1 | 2 | 3 | 4 }) {
  const t = useTranslations("portfolio.claim.status");
  const map: Record<1 | 2 | 3 | 4, { label: string; cls: string }> = {
    1: { label: t("committed"), cls: "bg-amber-100 text-amber-900" },
    2: { label: t("awaiting"), cls: "bg-amber-100 text-amber-900" },
    3: { label: t("claimable"), cls: "bg-primary text-white" },
    4: {
      label: t("fulfilled"),
      cls: "bg-primary-fixed text-on-primary-fixed-variant",
    },
  };
  const { label, cls } = map[phase];
  return (
    <span
      className={`px-3 py-1 rounded-full text-[11px] font-semibold uppercase tracking-wider ${cls}`}
    >
      {label}
    </span>
  );
}
