import { useQuery } from "@tanstack/react-query";

const SUBGRAPH_URL =
  process.env.NEXT_PUBLIC_SUBGRAPH_URL ||
  "https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/4.0.2/gn";

async function gql<T>(query: string, variables?: Record<string, unknown>): Promise<T> {
  const res = await fetch(SUBGRAPH_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`Subgraph HTTP ${res.status}`);
  const body = (await res.json()) as { data?: T; errors?: Array<{ message: string }> };
  if (body.errors?.length) {
    throw new Error(body.errors.map((e) => e.message).join(", "));
  }
  if (!body.data) throw new Error("Empty subgraph response");
  return body.data;
}

export interface SubgraphCampaign {
  id: string;
  producer: string;
  campaignToken: string;
  yieldToken: string;
  stakingVault: string;
  harvestManager: string;
  pricePerToken: string;
  minCap: string;
  maxCap: string;
  fundingDeadline: string;
  seasonDuration: string;
  minProductClaim: string;
  expectedAnnualHarvestUsd: string;
  expectedAnnualHarvest: string;
  firstHarvestYear: string;
  coverageHarvests: string;
  collateralLocked: string;
  collateralDrawn: string;
  currentSupply: string;
  totalStaked: string;
  totalRaised: string;
  treasuryRaised?: string;        // USD-18 raised via GROW Treasury auto-alloc (subgraph v3.x)
  treasuryTokensOut?: string;     // raw CT minted to the Treasury
  currentYieldRate: string;
  state: "Funding" | "Active" | "Buyback" | "Ended";
  paused: boolean;
  createdAt: string;
  createdAtBlock: string;
  activatedAt: string | null;
  metadataURI: string | null;
  metadataVersion: string;
  hidden: boolean;
  repaymentPool?: {
    initialized: boolean;
    bonusPerCt: string;
    poolBalance: string;
    totalFunded: string;
    totalWithdrawn: string;
    totalRedeemed: string;
    redeemCount: number;
    initializedAt: string | null;
    lastUpdatedAt: string;
  } | null;
}

const CAMPAIGN_FIELDS = `
  id
  producer
  campaignToken
  yieldToken
  stakingVault
  harvestManager
  pricePerToken
  minCap
  maxCap
  fundingDeadline
  seasonDuration
  minProductClaim
  expectedAnnualHarvestUsd
  expectedAnnualHarvest
  firstHarvestYear
  coverageHarvests
  collateralLocked
  collateralDrawn
  currentSupply
  totalStaked
  totalRaised
  treasuryRaised
  treasuryTokensOut
  currentYieldRate
  state
  paused
  createdAt
  createdAtBlock
  activatedAt
  metadataURI
  metadataVersion
  hidden
  repaymentPool {
    initialized
    bonusPerCt
    poolBalance
    totalFunded
    totalWithdrawn
    totalRedeemed
    redeemCount
    initializedAt
    lastUpdatedAt
  }
`;

/**
 * Public discovery list. By default excludes campaigns the factory owner has
 * flipped to hidden via `setCampaignHidden`. Admin surfaces pass
 * `{ includeHidden: true }` so the multisig can still see them to unhide.
 * EscrowClaimPanel also includes hidden so users with pending escrow on a
 * hidden campaign can still claim.
 */
export function useSubgraphCampaigns(opts: { includeHidden?: boolean } = {}) {
  const includeHidden = !!opts.includeHidden;
  return useQuery({
    queryKey: ["subgraph", "campaigns", includeHidden ? "all" : "visible"],
    queryFn: async () => {
      const whereClause = includeHidden ? "" : "where: { hidden: false }, ";
      const data = await gql<{ campaigns: SubgraphCampaign[] }>(`
        query Campaigns {
          campaigns(${whereClause}first: 100, orderBy: createdAt, orderDirection: desc) {
            ${CAMPAIGN_FIELDS}
          }
        }
      `);
      return data.campaigns;
    },
    refetchInterval: 15_000,
  });
}

