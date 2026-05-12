"use client";

import Link from "next/link";
import { useMemo } from "react";
import { useTranslations } from "next-intl";
import { formatUnits } from "viem";
import {
  useFeed,
  useLeaderboard,
  useBatchProducerProfiles,
  type FeedItem,
  type LeaderboardEntry,
  type BatchProducerProfile,
} from "@/lib/subgraph";
import { useBatchEnsNames } from "@/lib/ens";
import { useCampaignMetadata } from "@/lib/metadata";
import { KycBadge } from "@/components/KycBadge";
import { RefreshButton } from "@/components/RefreshButton";
import { KNOWN_TOKENS } from "@/contracts/tokens";
import { getAddresses } from "@/contracts";
import { txUrl } from "@/lib/explorer";

const FEED_LIMIT = 60;
const LEADERBOARD_LIMIT = 20;

// ---- payment-token decimals + symbol lookup (raw paymentAmount on Purchase
//      is stored in payment-token decimals, not USD-18, so we resolve via the
//      KNOWN_TOKENS catalog by address).
const TOKEN_BY_ADDRESS: Map<string, { symbol: string; decimals: number }> =
  (() => {
    const m = new Map<string, { symbol: string; decimals: number }>();
    for (const t of KNOWN_TOKENS) {
      for (const addr of Object.values(t.addresses)) {
        if (addr) m.set(addr.toLowerCase(), { symbol: t.symbol, decimals: t.decimals });
      }
    }
    return m;
  })();

function paymentTokenInfo(token: string): { symbol: string; decimals: number } {
  return (
    TOKEN_BY_ADDRESS.get(token.toLowerCase()) ?? { symbol: "?", decimals: 18 }
  );
}

// ---- protocol address overrides for display (Treasury / Minter / etc).
//      When the actor of an event is a protocol contract, we want to label
//      it as such instead of resolving against the profile/ENS pipeline that
//      would otherwise return "Anon grower".
function useProtocolLabels(): Map<string, { label: string; emoji: string }> {
  return useMemo(() => {
    const a = getAddresses();
    const m = new Map<string, { label: string; emoji: string }>();
    if (a.growTreasury)
      m.set(a.growTreasury.toLowerCase(), { label: "GROW Treasury", emoji: "🏦" });
    if (a.growMinter)
      m.set(a.growMinter.toLowerCase(), { label: "GROW Minter", emoji: "⚙️" });
    if (a.growFeeSplitter)
      m.set(a.growFeeSplitter.toLowerCase(), {
        label: "Fee Splitter",
        emoji: "🔀",
      });
    if (a.growStakingPool)
      m.set(a.growStakingPool.toLowerCase(), {
        label: "Staking Pool",
        emoji: "🪴",
      });
    return m;
  }, []);
}

