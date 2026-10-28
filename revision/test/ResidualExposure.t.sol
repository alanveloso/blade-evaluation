// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RevisionBase} from "./RevisionBase.sol";
import {BladeRequester, BladeParticipant} from "app/blade-app/BladeRequest.sol";
import {ManualInitiator, ManualParticipant} from "app/manual/ManualRequest.sol";
import {RequestPhase} from "blade/core/RequestAgent.sol";

/// @dev Residual exposures reproduced on the measured application contracts (both implementations).
/// These are not fixed by the Request correlation change; they document what remains.
contract ResidualExposureTest is RevisionBase {
    bytes32 internal constant CID = keccak256("revision/residual");

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

    function _nonzeroWritten(address a) internal returns (uint256 n) {
        (, bytes32[] memory w) = vm.accesses(a);
        for (uint256 i = 0; i < w.length; i++) {
            bool dup;
            for (uint256 j = 0; j < i; j++) {
                if (w[j] == w[i]) {
                    dup = true;
                    break;
                }
            }
            if (!dup && vm.load(a, w[i]) != bytes32(0)) {
                n++;
            }
        }
    }

    /// Abandoned session: the participant never answers. The Request subset has no timeout or Cancel,
    /// so both sides keep the live session indefinitely, its storage is never reclaimed, and the
    /// initiator cannot reuse the conversationId. Same behaviour in the purpose-built baseline.
    function test_abandonedRequest_strandsStorageAndBlocksReuse() public {
        vm.record();
        bI.startRequest(address(bP), CID, "");
        uint256 strandedI = _nonzeroWritten(address(bI));
        uint256 strandedP = _nonzeroWritten(address(bP));
        vm.warp(block.timestamp + 365 days);
        assertEq(uint8(bI.requestStatus(CID).phase), uint8(RequestPhase.Requested));
        assertEq(uint8(bP.requestStatus(CID).phase), uint8(RequestPhase.Requested));
        vm.expectRevert();
        bI.startRequest(address(bP), CID, "");

        vm.record();
        mI.startRequest(address(mP), CID, "");
        uint256 mStrandedI = _nonzeroWritten(address(mI));
        uint256 mStrandedP = _nonzeroWritten(address(mP));
        vm.warp(block.timestamp + 365 days);
        assertEq(mI.status(CID).phase, 1);
        vm.expectRevert();
        mI.startRequest(address(mP), CID, "");

        assertGt(strandedI, 0);
        assertGt(mStrandedI, 0);
        vm.writeFile(
            "outputs/storage/revision_abandoned.json",
            string.concat(
                "{\"blade_initiator_slots\":", vm.toString(strandedI),
                ",\"blade_participant_slots\":", vm.toString(strandedP),
                ",\"manual_initiator_slots\":", vm.toString(mStrandedI),
                ",\"manual_participant_slots\":", vm.toString(mStrandedP),
                ",\"note\":\"blade initiator count includes the persistent nonce slot on E2\"}"
            )
        );
    }

    /// Early conversationId occupation: any contract that learns a pending id (for example from the
    /// mempool) can open it first at the participant; the honest Request then reverts. The
    /// correlation token does not help because the attacker opens a legitimate session.
    function test_conversationIdSquatting_blocksHonestRequest() public {
        BladeRequester squatter = new BladeRequester();
        squatter.startRequest(address(bP), CID, "");
        vm.expectRevert();
        bI.startRequest(address(bP), CID, "");
        assertEq(bP.requestStatus(CID).transportPeer, address(squatter));

        ManualInitiator mSquatter = new ManualInitiator();
        mSquatter.startRequest(address(mP), CID, "");
        vm.expectRevert();
        mI.startRequest(address(mP), CID, "");
        assertEq(mP.status(CID).peer, address(mSquatter));
    }

    /// The squatter's session is not a replay: it carries its own fresh token and later continuations
    /// are bound to it, so the honest initiator cannot interfere with it either.
    function test_squattedSessionIsIsolatedFromHonestInitiator() public {
        BladeRequester squatter = new BladeRequester();
        squatter.startRequest(address(bP), CID, "");
        bP.agree(_reqInbound(CID, _token(address(bP), CID), ""), address(squatter));
        assertEq(uint8(squatter.requestStatus(CID).phase), uint8(RequestPhase.Agreed));
        assertEq(uint8(bI.requestStatus(CID).phase), uint8(RequestPhase.None));
        bytes32 token = _token(address(bP), CID);
        vm.expectRevert();
        bP.inform(_reqInbound(CID, token, ""), address(bI), "");
    }

    /// The evaluated wrappers are built with trustedRelay = address(0): the relay path, and therefore
    /// the documented relay-replay limitation, is not reachable in the measured configuration.
    function test_relayDisabledInMeasuredWrappers() public view {
        assertEq(bI.trustedRelay(), address(0));
        assertEq(bP.trustedRelay(), address(0));
    }
}
