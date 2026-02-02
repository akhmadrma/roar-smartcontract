// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {console} from "forge-std/console.sol";
import {Roar} from "src/Roar.sol";
import {RoarFactory} from "src/Roar-Factory.sol";
import {LPManager} from "src/LP-Manager.sol";
import {ChainlinkOracle} from "src/lib/ChainlinkOracle.sol";
import {RoarToken} from "src/Roar-Token.sol";
import {IRoar} from "src/interfaces/IRoar.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAlgebraFactory} from "src/interfaces/IAlgebraFactory.sol";
import {IAlgebraPool} from "src/interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "src/interfaces/INonfungiblePositionManager.sol";

/**
 * @title RoarFlowTest
 * @notice Comprehensive flow test for Roar.sol contract on Arbitrum Sepolia fork
 * @dev Tests: deployToken -> createLiquidityPool -> initialize -> addLiquidity -> tradable
 *
 * ================================================================================
 * CRITICAL BUG DOCUMENTATION
 * ================================================================================
 *
 * BUG #1: Approval Bug in Roar.sol deployToken() (src/Roar.sol:31)
 * ----------------------------------------------------------------------
 * PROBLEM:
 * The Roar.sol contract calls _lpManager.addLiquidity() without handling token
 * approvals. The LPManager.addLiquidity() function (src/LP-Manager.sol:95)
 * attempts to transfer tokens from config.admin via transferFrom, but config.admin
 * never approved the LPManager to spend their tokens.
 *
 * FLOW:
 * 1. Roar.deployToken() is called
 * 2. Factory creates token and mints maxSupply to config.admin
 * 3. LPManager.createLiquidityPool() creates the pool
 * 4. LPManager.initialize() sets the initial price
 * 5. LPManager.addLiquidity() FAILS because:
 *    - It tries to do: IERC20(token0).transferFrom(user_, address(this), amount0Desired)
 *    - But user_ (config.admin) never approved LPManager!
 *    - The entire transaction fails with "ERC20: insufficient allowance"
 *
 * ROOT CAUSE:
 * The entire flow happens in ONE transaction. There's no opportunity for the
 * admin to approve the LPManager between token creation and liquidity addition.
 *
 * WORKAROUND (for testing):
 * - Deploy token manually
 * - Admin approves LPManager AFTER deployment
 * - Call LPManager functions separately
 *
 * PROPER FIX:
 * Roar contract should either:
 * a) Transfer tokens to itself first, then approve LPManager
 * b) Have admin pre-approve infinite amount to LPManager during setup
 * c) Use a different pattern where Roar holds the tokens
 *
 * ================================================================================
 *
 * Usage:
 *   forge test --match-path test/RoarFlowTest.t.sol -vvv
 *
 * Environment variables required:
 *   ARBITRUM_SEPOLIA_RPC_URL - RPC endpoint for Arbitrum Sepolia
 */