export interface SubgraphGlobalStats {
  campaignCount: number;
  userCount: number;
  totalRaised: string;
  totalStakers: number;
}

export function useGlobalStats() {
  return useQuery({
    queryKey: ["subgraph", "globalStats"],
    queryFn: async () => {
      const data = await gql<{ globalStats: SubgraphGlobalStats | null }>(`
        query GlobalStats {
          globalStats(id: "0x676c6f62616c") {
            campaignCount
            userCount
            totalRaised
            totalStakers
          }
        }
      `);
      return data.globalStats;
    },
    refetchInterval: 30_000,
  });
}

export function useSubgraphCampaign(address: string | undefined) {
  return useQuery({
    queryKey: ["subgraph", "campaign", address?.toLowerCase()],
    enabled: !!address,
    queryFn: async () => {
      if (!address) return null;
      const data = await gql<{ campaign: SubgraphCampaign | null }>(
        `
        query Campaign($id: ID!) {
          campaign(id: $id) {
            ${CAMPAIGN_FIELDS}
          }
        }
        `,
        { id: address.toLowerCase() },
      );
      return data.campaign;
    },
    refetchInterval: 15_000,
  });
}

/**
 * Aggregated investor list for a campaign. Subgraph returns every Purchase
 * event, we fold them per-buyer client-side to surface a compact list
 * suitable for the /campaign/[address] invest tab.
 */
export interface CampaignInvestor {
  buyer: string;
  totalTokens: bigint;
  totalPayment: bigint;
  purchaseCount: number;
  firstPurchaseTs: number;
  lastPurchaseTs: number;
}

interface RawPurchase {
  buyer: string;
  paymentAmount: string;
  campaignTokensOut: string;
  timestamp: string;
}

export function useCampaignInvestors(address: string | undefined) {
  return useQuery({
    queryKey: ["subgraph", "investors", address?.toLowerCase()],
    enabled: !!address,
    queryFn: async (): Promise<CampaignInvestor[]> => {
      if (!address) return [];
      // Campaign entity field is stored as Bytes (hex); queries work against
      // the lowercase address.
      const data = await gql<{ purchases: RawPurchase[] }>(
        `
        query Investors($campaign: String!) {
          purchases(
            where: { campaign: $campaign }
            first: 1000
            orderBy: timestamp
            orderDirection: asc
          ) {
            buyer
            paymentAmount
            campaignTokensOut
            timestamp
          }
        }
        `,
        { campaign: address.toLowerCase() },
      );
      const byBuyer = new Map<string, CampaignInvestor>();
      for (const p of data.purchases) {
        const key = p.buyer.toLowerCase();
        const existing = byBuyer.get(key);
        const ts = Number(p.timestamp);
        if (existing) {
          existing.totalTokens += BigInt(p.campaignTokensOut);
          existing.totalPayment += BigInt(p.paymentAmount);
          existing.purchaseCount += 1;
          existing.lastPurchaseTs = Math.max(existing.lastPurchaseTs, ts);
        } else {
          byBuyer.set(key, {
            buyer: p.buyer,
            totalTokens: BigInt(p.campaignTokensOut),
            totalPayment: BigInt(p.paymentAmount),
            purchaseCount: 1,
            firstPurchaseTs: ts,
            lastPurchaseTs: ts,
          });
        }
      }
      return Array.from(byBuyer.values()).sort((a, b) =>
        a.totalTokens === b.totalTokens
          ? 0
          : b.totalTokens > a.totalTokens
            ? 1
            : -1,
      );
    },
    refetchInterval: 20_000,
  });
}

/**
 * Batch-resolve wallet → producer profile (name + avatar) in one round-trip.
 * Used by the InvestorList widget so each row can show the registered name
 * if the investor has ever published a profile via ProducerRegistry.
 * Falls back to a shortened address upstream when no profile exists.
 */
export interface BatchProducerProfile {
  id: string;
  profileURI: string;
  version: string;
  kyced: boolean;
  name?: string;
  avatar?: string;
}

