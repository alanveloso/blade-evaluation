// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    ManualInitiator,
    ManualParticipant,
    REQ_NONE,
    REQ_AGREED,
    ReqTokenMismatch,
    ReqMissingToken
} from "app/manual/ManualRequest.sol";

/// @dev Guarantees of the correlated purpose-built Request variant (revision/src/manual-variants/
/// correlated). Mirrors the BLADE E2 correlation tests: token assigned by the initiator, stored on both
/// sides, single-use across conversationId reuse, required on every act after the opening request.
contract ManualCorrelatedTest is Test {
    bytes32 internal constant CID = keccak256("revision/manual-correlated");

    ManualInitiator internal mI;
    ManualParticipant internal mP;

    function setUp() public {
        mI = new ManualInitiator();
        mP = new ManualParticipant();
    }

    function test_tokenAssignedAndSharedByBothSides() public {
        mI.startRequest(address(mP), CID, "");
        bytes32 t = mI.status(CID).token;
        assertTrue(t != bytes32(0));
        assertEq(mP.status(CID).token, t);
    }

    function test_wrongTokenRejectedAtInitiator() public {
        mI.startRequest(address(mP), CID, "");
        vm.prank(address(mP));
        vm.expectRevert(ReqTokenMismatch.selector);
        mI.onAgree(CID, keccak256("forged"));
    }

    function test_staleTokenRejectedAfterReuse() public {
        mI.startRequest(address(mP), CID, "");
        bytes32 first = mI.status(CID).token;
        mP.refuse(CID, "");
        mI.startRequest(address(mP), CID, "");
        bytes32 second = mI.status(CID).token;
        assertTrue(second != first, "token reused");
        vm.prank(address(mP));
        vm.expectRevert(ReqTokenMismatch.selector);
        mI.onAgree(CID, first);
        mP.agree(CID);
        assertEq(mI.status(CID).phase, REQ_AGREED);
    }

    function test_missingTokenRejectedAtParticipant() public {
        vm.prank(address(mI));
        vm.expectRevert(ReqMissingToken.selector);
        mP.onRequest(CID, bytes32(0), "");
    }

    function test_happyPathsClearSessionStorage() public {
        mI.startRequest(address(mP), CID, hex"abab");
        mP.agree(CID);
        mP.inform(CID, hex"abab");
        assertEq(mI.status(CID).phase, REQ_NONE);
        assertEq(mP.status(CID).phase, REQ_NONE);
        assertEq(mI.status(CID).token, bytes32(0));
        assertEq(mP.status(CID).token, bytes32(0));

        mI.startRequest(address(mP), CID, "");
        mP.agree(CID);
        mP.failure(CID, "");
        mI.startRequest(address(mP), CID, "");
        mP.inform(CID, "");
        assertEq(mI.status(CID).phase, REQ_NONE);
    }
}
