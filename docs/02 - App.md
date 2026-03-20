---
tags:
  - openrefi
  - app
  - frontend
  - subgraph
status: defined
---
# App — Frontend & Subgraph

## Architecture Overview

```
┌─────────────────────────────────────┐
│            Frontend (Web)           │
│  Next.js / React + wagmi + viem    │
│  MetaMask / WalletConnect          │
│  Reads from subgraph + contracts   │
└──────────────┬──────────────────────┘
               │
       ┌───────┴───────┐
       │               │
┌──────▼──────┐  ┌─────▼──────────┐
│  Subgraph   │  │  L2 Chain      │
│  (indexer)  │  │  Smart contracts│
│  Read-only  │  │  All state      │
└─────────────┘  └────────────────┘
```

**No backend.** All state lives on-chain. Subgraph indexes events for fast querying. Frontend reads from subgraph + direct contract calls. Merkle tree generation runs as an off-chain script (CLI) triggered by the producer.

## Frontend

### Pages / Views

| Page | Description |
|---|---|
| **Home** | Browse active campaigns, featured producers, Silvi.earth verified badge |
| **Campaign Detail** | Campaign info, fill progress (tokens staked / max supply), current dynamic yield rate, token price, buy CTA, dMRV report link |
| **Staking** | Stake/unstake $CAMPAIGN, live $YIELD accrual counter, current yield rate (5→1 gauge), penalty calculator, unstake queue status |
| **My Portfolio** | User's tokens across campaigns: held, staked, $YIELD earned, claimable harvests, cumulative ROI |
| **Harvest Claim** | Active seasons, claim status, choose: redeem product (if ≥ min claim, shipping form) or redeem USDC, two-step status tracker |
| **Create Campaign** | Producer form: token price, max supply (auto-calculated from # of assets × 1,000), season duration (≥ 1yr), min product claim amount |
| **Producer Dashboard** | Manage campaigns, report harvest value, upload dMRV reports, publish merkle roots, deposit USDC (90-day tracker) |

### Tech Stack
- **Framework**: Next.js (App Router)
- **Wallet**: wagmi v2 + viem
- **Wallet support**: MetaMask, WalletConnect, chain-specific wallets
- **Styling**: Tailwind CSS
- **Data**: Subgraph (The Graph) for indexed data + direct contract reads for real-time state
- **Notifications**: Push Protocol or email for harvest announcements
- **File storage**: IPFS (Pinata) for campaign media + dMRV reports

### Key UX Considerations
- Mobile-first design
- Stablecoin contribution option (users don't need to hold native token)
- Campaign fill progress with live dynamic yield rate
- Staking dashboard: live $YIELD counter, penalty preview slider
- Unstake queue: position in queue, estimated fill time
- Harvest redemption: clear comparison — product amount vs USDC value, minimum product claim warning
- Token balance displayed with USD equivalent (using floor price after harvest)
- dMRV badge: campaigns with Silvi.earth verification show a trust badge
- ROI calculator: projected returns based on staking time and current fill level

## Subgraph (The Graph)

Indexes all contract events for fast frontend queries. No backend needed.

### Entities

```graphql
type Campaign @entity {
  id: ID!
  producer: Bytes!
  campaignToken: Bytes!
  yieldToken: Bytes!
  pricePerToken: BigDecimal!
  maxSupply: BigInt!
  currentSupply: BigInt!
  totalStaked: BigInt!
  seasonDuration: BigInt!
  minProductClaim: BigInt!
  currentYieldRate: BigDecimal!
  state: String!
  createdAt: BigInt!
  seasons: [Season!]! @derivedFrom(field: "campaign")
  stakes: [Stake!]! @derivedFrom(field: "campaign")
}

type Season @entity {
  id: ID!
  campaign: Campaign!
  seasonId: BigInt!
  totalHarvestValueUSD: BigDecimal!
  totalYieldSupply: BigInt!
  totalProductUnits: BigInt!
  merkleRoot: Bytes!
  claimStart: BigInt!
  claimEnd: BigInt!
  usdcDeadline: BigInt!
  usdcDeposited: BigDecimal!
  claims: [Claim!]! @derivedFrom(field: "season")
}

type Stake @entity {
  id: ID!
  campaign: Campaign!
  user: Bytes!
  amount: BigInt!
  startTime: BigInt!
  yieldEarned: BigInt!
  active: Boolean!
}

type Claim @entity {
  id: ID!
  season: Season!
  user: Bytes!
  redemptionType: String!  # "product" or "usdc"
  yieldBurned: BigInt!
  productAmount: BigInt!
  usdcAmount: BigDecimal!
  fulfilled: Boolean!
  claimedAt: BigInt!
}

type UnstakeRequest @entity {
  id: ID!
  campaign: Campaign!
  user: Bytes!
  owedAmount: BigInt!
  filledAmount: BigInt!
  penaltyBurned: BigInt!
  status: String!  # "pending", "filled", "cancelled"
  requestedAt: BigInt!
}

type User @entity {
  id: ID!
  stakes: [Stake!]! @derivedFrom(field: "user")
  claims: [Claim!]! @derivedFrom(field: "user")
}
```

### Event Handlers

| Contract Event | Subgraph Action |
|---|---|
| `CampaignCreated` | Create Campaign entity |
| `TokensPurchased` | Update Campaign.currentSupply |
| `Staked` | Create/update Stake entity, update Campaign.totalStaked + currentYieldRate |
| `Unstaked` | Update Stake, create UnstakeRequest, update Campaign.totalStaked + currentYieldRate |
| `UnstakeQueueFilled` | Update UnstakeRequest status |
| `SeasonCreated` | Create Season entity |
| `HarvestReported` | Update Season with harvest data |
| `ProductRedeemed` | Create Claim (type: product) |
| `USDCRedeemed` | Create Claim (type: usdc) |
| `USDCDeposited` | Update Season.usdcDeposited |
| `USDCClaimed` | Update Claim.fulfilled |
| `YieldRateUpdated` | Update Campaign.currentYieldRate |

### Example Queries

```graphql
# Active campaigns with staking stats
{
  campaigns(where: { state: "Active" }) {
    id
    pricePerToken
    maxSupply
    totalStaked
    currentYieldRate
    currentSupply
  }
}

# User's portfolio across campaigns
{
  stakes(where: { user: "0x...", active: true }) {
    campaign { id pricePerToken }
    amount
    yieldEarned
    startTime
  }
}

# Season claims for a campaign
{
  claims(where: { season_: { campaign: "0x..." } }) {
    user
    redemptionType
    yieldBurned
    productAmount
    usdcAmount
  }
}
```

## Merkle Tree Generation (Off-chain Script)

Not a backend — a CLI script run by the producer (or protocol admin) at harvest time.

```
Script: generate-merkle.ts

Input:
  - Campaign address
  - Season ID
  - Total product units
  - Block number for snapshot

Steps:
  1. Query subgraph for all $YIELD balances at snapshot block
  2. Compute: userClaim = (userYield / totalYield) × totalProductUnits
  3. Filter out claims below minProductClaim (those go to USDC only)
  4. Build Merkle tree
  5. Output: merkleRoot + JSON file of proofs
  6. Producer publishes merkleRoot on-chain via HarvestManager
  7. Proof JSON hosted on IPFS (frontend fetches per user)
```

## Shipping / Fulfillment

Not part of the platform — handled by the producer off-chain.

- Frontend emits shipping info with the product claim (encrypted, stored on IPFS or submitted via form to producer)
- Producer monitors `ProductRedeemed` events (via subgraph or direct)
- Producer handles shipping logistics independently
- Shipping costs paid separately by the user (off-platform)

## dMRV Integration (Silvi.earth)

- Producer uploads dMRV report links via frontend
- IPFS hash stored on-chain (in campaign metadata or separate mapping)
- Frontend displays latest report on campaign page
- Historical reports queryable via subgraph

## Infrastructure
- **Hosting**: Vercel (frontend, static + SSR)
- **Subgraph**: The Graph (hosted or decentralized network)
- **RPC**: Public RPC or Ankr/QuickNode for target L2 (direct contract reads + tx submission)
- **IPFS**: Pinata (campaign media, dMRV reports, Merkle proofs)
- **CI/CD**: GitHub Actions

## What the Frontend Reads From

| Data | Source |
|---|---|
| Campaign list, stats, history | Subgraph |
| Current yield rate, token balances | Direct contract call (real-time) |
| User's $YIELD earned | Direct contract call |
| Staking history, claims | Subgraph |
| Unstake queue position | Subgraph + contract call |
| Merkle proofs for claims | IPFS (JSON file) |
| Campaign metadata, images | IPFS |
| dMRV reports | IPFS + Silvi.earth links |
