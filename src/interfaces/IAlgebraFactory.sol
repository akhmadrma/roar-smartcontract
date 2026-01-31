// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAlgebraFactory {
    function createPool(address tokenA, address tokenB) external returns (address pool);
}