export default function FeedPage() {
  const t = useTranslations("feed");
  const { data: feed, isLoading: feedLoading, refetch: refetchFeed } = useFeed(FEED_LIMIT);
  const {
    data: leaderboard,
    isLoading: lbLoading,
    refetch: refetchLb,
  } = useLeaderboard(LEADERBOARD_LIMIT);

  const addresses = useMemo(() => {
    const set = new Set<string>();
    (feed ?? []).forEach((f) => set.add(f.user.toLowerCase()));
    (leaderboard ?? []).forEach((l) => set.add(l.id.toLowerCase()));
    return Array.from(set);
  }, [feed, leaderboard]);

  const { data: profiles } = useBatchProducerProfiles(addresses);
  const { data: ensNames } = useBatchEnsNames(addresses);
  const protocolLabels = useProtocolLabels();

  function refetchAll() {
    void refetchFeed();
    void refetchLb();
  }

  return (
    <div className="max-w-7xl mx-auto px-4 md:px-8 pt-28 pb-20">
      <div className="flex items-start justify-between gap-4 mb-2">
        <h1 className="text-3xl md:text-4xl font-bold tracking-tight text-on-surface">
          {t("title")}
        </h1>
        <RefreshButton
          onClick={refetchAll}
          label={t("refresh")}
          className="mt-2 shrink-0"
        />
      </div>
      <p className="text-on-surface-variant mb-10 text-sm md:text-base">
        {t("subtitle")}
      </p>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        {/* Activity feed — 2/3 width on desktop */}
        <section className="lg:col-span-2">
          <h2 className="text-sm font-bold text-on-surface uppercase tracking-wider mb-4">
            {t("activity.title")}
          </h2>
          {feedLoading ? (
            <FeedSkeleton />
          ) : !feed || feed.length === 0 ? (
            <EmptyState text={t("activity.empty")} />
          ) : (
            <ol className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 divide-y divide-outline-variant/10 overflow-hidden">
              {feed.map((item) => (
                <FeedRow
                  key={item.id}
                  item={item}
                  profile={profiles?.get(item.user.toLowerCase())}
                  ens={ensNames?.get(item.user.toLowerCase()) ?? null}
                  protocolLabel={protocolLabels.get(item.user.toLowerCase())}
                />
              ))}
            </ol>
          )}
        </section>

        {/* Leaderboard — 1/3 width on desktop, sticky on lg+ */}
        <aside className="lg:col-span-1">
          <div className="lg:sticky lg:top-24">
            <h2 className="text-sm font-bold text-on-surface uppercase tracking-wider mb-4">
              {t("leaderboard.title")}
            </h2>
            {lbLoading ? (
              <LeaderboardSkeleton />
            ) : !leaderboard || leaderboard.length === 0 ? (
              <EmptyState text={t("leaderboard.empty")} />
            ) : (
              <ol className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-4 space-y-1">
                {leaderboard.map((entry, i) => (
                  <LeaderboardRow
                    key={entry.id}
                    rank={i + 1}
                    entry={entry}
                    profile={profiles?.get(entry.id.toLowerCase())}
                    ens={ensNames?.get(entry.id.toLowerCase()) ?? null}
                    protocolLabel={protocolLabels.get(entry.id.toLowerCase())}
                  />
                ))}
              </ol>
            )}
          </div>
        </aside>
      </div>
    </div>
  );
}

// ----------------------------------------------------------------------------

function FeedRow({
  item,
  profile,
  ens,
  protocolLabel,
}: {
  item: FeedItem;
  profile: BatchProducerProfile | undefined;
  ens: string | null;
  protocolLabel: { label: string; emoji: string } | undefined;
}) {
  const t = useTranslations("feed");
  const tProducer = useTranslations("grower");
  const { data: meta } = useCampaignMetadata(
    item.campaign.metadataURI,
    item.campaign.metadataVersion,
  );

  const displayName =
    protocolLabel?.label || profile?.name || ens || tProducer("anonymous");
  const campaignName = meta?.name ?? shortAddr(item.campaign.id);
  const when = relativeTime(item.timestamp, t);

  const description = renderDescription(item, t);
  const isProtocol = !!protocolLabel;

  // Tx hash on all event kinds. Older entities indexed before subgraph 3.4.0
  // return null and we just hide the link.
  const txHash = item.txHash;

  return (
    <li className="flex items-center gap-3 px-4 md:px-5 py-3 hover:bg-surface-container-low transition-colors">
      <ActionIcon kind={item.kind} protocolEmoji={protocolLabel?.emoji} />
      <div className="flex-1 min-w-0">
        <div className="text-sm text-on-surface">
          {isProtocol ? (
            <span className="font-semibold inline-flex items-center gap-1">
              <span>{displayName}</span>
            </span>
          ) : (
            <Link
              href={`/grower/${item.user}`}
              className="font-semibold hover:underline inline-flex items-center gap-1"
            >
              {profile?.avatar ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img
                  src={profile.avatar}
                  alt=""
                  className="w-4 h-4 rounded-full object-cover inline-block align-text-bottom"
                />
              ) : null}
              <span className="truncate">{displayName}</span>
              <KycBadge kyced={profile?.kyced} size={11} />
            </Link>
          )}{" "}
          {description.verb}{" "}
          <span className="font-semibold">{description.amount}</span>
          {description.preposition && (
            <>
              {" "}
              {description.preposition}{" "}
              <Link
                href={`/campaign/${item.campaign.id}`}
                className="font-semibold text-primary hover:underline"
              >
                {campaignName}
              </Link>
            </>
          )}
        </div>
        <div className="text-[11px] text-on-surface-variant mt-0.5 flex items-center gap-2">
          <span>{when}</span>
          {txHash && (
            <>
              <span aria-hidden="true">·</span>
              <a
                href={txUrl(txHash)}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 hover:text-on-surface transition-colors"
                title={txHash}
              >
                <span className="font-mono">{shortHash(txHash)}</span>
                <svg
                  width="10"
                  height="10"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2.4"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  aria-hidden="true"
                >
                  <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
                  <polyline points="15 3 21 3 21 9" />
                  <line x1="10" y1="14" x2="21" y2="3" />
                </svg>
              </a>
            </>
          )}
        </div>
      </div>
    </li>
  );
}

