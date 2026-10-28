// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Agent} from "./Agent.sol";
import {Message} from "./Message.sol";
import {Performative} from "./Performative.sol";
import {Protocol} from "./Protocol.sol";

// EXPERIMENTAL STUDY VARIANT (revision/src/core-variants/nonce-packed). Not the official Core.
// Derived from Core 4b60b86 RequestAgent.sol. Only the storage of the initiator's token changes: the
// initiator keeps the per-session nonce packed in the first session slot and recomputes the token
// keccak256(chainid, this, conversationId, nonce) on demand; the participant still stores the token it
// received. Token values, `requestStatus` ABI and returned values, events and reverts are unchanged.

/// @dev Compact FIPA Request session status. Not a full `Message`; no `content`.
enum RequestPhase {
    None,
    Requested,
    Agreed,
    Terminal
}

enum RequestRole {
    None,
    Initiator,
    Participant
}

/// @title On-chain implementation of the supported FIPA Request interaction subset.
/// @dev Cancel is outside the current Core scope. Abstract: the leaf calls `Agent` once.
/// @dev Correlation: every act after the opening Request is bound to the session token
/// (`replyWith` of that Request). Participant acts must carry it in `inReplyTo`; initiator
/// continuations must keep it in `replyWith`. The initiator's Core assigns the token from a
/// monotonic nonce, so a reused `conversationId` never reuses a token.
abstract contract RequestAgent is Agent {
    /// @dev External view of a live session (ABI unchanged from 4b60b86).
    struct Status {
        RequestPhase phase;
        RequestRole role;
        address transportPeer;
        bytes32 logicalPeer;
        bytes32 replyWith;
    }

    /// @dev Stored session. Slot 0: phase, role, transportPeer, nonce (initiator only; 10 bytes).
    /// `replyWith` is written only by the participant; the initiator recomputes it from `nonce`.
    struct StoredStatus {
        RequestPhase phase;
        RequestRole role;
        address transportPeer;
        uint80 nonce;
        bytes32 logicalPeer;
        bytes32 replyWith;
    }

    mapping(bytes32 conversationId => StoredStatus) internal _request;
    /// @dev Persistent (one slot per agent). Never decremented; makes Request tokens single-use.
    uint256 internal _requestNonce;

    error InvalidTransition();
    error UnexpectedPeer();
    error NotRequestPerformative();
    error MissingReplyWith();
    error ReplyWithAssignedByCore();
    error RequestNonceExhausted();

    event RequestAdvanced(bytes32 indexed conversationId, uint8 phase, uint8 performative);

    function requestStatus(bytes32 conversationId) external view returns (Status memory v) {
        StoredStatus storage s = _request[conversationId];
        v.phase = s.phase;
        v.role = s.role;
        v.transportPeer = s.transportPeer;
        v.logicalPeer = s.logicalPeer;
        v.replyWith = _token(s, conversationId);
    }

    function _token(StoredStatus storage s, bytes32 conversationId) private view returns (bytes32) {
        if (s.role == RequestRole.Initiator) {
            return keccak256(abi.encode(block.chainid, address(this), conversationId, uint256(s.nonce)));
        }
        return s.replyWith;
    }

    function _startRequest(address to, Message memory outbound) internal {
        if (outbound.protocol != uint8(Protocol.FipaRequest)) {
            revert InvalidTransition();
        }
        if (outbound.performative != uint8(Performative.Request)) {
            revert NotRequestPerformative();
        }
        StoredStatus storage s = _request[outbound.conversationId];
        if (s.phase != RequestPhase.None) {
            revert InvalidTransition();
        }
        if (outbound.replyWith != bytes32(0)) {
            revert ReplyWithAssignedByCore();
        }
        uint256 n = ++_requestNonce;
        if (n > type(uint80).max) {
            revert RequestNonceExhausted();
        }
        bytes32 token = keccak256(abi.encode(block.chainid, address(this), outbound.conversationId, n));
        s.phase = RequestPhase.Requested;
        s.role = RequestRole.Initiator;
        s.transportPeer = to;
        s.nonce = uint80(n);
        s.logicalPeer = bytes32(0);
        outbound.replyWith = token;
        emit RequestAdvanced(
            outbound.conversationId, uint8(RequestPhase.Requested), outbound.performative
        );
        _send(to, outbound);
    }

    /// @dev Returns true when this capability owns the inbound message (FIPA Request).
    function _handleRequestInbound(Message calldata message) internal returns (bool) {
        if (message.protocol != uint8(Protocol.FipaRequest)) {
            return false;
        }
        StoredStatus storage s = _request[message.conversationId];
        if (s.phase == RequestPhase.None) {
            if (message.performative != uint8(Performative.Request)) {
                revert InvalidTransition();
            }
            if (message.replyWith == bytes32(0)) {
                revert MissingReplyWith();
            }
            s.phase = RequestPhase.Requested;
            s.role = RequestRole.Participant;
            s.transportPeer = msg.sender;
            s.logicalPeer = message.logicalSender;
            s.replyWith = message.replyWith;
            emit RequestAdvanced(
                message.conversationId, uint8(RequestPhase.Requested), message.performative
            );
            return true;
        }
        _assertPeer(s, message);
        RequestPhase next = _nextInbound(s.role, s.phase, Performative(message.performative));
        _assertCorrelated(
            s,
            message.conversationId,
            s.role == RequestRole.Participant,
            message.replyWith,
            message.inReplyTo
        );
        _commit(message.conversationId, next, message.performative);
        return true;
    }

    /// @dev Returns true when outbound is a Request continuation this capability must validate.
    function _handleRequestReply(Message calldata, address to, Message memory outbound)
        internal
        returns (bool)
    {
        if (outbound.protocol != uint8(Protocol.FipaRequest)) {
            return false;
        }
        StoredStatus storage s = _request[outbound.conversationId];
        if (s.phase == RequestPhase.None) {
            revert InvalidTransition();
        }
        // The Core owns peer correlation in both directions. A continuation cannot be
        // redirected by application code to a transport peer different from the live session.
        if (s.logicalPeer == bytes32(0)) {
            if (to != s.transportPeer) {
                revert UnexpectedPeer();
            }
        } else if (to != trustedRelay) {
            revert UnexpectedPeer();
        }
        RequestPhase next = _nextOutbound(s.role, s.phase, Performative(outbound.performative));
        // Checked against the stored session, not against the application-supplied `inbound`.
        _assertCorrelated(
            s,
            outbound.conversationId,
            s.role == RequestRole.Initiator,
            outbound.replyWith,
            outbound.inReplyTo
        );
        _commit(outbound.conversationId, next, outbound.performative);
        return true;
    }

    function _onInbound(Message calldata message) internal virtual override {
        if (_handleRequestInbound(message)) {
            return;
        }
        super._onInbound(message);
    }

    function _reply(Message calldata inbound, address to, Message memory outbound)
        internal
        virtual
        override
    {
        _handleRequestReply(inbound, to, outbound);
        super._reply(inbound, to, outbound);
    }

    /// @dev `Terminal` is an event/transition token only; it is not kept in `_request`.
    function _commit(bytes32 conversationId, RequestPhase next, uint8 performative) internal {
        if (next == RequestPhase.Terminal) {
            delete _request[conversationId];
        } else {
            _request[conversationId].phase = next;
        }
        emit RequestAdvanced(conversationId, uint8(next), performative);
    }

    function _assertPeer(StoredStatus storage s, Message calldata message) internal view {
        if (s.logicalPeer == bytes32(0)) {
            if (msg.sender != s.transportPeer || message.logicalSender != bytes32(0)) {
                revert UnexpectedPeer();
            }
            return;
        }
        if (msg.sender != trustedRelay || message.logicalSender != s.logicalPeer) {
            revert UnexpectedPeer();
        }
    }

    function _assertCorrelated(
        StoredStatus storage s,
        bytes32 conversationId,
        bool fromInitiator,
        bytes32 replyWith,
        bytes32 inReplyTo
    ) internal view {
        if ((fromInitiator ? replyWith : inReplyTo) != _token(s, conversationId)) {
            revert ReplyWithMismatch();
        }
    }

    function _nextInbound(RequestRole role, RequestPhase phase, Performative act)
        internal
        pure
        returns (RequestPhase)
    {
        if (act == Performative.NotUnderstood) {
            if (phase == RequestPhase.Requested || phase == RequestPhase.Agreed) {
                return RequestPhase.Terminal;
            }
            revert InvalidTransition();
        }
        if (role == RequestRole.Initiator) {
            if (phase == RequestPhase.Requested) {
                if (
                    act == Performative.Refuse || act == Performative.Inform
                        || act == Performative.Failure
                ) {
                    return RequestPhase.Terminal;
                }
                if (act == Performative.Agree) {
                    return RequestPhase.Agreed;
                }
            } else if (phase == RequestPhase.Agreed) {
                if (act == Performative.Inform || act == Performative.Failure) {
                    return RequestPhase.Terminal;
                }
            }
        } else if (role == RequestRole.Participant) {
            if (phase == RequestPhase.Requested || phase == RequestPhase.Agreed) {
                revert InvalidTransition();
            }
        }
        revert InvalidTransition();
    }

    function _nextOutbound(RequestRole role, RequestPhase phase, Performative act)
        internal
        pure
        returns (RequestPhase)
    {
        if (act == Performative.NotUnderstood) {
            if (phase == RequestPhase.Requested || phase == RequestPhase.Agreed) {
                return RequestPhase.Terminal;
            }
            revert InvalidTransition();
        }
        if (role == RequestRole.Participant) {
            if (phase == RequestPhase.Requested) {
                if (
                    act == Performative.Refuse || act == Performative.Inform
                        || act == Performative.Failure
                ) {
                    return RequestPhase.Terminal;
                }
                if (act == Performative.Agree) {
                    return RequestPhase.Agreed;
                }
            } else if (phase == RequestPhase.Agreed) {
                if (act == Performative.Inform || act == Performative.Failure) {
                    return RequestPhase.Terminal;
                }
            }
        }
        revert InvalidTransition();
    }
}
