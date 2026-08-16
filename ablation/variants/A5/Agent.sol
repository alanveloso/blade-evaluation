// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAgent} from "./IAgent.sol";
import {Message, MessageLib} from "./Message.sol";

/// @title Generic blockchain-resident agent endpoint.
/// @dev Native transport identity is `msg.sender`; a configured trusted relay may carry an opaque
/// logical sender. The Core never stores a full `Message` or `content`.
contract Agent is IAgent {
    address public immutable trustedRelay;

    error RelayMustSetLogicalSender();
    error UnauthorizedLogicalSender();
    error ConversationMismatch();
    error ReplyWithMismatch();

    event Received(
        address indexed transportCaller,
        bytes32 indexed conversationId,
        bytes32 logicalSender,
        uint8 performative,
        uint8 protocol,
        bytes32 replyWith,
        bytes32 inReplyTo,
        uint64 replyBy,
        bytes content
    );

    constructor(address trustedRelay_) {
        trustedRelay = trustedRelay_;
    }

    /// @dev Named `handle` because Solidity reserves `receive` for the ETH receive function.
    /// Native callers must use `logicalSender == 0`; only `trustedRelay` may set it.
    function handle(Message calldata message) external {
        // Ablation A2: copy full calldata Message (including dynamic content) into memory for validation.
        Message memory copied = message;
        MessageLib.validate(copied);
        _authenticate(message);
        _onInbound(message);
        emit Received(
            msg.sender,
            message.conversationId,
            message.logicalSender,
            message.performative,
            message.protocol,
            message.replyWith,
            message.inReplyTo,
            message.replyBy,
            message.content
        );
        _onReceive(message);
    }

    error DispatchNotInternal();

    /// @dev Ablation A1: restore an external self-call before peer `handle`.
    /// The peer still observes this contract as `msg.sender`.
    function _send(address to, Message memory message) internal virtual {
        if (message.logicalSender != bytes32(0)) {
            revert UnauthorizedLogicalSender();
        }
        MessageLib.validateFields(message.protocol, message.conversationId);
        this._dispatch(to, message);
    }

    function _dispatch(address to, Message memory message) external {
        if (msg.sender != address(this)) {
            revert DispatchNotInternal();
        }
        IAgent(to).handle(message);
    }

    /// @dev Reply must keep the inbound conversation key; `inReplyTo` mirrors `replyWith` when set.
    function _reply(Message calldata inbound, address to, Message memory outbound)
        internal
        virtual
    {
        if (inbound.conversationId != outbound.conversationId) {
            revert ConversationMismatch();
        }
        if (inbound.replyWith != bytes32(0) && outbound.inReplyTo != inbound.replyWith) {
            revert ReplyWithMismatch();
        }
        _send(to, outbound);
    }

    function _authenticate(Message calldata message) internal view {
        if (trustedRelay != address(0) && msg.sender == trustedRelay) {
            if (message.logicalSender == bytes32(0)) {
                revert RelayMustSetLogicalSender();
            }
            return;
        }
        if (message.logicalSender != bytes32(0)) {
            revert UnauthorizedLogicalSender();
        }
    }

    function _onInbound(Message calldata message) internal virtual {}

    function _onReceive(Message calldata message) internal virtual {}
}