function renderDescription(
  item: FeedItem,
  t: ReturnType<typeof useTranslations>,
): { verb: string; amount: string; preposition: string | null } {
  switch (item.kind) {
    case "buy": {
      const tok = paymentTokenInfo(
        // `paymentToken` was added to FeedItem.buy in this change.
        (item as Extract<FeedItem, { kind: "buy" }>).paymentToken,
      );
      return {
        verb: t("activity.verbs.bought"),
        amount: `${formatRaw(item.paymentAmount, tok.decimals)} ${tok.symbol}`,
        preposition: t("activity.prepositions.in"),
      };
    }
    case "sellback":
      return {
        verb: t("activity.verbs.sellback"),
        amount: formatTokens18(item.amount),
        preposition: t("activity.prepositions.from"),
      };
    case "stake":
      return {
        verb: t("activity.verbs.staked"),
        amount: formatTokens18(item.amount),
        preposition: t("activity.prepositions.in"),
      };
    case "unstake":
      return {
        verb: t("activity.verbs.unstaked"),
        amount: formatTokens18(item.amount),
        preposition: t("activity.prepositions.from"),
      };
    case "claim":
      if (item.redemptionType === "product") {
        return {
          verb: t("activity.verbs.redeemedProduct"),
          amount: formatTokens18(item.productAmount),
          preposition: t("activity.prepositions.from"),
        };
      }
      return {
        verb: t("activity.verbs.redeemedUsdc"),
        amount: formatUsd18(item.usdcAmount),
        preposition: t("activity.prepositions.from"),
      };
    case "campaign":
      return {
        verb: t("activity.verbs.launched"),
        amount: "",
        preposition: null,
      };
  }
}

function ActionIcon({
  kind,
  protocolEmoji,
}: {
  kind: FeedItem["kind"];
  protocolEmoji?: string;
}) {
  const map: Record<FeedItem["kind"], { bg: string; emoji: string }> = {
    buy: { bg: "bg-emerald-50 text-emerald-700", emoji: "🌱" },
    sellback: { bg: "bg-amber-50 text-amber-700", emoji: "↩️" },
    stake: { bg: "bg-sky-50 text-sky-700", emoji: "🪴" },
    unstake: { bg: "bg-zinc-50 text-zinc-700", emoji: "🏃" },
    claim: { bg: "bg-orange-50 text-orange-700", emoji: "🌾" },
    campaign: { bg: "bg-primary-fixed text-on-primary-fixed-variant", emoji: "🌳" },
  };
  const cfg = map[kind];
  return (
    <div
      className={`w-9 h-9 rounded-full flex items-center justify-center text-base shrink-0 ${cfg.bg}`}
      aria-hidden="true"
    >
      {protocolEmoji ?? cfg.emoji}
    </div>
  );
}

// ----------------------------------------------------------------------------

