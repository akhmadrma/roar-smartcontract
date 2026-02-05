// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RoarFactory} from "./Roar-Factory.sol";
import {LPManager} from "./LP-Manager.sol";
import {IRoar} from "./interfaces/IRoar.sol";

contract Roar {
    RoarFactory factory;
    LPManager lpManager;
    address pairedToken;

    event TokenDeployed(address token, address pool, uint256 tokenLiqId, address creator);

    constructor(address factory_, address lpManager_, address pairedToken_) {
        factory = RoarFactory(factory_);
        lpManager = LPManager(lpManager_);
        pairedToken = pairedToken_;
    }

    // NOTE : returns for testing purposes
    function deployToken(IRoar.RoarTokenConfig memory config)
        public
        returns (address deployedToken_, address pool_, uint256 tokenLiqId_, address creator_)
    {
        // deploy from factory
        address deployedToken = factory.createRoarToken(config, address(lpManager));

        //creating pool
        address pool = lpManager.createLiquidityPool(deployedToken, pairedToken);

        //initializing pool
        lpManager.initialize(deployedToken, pool, config.admin);

        //add liquidity
        uint256 tokenLiqId = lpManager.addLiquidity(deployedToken, pool, config.admin);

        emit TokenDeployed(deployedToken, pool, tokenLiqId, config.admin);

        return (deployedToken, pool, tokenLiqId, config.admin);
    }
}
