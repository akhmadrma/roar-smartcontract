// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/interfaces/feeds/AggregatorV3Interface.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

event OracleUpdated(address oracle, uint256 updatedAt);

contract ChainlinkOracle is Ownable {
    AggregatorV3Interface internal dataFeed;
    address oracle;

    constructor(address oracle_) Ownable(msg.sender) {
        dataFeed = AggregatorV3Interface(oracle_);
        oracle = oracle_;
    }

    /**
     * Returns the latest answer.
     */
    function getETHUSDPrice() public view returns (int256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = dataFeed.latestRoundData();

        require(answer > 0, "Invalid price");
        require(block.timestamp - updatedAt <= 1200, "Stale price");
        require(answeredInRound >= roundId, "Incomplete round");

        return answer;
    }

    function updateOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "Invalid oracle");
        oracle = newOracle;

        dataFeed = AggregatorV3Interface(oracle);
        uint256 timestamp = block.timestamp;

        emit OracleUpdated(oracle, timestamp);
    }
}