function LeaderboardRow({
  rank,
  entry,
  profile,
  ens,
  protocolLabel,
}: {
  rank: number;
  entry: LeaderboardEntry;
  profile: BatchProducerProfile | undefined;
  ens: string | null;
  protocolLabel: { label: string; emoji: string } | undefined;
}) {
  const tProducer = useTranslations("grower");
  const displayName =
    protocolLabel?.label || profile?.name || ens || tProducer("anonymous");
  const medal =
    rank === 1 ? "🥇" : rank === 2 ? "🥈" : rank === 3 ? "🥉" : null;
  const isProtocol = !!protocolLabel;

  const RowInner = (
    <>
      <div className="w-6 shrink-0 text-center text-xs font-mono text-on-surface-variant">
        {medal ?? `#${rank}`}
      </div>
      {isProtocol ? (
        <div className="w-8 h-8 rounded-full bg-emerald-50 text-emerald-700 flex items-center justify-center text-base shrink-0">
          {protocolLabel!.emoji}
        </div>
      ) : profile?.avatar ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={profile.avatar}
          alt={displayName}
          className="w-8 h-8 rounded-full object-cover border border-outline-variant/15 shrink-0"
        />
      ) : (
        <div className="w-8 h-8 rounded-full bg-primary-fixed text-on-primary-fixed-variant flex items-center justify-center text-[10px] font-bold shrink-0">
          {entry.id.slice(2, 4).toUpperCase()}
        </div>
      )}
      <div className="flex-1 min-w-0">
        <div className="text-sm font-semibold text-on-surface truncate flex items-center gap-1">
          <span className="truncate">{displayName}</span>
          {!isProtocol && <KycBadge kyced={profile?.kyced} size={11} />}
        </div>
        <div className="text-[11px] text-on-surface-variant">
          {entry.purchasesCount}× buy
        </div>
      </div>
      <div className="text-sm font-bold text-on-surface whitespace-nowrap shrink-0">
        {formatUsd18(entry.totalInvested)}
      </div>
    </>
  );

  return (
    <li>
      {isProtocol ? (
        <div className="flex items-center gap-3 py-2 px-2 -mx-2 rounded-lg">
          {RowInner}
        </div>
      ) : (
        <Link
          href={`/grower/${entry.id}`}
          className="flex items-center gap-3 py-2 px-2 -mx-2 rounded-lg hover:bg-surface-container-low transition-colors"
        >
          {RowInner}
        </Link>
      )}
    </li>
  );
}

// ----------------------------------------------------------------------------

function EmptyState({ text }: { text: string }) {
  return (
    <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-8 text-center text-sm text-on-surface-variant">
      {text}
    </div>
  );
}

function FeedSkeleton() {
  return (
    <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 divide-y divide-outline-variant/10">
      {[0, 1, 2, 3, 4].map((i) => (
        <div key={i} className="flex items-center gap-3 px-5 py-3">
          <div className="w-9 h-9 rounded-full bg-surface-container-high animate-pulse" />
          <div className="flex-1 space-y-1.5">
            <div className="h-3 w-3/4 rounded bg-surface-container-high animate-pulse" />
            <div className="h-2.5 w-1/4 rounded bg-surface-container-high animate-pulse" />
          </div>
        </div>
      ))}
    </div>
  );
}

function LeaderboardSkeleton() {
  return (
    <div className="bg-surface-container-lowest rounded-2xl border border-outline-variant/15 p-4 space-y-2">
      {[0, 1, 2, 3, 4].map((i) => (
        <div key={i} className="flex items-center gap-3">
          <div className="w-6 h-3 bg-surface-container-high rounded animate-pulse" />
          <div className="w-8 h-8 bg-surface-container-high rounded-full animate-pulse" />
          <div className="flex-1 h-3 bg-surface-container-high rounded animate-pulse" />
          <div className="h-3 w-12 bg-surface-container-high rounded animate-pulse" />
        </div>
      ))}
    </div>
  );
}

// ----------------------------------------------------------------------------
// Formatting helpers

function formatUsd18(amt: string): string {
  const v = Number(formatUnits(BigInt(amt), 18));
  if (v === 0) return "$0";
  if (v < 0.01) return "<$0.01";
  return `$${v.toLocaleString(undefined, { maximumFractionDigits: 2 })}`;
}

function formatRaw(amt: string, decimals: number): string {
  const v = Number(formatUnits(BigInt(amt), decimals));
  if (v === 0) return "0";
  if (v < 0.01) return "<0.01";
  return v.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

function formatTokens18(amt: string): string {
  const v = Number(formatUnits(BigInt(amt), 18));
  return v.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

function shortHash(h: string): string {
  return `${h.slice(0, 6)}…${h.slice(-4)}`;
}

function relativeTime(
  ts: number,
  t: ReturnType<typeof useTranslations>,
): string {
  const now = Math.floor(Date.now() / 1000);
  const diff = Math.max(0, now - ts);
  if (diff < 60) return t("relative.justNow");
  if (diff < 3600) return t("relative.minutesAgo", { n: Math.floor(diff / 60) });
  if (diff < 86400) return t("relative.hoursAgo", { n: Math.floor(diff / 3600) });
  if (diff < 7 * 86400)
    return t("relative.daysAgo", { n: Math.floor(diff / 86400) });
  return new Date(ts * 1000).toLocaleDateString();
}
