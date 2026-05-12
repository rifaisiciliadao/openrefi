// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CampaignStorage} from "../host/CampaignStorage.sol";
import {IGrowfiCampaignTokenMint} from "../interfaces/IGrowfiCampaignTokenMint.sol";
import {IGrowfiStakingVaultMinV4} from "../interfaces/IGrowfiStakingVaultMinV4.sol";

/// @title  RepaymentModule
/// @notice Producer-funded early-redeem pool. The redemption payout
///         per $CAMPAIGN is split in two parts:
///
///           payout = principalUsdc + bonusUsdc
///           principalUsdc = amount * SaleClassic.pricePerToken / 1e30
///           bonusUsdc     = amount * bonusPerCt / 1e18
///
///         `pricePerToken` is read live from the SaleClassicModule's
///         namespaced storage slot — it's fixed at campaign init and
///         the producer cannot lowball below it. `bonusPerCt` is an
///         additive markup the producer can set/adjust (defaults to 0).
///
///         When a holder includes staking position ids in `unstakeFirst`,
///         the module force-unstakes each one via the StakingVault.
///         `forceUnstake` is producer-blessed: it returns full CT
///         principal AND mints the accrued $YIELD to the position owner
///         (no penalty, no forfeit). After unstaking, the caller's free
///         CT balance is burned in exchange for the USDC payout.
///
///         Storage namespace: `keccak256("growfi.module.repayment.v1")`.
contract RepaymentModule {
    using SafeERC20 for IERC20;

    struct Layout {
        uint256 poolBalance; // tracked accounting of producer-deposited USDC (USDC-6)
        uint256 bonusPerCt; // additive markup, USDC-6 per 1e18 $CAMPAIGN
        mapping(address => uint256) claimedByUser; // running total per user (USDC-6)
        uint256 reentrancyStatus;
        bool initialized;
    }

    bytes32 internal constant STORAGE_SLOT =
        0x14aa57f11bde39f5bf9c2d6c4d6638f5a3829e646927e7698ce9a2de15f76398; // keccak256("growfi.module.repayment.v1")

    /// @dev SaleClassicModule's namespaced storage slot. `pricePerToken`
    ///      is the first field of its Layout struct, so it sits at this
    ///      exact slot (offset 0). Both modules run in the Campaign's
    ///      delegatecall context, so reading via assembly is safe.
    bytes32 internal constant SALE_CLASSIC_SLOT =
        0xd7250d23bb7bc8e93366cf6815d31bcb947e004baa702b9bb515d6082501a234; // keccak256("growfi.module.sale.classic.v1")

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error AlreadyInitialized();
    error OnlyFactoryBootstrap();
    error OnlyProducer();
    error ZeroAmount();
    error InvalidState();
    error Reentrant();
    error PoolInsufficient();
    error PoolBalanceUnderflow();
    error PrincipalNotSet();
    error NotPositionOwner();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event RepaymentInitialized(uint256 initialBonusPerCt);
    event RepaymentPoolFunded(address indexed producer, uint256 amount, uint256 newPoolBalance);
    event RepaymentPoolWithdrawn(address indexed producer, uint256 amount, uint256 newPoolBalance);
    event RepaymentBonusSet(uint256 oldBonusPerCt, uint256 newBonusPerCt);
    event Repaid(
        address indexed holder,
        uint256 campaignTokensBurned,
        uint256 principalPaid,
        uint256 bonusPaid,
        uint256 newPoolBalance,
        uint256 totalClaimedByUser
    );

    // ------------------------------------------------------------------
    // Storage accessor
    // ------------------------------------------------------------------

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    /// @dev Live-read pricePerToken (USD-18 per 1e18 CT) from SaleClassicModule.
    ///      Returns 0 if SaleClassic is not attached/initialized — callers
    ///      that need a non-zero principal must guard against it.
    function _readPricePerToken() internal view returns (uint256 price) {
        bytes32 slot = SALE_CLASSIC_SLOT;
        assembly {
            price := sload(slot)
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

    // ------------------------------------------------------------------
    // Initializers
    // ------------------------------------------------------------------

    struct InitParams {
        uint256 initialBonusPerCt; // 0 = no bonus, producer can raise later
    }

    function initializeRepayment(InitParams calldata p) external {
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        if (s.initialized) revert AlreadyInitialized();
        if (msg.sender != cs.factory || !cs.factoryBootstrap) revert OnlyFactoryBootstrap();

        s.bonusPerCt = p.initialBonusPerCt;
        s.reentrancyStatus = _NOT_ENTERED;
        s.initialized = true;

        emit RepaymentInitialized(p.initialBonusPerCt);
    }

    /// @notice Producer-initiated init (when the module is attached
    ///         post-bootstrap via `Campaign.attachModule`). The initial
    ///         bonus may be 0 — refund-at-par is the floor either way.
    function initializeRepaymentByProducer(uint256 initialBonusPerCt) external onlyProducer {
        Layout storage s = _s();
        if (s.initialized) revert AlreadyInitialized();
        s.bonusPerCt = initialBonusPerCt;
        s.reentrancyStatus = _NOT_ENTERED;
        s.initialized = true;
        emit RepaymentInitialized(initialBonusPerCt);
    }

    // ------------------------------------------------------------------
    // Producer admin
    // ------------------------------------------------------------------

    function fundPool(uint256 amount) external onlyProducer nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        IERC20(cs.usdc).safeTransferFrom(msg.sender, address(this), amount);
        s.poolBalance += amount;
        emit RepaymentPoolFunded(msg.sender, amount, s.poolBalance);
    }

    function withdrawUnusedPool(uint256 amount) external onlyProducer nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Layout storage s = _s();
        if (amount > s.poolBalance) revert PoolBalanceUnderflow();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        s.poolBalance -= amount;
        IERC20(cs.usdc).safeTransfer(msg.sender, amount);
        emit RepaymentPoolWithdrawn(msg.sender, amount, s.poolBalance);
    }

    /// @notice Additive markup on top of the on-chain-derived principal.
    ///         Producer may set/adjust freely; 0 means "refund-at-par only".
    function setBonusPerCt(uint256 newBonusPerCt) external onlyProducer {
        Layout storage s = _s();
        uint256 old = s.bonusPerCt;
        s.bonusPerCt = newBonusPerCt;
        emit RepaymentBonusSet(old, newBonusPerCt);
    }

    // ------------------------------------------------------------------
    // Holder — redeem
    // ------------------------------------------------------------------

    /// @notice Burn `amount` of caller's $CAMPAIGN in exchange for
    ///         `principal + bonus` USDC. Pass any staking position ids
    ///         the caller wants to liquidate first in `unstakeFirst[]` —
    ///         each is force-unstaked, returning CT principal AND
    ///         minting accrued $YIELD to the position owner.
    function redeem(uint256 amount, uint256[] calldata unstakeFirst) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        if (cs.paused) revert InvalidState();
        if (cs.state == uint8(CampaignStorage.State.Ended)) revert InvalidState();

        uint256 pricePerToken = _readPricePerToken();
        if (pricePerToken == 0) revert PrincipalNotSet();

        // principal in USDC-6: amount(1e18 CT) * price(1e18 USD-18 per CT) / 1e30
        uint256 principal = (amount * pricePerToken) / 1e30;
        // bonus in USDC-6: amount(1e18 CT) * bonusPerCt(USDC-6 per 1e18 CT) / 1e18
        uint256 bonus = (amount * s.bonusPerCt) / 1e18;
        uint256 payout = principal + bonus;
        if (payout == 0) revert ZeroAmount();
        if (payout > s.poolBalance) revert PoolInsufficient();

        // Force-unstake each position the caller wants to clear. The
        // vault mints accrued $YIELD to the owner and returns principal
        // CT to the owner (msg.sender to the vault is the Campaign in
        // delegatecall context, satisfying `onlyCampaign`). We check
        // ownership here in the module — the vault's forceUnstake itself
        // is owner-agnostic so that the campaign retains the option to
        // wire other governance/grace flows later; the redeem entrypoint
        // is the one that needs to refuse force-unstaking strangers'
        // positions (would be a griefing vector).
        IGrowfiStakingVaultMinV4 sv = IGrowfiStakingVaultMinV4(cs.stakingVault);
        for (uint256 i; i < unstakeFirst.length;) {
            (address posOwner,,,,,) = sv.positions(unstakeFirst[i]);
            if (posOwner != msg.sender) revert NotPositionOwner();
            sv.forceUnstake(unstakeFirst[i]);
            unchecked {
                ++i;
            }
        }

        // Burn caller's $CAMPAIGN. `msg.sender` to the CampaignToken in
        // delegatecall context is the Campaign address, which satisfies
        // `onlyCampaignOrVault`.
        IGrowfiCampaignTokenMint(cs.campaignToken).burn(msg.sender, amount);

        s.poolBalance -= payout;
        s.claimedByUser[msg.sender] += payout;
        IERC20(cs.usdc).safeTransfer(msg.sender, payout);

        emit Repaid(msg.sender, amount, principal, bonus, s.poolBalance, s.claimedByUser[msg.sender]);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function poolBalance() external view returns (uint256) {
        return _s().poolBalance;
    }

    /// @notice Additive markup on top of principal (USDC-6 per 1e18 CT).
    function bonusPerCt() external view returns (uint256) {
        return _s().bonusPerCt;
    }

    /// @notice On-chain-derived principal payout per 1e18 CT (USDC-6).
    ///         Returns 0 if SaleClassicModule is not initialized.
    function principalPerCt() external view returns (uint256) {
        return _readPricePerToken() / 1e12;
    }

    /// @notice Effective payout per 1e18 CT (principal + bonus, USDC-6).
    function payoutPerCt() external view returns (uint256) {
        return (_readPricePerToken() / 1e12) + _s().bonusPerCt;
    }

    function claimedByUser(address user) external view returns (uint256) {
        return _s().claimedByUser[user];
    }

    /// @notice Preview total USDC payout for redeeming `amount` CT.
    function quoteRepayment(uint256 amount) external view returns (uint256) {
        uint256 price = _readPricePerToken();
        uint256 principal = (amount * price) / 1e30;
        uint256 bonus = (amount * _s().bonusPerCt) / 1e18;
        return principal + bonus;
    }
}
