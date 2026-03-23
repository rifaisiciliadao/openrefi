---
tags:
  - openrefi
  - overview
status: defined
---
# GrowFi — Platform Overview

## Vision
A regenerative finance platform that enables crowdfunding campaigns for real-world agricultural products. Using a fractionalization model (1,000 tokens per tree/asset), investors buy fractional positions in agricultural production. Tokens are staked to earn seasonal $YIELD, which is burned to claim physical product or USDC. Tree health is verified via **Silvi.earth** dMRV reports.

## Chain
- Deployable on **any EVM-compatible L2** (low gas fees required for micro-transactions)
- Uses standard ERC20, no chain-specific features
- Multi-token contributions: USDC, WETH, or any ERC20 (fixed rate or Chainlink oracle pricing)

## Two-Token Model

```
$CAMPAIGN = the tree (permanent, productive, deflationary)
$YIELD    = the fruit (seasonal, consumable, burned on redemption)
```

## Fractionalization

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
1. BUY           → Users buy $CAMPAIGN tokens with any accepted ERC20
2. STAKE         → Stake $CAMPAIGN → earn $YIELD over the season (multiple positions)
3. HARVEST       → Producer reports harvest value (after keeping 30%)
4. VERIFY        → Silvi.earth dMRV reports confirm tree health
5. REDEEM        → Burn $YIELD → choose: physical product OR USDC
6. RESTAKE       → Keep $CAMPAIGN staked → earn fresh $YIELD next season
7. COMPOUND      → As others exit, your share grows (deflationary)
```

## Key Design Decisions
- **Two tokens**: $CAMPAIGN (seat) + $YIELD (harvest claim)
- **Fractionalization**: 1,000 tokens per tree/asset
- **$CAMPAIGN**: strictly deflationary, only minted during initial sale
- **$YIELD**: burned on every redemption (product or USDC)
- **Multi-token payments**: USDC, WETH, any ERC20 — fixed rate or Chainlink oracle
- **Revenue split**: 30% producer (off-chain), 2% protocol fee, 68.6% to holders
- **Redemption**: Two-step — declare intent + fulfill (90-day USDC window)
- **Shipping**: paid separately by product redeemers
- **Verification**: Silvi.earth dMRV reports (informational, not tokenized)
- **Staking positions**: multiple independent positions per user, managed separately
- **Penalty**: Linear — earlier unstake = higher penalty, burned
- **Unstake queue**: FIFO, funded by new purchases
- **Dynamic yield rate**: 5→1 linear decay as campaign fills (protocol constant)
- **Min season**: 1 year
- **Architecture**: Fully on-chain + subgraph, no backend
- **Protocol token**: None — possible points system in future

## Project Structure
- [[01 - Protocol]] — Smart contracts, on-chain architecture, events spec
- [[02 - App]] — Frontend, subgraph schema
- [[03 - Tokenomics]] — Two-token productive asset model
- [[04 - Research Notes]] — L2 ecosystem research, references
- [[05 - Math & Formulas]] — Mathematical foundations for contracts
- [[06 - Simulation - Olive Oil Campaign]] — 100-tree olive oil campaign simulation
