---
tags:
  - growfi
  - tokenomics
  - yield
  - staking
  - grow-token
status: implemented
---
# Tokenomics — Token design, fees & yield

GrowFi has **two layers** of value capture, deployed together but conceptually independent:

| Layer | Tokens | Scope | Backed by |
|---|---|---|---|
| **L1 — per campaign** | `$CAMPAIGN` + `$YIELD` (one pair per campaign) | One real-world productive asset (e.g. an olive grove, a vineyard) | The producer's harvest + collateral lock |
| **L2 — protocol-wide** | `GROW` (single ERC20 across the protocol) | The whole catalogue of campaigns | The GrowFi Treasury (multi-stablecoin + CampaignTokens) |

Layer 1 is what the producer launches. Layer 2 is the protocol's own token, minted as a free participation reward whenever someone buys into _any_ campaign. A 30/70 fee split feeds the Treasury, which backs GROW with on-chain assets and pays USDC rewards to GROW stakers. **Producer payouts are unchanged** — every fee captured by the protocol comes out of the protocol's slice, never the producer's.

---

## L1 — Per-campaign two-token model

Each campaign has two tokens with distinct roles:

### `$CAMPAIGN` — the staking token ("the seat")
- ERC20 + ERC20Votes
- Bought from the campaign contract at a producer-set price
- Represents a **permanent productive position** in the campaign
- Staked → it produces `$YIELD` every season
- Not staked → earns nothing
- Tradable on DEX, can be burned for permanent exit
- Mintable by the Campaign contract only (during initial sales)
- **Strictly deflationary** — supply can only decrease

### `$YIELD` — the harvest token ("the fruit")
- ERC20, transferable
- Earned by staking `$CAMPAIGN` over a season
- Represents a claim on that season's harvest
- Burned to redeem product OR USDC
- Fresh `$YIELD` minted each season from staking
- Mintable by `GrowfiStakingVault` only

### Mental model
```
$CAMPAIGN = the tree (permanent, productive)
$YIELD    = the fruit (seasonal, consumable)

You don't cut down the tree to eat the fruit.
```

### Fractionalisation

Each productive asset is divided into tokens (max cap), with each token = a fraction of the underlying asset. `1 token = 1/maxCap` of the productive position.

### Dynamic yield rate

The yield rate decreases as more `$CAMPAIGN` gets staked — a built-in early-staker bonus.

```
yieldRate = 5 - 4 × (totalStaked / maxSupply)

  0% staked → 5.0×    (fastest accrual for first stakers)
 25% staked → 4.0×
 50% staked → 3.0×
 75% staked → 2.0×
100% staked → 1.0×    (baseline)
```

- Recalculated on every stake / unstake
- Already-earned `$YIELD` is locked in at the rate of the moment it was minted
- No producer input — same curve for every campaign

### Early-unstake penalty (linear)

```
penalty% = 100% - (timeStaked / seasonDuration × 100%)
```

| Unstake at | Penalty | Kept |
|---|---|---|
| 1 month (≈ 8%)   | 92% burned | 8%  |
| 3 months (25%)   | 75% burned | 25% |
| 6 months (50%)   | 50% burned | 50% |
| 9 months (75%)   | 25% burned | 75% |
| 12 months (100%) | 0%         | 100% + yield |

Yield accrues per second via a rate × elapsed-time accumulator (per-token reward tracker). Your harvest share at season-close = `your $YIELD` ÷ `total $YIELD minted that season`.

### Producer collateral (pre-paid yield reserve)

Producer-locked USDC sits in the campaign as a reserve pool that automatically covers holder yield shortfalls for the first `coverageHarvests` seasons. See `01 - Protocol.md §Producer Collateral` for the lifecycle and `05 - Math & Formulas.md §15` for the formulas. Three numbers visible in the UI:

- `harvestsToRepay = 10_000 / expectedYearlyReturnBps` — how many harvests of yield equal the original investment
- `coverageHarvests` — how many of those the producer pre-funds
- `tail = harvestsToRepay − coverageHarvests` — the residual delivery risk the holder carries

The collateral is **one-way**: once locked, it is drawn down by holder shortfalls or stays locked forever, never returns to the producer. This converts "expected yield" from a soft promise into an enforceable on-chain commitment.

### Producer parameters (per-campaign, set at create)

