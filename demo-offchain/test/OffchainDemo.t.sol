// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DemoRequester} from "../src/DemoRequester.sol";
import {DemoParticipant} from "../src/DemoParticipant.sol";
import {RequestAgent, RequestPhase, RequestRole} from "blade/core/RequestAgent.sol";
import {Agent} from "blade/core/Agent.sol";
import {Message} from "blade/core/Message.sol";
import {Performative} from "blade/core/Performative.sol";
import {Protocol} from "blade/core/Protocol.sol";

/// @dev Foundry stand-in for two independent off-chain operators. Each `vm.prank` is a separate
///      transaction; `vm.roll` makes the block gap explicit.
contract OffchainDemoTest is Test {
    DemoRequester internal requester;
    DemoParticipant internal participant;

    address internal requesterOp = address(0xA11CE);
    address internal participantOp = address(0xB0B);
    address internal stranger = address(0xBAD);

    bytes32 internal constant ID_A = keccak256("demo-offchain-A");
    bytes32 internal constant ID_B = keccak256("demo-offchain-B");
    bytes32 internal constant ID_C = keccak256("demo-offchain-C");

    bytes internal constant PAYLOAD_ACCEPT = hex"01";
    bytes internal constant PAYLOAD_REFUSE = hex"00";
    bytes internal constant PAYLOAD_WRONG = hex"03";
    bytes internal constant RESULT_DONE = hex"c0ffee";
    bytes internal constant REASON_BUSY = hex"b1";

    function setUp() public {
        requester = new DemoRequester(requesterOp);
        participant = new DemoParticipant(participantOp);
    }

    function test_requestDoesNotAutoReply() public {
        vm.prank(requesterOp);
        requester.request(address(participant), ID_A, PAYLOAD_ACCEPT);

        _assertRequested(ID_A);
        assertTrue(participant.pending(ID_A).present);
        assertFalse(requester.outcomes(ID_A).present);
        assertEq(participant.pending(ID_A).receivedBlock, uint64(block.number));
    }

    function test_caseA_informInLaterTransaction() public {
        uint256 requestBlock = block.number;
        vm.prank(requesterOp);
        requester.request(address(participant), ID_A, PAYLOAD_ACCEPT);

        _assertRequested(ID_A);
        bytes32 token = requester.requestStatus(ID_A).replyWith;
        assertEq(participant.requestStatus(ID_A).replyWith, token);
        assertEq(participant.pending(ID_A).requester, address(requester));
        assertEq(participant.pending(ID_A).content, PAYLOAD_ACCEPT);

        vm.roll(block.number + 1);
        vm.prank(participantOp);
        participant.respond(ID_A, uint8(Performative.Inform), token, RESULT_DONE);

        _assertCleared(ID_A);
        DemoRequester.Outcome memory out = requester.outcomes(ID_A);
        assertTrue(out.present);
        assertEq(out.performative, uint8(Performative.Inform));
        assertEq(out.correlation, token);
        assertEq(out.content, RESULT_DONE);
        assertGt(uint256(out.blockNumber), requestBlock);
        assertFalse(participant.pending(ID_A).present);
    }

    function test_caseB_refuseInLaterTransaction() public {
        vm.prank(requesterOp);
        requester.request(address(participant), ID_B, PAYLOAD_REFUSE);
        bytes32 token = requester.requestStatus(ID_B).replyWith;
        _assertRequested(ID_B);

        vm.roll(block.number + 1);
        vm.prank(participantOp);
        participant.respond(ID_B, uint8(Performative.Refuse), token, REASON_BUSY);

        _assertCleared(ID_B);
        DemoRequester.Outcome memory out = requester.outcomes(ID_B);
        assertTrue(out.present);
        assertEq(out.performative, uint8(Performative.Refuse));
        assertEq(out.correlation, token);
        assertEq(out.content, REASON_BUSY);
    }

    function test_caseC_unauthorizedSenderLeavesState() public {
        vm.prank(requesterOp);
        requester.request(address(participant), ID_C, PAYLOAD_WRONG);
        bytes32 before = _statusHash(requester, ID_C);
        bytes32 token = requester.requestStatus(ID_C).replyWith;

        Message memory forged = _inform(ID_C, token);
        vm.prank(stranger);
        vm.expectRevert(RequestAgent.UnexpectedPeer.selector);
        requester.handle(forged);

        assertEq(_statusHash(requester, ID_C), before);
        _assertRequested(ID_C);
        assertTrue(participant.pending(ID_C).present);
        assertFalse(requester.outcomes(ID_C).present);
    }

    function test_caseC_wrongTokenLeavesState() public {
        vm.prank(requesterOp);
        requester.request(address(participant), ID_C, PAYLOAD_WRONG);
        bytes32 beforeR = _statusHash(requester, ID_C);
        bytes32 beforeP = _statusHash(participant, ID_C);
        bytes32 wrong = keccak256("wrong-token");

        vm.prank(participantOp);
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        participant.respond(ID_C, uint8(Performative.Inform), wrong, RESULT_DONE);

        assertEq(_statusHash(requester, ID_C), beforeR);
        assertEq(_statusHash(participant, ID_C), beforeP);
        _assertRequested(ID_C);
        assertTrue(participant.pending(ID_C).present);
        assertFalse(requester.outcomes(ID_C).present);
    }

    function test_caseC_staleTokenAfterConversationIdReuse() public {
        vm.prank(requesterOp);
        requester.request(address(participant), ID_A, PAYLOAD_ACCEPT);
        bytes32 token1 = requester.requestStatus(ID_A).replyWith;
        vm.prank(participantOp);
        participant.respond(ID_A, uint8(Performative.Inform), token1, RESULT_DONE);
        _assertCleared(ID_A);

        vm.prank(requesterOp);
        requester.request(address(participant), ID_A, PAYLOAD_ACCEPT);
        bytes32 token2 = requester.requestStatus(ID_A).replyWith;
        assertTrue(token1 != token2);
        assertFalse(requester.outcomes(ID_A).present);
        bytes32 beforeR = _statusHash(requester, ID_A);
        bytes32 beforeP = _statusHash(participant, ID_A);

        vm.prank(participantOp);
        vm.expectRevert(Agent.ReplyWithMismatch.selector);
        participant.respond(ID_A, uint8(Performative.Inform), token1, RESULT_DONE);

        assertEq(_statusHash(requester, ID_A), beforeR);
        assertEq(_statusHash(participant, ID_A), beforeP);
        assertEq(requester.requestStatus(ID_A).replyWith, token2);
        _assertRequested(ID_A);

        vm.prank(participantOp);
        participant.respond(ID_A, uint8(Performative.Inform), token2, RESULT_DONE);
        _assertCleared(ID_A);
        assertEq(requester.outcomes(ID_A).correlation, token2);
    }

    function test_applicationFunctionsAreOperatorGated() public {
        vm.prank(stranger);
        vm.expectRevert(DemoRequester.NotOperator.selector);
        requester.request(address(participant), ID_A, PAYLOAD_ACCEPT);

        vm.prank(requesterOp);
        requester.request(address(participant), ID_A, PAYLOAD_ACCEPT);
        bytes32 token = requester.requestStatus(ID_A).replyWith;

        vm.prank(stranger);
        vm.expectRevert(DemoParticipant.NotOperator.selector);
        participant.respond(ID_A, uint8(Performative.Inform), token, RESULT_DONE);

        vm.prank(requesterOp);
        vm.expectRevert(DemoParticipant.NotOperator.selector);
        participant.respond(ID_A, uint8(Performative.Inform), token, RESULT_DONE);

        _assertRequested(ID_A);
    }

    function test_identitiesRolesAndEvents() public {
        vm.recordLogs();
        vm.prank(requesterOp);
        requester.request(address(participant), ID_A, PAYLOAD_ACCEPT);

        RequestAgent.Status memory sI = requester.requestStatus(ID_A);
        RequestAgent.Status memory sP = participant.requestStatus(ID_A);
        assertEq(uint8(sI.role), uint8(RequestRole.Initiator));
        assertEq(uint8(sP.role), uint8(RequestRole.Participant));
        assertEq(sI.transportPeer, address(participant));
        assertEq(sP.transportPeer, address(requester));
        assertEq(sI.logicalPeer, bytes32(0));
        assertEq(sP.logicalPeer, bytes32(0));
        assertTrue(sI.replyWith != bytes32(0));
        assertEq(sI.replyWith, sP.replyWith);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_sawAdvanced(logs, address(requester), ID_A, uint8(RequestPhase.Requested)));
        assertTrue(_sawAdvanced(logs, address(participant), ID_A, uint8(RequestPhase.Requested)));
        assertTrue(_sawReceived(logs, address(participant), address(requester), ID_A));

        bytes32 token = sI.replyWith;
        vm.recordLogs();
        vm.prank(participantOp);
        participant.respond(ID_A, uint8(Performative.Inform), token, RESULT_DONE);

        logs = vm.getRecordedLogs();
        assertTrue(_sawAdvanced(logs, address(participant), ID_A, uint8(RequestPhase.Terminal)));
        assertTrue(_sawAdvanced(logs, address(requester), ID_A, uint8(RequestPhase.Terminal)));
        assertTrue(_sawReceived(logs, address(requester), address(participant), ID_A));
    }

    function _assertRequested(bytes32 id) internal view {
        RequestAgent.Status memory sI = requester.requestStatus(id);
        RequestAgent.Status memory sP = participant.requestStatus(id);
        assertEq(uint8(sI.phase), uint8(RequestPhase.Requested));
        assertEq(uint8(sP.phase), uint8(RequestPhase.Requested));
        assertEq(uint8(sI.role), uint8(RequestRole.Initiator));
        assertEq(uint8(sP.role), uint8(RequestRole.Participant));
    }

    function _assertCleared(bytes32 id) internal view {
        RequestAgent.Status memory sI = requester.requestStatus(id);
        RequestAgent.Status memory sP = participant.requestStatus(id);
        assertEq(uint8(sI.phase), uint8(RequestPhase.None));
        assertEq(uint8(sP.phase), uint8(RequestPhase.None));
        assertEq(sI.transportPeer, address(0));
        assertEq(sP.transportPeer, address(0));
        assertEq(sI.replyWith, bytes32(0));
        assertEq(sP.replyWith, bytes32(0));
        assertEq(uint8(sI.role), uint8(RequestRole.None));
        assertEq(uint8(sP.role), uint8(RequestRole.None));
    }

    function _statusHash(RequestAgent agent, bytes32 id) internal view returns (bytes32) {
        return keccak256(abi.encode(agent.requestStatus(id)));
    }

    function _inform(bytes32 id, bytes32 token) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Inform);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = id;
        m.inReplyTo = token;
    }

    function _sawAdvanced(Vm.Log[] memory logs, address emitter, bytes32 id, uint8 phase)
        internal
        pure
        returns (bool)
    {
        bytes32 topic0 = keccak256("RequestAdvanced(bytes32,uint8,uint8)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter || logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != topic0) continue;
            if (logs[i].topics[1] != id) continue;
            (uint8 loggedPhase,) = abi.decode(logs[i].data, (uint8, uint8));
            if (loggedPhase == phase) return true;
        }
        return false;
    }

    function _sawReceived(Vm.Log[] memory logs, address emitter, address caller, bytes32 id)
        internal
        pure
        returns (bool)
    {
        bytes32 topic0 =
            keccak256("Received(address,bytes32,bytes32,uint8,uint8,bytes32,bytes32,uint64,bytes)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter || logs[i].topics.length < 3) continue;
            if (logs[i].topics[0] != topic0) continue;
            if (logs[i].topics[1] != bytes32(uint256(uint160(caller)))) continue;
            if (logs[i].topics[2] != id) continue;
            return true;
        }
        return false;
    }
}
