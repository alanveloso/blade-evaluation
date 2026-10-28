// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {RevisionBase} from "../RevisionBase.sol";
import {BladeRequester, BladeParticipant} from "app/blade-app/BladeRequest.sol";
import {BladeManager, BladeCnParticipant} from "app/blade-app/BladeContractNet.sol";
import {ManualInitiator, ManualParticipant} from "app/manual/ManualRequest.sol";
import {ManualManager, ManualCnParticipant} from "app/manual/ManualContractNet.sol";

/// @dev The observable purpose-built variant must emit, per protocol role, the same multiset of log
/// shapes as BLADE: (event signature, topic count, data length). Values may differ only in fields the
/// purpose-built design does not have (logical sender, replyWith, inReplyTo), which it emits as zero.
contract ManualObservableTest is RevisionBase {
    bytes32 internal constant CID = keccak256("revision/observable");

    function _shapes(Vm.Log[] memory logs, address emitter) internal pure returns (bytes32[] memory s) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter) {
                n++;
            }
        }
        s = new bytes32[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter) {
                s[n++] = keccak256(abi.encode(logs[i].topics[0], logs[i].topics.length, logs[i].data.length));
            }
        }
        for (uint256 i = 1; i < s.length; i++) {
            bytes32 x = s[i];
            uint256 j = i;
            while (j > 0 && s[j - 1] > x) {
                s[j] = s[j - 1];
                j--;
            }
            s[j] = x;
        }
    }

    function _assertSameShapes(Vm.Log[] memory a, address ea, Vm.Log[] memory b, address eb, string memory role)
        internal
        pure
    {
        bytes32[] memory sa = _shapes(a, ea);
        bytes32[] memory sb = _shapes(b, eb);
        assertEq(sa.length, sb.length, string.concat(role, ": log count"));
        for (uint256 i = 0; i < sa.length; i++) {
            assertEq(sa[i], sb[i], string.concat(role, ": log shape"));
        }
    }

    function _requestR3(uint256 n) internal {
        bytes memory p = _payload(n, 0xab);
        BladeRequester bI = new BladeRequester();
        BladeParticipant bP = new BladeParticipant();
        vm.recordLogs();
        bI.startRequest(address(bP), CID, p);
        bP.agree(_reqInbound(CID, _token(address(bP), CID), ""), address(bI));
        bP.inform(_reqInbound(CID, _token(address(bP), CID), ""), address(bI), p);
        Vm.Log[] memory lb = vm.getRecordedLogs();

        ManualInitiator mI = new ManualInitiator();
        ManualParticipant mP = new ManualParticipant();
        vm.recordLogs();
        mI.startRequest(address(mP), CID, p);
        mP.agree(CID);
        mP.inform(CID, p);
        Vm.Log[] memory lm = vm.getRecordedLogs();

        _assertSameShapes(lb, address(bI), lm, address(mI), "initiator");
        _assertSameShapes(lb, address(bP), lm, address(mP), "participant");
    }

    function test_requestR3_sameLogShapes_P0() public {
        _requestR3(0);
    }

    function test_requestR3_sameLogShapes_P1024() public {
        _requestR3(1024);
    }

    function test_requestR1_sameLogShapes() public {
        bytes memory p = _payload(32, 0xab);
        BladeRequester bI = new BladeRequester();
        BladeParticipant bP = new BladeParticipant();
        vm.recordLogs();
        bI.startRequest(address(bP), CID, p);
        bP.refuse(_reqInbound(CID, _token(address(bP), CID), ""), address(bI), p);
        Vm.Log[] memory lb = vm.getRecordedLogs();
        ManualInitiator mI = new ManualInitiator();
        ManualParticipant mP = new ManualParticipant();
        vm.recordLogs();
        mI.startRequest(address(mP), CID, p);
        mP.refuse(CID, p);
        Vm.Log[] memory lm = vm.getRecordedLogs();
        _assertSameShapes(lb, address(bI), lm, address(mI), "initiator");
        _assertSameShapes(lb, address(bP), lm, address(mP), "participant");
    }

    /// scenario B: first participant proposes and is accepted, second refuses.
    function _cn(bool scenarioB, uint256 n) internal {
        bytes memory p = _payload(n, 0xab);
        uint64 by = uint64(block.timestamp + 10);
        address[] memory none = new address[](0);

        BladeManager bM = new BladeManager();
        address[] memory bp = new address[](2);
        bp[0] = address(new BladeCnParticipant());
        bp[1] = address(new BladeCnParticipant());
        vm.recordLogs();
        bM.cfp(bp, CID, by, p);
        BladeCnParticipant(bp[0]).propose(_cfpInbound(CID, by, ""), address(bM), p);
        if (scenarioB) {
            BladeCnParticipant(bp[1]).refuse(_cfpInbound(CID, by, ""), address(bM));
        } else {
            BladeCnParticipant(bp[1]).propose(_cfpInbound(CID, by, ""), address(bM), p);
        }
        Vm.Log[] memory lb1 = vm.getRecordedLogs();

        ManualManager mM = new ManualManager();
        address[] memory mp = new address[](2);
        mp[0] = address(new ManualCnParticipant());
        mp[1] = address(new ManualCnParticipant());
        vm.recordLogs();
        mM.cfp(mp, CID, by, p);
        ManualCnParticipant(mp[0]).propose(CID, p);
        if (scenarioB) {
            ManualCnParticipant(mp[1]).refuse(CID);
        } else {
            ManualCnParticipant(mp[1]).propose(CID, p);
        }
        Vm.Log[] memory lm1 = vm.getRecordedLogs();

        _assertSameShapes(lb1, address(bM), lm1, address(mM), "manager/proposal");
        _assertSameShapes(lb1, bp[0], lm1, mp[0], "participant0/proposal");
        _assertSameShapes(lb1, bp[1], lm1, mp[1], "participant1/proposal");

        vm.warp(uint256(by) + 1);
        address[] memory accB = new address[](scenarioB ? 1 : 2);
        address[] memory accM = new address[](accB.length);
        for (uint256 i = 0; i < accB.length; i++) {
            accB[i] = bp[i];
            accM[i] = mp[i];
        }
        vm.recordLogs();
        bM.evaluate(CID, accB, none, none);
        for (uint256 i = 0; i < accB.length; i++) {
            BladeCnParticipant(accB[i]).inform(_acceptInbound(CID), address(bM), p);
        }
        Vm.Log[] memory lb2 = vm.getRecordedLogs();
        vm.recordLogs();
        mM.evaluate(CID, accM, none, none);
        for (uint256 i = 0; i < accM.length; i++) {
            ManualCnParticipant(accM[i]).inform(CID, p);
        }
        Vm.Log[] memory lm2 = vm.getRecordedLogs();
        _assertSameShapes(lb2, address(bM), lm2, address(mM), "manager/evaluation");
        _assertSameShapes(lb2, bp[0], lm2, mp[0], "participant0/evaluation");
    }

    function test_cnA_sameLogShapes() public {
        _cn(false, 256);
    }

    function test_cnB_sameLogShapes() public {
        _cn(true, 0);
    }

    function test_cnReject_sameLogShapes() public {
        uint64 by = uint64(block.timestamp + 10);
        address[] memory none = new address[](0);
        BladeManager bM = new BladeManager();
        address[] memory bp = new address[](1);
        bp[0] = address(new BladeCnParticipant());
        bM.cfp(bp, CID, by, "");
        BladeCnParticipant(bp[0]).propose(_cfpInbound(CID, by, ""), address(bM), "");
        ManualManager mM = new ManualManager();
        address[] memory mp = new address[](1);
        mp[0] = address(new ManualCnParticipant());
        mM.cfp(mp, CID, by, "");
        ManualCnParticipant(mp[0]).propose(CID, "");
        vm.warp(uint256(by) + 1);
        vm.recordLogs();
        bM.evaluate(CID, none, bp, none);
        Vm.Log[] memory lb = vm.getRecordedLogs();
        vm.recordLogs();
        mM.evaluate(CID, none, mp, none);
        Vm.Log[] memory lm = vm.getRecordedLogs();
        _assertSameShapes(lb, address(bM), lm, address(mM), "manager/reject");
        _assertSameShapes(lb, bp[0], lm, mp[0], "participant/reject");
    }
}