- `pricePerToken` — fixed USD price per token
- `minCap` (soft cap) — tokens to sell for the campaign to activate
- `maxCap` — hard cap on supply
- `fundingDeadline` — soft cap deadline; can be extended later via `setFundingDeadline`
- `seasonDuration` — minimum 30 days on mainnet (configurable testnet floor)
- `minProductClaim` — min product units to ship physical (e.g. 5 L)
- `expectedAnnualHarvestUsd` (USD, 1e18) — the producer's monetary commitment per year
- `expectedAnnualHarvest` (units, 1e18) — the matching physical-units commitment per year (price/unit derived in UI)
- `firstHarvestYear` — calendar year of harvest 1
- `coverageHarvests` — how many seasons the producer pre-funds via `lockCollateral`

### Per-campaign smart contracts

| Contract | Role |
|---|---|
| `GrowfiCampaign` | Funding escrow, sales, buyback-on-failure, sell-back queue, state machine |
| `GrowfiCampaignToken` | ERC20 + Votes, mint/burn gated to Campaign + StakingVault penalty burns, deflationary |
| `GrowfiStakingVault` | Stake `$CAMPAIGN`, mint `$YIELD` via per-token rate × time accumulator, linear penalty |
| `GrowfiYieldToken` | ERC20, mint by Vault, burn by Vault + HarvestManager |
| `GrowfiHarvestManager` | Harvest reporting, two-step redemption (Merkle product + USDC), 2% protocol fee |

---

## L2 — Protocol-wide GROW token

GROW is the protocol's utility token. **It is not a governance token, not a presale token, and not a producer liability.** It exists to let any participant in any campaign hold a single asset whose value tracks the whole catalogue.

### Why it exists

- **Today (without GROW):** every campaign is its own silo. You can be exposed to one campaign at a time. There is no aggregate position on "GrowFi as a whole".
- **With GROW:** every buy on any campaign mints free GROW to the buyer. A 30% slice of every protocol fee feeds the GROW Treasury, which buys CampaignTokens on the buyer's behalf. The Treasury earns harvest yield and pays USDC to GROW stakers. GROW gives one-shot exposure to the entire ecosystem.

### Genesis + supply

- **No presale, no public sale, no LP seed by the protocol.** Liquidity emerges organically from direct buys + secondary markets.
- `GrowfiToken.initialize` mints a single `genesisAmount` to a configurable `genesisRecipient` at deploy time (typically a multisig that distributes off-chain). The current testnet bootstrap uses 1,000,000 GROW.
- All subsequent emission is gated by `GrowfiMinter` (campaign participation rewards) or by `GrowfiToken.buy` (direct stablecoin sale).
- GROW is `ERC20` + `ERC20Burnable` (anyone can burn their own) + Initializable (deployed behind a `TransparentUpgradeableProxy`).

### Bonding-curve emission (free participation reward)

`GrowfiMinter` is the only path that mints GROW for free. It hooks into every campaign's `buy()` and decides how much GROW to award based on:
1. The campaign's current state (`Pending` / `Active` / `Failed`).
2. The cumulative buy volume of the campaign (`cumBuyVolumeUsd`, monotonically growing — sellback does NOT reset it).
3. A 3-tier step function over that cumulative volume.

#### Bonding-curve tiers (defaults)

| Tier | Cumulative buy volume range | GROW per $1 of buy |
|---|---|---|
| 1 | `[0, softcap × price]` | `1.0×` (`tier1RateBps = 10_000`) |
| 2 | `[softcap × price, threshold2]` | `0.7×` (`tier2RateBps = 7_000`) |
| 3 | `[threshold2, ∞)` | `0.4×` (`tier3RateBps = 4_000`) |

`threshold2 = (softcap + (maxcap - softcap) × tier2to3ThresholdBps / 10_000) × pricePerToken`

All four BPS are factory-settable by the multisig via `factory.setGrowfiBondingCurve`. Each must be `≤ 10_000`.

The curve is **monotonic on cumulative buy volume**: a buy → sellback → buy loop earns less GROW with each iteration, because sellback doesn't roll the cumulative back. This is the primary anti-farm property.

#### Pre-softcap escrow

Before a campaign reaches its soft cap (status `Pending`), GROW is **escrowed per `(campaign, buyer)`** instead of minted directly:

