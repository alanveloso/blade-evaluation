// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// RQ3:PROTOCOL
/// @dev Revision variant of population C (not the submitted baseline). Same external API as
/// comparison/src/manual/ManualRequest.sol, plus the correlation guarantee of BLADE Core 4b60b86:
/// the initiator assigns a single-use token from a monotonic nonce, both sides store it, and every
/// act after the opening request must carry it.

uint8 constant REQ_NONE = 0;
uint8 constant REQ_REQUESTED = 1;
uint8 constant REQ_AGREED = 2;

uint8 constant REQ_ROLE_NONE = 0;
uint8 constant REQ_ROLE_INITIATOR = 1;
uint8 constant REQ_ROLE_PARTICIPANT = 2;

error ReqZeroConversationId();
error ReqInvalidTransition();
error ReqUnexpectedPeer();
error ReqMissingToken();
error ReqTokenMismatch();

interface IManualRequestPeer {
    function onRequest(bytes32 conversationId, bytes32 token, bytes calldata content) external;
    function onRefuse(bytes32 conversationId, bytes32 token, bytes calldata content) external;
    function onInform(bytes32 conversationId, bytes32 token, bytes calldata content) external;
    function onAgree(bytes32 conversationId, bytes32 token) external;
    function onFailure(bytes32 conversationId, bytes32 token, bytes calldata content) external;
}

contract ManualInitiator {
    struct Status {
        uint8 phase;
        uint8 role;
        address peer;
        bytes32 token;
    }

    mapping(bytes32 conversationId => Status) internal _live;
    uint256 internal _nonce;

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
        bytes32 token = keccak256(abi.encode(block.chainid, address(this), conversationId, ++_nonce));
        s.phase = REQ_REQUESTED;
        s.role = REQ_ROLE_INITIATOR;
        s.peer = participant;
        s.token = token;
        IManualRequestPeer(participant).onRequest(conversationId, token, content);
    }

    function onRefuse(bytes32 conversationId, bytes32 token, bytes calldata) external {
        _terminalFromPeer(conversationId, token, REQ_REQUESTED);
    }

    function onInform(bytes32 conversationId, bytes32 token, bytes calldata) external {
        _terminalFromPeer(conversationId, token, 0);
    }

    function onAgree(bytes32 conversationId, bytes32 token) external {
        Status storage s = _requirePeer(conversationId, token);
        if (s.role != REQ_ROLE_INITIATOR || s.phase != REQ_REQUESTED) {
            revert ReqInvalidTransition();
        }
        s.phase = REQ_AGREED;
    }

    function onFailure(bytes32 conversationId, bytes32 token, bytes calldata) external {
        _terminalFromPeer(conversationId, token, 0);
    }

    function onRequest(bytes32, bytes32, bytes calldata) external pure {
        revert ReqInvalidTransition();
    }

    function _terminalFromPeer(bytes32 conversationId, bytes32 token, uint8 onlyIfRequested)
        internal
    {
        Status storage s = _requirePeer(conversationId, token);
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

    function _requirePeer(bytes32 conversationId, bytes32 token)
        internal
        view
        returns (Status storage s)
    {
        s = _live[conversationId];
        if (s.phase == REQ_NONE) {
            revert ReqInvalidTransition();
        }
        if (msg.sender != s.peer) {
            revert ReqUnexpectedPeer();
        }
        if (token != s.token) {
            revert ReqTokenMismatch();
        }
    }
}

contract ManualParticipant {
    struct Status {
        uint8 phase;
        uint8 role;
        address peer;
        bytes32 token;
    }

    mapping(bytes32 conversationId => Status) internal _live;

    function status(bytes32 conversationId) external view returns (Status memory) {
        return _live[conversationId];
    }

    function onRequest(bytes32 conversationId, bytes32 token, bytes calldata) external {
        if (conversationId == bytes32(0)) {
            revert ReqZeroConversationId();
        }
        if (token == bytes32(0)) {
            revert ReqMissingToken();
        }
        Status storage s = _live[conversationId];
        if (s.phase != REQ_NONE) {
            revert ReqInvalidTransition();
        }
        s.phase = REQ_REQUESTED;
        s.role = REQ_ROLE_PARTICIPANT;
        s.peer = msg.sender;
        s.token = token;
    }

    function refuse(bytes32 conversationId, bytes calldata content) external {
        (address peer, bytes32 token) = _consumeParticipantReply(conversationId, REQ_REQUESTED, true);
        IManualRequestPeer(peer).onRefuse(conversationId, token, content);
    }

    function inform(bytes32 conversationId, bytes calldata content) external {
        (address peer, bytes32 token) = _consumeParticipantReply(conversationId, 0, false);
        IManualRequestPeer(peer).onInform(conversationId, token, content);
    }

    function agree(bytes32 conversationId) external {
        Status storage s = _live[conversationId];
        if (s.role != REQ_ROLE_PARTICIPANT || s.phase != REQ_REQUESTED) {
            revert ReqInvalidTransition();
        }
        address peer = s.peer;
        s.phase = REQ_AGREED;
        IManualRequestPeer(peer).onAgree(conversationId, s.token);
    }

    function failure(bytes32 conversationId, bytes calldata content) external {
        (address peer, bytes32 token) = _consumeParticipantReply(conversationId, 0, false);
        IManualRequestPeer(peer).onFailure(conversationId, token, content);
    }

    function onRefuse(bytes32, bytes32, bytes calldata) external pure {
        revert ReqInvalidTransition();
    }

    function onInform(bytes32, bytes32, bytes calldata) external pure {
        revert ReqInvalidTransition();
    }

    function onAgree(bytes32, bytes32) external pure {
        revert ReqInvalidTransition();
    }

    function onFailure(bytes32, bytes32, bytes calldata) external pure {
        revert ReqInvalidTransition();
    }

    function _consumeParticipantReply(bytes32 conversationId, uint8 onlyRequested, bool refuseAct)
        internal
        returns (address peer, bytes32 token)
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
        token = s.token;
        delete _live[conversationId];
    }
}
// RQ3:END
