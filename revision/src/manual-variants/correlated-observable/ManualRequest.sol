// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// RQ3:PROTOCOL
/// @dev Revision variant of population C (not the submitted baseline): the correlated Request variant
/// (single-use token, as in BLADE Core 4b60b86) plus BLADE-equivalent observability (same `Received` and
/// `RequestAdvanced` signatures and emission points; token carried in replyWith / inReplyTo as BLADE does).
/// Layered on top of the `observable` Contract Net variant.

uint8 constant REQ_NONE = 0;
uint8 constant REQ_REQUESTED = 1;
uint8 constant REQ_AGREED = 2;
uint8 constant REQ_TERMINAL = 3;

uint8 constant REQ_ROLE_NONE = 0;
uint8 constant REQ_ROLE_INITIATOR = 1;
uint8 constant REQ_ROLE_PARTICIPANT = 2;

uint8 constant ACT_REQUEST = 0;
uint8 constant ACT_AGREE = 1;
uint8 constant ACT_REFUSE = 2;
uint8 constant ACT_FAILURE = 3;
uint8 constant ACT_INFORM = 4;
uint8 constant PROTOCOL_FIPA_REQUEST = 1;

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

abstract contract ManualRequestEvents {
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
    event RequestAdvanced(bytes32 indexed conversationId, uint8 phase, uint8 performative);
}

contract ManualInitiator is ManualRequestEvents {
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
        emit RequestAdvanced(conversationId, REQ_REQUESTED, ACT_REQUEST);
        IManualRequestPeer(participant).onRequest(conversationId, token, content);
    }

    function onRefuse(bytes32 conversationId, bytes32 token, bytes calldata content) external {
        _terminalFromPeer(conversationId, token, REQ_REQUESTED, ACT_REFUSE);
        _received(conversationId, ACT_REFUSE, token, content);
    }

    function onInform(bytes32 conversationId, bytes32 token, bytes calldata content) external {
        _terminalFromPeer(conversationId, token, 0, ACT_INFORM);
        _received(conversationId, ACT_INFORM, token, content);
    }

    function onAgree(bytes32 conversationId, bytes32 token) external {
        Status storage s = _requirePeer(conversationId, token);
        if (s.role != REQ_ROLE_INITIATOR || s.phase != REQ_REQUESTED) {
            revert ReqInvalidTransition();
        }
        s.phase = REQ_AGREED;
        emit RequestAdvanced(conversationId, REQ_AGREED, ACT_AGREE);
        emit Received(
            msg.sender, conversationId, bytes32(0), ACT_AGREE, PROTOCOL_FIPA_REQUEST, bytes32(0), token, 0, ""
        );
    }

    function onFailure(bytes32 conversationId, bytes32 token, bytes calldata content) external {
        _terminalFromPeer(conversationId, token, 0, ACT_FAILURE);
        _received(conversationId, ACT_FAILURE, token, content);
    }

    function onRequest(bytes32, bytes32, bytes calldata) external pure {
        revert ReqInvalidTransition();
    }

    function _received(bytes32 conversationId, uint8 act, bytes32 token, bytes calldata content) internal {
        emit Received(
            msg.sender, conversationId, bytes32(0), act, PROTOCOL_FIPA_REQUEST, bytes32(0), token, 0, content
        );
    }

    function _terminalFromPeer(bytes32 conversationId, bytes32 token, uint8 onlyIfRequested, uint8 act)
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
        emit RequestAdvanced(conversationId, REQ_TERMINAL, act);
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

contract ManualParticipant is ManualRequestEvents {
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

    function onRequest(bytes32 conversationId, bytes32 token, bytes calldata content) external {
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
        emit RequestAdvanced(conversationId, REQ_REQUESTED, ACT_REQUEST);
        emit Received(
            msg.sender, conversationId, bytes32(0), ACT_REQUEST, PROTOCOL_FIPA_REQUEST, token, bytes32(0), 0, content
        );
    }

    function refuse(bytes32 conversationId, bytes calldata content) external {
        (address peer, bytes32 token) = _consumeParticipantReply(conversationId, REQ_REQUESTED, true, ACT_REFUSE);
        IManualRequestPeer(peer).onRefuse(conversationId, token, content);
    }

    function inform(bytes32 conversationId, bytes calldata content) external {
        (address peer, bytes32 token) = _consumeParticipantReply(conversationId, 0, false, ACT_INFORM);
        IManualRequestPeer(peer).onInform(conversationId, token, content);
    }

    function agree(bytes32 conversationId) external {
        Status storage s = _live[conversationId];
        if (s.role != REQ_ROLE_PARTICIPANT || s.phase != REQ_REQUESTED) {
            revert ReqInvalidTransition();
        }
        address peer = s.peer;
        s.phase = REQ_AGREED;
        emit RequestAdvanced(conversationId, REQ_AGREED, ACT_AGREE);
        IManualRequestPeer(peer).onAgree(conversationId, s.token);
    }

    function failure(bytes32 conversationId, bytes calldata content) external {
        (address peer, bytes32 token) = _consumeParticipantReply(conversationId, 0, false, ACT_FAILURE);
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

    function _consumeParticipantReply(
        bytes32 conversationId,
        uint8 onlyRequested,
        bool refuseAct,
        uint8 act
    ) internal returns (address peer, bytes32 token) {
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
        emit RequestAdvanced(conversationId, REQ_TERMINAL, act);
    }
}
// RQ3:END