export function useBatchProducerProfiles(
  addresses: string[] | undefined,
) {
  const keys = (addresses ?? [])
    .filter((a): a is string => !!a)
    .map((a) => a.toLowerCase())
    .sort();
  const cacheKey = keys.join(",");
  return useQuery({
    queryKey: ["subgraph", "producers-batch", cacheKey],
    enabled: keys.length > 0,
    queryFn: async (): Promise<Map<string, BatchProducerProfile>> => {
      const data = await gql<{ producers: Array<{
        id: string;
        profileURI: string;
        version: string;
        kyced: boolean;
      }> }>(
        `
        query BatchProducers($ids: [ID!]!) {
          producers(where: { id_in: $ids }) {
            id
            profileURI
            version
            kyced
          }
        }
        `,
        { ids: keys },
      );
      // Fetch the off-chain JSON for each row in parallel so we can show
      // name/avatar on the same render. Failures just drop that producer
      // to address-only fallback.
      const rows = await Promise.all(
        data.producers.map(async (p) => {
          if (!p.profileURI) return { ...p, name: undefined, avatar: undefined };
          try {
            const res = await fetch(p.profileURI, { cache: "force-cache" });
            if (!res.ok) return { ...p };
            const j = (await res.json()) as {
              name?: string;
              avatar?: string;
            };
            return { ...p, name: j.name, avatar: j.avatar };
          } catch {
            return { ...p };
          }
        }),
      );
      const map = new Map<string, BatchProducerProfile>();
      for (const r of rows) map.set(r.id.toLowerCase(), r);
      return map;
    },
    staleTime: 60_000,
  });
}

export interface SubgraphSeason {
  id: string;
  seasonId: string;
  startTime: string;
  endTime: string | null;
  active: boolean;
  reported: boolean;
  reportedAt: string | null;
  totalHarvestValueUSD: string | null;
  holderPool: string | null;
  totalYieldSupply: string | null;
  totalProductUnits: string | null;
  merkleRoot: string | null;
  claimStart: string | null;
  claimEnd: string | null;
  usdcDeadline: string | null;
  usdcDeposited: string;
  usdcOwed: string;
}

export function useCampaignSeasons(campaignId: string | undefined) {
  return useQuery({
    queryKey: ["subgraph", "seasons", campaignId?.toLowerCase()],
    enabled: !!campaignId,
    queryFn: async () => {
      if (!campaignId) return [];
      const data = await gql<{ seasons: SubgraphSeason[] }>(
        `
        query Seasons($campaign: String!) {
          seasons(
            where: { campaign: $campaign }
            orderBy: seasonId
            orderDirection: desc
            first: 50
          ) {
            id
            seasonId
            startTime
            endTime
            active
            reported
            reportedAt
            totalHarvestValueUSD
            holderPool
            totalYieldSupply
            totalProductUnits
            merkleRoot
            claimStart
            claimEnd
            usdcDeadline
            usdcDeposited
            usdcOwed
          }
        }
        `,
        { campaign: campaignId.toLowerCase() },
      );
      return data.seasons;
    },
    refetchInterval: 15_000,
  });
}

export interface UserPortfolio {
  purchases: Array<{
    id: string;
    campaign: { id: string; pricePerToken: string; state: string };
    paymentToken: string;
    paymentAmount: string;
    campaignTokensOut: string;
    timestamp: string;
  }>;
  positions: Array<{
    id: string;
    positionId: string;
    campaign: {
      id: string;
      stakingVault: string;
      campaignToken: string;
      yieldToken: string;
      pricePerToken: string;
      state: string;
      metadataURI: string | null;
      metadataVersion: string;
    };
    amount: string;
    startTime: string;
    seasonId: string;
    yieldClaimed: string;
    active: boolean;
  }>;
  claims: Array<{
    id: string;
    campaign: { id: string };
    season: { seasonId: string; usdcDeposited: string; usdcOwed: string };
    redemptionType: string;
    yieldBurned: string;
    productAmount: string;
    usdcAmount: string;
    usdcClaimed: string;
    fulfilled: boolean;
  }>;
}

