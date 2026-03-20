---
tags:
  - openrefi
  - tokenomics
  - yield
  - staking
status: defined
---
# Tokenomics — Token Design & Yield

## Two-Token Model (Productive Asset)

Each campaign has two tokens with distinct roles:

### $CAMPAIGN (Staking Token — "The Seat")
- ERC20 + ERC20Votes
- Bought from campaign contract at a set price
- Represents a **permanent productive position** in the campaign
- Stake it → it produces $YIELD every season
- Not staked → earns nothing
- Can be traded on DEX
- Can be burned to **permanently exit**
- **Mintable by**: Campaign contract only (during initial sales)
- **Strictly deflationary** — supply can only decrease

### $YIELD (Harvest Token — "The Fruit")
- ERC20, transferable
- Earned by staking $CAMPAIGN over a season
- Represents a **claim on that season's harvest**
- Burned to redeem: product OR USDC
- Fresh $YIELD minted each season from staking
- **Mintable by**: StakingVault only

### Key Insight
```
$CAMPAIGN = the tree (permanent, productive)
$YIELD    = the fruit (seasonal, consumable)

You don't cut down the tree to eat the fruit.
```

## Millisimali Fractionalization

Each tree/asset is divided into **1,000 tokens**:

```
1 token       = 1/1,000th of a tree
1,000 tokens  = 1 full tree
100 trees     = 100,000 tokens
```

## Revenue Split

```
GROSS HARVEST (physical, off-chain)
│
├─ 30% PRODUCER (at origin, off-chain)
│  → Taken before reporting to platform
│  → Covers labor, maintenance, operations
│
└─ 70% REPORTED TO PLATFORM (on-chain)
   │
   ├─ 2% PROTOCOL FEE
   │  → Goes to protocol treasury
   │
   └─ 98% TO TOKEN HOLDERS
      → Claimable via $YIELD burn (product or USDC)
```

**Effective holder share**: 70% × 98% = **68.6% of gross harvest value**

## Campaign Parameters

### Producer Sets
- **Token price** — fixed price per token
- **Max supply** — total tokens (1,000 per asset)
- **Season duration** — minimum 1 year (365 days)
- **Minimum product claim** — e.g., 5 liters for olive oil

### Protocol Constants (Fixed for All Campaigns)
- **Yield rate**: dynamic, decays linearly from 5→1 as campaign fills
- **Penalty curve**: linear (earlier unstake = higher penalty)
- **Producer share**: 30% of harvest (off-chain)
- **Protocol fee**: 2% of reported harvest value
- **USDC deposit window**: 90 days
- **Fractionalization**: 1,000 tokens per asset
- **Shipping**: paid separately by product redeemers

## Dynamic Yield Rate

The yield rate decreases as more tokens get staked. Early stakers earn $YIELD faster — a built-in early-investor bonus.

```
yieldRate = 5 - 4 × (totalStaked / maxSupply)

0% filled   → yieldRate = 5.0 (5x reward for first movers)
25% filled  → yieldRate = 4.0
50% filled  → yieldRate = 3.0
75% filled  → yieldRate = 2.0
100% filled → yieldRate = 1.0 (baseline)
```

- Recalculated on every stake/unstake event
- Already-earned $YIELD is locked in at the old rate
- Creates strong FOMO incentive to stake early
- No producer input needed — same rules for every campaign

## Token Pricing

Token price is set by the producer based on desired payback period:

```
tokenPrice = netAnnualReturnPerToken × paybackYears

netAnnualReturnPerToken = (grossHarvestValue × 0.70 × 0.98) / totalSupply
```

Recommended payback range: **3-5 years** (20-33% annual ROI)

## Flow

```
1. CAMPAIGN LAUNCHES
   Producer sets: token price, max supply, season duration (≥ 1 year),
                  minimum product claim amount
   → Users buy $CAMPAIGN with CELO/cUSD

2. STAKING
   → Users stake $CAMPAIGN → earn $YIELD over time
   → Yield rate is high early (5x) and decreases as campaign fills
   → Users can stake and unstake multiple times
   → Non-stakers hold or trade but earn nothing

3. EARLY UNSTAKE
   → Linear penalty on $CAMPAIGN principal (burned)
   → ALL accumulated $YIELD forfeited
   → If no liquidity → unstaking queue (FIFO, funded by new buyers)

4. SEASON ENDS / HARVEST
   → Producer takes 30% at origin (off-chain)
   → Reports remaining 70% value to platform
   → 2% protocol fee deducted
   → $YIELD floor price = reportedValue × 0.98 / totalYieldSupply

5. REDEMPTION (Two-Step)
   Step 1: User declares product or USDC → $YIELD burned
   Step 2a (product): Merkle claim + shipping (paid by user)
     → Only if claimable amount ≥ minimum product claim
     → Below minimum → must choose USDC
   Step 2b (USDC): Producer deposits within 90 days → user claims
     → No minimum for USDC redemption

6. RESTAKE FOR NEXT SEASON
   → $CAMPAIGN stays staked → earns fresh $YIELD
   → Compound effect: as others exit, your share grows

7. PERMANENT EXIT
   → Unstake $CAMPAIGN + sell on DEX or let it be burned
```

