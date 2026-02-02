// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RoarFactory} from "./Roar-Factory.sol";
import {LPManager} from "./LP-Manager.sol";
import {IRoar} from "./interfaces/IRoar.sol";

contract Roar {
    RoarFactory _factory;
    LPManager _lpManager;
    address _pairedToken;

    constructor(address factory_, address lpManager_, address pairedToken_) {
        _factory = RoarFactory(factory_);
        _lpManager = LPManager(lpManager_);
        _pairedToken = pairedToken_;
    }

    function deployToken(IRoar.RoarTokenConfig memory config) public returns (address) {
        // deploy from factory
        address deployedToken = _factory.createRoarToken(config, address(_lpManager));

        //creating pool
        address pool = _lpManager.createLiquidityPool(deployedToken, _pairedToken);

        //initializing pool
        _lpManager.initialize(deployedToken, pool, config.admin);

        //add liquidity
        _lpManager.addLiquidity(deployedToken, pool, config.admin);

        return deployedToken;
    }

    //TODO : create for swap function
}
