// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// RQ3:PROTOCOL
/// @dev Population C: purpose-built 1:N Contract Net. No BLADE imports. Native msg.sender identity.

uint8 constant CN_SLOT_NONE = 0;
uint8 constant CN_SLOT_INVITED = 1;
uint8 constant CN_SLOT_PROPOSED = 2;
uint8 constant CN_SLOT_ACCEPTED = 3;

uint8 constant CN_PART_NONE = 0;
uint8 constant CN_PART_CFPED = 1;
uint8 constant CN_PART_PROPOSED = 2;
uint8 constant CN_PART_ACCEPTED = 3;

error CnInvalidCfp();
error CnEmptyParticipants();
error CnDuplicateParticipant();
error CnInvalidParticipant(address participant);
error CnInvalidTransition();
error CnUnexpectedPeer();
error CnEvaluationTooEarly();
error CnIncompleteEvaluation();
error CnDuplicateEvaluateEntry();
error CnOverlappingEvaluateLists();
error CnZeroConversationId();
error CnReplyByRequired();

interface IManualCnParticipant {
    function onCfp(bytes32 conversationId, uint64 replyBy, bytes calldata content) external;
    function onAccept(bytes32 conversationId) external;
    function onReject(bytes32 conversationId) external;
}

interface IManualCnManager {
    function onPropose(bytes32 conversationId, bytes calldata content) external;
    function onRefuse(bytes32 conversationId) external;
    function onInform(bytes32 conversationId, bytes calldata content) external;
    function onFailure(bytes32 conversationId, bytes calldata content) external;
}

contract ManualManager {
    struct Conversation {
        uint64 replyBy;
        bool evaluated;
        uint32 live;
        uint32 invited;
    }

    mapping(bytes32 conversationId => Conversation) internal _net;
    mapping(bytes32 conversationId => mapping(address participant => uint8 slot)) internal _slot;

    function conversation(bytes32 conversationId) external view returns (Conversation memory) {
        return _net[conversationId];
    }

    function slotOf(bytes32 conversationId, address participant) external view returns (uint8) {
        return _slot[conversationId][participant];
    }

    function cfp(
        address[] calldata participants,
        bytes32 conversationId,
        uint64 replyBy,
        bytes calldata content
    ) external {
        if (conversationId == bytes32(0)) {
            revert CnZeroConversationId();
        }
        if (replyBy == 0) {
            revert CnReplyByRequired();
        }
        uint256 n = participants.length;
        if (n == 0) {
            revert CnEmptyParticipants();
        }
        Conversation storage c = _net[conversationId];
        if (c.invited != 0 || c.live != 0) {
            revert CnInvalidTransition();
        }
        for (uint256 i = 0; i < n; i++) {
            address p = participants[i];
            if (p == address(0) || p.code.length == 0) {
                revert CnInvalidParticipant(p);
            }
            for (uint256 j = 0; j < i; j++) {
                if (participants[j] == p) {
                    revert CnDuplicateParticipant();
                }
            }
        }
        c.replyBy = replyBy;
        c.evaluated = false;
        c.live = uint32(n);
        c.invited = uint32(n);
        for (uint256 i = 0; i < n; i++) {
            _slot[conversationId][participants[i]] = CN_SLOT_INVITED;
        }
        for (uint256 i = 0; i < n; i++) {
            IManualCnParticipant(participants[i]).onCfp(conversationId, replyBy, content);
        }
    }

    function evaluate(
        bytes32 conversationId,
        address[] calldata accept,
        address[] calldata reject,
        address[] calldata silent
    ) external {
        Conversation storage c = _net[conversationId];
        if (c.invited == 0 && c.live == 0) {
            revert CnInvalidTransition();
        }
        if (c.evaluated) {
            revert CnInvalidTransition();
        }
        if (!(block.timestamp > c.replyBy)) {
            revert CnEvaluationTooEarly();
        }
        _noDup(accept);
        _noDup(reject);
        _noDup(silent);
        _disjoint(accept, reject);
        _disjoint(accept, silent);
        _disjoint(reject, silent);
        if (accept.length + reject.length + silent.length != c.live) {
            revert CnIncompleteEvaluation();
        }
        for (uint256 i = 0; i < silent.length; i++) {
            if (_slot[conversationId][silent[i]] != CN_SLOT_INVITED) {
                revert CnInvalidTransition();
            }
        }
        for (uint256 i = 0; i < reject.length; i++) {
            if (_slot[conversationId][reject[i]] != CN_SLOT_PROPOSED) {
                revert CnInvalidTransition();
            }
        }
        for (uint256 i = 0; i < accept.length; i++) {
            if (_slot[conversationId][accept[i]] != CN_SLOT_PROPOSED) {
                revert CnInvalidTransition();
            }
        }
        c.evaluated = true;
        for (uint256 i = 0; i < silent.length; i++) {
            delete _slot[conversationId][silent[i]];
            c.live -= 1;
        }
        for (uint256 i = 0; i < reject.length; i++) {
            delete _slot[conversationId][reject[i]];
            c.live -= 1;
        }
        for (uint256 i = 0; i < accept.length; i++) {
            _slot[conversationId][accept[i]] = CN_SLOT_ACCEPTED;
        }
        _maybeClear(conversationId);
        for (uint256 i = 0; i < reject.length; i++) {
            IManualCnParticipant(reject[i]).onReject(conversationId);
        }
        for (uint256 i = 0; i < accept.length; i++) {
            IManualCnParticipant(accept[i]).onAccept(conversationId);
        }
    }

    function onPropose(bytes32 conversationId, bytes calldata) external {
        Conversation storage c = _requireLive(conversationId);
        if (_slot[conversationId][msg.sender] != CN_SLOT_INVITED) {
            revert CnUnexpectedPeer();
        }
        _slot[conversationId][msg.sender] = CN_SLOT_PROPOSED;
        c;
    }

    function onRefuse(bytes32 conversationId) external {
        Conversation storage c = _requireLive(conversationId);
        if (_slot[conversationId][msg.sender] != CN_SLOT_INVITED) {
            revert CnInvalidTransition();
        }
        delete _slot[conversationId][msg.sender];
        c.live -= 1;
        _maybeClear(conversationId);
    }

    function onInform(bytes32 conversationId, bytes calldata) external {
        _completeAccepted(conversationId);
    }

    function onFailure(bytes32 conversationId, bytes calldata) external {
        _completeAccepted(conversationId);
    }

    function _completeAccepted(bytes32 conversationId) internal {
        Conversation storage c = _requireLive(conversationId);
        if (_slot[conversationId][msg.sender] != CN_SLOT_ACCEPTED) {
            revert CnInvalidTransition();
        }
        delete _slot[conversationId][msg.sender];
        c.live -= 1;
        _maybeClear(conversationId);
    }

    function _requireLive(bytes32 conversationId) internal view returns (Conversation storage c) {
        c = _net[conversationId];
        if (c.invited == 0 && c.live == 0) {
            revert CnInvalidTransition();
        }
        if (_slot[conversationId][msg.sender] == CN_SLOT_NONE) {
            revert CnUnexpectedPeer();
        }
    }

    function _maybeClear(bytes32 conversationId) internal {
        Conversation storage c = _net[conversationId];
        if (c.live != 0) {
            return;
        }
        delete _net[conversationId];
    }

    function _noDup(address[] calldata a) internal pure {
        for (uint256 i = 0; i < a.length; i++) {
            for (uint256 j = i + 1; j < a.length; j++) {
                if (a[i] == a[j]) {
                    revert CnDuplicateEvaluateEntry();
                }
            }
        }
    }

    function _disjoint(address[] calldata a, address[] calldata b) internal pure {
        for (uint256 i = 0; i < a.length; i++) {
            for (uint256 j = 0; j < b.length; j++) {
                if (a[i] == b[j]) {
                    revert CnOverlappingEvaluateLists();
                }
            }
        }
    }
}

