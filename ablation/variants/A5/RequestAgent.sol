// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Agent} from "./Agent.sol";
import {Message} from "./Message.sol";
import {Performative} from "./Performative.sol";
import {Protocol} from "./Protocol.sol";

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
abstract contract RequestAgent is Agent {
    /// @dev Live session only. Terminal acts `delete` this entry; `Terminal` is not stored.
    struct Status {
        RequestPhase phase;
        RequestRole role;
        address transportPeer;
        bytes32 logicalPeer;
    }

    mapping(bytes32 conversationId => Status) internal _request;

    error InvalidTransition();
    error UnexpectedPeer();
    error NotRequestPerformative();

    event RequestAdvanced(bytes32 indexed conversationId, uint8 phase, uint8 performative);

    function requestStatus(bytes32 conversationId) external view returns (Status memory) {
        return _request[conversationId];
    }

    function _startRequest(address to, Message memory outbound) internal {
        if (outbound.protocol != uint8(Protocol.FipaRequest)) {
            revert InvalidTransition();
        }
        if (outbound.performative != uint8(Performative.Request)) {
            revert NotRequestPerformative();
        }
        Status storage s = _request[outbound.conversationId];
        if (s.phase != RequestPhase.None) {
            revert InvalidTransition();
        }
        s.phase = RequestPhase.Requested;
        s.role = RequestRole.Initiator;
        s.transportPeer = to;
        s.logicalPeer = bytes32(0);
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
        Status storage s = _request[message.conversationId];
        if (s.phase == RequestPhase.None) {
            if (message.performative != uint8(Performative.Request)) {
                revert InvalidTransition();
            }
            s.phase = RequestPhase.Requested;
            s.role = RequestRole.Participant;
            s.transportPeer = msg.sender;
            s.logicalPeer = message.logicalSender;
            emit RequestAdvanced(
                message.conversationId, uint8(RequestPhase.Requested), message.performative
            );
            return true;
        }
        _assertPeer(s, message);
        _commit(
            message.conversationId,
            _nextInbound(s.role, s.phase, Performative(message.performative)),
            message.performative
        );
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
        Status storage s = _request[outbound.conversationId];
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
        _commit(
            outbound.conversationId,
            _nextOutbound(s.role, s.phase, Performative(outbound.performative)),
            outbound.performative
        );
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

    function _assertPeer(Status storage s, Message calldata message) internal view {
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
