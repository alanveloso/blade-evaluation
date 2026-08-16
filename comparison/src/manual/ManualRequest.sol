// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// RQ3:PROTOCOL
/// @dev Population C: purpose-built two-party Request. No BLADE imports.
/// Native only: identity is msg.sender. No events required by the protocol.

uint8 constant REQ_NONE = 0;
uint8 constant REQ_REQUESTED = 1;
uint8 constant REQ_AGREED = 2;

uint8 constant REQ_ROLE_NONE = 0;
uint8 constant REQ_ROLE_INITIATOR = 1;
uint8 constant REQ_ROLE_PARTICIPANT = 2;

error ReqZeroConversationId();
error ReqInvalidTransition();
error ReqUnexpectedPeer();

interface IManualRequestPeer {
    function onRequest(bytes32 conversationId, bytes calldata content) external;
    function onRefuse(bytes32 conversationId, bytes calldata content) external;
    function onInform(bytes32 conversationId, bytes calldata content) external;
    function onAgree(bytes32 conversationId) external;
    function onFailure(bytes32 conversationId, bytes calldata content) external;
}

contract ManualInitiator {
    struct Status {
        uint8 phase;
        uint8 role;
        address peer;
    }

    mapping(bytes32 conversationId => Status) internal _live;

    function status(bytes32 conversationId) external view returns (Status memory) {
        return _live[conversationId];
    }

    function startRequest(address participant, bytes32 conversationId, bytes calldata content)
        external
    {
        if (conversationId == bytes32(0)) {
            revert ReqZeroConversationId();
        }
        Status storage s = _live[conversationId];
        if (s.phase != REQ_NONE) {
            revert ReqInvalidTransition();
        }
        s.phase = REQ_REQUESTED;
        s.role = REQ_ROLE_INITIATOR;
        s.peer = participant;
        IManualRequestPeer(participant).onRequest(conversationId, content);
    }

    function onRefuse(bytes32 conversationId, bytes calldata) external {
        _terminalFromPeer(conversationId, REQ_REQUESTED);
    }

    function onInform(bytes32 conversationId, bytes calldata) external {
        _terminalFromPeer(conversationId, 0);
    }

    function onAgree(bytes32 conversationId) external {
        Status storage s = _requirePeer(conversationId);
        if (s.role != REQ_ROLE_INITIATOR || s.phase != REQ_REQUESTED) {
            revert ReqInvalidTransition();
        }
        s.phase = REQ_AGREED;
    }

    function onFailure(bytes32 conversationId, bytes calldata) external {
        _terminalFromPeer(conversationId, 0);
    }

    function onRequest(bytes32, bytes calldata) external pure {
        revert ReqInvalidTransition();
    }

    function _terminalFromPeer(bytes32 conversationId, uint8 onlyIfRequested) internal {
        Status storage s = _requirePeer(conversationId);
        if (s.role != REQ_ROLE_INITIATOR) {
            revert ReqInvalidTransition();
        }
        if (onlyIfRequested == REQ_REQUESTED) {
            if (s.phase != REQ_REQUESTED) {
                revert ReqInvalidTransition();
            }
        } else if (s.phase != REQ_REQUESTED && s.phase != REQ_AGREED) {
            revert ReqInvalidTransition();
        }
        delete _live[conversationId];
    }

    function _requirePeer(bytes32 conversationId) internal view returns (Status storage s) {
        s = _live[conversationId];
        if (s.phase == REQ_NONE) {
            revert ReqInvalidTransition();
        }
        if (msg.sender != s.peer) {
            revert ReqUnexpectedPeer();
        }
    }
}

contract ManualParticipant {
    struct Status {
        uint8 phase;
        uint8 role;
        address peer;
    }

    mapping(bytes32 conversationId => Status) internal _live;

    function status(bytes32 conversationId) external view returns (Status memory) {
        return _live[conversationId];
    }

    function onRequest(bytes32 conversationId, bytes calldata) external {
        if (conversationId == bytes32(0)) {
            revert ReqZeroConversationId();
        }
        Status storage s = _live[conversationId];
        if (s.phase != REQ_NONE) {
            revert ReqInvalidTransition();
        }
        s.phase = REQ_REQUESTED;
        s.role = REQ_ROLE_PARTICIPANT;
        s.peer = msg.sender;
    }

    function refuse(bytes32 conversationId, bytes calldata content) external {
        address peer = _consumeParticipantReply(conversationId, REQ_REQUESTED, true);
        IManualRequestPeer(peer).onRefuse(conversationId, content);
    }

    function inform(bytes32 conversationId, bytes calldata content) external {
        address peer = _consumeParticipantReply(conversationId, 0, false);
        IManualRequestPeer(peer).onInform(conversationId, content);
    }

    function agree(bytes32 conversationId) external {
        Status storage s = _live[conversationId];
        if (s.role != REQ_ROLE_PARTICIPANT || s.phase != REQ_REQUESTED) {
            revert ReqInvalidTransition();
        }
        address peer = s.peer;
        s.phase = REQ_AGREED;
        IManualRequestPeer(peer).onAgree(conversationId);
    }

    function failure(bytes32 conversationId, bytes calldata content) external {
        address peer = _consumeParticipantReply(conversationId, 0, false);
        IManualRequestPeer(peer).onFailure(conversationId, content);
    }

    function onRefuse(bytes32, bytes calldata) external pure {
        revert ReqInvalidTransition();
    }

    function onInform(bytes32, bytes calldata) external pure {
        revert ReqInvalidTransition();
    }

    function onAgree(bytes32) external pure {
        revert ReqInvalidTransition();
    }

    function onFailure(bytes32, bytes calldata) external pure {
        revert ReqInvalidTransition();
    }

    function _consumeParticipantReply(bytes32 conversationId, uint8 onlyRequested, bool refuseAct)
        internal
        returns (address peer)
    {
        Status storage s = _live[conversationId];
        if (s.role != REQ_ROLE_PARTICIPANT) {
            revert ReqInvalidTransition();
        }
        if (refuseAct) {
            if (s.phase != REQ_REQUESTED) {
                revert ReqInvalidTransition();
            }
        } else if (onlyRequested == REQ_REQUESTED) {
            if (s.phase != REQ_REQUESTED) {
                revert ReqInvalidTransition();
            }
        } else if (s.phase != REQ_REQUESTED && s.phase != REQ_AGREED) {
            revert ReqInvalidTransition();
        }
        peer = s.peer;
        delete _live[conversationId];
    }
}
// RQ3:END
