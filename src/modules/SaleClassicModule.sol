// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IGrowfiCampaignTokenMint} from "../interfaces/IGrowfiCampaignTokenMint.sol";
import {IGrowfiMinter} from "../interfaces/IGrowfiMinter.sol";

import {CampaignStorage} from "../host/CampaignStorage.sol";

/// @title  SaleClassicModule
/// @notice Default sale module. Hosts the classic bonding-curve primary
///         sale: multi-token buy, sell-back FIFO queue, funding-fee skim,
///         accepted-tokens registry, buyback refund on Funding-failure.
///
///         Runs in the Campaign's `delegatecall` context. All host-state
///         reads/writes go through `CampaignStorage.layout()`; the
///         module's own state lives in a namespaced slot.
///
///         Storage namespace: `keccak256("growfi.module.sale.classic.v1")`.
contract SaleClassicModule {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum PricingMode {
        Fixed,
        Oracle
    }

    struct TokenConfig {
        PricingMode pricingMode;
        // For fixed mode: how many payment tokens (native dec) per 1e18 $CAMPAIGN.
        uint256 fixedRate;
        AggregatorV3Interface oracleFeed; // address(0) if fixed mode
        uint8 paymentDecimals; // cached at add-time
        bool active;
    }

    struct SellBackOrder {
        address seller;
        uint256 amount;
    }

    /// @notice Module storage layout. Updated only via this module's
    ///         delegate-called code. NEVER touched by other modules or
    ///         by the host directly.
    struct Layout {
        // --- pricing + caps ---
        uint256 pricePerToken; // USD-18 per $CAMPAIGN
        uint256 minCap;
        uint256 maxCap;
        uint256 fundingDeadline;
        uint256 seasonDuration;
        uint256 fundingFeeBps; // protocol fee skimmed off each buy
        uint256 currentSupply; // cumulative $CAMPAIGN minted
        // --- per-token registry ---
        address[] acceptedTokenList;
        mapping(address => TokenConfig) tokenConfigs;
        // --- per-buyer purchase tracking (for buyback) ---
        mapping(address => mapping(address => uint256)) purchases; // user => token => net amount paid
        mapping(address => mapping(address => uint256)) purchasedTokens; // user => token => CT minted
        // --- sell-back queue ---
        SellBackOrder[] sellBackQueue;
        uint256 sellBackQueueHead;
        mapping(address => uint256) pendingSellBack;
        mapping(address => uint256[]) userSellBackIndices;
        mapping(address => uint256) openSellBackCount;
        // --- oracle config ---
        AggregatorV3Interface sequencerUptimeFeed;
        // --- GROW Minter hook (zero = disabled) ---
        address growMinter;
        // --- reentrancy guard (per-module) ---
        uint256 reentrancyStatus;
        // --- one-shot init guard ---
        bool initialized;
    }

    bytes32 internal constant STORAGE_SLOT =
        0xd7250d23bb7bc8e93366cf6815d31bcb947e004baa702b9bb515d6082501a234; // keccak256("growfi.module.sale.classic.v1")

    uint256 internal constant MAX_ACCEPTED_TOKENS = 10;
    uint256 internal constant MAX_OPEN_SELLBACK_ORDERS_PER_USER = 50;
    uint256 internal constant SEQUENCER_GRACE_PERIOD = 1 hours;
    uint256 internal constant ORACLE_STALE_WINDOW = 1 hours;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error AlreadyInitialized();
    error OnlyFactoryBootstrap();
    error OnlyProducer();
    error ZeroAmount();
    error ZeroAddress();
    error Reentrant();
    error InvalidState();
    error TokenNotAccepted();
    error AlreadyAccepted();
    error TooManyAcceptedTokens();
    error PaymentDecimalsTooHigh();
    error MaxCapReached();
    error FundingNotExpired();
    error MinCapAlreadyReached();
    error MinCapNotReached();
    error NothingToRefund();
    error NoSellBackPending();
    error TooManyOpenSellBackOrders();
    error SequencerDown();
    error SequencerGracePeriod();
    error NegativeOraclePrice();
    error StaleOraclePrice();
    error OracleDecimalsTooHigh();
    error DeadlineNotExtended();
    error DeadlineInPast();
    error NewMinCapBelowSupply();
    error NewMaxCapBelowCommitted();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event SaleClassicInitialized(
        uint256 pricePerToken,
        uint256 minCap,
        uint256 maxCap,
        uint256 fundingDeadline,
        uint256 seasonDuration,
        uint256 fundingFeeBps
    );
    event TokensPurchased(
        address indexed buyer,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 campaignTokensOut,
        uint256 oraclePriceUsed,
        uint256 newCurrentSupply
    );
    event FundingFeeCollected(address indexed buyer, address indexed paymentToken, uint256 fee);
    event AcceptedTokenAdded(
        address indexed token, string symbol, uint8 pricingMode, uint256 fixedRate, address oracleFeed
    );
    event AcceptedTokenRemoved(address indexed token);
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
    event BuybackClaimed(
        address indexed user, address indexed paymentToken, uint256 campaignTokensBurned, uint256 refundAmount
    );
    event CampaignStateChanged(uint8 oldState, uint8 newState);
    event CampaignActivated(uint256 totalRaised, uint256 tokensSold);
    event BuybackTriggered(uint256 totalRaised, uint256 tokensSold, uint256 minCap);
    event FundingDeadlineUpdated(uint256 oldDeadline, uint256 newDeadline);
    event MinCapUpdated(uint256 oldMinCap, uint256 newMinCap);
    event MaxCapUpdated(uint256 oldMaxCap, uint256 newMaxCap);

    // ------------------------------------------------------------------
    // Storage accessor
    // ------------------------------------------------------------------

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    modifier onlyProducer() {
        if (msg.sender != CampaignStorage.layout().producer) revert OnlyProducer();
        _;
    }

    modifier nonReentrant() {
        Layout storage s = _s();
        if (s.reentrancyStatus == _ENTERED) revert Reentrant();
        s.reentrancyStatus = _ENTERED;
        _;
        s.reentrancyStatus = _NOT_ENTERED;
    }

    modifier inFundingOrActive() {
        uint8 st = CampaignStorage.layout().state;
        if (st != uint8(CampaignStorage.State.Funding) && st != uint8(CampaignStorage.State.Active)) {
            revert InvalidState();
        }
        _;
    }

    modifier inState(CampaignStorage.State expected) {
        if (CampaignStorage.layout().state != uint8(expected)) revert InvalidState();
        _;
    }

    // ------------------------------------------------------------------
    // Bootstrap initializer (factory-only, one-shot)
    // ------------------------------------------------------------------

    struct InitParams {
        uint256 pricePerToken;
        uint256 minCap;
        uint256 maxCap;
        uint256 fundingDeadline;
        uint256 seasonDuration;
        uint256 fundingFeeBps;
        address sequencerUptimeFeed; // zero on L1
        address growMinter; // zero = no GROW emission
    }

    /// @notice Called by the factory during the Campaign bootstrap
    ///         window. Writes the sale-specific parameters into module
    ///         storage. Gated to `msg.sender == factory` AND
    ///         `factoryBootstrap == true` so it cannot be re-run after
    ///         the Campaign goes live.
    function initializeSaleClassic(InitParams calldata p) external {
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        if (s.initialized) revert AlreadyInitialized();
        if (msg.sender != cs.factory || !cs.factoryBootstrap) revert OnlyFactoryBootstrap();

        s.pricePerToken = p.pricePerToken;
        s.minCap = p.minCap;
        s.maxCap = p.maxCap;
        s.fundingDeadline = p.fundingDeadline;
        s.seasonDuration = p.seasonDuration;
        s.fundingFeeBps = p.fundingFeeBps;
        s.sequencerUptimeFeed = AggregatorV3Interface(p.sequencerUptimeFeed);
        s.growMinter = p.growMinter;
        s.reentrancyStatus = _NOT_ENTERED;
        s.initialized = true;

        emit SaleClassicInitialized(
            p.pricePerToken, p.minCap, p.maxCap, p.fundingDeadline, p.seasonDuration, p.fundingFeeBps
        );
    }

    // ------------------------------------------------------------------
    // Producer — accepted-tokens registry
    // ------------------------------------------------------------------

    function addAcceptedToken(address token, PricingMode mode, uint256 fixedRate, address oracleFeed)
        external
        onlyProducer
    {
        if (token == address(0)) revert ZeroAddress();
        Layout storage s = _s();
        if (s.tokenConfigs[token].active) revert AlreadyAccepted();
        if (s.acceptedTokenList.length >= MAX_ACCEPTED_TOKENS) revert TooManyAcceptedTokens();
        if (mode == PricingMode.Fixed) {
            require(fixedRate > 0, "Zero fixedRate");
        } else {
            if (oracleFeed == address(0)) revert ZeroAddress();
        }
        uint8 dec = IERC20Metadata(token).decimals();
        if (dec > 18) revert PaymentDecimalsTooHigh();

        s.tokenConfigs[token] = TokenConfig({
            pricingMode: mode,
            fixedRate: fixedRate,
            oracleFeed: AggregatorV3Interface(oracleFeed),
            paymentDecimals: dec,
            active: true
        });
        s.acceptedTokenList.push(token);

        emit AcceptedTokenAdded(token, "", uint8(mode), fixedRate, oracleFeed);
    }

    function removeAcceptedToken(address token) external onlyProducer {
        Layout storage s = _s();
        if (!s.tokenConfigs[token].active) revert TokenNotAccepted();
        s.tokenConfigs[token].active = false;

        uint256 len = s.acceptedTokenList.length;
        for (uint256 i; i < len;) {
            if (s.acceptedTokenList[i] == token) {
                if (i != len - 1) s.acceptedTokenList[i] = s.acceptedTokenList[len - 1];
                s.acceptedTokenList.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
        emit AcceptedTokenRemoved(token);
    }

    // ------------------------------------------------------------------
    // Buy
    // ------------------------------------------------------------------

    function buy(address paymentToken, uint256 paymentAmount) external nonReentrant inFundingOrActive {
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        if (paymentAmount == 0) revert ZeroAmount();
        if (!s.tokenConfigs[paymentToken].active) revert TokenNotAccepted();
        if (cs.paused) revert InvalidState();

        // Capture supplyBefore so the GROW bonding-curve hook can compute the
        // exact delta after the mint. Queue fills are supply-neutral, so the
        // hook only emits GROW for fresh mints.
        uint256 supplyBefore = s.currentSupply;
        uint256 mintableRoom = s.currentSupply < s.maxCap ? s.maxCap - s.currentSupply : 0;
        bool isActive = cs.state == uint8(CampaignStorage.State.Active);
        uint256 queueTokens = isActive ? _queueTotalTokens() : 0;
        uint256 buyableMax = mintableRoom + queueTokens;
        if (buyableMax == 0) revert MaxCapReached();

        (uint256 tokensOut, uint256 oraclePrice) = _calculateTokensOut(paymentToken, paymentAmount);
        if (tokensOut > buyableMax) {
            tokensOut = buyableMax;
            paymentAmount = _calculatePaymentNeeded(paymentToken, tokensOut, oraclePrice);
        }

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), paymentAmount);

        uint256 fundingFee = paymentAmount * s.fundingFeeBps / 10_000;
        uint256 netPayment = paymentAmount - fundingFee;
        address feeRecipient = cs.protocolFeeRecipient;
        if (fundingFee > 0 && feeRecipient != address(0)) {
            IERC20(paymentToken).safeTransfer(feeRecipient, fundingFee);
            emit FundingFeeCollected(msg.sender, paymentToken, fundingFee);
        }

        // In Funding, track per-buyer purchase so `buyback()` can refund the same
        // tokens at the same NET amount if the campaign fails.
        if (!isActive) {
            s.purchases[msg.sender][paymentToken] += netPayment;
            s.purchasedTokens[msg.sender][paymentToken] += tokensOut;
        }

        uint256 paymentRemaining = netPayment;
        uint256 tokensToMint = tokensOut;

        if (isActive) {
            (paymentRemaining, tokensToMint) =
                _fillSellBackQueue(paymentToken, paymentRemaining, tokensOut, msg.sender);
        }

        if (paymentRemaining > 0 && tokensToMint > 0) {
            if (isActive) {
                // Net payment → producer wallet
                IERC20(paymentToken).safeTransfer(cs.producer, paymentRemaining);
            }
            // In Funding state, funds stay in escrow on the Campaign address.
            IGrowfiCampaignTokenMint(cs.campaignToken).mint(msg.sender, tokensToMint);
            s.currentSupply += tokensToMint;
        }

        emit TokensPurchased(msg.sender, paymentToken, paymentAmount, tokensOut, oraclePrice, s.currentSupply);

        // GROW emission hook: fires AFTER the mint, BEFORE auto-activate so
        // pre-softcap buys land in escrow and the softcap hook unlocks them.
        if (s.growMinter != address(0)) {
            IGrowfiMinter(s.growMinter).recordBuy(msg.sender, supplyBefore, s.currentSupply);
        }

        if (cs.state == uint8(CampaignStorage.State.Funding) && s.currentSupply >= s.minCap) {
            _activate();
        }
    }

    // ------------------------------------------------------------------
    // Sell-back queue
    // ------------------------------------------------------------------

    function sellBack(uint256 amount) external nonReentrant inState(CampaignStorage.State.Active) {
        if (amount == 0) revert ZeroAmount();
        Layout storage s = _s();
        if (s.openSellBackCount[msg.sender] >= MAX_OPEN_SELLBACK_ORDERS_PER_USER) {
            revert TooManyOpenSellBackOrders();
        }
        CampaignStorage.Layout storage cs = CampaignStorage.layout();

        IERC20(cs.campaignToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 queueIndex = s.sellBackQueue.length;
        s.sellBackQueue.push(SellBackOrder({seller: msg.sender, amount: amount}));
        s.pendingSellBack[msg.sender] += amount;
        s.userSellBackIndices[msg.sender].push(queueIndex);
        unchecked {
            s.openSellBackCount[msg.sender]++;
        }
        emit SellBackRequested(msg.sender, amount, queueIndex);
    }

    function cancelSellBack() external nonReentrant {
        Layout storage s = _s();
        if (s.pendingSellBack[msg.sender] == 0) revert NoSellBackPending();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();

        uint256 returned;
        uint256[] storage indices = s.userSellBackIndices[msg.sender];
        for (uint256 i; i < indices.length;) {
            uint256 idx = indices[i];
            if (idx >= s.sellBackQueueHead && s.sellBackQueue[idx].amount > 0) {
                returned += s.sellBackQueue[idx].amount;
                s.sellBackQueue[idx].amount = 0;
            }
            unchecked {
                ++i;
            }
        }
        delete s.userSellBackIndices[msg.sender];
        s.pendingSellBack[msg.sender] = 0;
        s.openSellBackCount[msg.sender] = 0;
        if (returned > 0) {
            IERC20(cs.campaignToken).safeTransfer(msg.sender, returned);
        }
        emit SellBackCancelled(msg.sender, returned);
    }

    // ------------------------------------------------------------------
    // Buyback (failed campaign refund)
    // ------------------------------------------------------------------

    function triggerBuyback() external {
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        if (cs.state != uint8(CampaignStorage.State.Funding)) revert InvalidState();
        if (block.timestamp < s.fundingDeadline) revert FundingNotExpired();
        if (s.currentSupply >= s.minCap) revert MinCapAlreadyReached();

        uint8 oldState = cs.state;
        cs.state = uint8(CampaignStorage.State.Buyback);

        // GROW hook: campaign failed → void all per-user escrow.
        if (s.growMinter != address(0)) {
            IGrowfiMinter(s.growMinter).onBuyback();
        }

        emit CampaignStateChanged(oldState, cs.state);
        emit BuybackTriggered(0, s.currentSupply, s.minCap);
    }

    function buyback(address paymentToken) external nonReentrant inState(CampaignStorage.State.Buyback) {
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        uint256 refundAmount = s.purchases[msg.sender][paymentToken];
        if (refundAmount == 0) revert NothingToRefund();

        uint256 userTokens = s.purchasedTokens[msg.sender][paymentToken];
        s.purchases[msg.sender][paymentToken] = 0;
        s.purchasedTokens[msg.sender][paymentToken] = 0;

        IGrowfiCampaignTokenMint(cs.campaignToken).burn(msg.sender, userTokens);
        s.currentSupply -= userTokens;

        IERC20(paymentToken).safeTransfer(msg.sender, refundAmount);

        emit BuybackClaimed(msg.sender, paymentToken, userTokens, refundAmount);
    }

    // ------------------------------------------------------------------
    // Producer manual activation (alternative to auto-activate inside `buy`)
    // ------------------------------------------------------------------

    function activateCampaign() external onlyProducer inState(CampaignStorage.State.Funding) {
        if (_s().currentSupply < _s().minCap) revert MinCapNotReached();
        _activate();
    }

    // ------------------------------------------------------------------
    // Producer-only parameter setters (Funding-state guards)
    // ------------------------------------------------------------------

    /// @notice Producer extends the funding deadline. Cannot shorten;
    ///         cannot push into the past.
    function setFundingDeadline(uint256 newDeadline)
        external
        onlyProducer
        inState(CampaignStorage.State.Funding)
    {
        Layout storage s = _s();
        if (newDeadline <= block.timestamp) revert DeadlineInPast();
        if (newDeadline <= s.fundingDeadline) revert DeadlineNotExtended();
        uint256 old = s.fundingDeadline;
        s.fundingDeadline = newDeadline;
        emit FundingDeadlineUpdated(old, newDeadline);
    }

    /// @notice Producer adjusts the min cap. Must stay above currentSupply
    ///         and at/below maxCap. Funding-only — once Active the soft
    ///         cap has already triggered.
    function setMinCap(uint256 newMinCap) external onlyProducer inState(CampaignStorage.State.Funding) {
        Layout storage s = _s();
        // Must stay above currently committed supply AND at or below maxCap.
        if (newMinCap <= s.currentSupply || newMinCap > s.maxCap) revert NewMinCapBelowSupply();
        uint256 old = s.minCap;
        s.minCap = newMinCap;
        emit MinCapUpdated(old, newMinCap);
    }

    /// @notice Producer adjusts the max cap. Allowed during Funding or
    ///         Active. Must stay ≥ currentSupply + queue depth so the
    ///         existing sell-back queue can still be filled. During
    ///         Funding it must also stay ≥ minCap.
    function setMaxCap(uint256 newMaxCap) external onlyProducer {
        Layout storage s = _s();
        uint8 st = CampaignStorage.layout().state;
        if (
            st != uint8(CampaignStorage.State.Funding)
                && st != uint8(CampaignStorage.State.Active)
        ) revert InvalidState();
        uint256 committed = s.currentSupply + _queueTotalTokens();
        if (newMaxCap < committed) revert NewMaxCapBelowCommitted();
        if (st == uint8(CampaignStorage.State.Funding) && newMaxCap < s.minCap) revert NewMaxCapBelowCommitted();
        uint256 old = s.maxCap;
        s.maxCap = newMaxCap;
        emit MaxCapUpdated(old, newMaxCap);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function previewBuy(address paymentToken, uint256 paymentAmount)
        external
        view
        returns (uint256 tokensOut, uint256 effectivePayment, uint256 oraclePrice, uint256 fundingFee)
    {
        Layout storage s = _s();
        if (paymentAmount == 0) revert ZeroAmount();
        if (!s.tokenConfigs[paymentToken].active) revert TokenNotAccepted();
        (uint256 rawOut, uint256 rawOracle) = _calculateTokensOut(paymentToken, paymentAmount);
        oraclePrice = rawOracle;
        uint256 available = s.currentSupply < s.maxCap ? s.maxCap - s.currentSupply : 0;
        if (rawOut > available) {
            tokensOut = available;
            effectivePayment = _calculatePaymentNeeded(paymentToken, tokensOut, rawOracle);
        } else {
            tokensOut = rawOut;
            effectivePayment = paymentAmount;
        }
        fundingFee = effectivePayment * s.fundingFeeBps / 10_000;
    }

    function getPrice(address paymentToken, uint256 campaignAmount) external view returns (uint256) {
        Layout storage s = _s();
        TokenConfig storage cfg = s.tokenConfigs[paymentToken];
        if (!cfg.active) revert TokenNotAccepted();
        if (cfg.pricingMode == PricingMode.Fixed) {
            return campaignAmount * cfg.fixedRate / 1e18;
        }
        (uint256 oraclePrice,) = _getOraclePrice(cfg.oracleFeed);
        uint256 scale = 10 ** (18 - cfg.paymentDecimals);
        return campaignAmount * s.pricePerToken / oraclePrice / scale;
    }

    function getAcceptedTokens() external view returns (address[] memory) {
        return _s().acceptedTokenList;
    }

    function getSellBackQueueDepth() external view returns (uint256) {
        return _queueTotalTokens();
    }

    function tokenConfig(address token) external view returns (TokenConfig memory) {
        return _s().tokenConfigs[token];
    }

    function pricePerToken() external view returns (uint256) {
        return _s().pricePerToken;
    }

    function minCap() external view returns (uint256) {
        return _s().minCap;
    }

    function maxCap() external view returns (uint256) {
        return _s().maxCap;
    }

    function fundingDeadline() external view returns (uint256) {
        return _s().fundingDeadline;
    }

    function seasonDuration() external view returns (uint256) {
        return _s().seasonDuration;
    }

    function fundingFeeBps() external view returns (uint256) {
        return _s().fundingFeeBps;
    }

    function currentSupply() external view returns (uint256) {
        return _s().currentSupply;
    }

    function purchases(address user, address token) external view returns (uint256) {
        return _s().purchases[user][token];
    }

    function purchasedTokens(address user, address token) external view returns (uint256) {
        return _s().purchasedTokens[user][token];
    }

    function pendingSellBack(address user) external view returns (uint256) {
        return _s().pendingSellBack[user];
    }

    function growMinter() external view returns (address) {
        return _s().growMinter;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _activate() internal {
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        uint8 oldState = cs.state;
        cs.state = uint8(CampaignStorage.State.Active);

        // Release escrowed funds (held on the Campaign address) to producer.
        // Funding-fee was already skimmed at buy time; this is the net.
        address[] memory list = s.acceptedTokenList;
        uint256 len = list.length;
        for (uint256 i; i < len;) {
            address token = list[i];
            if (s.tokenConfigs[token].active) {
                uint256 bal = IERC20(token).balanceOf(address(this));
                if (bal > 0) IERC20(token).safeTransfer(cs.producer, bal);
            }
            unchecked {
                ++i;
            }
        }

        // GROW hook: campaign reached softcap → unlock per-user escrow for claim.
        if (s.growMinter != address(0)) {
            IGrowfiMinter(s.growMinter).onSoftCapReached();
        }

        emit CampaignStateChanged(oldState, cs.state);
        emit CampaignActivated(0, s.currentSupply);
    }

    function _queueTotalTokens() internal view returns (uint256 depth) {
        Layout storage s = _s();
        uint256 n = s.sellBackQueue.length;
        for (uint256 i = s.sellBackQueueHead; i < n;) {
            depth += s.sellBackQueue[i].amount;
            unchecked {
                ++i;
            }
        }
    }

    function _calculateTokensOut(address paymentToken, uint256 paymentAmount)
        internal
        view
        returns (uint256 tokensOut, uint256 oraclePrice)
    {
        Layout storage s = _s();
        TokenConfig storage cfg = s.tokenConfigs[paymentToken];
        if (cfg.pricingMode == PricingMode.Fixed) {
            tokensOut = paymentAmount * 1e18 / cfg.fixedRate;
            oraclePrice = 0;
        } else {
            (oraclePrice,) = _getOraclePrice(cfg.oracleFeed);
            uint256 scale = 10 ** (18 - cfg.paymentDecimals);
            tokensOut = paymentAmount * scale * oraclePrice / s.pricePerToken;
        }
    }

    function _calculatePaymentNeeded(address paymentToken, uint256 tokensOut, uint256 oraclePrice)
        internal
        view
        returns (uint256)
    {
        Layout storage s = _s();
        TokenConfig storage cfg = s.tokenConfigs[paymentToken];
        if (cfg.pricingMode == PricingMode.Fixed) {
            return tokensOut * cfg.fixedRate / 1e18;
        }
        uint256 scale = 10 ** (18 - cfg.paymentDecimals);
        return tokensOut * s.pricePerToken / oraclePrice / scale;
    }

    function _getOraclePrice(AggregatorV3Interface feed) internal view returns (uint256 price, uint8 decimals) {
        Layout storage s = _s();
        if (address(s.sequencerUptimeFeed) != address(0)) {
            (, int256 seqAnswer, uint256 seqStartedAt,,) = s.sequencerUptimeFeed.latestRoundData();
            if (seqAnswer == 1) revert SequencerDown();
            if (block.timestamp - seqStartedAt < SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriod();
        }

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (answer <= 0) revert NegativeOraclePrice();
        if (startedAt == 0) revert StaleOraclePrice();
        if (answeredInRound < roundId) revert StaleOraclePrice();
        if (block.timestamp - updatedAt > ORACLE_STALE_WINDOW) revert StaleOraclePrice();
        decimals = feed.decimals();
        if (decimals > 18) revert OracleDecimalsTooHigh();
        price = uint256(answer) * 10 ** (18 - decimals);
    }

    function _fillSellBackQueue(
        address paymentToken,
        uint256 paymentAmount,
        uint256 totalTokensForPayment,
        address buyer
    ) internal returns (uint256 remainingPayment, uint256 remainingTokens) {
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        remainingPayment = paymentAmount;
        remainingTokens = totalTokensForPayment;

        while (remainingPayment > 0 && s.sellBackQueueHead < s.sellBackQueue.length) {
            SellBackOrder storage order = s.sellBackQueue[s.sellBackQueueHead];
            if (order.amount == 0) {
                s.sellBackQueueHead++;
                continue;
            }

            uint256 fillAmount = order.amount;
            if (fillAmount > remainingTokens) fillAmount = remainingTokens;

            uint256 paymentForFill = fillAmount * paymentAmount / totalTokensForPayment;
            if (paymentForFill > remainingPayment) paymentForFill = remainingPayment;

            IERC20(paymentToken).safeTransfer(order.seller, paymentForFill);

            // Burn seller's parked $CAMPAIGN (sitting on Campaign address), mint to buyer.
            IGrowfiCampaignTokenMint(cs.campaignToken).burn(address(this), fillAmount);
            IGrowfiCampaignTokenMint(cs.campaignToken).mint(buyer, fillAmount);

            s.pendingSellBack[order.seller] -= fillAmount;
            order.amount -= fillAmount;
            remainingPayment -= paymentForFill;
            remainingTokens -= fillAmount;

            emit SellBackFilled(order.seller, buyer, paymentToken, fillAmount, paymentForFill, order.amount);

            if (order.amount == 0) {
                s.sellBackQueueHead++;
                if (s.openSellBackCount[order.seller] > 0) {
                    s.openSellBackCount[order.seller]--;
                }
            }
        }
    }
}
