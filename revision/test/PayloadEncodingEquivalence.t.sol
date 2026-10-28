// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RevisionBase} from "./RevisionBase.sol";
import {BladeRequester, BladeParticipant} from "app/blade-app/BladeRequest.sol";
import {BladeManager, BladeCnParticipant} from "app/blade-app/BladeContractNet.sol";
import {Message} from "blade/core/Message.sol";

/// @dev The submitted harness passed the opening payload again inside the reconstructed `inbound`
/// message of every BLADE continuation. These tests show that the wrapper and the Core never read
/// `inbound.content`: from the same pre-state, the legacy encoding (payload), the minimal encoding
/// (empty) and an arbitrary unrelated content produce identical storage, identical logs (emitter,
/// topics, data) and identical success. Removing the copies therefore preserves semantics.
contract PayloadEncodingEquivalenceTest is RevisionBase {
    bytes32 internal constant CID = keccak256("revision/payload-encoding");
    uint256 internal constant N = 1024;

    BladeRequester internal bI;
    BladeParticipant internal bP;
    BladeManager internal bM;
    BladeCnParticipant internal c0;
    BladeCnParticipant internal c1;

    function setUp() public {
        bI = new BladeRequester();
        bP = new BladeParticipant();
        bM = new BladeManager();
        c0 = new BladeCnParticipant();
        c1 = new BladeCnParticipant();
    }

    function _contents() internal pure returns (bytes[3] memory c) {
        c[0] = _payload(N, 0xab); // legacy: opening payload copied into inbound
        c[1] = ""; // minimal
        c[2] = _payload(77, 0x5a); // unrelated bytes
    }

    // ------------------------------------------------------------------------------- Request

    /// path: 1 refuse, 2 inform, 3 agree+inform, 4 agree+failure
    function _request(uint8 path, bytes memory inboundContent) internal returns (bytes32) {
        bytes memory p = _payload(N, 0xab);
        bI.startRequest(address(bP), CID, p);
        Message memory inbound = _reqInbound(CID, _token(address(bP), CID), inboundContent);
        vm.recordLogs();
        if (path == 1) {
            bP.refuse(inbound, address(bI), p);
        } else if (path == 2) {
            bP.inform(inbound, address(bI), p);
        } else {
            bP.agree(inbound, address(bI));
            bytes memory mid = abi.encode(_statusRaw(address(bI), CID), _statusRaw(address(bP), CID));
            if (path == 3) {
                bP.inform(inbound, address(bI), p);
            } else {
                bP.failure(inbound, address(bI), p);
            }
            return keccak256(abi.encode(_logsDigest(), mid, _statusRaw(address(bI), CID), _statusRaw(address(bP), CID)));
        }
        return keccak256(abi.encode(_logsDigest(), _statusRaw(address(bI), CID), _statusRaw(address(bP), CID)));
    }

    function _assertRequestPath(uint8 path) internal {
        bytes[3] memory c = _contents();
        uint256 snap = vm.snapshotState();
        bytes32 d0 = _request(path, c[0]);
        vm.revertToState(snap);
        bytes32 d1 = _request(path, c[1]);
        vm.revertToState(snap);
        bytes32 d2 = _request(path, c[2]);
        assertEq(d1, d0, "minimal inbound changed behavior");
        assertEq(d2, d0, "inbound content is read");
    }

    function test_R1_refuse_inboundContentUnused() public {
        _assertRequestPath(1);
    }

    function test_R2_inform_inboundContentUnused() public {
        _assertRequestPath(2);
    }

    function test_R3_agreeInform_inboundContentUnused() public {
        _assertRequestPath(3);
    }

    function test_R4_agreeFailure_inboundContentUnused() public {
        _assertRequestPath(4);
    }

    /// @dev The active-K workload reuses the R3 agree continuation for every conversation.
    function test_activeK_agree_inboundContentUnused() public {
        bytes[3] memory c = _contents();
        uint256 snap = vm.snapshotState();
        bytes32[3] memory d;
        for (uint256 v = 0; v < 3; v++) {
            if (v > 0) {
                vm.revertToState(snap);
            }
            vm.recordLogs();
            for (uint256 i = 0; i < 5; i++) {
                bytes32 id = keccak256(abi.encode("k", i));
                bI.startRequest(address(bP), id, "");
                bP.agree(_reqInbound(id, _token(address(bP), id), c[v]), address(bI));
            }
            d[v] = _logsDigest();
        }
        assertEq(d[1], d[0]);
        assertEq(d[2], d[0]);
    }

    // ------------------------------------------------------------------------- Contract Net

    /// scenario: 0 = A (both propose, both accepted), 1 = B (c0 proposes, c1 refuses)
    function _cn(uint8 scenario, bytes memory inboundContent) internal returns (bytes32) {
        bytes memory p = _payload(N, 0xab);
        address[] memory parts = new address[](2);
        parts[0] = address(c0);
        parts[1] = address(c1);
        uint64 by = uint64(block.timestamp + 10);
        bM.cfp(parts, CID, by, p);
        Message memory cfp = _cfpInbound(CID, by, inboundContent);
        vm.recordLogs();
        c0.propose(cfp, address(bM), p);
        address[] memory acc;
        if (scenario == 0) {
            c1.propose(cfp, address(bM), p);
            acc = parts;
        } else {
            c1.refuse(cfp, address(bM));
            acc = new address[](1);
            acc[0] = address(c0);
        }
        vm.warp(uint256(by) + 1);
        address[] memory none = new address[](0);
        bM.evaluate(CID, acc, none, none);
        for (uint256 i = 0; i < acc.length; i++) {
            BladeCnParticipant(acc[i]).inform(_acceptInbound(CID), address(bM), p);
        }
        return keccak256(
            abi.encode(
                _logsDigest(),
                bM.conversation(CID),
                bM.slotOf(CID, address(c0)),
                bM.slotOf(CID, address(c1)),
                c0.session(CID),
                c1.session(CID)
            )
        );
    }

    function _assertCn(uint8 scenario) internal {
        bytes[3] memory c = _contents();
        uint256 snap = vm.snapshotState();
        bytes32 d0 = _cn(scenario, c[0]);
        vm.revertToState(snap);
        bytes32 d1 = _cn(scenario, c[1]);
        vm.revertToState(snap);
        bytes32 d2 = _cn(scenario, c[2]);
        assertEq(d1, d0, "minimal inbound changed behavior");
        assertEq(d2, d0, "inbound content is read");
    }

    function test_cnA_propose_inboundContentUnused() public {
        _assertCn(0);
    }

    function test_cnB_proposeRefuse_inboundContentUnused() public {
        _assertCn(1);
    }

    /// @dev Guards the guard: a field that IS read (conversationId) must change the outcome, so the
    /// digests above are sensitive enough to detect a read of `inbound`.
    function test_digestDetectsReadField() public {
        bytes memory p = _payload(N, 0xab);
        bI.startRequest(address(bP), CID, p);
        Message memory inbound = _reqInbound(CID, _token(address(bP), CID), "");
        inbound.conversationId = keccak256("other");
        vm.expectRevert();
        bP.agree(inbound, address(bI));
    }
}