- `GrowEscrowed(campaign, buyer, amount)` event records the promised allocation.
- The buyer holds nothing transferable — escrow is non-transferable.
- When the campaign reaches its soft cap (`Campaign._activate` calls `Minter.onSoftCapReached`), status flips to `Active` and escrows become claimable via `Minter.claimEscrow(campaign)`. The buyer pulls — the protocol does not push.
- If the campaign instead expires below soft cap and someone calls `Campaign.triggerBuyback` (which calls `Minter.onBuyback`), status flips to `Failed` and **all escrow for that campaign is permanently voided**. No GROW is ever minted for a failed campaign.

This is the second anti-farm property: a failed campaign produces no GROW even if it had heavy intermediate buys.

#### Post-softcap direct mint

Once a campaign is `Active`, every subsequent buy mints GROW **directly to the buyer** (still subject to the bonding-curve tier the cumulative volume has reached). No escrow, no waiting.

#### Excluded buyers (no double-counting)

`GrowfiTreasury` (and any other address listed in `Minter.excludedFromMint`) **bypasses GROW emission entirely**: no GROW is minted to them on their buys, AND their volume does NOT advance the bonding curve. They donate liquidity without consuming the discount tiers, so real participants stay rewarded.

### Direct buy with stablecoins

Beyond participation rewards, anyone can mint fresh GROW by paying any allowlisted stablecoin to `GrowfiToken.buy(paymentToken, paymentAmount, maxPriceAccepted)`. The function lives inside the GROW token contract itself — there is no separate sale contract.

#### Pricing

```
referencePrice (USD-18-dec per GROW) = floor || cachedReference
salePrice = referencePrice × (BPS + markupBps) / BPS

Where:
  floor             = GrowfiTreasury.intrinsicFloorPrice()
  cachedReference   = GrowfiToken.referencePrice (seeded at deploy, refreshed on every buy)
  markupBps         = factory-settable, default 1_000 (10%), capped at MAX_MARKUP_BPS = 5_000 (50%)
```

The buyer passes `maxPriceAccepted` for slippage protection; the call reverts with `PriceExceedsMax` if `salePrice > maxPriceAccepted`.

#### Floor formula

```
intrinsicFloorPrice =
   (Σ stablecoinBalance_i × stablecoinScale_i  +  Σ CampaignTokenBalance_j × pricePerToken_j)
   ────────────────────────────────────────────────────────────────────────────────────────────
                              circulating GROW (= totalSupply - treasury's own balance)
```

- `stablecoinScale_i = 10^(18 - decimals_i)` — set by the multisig when the stablecoin is added (e.g. `1e12` for USDC/USDT, `1` for DAI).
- 1:1 USD-peg assumption in v1. If a stablecoin de-pegs, the multisig calls `Treasury.removeAcceptedStablecoin` as a circuit breaker — instantly removing it from the floor calculation and blocking new buys with that token.
- The treasury's own GROW is **excluded from the divisor** so it doesn't dilute the per-token backing.

#### Bootstrap behaviour

- At deploy, `initialReferencePrice` (seeded by deploy script, e.g. $0.10) is the fallback when the treasury has no holdings yet (`floor = 0`).
- Every successful buy that priced off `floor > 0` updates `referencePrice = floor`, so the cache always reflects the most recent on-chain reality.
- The sale only stops with `NoFloorAvailable` if BOTH `floor == 0` AND `referencePrice == 0` — practically never after bootstrap.

#### Anti-dilution

By construction the direct sale is non-dilutive: each transaction either keeps the floor flat or pushes it up — never down. The 10% markup is what makes it strictly accretive: every buy adds `paymentAmount` of stablecoin to the treasury and `paymentAmount × scale × 1e18 / salePrice` GROW to circulation, and the markup means the new ratio is ≥ the old.

#### Worked example

```
State:        treasury holds $5,000 USDC, circulating GROW = 10,000.
              floor = $5,000 / 10,000 = $0.50/GROW.

User intent:  buy GROW for $55 USDC, markup = 10%.

salePrice   = $0.50 × 1.10                    = $0.55/GROW
GROW out    = $55 × 1e6 × 1e12 × 1e18 / 0.55e18 = 100 GROW
Treasury    = $5,055 USDC
Circulating = 10,100 GROW
New floor   = $5,055 / 10,100 = $0.5005/GROW   (≥ $0.50 ✓)
```

