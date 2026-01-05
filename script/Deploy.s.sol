// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GoeHub} from "../src/GoeHub.sol";

contract Deploy is Script {
    function run() public {
        vm.startBroadcast();

        // TODO
        address flatDirectoryFactory;
        if (block.chainid == 11155111) {
            // Sepolia
            flatDirectoryFactory = 0x68272e6ff4c37b49eAf14bd7DF952E74840a22e0;
        } else {
            flatDirectoryFactory = address(0);
        }

        GoeHub dir = new GoeHub(flatDirectoryFactory);
        console.log("Deployed Hub at:", address(dir));

        vm.stopBroadcast();
    }
}
