// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {RoarToken} from "./Roar-Token.sol";
import {IRoar} from "./interfaces/IRoar.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title RoarFactory - Factory for deploying minimal proxy RoarToken clones
/// @notice Uses ERC-1167 minimal proxies to dramatically reduce deployment costs and contract size
/// @dev Factory deploys a master IMPLEMENTATION once, then creates ~100 byte clones
contract RoarFactory is AccessControl {
    /// @notice Address of the master RoarToken IMPLEMENTATION
    /// @dev This address is immutable and set in constructor
    address public immutable IMPLEMENTATION;

    /// @notice Emitted when a new token clone is created
    /// @param tokenAddress The address of the newly created clone
    event TokenCreated(address indexed tokenAddress);

    /// @notice Deploys the master IMPLEMENTATION and stores its address
    /// @dev The IMPLEMENTATION contract is disabled from initialization
    constructor(address roarGateway) {
        // Deploy the master IMPLEMENTATION contract
        // This will be used as the template for all clones
        IMPLEMENTATION = address(new RoarToken());
        _grantRole(DEFAULT_ADMIN_ROLE, roarGateway);
    }

    /// @notice Creates a new RoarToken clone using ERC-1167 minimal proxy pattern
    /// @param config Token configuration parameters
    /// @return tokenAddress The address of the newly created clone
    /// @dev The clone must be initialized after creation via the initialize() function
    function createRoarToken(IRoar.RoarTokenConfig memory config, address LPLock_)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (address tokenAddress)
    {
        // Create a minimal proxy pointing to the IMPLEMENTATION
        tokenAddress = Clones.clone(IMPLEMENTATION);

        // Initialize the clone with the provided configuration
        RoarToken(tokenAddress)
            .initialize(
                config.name,
                config.symbol,
                config.maxSupply,
                config.admin,
                config.image,
                config.metadata,
                config.context,
                config.initialSupplyChainId,
                LPLock_
            );

        emit TokenCreated(tokenAddress);
    }

    /// @notice Predicts the address of a clone before deployment using CREATE2
    /// @param deployer The address that will deploy the clone
    /// @param salt A unique salt for deterministic deployment
    /// @return predicted The predicted address of the clone
    /// @dev Useful for pre-calculating addresses for allowlists or other setup
    function predictDeterministicAddress(address deployer, bytes32 salt) public view returns (address predicted) {
        return Clones.predictDeterministicAddress(IMPLEMENTATION, salt, deployer);
    }

    /// @notice Creates a new RoarToken clone using CREATE2 for deterministic deployment
    /// @param config Token configuration parameters
    /// @param salt A unique salt for deterministic deployment
    /// @return tokenAddress The address of the newly created clone
    /// @dev Uses CREATE2 opcode for deterministic address generation
    function createDeterministicRoarToken(IRoar.RoarTokenConfig memory config, bytes32 salt, address LPLock_)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (address tokenAddress)
    {
        // Create a minimal proxy using CREATE2
        tokenAddress = Clones.cloneDeterministic(IMPLEMENTATION, salt);

        // Initialize the clone with the provided configuration
        RoarToken(tokenAddress)
            .initialize(
                config.name,
                config.symbol,
                config.maxSupply,
                config.admin,
                config.image,
                config.metadata,
                config.context,
                config.initialSupplyChainId,
                LPLock_
            );

        emit TokenCreated(tokenAddress);
    }
}
