---
tags:
  - openrefi
  - simulation
  - olive-oil
  - economics
  - dmrv
status: defined
---
# Simulation — 100 Olive Trees Campaign

## Base Parameters

| Parameter | Value |
|---|---|
| Trees | 100 |
| Yield per tree | 3 liters/year |
| Total harvest | 300 liters/year |
| Oil price | $20/liter |
| **Gross harvest value** | **$6,000/year** |
| Fractionalization | 1,000 tokens per tree |
| **Token supply** | **100,000 $OLV** |
| Token price | $0.144 |
| Season duration | 1 year |
| Min product claim | 5 liters |

## Revenue Split

```
PHYSICAL HARVEST: 300 liters ($6,000)
│
├─ 30% PRODUCER: 90 liters ($1,800)
│
└─ 70% REPORTED: 210 liters ($4,200)
   ├─ 2% PROTOCOL FEE: $84
   └─ 98% TO HOLDERS: 205.8 liters ($4,116)
```

## Fractionalized Access

| Investment | Tokens | Trees | Yearly product | Can claim product? |
|---|---|---|---|---|
| $0.14 | 1 | 0.001 | 0.002L | No → USDC only |
| $14.40 | 100 | 0.1 | 0.2L | No → USDC only |
| $144 | 1,000 | 1 | 2.1L | No → USDC only |
| $360 | 2,500 | 2.5 | 5.1L | Yes ✓ (≥5 liters) |
| $1,440 | 10,000 | 10 | 20.6L | Yes ✓ |
| $14,400 | 100,000 | 100 | 205.8L | Yes ✓ |

---

## Dynamic Yield Rate Simulation

The yield rate decays as the campaign fills:

```
yieldRate = 5 - 4 × (totalStaked / 100,000)
```

### Staking Fill-Up Scenario

Assume the campaign fills gradually over 6 months, then stays full for the remaining 6 months:

| Month | Event | Total Staked | Fill % | yieldRate |
|---|---|---|---|---|
| 0 | Launch | 0 | 0% | 5.0 |
| 1 | Early adopters | 10,000 | 10% | 4.6 |
| 2 | Growing | 25,000 | 25% | 4.0 |
| 3 | Momentum | 50,000 | 50% | 3.0 |
| 4 | Filling | 70,000 | 70% | 2.2 |
| 5 | Nearly full | 90,000 | 90% | 1.4 |
| 6 | Full | 100,000 | 100% | 1.0 |
| 7-12 | Steady | 100,000 | 100% | 1.0 |

### Early Staker vs Late Staker Comparison

**Alice — Day 1 staker (1,000 tokens, 1 tree)**
Stakes when campaign is nearly empty. Earns at high rates.

```
Month 1: rate ~4.8 avg → 1,000 × 4.8 × 30 = 144,000 $YIELD
Month 2: rate ~4.3 avg → 1,000 × 4.3 × 30 = 129,000 $YIELD
Month 3: rate ~3.5 avg → 1,000 × 3.5 × 30 = 105,000 $YIELD
Month 4: rate ~2.6 avg → 1,000 × 2.6 × 30 = 78,000 $YIELD
Month 5: rate ~1.8 avg → 1,000 × 1.8 × 30 = 54,000 $YIELD
Month 6: rate ~1.2 avg → 1,000 × 1.2 × 30 = 36,000 $YIELD
Month 7-12: rate 1.0   → 1,000 × 1.0 × 180 = 180,000 $YIELD

Alice total: ~726,000 $YIELD (365 days staked)
```

**Bob — Month 6 staker (1,000 tokens, 1 tree)**
Stakes when campaign is full. Earns at minimum rate only.

```
Month 7-12: rate 1.0 → 1,000 × 1.0 × 180 = 180,000 $YIELD

Bob total: 180,000 $YIELD (180 days staked)
```

**Harvest share comparison:**

```
Alice: 726,000 $YIELD
Bob:   180,000 $YIELD
Total: ~906,000 (just these two for illustration)

Alice's share: 726/906 = 80.1%
Bob's share:   180/906 = 19.9%

Same number of tokens, but Alice gets 4x Bob's harvest share.
```

Alice benefits from:
1. Higher yield rate (campaign was emptier when she joined)
2. Longer staking duration (365 vs 180 days)

---

### Full Campaign $YIELD Distribution

With 100,000 tokens filling gradually over 6 months:

```
Approximate total $YIELD minted across all stakers:

Early stakers (first 10,000 tokens, 12 months, avg rate ~3.5):
  10,000 × 3.5 × 365 = 12,775,000 $YIELD

Mid stakers (next 40,000 tokens, 9 months, avg rate ~2.5):
  40,000 × 2.5 × 270 = 27,000,000 $YIELD

Late stakers (next 40,000 tokens, 7 months, avg rate ~1.2):
  40,000 × 1.2 × 210 = 10,080,000 $YIELD

Final stakers (last 10,000 tokens, 6 months, rate ~1.0):
  10,000 × 1.0 × 180 = 1,800,000 $YIELD

Total $YIELD: ~51,655,000
```

### Harvest Share by Staker Tier

Holder pool: $4,116