export function useUserPortfolio(user: string | undefined) {
  return useQuery({
    queryKey: ["subgraph", "portfolio", user?.toLowerCase()],
    enabled: !!user,
    queryFn: async (): Promise<UserPortfolio> => {
      if (!user) return { purchases: [], positions: [], claims: [] };
      const addr = user.toLowerCase();
      const data = await gql<UserPortfolio>(
        `
        query UserPortfolio($user: Bytes!) {
          purchases(
            where: { buyer: $user }
            orderBy: timestamp
            orderDirection: desc
            first: 100
          ) {
            id
            campaign { id pricePerToken state }
            paymentToken
            paymentAmount
            campaignTokensOut
            timestamp
          }
          positions(
            where: { user: $user, active: true }
            orderBy: createdAt
            orderDirection: desc
            first: 100
          ) {
            id
            positionId
            campaign {
              id
              stakingVault
              campaignToken
              yieldToken
              pricePerToken
              state
              metadataURI
              metadataVersion
            }
            amount
            startTime
            seasonId
            yieldClaimed
            active
          }
          claims(
            where: { user: $user }
            orderBy: claimedAt
            orderDirection: desc
            first: 100
          ) {
            id
            campaign { id }
            season { seasonId usdcDeposited usdcOwed }
            redemptionType
            yieldBurned
            productAmount
            usdcAmount
            usdcClaimed
            fulfilled
          }
        }
        `,
        { user: addr },
      );
      return data;
    },
    refetchInterval: 20_000,
  });
}

export interface SubgraphProducer {
  id: string;
  profileURI: string | null;
  version: string;
  updatedAt: string | null;
  kyced: boolean;
  kycSetAt: string | null;
}

/**
 * Polls the subgraph every 3s for a producer until its `version` strictly
 * exceeds `sinceVersion`. If there was no previous profile at all, pass
 * undefined and any non-null response counts as "indexed".
 *
 * Used by the /producer edit form to keep the "saving" UI up until the
 * subgraph reflects the new profile — otherwise the form closes and the
 * page briefly shows stale data (or "anonymous producer") before the new
 * version arrives.
 */
export function useProducerIndexed(
  address: string | undefined,
  sinceVersion: string | undefined,
  enabled: boolean,
) {
  return useQuery({
    queryKey: [
      "subgraph",
      "producer-indexed",
      address?.toLowerCase(),
      sinceVersion ?? "none",
    ],
    enabled: !!address && enabled,
    refetchInterval: enabled ? 3000 : false,
    queryFn: async () => {
      if (!address) return null;
      const data = await gql<{ producer: { version: string } | null }>(
        `query Poll($id: ID!) { producer(id: $id) { version } }`,
        { id: address.toLowerCase() },
      );
      if (!data.producer) return null;
      const current = BigInt(data.producer.version);
      const since = sinceVersion ? BigInt(sinceVersion) : 0n;
      return current > since ? data.producer : null;
    },
  });
}

export function useSubgraphProducer(address: string | undefined) {
  return useQuery({
    queryKey: ["subgraph", "producer", address?.toLowerCase()],
    enabled: !!address,
    queryFn: async () => {
      if (!address) return null;
      const data = await gql<{ producer: SubgraphProducer | null }>(
        `
        query Producer($id: ID!) {
          producer(id: $id) {
            id
            profileURI
            version
            updatedAt
            kyced
            kycSetAt
          }
        }
        `,
        { id: address.toLowerCase() },
      );
      return data.producer;
    },
    refetchInterval: 20_000,
  });
}

/**
 * Aggregate read for the producer dashboard: every campaign they own + the
 * seasons under each, in one round-trip. Used to compute:
 *   - total USDC still owed to holders across all campaigns
 *   - seasons waiting for a harvest report
 *   - total raised / number of campaigns / active seasons
 */
export interface ProducerAggregate {
  campaigns: Array<{
    id: string;
    state: string;
    totalRaised: string;
    currentSupply: string;
    maxCap: string;
    seasons: Array<{
      seasonId: string;
      active: boolean;
      reported: boolean;
      usdcOwed: string;
      usdcDeposited: string;
      usdcDeadline: string | null;
      endTime: string | null;
    }>;
  }>;
}

