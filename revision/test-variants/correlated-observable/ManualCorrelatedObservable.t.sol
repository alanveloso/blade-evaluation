// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {RevisionBase} from "../RevisionBase.sol";
import {BladeRequester, BladeParticipant} from "app/blade-app/BladeRequest.sol";
import {
    ManualInitiator,
    ManualParticipant,
    ReqTokenMismatch,
    ReqInvalidTransition
} from "app/manual/ManualRequest.sol";

/// @dev Guarantee-level comparison of the correlated-observable baseline with BLADE on Core 4b60b86.
/// Logs are compared per role as ordered sequences with full values. The only substitutions are the
/// contract addresses (role-mapped) and the token values (each side derives its token from its own
/// address, so the BLADE token is mapped to the manual token); a log matching only after any other
/// change fails the test.
contract ManualCorrelatedObservableTest is RevisionBase {
    bytes32 internal constant CID = keccak256("revision/correlated-observable");

    struct Pair {
        BladeRequester bI;
        BladeParticipant bP;
        ManualInitiator mI;
        ManualParticipant mP;
    }

    function _pair() internal returns (Pair memory p) {
        p.bI = new BladeRequester();
        p.bP = new BladeParticipant();
        p.mI = new ManualInitiator();
        p.mP = new ManualParticipant();
    }

    function _mToken(address a, bytes32 cid) internal view returns (bytes32 t) {
        (bool ok, bytes memory ret) = a.staticcall(abi.encodeWithSignature("status(bytes32)", cid));
        require(ok && ret.length == 128, "correlated status layout");
        assembly {
            t := mload(add(ret, 128))
        }
    }

    function _only(Vm.Log[] memory logs, address emitter) internal pure returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter) {
                n++;
            }
        }
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter) {
                out[n++] = logs[i];
            }
        }
    }

    function _mapWord(bytes32 w, Pair memory p, bytes32 bTok, bytes32 mTok) internal pure returns (bytes32) {
        if (w == bytes32(uint256(uint160(address(p.bI))))) return bytes32(uint256(uint160(address(p.mI))));
        if (w == bytes32(uint256(uint160(address(p.bP))))) return bytes32(uint256(uint160(address(p.mP))));
        if (bTok != bytes32(0) && w == bTok) return mTok;
        return w;
    }

    /// @dev Maps a BLADE log onto the value the manual log must carry. `Received` data is decoded and
    /// re-encoded so tokens are substituted only in the replyWith / inReplyTo fields.
    function _mapLog(Vm.Log memory l, Pair memory p, bytes32 bTok, bytes32 mTok)
        internal
        pure
        returns (bytes32[] memory topics, bytes memory data)
    {
        topics = new bytes32[](l.topics.length);
        for (uint256 i = 0; i < l.topics.length; i++) {
            topics[i] = i == 0 ? l.topics[0] : _mapWord(l.topics[i], p, bTok, mTok);
        }
        data = bytes.concat(l.data);
        if (l.topics[0] == RECEIVED_SIG) {
            // Data words: logicalSender, performative, protocol, replyWith (96), inReplyTo (128), replyBy, content.
            bytes32 rw;
            bytes32 irt;
            assembly {
                rw := mload(add(data, 128))
                irt := mload(add(data, 160))
            }
            rw = _mapWord(rw, p, bTok, mTok);
            irt = _mapWord(irt, p, bTok, mTok);
            assembly {
                mstore(add(data, 128), rw)
                mstore(add(data, 160), irt)
            }
        }
    }

    function _assertSameLogs(
        Vm.Log[] memory lb,
        address eb,
        Vm.Log[] memory lm,
        address em,
        Pair memory p,
        bytes32 bTok,
        bytes32 mTok,
        string memory role
    ) internal pure {
        Vm.Log[] memory b = _only(lb, eb);
        Vm.Log[] memory m = _only(lm, em);
        assertEq(b.length, m.length, string.concat(role, ": log count"));
        for (uint256 i = 0; i < b.length; i++) {
            (bytes32[] memory t, bytes memory d) = _mapLog(b[i], p, bTok, mTok);
            assertEq(t.length, m[i].topics.length, string.concat(role, ": topic count"));
            for (uint256 j = 0; j < t.length; j++) {
                assertEq(t[j], m[i].topics[j], string.concat(role, ": topic value"));
            }
            assertEq(d, m[i].data, string.concat(role, ": data value"));
        }
    }

    /// path: 1 refuse, 2 inform, 3 agree+inform, 4 agree+failure
    function _run(Pair memory p, uint8 path, bytes memory payload)
        internal
        returns (Vm.Log[] memory lb, Vm.Log[] memory lm, bytes32 bTok, bytes32 mTok)
    {
        vm.recordLogs();
        p.bI.startRequest(address(p.bP), CID, payload);
        bTok = _token(address(p.bP), CID);
        if (path == 1) {
            p.bP.refuse(_reqInbound(CID, bTok, ""), address(p.bI), payload);
        } else if (path == 2) {
            p.bP.inform(_reqInbound(CID, bTok, ""), address(p.bI), payload);
        } else {
            p.bP.agree(_reqInbound(CID, bTok, ""), address(p.bI));
            if (path == 3) {
                p.bP.inform(_reqInbound(CID, bTok, ""), address(p.bI), payload);
            } else {
                p.bP.failure(_reqInbound(CID, bTok, ""), address(p.bI), payload);
            }
        }
        lb = vm.getRecordedLogs();

        vm.recordLogs();
        p.mI.startRequest(address(p.mP), CID, payload);
        mTok = _mToken(address(p.mP), CID);
        if (path == 1) {
            p.mP.refuse(CID, payload);
        } else if (path == 2) {
            p.mP.inform(CID, payload);
        } else {
            p.mP.agree(CID);
            if (path == 3) {
                p.mP.inform(CID, payload);
            } else {
                p.mP.failure(CID, payload);
            }
        }
        lm = vm.getRecordedLogs();
    }

    function _assertPath(uint8 path, uint256 n) internal {
        Pair memory p = _pair();
        (Vm.Log[] memory lb, Vm.Log[] memory lm, bytes32 bTok, bytes32 mTok) = _run(p, path, _payload(n, 0xab));
        assertTrue(bTok != bytes32(0) && mTok != bytes32(0), "tokens assigned");
        _assertSameLogs(lb, address(p.bI), lm, address(p.mI), p, bTok, mTok, "initiator");
        _assertSameLogs(lb, address(p.bP), lm, address(p.mP), p, bTok, mTok, "participant");
        // Terminal behaviour: both sides cleared, no continuation accepted afterwards.
        assertEq(_token(address(p.bI), CID), bytes32(0));
        assertEq(_token(address(p.bP), CID), bytes32(0));
        assertEq(_mToken(address(p.mI), CID), bytes32(0));
        assertEq(_mToken(address(p.mP), CID), bytes32(0));
        vm.expectRevert();
        p.bP.inform(_reqInbound(CID, bTok, ""), address(p.bI), "");
        vm.expectRevert(ReqInvalidTransition.selector);
        p.mP.inform(CID, "");
    }

    function test_R1_sameLogValues() public {
        _assertPath(1, 32);
    }

    function test_R2_sameLogValues() public {
        _assertPath(2, 32);
    }

    function test_R3_sameLogValues_P0() public {
        _assertPath(3, 0);
    }

    function test_R3_sameLogValues_P1024() public {
        _assertPath(3, 1024);
    }

    function test_R4_sameLogValues() public {
        _assertPath(4, 256);
    }

    function compareExternal(
        Vm.Log[] memory lb,
        Vm.Log[] memory lm,
        Pair memory p,
        bytes32 bTok,
        bytes32 mTok
    ) external pure {
        _assertSameLogs(lb, address(p.bI), lm, address(p.mI), p, bTok, mTok, "initiator");
        _assertSameLogs(lb, address(p.bP), lm, address(p.mP), p, bTok, mTok, "participant");
    }

    /// @dev Guards the comparison: without the token substitution (or with the payload changed) the same
    /// logs must not compare equal, so the value check above is not vacuous.
    function test_comparisonIsSensitive() public {
        Pair memory p = _pair();
        (Vm.Log[] memory lb, Vm.Log[] memory lm, bytes32 bTok, bytes32 mTok) = _run(p, 3, _payload(32, 0xab));
        this.compareExternal(lb, lm, p, bTok, mTok);
        vm.expectRevert();
        this.compareExternal(lb, lm, p, bytes32(0), mTok);
        Pair memory q = _pair();
        (Vm.Log[] memory lb2,, bytes32 bTok2,) = _run(q, 3, _payload(32, 0xab));
        (, Vm.Log[] memory lm2,, bytes32 mTok2) = _run(q, 3, _payload(32, 0xcd));
        vm.expectRevert();
        this.compareExternal(lb2, lm2, q, bTok2, mTok2);
    }

    /// @dev Same derivation on both sides: keccak256(chainid, initiator, conversationId, nonce).
    function test_tokenDerivationMatchesCore() public {
        Pair memory p = _pair();
        p.bI.startRequest(address(p.bP), CID, "");
        p.mI.startRequest(address(p.mP), CID, "");
        assertEq(_token(address(p.bI), CID), keccak256(abi.encode(block.chainid, address(p.bI), CID, uint256(1))));
        assertEq(_mToken(address(p.mI), CID), keccak256(abi.encode(block.chainid, address(p.mI), CID, uint256(1))));
    }

    /// @dev Reuse of a conversationId: a fresh token, the stale one rejected at the initiator in both, and
    /// the second instance logs identical (modulo mapping) to the first.
    function test_reuse_freshTokenStaleRejected() public {
        Pair memory p = _pair();
        (,, bytes32 b1, bytes32 m1) = _run(p, 1, "");
        (Vm.Log[] memory lb, Vm.Log[] memory lm, bytes32 b2, bytes32 m2) = _run(p, 1, "");
        assertTrue(b1 != b2 && m1 != m2, "fresh token per instance");
        _assertSameLogs(lb, address(p.bI), lm, address(p.mI), p, b2, m2, "initiator/reuse");
        _assertSameLogs(lb, address(p.bP), lm, address(p.mP), p, b2, m2, "participant/reuse");

        p.bI.startRequest(address(p.bP), CID, "");
        p.mI.startRequest(address(p.mP), CID, "");
        vm.expectRevert();
        p.bP.agree(_reqInbound(CID, b1, ""), address(p.bI));
        vm.prank(address(p.mP));
        vm.expectRevert(ReqTokenMismatch.selector);
        p.mI.onAgree(CID, m1);
    }

    /// @dev Concurrent conversations: tokens are independent and closing one leaves the other intact.
    function test_concurrentConversationsIsolated() public {
        Pair memory p = _pair();
        bytes32 c2 = keccak256("other");
        p.bI.startRequest(address(p.bP), CID, "");
        p.bI.startRequest(address(p.bP), c2, "");
        p.mI.startRequest(address(p.mP), CID, "");
        p.mI.startRequest(address(p.mP), c2, "");
        bytes32 bt2 = _token(address(p.bP), c2);
        bytes32 mt2 = _mToken(address(p.mP), c2);
        assertTrue(_token(address(p.bP), CID) != bt2 && _mToken(address(p.mP), CID) != mt2);
        vm.expectRevert();
        p.bP.agree(_reqInbound(CID, bt2, ""), address(p.bI));
        vm.prank(address(p.mP));
        vm.expectRevert(ReqTokenMismatch.selector);
        p.mI.onAgree(CID, mt2);
        p.bP.refuse(_reqInbound(CID, _token(address(p.bP), CID), ""), address(p.bI), "");
        p.mP.refuse(CID, "");
        assertEq(_token(address(p.bI), c2), bt2);
        assertEq(_mToken(address(p.mI), c2), mt2);
    }

    /// @dev Where the designs differ by construction (documented, not a hidden gap): the BLADE participant
    /// receives the token through an application-supplied inbound message and its Core rejects a wrong
    /// one; the purpose-built participant takes it from storage, so a wrong token is not expressible.
    function test_wrongTokenFromParticipantSide() public {
        Pair memory p = _pair();
        p.bI.startRequest(address(p.bP), CID, "");
        vm.expectRevert();
        p.bP.agree(_reqInbound(CID, keccak256("wrong"), ""), address(p.bI));
        p.mI.startRequest(address(p.mP), CID, "");
        p.mP.agree(CID);
        assertEq(p.mI.status(CID).phase, 2);
    }
}
