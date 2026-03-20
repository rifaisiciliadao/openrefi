---
tags:
  - openrefi
  - protocol
  - smart-contracts
status: defined
---
# Protocol — Smart Contracts

## Contract Architecture

### Core Contracts

#### 1. `CampaignFactory`
Registry and deployer for new campaigns.

- `createCampaign(params)` → deploys all campaign contracts
- Stores all campaign addresses
- Collects protocol fee (small % of raised funds)
- Owner: protocol multisig
- Enforces protocol constants: dynamic yield rate (5→1 linear decay), linear penalty, 90-day USDC deposit window, 30% producer share (off-chain), 2% protocol fee (on-chain), 1,000 tokens per asset

#### 2. `Campaign`
Handles token sales and routes funds.

**State:**
- `pricePerToken` — fixed price in cUSD
- `maxSupply` — max tokens mintable
- `currentSupply` — tokens minted so far
- `seasonDuration` — season length (≥ 365 days)
- `state` — enum: Active, Ended

**Functions:**
- `buy(amount)` — accept CELO/cUSD, mint $CAMPAIGN, routes funds to unstake queue first
- `emergencyPause()` — pause all operations

**Note:** $CAMPAIGN is only minted during initial sales. No new minting after that. Supply is strictly deflationary.

#### 3. `CampaignToken` (ERC20)
Per-campaign staking token — "the seat."

- ERC20 + ERC20Votes (for balance checkpointing)
- **Mintable by**: Campaign contract only (during initial sales)
- **Burnable**: on early unstake penalty + permanent exit
- Non-rebasing, transferable, tradeable on DEX
- Strictly deflationary — supply can only decrease

#### 4. `YieldToken` (ERC20)
Per-campaign harvest claim token — "the fruit."

- ERC20, transferable
- **Mintable by**: StakingVault only (during staking)
- **Burned on**: harvest redemption (product or USDC)
- Fresh $YIELD minted each season from staking
- No carry-over between seasons — each season's $YIELD is independent

#### 5. `StakingVault`
Handles staking, yield accrual, penalties, and the unstaking queue.

**State:**
- `totalStaked` — total $CAMPAIGN staked
- `maxSupply` — max $CAMPAIGN tokens (for yield rate calculation)
- `rewardPerTokenStored` — Synthetix accumulator
- `stakes[user]` — struct: amount, startTime, rewardPerTokenPaid
- `unstakeQueue[]` — FIFO queue of (user, owedAmount)
- `totalQueueDebt` — sum of all pending unstake obligations
- `currentSeason` — active season ID

**Dynamic Yield Rate:**
```
yieldRate = 5 - 4 × (totalStaked / maxSupply)

0% filled  → yieldRate = 5 (max, early bird bonus)
50% filled → yieldRate = 3
100% filled → yieldRate = 1 (min)
```

Recalculated on every stake/unstake event. Accumulator is updated before rate changes, locking in previously earned $YIELD at the old rate.

**Functions:**
- `stake(amount)` — update accumulator, deposit $CAMPAIGN, recalculate yieldRate
- `unstake()` — update accumulator, apply linear penalty (burn), forfeit $YIELD, recalculate yieldRate, return/queue remainder
- `restake()` — roll $CAMPAIGN into next season (keep position, start earning fresh $YIELD)
- `claimYield()` — view accumulated $YIELD balance
- `endSeason()` — finalize season, stop $YIELD accrual
- `startSeason(newSeasonId)` — begin new season, reset $YIELD accrual
- `processQueue(incomingFunds)` — called by Campaign.buy() to drain unstake queue FIFO
- `currentYieldRate()` — view: returns current dynamic yield rate

**Penalty Logic:**
```
penaltyRate = 1 - (elapsed / seasonDuration)
penaltyAmount = stakedAmount * penaltyRate → BURNED
returnedAmount = stakedAmount - penaltyAmount → returned or queued
ALL $YIELD forfeited
```

**Unstake Queue:**
- FIFO, partial fills allowed
- New purchases fund queue first
- Cancel unstake = re-stake if not yet filled

#### 6. `HarvestManager`
Two-step harvest redemption: product or USDC.

