---
tags:
  - openrefi
  - protocol
  - smart-contracts
status: defined
---
# Protocol — Smart Contracts

## Contract Architecture

### Core Contracts

#### 1. `CampaignFactory`
Registry and deployer for new campaigns.

- `createCampaign(params)` → deploys all campaign contracts
- Stores all campaign addresses
- Collects protocol fee (small % of raised funds)
- Owner: protocol multisig
- Enforces protocol constants: dynamic yield rate (5→1 linear decay), linear penalty, 90-day USDC deposit window, 30% producer share (off-chain), 2% protocol fee (on-chain), 1,000 tokens per asset

#### 2. `Campaign`
Handles token sales with multi-token support, escrow, and cap management.

**State (core):**
- `pricePerToken` — base price denominated in USD (e.g., $0.144)
- `minCap` — minimum tokens that must be sold for campaign to proceed
- `maxCap` — maximum tokens mintable (= maxSupply)
- `currentSupply` — tokens minted so far
- `fundingDeadline` — deadline to reach minCap
- `seasonDuration` — season length (≥ 365 days)
- `state` — enum: Funding, Active, Buyback, Ended
- `acceptedTokens[]` — list of accepted ERC20 tokens for payment
- `tokenConfig[address]` — per-token config: pricing mode (fixed or oracle), fixed rate, oracle feed address
- `purchases[user][token]` — tracks each user's payment amounts per token (for buyback refunds; recorded NET of the funding fee)
- `fundingFeeBps` — protocol fee skimmed off every `buy()` gross inflow (e.g. 300 = 3%); non-refundable on buyback. Snapshotted from the factory at creation. See `03 - Tokenomics.md` for distribution.

**State (productive-asset metadata, set at creation, immutable):**
- `expectedYearlyReturnBps` — producer's commitment to a yearly yield rate, in basis points (e.g. 1000 = 10%). Used by holders to derive `harvestsToRepay = 10_000 / expectedYearlyReturnBps` (i.e. how many harvests until the original investment has been returned in yield) and to size the producer's `requiredCollateral` for the chosen `coverageHarvests`.
- `expectedFirstYearHarvest` — physical product the producer expects to deliver in year one, in product units (1e18 internal scale). Sets the proportional baseline for `reportHarvest` (subsequent seasons can deviate; this is the up-front commitment used by the calculator).
- `coverageHarvests` — number of upcoming harvests the producer pre-funds with `collateralLocked`. Strong trust signal: holders see "guaranteed for X harvests" and can compare to `harvestsToRepay`. Tail = `harvestsToRepay − coverageHarvests` is the period where holders carry residual delivery risk.

**State (collateral, mutable):**
- `collateralLocked` — total USDC the producer has locked as pre-paid yield reserve. Cumulative; producer can `lockCollateral(amount)` repeatedly during Active state but never withdraw early.
- `collateralDrawn` — total USDC already drawn from the reserve to settle holder shortfalls.
- `seasonShortfallSettled[seasonId]` — guard so each covered season's shortfall draw runs at most once.

**Multi-Token Payment:**
```
For each accepted ERC20, the producer configures:
  - FIXED mode: set a manual conversion rate (e.g., 1 TOKEN = X $CAMPAIGN)
  - ORACLE mode: provide a Chainlink price feed address (e.g., WETH/USD)
    → contract reads oracle, converts to $CAMPAIGN amount at current price
```

**Example:**
```
Base price: $0.144 per $CAMPAIGN

USDC:  FIXED mode, 1:1 with base price → 0.144 USDC = 1 $CAMPAIGN
WETH:  ORACLE mode, Chainlink WETH/USD feed
       → WETH at $2,880 → 0.144/2880 = 0.00005 WETH = 1 $CAMPAIGN
DAI:   FIXED mode, 1:1 with base price → 0.144 DAI = 1 $CAMPAIGN
Custom: FIXED mode, producer sets rate manually
```

**Campaign Lifecycle:**
```
1. FUNDING state
   → Users buy tokens → funds held in escrow (contract)
   → No staking, no yield — just fundraising
   → Producer cannot access funds

2. Min cap reached → transitions to ACTIVE
   → Funds released to producer
   → Staking activates, yield accrual begins
   → Purchases continue until max cap

3. Max cap reached → no more purchases

4. Funding deadline passed, min cap NOT reached → transitions to BUYBACK
   → Staking never activated
   → Users call buyback() to refund at original purchase price
   → Each user gets back exactly what they paid, in the same token they paid with
   → $CAMPAIGN tokens burned on refund
```

**Sell-Back Queue:**
After activation, the producer has withdrawn the funds. Users who want to exit for cash can sell their $CAMPAIGN back via a FIFO queue funded by new buyers.

```
1. User unstakes from StakingVault → gets $CAMPAIGN back (minus penalty)
2. User calls Campaign.sellBack(amount) → $CAMPAIGN deposited into sell-back queue
3. New buyer calls buy() → payment goes to queued seller FIRST
4. Seller's $CAMPAIGN is burned, new $CAMPAIGN minted to buyer (net zero supply change)
5. If no new buyers → seller waits in queue
6. Seller can cancel sell-back and get $CAMPAIGN back if not yet filled
```

