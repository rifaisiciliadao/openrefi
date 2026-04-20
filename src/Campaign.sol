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
    uint256 public protocolFeeBps; // basis points (e.g., 200 = 2%)
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

    // --- Events ---

    event TokensPurchased(
        address indexed buyer,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 campaignTokensOut,
        uint256 oraclePriceUsed,
        uint256 newCurrentSupply
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

    function initialize(
        address producer_,
        address factory_,
        uint256 pricePerToken_,
        uint256 minCap_,
        uint256 maxCap_,
        uint256 fundingDeadline_,
        uint256 seasonDuration_,
        uint256 protocolFeeBps_,
        address protocolFeeRecipient_,
        address sequencerUptimeFeed_
    ) external initializer {
        __Pausable_init();
        producer = producer_;
        factory = factory_;
        pricePerToken = pricePerToken_;
        minCap = minCap_;
        maxCap = maxCap_;
        fundingDeadline = fundingDeadline_;
        seasonDuration = seasonDuration_;
        protocolFeeBps = protocolFeeBps_;
        protocolFeeRecipient = protocolFeeRecipient_;
        sequencerUptimeFeed = AggregatorV3Interface(sequencerUptimeFeed_);
        state = State.Funding;
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

        // Transfer payment from buyer
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), paymentAmount);

        // Track purchase for buyback refunds (only in Funding state where buyback is possible)
        if (state == State.Funding) {
            purchases[msg.sender][paymentToken] += paymentAmount;
            purchasedTokens[msg.sender][paymentToken] += tokensOut;
        }

        uint256 paymentRemaining = paymentAmount;
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
    function previewBuy(address paymentToken, uint256 paymentAmount)
        external
        view
        returns (uint256 tokensOut, uint256 effectivePayment, uint256 oraclePrice)
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

        // Release escrowed funds to producer. Skip inactive tokens (producer
        // removed them; nobody should have deposited after, but guard anyway).
        uint256 len = acceptedTokenList.length;
        for (uint256 i = 0; i < len; i++) {
            address token = acceptedTokenList[i];
            if (!tokenConfigs[token].active) continue;
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                uint256 fee = balance * protocolFeeBps / 10_000;
                if (fee > 0) {
                    IERC20(token).safeTransfer(protocolFeeRecipient, fee);
                }
                uint256 toProducer = balance - fee;
                if (toProducer > 0) {
                    IERC20(token).safeTransfer(producer, toProducer);
                }
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