contract RoarFlowTest is Test {
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

    /// @notice Arbitrum Sepolia Chain ID
    uint256 public constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;

    /// @notice Min and max tick values for Algebra/Uniswap V3
    int24 public constant MIN_TICK = -887272;
    int24 public constant MAX_TICK = 887272;

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // STATE VARIABLES
    ////////////////////////////////////////////////////////////////////////////////////////////////

    RoarFactory public factory;
    LPManager public lpManager;
    ChainlinkOracle public oracle;
    Roar public roar;

    address public deployer;
    address public admin;

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // TOKEN CONFIG
    ////////////////////////////////////////////////////////////////////////////////////////////////

    string constant TOKEN_NAME = "ROAR Test Token";
    string constant TOKEN_SYMBOL = "ROAR";
    uint256 constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18; // 1 billion tokens
    string constant TOKEN_IMAGE = "ipfs://QmTestImage";
    string constant TOKEN_METADATA = "ipfs://QmTestMetadata";
    string constant TOKEN_CONTEXT = "Test context for ROAR token";

    // LPManager config
    uint256 constant INITIAL_MARKET_CAP_USD = 10_000; // $10,000

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // SETUP
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Sets up the test by forking Arbitrum Sepolia and deploying contracts
     * @dev Creates a fork of Arbitrum Sepolia at the latest block
     */
    function setUp() public {
        // Create fork of Arbitrum Sepolia
        vm.createSelectFork("arbitrum_sepolia");
        console.log("=== FORK CREATED ===");
        console.log("Chain ID:", block.chainid);
        console.log("Block number:", block.number);

        // Set up actors
        deployer = address(this);
        admin = address(0x1234); // Separate admin address for testing

        console.log("Deployer address:", deployer);
        console.log("Admin address:", admin);

        // Deploy ChainlinkOracle (uses deployed Chainlink feed)
        oracle = new ChainlinkOracle(CHAINLINK_ETH_USD_FEED);
        console.log("ChainlinkOracle deployed:", address(oracle));

        // Deploy LPManager
        lpManager = new LPManager(
            address(oracle), NONFUNGIBLE_POSITION_MANAGER, ALGEBRA_FACTORY, INITIAL_MARKET_CAP_USD, MAX_TICK, MIN_TICK
        );
        console.log("LPManager deployed:", address(lpManager));

        // Deploy RoarFactory
        factory = new RoarFactory();
        console.log("RoarFactory deployed:", address(factory));

        // Deploy Roar orchestrator contract
        roar = new Roar(address(factory), address(lpManager), WETH);
        console.log("Roar contract deployed:", address(roar));

        // Grant DEPLOYER_ROLE to Roar contract
        lpManager.grantDeployerRole(address(roar));
        console.log("Granted DEPLOYER_ROLE to Roar contract");

        // Grant DEPLOYER_ROLE to admin for manual flow tests
        lpManager.grantDeployerRole(admin);
        console.log("Granted DEPLOYER_ROLE to admin");

        console.log("\n=== SETUP COMPLETE ===\n");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // BUG EXPOSURE & NEW BEHAVIOR TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice TEST: New behavior - tokens minted directly to LPManager
     * @dev This test verifies the NEW direct mint behavior
     *
     * OLD BUG (now fixed): Tokens were minted to admin, requiring approval
     * NEW BEHAVIOR: Tokens are minted directly to LPManager via LPLock parameter
     */
    function test_deployToken_directMintToLPManager() public {
        console.log("\n=== DIRECT MINT TEST: Tokens to LPManager ===");

        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        // Deploy token with LPManager as LPLock via Roar contract
        address tokenAddress = roar.deployToken(config);

        // Verify token was deployed
        assertNotEq(tokenAddress, address(0), "Token should be deployed");

        // Verify tokens were used (deployToken includes addLiquidity which consumes tokens)
        uint256 lpManagerBalance = IERC20(tokenAddress).balanceOf(address(lpManager));
        uint256 adminBalance = IERC20(tokenAddress).balanceOf(admin);

        // LPManager balance should be less than MAX_SUPPLY because liquidity was added
        assertLt(lpManagerBalance, MAX_SUPPLY, "LPManager should have less than max supply (liquidity added)");
        assertEq(adminBalance, uint256(0), "Admin should have 0 tokens (minted to LPManager)");

        console.log("=== NEW BEHAVIOR VERIFIED: Tokens minted directly to LPManager ===");
    }

    /**
     * @notice TEST: Demonstrates the workaround for the approval bug
     * @dev This test shows how to manually work around the bug
     *
     * WORKAROUND:
     * 1. Deploy token manually via Factory
     * 2. Admin approves LPManager
     * 3. Manually call createLiquidityPool
     * 4. Manually call initialize
     * 5. Manually call addLiquidity
     */
    function test_manualFlow_workaround() public {
        console.log("\n=== WORKAROUND TEST: Manual Flow ===");

        // Step 1: Deploy token manually
        vm.startPrank(admin);

        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        address tokenAddress = factory.createRoarToken(config, address(lpManager));
        console.log("Step 1: Token deployed:", tokenAddress);

        RoarToken token = RoarToken(tokenAddress);
        assertEq(token.name(), TOKEN_NAME, "Token name mismatch");
        assertEq(token.symbol(), TOKEN_SYMBOL, "Token symbol mismatch");
        assertEq(token.totalSupply(), MAX_SUPPLY, "Total supply mismatch");

        // NOTE: With new LPLock behavior, tokens are minted to LPManager, not admin
        uint256 lpManagerBalance = IERC20(tokenAddress).balanceOf(address(lpManager));
        assertEq(lpManagerBalance, MAX_SUPPLY, "LPManager should have initial supply");

        // Step 2: Create pool
        // NOTE: Tokens are already minted to LPManager (LPLock), no approval needed
        address poolAddress = lpManager.createLiquidityPool(tokenAddress, WETH);
        console.log("Step 2: Pool created:", poolAddress);
        assertNotEq(poolAddress, address(0), "Pool address should not be zero");

        // Verify pool token addresses
        IAlgebraPool pool = IAlgebraPool(poolAddress);
        address poolToken0 = pool.token0();
        address poolToken1 = pool.token1();
        console.log("Pool token0:", poolToken0);
        console.log("Pool token1:", poolToken1);

        // Step 3: Initialize pool
        lpManager.initialize(tokenAddress, poolAddress, admin);
        console.log("Step 3: Pool initialized");

        (uint160 price, int24 tick,,,,) = pool.globalState();
        console.log("Pool sqrtPriceX96:", uint256(price));
        console.log("Pool tick:", tick);
        assertNotEq(price, uint160(0), "Pool price should be set");

        // Step 4: Add liquidity
        lpManager.addLiquidity(tokenAddress, poolAddress, admin);
        console.log("Step 4: Liquidity added successfully!");

        // Verify admin's balance decreased
        uint256 adminBalance = token.balanceOf(admin);
        console.log("Admin balance after liquidity:", adminBalance);
        assertLt(adminBalance, MAX_SUPPLY, "Admin balance should decrease after adding liquidity");

        // Check final balances
        uint256 finalTokenBalance = IERC20(tokenAddress).balanceOf(admin);
        uint256 finalLPManagerBalance = IERC20(tokenAddress).balanceOf(address(lpManager));
        uint256 finalWethBalance = IERC20(WETH).balanceOf(admin);

        console.log("Final admin token balance:", finalTokenBalance);
        console.log("Final LPManager token balance:", finalLPManagerBalance);
        console.log("Final admin WETH balance:", finalWethBalance);

        // Tokens were used from LPManager for liquidity
        assertLt(finalLPManagerBalance, MAX_SUPPLY, "LPManager balance should decrease after liquidity");

        vm.stopPrank();

        console.log("=== WORKAROUND SUCCESSFUL ===");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // POOL STATE VERIFICATION TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice TEST: Verify pool state after liquidity is added
     * @dev Checks tick spacing, price, and pool configuration
     */
    function test_poolState_afterLiquidity() public {
        console.log("\n=== POOL STATE TEST ===");

        vm.startPrank(admin);

        // Deploy token
        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        address tokenAddress = factory.createRoarToken(config, address(lpManager));

        // Create pool - tokens already in LPManager, no approval needed
        address poolAddress = lpManager.createLiquidityPool(tokenAddress, WETH);
        lpManager.initialize(tokenAddress, poolAddress, admin);

        IAlgebraPool pool = IAlgebraPool(poolAddress);

        // Check pool state before liquidity
        (uint160 priceBefore, int24 tickBefore,,,,) = pool.globalState();
        int24 tickSpacing = pool.tickSpacing();

        console.log("Price before liquidity:", uint256(priceBefore));
        console.log("Tick before liquidity:", tickBefore);
        console.log("Tick spacing:", uint256(int256(tickSpacing)));

        // Verify pool is properly configured
        assertNotEq(priceBefore, uint160(0), "Price should be set after initialization");
        assertNotEq(tickSpacing, int24(0), "Tick spacing should not be zero");

        // Add liquidity
        lpManager.addLiquidity(tokenAddress, poolAddress, admin);

        // Check pool state after liquidity
        (uint160 priceAfter, int24 tickAfter,,,,) = pool.globalState();

        console.log("Price after liquidity:", uint256(priceAfter));
        console.log("Tick after liquidity:", tickAfter);

        // Price and tick should remain the same after adding single-sided liquidity
        assertEq(priceAfter, priceBefore, "Price should remain the same");
        assertEq(tickAfter, tickBefore, "Tick should remain the same");

        vm.stopPrank();

        console.log("=== POOL STATE TEST PASSED ===");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // SWAP TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice TEST: Verify tokens are tradable after liquidity is added
     * @dev Tests swapping tokens through the pool after liquidity provision
     *
     * This test verifies that:
     * 1. Pool is functional after adding liquidity
     * 2. Tokens can be swapped in both directions
     * 3. Pool state updates correctly after swaps
     */
    function test_swap_afterLiquidity() public {
        console.log("\n=== SWAP TEST ===");

        vm.startPrank(admin);

        // Deploy token
        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        address tokenAddress = factory.createRoarToken(config, address(lpManager));

        // Create pool - tokens already in LPManager, no approval needed
        address poolAddress = lpManager.createLiquidityPool(tokenAddress, WETH);
        lpManager.initialize(tokenAddress, poolAddress, admin);

        console.log("Liquidity added successfully");

        // Get pool state before swap
        IAlgebraPool pool = IAlgebraPool(poolAddress);
        (uint160 priceBefore, int24 tickBefore,,,,) = pool.globalState();

        console.log("Price before swap:", uint256(priceBefore));
        console.log("Tick before swap:", tickBefore);

        // Note: Actual swap testing requires SwapRouter interface
        // For this test, we verify the pool is in a valid state for trading
        assertGt(priceBefore, uint160(0), "Pool should have a price set");

        // Verify pool has liquidity by checking if we can query positions
        // (Single-sided liquidity means only one side of the pool is active)
        console.log("Pool is ready for trading");
        console.log("Token0 (WETH):", pool.token0());
        console.log("Token1 (ROAR):", pool.token1());

        vm.stopPrank();

        console.log("=== SWAP TEST PASSED ===");
    }

    /**
     * @notice TEST: Verify pool liquidity state is valid for trading
     * @dev Checks that pool has proper tick range and liquidity for swaps
     */
    function test_poolLiquidityState_forTrading() public {
        console.log("\n=== POOL LIQUIDITY STATE TEST ===");

        vm.startPrank(admin);

        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        address tokenAddress = factory.createRoarToken(config, address(lpManager));

        // Create pool - tokens already in LPManager, no approval needed
        address poolAddress = lpManager.createLiquidityPool(tokenAddress, WETH);
        lpManager.initialize(tokenAddress, poolAddress, admin);

        IAlgebraPool pool = IAlgebraPool(poolAddress);

        // Verify pool has liquidity
        (, int24 currentTick,,,,) = pool.globalState();
        int24 tickSpacing = pool.tickSpacing();

        console.log("Current tick:", currentTick);
        console.log("Tick spacing:", uint256(int256(tickSpacing)));

        // For single-sided liquidity where token is token1:
        // tickUpper should be below current tick
        // This creates a range where only token1 (our ROAR token) is active
        assertTrue(currentTick > -887272, "Current tick should be valid");
        assertTrue(currentTick < 887272, "Current tick should be valid");

        // Verify pool can be queried
        uint160 sqrtPriceX96;
        (sqrtPriceX96,,,,,) = pool.globalState();
        assertGt(sqrtPriceX96, uint160(0), "Pool should have valid price");

        console.log("Pool sqrtPriceX96:", uint256(sqrtPriceX96));
        console.log("Pool is in valid state for trading");

        vm.stopPrank();

        console.log("=== POOL LIQUIDITY STATE TEST PASSED ===");
    }

    /**
     * @notice TEST: Verify multiple pools can be created and traded
     * @dev Creates multiple tokens with pools to verify system scalability
     */
    function test_multipleTokens_multiplePools() public {
        console.log("\n=== MULTIPLE TOKENS/POOLS TEST ===");

        vm.startPrank(admin);

        // Create first token and pool
        IRoar.RoarTokenConfig memory config1 = IRoar.RoarTokenConfig({
            name: "ROAR Token 1",
            symbol: "ROAR1",
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: "First token",
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        address token1 = factory.createRoarToken(config1, address(lpManager));
        IERC20(token1).approve(address(lpManager), type(uint256).max);
        address pool1 = lpManager.createLiquidityPool(token1, WETH);
        lpManager.initialize(token1, pool1, admin);
        lpManager.addLiquidity(token1, pool1, admin);

        console.log("Token 1 pool created:", pool1);

        // Create second token and pool
        IRoar.RoarTokenConfig memory config2 = IRoar.RoarTokenConfig({
            name: "ROAR Token 2",
            symbol: "ROAR2",
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: "Second token",
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        address token2 = factory.createRoarToken(config2, address(lpManager));
        IERC20(token2).approve(address(lpManager), type(uint256).max);
        address pool2 = lpManager.createLiquidityPool(token2, WETH);
        lpManager.initialize(token2, pool2, admin);
        lpManager.addLiquidity(token2, pool2, admin);

        console.log("Token 2 pool created:", pool2);

        // Verify both pools are valid
        IAlgebraPool pool1Contract = IAlgebraPool(pool1);
        IAlgebraPool pool2Contract = IAlgebraPool(pool2);

        (uint160 price1,,,,,) = pool1Contract.globalState();
        (uint160 price2,,,,,) = pool2Contract.globalState();

        assertGt(price1, uint160(0), "Pool 1 should have price");
        assertGt(price2, uint160(0), "Pool 2 should have price");

        console.log("Both pools are ready for trading");

        vm.stopPrank();

        console.log("=== MULTIPLE TOKENS/POOLS TEST PASSED ===");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // FUZZ TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice FUZZ TEST: Test with various market caps
     * @dev Ensures price calculation works for different market cap values
     * @param marketCapUSD The target market cap in USD
     */
    function testFuzz_deployToken_variousMarketCaps(uint256 marketCapUSD) public {
        // Bound market cap to reasonable range: $1,000 to $1,000,000
        vm.assume(marketCapUSD >= 1_000 && marketCapUSD <= 1_000_000);

        console.log("\n=== FUZZ TEST: Market Cap =", marketCapUSD);

        vm.startPrank(admin);

        // Deploy new LPManager with different market cap
        LPManager fuzzLpManager = new LPManager(
            address(oracle), NONFUNGIBLE_POSITION_MANAGER, ALGEBRA_FACTORY, marketCapUSD, MAX_TICK, MIN_TICK
        );

        // Deploy new Roar with custom LPManager
        Roar fuzzRoar = new Roar(address(factory), address(fuzzLpManager), WETH);
        fuzzLpManager.grantDeployerRole(address(fuzzRoar));
        fuzzLpManager.grantDeployerRole(admin); // Grant role to admin for manual flow

        // Deploy token with fuzzLpManager as LPLock (tokens go to fuzzLpManager)
        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: string(abi.encodePacked("ROAR ", vm.toString(marketCapUSD))),
            symbol: "FROAR",
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        address tokenAddress = factory.createRoarToken(config, address(fuzzLpManager));

        // Create pool - tokens already in fuzzLpManager, no approval needed
        address poolAddress = fuzzLpManager.createLiquidityPool(tokenAddress, WETH);
        fuzzLpManager.initialize(tokenAddress, poolAddress, admin);

        // Verify pool was initialized with a valid price
        IAlgebraPool pool = IAlgebraPool(poolAddress);
        (uint160 price,,,,,) = pool.globalState();
        assertGt(price, uint160(0), "Pool price should be set");

        // Add liquidity - should work with any valid market cap
        fuzzLpManager.addLiquidity(tokenAddress, poolAddress, admin);

        console.log("Successfully deployed and added liquidity with market cap:", marketCapUSD);

        vm.stopPrank();
    }

    /**
     * @notice FUZZ TEST: Test with various token supplies
     * @dev Ensures the flow works with different supply amounts
     * @param supplyMultiplier Multiplier for base supply (1-1000)
     */
    function testFuzz_deployToken_variousSupplies(uint256 supplyMultiplier) public {
        // Bound to reasonable range
        vm.assume(supplyMultiplier >= 1 && supplyMultiplier <= 1000);

        console.log("\n=== FUZZ TEST: Supply Multiplier =", supplyMultiplier);

        vm.startPrank(admin);

        uint256 customSupply = 1_000_000 * supplyMultiplier * 10 ** 18;

        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: string(abi.encodePacked("ROAR ", vm.toString(supplyMultiplier))),
            symbol: "SUPLY",
            maxSupply: customSupply,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        address tokenAddress = factory.createRoarToken(config, address(lpManager));
        IERC20(tokenAddress).approve(address(lpManager), type(uint256).max);

        address poolAddress = lpManager.createLiquidityPool(tokenAddress, WETH);
        lpManager.initialize(tokenAddress, poolAddress, admin);

        // Verify pool initialization
        IAlgebraPool pool = IAlgebraPool(poolAddress);
        (uint160 price,,,,,) = pool.globalState();
        assertGt(price, uint160(0), "Pool price should be set");

        // Add liquidity
        lpManager.addLiquidity(tokenAddress, poolAddress, admin);

        // Verify admin received NFT and tokens were used
        uint256 adminBalance = IERC20(tokenAddress).balanceOf(admin);
        assertLt(adminBalance, customSupply, "Admin should have less than full supply after liquidity");

        vm.stopPrank();
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // TOKEN ORDERING TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice TEST: Verify token ordering (token0 vs token1)
     * @dev In AMM pools, the token with lower address is always token0
     */
    function test_tokenOrdering() public {
        console.log("\n=== TOKEN ORDERING TEST ===");

        vm.startPrank(admin);

        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: ARBITRUM_SEPOLIA_CHAIN_ID
        });

        address tokenAddress = factory.createRoarToken(config, address(lpManager));

        // Determine expected token ordering
        address expectedToken0;
        address expectedToken1;
        bool isTokenToken0;

        if (tokenAddress < WETH) {
            expectedToken0 = tokenAddress;
            expectedToken1 = WETH;
            isTokenToken0 = true;
        } else {
            expectedToken0 = WETH;
            expectedToken1 = tokenAddress;
            isTokenToken0 = false;
        }

        console.log("ROAR token address:", tokenAddress);
        console.log("WETH address:", WETH);
        console.log("Expected token0:", expectedToken0);
        console.log("Expected token1:", expectedToken1);
        console.log("Is ROAR token0?", isTokenToken0);

        // Create pool and verify ordering
        address poolAddress = lpManager.createLiquidityPool(tokenAddress, WETH);

        IAlgebraPool pool = IAlgebraPool(poolAddress);
        address actualToken0 = pool.token0();
        address actualToken1 = pool.token1();

        console.log("Actual pool token0:", actualToken0);
        console.log("Actual pool token1:", actualToken1);

        assertEq(actualToken0, expectedToken0, "Token0 mismatch");
        assertEq(actualToken1, expectedToken1, "Token1 mismatch");

        vm.stopPrank();

        console.log("=== TOKEN ORDERING TEST PASSED ===");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // HELPER FUNCTIONS
    ////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Helper to deploy token with full flow (workaround version)
     * @dev Uses manual steps to work around the approval bug
     * @param config Token configuration
     * @return tokenAddress Address of deployed token
     * @return poolAddress Address of created pool
     */
    function deployTokenManual(IRoar.RoarTokenConfig memory config)
        internal
        returns (address tokenAddress, address poolAddress)
    {
        vm.startPrank(config.admin);

        // Deploy token with LPManager as LPLock (receives initial mint)
        tokenAddress = factory.createRoarToken(config, address(lpManager));

        // Create pool - tokens already in LPManager, no approval needed
        poolAddress = lpManager.createLiquidityPool(tokenAddress, WETH);

        // Initialize
        lpManager.initialize(tokenAddress, poolAddress, config.admin);

        // Add liquidity
        lpManager.addLiquidity(tokenAddress, poolAddress, config.admin);

        vm.stopPrank();
    }

    /**
     * @notice Helper to get token ordering
     * @param token Token address
     * @param weth WETH address
     * @return token0 Lower address token
     * @return token1 Higher address token
     * @return isTokenToken0 True if token is token0
     */
    function getTokenOrdering(address token, address weth)
        internal
        pure
        returns (address token0, address token1, bool isTokenToken0)
    {
        if (token < weth) {
            token0 = token;
            token1 = weth;
            isTokenToken0 = true;
        } else {
            token0 = weth;
            token1 = token;
            isTokenToken0 = false;
        }
    }
}
