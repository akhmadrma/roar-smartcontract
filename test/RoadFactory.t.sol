// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RoarFactory} from "src/Roar-Factory.sol";
import {RoarToken} from "src/Roar-Token.sol";
import {IRoar} from "src/interfaces/IRoar.sol";

/**
 * @title RoadFactoryTest
 * @notice Test suite for RoadFactory contract
 * @dev Tests the factory pattern for deploying RoarToken contracts
 */
contract RoarFactoryTest is Test {
    RoarFactory factory;
    address deployer;
    address admin;
    address user;

    // Test token configuration
    string constant TOKEN_NAME = "Test Roar Token";
    string constant TOKEN_SYMBOL = "TRT";
    uint256 constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 1 billion tokens
    string constant TOKEN_IMAGE = "ipfs://QmTestImage";
    string constant TOKEN_METADATA = "ipfs://QmTestMetadata";
    string constant TOKEN_CONTEXT = "Test context for Roar token";
    uint256 constant INITIAL_CHAIN_ID = 1; // Ethereum mainnet

    function setUp() public {
        factory = new RoarFactory();
        deployer = address(this);
        admin = address(0x1);
        user = address(0x2);
        // Set chain ID to 1 (Ethereum mainnet) so initial supply is minted
        vm.chainId(INITIAL_CHAIN_ID);
    }

    /**
     * @notice Test successful deployment of RoarToken through factory
     * @dev Verifies that the factory correctly deploys a new token with all parameters
     */
    function test_CreateRoarToken_DeploysTokenCorrectly() public {
        // Create token through factory with config struct
        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: INITIAL_CHAIN_ID
        });
        address tokenAddress = factory.createRoarToken(config);

        // Verify token address is non-zero
        assertNotEq(tokenAddress, address(0), "Token address should not be zero");

        // Verify the deployed contract is a RoarToken
        RoarToken token = RoarToken(tokenAddress);

        // Verify token properties
        assertEq(token.name(), TOKEN_NAME, "Token name mismatch");
        assertEq(token.symbol(), TOKEN_SYMBOL, "Token symbol mismatch");
        assertEq(token.admin(), admin, "Token admin mismatch");
        assertEq(token.originalAdmin(), admin, "Original admin should be the admin");
        assertEq(token.imageUrl(), TOKEN_IMAGE, "Token image URL mismatch");
        assertEq(token.metadata(), TOKEN_METADATA, "Token metadata mismatch");
        assertEq(token.context(), TOKEN_CONTEXT, "Token context mismatch");

        // Verify initial supply was minted (to factory contract, which is msg.sender for token creation)
        assertEq(token.totalSupply(), MAX_SUPPLY, "Initial supply mismatch");
        assertEq(token.balanceOf(address(factory)), MAX_SUPPLY, "Factory should have initial supply");
    }

    /**
     * @notice Test token deployment without initial supply (different chain ID)
     * @dev Verifies that tokens are not minted when chain ID doesn't match initialSupplyChainId
     */
    function test_CreateRoarToken_NoInitialSupplyOnDifferentChain() public {
        // Set chain ID to different value
        vm.chainId(999);

        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: INITIAL_CHAIN_ID // Chain ID 1, but we're on 999
        });
        address tokenAddress = factory.createRoarToken(config);

        RoarToken token = RoarToken(tokenAddress);

        // Verify no tokens were minted
        assertEq(token.totalSupply(), 0, "Total supply should be zero");
        assertEq(token.balanceOf(deployer), 0, "Deployer should have no tokens");
    }

    /**
     * @notice test factory can create multiple tokens with different configs
     * @dev Verifies that each token deployment is independent
     */
    function test_CreateRoarToken_MultipleDeployments() public {
        // Deploy first token
        IRoar.RoarTokenConfig memory config1 = IRoar.RoarTokenConfig({
            name: "Token A",
            symbol: "TKA",
            maxSupply: 100 * 1e18,
            admin: admin,
            image: "ipfs://imageA",
            metadata: "ipfs://metadataA",
            context: "Context A",
            initialSupplyChainId: INITIAL_CHAIN_ID
        });
        address tokenAddress1 = factory.createRoarToken(config1);

        // Deploy second token
        IRoar.RoarTokenConfig memory config2 = IRoar.RoarTokenConfig({
            name: "Token B",
            symbol: "TKB",
            maxSupply: 200 * 1e18,
            admin: user,
            image: "ipfs://imageB",
            metadata: "ipfs://metadataB",
            context: "Context B",
            initialSupplyChainId: INITIAL_CHAIN_ID
        });
        address tokenAddress2 = factory.createRoarToken(config2);

        // Verify tokens are different
        assertNotEq(tokenAddress1, tokenAddress2, "Token addresses should be different");

        // Verify first token properties
        RoarToken token1 = RoarToken(tokenAddress1);
        assertEq(token1.name(), "Token A");
        assertEq(token1.symbol(), "TKA");
        assertEq(token1.totalSupply(), 100 * 1e18);
        assertEq(token1.admin(), admin);

        // Verify second token properties
        RoarToken token2 = RoarToken(tokenAddress2);
        assertEq(token2.name(), "Token B");
        assertEq(token2.symbol(), "TKB");
        assertEq(token2.totalSupply(), 200 * 1e18);
        assertEq(token2.admin(), user);
    }

    /**
     * @notice Test that deployed token works as expected ERC20
     * @dev Verifies standard ERC20 functionality after factory deployment
     */
    function test_CreateRoarToken_TransferWorks() public {
        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: INITIAL_CHAIN_ID
        });
        address tokenAddress = factory.createRoarToken(config);

        RoarToken token = RoarToken(tokenAddress);

        // Transfer from factory (which has initial supply) to user
        // We use vm.prank to make the factory contract call transfer
        uint256 transferAmount = 1000 * 1e18;
        vm.prank(address(factory));
        token.transfer(user, transferAmount);

        // Verify balances
        assertEq(token.balanceOf(user), transferAmount, "User should have received tokens");
        assertEq(token.balanceOf(address(factory)), MAX_SUPPLY - transferAmount, "Factory balance should be reduced");
    }

    /**
     * @notice Test deployed token admin functions work correctly
     * @dev Verifies that admin can update token metadata
     */
    function test_CreateRoarToken_AdminFunctions() public {
        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: INITIAL_CHAIN_ID
        });
        address tokenAddress = factory.createRoarToken(config);

        RoarToken token = RoarToken(tokenAddress);

        // Update image as admin
        vm.prank(admin);
        string memory newImage = "ipfs://NewImage";
        token.updateImage(newImage);
        assertEq(token.imageUrl(), newImage, "Image should be updated");

        // Update metadata as admin
        vm.prank(admin);
        string memory newMetadata = "ipfs://NewMetadata";
        token.updateMetadata(newMetadata);
        assertEq(token.metadata(), newMetadata, "Metadata should be updated");

        // Update admin as admin
        vm.prank(admin);
        token.updateAdmin(user);
        assertEq(token.admin(), user, "Admin should be updated");
    }

    /**
     * @notice Test that non-admin cannot call admin functions
     * @dev Verifies access control on deployed token
     */
    function test_CreateRoarToken_NonAdminCannotUpdate() public {
        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: INITIAL_CHAIN_ID
        });
        address tokenAddress = factory.createRoarToken(config);

        RoarToken token = RoarToken(tokenAddress);

        // Try to update as non-admin
        vm.expectRevert(RoarToken.NotAdmin.selector);
        vm.prank(user);
        token.updateImage("new image");
    }

    /**
     * @notice Test deployed token can be verified by original admin
     * @dev Verifies the verification mechanism works after factory deployment
     */
    function test_CreateRoarToken_Verification() public {
        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: INITIAL_CHAIN_ID
        });
        address tokenAddress = factory.createRoarToken(config);

        RoarToken token = RoarToken(tokenAddress);

        // Verify token is not verified initially
        assertFalse(token.isVerified(), "Token should not be verified initially");

        // Verify as original admin
        vm.prank(admin);
        token.verify();
        assertTrue(token.isVerified(), "Token should be verified");

        // Cannot verify twice
        vm.expectRevert(RoarToken.AlreadyVerified.selector);
        vm.prank(admin);
        token.verify();
    }

    /**
     * @notice Test that factory deploys tokens with unique addresses
     * @dev Verifies that each deployment creates a new contract address
     */
    function test_CreateRoarToken_UniqueAddresses() public {
        IRoar.RoarTokenConfig memory config = IRoar.RoarTokenConfig({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            maxSupply: MAX_SUPPLY,
            admin: admin,
            image: TOKEN_IMAGE,
            metadata: TOKEN_METADATA,
            context: TOKEN_CONTEXT,
            initialSupplyChainId: INITIAL_CHAIN_ID
        });

        address tokenAddress1 = factory.createRoarToken(config);
        address tokenAddress2 = factory.createRoarToken(config);

        // Addresses should be different even with identical parameters
        assertNotEq(tokenAddress1, tokenAddress2, "Each deployment should have unique address");
    }
}
