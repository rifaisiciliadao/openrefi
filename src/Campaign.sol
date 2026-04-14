// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {CampaignToken} from "./CampaignToken.sol";
import {StakingVault} from "./StakingVault.sol";

/// @title Campaign — Token Sales, Escrow, Sell-Back Queue, Buyback
/// @notice Handles $CAMPAIGN token sales with multi-token support.
///         Funds are escrowed during Funding, released to producer on activation.
///         Failed campaigns allow full buyback refunds.
contract Campaign is ReentrancyGuard, Pausable {
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

    // --- State ---

    CampaignToken public campaignToken;
    StakingVault public stakingVault;
    address public immutable producer;
    address public immutable factory;
    bool private _campaignTokenSet;
    bool private _stakingVaultSet;
    uint256 public immutable pricePerToken; // USD price per $CAMPAIGN, 18 decimals (e.g., 0.144e18)
    uint256 public immutable minCap; // minimum tokens to sell
    uint256 public immutable maxCap; // maximum tokens mintable
    uint256 public immutable fundingDeadline;
    uint256 public immutable seasonDuration;
    uint256 public immutable protocolFeeBps; // basis points (e.g., 200 = 2%)
    address public immutable protocolFeeRecipient;

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

    constructor(
        address producer_,
        address factory_,
        uint256 pricePerToken_,
        uint256 minCap_,
        uint256 maxCap_,
        uint256 fundingDeadline_,
        uint256 seasonDuration_,
        uint256 protocolFeeBps_,
        address protocolFeeRecipient_
    ) {
        producer = producer_;
        factory = factory_;
        pricePerToken = pricePerToken_;
        minCap = minCap_;
        maxCap = maxCap_;
        fundingDeadline = fundingDeadline_;
        seasonDuration = seasonDuration_;
        protocolFeeBps = protocolFeeBps_;
        protocolFeeRecipient = protocolFeeRecipient_;
        state = State.Funding;
    }

    /// @notice Set the CampaignToken address. Can only be called once by the factory.
    function setCampaignToken(address campaignToken_) external onlyFactory {
        require(!_campaignTokenSet, "Already set");
        campaignToken = CampaignToken(campaignToken_);
        _campaignTokenSet = true;
    }

    /// @notice Wire the StakingVault. Called by factory during setup.
    function setStakingVault(address stakingVault_) external onlyFactory {
        require(!_stakingVaultSet, "Already set");
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
        tokenConfigs[tokenAddress] = TokenConfig({
            pricingMode: pricingMode, fixedRate: fixedRate, oracleFeed: AggregatorV3Interface(oracleFeed), active: true
        });
        acceptedTokenList.push(tokenAddress);
        emit AcceptedTokenAdded(tokenAddress, "", uint8(pricingMode), fixedRate, oracleFeed);
    }

    function removeAcceptedToken(address tokenAddress) external onlyProducer {
        require(tokenConfigs[tokenAddress].active, "Not accepted");
        tokenConfigs[tokenAddress].active = false;
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
        if (currentSupply >= maxCap) revert MaxCapReached();

        // Calculate how many $CAMPAIGN tokens the payment buys
        (uint256 tokensOut, uint256 oraclePrice) = _calculateTokensOut(paymentToken, paymentAmount);
        uint256 available = maxCap - currentSupply;
        if (tokensOut > available) {
            tokensOut = available;
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

        // Fill sell-back queue first (only in Active state)
        if (state == State.Active) {
            paymentRemaining = _fillSellBackQueue(paymentToken, paymentRemaining, tokensOut, msg.sender);
        }

        // Mint remaining tokens to buyer
        if (paymentRemaining > 0) {
            uint256 tokensToMint = tokensOut;
            if (paymentRemaining < paymentAmount) {
                // Some was used filling queue; calculate remaining tokens
                tokensToMint = _paymentToTokens(paymentToken, paymentRemaining, oraclePrice);
            }

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

    // --- Sell-Back Queue ---

    /// @notice Deposit $CAMPAIGN into the sell-back queue. Only in Active state.
    function sellBack(uint256 amount) external nonReentrant whenNotPaused inState(State.Active) {
        if (amount == 0) revert ZeroAmount();
        // Transfer $CAMPAIGN from user to this contract
        IERC20(address(campaignToken)).safeTransferFrom(msg.sender, address(this), amount);

        uint256 queueIndex = sellBackQueue.length;
        sellBackQueue.push(SellBackOrder({seller: msg.sender, amount: amount}));
        pendingSellBack[msg.sender] += amount;
        userSellBackIndices[msg.sender].push(queueIndex);

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
        require(currentSupply >= minCap, "Min cap not reached");
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
        require(config.active, "Token not accepted");
        if (config.pricingMode == PricingMode.Fixed) {
            return campaignAmount * config.fixedRate / 1e18;
        } else {
            (uint256 oraclePrice,) = _getOraclePrice(config.oracleFeed);
            return campaignAmount * pricePerToken / oraclePrice;
        }
    }

    function getSellBackQueueDepth() external view returns (uint256) {
        uint256 depth = 0;
        for (uint256 i = sellBackQueueHead; i < sellBackQueue.length; i++) {
            depth += sellBackQueue[i].amount;
        }
        return depth;
    }

    function getAcceptedTokens() external view returns (address[] memory) {
        return acceptedTokenList;
    }

    // --- Internal ---

    function _activate() internal {
        State oldState = state;
        state = State.Active;

        // Release escrowed funds to producer
        for (uint256 i = 0; i < acceptedTokenList.length; i++) {
            address token = acceptedTokenList[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                // Deduct protocol fee
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
            // fixedRate = payment tokens per 1 $CAMPAIGN (18 decimals)
            tokensOut = paymentAmount * 1e18 / config.fixedRate;
            oraclePrice = 0;
        } else {
            (oraclePrice,) = _getOraclePrice(config.oracleFeed);
            // paymentValueUSD = paymentAmount * oraclePrice / 1e18
            // tokensOut = paymentValueUSD / pricePerToken
            tokensOut = paymentAmount * oraclePrice / pricePerToken;
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
            return tokensOut * pricePerToken / oraclePrice;
        }
    }

    function _paymentToTokens(address paymentToken, uint256 paymentAmount, uint256 oraclePrice)
        internal
        view
        returns (uint256)
    {
        TokenConfig storage config = tokenConfigs[paymentToken];
        if (config.pricingMode == PricingMode.Fixed) {
            return paymentAmount * 1e18 / config.fixedRate;
        } else {
            return paymentAmount * oraclePrice / pricePerToken;
        }
    }

    function _getOraclePrice(AggregatorV3Interface feed) internal view returns (uint256 price, uint8 decimals) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert NegativeOraclePrice();
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
    ) internal returns (uint256 remainingPayment) {
        remainingPayment = paymentAmount;
        uint256 remainingTokens = totalTokensForPayment;

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
            }
        }
    }
}
