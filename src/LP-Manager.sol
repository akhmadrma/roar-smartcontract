// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAlgebraFactory} from "./interfaces/IAlgebraFactory.sol";
import {IAlgebraPool} from "./interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRoar} from "./interfaces/IRoar.sol";
import {ChainlinkOracle} from "./lib/ChainlinkOracle.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

event LiquidityPoolCreated(address pool);
event LiquidityAdded(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
event LiquidityPoolInitialized(address pool, uint256 initialPrice);

contract LPManager is AccessControl, ReentrancyGuard {
    address _positionManager;
    address _algebraFactory;

    uint256 _initialMarketCap;
    int24 MAX_TICK;
    int24 MIN_TICK;

    bytes32 public DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
    bytes32 public ADMIN_ROLE = keccak256("ADMIN_ROLE");

    ChainlinkOracle oracle;

    modifier invalidValue(uint256 value) {
        require(value > 0, "Invalid value");
        _;
    }

    constructor(
        address oracle_,
        address positionManager,
        address algebraFactory,
        uint256 initialMarketCap,
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
    function createLiquidityPool(address token0, address token1)
        public
        onlyRole(DEPLOYER_ROLE)
        nonReentrant
        returns (address)
    {
        IAlgebraFactory algebraFactory = IAlgebraFactory(_algebraFactory);
        address pool = algebraFactory.createPool(token0, token1);
        emit LiquidityPoolCreated(pool);
        return pool;
    }

    // initialize position manager
    function initialize(address tokenCreated, address poolContract, address user_) external onlyRole(DEPLOYER_ROLE) {
        IAlgebraPool pool = IAlgebraPool(poolContract);

        // BUG FIX: Check if user_ is admin of tokenCreated (the RoarToken), not token0
        // token0 could be WETH which doesn't have admin() function
        bool owner = _isOwner(tokenCreated, user_);

        uint256 tokenSuply = IERC20(tokenCreated).totalSupply();
        require(tokenSuply > 0, "Token supply is zero");

        uint160 initialPrice = _calculateInitialPrice(tokenSuply, owner);

        pool.initialize(initialPrice);

        emit LiquidityPoolInitialized(poolContract, initialPrice);
    }

    function addLiquidity(address tokenCreated, address poolContract, address user_)
        external
        onlyRole(DEPLOYER_ROLE)
        nonReentrant
    {
        IAlgebraPool pool = IAlgebraPool(poolContract);
        (, int24 currentTick,,,,) = pool.globalState();
        int24 tickSpacing = pool.tickSpacing();

        // Get actual pool tokens (WETH is always token0 due to lower address)
        address poolToken0 = pool.token0();
        address poolToken1 = pool.token1();
        bool isTokenCreatedToken0 = (poolToken0 == tokenCreated);

        uint256 amount0Desired = IERC20(tokenCreated).balanceOf(address(this));
        require(amount0Desired > 0, "No tokens to add");

        // ✅ Approve position manager with the created token
        IERC20(tokenCreated).approve(_positionManager, amount0Desired);

        // Calculate tick range based on whether created token is token0 or token1
        int24 tickLower;
        int24 tickUpper;

        if (isTokenCreatedToken0) {
            // Token is token0 - single-sided liquidity (only token0)
            tickLower = _roundUpToTickSpacing(currentTick + int24(tickSpacing), tickSpacing);
            tickUpper = _roundDownToTickSpacing(MAX_TICK, tickSpacing);
        } else {
            // Token is token1 - single-sided liquidity (only token1)
            tickLower = _roundUpToTickSpacing(MIN_TICK, tickSpacing);
            tickUpper = _roundDownToTickSpacing(currentTick - int24(tickSpacing), tickSpacing);
        }

        // Determine amounts based on which token we're providing
        uint256 createdTokenAmount;
        uint256 pairedTokenAmount;

        if (isTokenCreatedToken0) {
            createdTokenAmount = amount0Desired;
            pairedTokenAmount = 0;
        } else {
            createdTokenAmount = 0;
            pairedTokenAmount = amount0Desired;
        }

        // Mint position - ALWAYS use poolToken0 and poolToken1 (maintain address order)
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: poolToken0, // Lower address token (WETH)
            token1: poolToken1, // Higher address token (our token)
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: createdTokenAmount,
            amount1Desired: pairedTokenAmount,
            amount0Min: (createdTokenAmount * 95) / 100, // Set appropriate slippage tolerance
            amount1Min: 0, // Set appropriate slippage tolerance
            recipient: msg.sender, // TODO: create LP contract for manage fee
            deadline: block.timestamp + 1200 // 20 minutes
        });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            INonfungiblePositionManager(_positionManager).mint(params);
        emit LiquidityAdded(tokenId, liquidity, amount0, amount1);
    }

    // owner check
    function _isOwner(address token_, address user_) private view returns (bool) {
        address tokenAdmin = IRoar(token_).admin();
        return user_ == tokenAdmin;
    }

    // calculate initial price
    function _calculateInitialPrice(uint256 tokenCirculatingSupply, bool isToken0)
        private
        view
        invalidValue(tokenCirculatingSupply)
        returns (uint160)
    {
        uint256 tokenPriceUSD = (_initialMarketCap * 10 ** 8 * 10 ** 18) / (tokenCirculatingSupply);
        uint256 tokenPriceETH = (tokenPriceUSD * 10 ** 18) / uint256(oracle.getETHUSDPrice());
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

        return SafeCast.toUint160(sqrtPriceX96);
    }

    // Round up to nearest tick spacing
    function _roundUpToTickSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
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
    function _roundDownToTickSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
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
