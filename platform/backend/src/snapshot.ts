import { createPublicClient, http, getAddress, type Address } from "viem";
import { baseSepolia, mainnet, sepolia } from "viem/chains";

const SUBGRAPH_URL =
  process.env.SUBGRAPH_URL ||
  "https://api.goldsky.com/api/public/project_cmo1ydnmbj6tv01uwahhbeenr/subgraphs/growfi/4.0.2/gn";

const CHAIN_ID = Number(process.env.CHAIN_ID || process.env.NEXT_PUBLIC_CHAIN_ID || baseSepolia.id);

const RPC_URL =
  process.env.RPC_URL ||
  process.env.SEPOLIA_RPC_URL ||
  process.env.BASE_SEPOLIA_RPC ||
  (CHAIN_ID === sepolia.id
    ? "https://ethereum-sepolia-rpc.publicnode.com"
    : "https://sepolia.base.org");

const chain =
  CHAIN_ID === sepolia.id ? sepolia : CHAIN_ID === mainnet.id ? mainnet : baseSepolia;

const client = createPublicClient({
  chain,
  transport: http(RPC_URL),
});

/**
 * Minimal StakingVault ABI — just the two views we need.
 * Kept local so the backend stays independent from the frontend bundle.
 */
const stakingVaultAbi = [
  {
    type: "function",
    name: "currentSeasonId",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "earned",
    stateMutability: "view",
    inputs: [{ name: "positionId", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "seasonTotalYieldOwed",
    stateMutability: "view",
    inputs: [{ name: "seasonId", type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "seasons",
    stateMutability: "view",
    inputs: [{ name: "", type: "uint256" }],
    outputs: [
      { name: "startTime", type: "uint256" },
      { name: "endTime", type: "uint256" },
      { name: "totalYieldMinted", type: "uint256" },
      { name: "rewardPerTokenAtEnd", type: "uint256" },
      { name: "totalYieldOwed", type: "uint256" },
      { name: "active", type: "bool" },
      { name: "existed", type: "bool" },
    ],
  },
] as const;

const erc20Abi = [
  {
    type: "function",
    name: "totalSupply",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
] as const;

interface SubgraphPosition {
  positionId: string;
  user: string;
  amount: string;
  yieldClaimed: string;
  active: boolean;
  seasonId: string;
}

interface SubgraphCampaignRef {
  stakingVault: string;
  yieldToken: string;
}

async function gql<T>(query: string, variables: Record<string, unknown>): Promise<T> {
  const res = await fetch(SUBGRAPH_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`Subgraph HTTP ${res.status}`);
  const body = (await res.json()) as {
    data?: T;
    errors?: Array<{ message: string }>;
  };
  if (body.errors?.length) {
    throw new Error(body.errors.map((e) => e.message).join(", "));
  }
  if (!body.data) throw new Error("Empty subgraph response");
  return body.data;
}

export interface SnapshotHolder {
  user: Address;
  yieldAmount: bigint;
}

export interface SnapshotResult {
  campaign: Address;
  seasonId: bigint;
  stakingVault: Address;
  yieldToken: Address;
  totalYield: bigint;
  seasonTotalYieldOwed: bigint | null;
  redeemableYieldSupply: bigint | null;
  holders: SnapshotHolder[];
  notes: string[];
}

/**
 * Compute per-user $YIELD for a given (campaign, seasonId):
 *
 *   yieldPerUser = Σ (position.yieldClaimed + earned(positionId))
 *
 * where `position` iterates all subgraph Position entities that currently
 * have `seasonId == target`. Inactive positions (fully unstaked with
 * penalty) are skipped.
 *
 * Caveats (documented in `notes` of the returned payload):
 * - `position.yieldClaimed` is cumulative per position across its
 *   lifetime, not per-season. If a position was restaked from an
 *   earlier season into this one, its yieldClaimed may over-count.
 *   The MVP assumption is that positions are not restaked before
 *   reportHarvest — true for first-season reports.
 * - Peer-to-peer $YIELD token transfers are not reflected here — the
 *   snapshot is "yield earned by position", not "current ERC20 balance".
 *   Again fine for the happy path.
 *
 * `redeemableYieldSupply` is different: it mirrors the on-chain denominator
 * used by HarvestManager.reportHarvest:
 *   yieldToken.totalSupply() + Σ(ended season totalYieldOwed - totalYieldMinted)
 */
export async function snapshotSeasonYield(
  campaign: Address,
  seasonId: bigint,
): Promise<SnapshotResult> {
  const notes: string[] = [];

  // 1. Fetch campaign refs + positions for this season from the subgraph.
  const data = await gql<{
    campaign: SubgraphCampaignRef | null;
    positions: SubgraphPosition[];
  }>(
    `
    query Snapshot($campaign: ID!, $campaignBytes: Bytes!, $seasonId: BigInt!) {
      campaign(id: $campaign) {
        stakingVault
        yieldToken
      }
      positions(
        where: { campaign: $campaignBytes, seasonId: $seasonId, active: true }
        first: 1000
      ) {
        positionId
        user
        amount
        yieldClaimed
        active
        seasonId
      }
    }
    `,
    {
      campaign: campaign.toLowerCase(),
      campaignBytes: campaign.toLowerCase(),
      seasonId: seasonId.toString(),
    },
  );

  if (!data.campaign) {
    throw new Error(`Campaign ${campaign} not indexed by subgraph`);
  }

  const stakingVault = getAddress(data.campaign.stakingVault) as Address;
  const yieldToken = getAddress(data.campaign.yieldToken) as Address;

  if (data.positions.length === 0) {
    notes.push("No active positions found for this season.");
  }

  // 2. For each position, read `earned` live from the vault.
  const earnedCalls = data.positions.map((p) => ({
    address: stakingVault,
    abi: stakingVaultAbi,
    functionName: "earned" as const,
    args: [BigInt(p.positionId)] as const,
  }));

  let earnedResults: Array<{ status: string; result?: bigint; error?: Error }> = [];
  if (earnedCalls.length > 0) {
    earnedResults = (await client.multicall({
      contracts: earnedCalls,
      allowFailure: true,
    })) as typeof earnedResults;
  }

  // 3. Sum per-user.
  const perUser = new Map<string, bigint>();
  let totalYield = 0n;

  data.positions.forEach((pos, i) => {
    const earned = earnedResults[i]?.result ?? 0n;
    const claimed = BigInt(pos.yieldClaimed);
    const contribution = claimed + earned;
    if (contribution === 0n) return;

    const user = getAddress(pos.user);
    const key = user.toLowerCase();
    perUser.set(key, (perUser.get(key) ?? 0n) + contribution);
    totalYield += contribution;
  });

  const holders: SnapshotHolder[] = Array.from(perUser.entries())
    .map(([user, yieldAmount]) => ({
      user: getAddress(user) as Address,
      yieldAmount,
    }))
    .sort((a, b) =>
      b.yieldAmount === a.yieldAmount ? 0 : b.yieldAmount > a.yieldAmount ? 1 : -1,
    );

  // 4. Cross-check against the canonical on-chain value, if the season
  //    was started. Surface any mismatch as a note.
  let seasonTotalYieldOwed: bigint | null = null;
  let redeemableYieldSupply: bigint | null = null;
  try {
    seasonTotalYieldOwed = (await client.readContract({
      address: stakingVault,
      abi: stakingVaultAbi,
      functionName: "seasonTotalYieldOwed",
      args: [seasonId],
    })) as bigint;

    if (seasonTotalYieldOwed !== totalYield) {
      const delta = totalYield - seasonTotalYieldOwed;
      notes.push(
        `Snapshot totalYield (${totalYield}) differs from seasonTotalYieldOwed (${seasonTotalYieldOwed}) by ${delta}. ` +
          "If the season isn't ended yet the running total is expected to drift.",
      );
    }
  } catch {
    notes.push(
      "seasonTotalYieldOwed read failed — season may not exist on chain yet.",
    );
  }

  try {
    redeemableYieldSupply = await readRedeemableYieldSupply(stakingVault, yieldToken);
    if (redeemableYieldSupply !== totalYield) {
      const delta = totalYield - redeemableYieldSupply;
      notes.push(
        `Snapshot totalYield (${totalYield}) differs from redeemableYieldSupply (${redeemableYieldSupply}) by ${delta}. ` +
          "Merkle generation must use redeemableYieldSupply as the denominator to match reportHarvest.",
      );
    }
  } catch {
    notes.push(
      "redeemableYieldSupply read failed — Merkle generation cannot be safely matched to reportHarvest.",
    );
  }

  return {
    campaign,
    seasonId,
    stakingVault,
    yieldToken,
    totalYield,
    seasonTotalYieldOwed,
    redeemableYieldSupply,
    holders,
    notes,
  };
}

async function readRedeemableYieldSupply(
  stakingVault: Address,
  yieldToken: Address,
): Promise<bigint> {
  const [currentSeasonId, mintedSupply] = await Promise.all([
    client.readContract({
      address: stakingVault,
      abi: stakingVaultAbi,
      functionName: "currentSeasonId",
    }) as Promise<bigint>,
    client.readContract({
      address: yieldToken,
      abi: erc20Abi,
      functionName: "totalSupply",
    }) as Promise<bigint>,
  ]);

  let total = mintedSupply;
  for (let seasonId = 1n; seasonId <= currentSeasonId; seasonId += 1n) {
    const season = (await client.readContract({
      address: stakingVault,
      abi: stakingVaultAbi,
      functionName: "seasons",
      args: [seasonId],
    })) as readonly [bigint, bigint, bigint, bigint, bigint, boolean, boolean];

    const totalYieldMinted = season[2];
    const totalYieldOwed = season[4];
    const active = season[5];
    const existed = season[6];

    if (existed && !active && totalYieldOwed > totalYieldMinted) {
      total += totalYieldOwed - totalYieldMinted;
    }
  }

  return total;
}
