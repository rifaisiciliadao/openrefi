// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {CampaignToken} from "./CampaignToken.sol";
import {StakingVault} from "./StakingVault.sol";
import {HarvestManager} from "./HarvestManager.sol";

/// @title Campaign — Token Sales, Escrow, Sell-Back Queue, Buyback
/// @notice Handles $CAMPAIGN token sales with multi-token support.
///         Funds are escrowed during Funding, released to producer on activation.
///         Failed campaigns allow full buyback refunds.
/// @dev    Initializable so it can be deployed as an EIP-1167 clone. Once a
///         clone is initialized, its configuration (producer, caps, fee, oracle,
///         etc.) is immutable for the life of the campaign.
contract Campaign is Initializable, ReentrancyGuard, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // --- Enums ---

    enum State {
        Funding,
        Active,
        Buyback,
        Ended
    }

    enum PricingMode {
        Fixed,
        Oracle
    }

    // --- Structs ---

    struct TokenConfig {
        PricingMode pricingMode;
        uint256 fixedRate; // payment tokens per 1 $CAMPAIGN (18 decimals). 0 if oracle mode.
        AggregatorV3Interface oracleFeed; // address(0) if fixed mode
        uint8 paymentDecimals; // cached IERC20Metadata.decimals() at add-time; used to normalize oracle math
        bool active;
    }

    struct SellBackOrder {
        address seller;
        uint256 amount; // $CAMPAIGN tokens remaining in this order
    }

    // --- Constants ---

    /// @notice Hard cap on the number of payment tokens ever added to a campaign.
    ///         Bounds the gas cost of the _activate loop so a malicious or
    ///         careless producer cannot brick activation by adding too many tokens.
    uint256 public constant MAX_ACCEPTED_TOKENS = 10;

    /// @notice Chainlink-standard grace period for L2 sequencer recovery.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    /// @notice Cap on simultaneous open sell-back orders per user.
    ///         Bounds `_fillSellBackQueue` work so a sybil cannot sprinkle dust
    ///         orders and grief every subsequent `buy` with linear scans.
    uint256 public constant MAX_OPEN_SELLBACK_ORDERS_PER_USER = 50;

    // --- State ---

    CampaignToken public campaignToken;
    StakingVault public stakingVault;
    address public producer;
    address public factory;
    bool private _campaignTokenSet;
    bool private _stakingVaultSet;
    uint256 public pricePerToken; // USD price per $CAMPAIGN, 18 decimals (e.g., 0.144e18)
    uint256 public minCap; // minimum tokens to sell
    uint256 public maxCap; // maximum tokens mintable
    uint256 public fundingDeadline;
    uint256 public seasonDuration;
    /// @custom:deprecated Was the activation-time 2% fee skimmed off escrow in
    ///                   `_activate`. Replaced by the per-`buy()` `fundingFeeBps`
    ///                   skim. Kept in storage for upgrade-safety; the value is
    ///                   written by `initialize` (for call-site compatibility)
    ///                   but no code reads it anymore.
    uint256 public protocolFeeBps;
    /// @notice Sink for the per-`buy()` funding fee. Also used as the sink for any
    ///         future Campaign-level fees. Snapshotted from the factory at init.
    address public protocolFeeRecipient;
    /// @notice Chainlink L2 sequencer-uptime feed address; `address(0)` on L1.
    AggregatorV3Interface public sequencerUptimeFeed;

    State public state;
    uint256 public currentSupply;

    // Payment token configs
    address[] public acceptedTokenList;
    mapping(address => TokenConfig) public tokenConfigs;

    // Buyback tracking: user => paymentToken => amount paid
    mapping(address => mapping(address => uint256)) public purchases;
    // Buyback tracking: user => paymentToken => $CAMPAIGN tokens purchased with that token
    mapping(address => mapping(address => uint256)) public purchasedTokens;

    // Sell-back queue (FIFO)
    SellBackOrder[] public sellBackQueue;
    uint256 public sellBackQueueHead;
    // Track per-user pending sell-back amount
    mapping(address => uint256) public pendingSellBack;
    // Track per-user queue indices for efficient cancellation
    mapping(address => uint256[]) public userSellBackIndices;
    // Track per-user count of still-open sell-back orders (≤ MAX_OPEN_SELLBACK_ORDERS_PER_USER).
    mapping(address => uint256) public openSellBackCount;

    // --- Appended storage (v2 — funding fee at buy time) ---

    /// @notice Funding-side fee in basis points, applied on every `buy()` gross inflow.
    ///         Non-refundable on buyback — this is the protocol's "ticket fee" for
    ///         hosting the campaign regardless of outcome. The yield-side 2% lives
    ///         separately in `HarvestManager.protocolFeeBps`. On fresh campaigns
    ///         this is written by `initialize`; on existing pre-v2 campaigns it is
    ///         seeded by `initializeV2` during the upgrade dance.
    uint256 public fundingFeeBps;

    // --- Appended storage (v3 — productive-asset metadata + collateral) ---

    /// @notice Producer's commitment: expected annual harvest value in USD,
    ///         18 decimals (e.g. 5_000e18 = $5,000/yr). The frontend derives
    ///         every other figure from this single number:
    ///           bps          = annual × 10_000 / (maxCap × pricePerToken)
    ///           harvestsToRepay = (maxCap × pricePerToken) / annual
    ///           recommendedCollateral = annual × coverageHarvests
    ///         Immutable after init.
    uint256 public expectedAnnualHarvestUsd;

    /// @notice Producer's commitment: calendar year of the first reportable
    ///         harvest (e.g. 2030). Used by the frontend to label subsequent
    ///         harvests as Year 1 → 2030, Year 2 → 2031, etc. Stored as a
    ///         plain integer year, NOT a timestamp — the on-chain season
    ///         lifecycle is driven by `seasonDuration` + `startSeason` calls,
    ///         independent of this commitment. Immutable.
    uint256 public firstHarvestYear;

    /// @notice Number of upcoming harvests pre-funded by `collateralLocked`.
    ///         Bounds `settleSeasonShortfall(seasonId)` to `seasonId ≤ coverageHarvests`.
    ///         Immutable after init.
    uint256 public coverageHarvests;

    /// @notice Cached USDC token used for collateral & shortfall settlement.
    ///         Snapshotted from `factory.usdc()` at init.
    IERC20 public usdc;

    /// @notice Owning HarvestManager. Wired post-deploy via `setHarvestManager`.
    HarvestManager public harvestManager;
    bool private _harvestManagerSet;

    /// @notice Total USDC the producer has locked as a pre-paid yield reserve.
    ///         Cumulative; producer can `lockCollateral(amount)` repeatedly during
    ///         Active state but never withdraw early — the lock is one-way.
    uint256 public collateralLocked;

    /// @notice Total USDC drawn from the reserve to cover holder shortfalls.
    ///         Always ≤ `collateralLocked`.
    uint256 public collateralDrawn;

    /// @notice Once-only guard so each covered season's shortfall settles at most once.
    mapping(uint256 => bool) public seasonShortfallSettled;

    // --- Events ---

    event TokensPurchased(
        address indexed buyer,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 campaignTokensOut,
        uint256 oraclePriceUsed,
        uint256 newCurrentSupply
    );

    event FundingFeeCollected(
        address indexed buyer,
        address indexed paymentToken,
        uint256 fee
    );

    /// @notice Producer locked additional USDC into the pre-paid yield reserve.
    event CollateralLocked(
        address indexed producer,
        uint256 amount,
        uint256 newCollateralLocked
    );

    /// @notice `settleSeasonShortfall` covered the gap between producer's
    ///         depositUSDC and the season's `usdcOwed` for `seasonId`.
    event CollateralShortfallSettled(
        uint256 indexed seasonId,
        uint256 amountDrawn,
        uint256 newCollateralDrawn
    );

    event AcceptedTokenAdded(
        address indexed tokenAddress, string symbol, uint8 pricingMode, uint256 fixedRate, address oracleFeed
    );

    event AcceptedTokenRemoved(address indexed tokenAddress);

    event CampaignStateChanged(uint8 oldState, uint8 newState);
    event CampaignActivated(uint256 totalRaised, uint256 tokensSold);
    event BuybackTriggered(uint256 totalRaised, uint256 tokensSold, uint256 minCap_);
    event BuybackClaimed(
        address indexed user, address indexed paymentToken, uint256 campaignTokensBurned, uint256 refundAmount
    );

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
    event CampaignPaused(bool paused);
    event FundingDeadlineUpdated(uint256 oldDeadline, uint256 newDeadline);
    event MinCapUpdated(uint256 oldMinCap, uint256 newMinCap);
    event MaxCapUpdated(uint256 oldMaxCap, uint256 newMaxCap);

    // --- Errors ---

    error OnlyProducer();
    error OnlyFactory();
    error InvalidState(State expected, State actual);
    error TokenNotAccepted();
    error MaxCapReached();
    error ZeroAmount();
    error FundingNotExpired();
    error MinCapAlreadyReached();
    error NothingToRefund();
    error NoSellBackPending();
    error StaleOraclePrice();
    error NegativeOraclePrice();
    error TooManyAcceptedTokens();
    error PaymentDecimalsTooHigh();
    error SequencerDown();
    error SequencerGracePeriod();
    error TooManyOpenSellBackOrders();
    error AlreadySet();
    error MinCapNotReached();
    error DeadlineNotExtended();
    error DeadlineInPast();
    error NewMinCapBelowSupply();
    error NewMaxCapBelowCommitted();
    error InvalidCoverageHarvests();
    error InvalidYearlyReturn();
    error OutOfCoverage();
    error AlreadySettled();
    error SeasonNotReported();
    error DeadlineNotReached();
    error NoCollateralAvailable();

    // --- Modifiers ---

    modifier onlyProducer() {
        if (msg.sender != producer) revert OnlyProducer();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier inState(State expected) {
        if (state != expected) revert InvalidState(expected, state);
        _;
    }

    // --- Constructor ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Per-campaign init params, packed into a struct because the flat
    ///         signature crossed the Solidity stack limit at 12 params.
    struct InitParams {
        address producer;
        address factory;
        uint256 pricePerToken;
        uint256 minCap;
        uint256 maxCap;
        uint256 fundingDeadline;
        uint256 seasonDuration;
        // Legacy zombie — written for layout compat, never read.
        uint256 protocolFeeBps;
        // 3% per `buy()` gross inflow, forwarded to `protocolFeeRecipient`.
        uint256 fundingFeeBps;
        // Expected annual harvest value in USD, 18-dec (e.g. 5_000e18 = $5,000/yr).
        uint256 expectedAnnualHarvestUsd;
        // Calendar year of the first reportable harvest (e.g. 2030).
        uint256 firstHarvestYear;
        // Number of upcoming harvests pre-funded via `lockCollateral`.
        uint256 coverageHarvests;
        address protocolFeeRecipient;
        address sequencerUptimeFeed;
        // USDC token (used for collateral lock + shortfall settlement).
        address usdc;
    }

    function initialize(InitParams calldata p) external initializer {
        __Pausable_init();
        producer = p.producer;
        factory = p.factory;
        pricePerToken = p.pricePerToken;
        minCap = p.minCap;
        maxCap = p.maxCap;
        fundingDeadline = p.fundingDeadline;
        seasonDuration = p.seasonDuration;
        protocolFeeBps = p.protocolFeeBps;
        fundingFeeBps = p.fundingFeeBps;
        expectedAnnualHarvestUsd = p.expectedAnnualHarvestUsd;
        firstHarvestYear = p.firstHarvestYear;
        coverageHarvests = p.coverageHarvests;
        protocolFeeRecipient = p.protocolFeeRecipient;
        sequencerUptimeFeed = AggregatorV3Interface(p.sequencerUptimeFeed);
        usdc = IERC20(p.usdc);
        state = State.Funding;
    }

    /// @notice One-shot reinitializer for campaigns deployed before the v2
    ///         Campaign impl (no per-`buy()` funding fee). Seeds the new
    ///         `fundingFeeBps` slot. Called in the same tx as the proxy
    ///         upgrade via `ProxyAdmin.upgradeAndCall(proxy, newImpl, initData)`.
    function initializeV2(uint256 fundingFeeBps_) external reinitializer(2) {
        fundingFeeBps = fundingFeeBps_;
    }

    /// @notice One-shot reinitializer for campaigns deployed before v3 (no
    ///         annual-harvest commitment, no first-harvest year, no coverage,
    ///         no collateral). Seeds the new immutable v3 slots. Called via
    ///         `ProxyAdmin.upgradeAndCall(proxy, newImpl, initializeV3(...))`.
    function initializeV3(
        uint256 expectedAnnualHarvestUsd_,
        uint256 firstHarvestYear_,
        uint256 coverageHarvests_,
        address usdc_
    ) external reinitializer(3) {
        expectedAnnualHarvestUsd = expectedAnnualHarvestUsd_;
        firstHarvestYear = firstHarvestYear_;
        coverageHarvests = coverageHarvests_;
        usdc = IERC20(usdc_);
    }

    /// @notice Set the CampaignToken address. Can only be called once by the factory.
    function setCampaignToken(address campaignToken_) external onlyFactory {
        if (_campaignTokenSet) revert AlreadySet();
        campaignToken = CampaignToken(campaignToken_);
        _campaignTokenSet = true;
    }

    /// @notice Wire the StakingVault. Called by factory during setup.
    function setStakingVault(address stakingVault_) external onlyFactory {
        if (_stakingVaultSet) revert AlreadySet();
        stakingVault = StakingVault(stakingVault_);
        _stakingVaultSet = true;
        campaignToken.setStakingVault(stakingVault_);
    }

    /// @notice Wire the YieldToken on the StakingVault. Called by factory during setup.
    function setYieldToken(address yieldToken_) external onlyFactory {
        stakingVault.setYieldToken(yieldToken_);
    }

    /// @notice Wire the owning HarvestManager. Called once by the factory after
    ///         the HarvestManager proxy is deployed. Required for
    ///         `settleSeasonShortfall` to top up holder claims out of collateral.
    function setHarvestManager(address harvestManager_) external onlyFactory {
        if (_harvestManagerSet) revert AlreadySet();
        harvestManager = HarvestManager(harvestManager_);
        _harvestManagerSet = true;
    }

    // --- Producer Collateral (Pre-Paid Yield Reserve) ---

    /// @notice Lock additional USDC into the campaign's pre-paid yield reserve.
    ///         Cumulative; producer can call this multiple times. There is NO
    ///         early-withdrawal path — the lock is one-way until the
    ///         `coverageHarvests` window's settlements run their course (and
    ///         even then, residuals stay in the contract per the v3 commitment
    ///         model). State guard: Funding (so collateral is visible to buyers
    ///         pre-activation) or Active. Disallowed in Buyback / Ended.
    /// @param amount Native-decimals USDC (6-dec on mainnet; 6-dec MockUSDC).
    function lockCollateral(uint256 amount) external onlyProducer nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (state != State.Funding && state != State.Active) revert InvalidState(State.Active, state);
        if (address(usdc) == address(0)) revert AlreadySet(); // pre-v3 campaign — must reinitialize first

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        collateralLocked += amount;

        emit CollateralLocked(msg.sender, amount, collateralLocked);
    }

    /// @notice Permissionless settlement of a covered season's shortfall.
    ///         For `seasonId ∈ [1..coverageHarvests]`, after the season's
    ///         `usdcDeadline` has passed: if the producer's `depositUSDC`
    ///         left a gap (`remainingDepositGross > 0`), this function pulls
    ///         up to that gap from `collateralLocked` and forwards it to the
    ///         HarvestManager so holders can `claimUSDC` normally. Marks the
    ///         season settled so the draw cannot run twice.
    ///
    /// @dev    Intentionally NOT `whenNotPaused`: holder protection path must
    ///         remain available even during an emergency pause (mirrors the
    ///         policy on `unstake` and `buyback`).
    function settleSeasonShortfall(uint256 seasonId) external nonReentrant {
        if (seasonId == 0 || seasonId > coverageHarvests) revert OutOfCoverage();
        if (seasonShortfallSettled[seasonId]) revert AlreadySettled();
        if (address(harvestManager) == address(0)) revert AlreadySet();

        // Read season state from HM. The auto-getter for SeasonHarvest returns
        // a tuple in struct-declaration order:
        //   (merkleRoot, totalHarvestValueUSD, totalYieldSupply, totalProductUnits,
        //    claimStart, claimEnd, usdcDeadline, usdcDeposited, usdcOwed,
        //    protocolFeeCollected, protocolFeeTransferred, reported)
        (
            ,                          // merkleRoot
            ,                          // totalHarvestValueUSD
            ,                          // totalYieldSupply
            ,                          // totalProductUnits
            ,                          // claimStart
            ,                          // claimEnd
            uint256 deadline,          // usdcDeadline
            ,                          // usdcDeposited
            ,                          // usdcOwed
            ,                          // protocolFeeCollected
            ,                          // protocolFeeTransferred
            bool reported              // reported flag
        ) = harvestManager.seasonHarvests(seasonId);
        if (!reported) revert SeasonNotReported();
        if (block.timestamp <= deadline) revert DeadlineNotReached();

        uint256 remaining = harvestManager.remainingDepositGross(seasonId);
        uint256 available = collateralLocked - collateralDrawn;

        // Idempotent flag set BEFORE any external transfer: re-entrancy hardening.
        seasonShortfallSettled[seasonId] = true;

        if (remaining == 0 || available == 0) {
            // Nothing to draw; emit a zero-amount event so the subgraph
            // can mark the season as "settlement attempted" and stop polling.
            emit CollateralShortfallSettled(seasonId, 0, collateralDrawn);
            return;
        }

        uint256 draw = remaining < available ? remaining : available;
        collateralDrawn += draw;

        usdc.safeIncreaseAllowance(address(harvestManager), draw);
        harvestManager.depositFromCollateral(seasonId, draw);

        emit CollateralShortfallSettled(seasonId, draw, collateralDrawn);
    }


    // --- Season Management ---

    /// @notice Start a new staking season. Only callable by producer when campaign is Active.
    function startSeason(uint256 seasonId) external onlyProducer inState(State.Active) {
        stakingVault.startSeason(seasonId);
    }

    /// @notice End the current staking season. Only callable by producer.
    function endSeason() external onlyProducer inState(State.Active) {
        stakingVault.endSeason();
    }

    // --- Campaign parameter updates ---
    //
    // Immutable-by-default was nice for trust-on-first-sight, but a producer
    // whose funding window slips short (e.g. marketing delay, seasonal cycle
    // shifted) used to have to upgrade the proxy through their ProxyAdmin
    // just to move the deadline. Since the producer already owns the proxy
    // admin they can always rewrite anything anyway, so the setters below
    // don't widen the trust model — they just skip the impl-redeploy dance
    // for the three parameters producers realistically want to tune.
    //
    // Guard-rails:
    //   - setFundingDeadline only extends (never cuts short — buyers who
    //     entered during Funding expected at least the original window).
    //   - setMinCap / setMaxCap only before activation and only above the
    //     already-committed supply, so neither can retroactively flip the
    //     campaign into Active with surprise terms or invalidate sales.
    //   - setMaxCap can also be called while Active (to loosen the hard cap
    //     if demand exceeds the original plan), but never below currentSupply
    //     + outstanding sell-back queue tokens (those are still claimable).

    /// @notice Extend the funding deadline. Only callable during Funding.
    ///         Cannot shorten — prevents surprise early-rug of buyers.
    function setFundingDeadline(uint256 newDeadline) external onlyProducer {
        if (state != State.Funding) revert InvalidState(State.Funding, state);
        if (newDeadline <= block.timestamp) revert DeadlineInPast();
        if (newDeadline <= fundingDeadline) revert DeadlineNotExtended();
        uint256 oldDeadline = fundingDeadline;
        fundingDeadline = newDeadline;
        emit FundingDeadlineUpdated(oldDeadline, newDeadline);
    }

    /// @notice Change the min cap (soft cap that triggers activation).
    ///         Funding-only. The new value must stay above currentSupply so
    ///         this call cannot retroactively auto-activate the campaign
    ///         behind buyers' backs (activation releases escrow funds).
    function setMinCap(uint256 newMinCap) external onlyProducer {
        if (state != State.Funding) revert InvalidState(State.Funding, state);
        if (newMinCap == 0) revert ZeroAmount();
        if (newMinCap <= currentSupply) revert NewMinCapBelowSupply();
        if (newMinCap > maxCap) revert NewMinCapBelowSupply(); // semantic: min must stay ≤ max
        uint256 oldMinCap = minCap;
        minCap = newMinCap;
        emit MinCapUpdated(oldMinCap, newMinCap);
    }

    /// @notice Change the max cap (hard cap on total minted supply).
    ///         Allowed in Funding and Active; the new value must cover
    ///         currentSupply plus the outstanding sell-back queue tokens
    ///         so no committed position can be stranded.
    function setMaxCap(uint256 newMaxCap) external onlyProducer {
        if (state != State.Funding && state != State.Active) {
            revert InvalidState(State.Active, state);
        }
        if (newMaxCap == 0) revert ZeroAmount();
        uint256 committed = currentSupply + _queueTotalTokens();
        if (newMaxCap < committed) revert NewMaxCapBelowCommitted();
        if (state == State.Funding && newMaxCap < minCap) {
            revert NewMaxCapBelowCommitted(); // min must stay ≤ max
        }
        uint256 oldMaxCap = maxCap;
        maxCap = newMaxCap;
        emit MaxCapUpdated(oldMaxCap, newMaxCap);
    }

    // --- Payment Token Management ---

    function addAcceptedToken(address tokenAddress, PricingMode pricingMode, uint256 fixedRate, address oracleFeed)
        external
        onlyProducer
    {
        require(tokenAddress != address(0), "Zero token address");
        require(!tokenConfigs[tokenAddress].active, "Already accepted");
        if (acceptedTokenList.length >= MAX_ACCEPTED_TOKENS) revert TooManyAcceptedTokens();
        if (pricingMode == PricingMode.Fixed) {
            require(fixedRate > 0, "Zero fixedRate");
        } else {
            require(oracleFeed != address(0), "Zero oracle address");
        }
        uint8 dec = IERC20Metadata(tokenAddress).decimals();
        if (dec > 18) revert PaymentDecimalsTooHigh();
        tokenConfigs[tokenAddress] = TokenConfig({
            pricingMode: pricingMode,
            fixedRate: fixedRate,
            oracleFeed: AggregatorV3Interface(oracleFeed),
            paymentDecimals: dec,
            active: true
        });
        acceptedTokenList.push(tokenAddress);
        emit AcceptedTokenAdded(tokenAddress, "", uint8(pricingMode), fixedRate, oracleFeed);
    }

    function removeAcceptedToken(address tokenAddress) external onlyProducer {
        require(tokenConfigs[tokenAddress].active, "Not accepted");
        tokenConfigs[tokenAddress].active = false;

        // Swap-and-pop to free the whitelist slot (otherwise MAX_ACCEPTED_TOKENS
        // bricks the whitelist after N add/remove cycles even when none are live).
        uint256 len = acceptedTokenList.length;
        for (uint256 i = 0; i < len; i++) {
            if (acceptedTokenList[i] == tokenAddress) {
                if (i != len - 1) {
                    acceptedTokenList[i] = acceptedTokenList[len - 1];
                }
                acceptedTokenList.pop();
                break;
            }
        }

        emit AcceptedTokenRemoved(tokenAddress);
    }

    // --- Buy ---

    /// @notice Purchase $CAMPAIGN tokens with an accepted ERC20.
    /// @param paymentToken The ERC20 token to pay with.
    /// @param paymentAmount The amount of payment tokens to spend.
    function buy(address paymentToken, uint256 paymentAmount) external nonReentrant whenNotPaused {
        if (state != State.Funding && state != State.Active) revert InvalidState(State.Funding, state);
        if (paymentAmount == 0) revert ZeroAmount();
        if (!tokenConfigs[paymentToken].active) revert TokenNotAccepted();

        // How many tokens can actually be supplied?
        //   - `mintableRoom`: new mints up to maxCap (Funding & Active).
        //   - `queueTokens`: existing $CAMPAIGN parked in the sell-back queue
        //     (Active only). Fills are burn+mint → supply-neutral, so they
        //     do NOT consume mintableRoom and remain available even at cap.
        // Revert only when BOTH are zero — otherwise sellers at cap would be
        // permanently stuck with no exit path.
        uint256 mintableRoom = currentSupply < maxCap ? maxCap - currentSupply : 0;
        uint256 queueTokens = state == State.Active ? _queueTotalTokens() : 0;
        uint256 buyableMax = mintableRoom + queueTokens;
        if (buyableMax == 0) revert MaxCapReached();

        // Calculate how many $CAMPAIGN tokens the payment buys
        (uint256 tokensOut, uint256 oraclePrice) = _calculateTokensOut(paymentToken, paymentAmount);
        if (tokensOut > buyableMax) {
            tokensOut = buyableMax;
            // Recalculate actual payment needed
            paymentAmount = _calculatePaymentNeeded(paymentToken, tokensOut, oraclePrice);
        }

        // Transfer payment from buyer (GROSS)
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), paymentAmount);

        // Skim the funding fee off the top and forward to the protocol recipient.
        // Everything downstream (queue fills, mint path, buyback refunds) operates
        // on the NET amount. Fee is non-refundable on buyback by design — the
        // protocol is paid for hosting the campaign regardless of outcome.
        uint256 fundingFee = paymentAmount * fundingFeeBps / 10_000;
        uint256 netPayment = paymentAmount - fundingFee;
        if (fundingFee > 0 && protocolFeeRecipient != address(0)) {
            IERC20(paymentToken).safeTransfer(protocolFeeRecipient, fundingFee);
            emit FundingFeeCollected(msg.sender, paymentToken, fundingFee);
        }

        // Track purchase for buyback refunds (only in Funding state where buyback is possible).
        // Record NET so `buyback()` refunds exactly what's in escrow; the fee is
        // already in the protocol recipient's wallet and stays there.
        if (state == State.Funding) {
            purchases[msg.sender][paymentToken] += netPayment;
            purchasedTokens[msg.sender][paymentToken] += tokensOut;
        }

        uint256 paymentRemaining = netPayment;
        uint256 tokensToMint = tokensOut;

        // Fill sell-back queue first (only in Active state). Return the exact
        // `remainingTokens` the queue fill DIDN'T consume — avoids round-trip
        // precision drift vs. re-deriving from paymentRemaining.
        if (state == State.Active) {
            (paymentRemaining, tokensToMint) = _fillSellBackQueue(paymentToken, paymentRemaining, tokensOut, msg.sender);
        }

        // Mint remaining tokens to buyer (if any). After the queue fill, this
        // only runs when there's fresh supply to mint — invariantly bounded
        // by `mintableRoom` thanks to the `buyableMax` clamp above.
        if (paymentRemaining > 0 && tokensToMint > 0) {
            if (state == State.Active) {
                // Funds go to producer
                IERC20(paymentToken).safeTransfer(producer, paymentRemaining);
            }
            // In Funding state, funds stay in escrow (this contract)

            campaignToken.mint(msg.sender, tokensToMint);
            currentSupply += tokensToMint;
        }

        emit TokensPurchased(msg.sender, paymentToken, paymentAmount, tokensOut, oraclePrice, currentSupply);

        // Auto-activate if min cap reached during Funding
        if (state == State.Funding && currentSupply >= minCap) {
            _activate();
        }
    }

    /// @dev Sum of outstanding sell-back queue tokens. O(n) over unfilled
    ///      orders. Internal to avoid external-call cost from `buy()`.
    function _queueTotalTokens() internal view returns (uint256 depth) {
        for (uint256 i = sellBackQueueHead; i < sellBackQueue.length; i++) {
            depth += sellBackQueue[i].amount;
        }
    }

    // --- Sell-Back Queue ---

    /// @notice Deposit $CAMPAIGN into the sell-back queue. Only in Active state.
    function sellBack(uint256 amount) external nonReentrant whenNotPaused inState(State.Active) {
        if (amount == 0) revert ZeroAmount();
        if (openSellBackCount[msg.sender] >= MAX_OPEN_SELLBACK_ORDERS_PER_USER) revert TooManyOpenSellBackOrders();
        // Transfer $CAMPAIGN from user to this contract
        IERC20(address(campaignToken)).safeTransferFrom(msg.sender, address(this), amount);

        uint256 queueIndex = sellBackQueue.length;
        sellBackQueue.push(SellBackOrder({seller: msg.sender, amount: amount}));
        pendingSellBack[msg.sender] += amount;
        userSellBackIndices[msg.sender].push(queueIndex);
        openSellBackCount[msg.sender]++;

        emit SellBackRequested(msg.sender, amount, queueIndex);
    }

    /// @notice Cancel pending sell-back and get $CAMPAIGN back (unfilled portion).
    function cancelSellBack() external nonReentrant {
        if (pendingSellBack[msg.sender] == 0) revert NoSellBackPending();

        uint256 returned = 0;
        uint256[] storage indices = userSellBackIndices[msg.sender];
        for (uint256 i = 0; i < indices.length; i++) {
            uint256 idx = indices[i];
            if (idx >= sellBackQueueHead && sellBackQueue[idx].amount > 0) {
                returned += sellBackQueue[idx].amount;
                sellBackQueue[idx].amount = 0;
            }
        }
        delete userSellBackIndices[msg.sender];

        pendingSellBack[msg.sender] = 0;
        openSellBackCount[msg.sender] = 0;
        if (returned > 0) {
            IERC20(address(campaignToken)).safeTransfer(msg.sender, returned);
        }

        emit SellBackCancelled(msg.sender, returned);
    }

    // --- Buyback (Failed Campaign) ---

    /// @notice Trigger buyback state if funding deadline passed and min cap not reached.
    function triggerBuyback() external {
        if (state != State.Funding) revert InvalidState(State.Funding, state);
        if (block.timestamp < fundingDeadline) revert FundingNotExpired();
        if (currentSupply >= minCap) revert MinCapAlreadyReached();

        State oldState = state;
        state = State.Buyback;
        emit CampaignStateChanged(uint8(oldState), uint8(state));
        emit BuybackTriggered(0, currentSupply, minCap);
    }

    /// @notice Claim buyback refund for a specific payment token. Burns proportional $CAMPAIGN, returns original payment.
    /// @param paymentToken The token to claim refund in (must match original purchase).
    /// @dev    Deliberately NOT gated by `whenNotPaused`: buyback is the refund
    ///         path for a failed campaign and must remain available even if
    ///         the factory pauses the contract for some other emergency.
    function buyback(address paymentToken) external nonReentrant inState(State.Buyback) {
        uint256 refundAmount = purchases[msg.sender][paymentToken];
        if (refundAmount == 0) revert NothingToRefund();

        uint256 userTokens = purchasedTokens[msg.sender][paymentToken];
        purchases[msg.sender][paymentToken] = 0;
        purchasedTokens[msg.sender][paymentToken] = 0;

        // Burn only the $CAMPAIGN tokens purchased with this specific payment token
        campaignToken.burn(msg.sender, userTokens);
        currentSupply -= userTokens;

        // Refund original payment
        IERC20(paymentToken).safeTransfer(msg.sender, refundAmount);

        emit BuybackClaimed(msg.sender, paymentToken, userTokens, refundAmount);
    }

    // --- State Transitions ---

    /// @notice Manually activate campaign (alternative to auto-activation on minCap).
    function activateCampaign() external onlyProducer inState(State.Funding) {
        if (currentSupply < minCap) revert MinCapNotReached();
        _activate();
    }

    function endCampaign() external onlyProducer inState(State.Active) {
        State oldState = state;
        state = State.Ended;
        emit CampaignStateChanged(uint8(oldState), uint8(state));
    }

    // --- Pause ---

    function emergencyPause() external onlyFactory {
        _pause();
        emit CampaignPaused(true);
    }

    function emergencyUnpause() external onlyFactory {
        _unpause();
        emit CampaignPaused(false);
    }

    // --- Views ---

    function getPrice(address paymentToken, uint256 campaignAmount) external view returns (uint256) {
        TokenConfig storage config = tokenConfigs[paymentToken];
        if (!config.active) revert TokenNotAccepted();
        if (config.pricingMode == PricingMode.Fixed) {
            return campaignAmount * config.fixedRate / 1e18;
        } else {
            (uint256 oraclePrice,) = _getOraclePrice(config.oracleFeed);
            // payment_native = campaignAmount(18dec) * pricePerToken(18dec) / oraclePrice(18dec) / 10**(18-paymentDecimals)
            uint256 scale = 10 ** (18 - config.paymentDecimals);
            return campaignAmount * pricePerToken / oraclePrice / scale;
        }
    }

    /// @notice On-chain preview for `buy`: given a payment amount, return how many
    ///         $CAMPAIGN tokens the buyer receives and how much of the payment is
    ///         actually consumed (cropped if `tokensOut` would overflow `maxCap`).
    /// @dev    Does NOT simulate sell-back queue fills — the net tokens received
    ///         by the buyer is identical either way (queue fill burns+mints 1:1);
    ///         the breakdown matters only for gas accounting, not for UX pricing.
    /// @return tokensOut        $CAMPAIGN minted to the buyer for this payment.
    /// @return effectivePayment GROSS amount that will be pulled from the wallet (pre-fee).
    /// @return oraclePrice      Oracle price used (0 for fixed-rate tokens).
    /// @return fundingFee       Portion of `effectivePayment` that will be skimmed to the protocol.
    function previewBuy(address paymentToken, uint256 paymentAmount)
        external
        view
        returns (uint256 tokensOut, uint256 effectivePayment, uint256 oraclePrice, uint256 fundingFee)
    {
        if (paymentAmount == 0) revert ZeroAmount();
        if (!tokenConfigs[paymentToken].active) revert TokenNotAccepted();
        (uint256 rawOut, uint256 rawOracle) = _calculateTokensOut(paymentToken, paymentAmount);
        oraclePrice = rawOracle;
        uint256 available = maxCap - currentSupply;
        if (rawOut > available) {
            tokensOut = available;
            effectivePayment = _calculatePaymentNeeded(paymentToken, tokensOut, rawOracle);
        } else {
            tokensOut = rawOut;
            effectivePayment = paymentAmount;
        }
        fundingFee = effectivePayment * fundingFeeBps / 10_000;
    }

    function getSellBackQueueDepth() external view returns (uint256) {
        return _queueTotalTokens();
    }

    function getAcceptedTokens() external view returns (address[] memory) {
        return acceptedTokenList;
    }

    // --- Internal ---

    function _activate() internal {
        State oldState = state;
        state = State.Active;

        // Release escrowed funds to producer. Fees were already skimmed at buy()
        // time, so the escrow balance is already net — no further split here.
        // Skip inactive tokens (producer removed them; nobody should have
        // deposited after, but guard anyway).
        uint256 len = acceptedTokenList.length;
        for (uint256 i = 0; i < len; i++) {
            address token = acceptedTokenList[i];
            if (!tokenConfigs[token].active) continue;
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(producer, balance);
            }
        }

        emit CampaignStateChanged(uint8(oldState), uint8(state));
        emit CampaignActivated(0, currentSupply);
    }

    function _calculateTokensOut(address paymentToken, uint256 paymentAmount)
        internal
        view
        returns (uint256 tokensOut, uint256 oraclePrice)
    {
        TokenConfig storage config = tokenConfigs[paymentToken];
        if (config.pricingMode == PricingMode.Fixed) {
            // fixedRate = payment tokens (native decimals) per 1e18 $CAMPAIGN; producer bakes decimals in
            tokensOut = paymentAmount * 1e18 / config.fixedRate;
            oraclePrice = 0;
        } else {
            (oraclePrice,) = _getOraclePrice(config.oracleFeed);
            // Normalize payment (native dec) to 18 dec, then: tokensOut = paymentUSD / pricePerToken
            uint256 scale = 10 ** (18 - config.paymentDecimals);
            tokensOut = paymentAmount * scale * oraclePrice / pricePerToken;
        }
    }

    function _calculatePaymentNeeded(address paymentToken, uint256 tokensOut, uint256 oraclePrice)
        internal
        view
        returns (uint256)
    {
        TokenConfig storage config = tokenConfigs[paymentToken];
        if (config.pricingMode == PricingMode.Fixed) {
            return tokensOut * config.fixedRate / 1e18;
        } else {
            uint256 scale = 10 ** (18 - config.paymentDecimals);
            return tokensOut * pricePerToken / oraclePrice / scale;
        }
    }

    function _getOraclePrice(AggregatorV3Interface feed) internal view returns (uint256 price, uint8 decimals) {
        // Chainlink L2 sequencer-uptime guard (Arbitrum, Base, Optimism, …).
        // answer == 0 → sequencer up; answer == 1 → sequencer down.
        // After recovery, observations within the grace period are still unsafe.
        if (address(sequencerUptimeFeed) != address(0)) {
            (, int256 seqAnswer, uint256 seqStartedAt,,) = sequencerUptimeFeed.latestRoundData();
            if (seqAnswer == 1) revert SequencerDown();
            if (block.timestamp - seqStartedAt < SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriod();
        }

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (answer <= 0) revert NegativeOraclePrice();
        if (startedAt == 0) revert StaleOraclePrice();
        if (answeredInRound < roundId) revert StaleOraclePrice();
        if (block.timestamp - updatedAt > 1 hours) revert StaleOraclePrice();
        decimals = feed.decimals();
        require(decimals <= 18, "Oracle decimals > 18");
        // Normalize to 18 decimals
        price = uint256(answer) * 10 ** (18 - decimals);
    }

    function _fillSellBackQueue(
        address paymentToken,
        uint256 paymentAmount,
        uint256 totalTokensForPayment,
        address buyer
    ) internal returns (uint256 remainingPayment, uint256 remainingTokens) {
        remainingPayment = paymentAmount;
        remainingTokens = totalTokensForPayment;

        while (remainingPayment > 0 && sellBackQueueHead < sellBackQueue.length) {
            SellBackOrder storage order = sellBackQueue[sellBackQueueHead];
            if (order.amount == 0) {
                sellBackQueueHead++;
                continue;
            }

            uint256 fillAmount = order.amount;
            if (fillAmount > remainingTokens) {
                fillAmount = remainingTokens;
            }

            // Calculate payment for this fill
            uint256 paymentForFill = fillAmount * paymentAmount / totalTokensForPayment;
            if (paymentForFill > remainingPayment) {
                paymentForFill = remainingPayment;
            }

            // Pay the seller
            IERC20(paymentToken).safeTransfer(order.seller, paymentForFill);

            // Burn seller's $CAMPAIGN, mint to buyer
            campaignToken.burn(address(this), fillAmount);
            campaignToken.mint(buyer, fillAmount);
            // Net supply change: zero

            pendingSellBack[order.seller] -= fillAmount;
            order.amount -= fillAmount;
            remainingPayment -= paymentForFill;
            remainingTokens -= fillAmount;

            emit SellBackFilled(order.seller, buyer, paymentToken, fillAmount, paymentForFill, order.amount);

            if (order.amount == 0) {
                sellBackQueueHead++;
                if (openSellBackCount[order.seller] > 0) {
                    openSellBackCount[order.seller]--;
                }
            }
        }
    }
}
