# GrowFi

GrowFi is a regenerative finance protocol for crowdfunding real-world agricultural production. Investors buy fractionalized tokens representing productive assets (e.g., olive trees), stake them to earn seasonal yield, and redeem harvest as physical product or USDC.

## About this repository

This repo documents the protocol design and specification. It is a living document — the protocol is being actively designed and refined before development begins.

**No code yet.** Everything in `/docs` is specification, not implementation.

## Documentation

| Document | Description |
|---|---|
| [00 - Overview](docs/00%20-%20Overview.md) | Vision, flow, key design decisions |
| [01 - Protocol](docs/01%20-%20Protocol.md) | Smart contract architecture, functions, events spec |
| [02 - App](docs/02%20-%20App.md) | Frontend architecture, subgraph schema |
| [03 - Tokenomics](docs/03%20-%20Tokenomics.md) | Two-token model, staking, yield, redemption |
| [04 - Research Notes](docs/04%20-%20Research%20Notes.md) | L2 ecosystem research, comparable projects |
| [05 - Math & Formulas](docs/05%20-%20Math%20%26%20Formulas.md) | Mathematical foundations for all contract mechanics |
| [06 - Simulation](docs/06%20-%20Simulation%20-%20Olive%20Oil%20Campaign.md) | 100-tree olive oil campaign simulation with numbers |

## How it works

```
$CAMPAIGN = the tree (permanent, productive, deflationary)
$YIELD    = the fruit (seasonal, consumable, burned on redemption)
```

1. **Buy** — Users purchase `$CAMPAIGN` tokens with any accepted ERC20 (USDC, WETH, etc.)
2. **Stake** — Stake `$CAMPAIGN` to earn `$YIELD` over the season (dynamic rate: early stakers earn more)
3. **Harvest** — Producer reports harvest value, keeps 30% for operations
4. **Redeem** — Burn `$YIELD` to claim physical product or USDC
5. **Restake** — Keep `$CAMPAIGN` staked for next season. As others exit, your share grows.

## Key features

- **Fractionalized ownership** — 1,000 tokens per asset, micro-investment from ~$0.14
- **Two-token model** — `$CAMPAIGN` (permanent seat) + `$YIELD` (seasonal harvest claim)
- **Dynamic yield rate** — 5x for first stakers, decays to 1x as campaign fills
- **Deflationary** — `$CAMPAIGN` supply can only decrease (penalties + exits)
- **Multi-token payments** — USDC, WETH, any ERC20 with fixed rate or Chainlink oracle pricing
- **On-chain first** — All state on-chain, indexed via The Graph subgraph, no backend
- **Verified impact** — Tree health tracked via Silvi.earth dMRV reports
- **Chain agnostic** — Deployable on any EVM-compatible L2

## License

MIT
