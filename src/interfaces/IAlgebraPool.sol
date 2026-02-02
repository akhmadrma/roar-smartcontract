// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAlgebraPool {
    // Pool state
    function globalState()
        external
        view
        returns (
            uint160 price,
            int24 tick,
            uint16 lastFee,
            uint8 pluginConfig,
            uint16 communityFee,
            bool unlocked
        );

    function tickSpacing() external view returns (int24);

    function token0() external view returns (address);

    function token1() external view returns (address);

    // Initialize
    function initialize(uint160 initialPrice) external;

    // Position management
    struct PositionInfo {
        uint128 liquidity;
        uint32 lastLiquidityAddTimestamp;
        uint256 innerFeeGrowth0Token;
        uint256 innerFeeGrowth1Token;
        uint128 fees0;
        uint128 fees1;
    }

    function positions(bytes32 key)
        external
        view
        returns (PositionInfo memory position);

    // Swap
    struct SwapParams {
        address recipient;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        bool zeroForOne;
    }

    function swap(SwapParams calldata params) external returns (int256 amount0, int256 amount1);
}