**Queue rules:**
- FIFO — first to request, first to be paid
- Partial fills allowed
- New purchases fill the queue before minting fresh tokens
- Seller receives payment in whatever token the new buyer paid with
- Cancel = get $CAMPAIGN back (if not yet filled)

**Functions:**
- `addAcceptedToken(tokenAddress, pricingMode, fixedRate, oracleFeed)` — producer adds a payment token
- `removeAcceptedToken(tokenAddress)` — producer removes a payment token
- `buy(tokenAddress, amount)` — pay with any accepted ERC20. During Funding: held in escrow (NET of `fundingFeeBps`). During Active: fills sell-back queue first (NET), then mints new tokens (up to maxCap). The `fundingFeeBps` skim is forwarded to `protocolFeeRecipient` immediately and emitted as `FundingFeeCollected`.
- `sellBack(amount)` — deposit $CAMPAIGN into sell-back queue. Receives payment tokens when a new buyer fills the order
- `cancelSellBack()` — cancel pending sell-back, get $CAMPAIGN back (unfilled portion)
- `buyback()` — refund at original purchase price if campaign is in Buyback state (failed funding). Burns $CAMPAIGN, returns payment tokens NET of `fundingFeeBps` (the funding fee is non-refundable by design — see `03 - Tokenomics.md`)
- `activateCampaign()` — called when min cap reached (can be automatic or manual). Releases escrow to producer, enables staking
- `triggerBuyback()` — callable by anyone after funding deadline if min cap not reached. Transitions to Buyback state
- `lockCollateral(uint256 amount)` — producer-only, Active state. Pulls `amount` USDC from the producer into `collateralLocked`. Cumulative; emits `CollateralLocked`. **No early withdrawal path** — the lock is one-way until `coverageHarvests` settle (or campaign Ended).
- `settleSeasonShortfall(uint256 seasonId)` — permissionless, callable once per `seasonId ∈ [1..coverageHarvests]` after that season's `usdcDeadline` has passed. Computes the holder pool's missing USDC (`remainingDepositGross`), draws up to that amount from `collateralLocked`, forwards to `HarvestManager.depositUSDC` so the existing claim path delivers to holders pro-rata, increments `collateralDrawn`, sets `seasonShortfallSettled[seasonId] = true`, emits `CollateralShortfallSettled`. Does nothing if no shortfall.
- `getPrice(tokenAddress, campaignAmount)` — view: returns cost in the specified token for X $CAMPAIGN
- `getSellBackQueue()` — view: returns queue depth and positions
- `emergencyPause()` — pause all operations

**Price Calculation:**
```
If FIXED mode:
  tokensOut = paymentAmount / fixedRate

If ORACLE mode:
  usdPrice = oracle.latestAnswer()  (e.g., WETH/USD)
  paymentValueUSD = paymentAmount × usdPrice
  tokensOut = paymentValueUSD / pricePerToken
```

**Buyback Refund:**
```
User paid 0.05 WETH for 1,000 $CAMPAIGN
Campaign fails to reach min cap
User calls buyback() → burns 1,000 $CAMPAIGN, receives 0.05 WETH back

Refund is in the SAME token the user originally paid with,
at the SAME amount (not recalculated via oracle).
```

**Note:** $CAMPAIGN is only minted during initial sales. No new minting after that. Supply is strictly deflationary.

**Producer Collateral (Pre-Paid Yield Reserve):**

The producer can pre-fund the first `coverageHarvests` seasons of holder yield by locking USDC into the campaign at activation. This converts an explicit promise (`expectedYearlyReturnBps`) into an on-chain guarantee for the duration of the lock.

```
Sizing (recommended, enforced off-chain in the UI):
  expectedYearlyUsdc  = totalRaised × expectedYearlyReturnBps / 10_000
  requiredCollateral  = coverageHarvests × expectedYearlyUsdc
  harvestsToRepay     = 10_000 / expectedYearlyReturnBps
  uncoveredTail       = harvestsToRepay − coverageHarvests
```

Lifecycle:
```
1. Campaign reaches Active state → `totalRaised` is final.
2. Producer calls `lockCollateral(USDC)` (any amount, additive, no withdraw).
   The UI displays the implied "covers X harvests at this expectedYearlyReturn".

3. For each season s ∈ [1..coverageHarvests]:
   - Producer calls `reportHarvest(s, ...)` → sets `usdcOwed[s]` and starts the
     `usdcDeadline[s]` window for producer's own depositUSDC.
   - Holders call `redeemUSDC(s, yieldAmount)` → registers their claim.
   - Producer (ideally) calls `depositUSDC(s, amount)` from harvest income.
   - When `block.timestamp > usdcDeadline[s]`:
     - If `remainingDepositGross[s] == 0` → fully funded by producer; nothing to do.
     - Else → anyone calls `settleSeasonShortfall(s)`:
       * draws min(remainingDepositGross, collateralLocked − collateralDrawn) USDC
         from the locked reserve
       * forwards to HarvestManager via the existing depositUSDC path
       * holders' claimUSDC now succeeds for that season
       * `collateralDrawn` advances, `seasonShortfallSettled[s] = true`

4. After season `coverageHarvests` settles → coverage period ends.
   Future seasons rely entirely on the producer's own deposits (no automatic
   draw). Any residual `collateralLocked − collateralDrawn` STAYS LOCKED in
   the contract; per the protocol's commitment model the collateral does not
   return to the producer. Distribution of residuals back to holders is a
   future enhancement (see TODO in `Math & Formulas.md §15`).
```

