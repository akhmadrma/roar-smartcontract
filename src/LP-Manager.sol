// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAlgebraFactory} from "./interfaces/IAlgebraFactory.sol";
import {IAlgebraPool} from "./interfaces/IAlgebraPool.sol";
import {
    INonfungiblePositionManager
} from "./interfaces/INonfungiblePositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRoar} from "./interfaces/IRoar.sol";
import {ChainlinkOracle} from "./lib/ChainlinkOracle.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

event LiquidityPoolCreated(address pool);
event LiquidityAdded(
    uint256 tokenId,
    uint128 liquidity,
    uint256 amount0,
    uint256 amount1
);

contract LPManager is AccessControl {
    address _positionManager;
    address _algebraFactory;

    uint16 _initialMarketCap;
    int24 MAX_TICK;
    int24 MIN_TICK;

    bytes32 public DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
    bytes32 public ADMIN_ROLE = keccak256("ADMIN_ROLE");

    ChainlinkOracle oracle;

    constructor(
        address oracle_,
        address positionManager,
        address algebraFactory,
        uint16 initialMarketCap,
        int24 maxTick_,
        int24 minTick_
    ) {
        oracle = ChainlinkOracle(oracle_);
        _positionManager = positionManager;
        _algebraFactory = algebraFactory;
        _initialMarketCap = initialMarketCap;
        MAX_TICK = maxTick_;
        MIN_TICK = minTick_;
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    //create liquidity pool
    function createLiquidityPool(
        address token0,
        address token1
    ) public onlyRole(DEPLOYER_ROLE) returns (address) {
        IAlgebraFactory algebraFactory = IAlgebraFactory(_algebraFactory);
        address pool = algebraFactory.createPool(token0, token1);
        emit LiquidityPoolCreated(pool);
        return pool;
    }

    // initialize position manager
    function initialize(
        address tokenCreated,
        address poolContract,
        address user_
    ) external onlyRole(DEPLOYER_ROLE) {
        IAlgebraPool pool = IAlgebraPool(poolContract);
        address token0 = pool.token0();

        bool owner = _isOwner(token0, user_);

        uint256 tokenSuply = IERC20(tokenCreated).totalSupply();

        uint160 initialPrice = _calculateInitialPrice(tokenSuply, owner);

        pool.initialize(initialPrice);
    }

    function addLiquidity(
        address tokenCreated,
        address poolContract,
        address user_
    ) external onlyRole(DEPLOYER_ROLE) {
        IAlgebraPool pool = IAlgebraPool(poolContract);
        (, int24 currentTick, , , , ) = pool.globalState();
        int24 tickSpacing = pool.tickSpacing();

        int24 tickLower = _roundUpToTickSpacing(
            currentTick + int24(tickSpacing),
            tickSpacing
        );
        int24 tickUpper = _roundDownToTickSpacing(MAX_TICK, tickSpacing);
        uint256 amount0Desired = IERC20(tokenCreated).balanceOf(user_); //NOTE : change this following the first holder token
        require(amount0Desired > 0, "No tokens to add");

        address token0 = pool.token0();
        address token1 = pool.token1();

        if (token0 != tokenCreated) {
            (token0, token1) = (token1, token0);
        }
        

        // ✅ FIX: Transfer tokens from user to this contract
        IERC20(token0).transferFrom(user_, address(this), amount0Desired);

        // ✅ Now approve position manager
        IERC20(token0).approve(_positionManager, amount0Desired);

        // Mint position
        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: 0,
                amount0Min: (amount0Desired * 95) / 100, // Set appropriate slippage tolerance
                amount1Min: 0, // Set appropriate slippage tolerance
                recipient: msg.sender,
                deadline: block.timestamp + 1200 // 20 minutes
            });

        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = INonfungiblePositionManager(_positionManager).mint(params);
        emit LiquidityAdded(tokenId, liquidity, amount0, amount1);
    }

    // owner check
    function _isOwner(
        address token_,
        address user_
    ) private view returns (bool) {
        address tokenAdmin = IRoar(token_).admin();
        return user_ == tokenAdmin;
    }

    // calculate initial price
    function _calculateInitialPrice(
        uint256 tokenCirculatingSupply,
        bool isToken0
    ) private view returns (uint160) {
        uint256 tokenPriceUSD = (_initialMarketCap * 10 ** 8 * 10 ** 18) /
            (tokenCirculatingSupply);
        uint256 tokenPriceETH = (tokenPriceUSD * 10 ** 18) /
            uint256(oracle.getETHUSDPrice());
        // Calculate price ratio
        uint256 priceRatioX192;
        if (isToken0) {
            // Token is token0, WETH is token1
            // Price = amount1/amount0 = WETH/Token
            priceRatioX192 = (10 ** 18 * (2 ** 192)) / tokenPriceETH;
        } else {
            // WETH is token0, token is token1
            // Price = amount1/amount0 = Token/WETH
            priceRatioX192 = (tokenPriceETH * (2 ** 192)) / (10 ** 18);
        }

        uint256 sqrtPriceX96 = Math.sqrt(priceRatioX192);
        require(sqrtPriceX96 > 0, "Invalid price");
        require(sqrtPriceX96 <= type(uint160).max, "Price overflow");

        return uint160(sqrtPriceX96);
    }

    // Round up to nearest tick spacing
    function _roundUpToTickSpacing(
        int24 tick,
        int24 spacing
    ) internal pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder == 0) {
            return tick;
        }

        if (tick > 0) {
            return tick + spacing - remainder;
        } else {
            return tick - remainder;
        }
    }

    // Round down to nearest tick spacing
    function _roundDownToTickSpacing(
        int24 tick,
        int24 spacing
    ) internal pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder == 0) {
            return tick;
        }
        // For positive ticks: round down by subtracting remainder
        // For negative ticks: round down by subtracting (spacing + remainder)
        if (tick > 0) {
            return tick - remainder;
        } else {
            return tick - spacing - remainder; // rounds down (more negative)
        }
    }

    function grantDeployerRole(address deployer) external onlyRole(ADMIN_ROLE) {
    _grantRole(DEPLOYER_ROLE, deployer);
}

    //TODO : add update fuction for constructor params
}
