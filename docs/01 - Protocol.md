---
tags:
  - openrefi
  - protocol
  - smart-contracts
status: defined
---
# Protocol — Smart Contracts

The on-chain stack is split into a small **core** of stable contracts plus a set of **modules** that the Campaign host delegatecalls into. The full module spec is in [[07 - Module Framework (Diamond)]]; this document covers what each contract owns.

## Contract Architecture

### Core Contracts

#### 1. `CampaignFactory`
Registry, deployer, and module whitelist authority.

- `createCampaign(params)` → deploys the per-campaign proxy stack (Campaign host + CampaignToken + YieldToken + StakingVault + HarvestManager), initializes them in dependency order, and auto-injects every module listed in `defaultModules[]` into the new Campaign during a one-shot bootstrap window.
- Maintains the **module whitelist**: `approvedModuleImpls[kind][impl]` and `moduleKindSelectors[kind]`, both `onlyOwner`. A Campaign cannot attach a module whose impl is not on this whitelist.
- Maintains the **default modules list**: `defaultModules[]` (each entry: `type`, `kind`, `impl`, `metadataURI`). Editable by the factory owner; changes propagate only to future Campaigns.
- Stores all campaign addresses (`isCampaign[address] → bool`).
- Enforces protocol-wide invariants set at create-time: `nameTaken` uniqueness, `minSeasonDuration` floor, the L2 sequencer-uptime feed reference, the canonical USDC address used by collateral flows.
- Owner: protocol multisig.

#### 2. `Campaign` (host)

A thin contract that owns the campaign state machine, the module registry, and the physical USDC escrow. It contains **no buy, sellback, collateral or harvest logic** — those are modules.

**State (core, owned by the host):**
- `producer`, `factory` — identities
- `campaignToken`, `yieldToken`, `stakingVault`, `harvestManager`, `usdc` — per-campaign bindings
- `state` — enum: `Funding`, `Active`, `Buyback`, `Ended`
- `currentSeasonId` — incremented by `startSeason()`
- `paused` — emergency stop, owner-gated
- `factoryBootstrap` — one-shot flag for default-module injection at deploy
- Module registry: `selectorToType[bytes4] → bytes32`, `moduleSlot[bytes32] → ModuleSlot`, `moduleTypeList[]`

All Campaign storage is read/written through the `CampaignStorage.layout()` library at a deterministic slot (`keccak256("growfi.campaign.core.v1")`) so modules can access it in `delegatecall` context without storage collisions. See [[07 - Module Framework (Diamond)]] §CampaignStorage.

**Host functions:**
- `initialize(params)` — proxy initializer; sets bindings, opens `factoryBootstrap`. Called by the factory at deploy.
- `closeBootstrap()` `onlyFactory` — clears `factoryBootstrap` after the factory's default-module injection loop completes.
- `attachModule(type, kind, impl, uri)` `onlyProducer` — attach a module after deploy.
- `attachModuleAsFactory(type, kind, impl, uri)` `onlyFactory` (and only while `factoryBootstrap` is true) — used by the factory to inject defaults.
- `detachModule(type)` `onlyProducer` — clear a slot and all its selectors.
- `setModuleEnabled(type, bool)` `onlyProducer` — fast disable without detach.
- `activate()` — transition Funding → Active when `currentSupply ≥ minCap`. Releases USDC escrow held by Campaign to the producer.
- `triggerBuyback()` — public, callable after `fundingDeadline` if `currentSupply < minCap`. Transitions Funding → Buyback.
- `endCampaign()` `onlyProducer` — closes the campaign permanently.
- `startSeason()`, `endSeason()` — staking lifecycle delegation to StakingVault.
- `setPaused(bool)` `onlyProducer` — emergency stop. Some module entrypoints choose to honor it via the `nonReentrant`-equivalent guard.
- `fallback() / delegatecall router` — resolves an unknown selector to a module via `selectorToType[msg.sig] → moduleSlot[type]`, then `delegatecall(impl)`.

**Lifecycle:**
```
1. FUNDING state
   → Users call sale-module functions (buy, sellBack, ...) via the host fallback
   → USDC sits in the Campaign address (escrow)
   → No staking, no yield

2. Min cap reached → activate() transitions to ACTIVE
   → Escrow released to producer
   → Staking activates, yield accrual begins
   → Sellback queue active

3. Max cap reached → sale module rejects further mints (queue still consumable)

4. Funding deadline passed, min cap NOT reached → triggerBuyback() → BUYBACK
   → Sale module exposes the refund path against the original payment record
```

