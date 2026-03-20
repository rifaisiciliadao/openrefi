---
tags:
  - openrefi
  - overview
status: defined
chain: CELO
---
# OpenReFi — Platform Overview

## Vision
A regenerative finance platform on **CELO** that enables crowdfunding campaigns for real-world agricultural products. Using a "millisimali" model (1,000 tokens per tree/asset), investors buy fractional positions in agricultural production. Tokens are staked to earn seasonal $YIELD, which is burned to claim physical product or USDC. Tree health is verified via **Silvi.earth** dMRV reports.

## Why CELO?
- **OP Stack L2** — sub-cent gas fees, 1-second block times
- **Fee abstraction** — users can pay gas in stablecoins (cUSD, cEUR)
- **ReFi-native ecosystem** — Toucan, GainForest, Loam already on CELO
- **Mobile-first** — MiniPay wallet, great for onboarding non-crypto users
- **Grant opportunities** — Climate Collective Treasury (4.7M CELO), CeloPG
- **Full EVM compatibility** — standard Solidity tooling
- **No crowdfunding platform on CELO yet** — clear gap

## Two-Token Model

```
$CAMPAIGN = the tree (permanent, productive, deflationary)
$YIELD    = the fruit (seasonal, consumable, burned on redemption)
```

## Millisimali Fractionalization

Each tree/asset is divided into **1,000 tokens**, making micro-investment accessible:

```
1 token       = 1/1,000th of a tree (~$0.14)
1,000 tokens  = 1 full tree (~$144)
10,000 tokens = 10 trees (~$1,440)
```

## Revenue Split

```
Gross Harvest → 30% producer (off-chain) → 70% reported → 2% protocol → 68.6% to holders
```

## High-Level Flow

```
1. BUY           → Users buy $CAMPAIGN tokens (millisimali fractions)
2. STAKE         → Stake $CAMPAIGN → earn $YIELD over the season
3. HARVEST       → Producer reports harvest value (after keeping 30%)
4. VERIFY        → Silvi.earth dMRV reports confirm tree health
5. REDEEM        → Burn $YIELD → choose: physical product OR USDC
6. RESTAKE       → Keep $CAMPAIGN staked → earn fresh $YIELD next season
7. COMPOUND      → As others exit, your share grows (deflationary)
```

## Key Design Decisions (Finalized)
- **Two tokens**: $CAMPAIGN (seat) + $YIELD (harvest claim)
- **Millisimali**: 1,000 tokens per tree/asset
- **$CAMPAIGN**: strictly deflationary, only minted during initial sale
- **$YIELD**: burned on every redemption (product or USDC)
- **Revenue split**: 30% producer (off-chain), 2% protocol fee, 68.6% to holders
- **Redemption**: Two-step — declare intent + fulfill (90-day USDC window)
- **Shipping**: paid separately by product redeemers
- **Verification**: Silvi.earth dMRV reports (informational, not tokenized)
- **Penalty**: Linear — earlier unstake = higher penalty, burned
- **Unstake queue**: FIFO, funded by new purchases
- **Min season**: 1 year
- **Protocol token**: None — possible points system in future

## Project Structure
- [[01 - Protocol]] — Smart contracts, on-chain architecture
- [[02 - App]] — Frontend, backend, off-chain infrastructure
- [[03 - Tokenomics]] — Two-token productive asset model
- [[04 - Research Notes]] — CELO ecosystem, references
- [[05 - Math & Formulas]] — Mathematical foundations for contracts
- [[06 - Simulation - Olive Oil Campaign]] — 100-tree olive oil campaign simulation
