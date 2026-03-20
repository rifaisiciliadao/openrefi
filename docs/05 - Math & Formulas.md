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

## 3. Token Purchase

```
tokensOut = amountPaid / pricePerToken
tokensOut = min(tokensOut, maxSupply - currentSupply)
refund    = amountPaid - (tokensOut × pricePerToken)
```

Purchase routing priority:

```
1. incomingFunds → drain unstaking queue (FIFO)
2. remainingFunds → contract / producer
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
returnedAmount = stakedBalance(user) - penaltyAmount  → returned or queued
ALL $YIELD FORFEITED
```

---

## 10. Unstaking Queue (FIFO)

```
Queue = [(user₁, owedAmount₁), (user₂, owedAmount₂), ...]

On new purchase (incomingFunds):
  while incomingFunds > 0 AND queue not empty:
    head = queue[0]
    fillAmount = min(incomingFunds, head.owedAmount)
    transfer(fillAmount, head.user)
    head.owedAmount -= fillAmount
    incomingFunds -= fillAmount
    if head.owedAmount == 0:
      queue.removeFirst()
```

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
| `maxSupply` | any | 100,000 |
| `seasonDuration` | ≥ 365 days | 365 days |
| `minProductClaim` | any (in product units) | 20 liters |

### Protocol Constants (Fixed)

| Parameter | Value |
|---|---|
| `maxYieldRate` | 5 $YIELD/token/day (at 0% fill) |
| `minYieldRate` | 1 $YIELD/token/day (at 100% fill) |
| `yieldDecay` | linear: `max - (max - min) × fill%` |
| `penaltyCurve` | linear: `1 - elapsed/duration` |
| `producerShare` | 30% (off-chain) |
| `protocolFee` | 2% of reported harvest |
| `usdcDepositWindow` | 90 days |
| `fractionalization` | 1,000 tokens per asset |
