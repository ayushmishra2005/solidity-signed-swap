// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SignedSwap} from "../src/SignedSwap.sol";

contract DeploySignedSwap is Script {
    function run() external returns (SignedSwap) {
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(30));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", msg.sender);

        vm.startBroadcast();
        SignedSwap swap = new SignedSwap(feeBps, feeRecipient);
        vm.stopBroadcast();

        return swap;
    }
}
