// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {console} from "forge-std/console.sol";
import {Roar} from "src/Roar.sol";
import {RoarFactory} from "src/Roar-Factory.sol";
import {LPManager} from "src/LP-Manager.sol";
import {ChainlinkOracle} from "src/lib/ChainlinkOracle.sol";
import {RoarToken} from "src/Roar-Token.sol";
import {IRoar} from "src/interfaces/IRoar.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAlgebraPool} from "src/interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "src/interfaces/INonfungiblePositionManager.sol";
import {FeesManager} from "src/Fees-Manager.sol";
import {INonfungiblePositionManager} from "src/interfaces/INonfungiblePositionManager.sol";
import {IAlgebraPool} from "src/interfaces/IAlgebraPool.sol";
import {ISwapRouter} from "src/interfaces/ISwapRouter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract FeesFlowTest is Test {
    ////////////////////////////////////////////////////////////////////////////////////////////////
    // CONSTANTS - Arbitrum Sepolia Deployed Addresses
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Camelot Algebra Factory on Arbitrum Sepolia
    address public constant ALGEBRA_FACTORY = 0xaA37Bea711D585478E1c04b04707cCb0f10D762a;

    /// @notice Camelot Nonfungible Position Manager on Arbitrum Sepolia
    address public constant NONFUNGIBLE_POSITION_MANAGER = 0x79EA6cB3889fe1FC7490A1C69C7861761d882D4A;

    /// @notice WETH on Arbitrum Sepolia
    address public constant WETH = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;

    /// @notice Chainlink ETH/USD Feed on Arbitrum Sepolia
    address public constant CHAINLINK_ETH_USD_FEED = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;

    address public constant SWAP_ROUTER = 0x171B925C51565F5D2a7d8C494ba3188D304EFD93;
    /// @notice Arbitrum Sepolia Chain ID
    uint256 public constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;

    /// @notice Min and max tick values for Algebra/Uniswap V3
    int24 public constant MIN_TICK = -887272;
    int24 public constant MAX_TICK = 887272;

    /// @notice Initial market cap in USD
    uint256 constant INITIAL_MARKET_CAP_USD = 10_000; // $10,000

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // STATE VARIABLES
    ////////////////////////////////////////////////////////////////////////////////////////////////

    RoarFactory public factory;
    LPManager public lpManager;
    ChainlinkOracle public oracle;
    Roar public roar;
    FeesManager public feesManager;

    address public creator;
    address public admin;
    address public traders;

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // TOKEN CONFIG
    ////////////////////////////////////////////////////////////////////////////////////////////////

    string constant TOKEN_NAME = "ROAR Test Token";
    string constant TOKEN_SYMBOL = "ROAR";
    uint256 constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18; // 1 billion tokens
    string constant TOKEN_IMAGE = "ipfs://QmTestImage";
    string constant TOKEN_METADATA = "ipfs://QmTestMetadata";
    string constant TOKEN_CONTEXT = "Test context for ROAR token";

    function setUp() public {
        // Create fork of Arbitrum Sepolia
        vm.createSelectFork("arbitrum_sepolia");
        console.log("=== FORK CREATED ===");
        console.log("Chain ID:", block.chainid);
        console.log("Block number:", block.number);

        // Set up actors
        admin = address(this);
        creator = address(0x1234); // Separate admin address for testing
        traders = address(0x5678); // Protocol admin for fees

        console.log("=== State ===");
        console.log("Creator address:", creator);
        console.log("Admin address:", admin);
        console.log("Traders address", traders);

        console.log("=== Contracts ===");
        //Deploy Oracle
        oracle = new ChainlinkOracle(CHAINLINK_ETH_USD_FEED);
        console.log("ChainlinkOracle deployed:", address(oracle));

        // Deploy FeesManager first (needed for LPManager)
        feesManager = new FeesManager(
            NONFUNGIBLE_POSITION_MANAGER,
            WETH, // native token fees in WETH
            SWAP_ROUTER
        );
        console.log("FeesManager deployed:", address(feesManager));

        // Deploy LPManager with FeesManager
        lpManager = new LPManager(
            address(oracle),
            NONFUNGIBLE_POSITION_MANAGER,
            ALGEBRA_FACTORY,
            INITIAL_MARKET_CAP_USD,
            MAX_TICK,
            MIN_TICK,
            address(feesManager)
        );
        console.log("LPManager deployed:", address(lpManager));

        // Grant LP_MANAGER_ROLE to LPManager so it can register creators
        feesManager.grantRole(feesManager.LP_MANAGER_ROLE(), address(lpManager));
        console.log("Granted LP_MANAGER_ROLE to LPManager");

        // Deploy RoarFactory
        factory = new RoarFactory(admin);
        console.log("RoarFactory deployed:", address(factory));
        // Deploy Roar orchestrator contract
        roar = new Roar(address(factory), address(lpManager), WETH);
        console.log("Roar contract deployed:", address(roar));

        // Grant DEFAULT_ADMIN_ROLE to Roar contract
        factory.grantRole(factory.DEFAULT_ADMIN_ROLE(), address(roar));
        console.log("Granted DEFAULT_ADMIN_ROLE to Roar contract");

        // Grant DEPLOYER_ROLE to Roar contract
        lpManager._grantDeployerRole(address(roar));
        console.log("Granted lpManager DEPLOYER_ROLE to Roar contract");

        console.log("\n=== SETUP COMPLETE ===\n");
    }

    function test_DeployToken()
        public
        returns (address token_, address pool_, uint256 tokenLiqId_, address creatorAddress_)
    {
        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: creator,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        (address token, address pool, uint256 tokenLiqId, address creatorAddress) = roar.deployToken(config);

        console.log("\n=== DEPLOY TOKEN TEST ===");
        console.log("Token deployed:", token);
        console.log("Pool deployed:", pool);
        console.log("Token liquidity ID:", tokenLiqId);
        console.log("Token creator:", creatorAddress);

        IAlgebraPool poolContract = IAlgebraPool(pool);

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER);

        assertEq(creatorAddress, creator, "Token creator mismatch");

        vm.startPrank(traders);
        // Fund the caller (traders) with ETH for gas fee
        vm.deal(traders, 100 ether);
        getWETH(100 ether);
        console.log("Traders WETH balance:", IERC20(WETH).balanceOf(traders));

        simulateTrading(token, pool, 20, traders);

        console.log("Token balance:", IERC20(token).balanceOf(traders));

        vm.stopPrank();

        feesManager.collectFees(tokenLiqId);

        console.log("creator WETH balance:", IERC20(WETH).balanceOf(creator));
        console.log("feesManager WETH balance:", IERC20(WETH).balanceOf(address(feesManager)));

        return (token, pool, tokenLiqId, creatorAddress);
    }

    ///////////////////////////////////////////////////////////
    ////// HELPERS
    ///////////////////////////////////////////////////////////

    /**
     * @notice Helper to execute a swap through the swap router
     * @dev Simulates trading activity to generate fees for liquidity providers
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens to swap
     * @param recipient Address to receive output tokens
     * @return amountOut Amount of output tokens received
     */
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, address recipient, address from)
        public
        returns (uint256 amountOut)
    {
        // Pull tokens from the actor (who approved us in prank context)
        IERC20(tokenIn).transferFrom(from, address(this), amountIn);

        // Approve swap router to spend tokens (now we own them)
        IERC20(tokenIn).approve(SWAP_ROUTER, amountIn);

        // Create swap params
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            recipient: recipient,
            deadline: block.timestamp + 1000,
            amountIn: amountIn,
            amountOutMinimum: 0, // Accept any amount out for testing
            limitSqrtPrice: 0
        });

        // Execute swap
        amountOut = ISwapRouter(SWAP_ROUTER).exactInputSingle(params);
    }

    /**
     * @notice Helper to simulate trading activity and generate fees
     * @dev Executes multiple swaps back and forth to generate fees
     * @param tokenAddress The creator token address
     * @param poolAddress The pool address
     * @param iterations Number of swap iterations to perform
     */
    function simulateTrading(address tokenAddress, address poolAddress, uint256 iterations, address actor) internal {
        uint256 swapAmount = 0.1 ether;
        uint256 successfulSwaps = 0;

        for (uint256 i = 0; i < iterations; i++) {
            if (i % 2 == 0) {
                // Swap WETH for tokens
                uint256 wethBalance = IERC20(WETH).balanceOf(actor);
                if (wethBalance >= swapAmount) {
                    // Approve test contract to pull tokens (in prank context as actor)
                    IERC20(WETH).approve(address(this), swapAmount);
                    try this.executeSwap(WETH, tokenAddress, swapAmount, actor, actor) returns (uint256 amountOut) {
                        // console.log("Swap WETH -> Token, received:", amountOut);
                        successfulSwaps++;
                    } catch Error(string memory reason) {
                        console.log("Swap FAILED:", reason);
                    } catch {
                        console.log("Swap FAILED: Unknown error");
                    }
                } else {
                    console.log("Swap SKIPPED: Insufficient WETH");
                }
            } else {
                // Swap tokens for WETH
                uint256 tokenBalance = IERC20(tokenAddress).balanceOf(actor);
                if (tokenBalance >= swapAmount) {
                    // Approve test contract to pull tokens (in prank context as actor)
                    IERC20(tokenAddress).approve(address(this), swapAmount);
                    try this.executeSwap(tokenAddress, WETH, swapAmount, actor, actor) returns (uint256 amountOut) {
                        // console.log("Swap Token -> WETH, received:", amountOut);
                        successfulSwaps++;
                    } catch Error(string memory reason) {
                        console.log("Swap FAILED:", reason);
                    } catch {
                        console.log("Swap FAILED: Unknown error");
                    }
                } else {
                    console.log("Swap SKIPPED: Insufficient tokens");
                }
            }
        }

        console.log("Total successful swaps:", successfulSwaps);
        require(successfulSwaps > 0, "No swaps executed successfully - check balances and pool state");
    }

    /**
     * @notice Helper to get WETH for testing
     * @dev Wraps ETH to get WETH for swap testing
     * @param amount Amount of ETH to wrap
     */
    function getWETH(uint256 amount) internal {
        (bool success,) = WETH.call{value: amount}(abi.encodeWithSignature("deposit()"));
        require(success, "WETH deposit failed");
    }
}
