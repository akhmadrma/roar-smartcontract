// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

//  recieve NFT position from LP

import "./interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FeesManager is AccessControl {
    using SafeERC20 for IERC20;
    mapping(address creator => uint256 tokenId) public ownership;
    mapping(uint256 tokenId => address creator) public tokenIdToCreator;

    address public nativeTokenFees;
    address public positionManager;
    address public swapRouter;

    bytes32 public constant LP_MANAGER_ROLE = keccak256("LP_MANAGER_ROLE");

    event FeesCollected(uint256 indexed tokenId, address indexed creator, uint256 creatorShare, uint256 protocolShare);
    event ProtocolFeesWithdrawn(address indexed admin, uint256 amount);
    event CreatorRegistered(uint256 indexed tokenId, address indexed creator);

    constructor(address positionManager_, address nativeTokenFees_, address swapRouter_) {
        positionManager = positionManager_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        nativeTokenFees = nativeTokenFees_;
        swapRouter = swapRouter_;
    }

    function getFees(uint256 tokenId)
        public
        returns (
            uint256 token0CreatorFees,
            uint256 token0protocolFees,
            uint256 token1CreatorFees,
            uint256 token1protocolFees
        )
    {
        INonfungiblePositionManager _positionManager = INonfungiblePositionManager(positionManager);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: 0, amount1Max: 0
        });

        _positionManager.collect(collectParams);

        // Get uncolled fees (tokensOwed)
        (,,,,,,,,, uint128 tokensOwed0, uint128 tokensOwed1) = _positionManager.positions(tokenId);

        token0CreatorFees = _getCreatorFees(tokensOwed0);
        token0protocolFees = _getProtocolFees(tokensOwed0);
        token1CreatorFees = _getCreatorFees(tokensOwed1);
        token1protocolFees = _getProtocolFees(tokensOwed1);
    }

    function collectFees(uint256 tokenId) external {
        INonfungiblePositionManager _positionManager = INonfungiblePositionManager(positionManager);

        (,, address token0, address token1,,,,,,,) = _positionManager.positions(tokenId);

        // Detect which token is the creator token vs native token
        address creatorToken;
        address nativeToken;
        bool isToken0Native;

        if (token0 == nativeTokenFees) {
            creatorToken = token1;
            nativeToken = token0;
            isToken0Native = true;
        } else {
            creatorToken = token0;
            nativeToken = token1;
            isToken0Native = false;
        }

        // Collect all available fees (use type(uint128).max to collect all)
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });

        (uint256 amount0Collected, uint256 amount1Collected) = _positionManager.collect(collectParams);

        // Determine collected amounts for each token
        uint256 creatorTokenAmount = isToken0Native ? amount1Collected : amount0Collected;
        uint256 nativeTokenAmount = isToken0Native ? amount0Collected : amount1Collected;

        // Swap creator token fees to native token
        if (creatorTokenAmount > 0) {
            IERC20(creatorToken).safeIncreaseAllowance(swapRouter, creatorTokenAmount);

            ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
                tokenIn: creatorToken,
                tokenOut: nativeTokenFees,
                recipient: address(this),
                deadline: block.timestamp + 1000,
                amountIn: creatorTokenAmount,
                amountOutMinimum: 0, // NOTE: Should use oracle for slippage protection
                limitSqrtPrice: 0
            });

            uint256 swappedAmount = ISwapRouter(swapRouter).exactInputSingle(swapParams);

            nativeTokenAmount += swappedAmount;
        }

        // Split fees: 80% to creator, 20% to protocol
        uint256 creatorShare = _getCreatorFees(nativeTokenAmount);
        uint256 protocolShare = _getProtocolFees(nativeTokenAmount);

        address creator = tokenIdToCreator[tokenId];
        require(creator != address(0), "Invalid token owner");

        // Transfer shares
        if (creatorShare > 0) {
            IERC20(nativeTokenFees).safeTransfer(creator, creatorShare);
        }
        // Protocol fees remain in contract for admin withdrawal

        emit FeesCollected(tokenId, creator, creatorShare, protocolShare);
    }

    function updateNativeTokenFees(address nativeTokenFees_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        nativeTokenFees = nativeTokenFees_;
    }

    function updatePositionManager(address positionManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        positionManager = positionManager_;
    }

    function withdrawProtocolFees(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(IERC20(nativeTokenFees).balanceOf(address(this)) >= amount, "Insufficient balance");
        IERC20(nativeTokenFees).transfer(msg.sender, amount);
        emit ProtocolFeesWithdrawn(msg.sender, amount);
    }

    /// @notice Register a creator for a tokenId (called by LPManager during mint)
    /// @param tokenId The NFT position ID
    /// @param creator The creator address to register for this position
    function registerCreator(uint256 tokenId, address creator) external onlyRole(LP_MANAGER_ROLE) {
        require(tokenIdToCreator[tokenId] == address(0), "Creator already registered");
        tokenIdToCreator[tokenId] = creator;
        ownership[creator] = tokenId;
        emit CreatorRegistered(tokenId, creator);
    }

    //helper
    function _getCreatorFees(uint256 totalFees) internal pure returns (uint256) {
        return (totalFees * 80) / 100;
    }

    function _getProtocolFees(uint256 totalFees) internal pure returns (uint256) {
        return (totalFees * 20) / 100;
    }
}
