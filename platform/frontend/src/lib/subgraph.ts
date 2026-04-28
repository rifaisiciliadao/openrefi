import { useQuery } from "@tanstack/react-query";

const SUBGRAPH_URL =
  process.env.NEXT_PUBLIC_SUBGRAPH_URL ||
  "https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/prod/gn";

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
  currentYieldRate: string;
  state: "Funding" | "Active" | "Buyback" | "Ended";
  paused: boolean;
  createdAt: string;
  createdAtBlock: string;
  activatedAt: string | null;
  metadataURI: string | null;
  metadataVersion: string;
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
  currentYieldRate
  state
  paused
  createdAt
  createdAtBlock
  activatedAt
  metadataURI
  metadataVersion
`;

export function useSubgraphCampaigns() {
  return useQuery({
    queryKey: ["subgraph", "campaigns"],
    queryFn: async () => {
      const data = await gql<{ campaigns: SubgraphCampaign[] }>(`
        query Campaigns {
          campaigns(first: 100, orderBy: createdAt, orderDirection: desc) {
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
            where: { producer: $producer }
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