Nothing else lives in the host. Every other behavior (pricing, fee skim, sellback queue, collateral, accepted-token management) is in a module.

### Default Modules

The factory's `defaultModules[]` list is auto-injected into every new Campaign at deploy. Producers can swap them later for variants approved on the factory whitelist.

#### `growfi.sale.classic.v1`

Owns the classic bonding-curve primary sale: buy, sellback, funding-fee skim, accepted-tokens registry, buyback refund on Funding-failure.

**Module storage** (`keccak256("growfi.module.sale.classic.v1")`):
- `pricePerToken` — base price denominated in USD-18 (e.g. `0.144e18`)
- `minCap`, `maxCap`, `currentSupply` — cap tracking
- `fundingDeadline`, `seasonDuration` — lifecycle parameters
- `acceptedTokens[]` — list of accepted ERC20s for payment
- `tokenConfig[address]` — per-token pricing: `mode` (Fixed/Oracle/StableUsd), `fixedRate`, `oracleFeed`, `heartbeat`, `paymentDecimals`
- `purchases[user][token]` — per-token net amount paid by each user; used by `buyback()` to refund failed campaigns in the original token, at the original NET price (the funding fee is non-refundable by design)
- `fundingFeeBps` — bps skimmed off every `buy()` gross inflow, forwarded to `protocolFeeRecipient` (default 300 = 3%). Snapshotted from the factory at attach time.
- `sellBackQueue[]`, `sellBackOpenCount[user]`, `MAX_OPEN_SELLBACK_ORDERS_PER_USER` — FIFO sellback queue with a per-user cap (default 50) to prevent griefing.

**Module entrypoints** (all callable as `Campaign.<fn>` thanks to fallback delegation):
- `buy(address paymentToken, uint256 paymentAmount, uint256 minTokensOut)` — pays with any accepted ERC20. During Funding: USDC held in Campaign escrow (NET of `fundingFeeBps`). During Active: fills sellback queue first, then mints fresh tokens up to `maxCap`. `fundingFeeBps` is forwarded to `protocolFeeRecipient` immediately and emitted as `FundingFeeCollected`.
- `previewBuy(address paymentToken, uint256 paymentAmount)` → `(tokensOut, effectivePayment, oraclePrice, fundingFee)` — pure quote.
- `getPrice(address paymentToken, uint256 campaignAmount)` — inverse view.
- `requestSellBack(uint256 amount)` — deposit $CAMPAIGN into the FIFO queue. Receives payment when a future buyer fills the order.
- `cancelSellBack(uint256 queuePosition)` — withdraw the unfilled portion of an order.
- `buyback(address paymentToken)` — Buyback-state refund. Burns the caller's $CAMPAIGN and returns the recorded `purchases[user][paymentToken]` amount in the same token.
- `addAcceptedToken(address token, PricingMode mode, uint256 fixedRate, address oracleFeed, uint64 heartbeat)` `onlyProducer` — register a payment token.
- `removeAcceptedToken(address token)` `onlyProducer` — deregister.

**Pricing modes:**
- `FIXED` — `tokensOut = paymentAmount × 1e18 / fixedRate`
- `ORACLE` — `tokensOut = paymentAmount × livePriceUsd / pricePerToken`, with sequencer-uptime check on L2 and staleness/heartbeat guard
- `StableUsd` — `tokensOut = paymentAmount × scale / pricePerToken` for whitelisted stablecoins (USDC, USDT, DAI) with deemed-$1 pricing

**Events** emitted by the module body but indexed off the Campaign address:
```solidity
event TokensPurchased(
    address indexed buyer,
    address indexed paymentToken,
    uint256 paymentAmount,        // GROSS (pre-fundingFee)
    uint256 campaignTokensOut,
    uint256 oraclePriceUsed,      // 0 if fixed/stable mode
    uint256 newCurrentSupply
);
event FundingFeeCollected(address indexed buyer, address indexed paymentToken, uint256 fee);
event SellBackRequested(address indexed user, uint256 queuePosition, uint256 amount);
event SellBackFilled(address indexed buyer, address indexed seller, uint256 amount, address paymentToken);
event SellBackCancelled(address indexed user, uint256 queuePosition, uint256 amountReturned);
event AcceptedTokenAdded(address indexed token, uint8 mode, uint256 fixedRate, address oracleFeed);
event AcceptedTokenRemoved(address indexed token);
```

