// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IRoar {
    struct RoarTokenConfig {
        string name;
        string symbol;
        uint256 maxSupply;
        address admin;
        string image;
        string metadata;
        string context;
        uint256 initialSupplyChainId;
    }
}
