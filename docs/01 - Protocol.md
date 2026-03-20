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

**State:**
- `pricePerToken` — base price denominated in USD (e.g., $0.144)
- `minCap` — minimum tokens that must be sold for campaign to proceed
- `maxCap` — maximum tokens mintable (= maxSupply)
- `currentSupply` — tokens minted so far
- `fundingDeadline` — deadline to reach minCap
- `seasonDuration` — season length (≥ 365 days)
- `state` — enum: Funding, Active, Buyback, Ended
- `acceptedTokens[]` — list of accepted ERC20 tokens for payment
- `tokenConfig[address]` — per-token config: pricing mode (fixed or oracle), fixed rate, oracle feed address
- `purchases[user][token]` — tracks each user's payment amounts per token (for buyback refunds)

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

**Functions:**
- `addAcceptedToken(tokenAddress, pricingMode, fixedRate, oracleFeed)` — producer adds a payment token
- `removeAcceptedToken(tokenAddress)` — producer removes a payment token
- `buy(tokenAddress, amount)` — pay with any accepted ERC20, mint $CAMPAIGN. Funds held in escrow until min cap reached, then routes to unstake queue + producer
- `buyback()` — refund user at original purchase price if campaign is in Buyback state. Burns $CAMPAIGN, returns payment tokens
- `activateCampaign()` — called when min cap reached (can be automatic or manual). Releases funds, enables staking
- `triggerBuyback()` — callable by anyone after funding deadline if min cap not reached. Transitions to Buyback state
- `getPrice(tokenAddress, campaignAmount)` — view: returns cost in the specified token for X $CAMPAIGN
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
    uint256 paymentAmount,
    uint256 campaignTokensOut,
    uint256 oraclePriceUsed,     // 0 if fixed mode
    uint256 newCurrentSupply
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