#### `growfi.collateral.v1`

Owns the productive-asset commitments and the pre-paid yield reserve.

**Module storage** (`keccak256("growfi.module.collateral.v1")`):
- `expectedAnnualHarvestUsd` — producer's USD-18 yearly yield commitment (e.g. `$5,000/yr`)
- `expectedAnnualHarvest` — producer's physical product commitment per year (1e18 internal scale; the UI derives implied $/unit from the two)
- `firstHarvestYear` — calendar year of the first harvest
- `coverageHarvests` — number of upcoming harvests pre-funded with `collateralLocked`
- `collateralLocked` — total USDC the producer has locked as the pre-paid reserve; one-way (no early withdrawal)
- `collateralDrawn` — total USDC drawn to settle holder shortfalls
- `seasonShortfallSettled[seasonId]` — idempotency guard

**Module entrypoints:**
- `lockCollateral(uint256 amount)` `onlyProducer` — pulls USDC from the producer into `collateralLocked`. Cumulative; capped at `maxCollateral() = expectedAnnualHarvestUsd × coverageHarvests` (USD-18 → USDC-6 rescale).
- `depositUSDC(uint256 seasonId, uint256 walletCap)` `onlyProducer` — single producer-facing yield-deposit entrypoint. Drains `min(obligation, collateralLocked − collateralDrawn)` from collateral first, then pulls the remaining gap from the producer's wallet up to `walletCap`. Forwards via `HarvestManager.depositFromCollateral(seasonId, amount)`.
- `settleSeasonShortfall(uint256 seasonId)` — permissionless, callable once per `seasonId ∈ [1..coverageHarvests]` after that season's `usdcDeadline` has passed. Draws up to the unfunded gap from `collateralLocked` and forwards to HarvestManager.
- View helpers: `maxCollateral()`, `availableCollateral()`, `remainingDepositGross(seasonId)`, `harvestsToRepay()` (derived from `expectedAnnualHarvestUsd` and `pricePerToken × maxCap`).

**Events:**
```solidity
event CollateralLocked(address indexed producer, uint256 amount, uint256 totalLocked);
event CollateralShortfallSettled(uint256 indexed seasonId, uint256 amountDrawn, uint256 totalDrawn);
```

Sizing math and risk indicators live in [[05 - Math & Formulas]] §15.

### Optional Modules

Producer-attached only when needed. Whitelisted in the factory before they become installable.

#### `growfi.repayment.v1` (planned)

Lets the producer pre-fund an early exit for backers. Owner deposits USDC into the module's pool; holders burn their $CAMPAIGN in exchange for `principal + accrued yield`. Useful when the producer wants to close a campaign cleanly before its natural end (e.g. liquidity event, sale of the underlying asset).

#### `growfi.dmrv.silvi.v1` (planned)

Publishes Silvi-verified dMRV signals (tree health, biomass, carbon sequestration) on-chain, tied to the campaign address. Read-only with respect to the Campaign core — the module stores its own state, the rest of the protocol can quote it for UI badges, insurance triggers, or governance signals.

#### Future kinds

Insurance/hedging, alternative sale variants (Dutch auction, whitelist-gated, KYC-gated), governance, royalty/referral, secondary market integrations. Each one adds a new `kind` to the factory whitelist; the Campaign host does not change.

#### 3. `CampaignToken` (ERC20)
Per-campaign staking token — "the seat."

- ERC20 + ERC20Votes (for balance checkpointing)
- **Mintable by**: Campaign contract only (during initial sales)
- **Burnable**: on early unstake penalty + permanent exit
- Non-rebasing, transferable, tradeable on DEX
- Strictly deflationary — supply can only decrease

#### 4. `YieldToken` (ERC20)
Per-campaign harvest claim token — "the fruit."

- ERC20, transferable
- **Mintable by**: StakingVault only (during staking)
- **Burned on**: harvest redemption (product or USDC)
- Fresh $YIELD minted each season from staking
- No carry-over between seasons — each season's $YIELD is independent

#### 5. `StakingVault`
Handles staking, yield accrual, penalties, and the unstaking queue.