Trust signal & risk indicator (UI-side, derived):
- "Coperto X raccolti" — direct from `coverageHarvests`.
- "Tail di Y raccolti" — `harvestsToRepay − coverageHarvests`. Higher tail = more years where the holder carries delivery risk.
- Risk score: roughly `tail / harvestsToRepay`. Smaller is better.

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
- `processQueue(incomingFunds)` — called by Campaign.buy() to drain unstake queue FIFO
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
  └── deploys per campaign:
        ├── CampaignToken (ERC20 + Votes) — strictly deflationary
        ├── YieldToken (ERC20) — seasonal, burned on redemption
        ├── Campaign (sales only, routes funds to queue)
        ├── StakingVault
        │     ├── mints → YieldToken (staking rewards)
        │     └── burns → CampaignToken (penalties)
        └── HarvestManager
              ├── burns → YieldToken (on redemption)
              └── receives → USDC from producer
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

All events emitted for subgraph indexing.

### CampaignFactory Events

```solidity
// Emitted when a new campaign is deployed
event CampaignCreated(
    address indexed campaign,
    address indexed producer,
    address campaignToken,
    address yieldToken,
    address stakingVault,
    address harvestManager,
    uint256 pricePerToken,
    uint256 minCap,
    uint256 maxCap,
    uint256 fundingDeadline,
    uint256 seasonDuration,
    uint256 minProductClaim,
    uint256 createdAt
);
```

### Campaign Events

```solidity
// Emitted when a user purchases $CAMPAIGN tokens
event TokensPurchased(
    address indexed buyer,
    address indexed paymentToken,
    uint256 paymentAmount,        // GROSS (pre-fundingFee)
    uint256 campaignTokensOut,
    uint256 oraclePriceUsed,     // 0 if fixed mode
    uint256 newCurrentSupply
);

// Emitted alongside TokensPurchased; the `fee` was forwarded to
// `protocolFeeRecipient` and is non-refundable on buyback.
event FundingFeeCollected(
    address indexed buyer,
    address indexed paymentToken,
    uint256 fee
);

// Producer locked additional USDC into the pre-paid yield reserve
event CollateralLocked(
    address indexed producer,
    uint256 amount,
    uint256 newCollateralLocked  // running total
);

// Anyone called settleSeasonShortfall(seasonId) and the reserve covered
// the gap between producer's depositUSDC and the season's usdcOwed.
event CollateralShortfallSettled(
    uint256 indexed seasonId,
    uint256 amountDrawn,
    uint256 newCollateralDrawn   // running total
);

// Emitted when a payment token is added
event AcceptedTokenAdded(
    address indexed tokenAddress,
    string symbol,
    uint8 pricingMode,           // 0 = fixed, 1 = oracle
    uint256 fixedRate,           // 0 if oracle mode
    address oracleFeed           // address(0) if fixed mode
);

// Emitted when a payment token is removed
event AcceptedTokenRemoved(
    address indexed tokenAddress
);

// Emitted when campaign state changes
event CampaignStateChanged(
    uint8 oldState,
    uint8 newState
);

// Emitted when campaign transitions to Active (min cap reached)
event CampaignActivated(
    uint256 totalRaised,
    uint256 tokensSold
);

// Emitted when campaign transitions to Buyback (min cap not reached by deadline)
event BuybackTriggered(
    uint256 totalRaised,
    uint256 tokensSold,
    uint256 minCap
);

// Emitted when a user claims a buyback refund
event BuybackClaimed(
    address indexed user,
    address indexed paymentToken,
    uint256 campaignTokensBurned,
    uint256 refundAmount
);

// Emitted on emergency pause/unpause
// Emitted when a user enters the sell-back queue
event SellBackRequested(
    address indexed user,
    uint256 amount,
    uint256 queuePosition
);

// Emitted when a sell-back order is (partially) filled by a new buyer
event SellBackFilled(
    address indexed seller,
    address indexed buyer,
    address paymentToken,
    uint256 campaignTokenAmount,
    uint256 paymentAmount,
    uint256 remainingInQueue
);

// Emitted when a user cancels their sell-back request
event SellBackCancelled(
    address indexed user,
    uint256 amountReturned
);

event CampaignPaused(bool paused);
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