**State:**
- `seasons[seasonId]` — struct: merkleRoot, totalHarvestValueUSD, totalYieldSupply, claimStart, claimEnd, usdcDeadline, minProductClaim
- `claims[seasonId][user]` — struct: claimed (bool), redemptionType (product/usdc), amount
- `usdcDeposited` — USDC deposited by producer for that season

**Functions:**
- `reportHarvest(seasonId, totalValueUSD, merkleRoot, totalUnits)` — producer reports 70% of gross harvest (30% kept at origin)
- `redeemProduct(seasonId, amount, merkleProof)` — Step 1+2a: burn $YIELD, verify proof, emit Claimed event. Reverts if amount < minProductClaim
- `redeemUSDC(seasonId, amount)` — Step 1: burn $YIELD, register USDC claim. No minimum
- `claimUSDC(seasonId)` — Step 2b: claim deposited USDC (after producer deposits)
- `depositUSDC(seasonId, amount)` — producer deposits USDC (within 90-day window)

**Revenue Flow:**
```
Producer reports harvest (70% of gross, 30% kept at origin)
  → 2% protocol fee deducted automatically
  → 98% of reported value available to token holders
```

**Two-Step Redemption:**
```
Product path:
  1. User calls redeemProduct() → $YIELD burned, Merkle verified, Claimed event emitted
  2. Off-chain fulfillment → ship product (shipping paid by user)

USDC path:
  1. User calls redeemUSDC() → $YIELD burned, USDC claim registered
  2. Producer sells unredeemed product → deposits USDC within 90 days
  3. User calls claimUSDC() → receives USDC
```

---

## Contract Dependency Graph

```
CampaignFactory
  └── deploys per campaign:
        ├── CampaignToken (ERC20 + Votes) — strictly deflationary
        ├── YieldToken (ERC20) — seasonal, burned on redemption
        ├── Campaign (sales only, routes funds to queue)
        ├── StakingVault
        │     ├── mints → YieldToken (staking rewards)
        │     └── burns → CampaignToken (penalties)
        └── HarvestManager
              ├── burns → YieldToken (on redemption)
              └── receives → USDC from producer
```

## Multi-Season Lifecycle

```
Season 1:
  Campaign.buy() → mint $CAMPAIGN (one-time)
  StakingVault.stake() → earn $YIELD
  HarvestManager.reportHarvest() → redemption opens
  Users burn $YIELD → product or USDC
  Some users exit → $CAMPAIGN burned (deflationary)

Season 2:
  No new $CAMPAIGN minted (unless new buyers from remaining maxSupply)
  StakingVault.startSeason() → fresh $YIELD accrual
  Restakers earn $YIELD on same $CAMPAIGN
  Their share is now larger (fewer stakers)
  
Season N:
  Loyal stakers have growing harvest share
  Supply continuously deflating
```

## Technical Considerations for CELO

- **Gas token**: CELO, support cUSD contributions via fee abstraction
- **Block time**: 1 second — yield accrual uses seconds
- **CELO token duality**: native + ERC20, handle both transfer types
- **Key derivation**: `m/44'/52752'/0'/0` (different from Ethereum)
- **Oracles**: Chainlink, RedStone, Pyth available if needed
- **DEX listing**: Uniswap V4, Velodrome on CELO for $CAMPAIGN trading

## Development Stack
- **Language**: Solidity 0.8.x
- **Framework**: Foundry (forge, cast, anvil)
- **Libraries**: OpenZeppelin Contracts v5 (ERC20, ERC20Votes, MerkleProof, AccessControl, ReentrancyGuard)
- **Testing**: Forge tests + fork testing against CELO L2
- **Deployment**: Foundry scripts, verified on Celoscan
- **Auditing**: Slither, Aderyn static analysis → external audit before mainnet

## Security Considerations
- Reentrancy guards on all state-changing functions
- Merkle proof verification for all product claims
- Role-based access: producer vs protocol admin
- Emergency pause on all contracts
- StakingVault is the only contract that can mint YieldToken
- Campaign is the only contract that can mint CampaignToken
- $CAMPAIGN is strictly deflationary — no minting after initial sale
- USDC deposit deadline enforcement (90 days)
- Snapshot timing announced in advance
