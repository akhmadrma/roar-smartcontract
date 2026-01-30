// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import {RoarFactory} from "../src/Roar-Factory.sol";

contract DeployFactory is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        //Deploy
        console.log("Deploying RoarFactory");
        RoarFactory factory = new RoarFactory();
        console.log("RoarFactory deployed at: ", address(factory));
    }
}
