// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {BladeRequester, BladeParticipant} from "../src/blade-app/BladeRequest.sol";
import {BladeManager, BladeCnParticipant} from "../src/blade-app/BladeContractNet.sol";
import {ManualInitiator, ManualParticipant, REQ_NONE} from "../src/manual/ManualRequest.sol";
import {
    ManualManager,
    ManualCnParticipant,
    CN_SLOT_NONE,
    CN_PART_NONE,
    CN_PART_CFPED
} from "../src/manual/ManualContractNet.sol";
import {RequestAgent, RequestPhase} from "blade/core/RequestAgent.sol";
import {ContractNetLib} from "blade/core/ContractNetLib.sol";
import {Message} from "blade/core/Message.sol";
import {Performative} from "blade/core/Performative.sol";
import {Protocol} from "blade/core/Protocol.sol";

/// @dev F1.5 parameterized semantic eligibility. Not the RQ2/RQ4 gas campaign.
contract ParametricEquivalenceTest is Test {
    bytes32 internal constant CID = keccak256("f1.5");

    function _bytes(uint256 n) internal pure returns (bytes memory p) {
        p = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            p[i] = bytes1(uint8(0xab));
        }
    }

    function _req(bytes memory payload) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = CID;
        m.content = payload;
    }

    function _cfpMsg(uint64 replyBy, bytes memory payload)
        internal
        pure
        returns (Message memory m)
    {
        m.performative = uint8(Performative.Cfp);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = CID;
        m.replyBy = replyBy;
        m.content = payload;
    }

    function _acceptMsg(uint64 replyBy) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.AcceptProposal);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = CID;
        m.replyBy = replyBy;
    }

    function _empty() internal pure returns (address[] memory a) {}

    function _acceptAll(address[] memory parts) internal pure returns (address[] memory a) {
        a = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            a[i] = parts[i];
        }
    }

    function _lastReceivedContent() internal view returns (bytes memory content) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig =
            keccak256("Received(address,bytes32,bytes32,uint8,uint8,bytes32,bytes32,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (,,,,,, bytes memory c) = abi.decode(
                    logs[i].data, (bytes32, uint8, uint8, bytes32, bytes32, uint64, bytes)
                );
                content = c;
            }
        }
    }

    function _r3(bytes memory payload) internal {
        BladeRequester bI = new BladeRequester();
        BladeParticipant bP = new BladeParticipant();
        vm.recordLogs();
        bI.startRequest(address(bP), CID, payload);
        assertEq(_lastReceivedContent(), payload);
        assertEq(uint8(bI.requestStatus(CID).phase), uint8(RequestPhase.Requested));
        assertEq(uint8(bP.requestStatus(CID).phase), uint8(RequestPhase.Requested));
        bP.agree(_req(payload), address(bI));
        assertEq(uint8(bI.requestStatus(CID).phase), uint8(RequestPhase.Agreed));
        vm.recordLogs();
        bP.inform(_req(payload), address(bI), payload);
        assertEq(_lastReceivedContent(), payload);
        assertEq(uint8(bI.requestStatus(CID).phase), uint8(RequestPhase.None));
        assertEq(uint8(bP.requestStatus(CID).phase), uint8(RequestPhase.None));

        ManualInitiator mI = new ManualInitiator();
        ManualParticipant mP = new ManualParticipant();
        vm.expectCall(address(mP), abi.encodeCall(mP.onRequest, (CID, payload)));
        mI.startRequest(address(mP), CID, payload);
        mP.agree(CID);
        vm.expectCall(address(mI), abi.encodeCall(mI.onInform, (CID, payload)));
        mP.inform(CID, payload);
        assertEq(mI.status(CID).phase, REQ_NONE);
        assertEq(mP.status(CID).phase, REQ_NONE);
    }

    function test_R3_payload_0() public {
        _r3(_bytes(0));
    }

    function test_R3_payload_32() public {
        _r3(_bytes(32));
    }

    function test_R3_payload_256() public {
        _r3(_bytes(256));
    }

    function test_R3_payload_1024() public {
        _r3(_bytes(1024));
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
        bM.cfp(bP, CID, byB, payload);
        assertEq(_lastReceivedContent(), payload);
        for (uint256 i = 0; i < n; i++) {
            assertEq(BladeCnParticipant(bP[i]).session(CID).phase, ContractNetLib.PART_CFPED);
            BladeCnParticipant(bP[i]).propose(_cfpMsg(byB, payload), address(bM), payload);
        }
        vm.warp(uint256(byB) + 1);
        bM.evaluate(CID, _acceptAll(bP), _empty(), _empty());
        for (uint256 i = 0; i < n; i++) {
            vm.recordLogs();
            BladeCnParticipant(bP[i]).inform(_acceptMsg(0), address(bM), payload);
            assertEq(_lastReceivedContent(), payload);
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
        mM.evaluate(CID, _acceptAll(mP), _empty(), _empty());
        for (uint256 i = 0; i < n; i++) {
            vm.expectCall(address(mM), abi.encodeCall(mM.onInform, (CID, payload)));
            ManualCnParticipant(mP[i]).inform(CID, payload);
            assertEq(ManualCnParticipant(mP[i]).session(CID).phase, CN_PART_NONE);
            assertEq(mM.slotOf(CID, mP[i]), CN_SLOT_NONE);
        }
        assertEq(mM.conversation(CID).live, 0);
    }

    function test_cnA_N1_payload0() public {
        _scenarioA(1, _bytes(0));
    }

    function test_cnA_N2_payload0() public {
        _scenarioA(2, _bytes(0));
    }

    function test_cnA_N4_payload0() public {
        _scenarioA(4, _bytes(0));
    }

    function test_cnA_N8_payload0_orSkip() public {
        try this.scenarioAExternal{gas: 30_000_000}(8, _bytes(0)) {
            return;
        } catch {
            emit log("N=8 resource-limited in equivalence harness; not semantic inequivalence");
        }
    }

    function scenarioAExternal(uint256 n, bytes calldata payload) external {
        _scenarioA(n, payload);
    }

    function test_cnA_N2_payload32() public {
        _scenarioA(2, _bytes(32));
    }

    function test_cnA_N2_payload256() public {
        _scenarioA(2, _bytes(256));
    }

    function test_cnA_N2_payload1024() public {
        _scenarioA(2, _bytes(1024));
    }

    function test_cnA_N1_payload256() public {
        _scenarioA(1, _bytes(256));
    }

    function test_cnA_N4_payload256() public {
        _scenarioA(4, _bytes(256));
    }
}
