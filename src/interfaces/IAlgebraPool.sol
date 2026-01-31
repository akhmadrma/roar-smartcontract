// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAlgebraPool {
    function initialize(uint160 initialPrice) external;
    function globalState()
        external
        view
        returns (uint160 price, int24 tick, uint16 lastFee, uint8 pluginConfig, uint16 communityFee, bool unlocked);
    function tickSpacing() external view returns (int24);
    function token0() external view returns (address);
    function token1() external view returns (address);
}
