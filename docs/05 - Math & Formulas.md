---
tags:
  - openrefi
  - math
  - formulas
  - contracts
status: defined
---
# Math & Formulas

Mathematical foundations for all contract mechanics.

---

## 1. Revenue Split

Before any on-chain math, the harvest is split:

```
grossHarvest        = totalLiters × pricePerLiter
producerShare       = grossHarvest × 0.30          (off-chain, at origin)
reportedHarvest     = grossHarvest × 0.70          (reported to platform)
protocolFee         = reportedHarvest × 0.02       (on-chain, to protocol)
holderPool          = reportedHarvest × 0.98       (on-chain, to holders)

Effective holder share = grossHarvest × 0.686
```

Example (100 trees, 3L/tree, $20/L):

```
grossHarvest    = 300 × $20 = $6,000
producerShare   = $1,800 (90 liters kept)
reportedHarvest = $4,200 (210 liters)
protocolFee     = $84
holderPool      = $4,116 (205.8 liters)
```

---

## 2. Token Pricing

```
netAnnualPerToken = holderPool / totalSupply
tokenPrice        = netAnnualPerToken × paybackYears

paybackYears = tokenPrice / netAnnualPerToken
annualROI    = 1 / paybackYears × 100%
```

---

## 3. Token Purchase (Multi-Token)

Base price is denominated in USD. Payments accepted in any configured ERC20.

### Fixed-rate tokens (USDC, DAI, etc.)

```
tokensOut = paymentAmount / fixedRate
tokensOut = min(tokensOut, maxSupply - currentSupply)
refund    = paymentAmount - (tokensOut × fixedRate)
```

### Oracle-priced tokens (WETH, etc.)

```
usdPrice = oracle.latestAnswer()             (e.g., WETH/USD from Chainlink)
paymentValueUSD = paymentAmount × usdPrice
tokensOut = paymentValueUSD / pricePerToken
tokensOut = min(tokensOut, maxSupply - currentSupply)
refund    = paymentAmount - (tokensOut × pricePerToken / usdPrice)
```

Example (WETH at $2,880, pricePerToken = $0.144):

```
User sends 0.05 WETH
paymentValueUSD = 0.05 × $2,880 = $144
tokensOut = $144 / $0.144 = 1,000 $CAMPAIGN (1 tree)
```

### Purchase fund routing

```
During FUNDING state: funds held in escrow
During ACTIVE state:  funds released to producer
```

---

## 4. Dynamic Yield Rate

The yield rate decreases linearly as the campaign fills up. Early stakers earn $YIELD faster than latecomers.

```
yieldRate = maxRate - (maxRate - minRate) × (totalStaked / maxSupply)

where:
  maxRate = 5 (protocol constant, at 0% filled)
  minRate = 1 (protocol constant, at 100% filled)
```

### Rate at different fill levels

| Campaign Fill | totalStaked | yieldRate |
|---|---|---|
| 0% | 0 | 5.0 |
| 10% | 10,000 | 4.6 |
| 25% | 25,000 | 4.0 |
| 50% | 50,000 | 3.0 |
| 75% | 75,000 | 2.0 |
| 100% | 100,000 | 1.0 |

### How it interacts with the accumulator

Every time someone stakes or unstakes, `yieldRate` is recalculated before updating the accumulator:

```
On stake/unstake event:
  1. Calculate pending rewards at OLD yieldRate
  2. Update rewardPerTokenStored
  3. Update totalStaked
  4. Recalculate yieldRate based on new totalStaked
  5. Future accrual uses new yieldRate
```

Early stakers' already-accumulated $YIELD is locked in at the higher rates. New accrual happens at the new (lower) rate.

### Early staker advantage

```
Example (100,000 max supply, 1-year season):

Alice stakes 1,000 tokens on day 1 (she's first, fill = 1%)
  yieldRate ≈ 4.96
  Per day: 1,000 × 4.96 = 4,960 $YIELD/day

...campaign fills to 50% over 3 months...

Bob stakes 1,000 tokens at month 6 (fill = 50%)
  yieldRate = 3.0
  Per day: 1,000 × 3.0 = 3,000 $YIELD/day

Alice earned at higher rates for the first 6 months,
then at the same rate as everyone else after.
Her total $YIELD >> Bob's total $YIELD → bigger harvest share.
```

---

## 5. Yield Accrual (Synthetix Accumulator)

Per-second granularity, O(1) gas:

```
yieldRatePerSecond = currentYieldRate / 86,400

rewardPerTokenStored += (Δt_seconds × yieldRatePerSecond × 1e18) / totalStaked

yieldEarned(user) = stakedBalance(user)
                    × (rewardPerTokenStored - userRewardPerTokenPaid(user))
                    / 1e18
```

Note: `currentYieldRate` changes on every stake/unstake event (see section 4). The accumulator captures the correct time-weighted rate for each user.

---

## 6. Harvest Share

