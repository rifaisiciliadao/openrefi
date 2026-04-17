// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/// @title YieldToken — "The Fruit"
/// @notice Per-campaign harvest claim token. Minted by StakingVault, burned on redemption.
/// @dev Fresh $YIELD minted each season. No carry-over between seasons.
///      Initializable so it can be deployed as an EIP-1167 clone.
contract YieldToken is Initializable, ERC20Upgradeable {
    address public stakingVault;
    address public harvestManager;

    error OnlyStakingVault();
    error OnlyVaultOrHarvest();

    modifier onlyStakingVault() {
        if (msg.sender != stakingVault) revert OnlyStakingVault();
        _;
    }

    modifier onlyVaultOrHarvest() {
        if (msg.sender != stakingVault && msg.sender != harvestManager) revert OnlyVaultOrHarvest();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name_, string memory symbol_, address stakingVault_, address harvestManager_)
        external
        initializer
    {
        __ERC20_init(name_, symbol_);
        stakingVault = stakingVault_;
        harvestManager = harvestManager_;
    }

    /// @notice Mint yield tokens. Only callable by StakingVault during staking.
    function mint(address to, uint256 amount) external onlyStakingVault {
        _mint(to, amount);
    }

    /// @notice Burn yield tokens. Callable by StakingVault (forfeit) or HarvestManager (redemption).
    function burn(address from, uint256 amount) external onlyVaultOrHarvest {
        _burn(from, amount);
    }
}
