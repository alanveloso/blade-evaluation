// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ScriptedRequestAgent} from "../Request.t.sol";
import {RequestAgent, RequestPhase} from "../../src/core/RequestAgent.sol";
import {Agent} from "../../src/core/Agent.sol";
import {Message} from "../../src/core/Message.sol";
import {Performative} from "../../src/core/Performative.sol";
import {Protocol} from "../../src/core/Protocol.sol";

/// @dev Nonce-packing study (revision/src/core-variants/nonce-packed). Runs unchanged against the
/// official Core 4b60b86 and the packed variant; where the two must differ the test branches on the
/// storage layout and asserts the expected behaviour of each, so differences are explicit.
///
/// The official `Request.t.sol::test_corr_tokenAssignedByCoreAndDeliveredToPeer` peeks at
/// `_request[id].replyWith` in storage via `ExposedTokenRequester`. That field is zero on the packed
/// initiator (the token is recomputed); `requestStatus().replyWith` still returns the token. That
/// single official failure is a storage-layout assertion, not a correlation failure.
contract NonceStudyTest is Test {
    ScriptedRequestAgent internal alice;
    ScriptedRequestAgent internal bob;

    bytes32 internal constant NONCE_SLOT = bytes32(uint256(1));

    function setUp() public {
        Agent relay = new Agent(address(0));
        alice = new ScriptedRequestAgent(address(relay));
        bob = new ScriptedRequestAgent(address(relay));
    }

    function _req(bytes32 cid) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = cid;
    }

    function _act(bytes32 cid, bytes32 token, Performative act) internal pure returns (Message memory m) {
        m.performative = uint8(act);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = cid;
        m.inReplyTo = token;
    }

    function _sessionSlot(bytes32 cid, uint256 k) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(cid, uint256(0)))) + k);
    }

    function _formula(address a, bytes32 cid, uint256 n) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, a, cid, n));
    }

    /// @dev True on the packed variant: the initiator does not store its token (third session word).
    function _packed(bytes32 liveCid) internal view returns (bool) {
        return vm.load(address(alice), _sessionSlot(liveCid, 2)) == bytes32(0);
    }

    function test_tokensFollowTheCoreFormula() public {
        for (uint256 n = 1; n <= 3; n++) {
            bytes32 cid = keccak256(abi.encode("cid", n));
            alice.startRequest(address(bob), _req(cid));
            bytes32 t = _formula(address(alice), cid, n);
            assertEq(alice.requestStatus(cid).replyWith, t, "initiator view");
            assertEq(bob.requestStatus(cid).replyWith, t, "participant stored");
        }
    }

    function testFuzz_tokenMatchesFormulaAfterPriorRequests(uint8 prior, bytes32 cid) public {
        vm.assume(cid != bytes32(0));
        prior = uint8(bound(prior, 0, 20));
        for (uint256 i = 0; i < prior; i++) {
            bytes32 c = keccak256(abi.encode("prior", i));
            vm.assume(c != cid);
            alice.startRequest(address(bob), _req(c));
        }
        alice.startRequest(address(bob), _req(cid));
        bytes32 t = _formula(address(alice), cid, uint256(prior) + 1);
        assertEq(alice.requestStatus(cid).replyWith, t);
        Message memory inbound = _req(cid);
        inbound.replyWith = t;
        bob.respond(inbound, address(alice), _act(cid, t, Performative.Agree));
        assertEq(uint8(alice.requestStatus(cid).phase), uint8(RequestPhase.Agreed));
        bob.respond(inbound, address(alice), _act(cid, t, Performative.Inform));
        assertEq(uint8(alice.requestStatus(cid).phase), uint8(RequestPhase.None));
        assertEq(alice.requestStatus(cid).replyWith, bytes32(0), "cleared view");
    }

    /// @dev Session words at the initiator: official = slot0 + token; packed = slot0 only (nonce in
    /// its upper 10 bytes). Participant and persistent nonce slot unchanged in both.
    function test_storageLayout() public {
        bytes32 cid = keccak256("layout");
        alice.startRequest(address(bob), _req(cid));
        bytes32 w0 = vm.load(address(alice), _sessionSlot(cid, 0));
        assertTrue(w0 != bytes32(0));
        assertEq(vm.load(address(alice), _sessionSlot(cid, 1)), bytes32(0), "logicalPeer");
        assertEq(uint256(vm.load(address(alice), NONCE_SLOT)), 1, "persistent nonce");
        assertTrue(vm.load(address(bob), _sessionSlot(cid, 2)) != bytes32(0), "participant token stored");
        if (_packed(cid)) {
            assertEq(uint256(w0) >> 176, 1, "packed nonce");
        } else {
            assertEq(vm.load(address(alice), _sessionSlot(cid, 2)), _formula(address(alice), cid, 1));
            assertEq(uint256(w0) >> 176, 0, "no packed nonce in official layout");
        }
    }

    /// @dev Counter limit. Official: uint256 (unbounded in practice). Packed: the per-session nonce is a
    /// uint80, so the 2^80-th request reverts instead of truncating (no token reuse possible).
    function test_nonceBoundary() public {
        vm.store(address(alice), NONCE_SLOT, bytes32(uint256(type(uint80).max) - 1));
        bytes32 a = keccak256("last");
        alice.startRequest(address(bob), _req(a));
        assertEq(alice.requestStatus(a).replyWith, _formula(address(alice), a, type(uint80).max));
        bytes32 b = keccak256("beyond");
        if (_packed(a)) {
            vm.expectRevert(bytes4(keccak256("RequestNonceExhausted()")));
            alice.startRequest(address(bob), _req(b));
        } else {
            alice.startRequest(address(bob), _req(b));
            assertEq(alice.requestStatus(b).replyWith, _formula(address(alice), b, uint256(type(uint80).max) + 1));
        }
    }

    /// @dev Semantic difference of the packed variant: the initiator recomputes the token with the
    /// current chain id, so a chain-id change during a live session (e.g. a fork) invalidates the
    /// session's replies; the official Core compares against the stored token and still accepts them.
    function test_chainIdChangeDuringSession() public {
        bytes32 cid = keccak256("fork");
        alice.startRequest(address(bob), _req(cid));
        bytes32 t = bob.requestStatus(cid).replyWith;
        bool packed = _packed(cid);
        vm.chainId(block.chainid + 1);
        Message memory inbound = _req(cid);
        inbound.replyWith = t;
        if (packed) {
            assertTrue(alice.requestStatus(cid).replyWith != t, "view changes with chain id");
            vm.expectRevert(Agent.ReplyWithMismatch.selector);
            bob.respond(inbound, address(alice), _act(cid, t, Performative.Agree));
        } else {
            bob.respond(inbound, address(alice), _act(cid, t, Performative.Agree));
            assertEq(uint8(alice.requestStatus(cid).phase), uint8(RequestPhase.Agreed));
        }
    }
}
