# GrowFi

**Regenerative finance protocol for fractionalized agricultural production.**

GrowFi lets producers raise capital from a crowd of investors, who in turn receive a tokenized claim on the seasonal harvest — redeemable as physical product (e.g. olive oil) or as USDC. Each campaign is a self-contained set of contracts deployed by the protocol factory, with a deflationary equity token, dynamic-yield staking, seasonal harvest reporting, and a sell-back queue for secondary-market liquidity.

The first production use case is extra-virgin olive oil in Sicily, but the protocol is commodity-agnostic and chain-agnostic.

---

## How it works

```
┌───────────────────────┐       ┌───────────────────────────┐
│   CampaignFactory     │──────▶│       Campaign            │
│   (protocol registry) │       │   (sales, escrow,         │
└───────────────────────┘       │    sell-back, buyback)    │
                                 └────────────┬──────────────┘
                                              │ mints/burns
                                              ▼
                                 ┌───────────────────────────┐
                                 │     CampaignToken         │
                                 │   "The Seat" — ERC20Votes │
                                 └────────────┬──────────────┘
                                              │ staked into
                                              ▼
                                 ┌───────────────────────────┐
                                 │     StakingVault          │
                                 │  dynamic 1–5×/day yield   │
                                 │  multi-position, seasonal │
                                 └────────────┬──────────────┘
                                              │ mints
                                              ▼
                                 ┌───────────────────────────┐
                                 │       YieldToken          │
                                 │   "The Fruit" — ERC20     │
                                 └────────────┬──────────────┘
                                              │ burned for redemption
                                              ▼
                                 ┌───────────────────────────┐
                                 │     HarvestManager        │
                                 │  Merkle product claims +  │
                                 │  pro-rata USDC claims     │
                                 └───────────────────────────┘
```

### Lifecycle

1. **Funding** — Producer is onboarded by the protocol owner via `CampaignFactory.createCampaign(...)`. The factory deploys the full contract suite and wires circular dependencies through setter functions. Investors buy `$CAMPAIGN` tokens with any whitelisted payment token (fixed-rate, e.g. USDC, or Chainlink oracle-priced, e.g. WETH). Funds sit in escrow on the `Campaign` contract. Each buyer's payment is tracked per token for refund purposes.
2. **Activation** — As soon as `minCap` is reached, the campaign auto-activates: escrowed funds are released to the producer (minus a 2 % protocol fee), and the campaign enters the `Active` state.
3. **Failure → Buyback** — If `minCap` is not reached by `fundingDeadline`, anyone can trigger `Buyback`. Each investor can reclaim their exact original payment (per token) by burning their proportional `$CAMPAIGN`.
4. **Staking & seasons** — In the `Active` state the producer calls `startSeason(id)`. Holders stake `$CAMPAIGN` to earn `$YIELD`. The yield rate is **dynamic**: 5 `$YIELD/token/day` at 0 % vault fill, linearly decaying to 1 at 100 % fill (Synthetix-style O(1) accumulator). Unstaking before the end of the season incurs a linear penalty (tokens burned). Each stake creates an independent position (up to 50 per user, compactable).
5. **Sell-back queue** — Active holders can deposit `$CAMPAIGN` into a FIFO sell-back queue. New buyers automatically fill the queue first — supply stays flat (burn + mint net zero), and the seller receives the buyer's payment token at the same price.
6. **Harvest reporting** — At the end of each season the producer calls `reportHarvest(seasonId, valueUSD, merkleRoot, productUnits)`. The contract snapshots the total `$YIELD` supply and opens a 30-day claim window plus a 90-day USDC deposit window. 2 % protocol fee is deducted. Holders can either burn `$YIELD` for physical product (verified against the Merkle root) or for a pro-rata share of the USDC pool.
7. **Redemption** — Product redemption requires a valid Merkle proof of `(holder, seasonId, productAmount)` and enforces a minimum claim (e.g. 5 L). USDC claims are pro-rata against the producer's deposits — can be called repeatedly as the producer deposits more. After the deposit window closes the remaining USDC obligation is frozen.
8. **Next season** — Positions can be `restake`d into the next season (yield from the previous season is auto-claimed at restake). Unstake after the full season returns principal with no penalty.

---

## Contracts

