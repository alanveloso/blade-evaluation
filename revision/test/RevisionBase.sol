// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Message} from "blade/core/Message.sol";
import {Performative} from "blade/core/Performative.sol";
import {Protocol} from "blade/core/Protocol.sol";

/// @dev Shared helpers for the revision tests. Compiles against Core fbf266f5 (E1) and 4b60b86 (E2):
/// the session token is read through a raw `requestStatus` call (4 words on E1, 5 words on E2).
abstract contract RevisionBase is Test {
    function _payload(uint256 n, bytes1 b) internal pure returns (bytes memory p) {
        p = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            p[i] = b;
        }
    }

    function _token(address agent, bytes32 cid) internal view returns (bytes32 t) {
        (bool ok, bytes memory ret) =
            agent.staticcall(abi.encodeWithSignature("requestStatus(bytes32)", cid));
        require(ok, "requestStatus");
        if (ret.length == 160) {
            assembly {
                t := mload(add(ret, 160))
            }
        } else {
            require(ret.length == 128, "requestStatus layout");
        }
    }

    function _statusRaw(address agent, bytes32 cid) internal view returns (bytes memory ret) {
        bool ok;
        (ok, ret) = agent.staticcall(abi.encodeWithSignature("requestStatus(bytes32)", cid));
        require(ok, "requestStatus");
    }

    /// @dev True when the Core under test assigns Request correlation tokens (E2).
    function _coreAssignsTokens(address participant, bytes32 cid) internal view returns (bool) {
        return _statusRaw(participant, cid).length == 160;
    }

    function _reqInbound(bytes32 cid, bytes32 token, bytes memory content)
        internal
        pure
        returns (Message memory m)
    {
        m.performative = uint8(Performative.Request);
        m.protocol = uint8(Protocol.FipaRequest);
        m.conversationId = cid;
        m.replyWith = token;
        m.content = content;
    }

    function _cfpInbound(bytes32 cid, uint64 replyBy, bytes memory content)
        internal
        pure
        returns (Message memory m)
    {
        m.performative = uint8(Performative.Cfp);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = cid;
        m.replyBy = replyBy;
        m.content = content;
    }

    function _acceptInbound(bytes32 cid) internal pure returns (Message memory m) {
        m.performative = uint8(Performative.AcceptProposal);
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = cid;
    }

    function _logsDigest() internal returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        return keccak256(abi.encode(logs));
    }

    bytes32 internal constant RECEIVED_SIG =
        keccak256("Received(address,bytes32,bytes32,uint8,uint8,bytes32,bytes32,uint64,bytes)");

    /// @dev False only in test profiles for Cores whose `Received` emission was removed for measurement
    /// (set by the revision runner through REVISION_EXPECT_RECEIVED=false). Parsed as a string so that
    /// an accidental "0" is not an invalid bool for `envOr`.
    function _expectReceived() internal view returns (bool) {
        bytes32 v = keccak256(bytes(vm.envOr("REVISION_EXPECT_RECEIVED", string("true"))));
        return v != keccak256("false") && v != keccak256("0") && v != keccak256("FALSE");
    }

    /// @dev Contents of the `Received` logs recorded since the last `vm.recordLogs()` (consumes them).
    function _receivedContents() internal returns (bytes[] memory out) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == RECEIVED_SIG) {
                n++;
            }
        }
        out = new bytes[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == RECEIVED_SIG) {
                (,,,,,, bytes memory c) =
                    abi.decode(logs[i].data, (bytes32, uint8, uint8, bytes32, bytes32, uint64, bytes));
                out[n++] = c;
            }
        }
    }

    function _body(bytes memory d) internal pure returns (bytes memory b) {
        b = new bytes(d.length - 4);
        for (uint256 i = 0; i < b.length; i++) {
            b[i] = d[i + 4];
        }
    }

    function _sel(bytes memory d) internal pure returns (bytes4 s) {
        if (d.length >= 4) {
            s = bytes4(d[0]) | (bytes4(d[1]) >> 8) | (bytes4(d[2]) >> 16) | (bytes4(d[3]) >> 24);
        }
    }

    /// @dev Contents of every successful `handle(Message)` call into `to`, taken from the recorded
    /// call data (independent of events). Requires `vm.startStateDiffRecording()` beforehand.
    function _handledContents(Vm.AccountAccess[] memory acc, address to)
        internal
        pure
        returns (bytes[] memory out)
    {
        bytes4 h = bytes4(keccak256("handle((uint8,uint8,bytes32,bytes32,bytes32,uint64,bytes32,bytes))"));
        uint256 n;
        for (uint256 i = 0; i < acc.length; i++) {
            if (_isCall(acc[i], to, h)) {
                n++;
            }
        }
        out = new bytes[](n);
        n = 0;
        for (uint256 i = 0; i < acc.length; i++) {
            if (_isCall(acc[i], to, h)) {
                out[n++] = abi.decode(_body(acc[i].data), (Message)).content;
            }
        }
    }

    /// @dev Content argument (always the last one) of every successful call into `to` whose selector
    /// is `sigA` or `sigB`; covers the submitted manual callbacks and the correlated ones (extra token).
    function _manualContents(Vm.AccountAccess[] memory acc, address to, string memory sigA, string memory sigB)
        internal
        pure
        returns (bytes[] memory out)
    {
        bytes4 a = bytes4(keccak256(bytes(sigA)));
        bytes4 b = bytes4(keccak256(bytes(sigB)));
        uint256 n;
        for (uint256 i = 0; i < acc.length; i++) {
            if (_isCall(acc[i], to, a) || _isCall(acc[i], to, b)) {
                n++;
            }
        }
        out = new bytes[](n);
        n = 0;
        for (uint256 i = 0; i < acc.length; i++) {
            if (_isCall(acc[i], to, a)) {
                (, bytes memory c) = abi.decode(_body(acc[i].data), (bytes32, bytes));
                out[n++] = c;
            } else if (_isCall(acc[i], to, b)) {
                (,, bytes memory c) = abi.decode(_body(acc[i].data), (bytes32, bytes32, bytes));
                out[n++] = c;
            }
        }
    }

    function _isCall(Vm.AccountAccess memory x, address to, bytes4 sel) private pure returns (bool) {
        return x.kind == VmSafe.AccountAccessKind.Call && x.account == to && !x.reverted
            && _sel(x.data) == sel;
    }

    /// @dev Exactly one delivery with the expected content.
    function _assertDeliveredOnce(bytes[] memory got, bytes memory expected, string memory what) internal pure {
        assertEq(got.length, 1, string.concat(what, ": delivery count"));
        assertEq(got[0], expected, string.concat(what, ": delivered content"));
    }

    /// @dev Profile-aware check of the `Received` logs: their contents when the Core emits them,
    /// and their absence when the profile declares the emission removed.
    function _assertReceived(bytes[] memory logs, uint256 count, bytes memory expected, string memory what)
        internal
    {
        if (!_expectReceived()) {
            assertEq(logs.length, 0, string.concat(what, ": Received present although removed"));
            return;
        }
        assertEq(logs.length, count, string.concat(what, ": Received count"));
        for (uint256 i = 0; i < logs.length; i++) {
            assertEq(logs[i], expected, string.concat(what, ": Received content"));
        }
    }
}
