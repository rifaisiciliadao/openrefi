---
tags:
  - openrefi
  - app
  - frontend
  - backend
status: defined
---
# App — Frontend & Backend

## Architecture Overview

```
┌─────────────────────────────────────┐
│            Frontend (Web)           │
│  Next.js / React + wagmi + viem    │
│  Valora / MetaMask wallet connect  │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│            Backend API              │
│  Node.js / Fastify                  │
│  Campaign metadata, user profiles   │
│  Merkle tree generation             │
│  Fulfillment / shipping tracking    │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│          CELO L2 (on-chain)         │
│  Smart contracts (see Protocol)     │
└─────────────────────────────────────┘
```

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
- **Wallet**: wagmi v2 + viem for CELO L2 interaction
- **Wallet support**: Valora (CELO native), MetaMask, WalletConnect
- **Styling**: Tailwind CSS
- **State**: React Query (TanStack) for contract reads
- **Notifications**: Push Protocol or email for harvest announcements

### Key UX Considerations
- Mobile-first design (CELO's user base is mobile-heavy)
- cUSD contribution option (users don't need to hold CELO)
- Campaign fill progress with live dynamic yield rate (shows FOMO: "yield rate dropping as campaign fills!")
- Staking dashboard: live $YIELD counter, penalty preview slider ("if you unstake now, you lose X%")
- Unstake queue: position in queue, estimated fill time based on recent purchase volume
- Harvest redemption: clear comparison — product amount vs USDC value, minimum product claim warning
- Token balance displayed with USD equivalent (using floor price after harvest)
- dMRV badge: campaigns with Silvi.earth verification show a trust badge
- ROI calculator: show projected returns based on staking time and current fill level

## Backend

### Responsibilities

1. **Campaign Metadata Storage**
   - Campaign descriptions, images, producer info, asset count
   - Stored in PostgreSQL + IPFS for decentralization
   - On-chain stores only hashes/references

2. **Merkle Tree Generation**
   - At harvest time: snapshot $YIELD balances from CELO L2
   - Compute proportional claims per holder
   - Enforce minimum product claim threshold
   - Generate Merkle tree
   - Publish root on-chain via HarvestManager
   - Serve proofs via API

3. **Fulfillment / Shipping**
   - Listen to `Claimed` events from HarvestManager
   - Queue shipping orders
   - Track delivery status
   - Notify users of shipment
   - Shipping costs calculated and charged separately

4. **User Profiles**
   - Shipping addresses (encrypted at rest)
   - Claim history
   - Email for notifications (optional)

5. **Staking & Queue Monitoring**
   - Index staking events for dashboard stats
   - Track unstake queue state for UI display
   - Calculate real-time yield rate based on current fill %
   - Project $YIELD earnings for users

6. **dMRV Integration (Silvi.earth)**
   - Store links to Silvi.earth dMRV reports per campaign
   - Fetch latest tree health status
   - Store IPFS hashes of reports on-chain
   - Display historical dMRV reports on campaign page

### Tech Stack
- **Runtime**: Node.js
- **Framework**: Fastify
- **Database**: PostgreSQL (Prisma ORM)
- **Queue**: BullMQ + Redis (for event processing, shipping)
- **Blockchain indexing**: Ponder or custom event listener
- **File storage**: IPFS (Pinata) for campaign media + dMRV reports
- **Auth**: SIWE (Sign-In with Ethereum)

### API Endpoints

```
# Campaigns
GET    /api/campaigns                        — list all campaigns
GET    /api/campaigns/:id                    — campaign detail + staking stats + current yield rate
POST   /api/campaigns                        — create campaign (producer, auth required)

# Staking
GET    /api/staking/:campaignId/stats        — total staked, fill %, current yield rate, queue depth
GET    /api/staking/:campaignId/:address     — user's stake, $YIELD earned, penalty preview
GET    /api/staking/:campaignId/queue        — unstake queue state (positions, amounts)
GET    /api/staking/:campaignId/roi          — projected ROI calculator (based on fill + time)

# Harvests
GET    /api/harvests/:campaignId             — list seasons for a campaign
GET    /api/harvests/:seasonId/info          — season details, floor price, claim window
GET    /api/claim-proof/:seasonId/:address   — get merkle proof for user

# Redemption
GET    /api/redemption/:campaignId/:address  — user's options: product amount vs USDC value, min claim check

# User
GET    /api/user/portfolio                   — tokens held + staked + yield across all campaigns
POST   /api/user/shipping                    — save/update shipping address
GET    /api/user/claims                      — claim history + tracking

# Producer
POST   /api/producer/harvest                 — report harvest value (totalUSD)
POST   /api/producer/merkle                  — trigger merkle tree generation + publish root
POST   /api/producer/dmrv                    — upload/link Silvi.earth dMRV report
POST   /api/producer/deposit-usdc            — track USDC deposit status (90-day window)
GET    /api/producer/campaigns               — producer's campaigns overview

# dMRV
GET    /api/dmrv/:campaignId                 — latest dMRV report + history
GET    /api/dmrv/:campaignId/health          — current tree health summary
```

## Infrastructure
- **Hosting**: Vercel (frontend) + Railway/Fly.io (backend)
- **Database**: Managed PostgreSQL (Neon or Supabase)
- **RPC**: CELO public RPC or Ankr/QuickNode
- **Monitoring**: Sentry for errors, basic analytics
- **CI/CD**: GitHub Actions

## Integration Tests Needed
- Campaign creation → buy tokens → token minting flow
- Stake → dynamic yield rate update → $YIELD accrual flow
- Early unstake → penalty → queue → filled by new buyer flow
- Merkle tree generation → proof serving → on-chain claim (product path)
- Merkle tree generation → min product claim enforcement
- Harvest report → $YIELD floor price → USDC redemption two-step flow
- USDC deposit by producer within 90-day window
- Fulfillment pipeline: claim event → shipping queue → status update
- Wallet connection flow (Valora + MetaMask)
- dMRV report upload → IPFS storage → on-chain hash