**State:**
- `totalStaked` — total $CAMPAIGN staked
- `maxSupply` — max $CAMPAIGN tokens (for yield rate calculation)
- `rewardPerTokenStored` — Synthetix accumulator
- `nextPositionId` — auto-incrementing position ID counter
- `positions[positionId]` — struct: owner, amount, startTime, rewardPerTokenPaid, seasonId, active
- `userPositions[user]` — array of position IDs owned by user
- `unstakeQueue[]` — FIFO queue of (user, positionId, owedAmount)
- `totalQueueDebt` — sum of all pending unstake obligations
- `currentSeason` — active season ID

**Dynamic Yield Rate:**
```
yieldRate = 5 - 4 × (totalStaked / maxSupply)

0% filled  → yieldRate = 5 (max, early bird bonus)
50% filled → yieldRate = 3
100% filled → yieldRate = 1 (min)
```

Recalculated on every stake/unstake event. Accumulator is updated before rate changes, locking in previously earned $YIELD at the old rate.

**Functions:**
- `stake(amount)` → `positionId` — update accumulator, deposit $CAMPAIGN, create new position, recalculate yieldRate. Returns the new position ID.
- `unstake(positionId)` — update accumulator, apply linear penalty based on this position's startTime, forfeit this position's $YIELD, recalculate yieldRate, return/queue remainder
- `restake(positionId)` — roll a specific position into next season (keep amount, reset startTime, start earning fresh $YIELD)
- `restakeAll()` — convenience: restake all active positions for the user
- `claimYield(positionId)` — view accumulated $YIELD for a specific position
- `claimAllYield()` — view total accumulated $YIELD across all user positions
- `getPositions(user)` — view: returns all position IDs and details for a user
- `endSeason()` — finalize season, stop $YIELD accrual
- `startSeason(newSeasonId)` — begin new season, reset $YIELD accrual
- `processQueue(incomingFunds)` — called from the sale module (delegatecall context: caller is the Campaign address) to drain the unstake queue FIFO when a new buy arrives
- `currentYieldRate()` — view: returns current dynamic yield rate

**Multiple Positions:**
Each `stake()` call creates an independent position with its own:
- `positionId` — unique identifier
- `amount` — tokens staked in this position
- `startTime` — when this position was created
- `rewardPerTokenPaid` — accumulator snapshot at stake time

This means:
- Each position has its own penalty calculation (based on its own startTime)
- Users can unstake one position while keeping others
- Early positions earn more $YIELD (higher rate when campaign was emptier + longer duration)
- Users can manage risk by staking in tranches

**Penalty Logic:**
```
penaltyRate = 1 - (elapsed / seasonDuration)
penaltyAmount = stakedAmount * penaltyRate → BURNED
returnedAmount = stakedAmount - penaltyAmount → returned or queued
ALL $YIELD forfeited
```

**Unstake Queue:**
- FIFO, partial fills allowed
- New purchases fund queue first
- Cancel unstake = re-stake if not yet filled

#### 6. `HarvestManager`
Two-step harvest redemption: product or USDC.

**State:**
- `seasons[seasonId]` — struct: merkleRoot, totalHarvestValueUSD, totalYieldSupply, claimStart, claimEnd, usdcDeadline, minProductClaim
- `claims[seasonId][user]` — struct: claimed (bool), redemptionType (product/usdc), amount
- `usdcDeposited` — USDC deposited by producer for that season

**Functions:**
- `reportHarvest(seasonId, totalValueUSD, merkleRoot, totalUnits)` — producer reports 70% of gross harvest (30% kept at origin)
- `redeemProduct(seasonId, amount, merkleProof)` — Step 1+2a: burn $YIELD, verify proof, emit Claimed event. Reverts if amount < minProductClaim
- `redeemUSDC(seasonId, amount)` — Step 1: burn $YIELD, register USDC claim. No minimum
- `claimUSDC(seasonId)` — Step 2b: claim deposited USDC (after producer deposits)
- `depositUSDC(seasonId, amount)` — producer deposits USDC (within 90-day window)

**Revenue Flow:**
```
Producer reports harvest (70% of gross, 30% kept at origin)
  → 2% protocol fee deducted automatically
  → 98% of reported value available to token holders
```

**Two-Step Redemption:**
```
Product path:
  1. User calls redeemProduct() → $YIELD burned, Merkle verified, Claimed event emitted
  2. Off-chain fulfillment → ship product (shipping paid by user)

USDC path:
  1. User calls redeemUSDC() → $YIELD burned, USDC claim registered
  2. Producer sells unredeemed product → deposits USDC within 90 days
  3. User calls claimUSDC() → receives USDC
```