A user's share is proportional to their $YIELD relative to total:

```
userShare = userYield / totalYieldSupply
```

Because of the dynamic yield rate:
- Early stakers accumulate more $YIELD (higher rate when campaign was less filled)
- Late stakers accumulate less $YIELD (lower rate as campaign filled up)
- Time-weighted: longer staking = more $YIELD

This creates a natural early-investor bonus without needing explicit tiers.

---

## 7. $YIELD Floor Price

```
holderPool      = reportedHarvestUSD × 0.98
yieldFloorPrice = holderPool / totalYieldSupply
```

---

## 8. Harvest Redemption (Two-Step)

### Product Redemption

```
productClaim(user) = (userYield / totalYieldSupply) × totalProductUnits

Requires: productClaim(user) ≥ minProductClaim

Merkle leaf:
  leaf = keccak256(abi.encodePacked(user, seasonId, claimAmount))

Verification:
  MerkleProof.verify(proof, merkleRoot, leaf) == true
```

### USDC Redemption

```
usdcOut(user) = userYield × yieldFloorPrice
```

No minimum for USDC. $YIELD burned in both cases.

### USDC Funding Balance

```
usdcNeeded    = Σ usdcOut(i) for all USDC redeemers
productSold   = totalProductUnits - productRedeemed
usdcFromSales = productSold × pricePerUnit

usdcFromSales == usdcNeeded  (self-balancing)
```

---

## 9. Early Unstake Penalty (Linear)

```
elapsedRatio   = (timeNow - stakeStartTime) / seasonDuration
penaltyRate    = 1 - elapsedRatio
penaltyAmount  = stakedBalance(user) × penaltyRate   → BURNED
returnedAmount = stakedBalance(user) - penaltyAmount  → returned to user instantly
ALL un-withdrawn $YIELD for this position is FORFEITED (not minted)
```

Unstaking is always instant — the vault holds all staked tokens and can always return them.

To exit for cash, two options:
1. Sell $CAMPAIGN on DEX
2. Use the Campaign sell-back queue (see section 10)

---

## 10. Sell-Back Queue (FIFO)

Users who want to convert $CAMPAIGN back to payment tokens after unstaking.

```
Queue = [(user₁, amount₁), (user₂, amount₂), ...]

On new purchase by buyer (buy(tokenAddress, paymentAmount)):
  while paymentAmount > 0 AND queue is not empty:
    head = queue[0]
    // Calculate how much $CAMPAIGN the payment buys
    tokensFromPayment = paymentAmount / priceInToken
    fillAmount = min(tokensFromPayment, head.amount)

    // Pay the seller
    paymentToSeller = fillAmount × priceInToken
    transfer(paymentToken, paymentToSeller, head.user)

    // Burn seller's $CAMPAIGN, mint fresh to buyer
    burn(head.amount of $CAMPAIGN)
    mint(fillAmount of $CAMPAIGN to buyer)

    head.amount -= fillAmount
    paymentAmount -= paymentToSeller
    if head.amount == 0:
      queue.removeFirst()

  // Remaining payment mints new tokens (if under maxCap)
  if paymentAmount > 0:
    mint new $CAMPAIGN to buyer
```

