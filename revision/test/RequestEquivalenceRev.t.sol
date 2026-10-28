// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RevisionBase} from "./RevisionBase.sol";
import {BladeRequester, BladeParticipant} from "app/blade-app/BladeRequest.sol";
import {
    ManualInitiator,
    ManualParticipant,
    REQ_NONE,
    REQ_REQUESTED,
    REQ_AGREED,
    REQ_ROLE_INITIATOR,
    REQ_ROLE_PARTICIPANT
} from "app/manual/ManualRequest.sol";
import {RequestAgent, RequestPhase, RequestRole} from "blade/core/RequestAgent.sol";
import {Message} from "blade/core/Message.sol";

/// @dev Revision of comparison/test/RequestEquivalence.t.sol (kept unchanged for E0/E1). BLADE
/// continuations carry the session token (zero on E1) and no redundant inbound payload, exactly as the
/// revision runner encodes them. Runs against E1 and E2.
contract RequestEquivalenceRevTest is RevisionBase {
    bytes32 internal constant CID = keccak256("f1-r");
    bytes internal constant PAYLOAD = hex"";

    BladeRequester internal bI;
    BladeParticipant internal bP;
    ManualInitiator internal mI;
    ManualParticipant internal mP;

    function setUp() public {
        bI = new BladeRequester();
        bP = new BladeParticipant();
        mI = new ManualInitiator();
        mP = new ManualParticipant();
    }

    function _req() internal view returns (Message memory) {
        return _reqInbound(CID, _token(address(bP), CID), "");
    }

    function _phase(RequestAgent a) internal view returns (uint8) {
        return uint8(a.requestStatus(CID).phase);
    }

    function _bladeCleared() internal view {
        assertEq(_phase(bI), uint8(RequestPhase.None));
        assertEq(_phase(bP), uint8(RequestPhase.None));
        assertEq(bI.requestStatus(CID).transportPeer, address(0));
        assertEq(bP.requestStatus(CID).transportPeer, address(0));
    }

    function _manualCleared() internal view {
        assertEq(mI.status(CID).phase, REQ_NONE);
        assertEq(mP.status(CID).phase, REQ_NONE);
        assertEq(mI.status(CID).peer, address(0));
        assertEq(mP.status(CID).peer, address(0));
    }

    function test_R1_requestRefuse() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        assertEq(_phase(bI), uint8(RequestPhase.Requested));
        assertEq(_phase(bP), uint8(RequestPhase.Requested));
        bP.refuse(_req(), address(bI), PAYLOAD);
        _bladeCleared();

        mI.startRequest(address(mP), CID, PAYLOAD);
        assertEq(mI.status(CID).phase, REQ_REQUESTED);
        assertEq(mP.status(CID).phase, REQ_REQUESTED);
        mP.refuse(CID, PAYLOAD);
        _manualCleared();
    }

    function test_R2_requestInform() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.inform(_req(), address(bI), PAYLOAD);
        _bladeCleared();

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.inform(CID, PAYLOAD);
        _manualCleared();
    }

    function test_R3_requestAgreeInform() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.agree(_req(), address(bI));
        assertEq(_phase(bI), uint8(RequestPhase.Agreed));
        assertEq(_phase(bP), uint8(RequestPhase.Agreed));
        assertEq(uint8(bI.requestStatus(CID).role), uint8(RequestRole.Initiator));
        assertEq(uint8(bP.requestStatus(CID).role), uint8(RequestRole.Participant));
        bP.inform(_req(), address(bI), PAYLOAD);
        _bladeCleared();

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.agree(CID);
        assertEq(mI.status(CID).phase, REQ_AGREED);
        assertEq(mP.status(CID).phase, REQ_AGREED);
        assertEq(mI.status(CID).role, REQ_ROLE_INITIATOR);
        assertEq(mP.status(CID).role, REQ_ROLE_PARTICIPANT);
        mP.inform(CID, PAYLOAD);
        _manualCleared();
    }

    function test_R4_requestAgreeFailure() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.agree(_req(), address(bI));
        bP.failure(_req(), address(bI), PAYLOAD);
        _bladeCleared();

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.agree(CID);
        mP.failure(CID, PAYLOAD);
        _manualCleared();
    }

    function test_invalid_refuseAfterAgree() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bP.agree(_req(), address(bI));
        Message memory m = _req();
        vm.expectRevert();
        bP.refuse(m, address(bI), PAYLOAD);

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.agree(CID);
        vm.expectRevert();
        mP.refuse(CID, PAYLOAD);
    }

    function test_invalid_continuationAfterCleanup() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        Message memory m = _req();
        bP.refuse(m, address(bI), PAYLOAD);
        vm.expectRevert();
        bP.inform(m, address(bI), PAYLOAD);

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
        _bladeCleared();

        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.refuse(CID, PAYLOAD);
        mI.startRequest(address(mP), CID, PAYLOAD);
        mP.inform(CID, PAYLOAD);
        _manualCleared();
    }

    /// @dev An inbound reconstructed from a previous instance of a reused conversationId. On E1 the
    /// BLADE wrapper accepts it (no token exists); on E2 the Core rejects it. The purpose-built API
    /// has no application-supplied inbound message, so the same mistake cannot be expressed there.
    function test_staleInboundAfterReuse() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        Message memory first = _req();
        bP.refuse(first, address(bI), PAYLOAD);
        bI.startRequest(address(bP), CID, PAYLOAD);
        if (_coreAssignsTokens(address(bP), CID)) {
            assertTrue(_req().replyWith != first.replyWith, "token reused");
            vm.expectRevert();
            bP.agree(first, address(bI));
            bP.agree(_req(), address(bI));
        } else {
            bP.agree(first, address(bI));
        }
        assertEq(_phase(bI), uint8(RequestPhase.Agreed));
    }

    function test_tokenOnlyWhenCoreAssigns() public {
        bI.startRequest(address(bP), CID, PAYLOAD);
        bytes32 tP = _token(address(bP), CID);
        bytes32 tI = _token(address(bI), CID);
        assertEq(tI, tP, "both sides keep the same token");
        assertEq(tP != bytes32(0), _coreAssignsTokens(address(bP), CID));
    }
}