Net for the buyer: pays a 10% premium, but the same buy lifts the floor for everyone (themselves included), and they hold a token with a claim on the protocol's growing aggregate harvest income.

### Treasury — what it holds and how it pays

`GrowfiTreasury` is the protocol-owned reserve backing GROW. It holds three asset classes:

1. **Allowlisted stablecoins** (multisig-curated): USDC, USDT, DAI, … each with a scale factor. Used both for the floor calc and for direct-buy proceeds.
2. **CampaignTokens** of campaigns the protocol has invested in (the _tracked_ set, see below).
3. **The treasury's own GROW** (excluded from circulating in the floor calc).

Two dynamic sets, both controlled by the factory multisig:

| Set | Purpose | Setter |
|---|---|---|
| `_acceptedStablecoins` | Stablecoins valid for direct buys + floor calc | `factory.addGrowfiTreasuryStablecoin` / `removeGrowfiTreasuryStablecoin` |
| `_trackedCampaigns` | Campaigns the Treasury invests in / harvests from | `factory.addGrowfiTreasuryTrackedCampaign` / `removeGrowfiTreasuryTrackedCampaign` |

**Treasury tracking is NOT auto-registered on `createCampaign`**, on purpose. Auto-registration would expose the Treasury to a drain vector via spammed/malicious campaigns. The multisig must explicitly track each campaign after vetting it (KYC, collateral lock, reputation). The Minter side stays open so participants always earn GROW; only the Treasury investment side is gated. The same multisig curates the public-discovery `hiddenCampaigns` flag, which is a pure UI filter and has no on-chain effect.

#### Canonical USDC (decoupled from the allowlist)

`Treasury.canonicalUsdc` is snapshotted from `factory.usdc()` at init. It is **independent** of the dynamic `_acceptedStablecoins` allowlist. Even if the multisig revokes USDC from the allowlist (depeg circuit breaker — disabling new direct buys with USDC), the harvest payout path (`claimUsdcAndDistribute`) keeps working because campaigns always pay harvest in this canonical token.

#### Harvest claim path

The Treasury earns USDC by holding CampaignTokens of tracked campaigns and going through the standard yield flow:

```
1. allocateToCampaign(campaign, paymentToken, amount)        — multisig
   Treasury approves the campaign and calls Campaign.buy() in `paymentToken`.
   Treasury now holds CampaignTokens of `campaign`.

2. stakeOnCampaign(campaign, amount)                         — multisig
   Treasury stakes its CampaignTokens in StakingVault, opens a position.

3. claimYieldFromCampaign(campaign, positionId)              — multisig
   Treasury claims accrued $YIELD.

4. commitUsdcRedeem(campaign, seasonId, yieldAmount)         — multisig
   Treasury burns its $YIELD → registers a USDC commit on HarvestManager.

5. claimUsdcAndDistribute(campaign, seasonId)                — PERMISSIONLESS
   Anyone pays gas. Treasury pulls USDC from HarvestManager, splits:
     • stakerRewardBps (default 80%) → forwarded to GrowfiStakingPool
                                       + Pool.notifyReward(amount)
     • remainder        (default 20%) → retained for compounding (stays in Treasury)
```

Step 5 being permissionless lets keepers, the frontend, or any concerned holder push yield through the system without waiting on the multisig.

#### Cross-tracked allocation (opt-in automation)

`allocateAcrossTracked(paymentToken, totalAmount)` spreads a budget equally across all tracked, Active, not-yet-full campaigns in a single call. Two safety properties:

- **`onlyFactory` + `automationEnabled` switch.** Default is OFF. The multisig flips `setGrowfiTreasuryAutomationEnabled(true)` to enable it, OFF to kill. This is **not** a permissionless mass-allocate — only the multisig can trigger.
- **Per-campaign try/catch.** A single bad campaign (paused, upgraded weirdly, reverting) cannot DOS the whole batch. Failed allocations fall through; successful ones proceed. The event `AcrossTrackedAllocated` reports the actually-allocated amount and the success count.

#### Failed-campaign recovery

If a tracked campaign fails to reach its soft cap and enters Buyback, `factory.buybackGrowfiTreasury(campaign, paymentToken)` calls `Campaign.buyback(paymentToken)` from the Treasury, burns its CampaignTokens, and recovers the original NET payment (97% of what was spent — funding fee is non-refundable by design).

