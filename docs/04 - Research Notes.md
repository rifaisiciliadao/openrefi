---
tags:
  - openrefi
  - research
  - celo
status: reference
---
# Research Notes

## CELO Chain (as of March 2026)

- Migrated from L1 to **OP Stack L2** (March 2025)
- Sub-cent gas, 1-second blocks
- Fee abstraction: pay gas in ERC20 (cUSD, cEUR)
- Uses **EigenDA** for data availability (L1 fees effectively zero)
- Centralized sequencer (decentralized sequencing on roadmap)
- CELO token is both native currency and ERC20 (no wrapping needed)
- Key derivation path: `m/44'/52752'/0'/0`

## DeFi Infrastructure on CELO

| Category | Available |
|---|---|
| DEX | Uniswap V4, Velodrome, Ubeswap |
| Lending | Aave V3 |
| Oracles | Chainlink, RedStone, Pyth, Band, Supra |
| Stablecoins | USDC, USDT, cUSD, cEUR, eXOF, cREAL |
| Yield | Steer Protocol, Ichi, Merkl |

## Existing ReFi on CELO

- **Toucan** — tokenized carbon credits (TCO2)
- **GainForest** — rewards for forest protection (Ecocerts)
- **Loam** — marketplace for farming data, regenerative practices
- **No crowdfunding platform found** — this is a gap/opportunity

## Grant Opportunities

- **Climate Collective Treasury** — 4.7M CELO for climate projects
- **CeloPG** — up to 50,000 cUSD matching in Gitcoin rounds
- **Celo x Toucan Grants** — ReFi-specific acceleration
- Portal: [celopg.eco/programs](https://www.celopg.eco/programs)
- General: [docs.celo.org/build-on-celo/fund-your-project](https://docs.celo.org/build-on-celo/fund-your-project)

## Comparable Projects / Patterns

| Project | What they do | Relevant pattern |
|---|---|---|
| **Juicebox** | On-chain crowdfunding with ERC20 rewards | Campaign + token minting model |
| **Unisocks** | Burn ERC20 to redeem physical socks | Burn-to-redeem pattern |
| **Synthetix StakingRewards** | Reward distribution to stakers | Yield accrual math (accumulator pattern) |
| **Uniswap Merkle Distributor** | Merkle-proof based claiming | Harvest claim distribution |
