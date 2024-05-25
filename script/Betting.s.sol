// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import "./HelperConfig.sol";
import "../src/Betting.sol";

contract DeployBetting is Script {
    function run() external {
        HelperConfig helperConfig = new HelperConfig();

        (address usdc, address priceFeed, address botAddress, uint256 botFee) = helperConfig
            .activeNetworkConfig();

        vm.startBroadcast();

        new Betting(usdc, priceFeed, botAddress, botFee);

        vm.stopBroadcast();
    }
}
