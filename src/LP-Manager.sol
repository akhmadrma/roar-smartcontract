// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAlgebraFactory} from "./interfaces/IAlgebraFactory.sol";
import {IAlgebraPool} from "./interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IFeesManager} from "./interfaces/IFeesManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRoar} from "./interfaces/IRoar.sol";
import {ChainlinkOracle} from "./lib/ChainlinkOracle.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

event LiquidityPoolCreated(address pool);
event LiquidityAdded(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1, address feeManager);
event LiquidityPoolInitialized(address pool, uint256 initialPrice);

contract LPManager is AccessControl, ReentrancyGuard {
    address _positionManager;
    address _algebraFactory;

    address _feeManager;

    uint256 _initialMarketCap;
    int24 MAX_TICK;
    int24 MIN_TICK;

    bytes32 public DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    ChainlinkOracle oracle;

    modifier invalidValue(uint256 value) {
        _valueCheck(value);
        _;
    }

    constructor(
        address oracle_,
        address positionManager,
        address algebraFactory,
        uint256 initialMarketCap,
        int24 maxTick_,
        int24 minTick_,
        address feeManager_
    ) {
        require(initialMarketCap > 0, "Market cap must be positive");
        oracle = ChainlinkOracle(oracle_);
        _positionManager = positionManager;
        _algebraFactory = algebraFactory;
        _initialMarketCap = initialMarketCap;
        MAX_TICK = maxTick_;
        MIN_TICK = minTick_;
        _feeManager = feeManager_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
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

        // Validate user is admin of tokenCreated
        require(_isOwner(tokenCreated, user_), "User is not token admin");

        uint256 tokenSuply = IERC20(tokenCreated).totalSupply();
        require(tokenSuply > 0, "Token supply is zero");

        // Determine actual token ordering from pool
        address poolToken0 = pool.token0();
        bool isToken0 = (poolToken0 == tokenCreated);

        uint160 initialPrice = _calculateInitialPrice(tokenSuply, isToken0);

        pool.initialize(initialPrice);

        emit LiquidityPoolInitialized(poolContract, initialPrice);
    }

    function addLiquidity(
        address tokenCreated,
        address poolContract,
        address creator
        //NOTE : returns for testing
    )
        external
        onlyRole(DEPLOYER_ROLE)
        nonReentrant
        returns (uint256)
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

        // Calculate tick range based on whether created token is token0 or token1
        int24 tickLower;
        int24 tickUpper;

        if (isTokenCreatedToken0) {
            // Token is token0 - single-sided liquidity (only token0)
            tickLower = _roundUpToTickSpacing(currentTick + tickSpacing, tickSpacing);
            tickUpper = _roundDownToTickSpacing(MAX_TICK, tickSpacing);
        } else {
            // Token is token1 - single-sided liquidity (only token1)
            tickLower = _roundUpToTickSpacing(MIN_TICK, tickSpacing);
            tickUpper = _roundDownToTickSpacing(currentTick - tickSpacing, tickSpacing);
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

        IERC20(poolToken0).approve(_positionManager, createdTokenAmount);
        IERC20(poolToken1).approve(_positionManager, pairedTokenAmount);

        // Mint position - ALWAYS use poolToken0 and poolToken1 (maintain address order)
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: poolToken0, // Lower address token (WETH)
            token1: poolToken1, // Higher address token (our token)
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: createdTokenAmount,
            amount1Desired: pairedTokenAmount,
            amount0Min: (createdTokenAmount * 95) / 100, // Set appropriate slippage tolerance
            amount1Min: (pairedTokenAmount * 95) / 100, // Set appropriate slippage tolerance
            recipient: _feeManager,
            deadline: block.timestamp + 1200 // 20 minutes
        });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            INonfungiblePositionManager(_positionManager).mint(params);
        emit LiquidityAdded(tokenId, liquidity, amount0, amount1, params.recipient);

        // Register creator with FeesManager for fee collection
        IFeesManager(_feeManager).registerCreator(tokenId, creator);

        return tokenId;
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

        int256 ethUsdPrice = oracle.getETHUSDPrice();
        require(ethUsdPrice > 0, "Oracle: invalid ETH price");

        uint256 tokenPriceETH = (tokenPriceUSD * 10 ** 18) / SafeCast.toUint256(ethUsdPrice);
        // Calculate price ratio
        uint256 priceRatioX192;
        if (isToken0) {
            // Token is token0, WETH is token1
            // Price = amount1/amount0 = WETH/Token
            priceRatioX192 = (tokenPriceETH * (2 ** 192)) / (10 ** 18);
        } else {
            // WETH is token0, token is token1
            // Price = amount1/amount0 = Token/WETH
            priceRatioX192 = (10 ** 18 * (2 ** 192)) / tokenPriceETH;
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

    function _valueCheck(uint256 value) internal pure {
        require(value > 0, "Invalid value");
    }

    function _grantDeployerRole(address deployer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(deployer != address(0), "Invalid deployer address");
        grantRole(DEPLOYER_ROLE, deployer);
    }

    function _grantAdminRole(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "Invalid admin address");
        revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function updateInitialMarketCap(uint256 initialMarketCap_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _initialMarketCap = initialMarketCap_;
    }

    function updateMaxTick(int24 maxTick_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MAX_TICK = maxTick_;
    }

    function updateMinTick(int24 minTick_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MIN_TICK = minTick_;
    }

    function updatePositionManager(address positionManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _positionManager = positionManager_;
    }

    function updateAlgebraFactory(address algebraFactory_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _algebraFactory = algebraFactory_;
    }

    function updateOracle(address oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracle = ChainlinkOracle(oracle_);
    }
}
