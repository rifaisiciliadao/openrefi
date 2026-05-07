// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * GrowfiFeeSplitter — passive multi-token fee router.
 *
 * Sits in the `protocolFeeRecipient` slot of every GrowfiCampaign and GrowfiHarvestManager.
 * Any ERC20 sent here can be split, by anyone calling `flushToken(token)`, into:
 *   • `treasuryBps` (default 30%) → GrowfiTreasury (backs the GROW token)
 *   • `BPS - treasuryBps` (default 70%) → operations multisig
 *
 * Multi-token by design:
 * - Campaigns may collect fees in USDC, USDT, DAI, or whatever stablecoins their producers
 *   accepted. The splitter just holds whatever balance arrives and routes it on demand.
 * - `flushToken(token)` is permissionless — anyone can pay gas to flush. Useful as a public good
 *   for stake revenue distribution and for keepers / cron jobs.
 * - `flushMany(tokens[])` for batch flushing in one tx.
 *
 * No rescue function needed: the flush works for ANY ERC20, so "stuck" tokens are just one
 * permissionless `flushToken` call away from being routed.
 */
contract GrowfiFeeSplitter is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_TREASURY_BPS = 5_000; // 50% cap

    address public factory;
    address public treasury;
    address public operations;
    uint256 public treasuryBps;

    error NotFactory();
    error ZeroAddress();
    error InvalidBps();
    error ZeroBalance();

    event TreasurySet(address indexed previous, address indexed current);
    event OperationsSet(address indexed previous, address indexed current);
    event TreasuryBpsSet(uint256 previous, uint256 current);
    event Flushed(address indexed token, uint256 toTreasury, uint256 toOperations);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address factory_, address treasury_, address operations_, uint256 initialTreasuryBps)
        external
        initializer
    {
        if (factory_ == address(0) || treasury_ == address(0) || operations_ == address(0)) revert ZeroAddress();
        if (initialTreasuryBps > MAX_TREASURY_BPS) revert InvalidBps();

        factory = factory_;
        treasury = treasury_;
        operations = operations_;
        treasuryBps = initialTreasuryBps;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    // ---------- factory admin ----------

    function setTreasury(address newTreasury) external onlyFactory {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasurySet(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setOperations(address newOps) external onlyFactory {
        if (newOps == address(0)) revert ZeroAddress();
        emit OperationsSet(operations, newOps);
        operations = newOps;
    }

    function setTreasuryBps(uint256 newBps) external onlyFactory {
        if (newBps > MAX_TREASURY_BPS) revert InvalidBps();
        emit TreasuryBpsSet(treasuryBps, newBps);
        treasuryBps = newBps;
    }

    // ---------- flush ----------

    /// @notice Permissionlessly route this contract's balance of `token` to Treasury + Operations.
    /// @dev Splits at the current `treasuryBps`. Reverts if balance is zero.
    function flushToken(address token) external nonReentrant {
        _flush(token);
    }

    /// @notice Batch variant. Skips empty balances silently.
    function flushMany(address[] calldata tokens) external nonReentrant {
        for (uint256 i; i < tokens.length; ++i) {
            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal > 0) _flushSingle(tokens[i], bal);
        }
    }

    function _flush(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert ZeroBalance();
        _flushSingle(token, bal);
    }

    function _flushSingle(address token, uint256 bal) internal {
        uint256 toTreasury = (bal * treasuryBps) / BPS;
        uint256 toOperations = bal - toTreasury;

        if (toTreasury > 0) {
            IERC20(token).safeTransfer(treasury, toTreasury);
        }
        if (toOperations > 0) {
            IERC20(token).safeTransfer(operations, toOperations);
        }

        emit Flushed(token, toTreasury, toOperations);
    }

    // ---------- views ----------

    /// @notice Preview a flush without executing.
    function previewFlush(address token)
        external
        view
        returns (uint256 balance, uint256 toTreasury, uint256 toOperations)
    {
        balance = IERC20(token).balanceOf(address(this));
        toTreasury = (balance * treasuryBps) / BPS;
        toOperations = balance - toTreasury;
    }
}