export function useProducerAggregate(producerAddress: string | undefined) {
  return useQuery({
    queryKey: [
      "subgraph",
      "producer-aggregate",
      producerAddress?.toLowerCase(),
    ],
    enabled: !!producerAddress,
    queryFn: async (): Promise<ProducerAggregate> => {
      if (!producerAddress) return { campaigns: [] };
      const data = await gql<ProducerAggregate>(
        `
        query ProducerAggregate($producer: Bytes!) {
          campaigns(
            where: { producer: $producer }
            orderBy: createdAt
            orderDirection: desc
            first: 100
          ) {
            id
            state
            totalRaised
            currentSupply
            maxCap
            seasons(first: 50, orderBy: seasonId, orderDirection: desc) {
              seasonId
              active
              reported
              usdcOwed
              usdcDeposited
              usdcDeadline
              endTime
            }
          }
        }
        `,
        { producer: producerAddress.toLowerCase() },
      );
      return data;
    },
    refetchInterval: 30_000,
  });
}

export function useProducerCampaigns(producerAddress: string | undefined) {
  return useQuery({
    queryKey: ["subgraph", "producer-campaigns", producerAddress?.toLowerCase()],
    enabled: !!producerAddress,
    queryFn: async () => {
      if (!producerAddress) return [];
      const data = await gql<{ campaigns: SubgraphCampaign[] }>(
        `
        query ProducerCampaigns($producer: Bytes!) {
          campaigns(
            where: { producer: $producer, hidden: false }
            orderBy: createdAt
            orderDirection: desc
            first: 100
          ) {
            ${CAMPAIGN_FIELDS}
          }
        }
        `,
        { producer: producerAddress.toLowerCase() },
      );
      return data.campaigns;
    },
    refetchInterval: 20_000,
  });
}

export interface SubgraphMeta {
  block: { number: number; hash: string };
  hasIndexingErrors: boolean;
}

export function useSubgraphMeta() {
  return useQuery({
    queryKey: ["subgraph", "meta"],
    queryFn: async () =>
      (await gql<{ _meta: SubgraphMeta }>("{ _meta { block { number hash } hasIndexingErrors } }"))._meta,
    refetchInterval: 30_000,
  });
}

/**
 * Imperative pre-deploy guard for /create. Returns the address of an
 * existing campaign whose off-chain metadata.name (case-insensitive,
 * whitespace-trimmed) matches the candidate, or `null` if the slot is
 * free. Walks every campaign with a metadataURI; off-chain JSON fetches
 * run in parallel. Designed to be cheap on the demo (1–10 campaigns)
 * without requiring a subgraph schema change to index `tokenName`.
 *
 * Note: campaigns without metadataURI (LinkMetadataBanner state) are
 * ignored — there's no name to compare against. They'll claim their
 * name once the producer signs setMetadata; a same-name attempt during
 * that window will succeed, but that's a vanishingly small race.
 */
// -----------------------------------------------------------------------
// Public activity feed + leaderboard
//
// `useFeed` batches the 5 user-facing event streams (Purchase, Position,
// Claim, SellBackOrder, Campaign created) in one GraphQL round-trip,
// normalizes them into a discriminated union sorted by timestamp desc.
// `useLeaderboard` reads the pre-aggregated `User` entity from the
// subgraph (totalInvested + purchasesCount) ordered by spend.
// -----------------------------------------------------------------------

type CampaignRef = { id: string; metadataURI: string | null; metadataVersion: string };

