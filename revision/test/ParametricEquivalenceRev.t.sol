// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {RevisionBase} from "./RevisionBase.sol";
import {BladeRequester, BladeParticipant} from "app/blade-app/BladeRequest.sol";
import {BladeManager, BladeCnParticipant} from "app/blade-app/BladeContractNet.sol";
import {ManualInitiator, ManualParticipant, REQ_NONE, REQ_REQUESTED, REQ_AGREED} from "app/manual/ManualRequest.sol";
import {
    ManualManager,
    ManualCnParticipant,
    CN_SLOT_NONE,
    CN_PART_NONE,
    CN_PART_CFPED
} from "app/manual/ManualContractNet.sol";
import {RequestPhase} from "blade/core/RequestAgent.sol";
import {ContractNetLib} from "blade/core/ContractNetLib.sol";

/// @dev Revision of comparison/test/ParametricEquivalence.t.sol (unchanged for E0/E1). Same 13 cells and
/// state assertions. Differences, all required by the corrected Core or the revised methodology:
/// - BLADE continuations carry the Core-assigned token (`_token`, zero on E1) and no inbound payload.
/// - Payload delivery is asserted on the recorded `handle` call data for BLADE and on the callback call
///   data for the manual baseline (stronger than the original "last Received log" check: every
///   recipient, exactly once). `Received` contents are checked as well unless the profile declares the
///   emission removed, in which case their absence is asserted.
contract ParametricEquivalenceRevTest is RevisionBase {
    bytes32 internal constant CID = keccak256("f1.5");

    function _empty() internal pure returns (address[] memory a) {}

    function _r3(bytes memory payload) internal {
        BladeRequester bI = new BladeRequester();
        BladeParticipant bP = new BladeParticipant();
        vm.recordLogs();
        vm.startStateDiffRecording();
        bI.startRequest(address(bP), CID, payload);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        _assertDeliveredOnce(_handledContents(acc, address(bP)), payload, "request");
        _assertReceived(_receivedContents(), 1, payload, "request");
        assertEq(uint8(bI.requestStatus(CID).phase), uint8(RequestPhase.Requested));
        assertEq(uint8(bP.requestStatus(CID).phase), uint8(RequestPhase.Requested));
        bP.agree(_reqInbound(CID, _token(address(bP), CID), ""), address(bI));
        assertEq(uint8(bI.requestStatus(CID).phase), uint8(RequestPhase.Agreed));
        assertEq(uint8(bP.requestStatus(CID).phase), uint8(RequestPhase.Agreed));
        vm.recordLogs();
        vm.startStateDiffRecording();
        bP.inform(_reqInbound(CID, _token(address(bP), CID), ""), address(bI), payload);
        acc = vm.stopAndReturnStateDiff();
        _assertDeliveredOnce(_handledContents(acc, address(bI)), payload, "inform");
        _assertReceived(_receivedContents(), 1, payload, "inform");
        assertEq(uint8(bI.requestStatus(CID).phase), uint8(RequestPhase.None));
        assertEq(uint8(bP.requestStatus(CID).phase), uint8(RequestPhase.None));

        ManualInitiator mI = new ManualInitiator();
        ManualParticipant mP = new ManualParticipant();
        vm.startStateDiffRecording();
        mI.startRequest(address(mP), CID, payload);
        acc = vm.stopAndReturnStateDiff();
        _assertDeliveredOnce(
            _manualContents(acc, address(mP), "onRequest(bytes32,bytes)", "onRequest(bytes32,bytes32,bytes)"),
            payload,
            "manual request"
        );
        assertEq(mI.status(CID).phase, REQ_REQUESTED);
        assertEq(mP.status(CID).phase, REQ_REQUESTED);
        mP.agree(CID);
        assertEq(mI.status(CID).phase, REQ_AGREED);
        vm.startStateDiffRecording();
        mP.inform(CID, payload);
        acc = vm.stopAndReturnStateDiff();
        _assertDeliveredOnce(
            _manualContents(acc, address(mI), "onInform(bytes32,bytes)", "onInform(bytes32,bytes32,bytes)"),
            payload,
            "manual inform"
        );
        assertEq(mI.status(CID).phase, REQ_NONE);
        assertEq(mP.status(CID).phase, REQ_NONE);
    }

    function test_R3_payload_0() public {
        _r3(_payload(0, 0xab));
    }

    function test_R3_payload_32() public {
        _r3(_payload(32, 0xab));
    }

    function test_R3_payload_256() public {
        _r3(_payload(256, 0xab));
    }

    function test_R3_payload_1024() public {
        _r3(_payload(1024, 0xab));
    }

    function _scenarioA(uint256 n, bytes memory payload) internal {
        BladeManager bM = new BladeManager();
        address[] memory bP = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            bP[i] = address(new BladeCnParticipant());
            for (uint256 j = 0; j < i; j++) {
                assertTrue(bP[i] != bP[j]);
            }
        }
        uint64 byB = uint64(block.timestamp + 10);
        vm.recordLogs();
        vm.startStateDiffRecording();
        bM.cfp(bP, CID, byB, payload);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        _assertReceived(_receivedContents(), n, payload, "cfp");
        for (uint256 i = 0; i < n; i++) {
            _assertDeliveredOnce(_handledContents(acc, bP[i]), payload, "cfp");
            assertEq(BladeCnParticipant(bP[i]).session(CID).phase, ContractNetLib.PART_CFPED);
            BladeCnParticipant(bP[i]).propose(_cfpInbound(CID, byB, ""), address(bM), payload);
        }
        vm.warp(uint256(byB) + 1);
        bM.evaluate(CID, bP, _empty(), _empty());
        for (uint256 i = 0; i < n; i++) {
            vm.recordLogs();
            vm.startStateDiffRecording();
            BladeCnParticipant(bP[i]).inform(_acceptInbound(CID), address(bM), payload);
            acc = vm.stopAndReturnStateDiff();
            _assertDeliveredOnce(_handledContents(acc, address(bM)), payload, "inform");
            _assertReceived(_receivedContents(), 1, payload, "inform");
            assertEq(BladeCnParticipant(bP[i]).session(CID).phase, ContractNetLib.PART_NONE);
        }
        assertEq(bM.conversation(CID).live, 0);
        assertEq(bM.conversation(CID).invited, 0);

        ManualManager mM = new ManualManager();
        address[] memory mP = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            mP[i] = address(new ManualCnParticipant());
            for (uint256 j = 0; j < i; j++) {
                assertTrue(mP[i] != mP[j]);
            }
        }
        uint64 byM = uint64(block.timestamp + 10);
        for (uint256 i = 0; i < n; i++) {
            vm.expectCall(mP[i], abi.encodeCall(ManualCnParticipant.onCfp, (CID, byM, payload)));
        }
        mM.cfp(mP, CID, byM, payload);
        for (uint256 i = 0; i < n; i++) {
            assertEq(ManualCnParticipant(mP[i]).session(CID).phase, CN_PART_CFPED);
            ManualCnParticipant(mP[i]).propose(CID, payload);
        }
        vm.warp(uint256(byM) + 1);
        mM.evaluate(CID, mP, _empty(), _empty());
        for (uint256 i = 0; i < n; i++) {
            vm.expectCall(address(mM), abi.encodeCall(mM.onInform, (CID, payload)));
            ManualCnParticipant(mP[i]).inform(CID, payload);
            assertEq(ManualCnParticipant(mP[i]).session(CID).phase, CN_PART_NONE);
            assertEq(mM.slotOf(CID, mP[i]), CN_SLOT_NONE);
        }
        assertEq(mM.conversation(CID).live, 0);
    }

    function test_cnA_N1_payload0() public {
        _scenarioA(1, _payload(0, 0xab));
    }

    function test_cnA_N2_payload0() public {
        _scenarioA(2, _payload(0, 0xab));
    }

    function test_cnA_N4_payload0() public {
        _scenarioA(4, _payload(0, 0xab));
    }

    /// @dev The original skips on resource exhaustion; the revision requires the N=8 cell to pass.
    function test_cnA_N8_payload0() public {
        _scenarioA(8, _payload(0, 0xab));
    }

    function test_cnA_N2_payload32() public {
        _scenarioA(2, _payload(32, 0xab));
    }

    function test_cnA_N2_payload256() public {
        _scenarioA(2, _payload(256, 0xab));
    }

    function test_cnA_N2_payload1024() public {
        _scenarioA(2, _payload(1024, 0xab));
    }

    function test_cnA_N1_payload256() public {
        _scenarioA(1, _payload(256, 0xab));
    }

    function test_cnA_N4_payload256() public {
        _scenarioA(4, _payload(256, 0xab));
    }
}
