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

## Fractionalization

Each tree/asset is divided into **1,000 tokens**:

```
1 token       = 1/1,000th of a tree
1,000 tokens  = 1 full tree
100 trees     = 100,000 tokens
```

## Revenue Split

There are **two** protocol fees, applied at different lifecycle moments and
with different sinks. Both go to `protocolFeeRecipient`.

```
1) FUNDING-SIDE — `Campaign.buy()` skim, applied per purchase
   ┌──────────────────────────────────────────────────────────────┐
   │ Buyer pays X (gross)                                         │
   │ ├─  3% FUNDING FEE  →  protocolFeeRecipient (non-refundable) │
   │ └─ 97% NET          →  escrow (Funding) or producer (Active) │
   │                        Sell-back queue & buyback work on NET │
   └──────────────────────────────────────────────────────────────┘

2) HARVEST-SIDE — applied at every `HarvestManager.depositUSDC`
   GROSS HARVEST (physical, off-chain)
   │
   ├─ 30% PRODUCER (at origin, off-chain — labor/ops)
   │
   └─ 70% REPORTED TO PLATFORM (on-chain)
      │
      ├─  2% PROTOCOL FEE     → protocolFeeRecipient
      │
      └─ 98% TO TOKEN HOLDERS → claimable via $YIELD burn (product or USDC)
```

**Effective holder share** (harvest only): 70% × 98% = **68.6% of gross harvest value**.

The 3% funding-side fee is **non-refundable on buyback**: a failed campaign
returns the NET (97%) to buyers. Rationale — the protocol incurs hosting +
indexing cost regardless of outcome, and the fee acts as a small "skin in
the game" filter against spam campaigns.

## Producer Collateral (Pre-Paid Yield Reserve)

Distinct from the two fees above. Producer-locked USDC sits in the campaign as
a reserve pool that automatically covers holder yield shortfalls for the
first `coverageHarvests` seasons. See `01 - Protocol.md §Producer Collateral`
for the lifecycle and `05 - Math & Formulas.md §15` for the formulas. Three
concrete numbers visible in UI:

- `harvestsToRepay = 10_000 / expectedYearlyReturnBps` — how many harvests of
  yield equal the original investment.
- `coverageHarvests` — how many of those the producer pre-funds.
- `tail = harvestsToRepay − coverageHarvests` — the residual delivery risk
  the holder carries.

The collateral is **one-way**: once locked, it can be drawn down by holder
shortfalls or stay locked forever, but never returns to the producer. This
asymmetry is intentional — it converts "expected yield" from a soft promise
into an enforceable on-chain commitment.

## Campaign Parameters

### Producer Sets
- **Token price** — fixed price per token (USD denominated)
- **Min cap** — minimum tokens to sell for campaign to proceed
- **Max cap** — maximum tokens (1,000 per asset)
- **Funding deadline** — deadline to reach min cap
- **Season duration** — minimum 1 year (365 days)
- **Minimum product claim** — e.g., 5 liters for olive oil
- **Expected yearly return (bps)** — producer's commitment, e.g. 1000 = 10%/year. Drives `harvestsToRepay` and the recommended collateral sizing. Immutable once campaign is created.
- **Expected first-year harvest** — physical product target for year one (in product units). Calibrates the ROI calculator and seeds the proportional baseline shown to investors.
- **Coverage harvests** — number of upcoming harvests the producer commits to pre-fund through `lockCollateral`. Higher = stronger trust signal, more capital required up front.

### Protocol Constants (Fixed for All Campaigns)
- **Yield rate**: dynamic, decays linearly from 5→1 as campaign fills
- **Penalty curve**: linear (earlier unstake = higher penalty)
- **Producer share**: 30% of harvest (off-chain)
- **Funding fee**: 3% of every `buy()` gross inflow (non-refundable on buyback)
- **Harvest fee**: 2% of every `depositUSDC` (yield-side)
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
0. CAMPAIGN CREATED
   Producer sets: token price, min cap, max cap, funding deadline,
                  season duration (≥ 1 year), minimum product claim amount
   → Campaign enters FUNDING state

1. FUNDING PHASE
   → Users buy $CAMPAIGN with any accepted ERC20 (USDC, WETH, etc.)
   → Price set per token: fixed rate or via Chainlink oracle
   → Funds held in escrow (contract), producer cannot access them
   → No staking during funding — just fundraising

2. MIN CAP REACHED → ACTIVE
   → Funds released to producer
   → Staking activates, yield accrual begins
   → Purchases continue until max cap

   OR: FUNDING DEADLINE PASSED, MIN CAP NOT REACHED → BUYBACK
   → Users call buyback() → full refund at original purchase price
   → Refund in the same token they paid with
   → $CAMPAIGN burned on refund

3. STAKING (only in ACTIVE state)
   → Users stake $CAMPAIGN → earn $YIELD over time
   → Yield rate is high early (5x) and decreases as campaign fills
   → Users can open multiple positions, manage each separately
   → Non-stakers hold or trade but earn nothing

4. EARLY UNSTAKE (two steps)
   Step 1: unstake(positionId) on StakingVault
     → Linear penalty on $CAMPAIGN principal (burned)
     → ALL un-withdrawn $YIELD forfeited
     → Remaining $CAMPAIGN returned to user instantly
   Step 2 (optional): sellBack(amount) on Campaign
     → $CAMPAIGN deposited into sell-back queue
     → Filled when new buyer comes (FIFO)
     → Or cancel and keep $CAMPAIGN
     → Or sell on DEX instead

5. SEASON ENDS / HARVEST
   → Producer takes 30% at origin (off-chain)
   → Reports remaining 70% value to platform
   → 2% protocol fee deducted
   → $YIELD floor price = reportedValue × 0.98 / totalYieldSupply

6. REDEMPTION (Two-Step, within claim window)
   Step 1: User declares product or USDC → $YIELD burned
   Step 2a (product): Merkle claim + shipping (paid by user)
     → Only if claimable amount ≥ minimum product claim
     → Below minimum → must choose USDC
   Step 2b (USDC): Producer deposits within 90 days → user claims
     → No minimum for USDC redemption

7. RESTAKE FOR NEXT SEASON
   → $CAMPAIGN stays staked → earns fresh $YIELD
   → Compound effect: as others exit, your share grows

8. PERMANENT EXIT
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