export type FeedItem =
  | {
      kind: "buy";
      id: string;
      timestamp: number;
      user: string;
      campaign: CampaignRef;
      paymentAmount: string;
      paymentToken: string;
      campaignTokensOut: string;
      txHash: string | null;
    }
  | {
      kind: "sellback";
      id: string;
      timestamp: number;
      user: string;
      campaign: CampaignRef;
      amount: string;
      status: string;
      txHash: string | null;
    }
  | {
      kind: "stake";
      id: string;
      timestamp: number;
      user: string;
      campaign: CampaignRef;
      amount: string;
      txHash: string | null;
    }
  | {
      kind: "unstake";
      id: string;
      timestamp: number;
      user: string;
      campaign: CampaignRef;
      amount: string;
      penaltyBurned: string | null;
      txHash: string | null;
    }
  | {
      kind: "claim";
      id: string;
      timestamp: number;
      user: string;
      campaign: CampaignRef;
      redemptionType: string;
      yieldBurned: string;
      productAmount: string;
      usdcAmount: string;
      txHash: string | null;
    }
  | {
      kind: "campaign";
      id: string;
      timestamp: number;
      user: string;
      campaign: CampaignRef;
      txHash: string | null;
    };

const FEED_CAMPAIGN_FIELDS = "id metadataURI metadataVersion";

export function useFeed(limit = 50) {
  return useQuery({
    queryKey: ["subgraph", "feed", limit],
    queryFn: async (): Promise<FeedItem[]> => {
      const data = await gql<{
        purchases: Array<{
          id: string;
          buyer: string;
          paymentAmount: string;
          paymentToken: string;
          campaignTokensOut: string;
          timestamp: string;
          transactionHash: string;
          campaign: { id: string; metadataURI: string | null; metadataVersion: string };
        }>;
        sellBackOrders: Array<{
          id: string;
          user: string;
          amount: string;
          status: string;
          requestedAt: string;
          requestTx: string | null;
          campaign: { id: string; metadataURI: string | null; metadataVersion: string };
        }>;
        stakes: Array<{
          id: string;
          user: string;
          amount: string;
          createdAt: string;
          createdAtTx: string | null;
          unstakedAt: string | null;
          penaltyBurned: string | null;
          campaign: { id: string; metadataURI: string | null; metadataVersion: string };
        }>;
        unstakes: Array<{
          id: string;
          user: string;
          amount: string;
          unstakedAt: string;
          unstakedAtTx: string | null;
          penaltyBurned: string | null;
          campaign: { id: string; metadataURI: string | null; metadataVersion: string };
        }>;
        claims: Array<{
          id: string;
          user: string;
          redemptionType: string;
          yieldBurned: string;
          productAmount: string;
          usdcAmount: string;
          claimedAt: string;
          claimTx: string | null;
          campaign: { id: string; metadataURI: string | null; metadataVersion: string };
        }>;
        campaigns: Array<{
          id: string;
          producer: string;
          createdAt: string;
          createdAtTx: string | null;
          metadataURI: string | null;
          metadataVersion: string;
        }>;
      }>(
        `query Feed($limit: Int!) {
          purchases(first: $limit, orderBy: timestamp, orderDirection: desc) {
            id buyer paymentAmount paymentToken campaignTokensOut timestamp transactionHash
            campaign { ${FEED_CAMPAIGN_FIELDS} }
          }
          sellBackOrders(first: $limit, orderBy: requestedAt, orderDirection: desc) {
            id user amount status requestedAt requestTx
            campaign { ${FEED_CAMPAIGN_FIELDS} }
          }
          stakes: positions(first: $limit, orderBy: createdAt, orderDirection: desc) {
            id user amount createdAt createdAtTx unstakedAt penaltyBurned
            campaign { ${FEED_CAMPAIGN_FIELDS} }
          }
          unstakes: positions(first: $limit, where: { active: false, unstakedAt_not: null }, orderBy: unstakedAt, orderDirection: desc) {
            id user amount unstakedAt unstakedAtTx penaltyBurned
            campaign { ${FEED_CAMPAIGN_FIELDS} }
          }
          claims(first: $limit, orderBy: claimedAt, orderDirection: desc) {
            id user redemptionType yieldBurned productAmount usdcAmount claimedAt claimTx
            campaign { ${FEED_CAMPAIGN_FIELDS} }
          }
          campaigns(first: $limit, where: { hidden: false }, orderBy: createdAt, orderDirection: desc) {
            id producer createdAt createdAtTx metadataURI metadataVersion
          }
        }`,
        { limit },
      );

      const items: FeedItem[] = [];

      for (const p of data.purchases) {
        items.push({
          kind: "buy",
          id: `buy-${p.id}`,
          timestamp: Number(p.timestamp),
          user: p.buyer,
          campaign: p.campaign,
          paymentAmount: p.paymentAmount,
          paymentToken: p.paymentToken,
          campaignTokensOut: p.campaignTokensOut,
          txHash: p.transactionHash,
        });
      }
      for (const s of data.sellBackOrders) {
        items.push({
          kind: "sellback",
          id: `sellback-${s.id}`,
          timestamp: Number(s.requestedAt),
          user: s.user,
          campaign: s.campaign,
          amount: s.amount,
          status: s.status,
          txHash: s.requestTx,
        });
      }
      for (const p of data.stakes) {
        items.push({
          kind: "stake",
          id: `stake-${p.id}`,
          timestamp: Number(p.createdAt),
          user: p.user,
          campaign: p.campaign,
          amount: p.amount,
          txHash: p.createdAtTx,
        });
      }
      for (const p of data.unstakes) {
        items.push({
          kind: "unstake",
          id: `unstake-${p.id}`,
          timestamp: Number(p.unstakedAt),
          user: p.user,
          campaign: p.campaign,
          amount: p.amount,
          penaltyBurned: p.penaltyBurned,
          txHash: p.unstakedAtTx,
        });
      }
      for (const c of data.claims) {
        items.push({
          kind: "claim",
          id: `claim-${c.id}`,
          timestamp: Number(c.claimedAt),
          user: c.user,
          campaign: c.campaign,
          redemptionType: c.redemptionType,
          yieldBurned: c.yieldBurned,
          productAmount: c.productAmount,
          usdcAmount: c.usdcAmount,
          txHash: c.claimTx,
        });
      }
      for (const c of data.campaigns) {
        items.push({
          kind: "campaign",
          id: `campaign-${c.id}`,
          timestamp: Number(c.createdAt),
          user: c.producer,
          campaign: {
            id: c.id,
            metadataURI: c.metadataURI,
            metadataVersion: c.metadataVersion,
          },
          txHash: c.createdAtTx,
        });
      }

      items.sort((a, b) => b.timestamp - a.timestamp);
      return items.slice(0, limit);
    },
    refetchInterval: 30_000,
  });
}