Net supply effect: zero (seller's tokens burned, buyer gets fresh mint).

---

## 11. Deflationary Pressure

$CAMPAIGN is strictly deflationary:

```
finalSupply(season N) = initialSupply - Σ totalBurned(1..N)
```

Per-token value increases as supply shrinks:

```
valuePerToken(season N) = holderPool / activeStakers(season N)
```

---

## 12. Compounding Model

```
activeStakers(N) = activeStakers(N-1) × (1 - exitRate) - penaltyBurns(N)

returnPerToken(N) = holderPool / activeStakers(N)

cumulativeReturn(N) = Σ returnPerToken(k) for k = 1..N
breakeven when: cumulativeReturn(N) ≥ tokenPrice
```

---

## 13. Producer Sustainability

```
initialCapital    = tokenPrice × totalSupply
annualRevenue     = grossHarvest × 0.30
annualCosts       = maintenance + labor + pressing
annualNetCashflow = annualRevenue - annualCosts

sustainableYears = initialCapital / max(0, annualCosts - annualRevenue)
```

---

## 14. Parameters Summary

### Producer Sets

| Parameter | Constraint | Example |
|---|---|---|
| `pricePerToken` | 3-5yr payback recommended | $0.144 |
| `minCap` | any (in tokens) | 50,000 |
| `maxCap` | any (in tokens) | 100,000 |
| `fundingDeadline` | any | 90 days from launch |
| `seasonDuration` | ≥ 365 days | 365 days |
| `minProductClaim` | any (in product units) | 5 liters |
| `expectedYearlyReturnBps` | 1 ≤ bps ≤ 10_000 | 1000 (= 10%/year) |
| `expectedFirstYearHarvest` | > 0 product units | 5_000 L olive oil |
| `coverageHarvests` | 0 ≤ n ≤ harvestsToRepay | 3 (= 3 harvests pre-funded) |

### Protocol Constants (Fixed)

| Parameter | Value |
|---|---|
| `maxYieldRate` | 5 $YIELD/token/day (at 0% fill) |
| `minYieldRate` | 1 $YIELD/token/day (at 100% fill) |
| `yieldDecay` | linear: `max - (max - min) × fill%` |
| `penaltyCurve` | linear: `1 - elapsed/duration` |
| `producerShare` | 30% (off-chain) |
| `fundingFee` | 3% of every `buy()` gross inflow (non-refundable on buyback) |
| `harvestFee` | 2% of every `depositUSDC` (yield-side) |
| `usdcDepositWindow` | 90 days |
| `fractionalization` | 1,000 tokens per asset |

---

## 15. Producer Collateral (Pre-Paid Yield Reserve)

The producer's commitment to a yearly return is converted into an enforceable
on-chain guarantee by locking USDC in advance and letting the contract
auto-cover holder yield shortfalls for the first `coverageHarvests` seasons.

### Sizing

```
expectedYearlyUsdc   = totalRaised × expectedYearlyReturnBps / 10_000
harvestsToRepay      = ⌈10_000 / expectedYearlyReturnBps⌉              // ceiling
requiredCollateral   = coverageHarvests × expectedYearlyUsdc           // recommended floor
uncoveredTail        = max(0, harvestsToRepay − coverageHarvests)
riskScore (UI)       = uncoveredTail / harvestsToRepay                 // 0 = fully covered, 1 = no coverage
```

`totalRaised` is only finalized at activation; sizing is calculated against
`maxCap × pricePerToken` at creation time (worst-case) and re-anchored to
actual `totalRaised` once the campaign is Active. The producer can call
`lockCollateral` multiple times; the recommended target updates as the UI
re-derives `requiredCollateral` from current `totalRaised`.

### Shortfall Draw

For each season `s ∈ [1..coverageHarvests]`, after `usdcDeadline[s]` passes,
anyone may call `settleSeasonShortfall(s)`:

```
remainingDepositGross[s] = HarvestManager.remainingDepositGross(s)
                         = max(0, usdcOwed[s] - producer's deposits + 2% fee buffer)

availableCollateral      = collateralLocked − collateralDrawn

drawAmount               = min(remainingDepositGross[s], availableCollateral)

if drawAmount > 0:
   approve and call HarvestManager.depositUSDC(s, drawAmount) from the campaign
   collateralDrawn += drawAmount
   emit CollateralShortfallSettled(s, drawAmount, collateralDrawn)

mark seasonShortfallSettled[s] = true
```

The path is deterministic and permissionless. Edge cases:

- `remainingDepositGross[s] == 0` → no draw, only flag set. Idempotent.
- `availableCollateral == 0` → no draw, only flag set. Holders carry the gap.
- `availableCollateral < remainingDepositGross[s]` → partial draw, holders
  carry the remainder.
- `seasonId > coverageHarvests` → revert `OutOfCoverage`. The draw is only
  active for the committed window.
- `seasonId` already settled → revert `AlreadySettled`. Each season's shortfall
  draws at most once.

### Residual

After `coverageHarvests` seasons settle, any positive
`collateralLocked − collateralDrawn` stays in the contract. It does not
return to the producer (one-way commitment, see Tokenomics §Producer
Collateral). Distribution of the residual to current $CAMPAIGN holders is
deferred (TODO v3.1 — pro-rata bonus injected as a synthetic harvest through
HarvestManager). The locked-forever option is accepted as the conservative
default until the distribution mechanic is audited.

### Attack-surface notes (covered in `test/CollateralAttacks.t.sol`)

- **Fee-on-transfer collateral**: collateral is hard-coded to `factory.usdc()`,
  so a producer cannot lock a fee-on-transfer token to under-fund the reserve.
- **Re-entrancy on settlement**: `settleSeasonShortfall` is `nonReentrant`; the
  internal `depositUSDC` call is to `HarvestManager` only and does not
  invoke external callbacks.
- **Double-draw**: `seasonShortfallSettled[seasonId]` flag flips before any
  external transfer.
- **Premature settlement**: `block.timestamp > usdcDeadline[seasonId]` gate.
- **Out-of-coverage settlement**: `seasonId > 0 && seasonId ≤ coverageHarvests`.
- **Pause does not block holder protection**: `settleSeasonShortfall` is
  intentionally NOT `whenNotPaused` (consistent with `unstake` and `buyback`).
- **Producer rage-quit (never reports)**: `usdcDeadline[s]` is unset → settlement
  reverts with `SeasonNotReported`. Mitigation is out-of-band for v3
  (deferred to v3.1: deterministic `season-end + GRACE` deadline that lets
  anyone trigger a default report).