#### Burn-to-redeem (the price floor)

Any GROW holder can call `Treasury.redeem(growAmount)`:

1. Treasury pulls `growAmount` from the holder via `transferFrom` and burns it.
2. For every accepted stablecoin, sends `holding × growAmount / circulating` to the holder.
3. For every tracked CampaignToken, sends `holding × growAmount / circulating` to the holder.

Result: market price cannot stay below the per-token treasury value without arbitrage closing the gap. Pure burn-to-redeem (no redemption windows) is the v1 default — simpler, no run-on-the-bank dynamics worth designing around at current scale.

#### Rescue (multisig-only, accidentally-sent tokens)

`factory.rescueGrowfiTreasuryToken(token, to, amount)` recovers ERC20s that landed in the Treasury by mistake. Hard-coded protections forbid rescuing **(a)** any accepted stablecoin, **(b)** GROW itself, **(c)** any tracked CampaignToken — the three asset classes that back the floor.

### Fee splitter — the 30/70 routing

`GrowfiFeeSplitter` sits in the `protocolFeeRecipient` slot of every campaign and HarvestManager. It is a passive multi-token router:

- Anyone can call `flushToken(token)` (or `flushMany([…])`) on it.
- The current balance of `token` is split:
  - `treasuryBps` (default 30% = `3_000`, capped at `MAX_TREASURY_BPS = 5_000`) → `GrowfiTreasury`
  - `BPS - treasuryBps` (default 70%) → operations multisig
- Permissionless flush makes it a public good — keepers / cron jobs / the frontend can settle it.
- Multi-token by design: campaigns may collect fees in USDC, USDT, DAI, or any stablecoin their producer accepted. The splitter holds whatever balance arrives.
- No `rescue` function needed — the flush works for **any** ERC20, so "stuck" tokens are one permissionless call away from being routed.

### Staking pool — GROW stakers earn USDC

`GrowfiStakingPool` lets GROW holders stake to earn a continuous USDC stream funded by the Treasury's harvest distributions.

#### Mechanics

- **Reward source.** `Treasury.claimUsdcAndDistribute` forwards `stakerRewardBps` (default 80%) of every harvest claim to the pool and calls `notifyReward(amount)`. The remaining 20% stays in the Treasury for compounding (can be allocated into more CampaignTokens, raising the floor).
- **Distribution.** Each `notifyReward` triggers a fresh distribution period of length `rewardsDuration` (default 30 days). If a period is already in flight, the unspent remainder is folded into the new amount and the rate is recomputed over a fresh 30 days. The accumulator is `rewardPerTokenStored + (timeSlice × rewardRate × 1e18) / effectiveTotalStaked`, settled lazily on every user action.
- **No lockup.** `withdraw()` is always available. The "cost" of exiting is the multiplier reset, not a time lock.

#### Time-in-pool multiplier

The user's effective balance is `rawBalance × multiplierBps / 10_000`. The accumulator's denominator is `effectiveTotalStaked` (sum of effective balances). This boosts long-term stakers without paying them more nominal USDC than the system has.

```
multiplierBps = 10_000 + min((now - streakStart) / 365 days, 1.0) × 10_000

  Day   0  →  10_000 bps  (1.0×, baseline)
  Day  91  →  12_500 bps  (1.25×)
  Day 182  →  15_000 bps  (1.50×)
  Day 273  →  17_500 bps  (1.75×)
  Day 365+ →  20_000 bps  (2.0×, capped at MAX_MULTIPLIER)
```

Streak rules (each enforced by `_settleAndRefresh` which is invoked on every user action):