| Contract | Role |
|---|---|
| `CampaignFactory.sol` | Owner-gated deployer & registry. Emergency pause/unpause per campaign. |
| `Campaign.sol` | Token sales, escrow, activation, buyback refunds, sell-back queue. |
| `CampaignToken.sol` | ERC20 + Permit + Votes. Mint gated to `Campaign`; burn to `Campaign` + `StakingVault` (penalties). |
| `StakingVault.sol` | Seasonal staking with multi-position, linear early-exit penalty, Synthetix accumulator. |
| `YieldToken.sol` | ERC20. Mint gated to `StakingVault`; burn to `StakingVault` + `HarvestManager`. |
| `HarvestManager.sol` | Harvest reporting, Merkle-based product redemption, pro-rata USDC redemption, producer deposit window. |

All contracts are Solidity 0.8.24, built against OpenZeppelin v5, compiled with `via_ir` and optimizer runs 200.

---

## Security

- **Access control** — every mint/burn and privileged function is gated by a concrete caller role (`OnlyCampaign`, `OnlyProducer`, `OnlyFactory`, `OnlyVaultOrHarvest`, …). Setter functions enforce one-time wiring.
- **ReentrancyGuard + Pausable** on every state-changing external function.
- **Oracle safety** — `latestRoundData` is validated for non-negative price, non-stale (`updatedAt` within 1 h) and `decimals ≤ 18` before being normalized.
- **Escrow isolation** — funding-phase payments sit in the Campaign contract; only `_activate()` (on min-cap success) or `buyback()` (on failure) can move them.
- **No admin withdrawal** on campaign escrows. No upgrade proxy. No rescue function.
- **2 % protocol fee** is taken on activation and on harvest report; never on post-activation secondary-market buys.

### Test suite (95 tests, all green)

| Suite | Tests | Purpose |
|---|---|---|
| `AuditTest` | 6 | Regression tests for issues surfaced during internal audit. |
| `CampaignTokenTest` | 7 | ERC20 + Votes + access control. |
| `YieldTokenTest` | 5 | ERC20 + mint/burn gating. |
| `SecurityTest` | 15 | Targeted security-surface coverage. |
| `IntegrationTest` | 5 | Happy-path multi-contract flows. |
| `E2ETest` | 1 | Ten-phase full-lifecycle simulation with multi-investor, multi-token, multi-season, real Merkle tree, pro-rata USDC deposits. |
| `RedTeamTest` | 39 | Adversarial attack attempts across every surface: forged Merkle proofs, oracle manipulation, unauthorized mint/burn, double-redemption, season replay, factory setter re-hijack, pause bypass, escrow drain, max-cap bypass, MEV-style sell-back gaming, USDC deadline bypass, griefing with max positions, dust-redemption, etc. Each passing test is a blocked exploit. |
| `FuzzTest` | 8 | Property-based tests (256 runs each, ~2k random inputs): buyback refund exactness, maxCap bound, sell-back supply preservation, unstake penalty monotonicity, yield linearity in stake amount, USDC pro-rata with partial deposits, escrow sums, purchased-tokens accounting. |
| `InvariantsTest` | 9 | Stateful fuzzing via Handler pattern (64 runs × 50 depth = ~28k random calls per run). Global invariants checked after every action: vault balance == totalStaked, sum(active positions) == totalStaked, currentSupply ≥ totalSupply with burn accounting, sum(pendingSellBack) == queue depth, escrow == sum(purchases) in Funding, campaign holds ≥ queued sell-back, currentSupply ≤ maxCap, state monotonic. |

Run `forge test --summary` to see the full matrix.

---

## Usage

```bash
# Install dependencies
forge install

# Build
forge build

# Run full test suite
forge test

# Run a specific attack scenario
forge test --match-test test_attack_forgeMerkleProof -vvv

# Format
forge fmt

# Gas snapshot
forge snapshot
```

Deployment script lives at `script/Deploy.s.sol`.

---

## Status

- Smart contracts implemented and tested: **95/95 passing** (unit + integration + E2E + adversarial + fuzz + stateful invariants).
- Internal security review: complete (fixes merged).
- External audit: **pending**. Do not deploy to mainnet until audit is finalized.
- Fork tests against mainnet USDC + Chainlink feeds: not yet implemented.
- Subgraph / indexer: out of scope of this repo (see event specs in `Campaign.sol`, `StakingVault.sol`, `HarvestManager.sol`).

---

## License

MIT — see [LICENSE](./LICENSE).