## Minimum Product Claim

Set per campaign by the producer (makes no sense to ship 0.5 liters of olive oil).

```
Example — Olive Oil Campaign:
  Minimum claim: 5 liters
  Per token/year: 0.002058 liters
  Tokens needed for min claim: ~2,430 tokens (~2.5 trees, ~$350)

Below minimum → USDC only
Above minimum → choose product or USDC
```

| Investment | Tokens | Trees | Yearly product | Can claim product? |
|---|---|---|---|---|
| $0.14 | 1 | 0.001 | 0.002L | No → USDC only |
| $14.40 | 100 | 0.1 | 0.2L | No → USDC only |
| $144 | 1,000 | 1 | 2.1L | No → USDC only |
| $360 | 2,500 | 2.5 | 5.1L | Yes ✓ |
| $1,440 | 10,000 | 10 | 20.6L | Yes ✓ |
| $14,400 | 100,000 | 100 | 205.8L | Yes ✓ |

Users below minimum can:
1. **Redeem USDC** (always available, no minimum)
2. **Accumulate more tokens** to reach the threshold
3. **Accumulate $YIELD** across seasons to batch a larger claim

## The Compounding Effect

Restakers grow their share through two forces:

1. **Exiters burn tokens** — supply shrinks, your % grows
2. **Penalties burn tokens** — early unstakers lose a portion permanently

```
Example ($0.144/token, 10% exit/year, 100,000 supply):
  Year 1: 90,000 staked → $0.04573/token (31.8% ROI)
  Year 2: 81,000 staked → $0.05082/token (35.3% ROI)
  Year 3: 72,900 staked → $0.05646/token (39.2% ROI) ← breakeven ~here
  Year 4: 65,610 staked → $0.06274/token (43.6% ROI)
  Year 5: 59,049 staked → $0.06971/token (48.4% ROI)

  5-year cumulative: 198% total return
```

## Unstaking Queue

- FIFO order — first to request, first to be paid
- Partial fills allowed
- New $CAMPAIGN purchases fund the queue before anything else
- Queued users can cancel and re-stake if not yet filled
- At season end, unfilled users keep their tokens

## Staking Mechanics

### Penalty Curve (Linear)

```
penalty% = 100% - (timeStaked / seasonDuration * 100%)
```

| Unstake at | Penalty | Kept |
|---|---|---|
| 1 month (8%) | 92% burned | 8% |
| 3 months (25%) | 75% burned | 25% |
| 6 months (50%) | 50% burned | 50% |
| 9 months (75%) | 25% burned | 75% |
| 12 months (100%) | 0% | 100% + yield |

### Yield Distribution
- $YIELD accrues per second while staked (Synthetix accumulator)
- Dynamic rate: high at start (5x), decreases as campaign fills (1x)
- Your harvest share = your $YIELD / total $YIELD minted that season
- Early stakers accumulate more $YIELD = bigger harvest share

## Verification — Silvi.earth dMRV

- Tree health tracked via **Silvi.earth** application
- **dMRV reports** published over the years (not tokenized)
- Covers: tree health, growth, carbon sequestration, biodiversity
- Published on campaign page + IPFS hash stored on-chain

## USDC Redemption Funding

Self-balancing:

```
Product redeemers claim A liters
Remaining product: total - A liters
Producer sells remaining → deposits USDC within 90 days
→ Covers all USDC obligations exactly
```

## Smart Contracts

| Contract | Role |
|---|---|
| **CampaignToken** | ERC20 + Votes, mintable by Campaign only, strictly deflationary |
| **YieldToken** | ERC20, mintable by StakingVault only, burned on harvest redemption |
| **Campaign** | Sells $CAMPAIGN at set price, routes funds to unstake queue first |
| **StakingVault** | Accepts stakes, mints $YIELD with dynamic rate, handles penalties + unstake queue |
| **HarvestManager** | Harvest reporting, two-step redemption (product Merkle + USDC), protocol fee, burns $YIELD, enforces min product claim |
| **CampaignFactory** | Deploys all of the above per campaign |

## Points System (Future)
- No protocol-level token for now
- Possible points system to reward: seasons participated, continuous staking streaks, referrals
- Future utility TBD