---

## Contract Dependency Graph

```
CampaignFactory
  ├── module whitelist: approvedModuleImpls[kind][impl], moduleKindSelectors[kind]
  ├── defaultModules[]: auto-injected into every new Campaign at deploy
  └── deploys per campaign:
        ├── Campaign (host: state machine + module registry + USDC escrow + fallback)
        │     ├── default module: growfi.sale.classic.v1
        │     ├── default module: growfi.collateral.v1
        │     └── optional modules: growfi.repayment.v1, growfi.dmrv.silvi.v1, ...
        ├── CampaignToken (ERC20 + Votes) — strictly deflationary
        ├── YieldToken (ERC20) — seasonal, burned on redemption
        ├── StakingVault
        │     ├── mints → YieldToken (staking rewards)
        │     └── burns → CampaignToken (penalties, forceUnstake on module call)
        └── HarvestManager
              ├── burns → YieldToken (on redemption)
              └── receives → USDC from producer (or from collateral via module)
```

### Standalone Registries

Two single-instance registries live outside the per-campaign proxy graph and
are not upgradeable. They carry off-chain pointers and trust signals that the
core contracts can verify on-chain.

#### `CampaignRegistry`
- `metadataURI[campaign] → string` plus a monotonic `version[campaign]`.
- Producer-only write, gated by `factory.isCampaign(campaign)` so only
  legitimate campaigns can publish metadata.
- Emits `MetadataSet(campaign, producer, version, uri)` indexed by the subgraph
  into `Campaign.metadataURI` / `Campaign.metadataVersion`.

#### `ProducerRegistry`
- `profileURI[producer] → string` plus a monotonic `version[producer]`.
- Anyone writes their own row (keys on `msg.sender`); zero admin in the public
  surface — preserves the permissionless pitch for the producer profile.
- KYC bit (additive, role-gated): a `kyced[producer] → bool` flag flipped by
  `setKyc(address producer, bool kyced)`, which is gated to `KYC_ADMIN_ROLE`
  (single-slot role; the contract owner grants/revokes via
  `grantKycAdmin(address) / revokeKycAdmin(address)`). Emits
  `KycSet(producer, kyced, by)` indexed into `Producer.kyced`.
- Trust model: the producer cannot self-attest the KYC bit (preventing
  spoofing); the role is centralized and assumes the protocol operator runs
  KYC off-chain (e.g. via a third-party verifier) and reflects the result
  on-chain. Off-the-shelf `Ownable2Step` for role transfer; explicit
  events on every flip.

## Multi-Season Lifecycle

```
Season 1:
  Campaign.buy() → mint $CAMPAIGN (one-time)
  StakingVault.stake() → earn $YIELD
  HarvestManager.reportHarvest() → redemption opens
  Users burn $YIELD → product or USDC
  Some users exit → $CAMPAIGN burned (deflationary)

Season 2:
  No new $CAMPAIGN minted (unless new buyers from remaining maxSupply)
  StakingVault.startSeason() → fresh $YIELD accrual
  Restakers earn $YIELD on same $CAMPAIGN
  Their share is now larger (fewer stakers)
  
Season N:
  Loyal stakers have growing harvest share
  Supply continuously deflating
```

## Contract Events

All events emitted for subgraph indexing. Module events are emitted from the Campaign address (the modules run in `delegatecall` context), so from the indexer's perspective there's a single event source per Campaign even though logical ownership is split across host + modules.

### CampaignFactory Events

```solidity
// Emitted when a new campaign is deployed. Sale/collateral specifics are
// emitted separately by the corresponding default modules during their own
// initialize step (see SaleClassicInitialized / CollateralInitialized below).
event CampaignCreated(
    address indexed campaign,
    address indexed producer,
    address campaignToken,
    address yieldToken,
    address stakingVault,
    address harvestManager,
    uint256 createdAt
);

// Factory module-whitelist events
event ModuleImplApproved(bytes32 indexed kind, address indexed impl, bool approved);
event ModuleKindSelectorsSet(bytes32 indexed kind, bytes4[] selectors);
event DefaultModulesUpdated(uint256 count);
```

### Campaign host events

