// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DemoRequester} from "../src/DemoRequester.sol";
import {DemoParticipant} from "../src/DemoParticipant.sol";

contract DeployDemo is Script {
    function run() external {
        address requesterOp = vm.envAddress("REQUESTER_OPERATOR");
        address participantOp = vm.envAddress("PARTICIPANT_OPERATOR");

        vm.startBroadcast();
        DemoRequester requester = new DemoRequester(requesterOp);
        DemoParticipant participant = new DemoParticipant(participantOp);
        vm.stopBroadcast();

        console2.log("requester", address(requester));
        console2.log("participant", address(participant));
        console2.log("requesterOperator", requesterOp);
        console2.log("participantOperator", participantOp);
    }
}
