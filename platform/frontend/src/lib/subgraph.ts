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
  currentSupply: string;
  totalStaked: string;
  totalRaised: string;
  currentYieldRate: string;
  state: "Funding" | "Active" | "Buyback" | "Ended";
  paused: boolean;
  createdAt: string;
  createdAtBlock: string;
  activatedAt: string | null;
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