```solidity
// Module registry lifecycle
event ModuleAttached(bytes32 indexed moduleType, address indexed impl, bytes32 indexed kind, string metadataURI);
event ModuleDetached(bytes32 indexed moduleType, address indexed previousImpl);
event ModuleEnabledSet(bytes32 indexed moduleType, bool enabled);
event ModuleSelectorRegistered(bytes4 indexed selector, bytes32 indexed moduleType);

// State machine transitions (host-owned)
event CampaignStateChanged(uint8 oldState, uint8 newState);
event CampaignActivated(uint256 totalRaised, uint256 tokensSold);
event BuybackTriggered(uint256 totalRaised, uint256 tokensSold, uint256 minCap);
event CampaignPaused(bool paused);
```

### Module events (emitted from the Campaign address)

Modules run in `delegatecall` context and emit events as if they were the Campaign itself. The subgraph indexes them off the Campaign address with no special handling.

#### `growfi.sale.classic.v1` events

```solidity
// Module initialization (emitted once during factory bootstrap)
event SaleClassicInitialized(
    uint256 pricePerToken,
    uint256 minCap,
    uint256 maxCap,
    uint256 fundingDeadline,
    uint256 seasonDuration,
    uint256 fundingFeeBps
);

// Emitted when a user purchases $CAMPAIGN tokens
event TokensPurchased(
    address indexed buyer,
    address indexed paymentToken,
    uint256 paymentAmount,        // GROSS (pre-fundingFee)
    uint256 campaignTokensOut,
    uint256 oraclePriceUsed,      // 0 if fixed/stable mode
    uint256 newCurrentSupply
);

// Emitted alongside TokensPurchased; the `fee` was forwarded to
// `protocolFeeRecipient` and is non-refundable on buyback.
event FundingFeeCollected(
    address indexed buyer,
    address indexed paymentToken,
    uint256 fee
);

// Accepted-tokens registry mutations
event AcceptedTokenAdded(
    address indexed tokenAddress,
    string symbol,
    uint8 pricingMode,            // 0 = fixed, 1 = oracle, 2 = stableUsd
    uint256 fixedRate,            // 0 if oracle mode
    address oracleFeed            // address(0) if fixed mode
);
event AcceptedTokenRemoved(address indexed tokenAddress);

// Buyback (Funding-failure refund)
event BuybackClaimed(
    address indexed user,
    address indexed paymentToken,
    uint256 campaignTokensBurned,
    uint256 refundAmount
);

// Sellback queue
event SellBackRequested(address indexed user, uint256 amount, uint256 queuePosition);
event SellBackFilled(
    address indexed seller,
    address indexed buyer,
    address paymentToken,
    uint256 campaignTokenAmount,
    uint256 paymentAmount,
    uint256 remainingInQueue
);
event SellBackCancelled(address indexed user, uint256 amountReturned);
```

#### `growfi.collateral.v1` events

```solidity
event CollateralInitialized(
    uint256 expectedAnnualHarvestUsd,
    uint256 expectedAnnualHarvest,
    uint256 firstHarvestYear,
    uint256 coverageHarvests
);

// Producer locked additional USDC into the pre-paid yield reserve
event CollateralLocked(
    address indexed producer,
    uint256 amount,
    uint256 newCollateralLocked   // running total
);

// Anyone called settleSeasonShortfall(seasonId) and the reserve covered the
// gap between producer's depositUSDC and the season's usdcOwed.
event CollateralShortfallSettled(
    uint256 indexed seasonId,
    uint256 amountDrawn,
    uint256 newCollateralDrawn    // running total
);
```

### StakingVault Events

```solidity
// Emitted when a user stakes $CAMPAIGN tokens (creates a new position)
event Staked(
    address indexed user,
    uint256 indexed positionId,
    uint256 amount,
    uint256 newTotalStaked,
    uint256 newYieldRate          // updated dynamic yield rate
);

// Emitted when a user unstakes a specific position early (with penalty)
event Unstaked(
    address indexed user,
    uint256 indexed positionId,
    uint256 stakedAmount,
    uint256 penaltyAmount,       // burned
    uint256 returnedAmount,      // returned or queued
    uint256 yieldForfeited,      // $YIELD lost
    bool queued,                 // true if entered unstake queue
    uint256 newTotalStaked,
    uint256 newYieldRate
);

// Emitted when a user cancels their unstake request and re-stakes
event UnstakeCancelled(
    address indexed user,
    uint256 indexed positionId,
    uint256 amount,
    uint256 newTotalStaked,
    uint256 newYieldRate
);

// Emitted when an unstake queue entry is (partially) filled
event UnstakeQueueFilled(
    address indexed user,
    uint256 indexed positionId,
    uint256 filledAmount,
    uint256 remainingOwed
);

// Emitted when a user restakes a specific position for the next season
event Restaked(
    address indexed user,
    uint256 indexed positionId,
    uint256 amount,
    uint256 newSeasonId
);

// Emitted when $YIELD is minted to a staker (on claim or season end)
event YieldMinted(
    address indexed user,
    uint256 indexed positionId,
    uint256 yieldAmount,
    uint256 seasonId
);

// Emitted when the dynamic yield rate changes
event YieldRateUpdated(
    uint256 newYieldRate,        // scaled by 1e18
    uint256 totalStaked,
    uint256 maxSupply
);

// Emitted when a new season starts
event SeasonStarted(
    uint256 indexed seasonId,
    uint256 startTime
);

// Emitted when a season ends
event SeasonEnded(
    uint256 indexed seasonId,
    uint256 endTime,
    uint256 totalYieldMinted
);
```

