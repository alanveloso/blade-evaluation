// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BladeRequester, BladeParticipant} from "../src/blade-app/BladeRequest.sol";
import {
    ManualInitiator,
    ManualParticipant,
    REQ_NONE,
    REQ_REQUESTED,
    REQ_AGREED,
    REQ_ROLE_INITIATOR,
    REQ_ROLE_PARTICIPANT
} from "../src/manual/ManualRequest.sol";
import {RequestAgent, RequestPhase, RequestRole} from "blade/core/RequestAgent.sol";
import {Message} from "blade/core/Message.sol";
import {Performative} from "blade/core/Performative.sol";
import {Protocol} from "blade/core/Protocol.sol";
import {IAgent} from "blade/core/IAgent.sol";

contract RequestEquivalenceTest is Test {
    bytes internal constant PAYLOAD = hex"";
    bytes32 internal constant CID = keccak256("f1-r");

    BladeRequester internal bI;
    BladeParticipant internal bP;
    ManualInitiator internal mI;
    ManualParticipant internal mP;

    function _req() internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = CID;
        m.content = PAYLOAD;
    }

    function setUp() public {
        bI = new BladeRequester();
        bP = new BladeParticipant();
        mI = new ManualInitiator();
        mP = new ManualParticipant();
    }

    function _bladeCleared(RequestAgent a) internal view {
        RequestAgent.Status memory s = a.requestStatus(CID);
        assertEq(uint8(s.phase), uint8(RequestPhase.None));
        assertEq(s.transportPeer, address(0));
    }

    function _manualClearedI() internal view {
        assertEq(mI.status(CID).phase, REQ_NONE);
        assertEq(mI.status(CID).peer, address(0));
    }

    function _manualClearedP() internal view {
        assertEq(mP.status(CID).phase, REQ_NONE);
        assertEq(mP.status(CID).peer, address(0));
    }

    function test_R1_requestRefuse() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        assertEq(uint8(bI.requestStatus(CID).phase), uint8(RequestPhase.Requested));
        assertEq(uint8(bP.requestStatus(CID).phase), uint8(RequestPhase.Requested));
        bP.refuse(_req(), address(bI), PAYLOAD);
        _bladeCleared(bI);
        _bladeCleared(bP);

        mI.startRequest(address(mP), CID, PAYLOAD);
        assertEq(mI.status(CID).phase, REQ_REQUESTED);
        assertEq(mP.status(CID).phase, REQ_REQUESTED);
        mP.refuse(CID, PAYLOAD);
        _manualClearedI();
        _manualClearedP();
    }

    function test_R2_requestInform() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.inform(_req(), address(bI), PAYLOAD);
        _bladeCleared(bI);
        _bladeCleared(bP);

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.inform(CID, PAYLOAD);
        _manualClearedI();
        _manualClearedP();
    }

    function test_R3_requestAgreeInform() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.agree(_req(), address(bI));
        assertEq(uint8(bI.requestStatus(CID).phase), uint8(RequestPhase.Agreed));
        assertEq(uint8(bP.requestStatus(CID).phase), uint8(RequestPhase.Agreed));
        assertEq(uint8(bI.requestStatus(CID).role), uint8(RequestRole.Initiator));
        assertEq(uint8(bP.requestStatus(CID).role), uint8(RequestRole.Participant));
        bP.inform(_req(), address(bI), PAYLOAD);
        _bladeCleared(bI);
        _bladeCleared(bP);

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.agree(CID);
        assertEq(mI.status(CID).phase, REQ_AGREED);
        assertEq(mP.status(CID).phase, REQ_AGREED);
        assertEq(mI.status(CID).role, REQ_ROLE_INITIATOR);
        assertEq(mP.status(CID).role, REQ_ROLE_PARTICIPANT);
        mP.inform(CID, PAYLOAD);
        _manualClearedI();
        _manualClearedP();
    }

    function test_R4_requestAgreeFailure() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.agree(_req(), address(bI));
        bP.failure(_req(), address(bI), PAYLOAD);
        _bladeCleared(bI);
        _bladeCleared(bP);

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.agree(CID);
        mP.failure(CID, PAYLOAD);
        _manualClearedI();
        _manualClearedP();
    }

    function test_invalid_zeroConversationId() public {
        vm.expectRevert();
        bI.startRequest(address(bP), bytes32(0), PAYLOAD);
        vm.expectRevert();
        mI.startRequest(address(mP), bytes32(0), PAYLOAD);
    }

    function test_invalid_duplicateLiveRequest() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        vm.expectRevert();
        bI.startRequest(address(bP), CID, PAYLOAD);

        mI.startRequest(address(mP), CID, PAYLOAD);
        vm.expectRevert();
        mI.startRequest(address(mP), CID, PAYLOAD);
    }

    function test_invalid_refuseAfterAgree() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.agree(_req(), address(bI));
        vm.expectRevert();
        bP.refuse(_req(), address(bI), PAYLOAD);

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.agree(CID);
        vm.expectRevert();
        mP.refuse(CID, PAYLOAD);
    }

    function test_invalid_continuationAfterCleanup() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.refuse(_req(), address(bI), PAYLOAD);
        vm.expectRevert();
        bP.inform(_req(), address(bI), PAYLOAD);

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.refuse(CID, PAYLOAD);
        vm.expectRevert();
        mP.inform(CID, PAYLOAD);
    }

    function test_reuseAfterCleanup() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.refuse(_req(), address(bI), PAYLOAD);
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.inform(_req(), address(bI), PAYLOAD);
        _bladeCleared(bI);

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.refuse(CID, PAYLOAD);
        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.inform(CID, PAYLOAD);
        _manualClearedI();
    }

    function test_invalid_wrongPeer() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        Message memory refuse;
        refuse.performative = uint8(Performative.Refuse);
        refuse.protocol = uint8(Protocol.FipaRequest);
        refuse.conversationId = CID;
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        IAgent(address(bI)).handle(refuse);

        mI.startRequest(address(mP), CID, PAYLOAD);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        mI.onRefuse(CID, PAYLOAD);
    }
}