export interface LeaderboardEntry {
  id: string;                // wallet address
  totalInvested: string;     // USD-18 sum across all buys
  purchasesCount: number;
  firstSeenAt: string;
}

export function useLeaderboard(limit = 20) {
  return useQuery({
    queryKey: ["subgraph", "leaderboard", limit],
    queryFn: async (): Promise<LeaderboardEntry[]> => {
      const data = await gql<{ users: LeaderboardEntry[] }>(
        `query Leaderboard($limit: Int!) {
          users(first: $limit, orderBy: totalInvested, orderDirection: desc, where: { totalInvested_gt: 0 }) {
            id
            totalInvested
            purchasesCount
            firstSeenAt
          }
        }`,
        { limit },
      );
      return data.users;
    },
    refetchInterval: 30_000,
  });
}

export async function findCampaignByName(
  candidate: string,
): Promise<string | null> {
  const target = candidate.trim().toLowerCase();
  if (!target) return null;
  const data = await gql<{
    campaigns: Array<{ id: string; metadataURI: string | null }>;
  }>("{ campaigns { id metadataURI } }");
  const withMeta = data.campaigns.filter((c) => !!c.metadataURI);
  const matches = await Promise.all(
    withMeta.map(async (c) => {
      try {
        const res = await fetch(c.metadataURI!, { cache: "no-store" });
        if (!res.ok) return null;
        const j = (await res.json()) as { name?: string };
        const name = (j.name ?? "").trim().toLowerCase();
        return name === target ? c.id : null;
      } catch {
        return null;
      }
    }),
  );
  return matches.find((m) => m !== null) ?? null;
}
