// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {YieldToken} from "./YieldToken.sol";
import {StakingVault} from "./StakingVault.sol";

/// @title HarvestManager — Harvest Reporting & Two-Step Redemption
/// @notice Producer reports harvest → holders burn $YIELD to redeem product (Merkle) or USDC.
///         2% protocol fee deducted on harvest report.
/// @dev    Initializable so it can be deployed as an EIP-1167 clone.
contract HarvestManager is Initializable, ReentrancyGuard, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // --- Structs ---

    struct SeasonHarvest {
        bytes32 merkleRoot;
        uint256 totalHarvestValueUSD; // 70% of gross, 18 decimals
        uint256 totalYieldSupply; // snapshot of total $YIELD at report time
        uint256 totalProductUnits; // e.g., liters (18 decimals)
        uint256 claimStart;
        uint256 claimEnd;
        uint256 usdcDeadline; // claimEnd + 90 days
        uint256 usdcDeposited;
        uint256 usdcOwed;
        uint256 protocolFeeCollected; // theoretical/target fee in 18-dec USD at report time
        uint256 protocolFeeTransferred; // actual USDC (6-dec native) routed to feeRecipient so far
        bool reported;
    }

    enum RedemptionType {
        None,
        Product,
        USDC
    }

    struct Claim {
        bool claimed;
        RedemptionType redemptionType;
        uint256 amount; // $YIELD burned
        uint256 usdcAmount; // USDC owed (only for USDC redemption), 18 decimals
        uint256 usdcClaimed; // USDC already claimed, 18 decimals
    }

    // --- State ---

    YieldToken public yieldToken;
    StakingVault public stakingVault;
    IERC20 public usdc;
    address public producer;
    address public factory;
    address public protocolFeeRecipient;
    uint256 public protocolFeeBps; // 200 = 2%
    uint256 public minProductClaim; // minimum product units for product redemption (18 decimals)
    bool private _yieldTokenSet;
    bool private _stakingVaultSet;

    uint256 public constant USDC_DEPOSIT_WINDOW = 90 days;

    mapping(uint256 => SeasonHarvest) public seasonHarvests;
    mapping(uint256 => mapping(address => Claim)) public claims;

    // --- Appended storage v3 ---

    /// @notice Owning Campaign proxy. Set once by the factory; needed so the
    ///         Campaign can deposit on behalf of holders out of its
    ///         pre-paid yield reserve when the producer falls short.
    address public campaign;
    bool private _campaignSet;

    // --- Events ---

    event HarvestReported(
        uint256 indexed seasonId,
        uint256 totalHarvestValueUSD,
        uint256 protocolFee,
        uint256 holderPool,
        uint256 totalProductUnits,
        bytes32 merkleRoot,
        uint256 claimStart,
        uint256 claimEnd,
        uint256 usdcDeadline
    );

    event ProductRedeemed(
        address indexed user, uint256 indexed seasonId, uint256 yieldBurned, uint256 productAmount, bytes32 merkleLeaf
    );

    /// @notice Holder committed $YIELD to a USDC claim — no USDC has moved yet.
    ///         Fired by `redeemUSDC`. The actual transfer is a separate
    ///         `USDCRedeemed` event emitted later by `claimUSDC`.
    event USDCCommitted(address indexed user, uint256 indexed seasonId, uint256 yieldBurned, uint256 usdcAmount);

    event USDCDeposited(
        uint256 indexed seasonId, address indexed producer_, uint256 amount, uint256 totalDeposited, uint256 totalOwed
    );

    /// @notice USDC actually transferred to the holder — fired by `claimUSDC`.
    event USDCRedeemed(address indexed user, uint256 indexed seasonId, uint256 amount);

    /// @notice Theoretical protocol fee, snapshotted at report time (18-dec USD).
    event ProtocolFeeTargeted(uint256 indexed seasonId, uint256 amountUSD18, address recipient);

    /// @notice Actual USDC transferred to the fee recipient on a producer deposit.
    event ProtocolFeeTransferred(uint256 indexed seasonId, uint256 amountUsdc6, address recipient);

    // --- Errors ---

    error OnlyProducer();
    error OnlyFactory();
    error OnlyCampaign();
    error AlreadyReported();
    error NotReported();
    error ClaimWindowClosed();
    error ClaimWindowNotOpen();
    error AlreadyClaimed();
    error BelowMinProductClaim();
    error InvalidMerkleProof();
    error ZeroAmount();
    error USDCNotDeposited();
    error DepositWindowClosed();
    error DepositExceedsOwed();
    error AlreadySet();
    error NotUsdcRedemption();

    // --- Modifiers ---

    modifier onlyProducer() {
        if (msg.sender != producer) revert OnlyProducer();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier onlyCampaign() {
        if (msg.sender != campaign) revert OnlyCampaign();
        _;
    }

    // --- Constructor ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address usdc_,
        address producer_,
        address factory_,
        address protocolFeeRecipient_,
        uint256 protocolFeeBps_,
        uint256 minProductClaim_
    ) external initializer {
        __Pausable_init();
        usdc = IERC20(usdc_);
        producer = producer_;
        factory = factory_;
        protocolFeeRecipient = protocolFeeRecipient_;
        protocolFeeBps = protocolFeeBps_;
        minProductClaim = minProductClaim_;
    }

    /// @notice Set the YieldToken address. Can only be called once by the factory.
    function setYieldToken(address yieldToken_) external onlyFactory {
        if (_yieldTokenSet) revert AlreadySet();
        yieldToken = YieldToken(yieldToken_);
        _yieldTokenSet = true;
    }

    /// @notice Set the StakingVault address. Can only be called once by the factory.
    ///         Used to snapshot the per-season totalYieldOwed in reportHarvest.
    function setStakingVault(address stakingVault_) external onlyFactory {
        if (_stakingVaultSet) revert AlreadySet();
        stakingVault = StakingVault(stakingVault_);
        _stakingVaultSet = true;
    }

    /// @notice Set the owning Campaign proxy. Called once by the factory after
    ///         the Campaign proxy has been deployed. Required for
    ///         `depositFromCollateral` to be callable by the Campaign.
    function setCampaign(address campaign_) external onlyFactory {
        if (_campaignSet) revert AlreadySet();
        campaign = campaign_;
        _campaignSet = true;
    }

    // --- Harvest Reporting ---

    /// @notice Producer reports the harvest for a season.
    /// @param seasonId Season identifier.
    /// @param totalValueUSD 70% of gross harvest value (18 decimals).
    /// @param merkleRoot Merkle root for product claims.
    /// @param totalUnits Total product units available (18 decimals, e.g., liters).
    function reportHarvest(uint256 seasonId, uint256 totalValueUSD, bytes32 merkleRoot, uint256 totalUnits)
        external
        onlyProducer
        whenNotPaused
    {
        SeasonHarvest storage harvest = seasonHarvests[seasonId];
        if (harvest.reported) revert AlreadyReported();

        uint256 protocolFee = totalValueUSD * protocolFeeBps / 10_000;
        uint256 holderPool = totalValueUSD - protocolFee;

        // Snapshot the canonical per-season yield total (accrued, not just
        // minted). Immune to holders front-running or lagging claimYield
        // around the reportHarvest transaction.
        uint256 totalYieldSupply = stakingVault.seasonTotalYieldOwed(seasonId);

        harvest.merkleRoot = merkleRoot;
        harvest.totalHarvestValueUSD = totalValueUSD;
        harvest.totalYieldSupply = totalYieldSupply;
        harvest.totalProductUnits = totalUnits;
        harvest.claimStart = block.timestamp;
        harvest.claimEnd = block.timestamp + 30 days;
        harvest.usdcDeadline = block.timestamp + 30 days + USDC_DEPOSIT_WINDOW;
        harvest.protocolFeeCollected = protocolFee;
        harvest.reported = true;

        emit HarvestReported(
            seasonId,
            totalValueUSD,
            protocolFee,
            holderPool,
            totalUnits,
            merkleRoot,
            harvest.claimStart,
            harvest.claimEnd,
            harvest.usdcDeadline
        );
        emit ProtocolFeeTargeted(seasonId, protocolFee, protocolFeeRecipient);
    }

    // --- Redemption ---

    /// @notice Redeem $YIELD for physical product. Burns $YIELD, verifies Merkle proof.
    function redeemProduct(uint256 seasonId, uint256 yieldAmount, bytes32[] calldata merkleProof)
        external
        nonReentrant
        whenNotPaused
    {
        SeasonHarvest storage harvest = seasonHarvests[seasonId];
        if (!harvest.reported) revert NotReported();
        if (block.timestamp < harvest.claimStart || block.timestamp > harvest.claimEnd) revert ClaimWindowClosed();

        Claim storage claim = claims[seasonId][msg.sender];
        if (claim.claimed) revert AlreadyClaimed();
        if (yieldAmount == 0) revert ZeroAmount();

        // Calculate product amount
        uint256 productAmount = yieldAmount * harvest.totalProductUnits / harvest.totalYieldSupply;
        if (productAmount < minProductClaim) revert BelowMinProductClaim();

        // Verify Merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, seasonId, productAmount));
        if (!MerkleProof.verify(merkleProof, harvest.merkleRoot, leaf)) revert InvalidMerkleProof();

        // Burn $YIELD
        yieldToken.burn(msg.sender, yieldAmount);

        claim.claimed = true;
        claim.redemptionType = RedemptionType.Product;
        claim.amount = yieldAmount;

        emit ProductRedeemed(msg.sender, seasonId, yieldAmount, productAmount, leaf);
    }

    /// @notice Redeem $YIELD for USDC. Burns $YIELD, registers USDC claim.
    function redeemUSDC(uint256 seasonId, uint256 yieldAmount) external nonReentrant whenNotPaused {
        SeasonHarvest storage harvest = seasonHarvests[seasonId];
        if (!harvest.reported) revert NotReported();
        if (block.timestamp < harvest.claimStart || block.timestamp > harvest.claimEnd) revert ClaimWindowClosed();

        Claim storage claim = claims[seasonId][msg.sender];
        if (claim.claimed) revert AlreadyClaimed();
        if (yieldAmount == 0) revert ZeroAmount();

        // Calculate USDC amount: yieldAmount * holderPool / totalYieldSupply
        uint256 holderPool = harvest.totalHarvestValueUSD - harvest.protocolFeeCollected;
        uint256 usdcAmount = yieldAmount * holderPool / harvest.totalYieldSupply;

        // Burn $YIELD
        yieldToken.burn(msg.sender, yieldAmount);

        claim.claimed = true;
        claim.redemptionType = RedemptionType.USDC;
        claim.amount = yieldAmount;
        claim.usdcAmount = usdcAmount;

        harvest.usdcOwed += usdcAmount;

        emit USDCCommitted(msg.sender, seasonId, yieldAmount, usdcAmount);
    }

    /// @notice Claim deposited USDC after producer has deposited. Can be called multiple times as producer deposits more.
    function claimUSDC(uint256 seasonId) external nonReentrant {
        Claim storage claim = claims[seasonId][msg.sender];
        if (claim.redemptionType != RedemptionType.USDC) revert NotUsdcRedemption();
        if (claim.usdcAmount == 0) revert ZeroAmount();

        SeasonHarvest storage harvest = seasonHarvests[seasonId];
        if (harvest.usdcDeposited == 0) revert USDCNotDeposited();

        // Calculate pro-rata entitlement based on current deposits
        uint256 entitlement = claim.usdcAmount;
        if (harvest.usdcDeposited < harvest.usdcOwed) {
            entitlement = claim.usdcAmount * harvest.usdcDeposited / harvest.usdcOwed;
        }

        // Only transfer the difference from what was already claimed
        uint256 claimable = entitlement - claim.usdcClaimed;
        if (claimable == 0) revert ZeroAmount();

        // Transfer USDC (18 decimals → 6 decimals). Credit back ONLY what was
        // actually transferred so sub-1e12 dust stays claimable after future
        // deposits push usdcDeposited up the next boundary.
        uint256 usdcToTransfer = claimable / 1e12;
        if (usdcToTransfer == 0) revert ZeroAmount();
        claim.usdcClaimed += usdcToTransfer * 1e12;
        usdc.safeTransfer(msg.sender, usdcToTransfer);

        emit USDCRedeemed(msg.sender, seasonId, usdcToTransfer);
    }

    // --- Producer USDC Deposit ---

    /// @notice Producer deposits USDC to cover USDC redemption claims.
    /// @dev    Each deposit is split: `protocolFeeBps` (2%) is forwarded directly
    ///         to `protocolFeeRecipient`; the remainder credits the holder pool.
    ///         Producer therefore must deposit `usdcOwed/1e12 * 10000/(10000-feeBps)`
    ///         native USDC to fully cover claims.
    function depositUSDC(uint256 seasonId, uint256 amount) external onlyProducer nonReentrant whenNotPaused {
        // Producer's deposit must happen INSIDE the 90-day window.
        if (block.timestamp > seasonHarvests[seasonId].usdcDeadline) revert DepositWindowClosed();
        _doDeposit(seasonId, amount);
    }

    /// @notice Out-of-collateral top-up entry point. Called by the owning
    ///         Campaign during `settleSeasonShortfall` to cover holder claims
    ///         when the producer's deposit falls short of `usdcOwed`. Same
    ///         98/2 split as the producer's own `depositUSDC`.
    /// @dev    Intentionally NOT `whenNotPaused` — holder-protection path
    ///         must remain available even if the protocol pauses the
    ///         contract for an unrelated emergency.
    /// @dev    Intentionally does NOT enforce the producer's `usdcDeadline`
    ///         window: the Campaign only ever calls this AFTER the deadline
    ///         has lapsed (that's what `Campaign.settleSeasonShortfall`
    ///         requires before it draws from collateral).
    function depositFromCollateral(uint256 seasonId, uint256 amount) external onlyCampaign nonReentrant {
        _doDeposit(seasonId, amount);
    }

    /// @dev    Shared deposit logic for both producer-funded
    ///         (`depositUSDC`) and Campaign-funded (`depositFromCollateral`)
    ///         paths. Pulls `amount` USDC from `msg.sender` and splits it
    ///         98/2 into the season pool and the protocol fee. The
    ///         `usdcDeadline` check is enforced by the producer-facing
    ///         entry point only — the collateral path is post-deadline by
    ///         construction.
    function _doDeposit(uint256 seasonId, uint256 amount) internal {
        SeasonHarvest storage harvest = seasonHarvests[seasonId];
        if (!harvest.reported) revert NotReported();
        if (amount == 0) revert ZeroAmount();

        uint256 feePortion = amount * protocolFeeBps / 10_000;
        uint256 poolPortion = amount - feePortion;

        // Prevent over-deposit: refuse if the resulting pool would exceed usdcOwed.
        // Caller should call `remainingDepositGross` to size their transfer.
        uint256 newPool18 = harvest.usdcDeposited + poolPortion * 1e12;
        if (newPool18 > harvest.usdcOwed) revert DepositExceedsOwed();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (feePortion > 0) {
            usdc.safeTransfer(protocolFeeRecipient, feePortion);
            harvest.protocolFeeTransferred += feePortion;
            emit ProtocolFeeTransferred(seasonId, feePortion, protocolFeeRecipient);
        }

        harvest.usdcDeposited = newPool18;

        emit USDCDeposited(seasonId, msg.sender, amount, harvest.usdcDeposited, harvest.usdcOwed);
    }

    /// @notice Maximum gross USDC (6-dec) the producer can still deposit without exceeding `usdcOwed`.
    ///         Floors conservatively so the resulting pool ≤ usdcOwed; may under-cover by < 1 USDC
    ///         due to the 6→18 decimal scale; producers top up with a second call if needed.
    function remainingDepositGross(uint256 seasonId) external view returns (uint256) {
        SeasonHarvest storage harvest = seasonHarvests[seasonId];
        if (harvest.usdcDeposited >= harvest.usdcOwed) return 0;
        uint256 netBps = 10_000 - protocolFeeBps;
        uint256 poolMax6 = (harvest.usdcOwed - harvest.usdcDeposited) / 1e12; // floor, 6-dec
        return poolMax6 * 10_000 / netBps; // floor gross
    }

    // --- Pause ---

    function emergencyPause() external onlyFactory {
        _pause();
    }

    function emergencyUnpause() external onlyFactory {
        _unpause();
    }

    // --- Views ---

    function getYieldFloorPrice(uint256 seasonId) external view returns (uint256) {
        SeasonHarvest storage harvest = seasonHarvests[seasonId];
        if (!harvest.reported || harvest.totalYieldSupply == 0) return 0;
        uint256 holderPool = harvest.totalHarvestValueUSD - harvest.protocolFeeCollected;
        return holderPool * 1e18 / harvest.totalYieldSupply;
    }
}