| Action | Effect on streak |
|---|---|
| First stake (balance was 0) | `streakStart = now`, multiplier = 1.0× |
| Adding to an existing stake | Streak preserved |
| `claim()` (just claim, don't withdraw) | Streak preserved; multiplier may bump up |
| `withdraw(any amount)` (partial or full) | Streak **RESETS** to 1.0× |
| `exit()` | Streak fully cleared (balance → 0) |

The stored multiplier is **refreshed on every user action** (stake / withdraw / claim), not by an on-chain "poke" job. Between actions the on-chain multiplier stays fixed even if the streak crosses a threshold time-wise. The view `previewMultiplier(user)` returns the live ramped value the frontend can show; the user must take an action to apply it. This keeps the math conserving (no surprise dilution of other stakers' shares from a time-only event).

#### Pending-for-first-staker

If `Treasury.notifyReward` fires while the pool is empty (no stakers yet), the amount accumulates in `pendingForFirstStaker` instead of being lost. The first stake flushes that bucket and starts a fresh `rewardsDuration` period. This is what makes the "deploy now, GROW staking lives, even with no stakers yet" path safe.

### GROW utility surface

| Capability | Status | What it does |
|---|---|---|
| **Burn to redeem** | v1 (live) | Burn GROW for pro-rata of all Treasury holdings (stablecoins + CampaignTokens). Mathematical floor. |
| **Stake for USDC stream** | v1 (live) | Stake GROW in `GrowfiStakingPool`, earn USDC funded by Treasury harvest distributions. |
| **Direct buy** | v1 (live) | Pay any allowlisted stablecoin → mint GROW at floor × (1 + markup). Non-dilutive. |
| **No governance** | by design | No DAO, no proposals, no votes. Multisig-controlled parameters via `factory` forwarders. |
| Fee discount on campaign buys | v2 (deferred) | Holders pay reduced funding fee. |
| Harvest Box | v2 (deferred) | Periodic claim of physical product samples drawn from the Treasury's harvest holdings. |

### Why intrinsic value grows over time

1. **Treasury compounds.** It holds USDC + CampaignTokens earning harvest yield. Per-token backing grows as more campaigns mature.
2. **Supply tracks volume.** GROW supply only grows when protocol volume grows. The same volume that mints GROW also funds the Treasury (30% of every fee). Supply and backing scale together.
3. **Burn reduces float.** Sellback-burns and `redeem()` calls remove GROW from circulation. The remaining supply has a larger claim on a growing Treasury.

### Protocol-wide smart contracts

| Contract | Role |
|---|---|
| `GrowfiToken` | ERC20 + Burnable. Genesis mint + bonding-curve mint by Minter + direct multi-stablecoin buy with floor × (1 + markup). |
| `GrowfiMinter` | Hooks into every campaign's `buy()`. 3-tier bonding curve over cumulative buy volume, pre-softcap escrow, buyback void, exclusion list. |
| `GrowfiTreasury` | Holds the basket. Floor calc, allocate/stake/claim/redeem, manual + opt-in cross-tracked allocation, canonical-USDC harvest path, multisig rescue. |
| `GrowfiFeeSplitter` | Sits in `protocolFeeRecipient` slot. Permissionless multi-token flush, default 30/70 (Treasury / Operations). |
| `GrowfiStakingPool` | Stake GROW → earn USDC. Continuous 1.0× → 2.0× multiplier ramp over 365 days, withdraw resets streak, pending-for-first-staker safety. |

All five are `Initializable` + behind `TransparentUpgradeableProxy` + admin'd by the factory owner via forwarder methods (`factory.setGrowfiTokenMarkup`, `factory.setGrowfiBondingCurve`, `factory.allocateGrowfiTreasury`, …).

---

## Revenue split (where every $1 of fees goes)

There are **two** protocol fees, applied at different lifecycle moments. Both flow into the same `protocolFeeRecipient` (= `GrowfiFeeSplitter`), then split 30/70.

```
1) FUNDING-SIDE — `Campaign.buy()` skim, applied per purchase
   Buyer pays X (gross)
   ├─  3% FUNDING FEE  →  GrowfiFeeSplitter  (non-refundable on buyback)
   └─ 97% NET          →  escrow (Funding) or producer (Active)
                          Sell-back queue & buyback work on NET

2) HARVEST-SIDE — applied at every `HarvestManager.depositFromCollateral`
   GROSS HARVEST (physical, off-chain)
   │
   ├─ 30% PRODUCER  (at origin, off-chain — labor/ops)
   │
   └─ 70% REPORTED TO PLATFORM (on-chain)
       │
       ├─  2% HARVEST FEE       →  GrowfiFeeSplitter
       │
       └─ 98% TO TOKEN HOLDERS  →  claimable via $YIELD burn (product or USDC)

3) FEE-SPLITTER FLUSH — anyone calls `flushToken(token)` permissionlessly
   FeeSplitter balance of `token`
   ├─ 30% (treasuryBps)        →  GrowfiTreasury     (backs GROW)
   └─ 70% (BPS - treasuryBps)  →  Operations multisig
```

**Effective holder share (harvest only):** 70% × 98% = **68.6% of gross harvest value**.

**The 3% funding-side fee is non-refundable on buyback.** A failed campaign returns the NET (97%) to buyers. Rationale: the protocol incurs hosting + indexing cost regardless of outcome, and the small "skin in the game" filters spam campaigns.

**Producer payouts are unchanged by the GROW system.** The Treasury's slice comes out of the protocol's slice (via the Splitter's 30%), never out of producer or holder allocations.

---

## Per-campaign flow (lifecycle reminder)

```
0. CREATE CAMPAIGN
   Producer sets all per-campaign params (price, caps, deadline, season, claim min,
   v3 commitments). Factory deploys 5 proxies + auto-registers in GrowfiMinter.
   → State = Funding

1. FUNDING
   Users buy $CAMPAIGN with allowlisted ERC20.
   • 3% funding fee → GrowfiFeeSplitter
   • 97% net → escrow (held by Campaign contract)
   • Minter records buy → GROW awarded to escrow per (campaign, buyer)

2. SOFT CAP REACHED → ACTIVE
   • Net escrow released to producer
   • Staking activates, yield accrual begins
   • Minter.onSoftCapReached() → buyers can call Minter.claimEscrow(campaign)
     and pull their GROW directly to wallet
   • Subsequent buys mint GROW directly (no escrow)

   OR: DEADLINE EXPIRES BELOW SOFT CAP → BUYBACK
   • Users call Campaign.buyback(token) → 97% net refund
   • Campaign.buyback path also calls Minter.onBuyback()
     → all escrowed GROW for that campaign is permanently voided

3. STAKING (Active state only)
   Stake $CAMPAIGN → earn $YIELD via dynamic rate (5×→1×) accumulator.
   Multiple positions per user.

4. EARLY UNSTAKE (two steps)
   • unstake() — linear penalty on principal (burned), all $YIELD forfeited
   • optional sellBack() — push principal into FIFO sell-back queue OR cancel
                            and keep, OR sell on DEX

5. SEASON END / HARVEST
   Producer takes 30% off-chain, reports remaining 70% on-chain.
   2% harvest fee → GrowfiFeeSplitter, 98% → holders.
   $YIELD floor = reportedValue × 0.98 / totalYieldSupply.

6. REDEMPTION (within claim window)
   Step 1: declare product or USDC → $YIELD burned
   Step 2a (product): Merkle claim + shipping (paid by user, ≥ minProductClaim)
   Step 2b (USDC): producer depositUSDC within 90 days → user claimUSDC

7. PROTOCOL-LEVEL REDISTRIBUTION (parallel track)
   FeeSplitter accumulates fees → permissionless flushToken
   → 30% lands in Treasury (USDC / USDT / DAI as collected)
   Multisig (or `allocateAcrossTracked` when automation is on) buys CampaignTokens
   on behalf of Treasury → stakes them → earns harvest → permissionless
   claimUsdcAndDistribute splits 80% to GrowfiStakingPool / 20% retained.
   GROW stakers harvest USDC continuously.

8. PERMANENT EXIT
   Unstake $CAMPAIGN + sell on DEX, or burn $CAMPAIGN (deflationary), or
   burn GROW via Treasury.redeem() to pull a pro-rata basket.
```

---

## Verification — Silvi.earth dMRV

- Tree health tracked via the **Silvi.earth** application (optional dMRV partner).
- Reports published over the years (not tokenized).
- Covers tree health, growth, carbon sequestration, biodiversity.
- Published on the campaign page + IPFS hash stored on-chain.

---

## What this is and is not

**It is:**
- A two-layer regenerative finance protocol with permissionless campaign creation.
- A protocol-wide utility token (GROW) backed by a real, on-chain treasury, minted on participation.
- Aggregate exposure to all GrowFi campaigns through a single asset (GROW).
- Upgradeable via the existing factory + per-proxy ProxyAdmin model.

**It is not:**
- A governance token — no votes, no DAO, no proposals.
- A fundraising instrument — no presale, no public sale, no LP seed by the protocol.
- A liability on producers — producer payouts are unchanged; the Treasury's slice comes from the protocol's slice.
- A speculative wrapper — every GROW has a verifiable on-chain backing (`Treasury.intrinsicFloorPrice()` is a public view).