| Tier | Tokens | $YIELD | Share % | Harvest $ | Per-token $ |
|---|---|---|---|---|---|
| Early (10%) | 10,000 | 12,775,000 | 24.7% | $1,016.69 | $0.1017 |
| Mid (40%) | 40,000 | 27,000,000 | 52.3% | $2,152.67 | $0.0538 |
| Late (40%) | 40,000 | 10,080,000 | 19.5% | $802.62 | $0.0201 |
| Last (10%) | 10,000 | 1,800,000 | 3.5% | $144.06 | $0.0144 |

**Early stakers earn 7x more per token than last stakers!**

```
Early staker ROI (season 1): $0.1017 / $0.144 = 70.6%
Last staker ROI (season 1):  $0.0144 / $0.144 = 10.0%
```

---

## 5-Year Simulation (Early Staker, 10% exit/year)

Using an early staker with 1,000 tokens ($144 invested):

```
Year 1: 100,000 staked, early bird advantage
  Share: ~1.25% (boosted by dynamic rate)
  Return: $51.45
  ROI: 35.7%

Year 2: 81,000 staked (exits + penalties)
  Now rate is flat (1.0) for everyone, but fewer stakers
  Share: 1,000/81,000 = 1.23%
  Return: $50.69
  ROI: 35.2%

Year 3: 72,900 staked
  Share: 1.37%
  Return: $56.39
  ROI: 39.2%

Year 4: 65,610 staked
  Share: 1.52%
  Return: $62.56
  ROI: 43.4%

Year 5: 59,049 staked
  Share: 1.69%
  Return: $69.56
  ROI: 48.3%
```

| Year | Return | Cumulative | Cumulative ROI |
|---|---|---|---|
| 1 | $51.45 | $51.45 | 35.7% |
| 2 | $50.69 | $102.14 | 70.9% |
| 3 | $56.39 | $158.53 | **110.1%** |
| 4 | $62.56 | $221.09 | 153.5% |
| 5 | $69.56 | $290.65 | 201.8% |

**Early staker breakeven: ~year 2.8** (faster than the 3.5yr target because of the dynamic rate bonus)

---

## Late Staker 5-Year Comparison

A last-wave staker (1,000 tokens, joined at month 6):

| Year | Return | Cumulative | Cumulative ROI |
|---|---|---|---|
| 1 | $14.41 | $14.41 | 10.0% |
| 2 | $50.69 | $65.10 | 45.2% |
| 3 | $56.39 | $121.49 | 84.4% |
| 4 | $62.56 | $184.05 | 127.8% |
| 5 | $69.56 | $253.61 | 176.1% |

**Late staker breakeven: ~year 3.6** — still profitable, just slower. From year 2 onward they earn the same as everyone else (flat rate, proportional to stake).

---

## dMRV — Tree Health Verification

Tree health and environmental impact tracked via **Silvi.earth**:

- dMRV (Digital Measurement, Reporting and Verification) reports published annually
- Covers: tree health, growth metrics, carbon sequestration, biodiversity
- Reports are informational — NOT tokenized
- Published on campaign page + IPFS hash on-chain
- Provides transparency: investors verify trees are real and healthy

---

## Producer Economics

```
Initial capital: 100,000 × $0.144 = $14,400

Annual revenue:
  Harvest share (30%): 90 liters × $20 = $1,800

Annual costs:
  Tree maintenance:     $1,500
  Harvesting labor:     $1,000
  Pressing/bottling:    $800
  Silvi.earth reports:  $200
  ─────────────────────
  Total:                $3,500/year

Annual deficit: $3,500 - $1,800 = $1,700
Runway: $14,400 / $1,700 = ~8.5 years
```

---

## USDC Redemption Funding

```
If 30% choose USDC, 70% choose product:
  USDC needed: 30% × $4,116 = $1,234.80
  Product shipped: 70% × 205.8 = 144.06 liters
  Remaining: 61.74 liters
  Producer sells: 61.74 × $20 = $1,234.80 → covers USDC ✓
```

---

## Protocol Revenue

```
Per campaign/year: 2% × $4,200 = $84

At scale:
  100 campaigns: $8,400/year
  1,000 campaigns: $84,000/year
```

---

## Key Takeaways

1. **$0.144/token** — micro-accessible, anyone can participate
2. **Early stakers earn 7x more per token** than last-wave stakers in season 1
3. **Early staker breakeven: ~2.8 years** (vs 3.6 years for late stakers)
4. **From year 2 onward**, all stakers earn equally — the early bonus is a one-time advantage
5. **Deflationary compounding**: loyal 5-year stakers hit ~200% return
6. **Dynamic yield rate** creates natural FOMO without artificial scarcity

### The Value Proposition
```
Early investor: "I stake early at 5x yield rate.
                 Season 1, I earn 70% ROI.
                 By year 3, I've broken even.
                 By year 5, I've doubled my money."

Late investor:  "I join at 1x rate, earn 10% in season 1.
                 But from year 2 onward I earn the same as everyone.
                 I still break even by year 3.6."

Producer:       "I raise $14,400 upfront, keep 30% of harvest.
                 Sustainable for 8+ years.
                 Silvi.earth verifies my trees are healthy."
```