contract ManualCnParticipant {
    struct Session {
        uint8 phase;
        address manager;
        uint64 replyBy;
    }

    mapping(bytes32 conversationId => Session) internal _cn;

    function session(bytes32 conversationId) external view returns (Session memory) {
        return _cn[conversationId];
    }

    function onCfp(bytes32 conversationId, uint64 replyBy, bytes calldata) external {
        if (conversationId == bytes32(0)) {
            revert CnZeroConversationId();
        }
        if (replyBy == 0) {
            revert CnReplyByRequired();
        }
        Session storage s = _cn[conversationId];
        if (s.phase != CN_PART_NONE) {
            revert CnInvalidTransition();
        }
        s.phase = CN_PART_CFPED;
        s.manager = msg.sender;
        s.replyBy = replyBy;
    }

    function propose(bytes32 conversationId, bytes calldata content) external {
        Session storage s = _cn[conversationId];
        if (s.phase != CN_PART_CFPED) {
            revert CnInvalidTransition();
        }
        address manager = s.manager;
        s.phase = CN_PART_PROPOSED;
        IManualCnManager(manager).onPropose(conversationId, content);
    }

    function refuse(bytes32 conversationId) external {
        Session storage s = _cn[conversationId];
        if (s.phase != CN_PART_CFPED) {
            revert CnInvalidTransition();
        }
        address manager = s.manager;
        delete _cn[conversationId];
        IManualCnManager(manager).onRefuse(conversationId);
    }

    function inform(bytes32 conversationId, bytes calldata content) external {
        Session storage s = _cn[conversationId];
        if (s.phase != CN_PART_ACCEPTED) {
            revert CnInvalidTransition();
        }
        address manager = s.manager;
        delete _cn[conversationId];
        IManualCnManager(manager).onInform(conversationId, content);
    }

    function failure(bytes32 conversationId, bytes calldata content) external {
        Session storage s = _cn[conversationId];
        if (s.phase != CN_PART_ACCEPTED) {
            revert CnInvalidTransition();
        }
        address manager = s.manager;
        delete _cn[conversationId];
        IManualCnManager(manager).onFailure(conversationId, content);
    }

    function onAccept(bytes32 conversationId) external {
        Session storage s = _cn[conversationId];
        if (msg.sender != s.manager) {
            revert CnUnexpectedPeer();
        }
        if (s.phase != CN_PART_PROPOSED) {
            revert CnInvalidTransition();
        }
        s.phase = CN_PART_ACCEPTED;
    }

    function onReject(bytes32 conversationId) external {
        Session storage s = _cn[conversationId];
        if (msg.sender != s.manager) {
            revert CnUnexpectedPeer();
        }
        if (s.phase != CN_PART_PROPOSED) {
            revert CnInvalidTransition();
        }
        delete _cn[conversationId];
    }
}
// RQ3:END
