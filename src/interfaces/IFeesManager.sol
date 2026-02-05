// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IFeesManager {
    function registerCreator(uint256 tokenId, address creator) external;
}
