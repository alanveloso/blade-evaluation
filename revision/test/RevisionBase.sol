// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
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
}
