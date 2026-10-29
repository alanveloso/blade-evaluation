// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Agent} from "blade/core/Agent.sol";
import {RequestAgent} from "blade/core/RequestAgent.sol";
import {Message} from "blade/core/Message.sol";
import {Performative} from "blade/core/Performative.sol";
import {Protocol} from "blade/core/Protocol.sol";

/// @title Off-chain participant wrapper. Receives, exposes, and waits; never auto-replies.
/// @dev `_onReceive` only records the inbound Request. A later operator transaction calls
///      `respond`, which reuses `RequestAgent._reply` (validation + FSM + transport).
contract DemoParticipant is RequestAgent {
    struct PendingRequest {
        bool present;
        address requester;
        bytes32 replyWith;
        uint64 receivedBlock;
        bytes content;
    }

    address public immutable operator;
    mapping(bytes32 conversationId => PendingRequest) private _pending;
    bytes32[] private _pendingIds;

    error NotOperator();
    error NotSelf();
    error ZeroOperator();
    error NoPendingRequest();
    error UnsupportedPerformative();

    event TaskObserved(
        bytes32 indexed conversationId,
        address requester,
        bytes32 replyWith,
        uint64 receivedBlock,
        bytes content
    );

    constructor(address operator_) Agent(address(0)) {
        if (operator_ == address(0)) revert ZeroOperator();
        operator = operator_;
    }

    function pending(bytes32 conversationId) external view returns (PendingRequest memory) {
        return _pending[conversationId];
    }

    function pendingIdCount() external view returns (uint256) {
        return _pendingIds.length;
    }

    function pendingIdAt(uint256 index) external view returns (bytes32) {
        return _pendingIds[index];
    }

    /// @dev Application entry. Correlation token is chosen by the off-chain operator; the Core
    ///      still checks it against the live session. A wrong token reverts and leaves state.
    function respond(
        bytes32 conversationId,
        uint8 performative,
        bytes32 inReplyTo,
        bytes calldata content
    ) external {
        if (msg.sender != operator) revert NotOperator();
        PendingRequest memory p = _pending[conversationId];
        if (!p.present) revert NoPendingRequest();
        if (
            performative != uint8(Performative.Inform) && performative != uint8(Performative.Refuse)
        ) {
            revert UnsupportedPerformative();
        }

        Message memory inbound;
        inbound.performative = uint8(Performative.Request);
        inbound.protocol = uint8(Protocol.FipaRequest);
        inbound.conversationId = conversationId;
        inbound.replyWith = p.replyWith;

        Message memory outbound;
        outbound.performative = performative;
        outbound.protocol = uint8(Protocol.FipaRequest);
        outbound.conversationId = conversationId;
        outbound.inReplyTo = inReplyTo;
        outbound.content = content;

        // `_reply` takes `Message calldata`; the external self-call ABI-encodes the memory copies.
        this.executeReply(inbound, p.requester, outbound);
        _clearPending(conversationId);
    }

    function executeReply(Message calldata inbound, address to, Message calldata outbound)
        external
    {
        if (msg.sender != address(this)) revert NotSelf();
        _reply(inbound, to, outbound);
    }

    /// @dev Register the request for the off-chain process. Must not call `_reply`.
    function _onReceive(Message calldata inbound) internal override {
        if (inbound.performative != uint8(Performative.Request)) {
            return;
        }
        if (!_pending[inbound.conversationId].present) {
            _pendingIds.push(inbound.conversationId);
        }
        _pending[inbound.conversationId] = PendingRequest({
            present: true,
            requester: msg.sender,
            replyWith: inbound.replyWith,
            receivedBlock: uint64(block.number),
            content: inbound.content
        });
        emit TaskObserved(
            inbound.conversationId,
            msg.sender,
            inbound.replyWith,
            uint64(block.number),
            inbound.content
        );
    }

    function _clearPending(bytes32 conversationId) private {
        delete _pending[conversationId];
        uint256 n = _pendingIds.length;
        for (uint256 i; i < n; ++i) {
            if (_pendingIds[i] == conversationId) {
                _pendingIds[i] = _pendingIds[n - 1];
                _pendingIds.pop();
                break;
            }
        }
    }
}