### HarvestManager Events

```solidity
// Emitted when the producer reports a harvest
event HarvestReported(
    uint256 indexed seasonId,
    uint256 totalHarvestValueUSD, // 70% of gross (after producer's 30%)
    uint256 protocolFee,          // 2% of reported
    uint256 holderPool,           // 98% of reported
    uint256 totalProductUnits,
    bytes32 merkleRoot,
    uint256 claimStart,
    uint256 claimEnd,
    uint256 usdcDeadline          // claimEnd + 90 days
);

// Emitted when a user redeems $YIELD for physical product
event ProductRedeemed(
    address indexed user,
    uint256 indexed seasonId,
    uint256 yieldBurned,
    uint256 productAmount,        // in product units (e.g., liters)
    bytes32 merkleLeaf
);

// Emitted when a user redeems $YIELD for USDC (step 1 — intent declared)
event USDCRedeemed(
    address indexed user,
    uint256 indexed seasonId,
    uint256 yieldBurned,
    uint256 usdcAmount            // amount owed
);

// Emitted when the producer deposits USDC to cover redemptions
event USDCDeposited(
    uint256 indexed seasonId,
    address indexed producer,
    uint256 amount,
    uint256 totalDeposited,
    uint256 totalOwed
);

// Emitted when a user claims their deposited USDC (step 2)
event USDCClaimed(
    address indexed user,
    uint256 indexed seasonId,
    uint256 amount
);

// Emitted when protocol fee is collected
event ProtocolFeeCollected(
    uint256 indexed seasonId,
    uint256 amount,
    address recipient
);
```

### CampaignToken Events

Standard ERC20 + ERC20Votes events (inherited from OpenZeppelin):

```solidity
// Standard ERC20
event Transfer(address indexed from, address indexed to, uint256 value);
event Approval(address indexed owner, address indexed spender, uint256 value);

// ERC20Votes
event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);
```

### YieldToken Events

Standard ERC20 events (inherited from OpenZeppelin):

```solidity
event Transfer(address indexed from, address indexed to, uint256 value);
event Approval(address indexed owner, address indexed spender, uint256 value);
```

---

## Technical Considerations

- **Chain**: any EVM-compatible L2 (low gas required for micro-transactions)
- **Yield accrual**: uses seconds (block.timestamp), chain-agnostic
- **Stablecoin support**: USDC, USDT, or chain-native stablecoins for contributions and USDC redemption
- **Oracles**: Chainlink, RedStone, Pyth available on most L2s if needed
- **DEX listing**: Uniswap, Velodrome, or any AMM for $CAMPAIGN trading

## Development Stack
- **Language**: Solidity 0.8.x
- **Framework**: Foundry (forge, cast, anvil)
- **Libraries**: OpenZeppelin Contracts v5 (ERC20, ERC20Votes, MerkleProof, AccessControl, ReentrancyGuard)
- **Testing**: Forge tests + fork testing against target L2
- **Deployment**: Foundry scripts, verified on block explorer
- **Auditing**: Slither, Aderyn static analysis → external audit before mainnet

## Security Considerations
- Reentrancy guards on all state-changing functions
- Merkle proof verification for all product claims
- Role-based access: producer vs protocol admin
- Emergency pause on all contracts
- StakingVault is the only contract that can mint YieldToken
- Campaign is the only contract that can mint CampaignToken
- $CAMPAIGN is strictly deflationary — no minting after initial sale
- USDC deposit deadline enforcement (90 days)
- Snapshot timing announced in advance
