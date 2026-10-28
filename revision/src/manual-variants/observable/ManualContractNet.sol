// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// RQ3:PROTOCOL
/// @dev Revision variant of population C (not the submitted baseline). Same protocol logic and API as
/// comparison/src/manual/ManualContractNet.sol, plus the observability BLADE provides: the same
/// `Received`, `ContractNetSlot` and `ContractNetParticipantPhase` event signatures, emitted at the
/// same protocol points. Fields the purpose-built design does not have are emitted as zero.

uint8 constant CN_SLOT_NONE = 0;
uint8 constant CN_SLOT_INVITED = 1;
uint8 constant CN_SLOT_PROPOSED = 2;
uint8 constant CN_SLOT_ACCEPTED = 3;

uint8 constant CN_PART_NONE = 0;
uint8 constant CN_PART_CFPED = 1;
uint8 constant CN_PART_PROPOSED = 2;
uint8 constant CN_PART_ACCEPTED = 3;

uint8 constant CN_ACT_REFUSE = 2;
uint8 constant CN_ACT_FAILURE = 3;
uint8 constant CN_ACT_INFORM = 4;
uint8 constant CN_ACT_CFP = 7;
uint8 constant CN_ACT_PROPOSE = 8;
uint8 constant CN_ACT_ACCEPT = 9;
uint8 constant CN_ACT_REJECT = 10;
uint8 constant PROTOCOL_FIPA_CONTRACT_NET = 2;

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

abstract contract ManualCnReceived {
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

    function _received(bytes32 conversationId, uint8 act, uint64 replyBy, bytes calldata content)
        internal
    {
        emit Received(
            msg.sender,
            conversationId,
            bytes32(0),
            act,
            PROTOCOL_FIPA_CONTRACT_NET,
            bytes32(0),
            bytes32(0),
            replyBy,
            content
        );
    }

    function _receivedEmpty(bytes32 conversationId, uint8 act) internal {
        emit Received(
            msg.sender, conversationId, bytes32(0), act, PROTOCOL_FIPA_CONTRACT_NET, bytes32(0), bytes32(0), 0, ""
        );
    }
}

contract ManualManager is ManualCnReceived {
    struct Conversation {
        uint64 replyBy;
        bool evaluated;
        uint32 live;
        uint32 invited;
    }

    mapping(bytes32 conversationId => Conversation) internal _net;
    mapping(bytes32 conversationId => mapping(address participant => uint8 slot)) internal _slot;

    event ContractNetSlot(
        bytes32 indexed conversationId, address indexed participant, uint8 slot, uint8 performative
    );

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
            emit ContractNetSlot(conversationId, participants[i], CN_SLOT_INVITED, CN_ACT_CFP);
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
            emit ContractNetSlot(conversationId, reject[i], CN_SLOT_NONE, CN_ACT_REJECT);
        }
        for (uint256 i = 0; i < accept.length; i++) {
            _slot[conversationId][accept[i]] = CN_SLOT_ACCEPTED;
            emit ContractNetSlot(conversationId, accept[i], CN_SLOT_ACCEPTED, CN_ACT_ACCEPT);
        }
        _maybeClear(conversationId);
        for (uint256 i = 0; i < reject.length; i++) {
            IManualCnParticipant(reject[i]).onReject(conversationId);
        }
        for (uint256 i = 0; i < accept.length; i++) {
            IManualCnParticipant(accept[i]).onAccept(conversationId);
        }
    }

    function onPropose(bytes32 conversationId, bytes calldata content) external {
        Conversation storage c = _requireLive(conversationId);
        if (_slot[conversationId][msg.sender] != CN_SLOT_INVITED) {
            revert CnUnexpectedPeer();
        }
        _slot[conversationId][msg.sender] = CN_SLOT_PROPOSED;
        emit ContractNetSlot(conversationId, msg.sender, CN_SLOT_PROPOSED, CN_ACT_PROPOSE);
        _received(conversationId, CN_ACT_PROPOSE, c.replyBy, content);
    }

    function onRefuse(bytes32 conversationId) external {
        Conversation storage c = _requireLive(conversationId);
        if (_slot[conversationId][msg.sender] != CN_SLOT_INVITED) {
            revert CnInvalidTransition();
        }
        uint64 replyBy = c.replyBy;
        delete _slot[conversationId][msg.sender];
        c.live -= 1;
        emit ContractNetSlot(conversationId, msg.sender, CN_SLOT_NONE, CN_ACT_REFUSE);
        _maybeClear(conversationId);
        emit Received(
            msg.sender,
            conversationId,
            bytes32(0),
            CN_ACT_REFUSE,
            PROTOCOL_FIPA_CONTRACT_NET,
            bytes32(0),
            bytes32(0),
            replyBy,
            ""
        );
    }

    function onInform(bytes32 conversationId, bytes calldata content) external {
        _completeAccepted(conversationId, CN_ACT_INFORM);
        _received(conversationId, CN_ACT_INFORM, 0, content);
    }

    function onFailure(bytes32 conversationId, bytes calldata content) external {
        _completeAccepted(conversationId, CN_ACT_FAILURE);
        _received(conversationId, CN_ACT_FAILURE, 0, content);
    }

    function _completeAccepted(bytes32 conversationId, uint8 act) internal {
        Conversation storage c = _requireLive(conversationId);
        if (_slot[conversationId][msg.sender] != CN_SLOT_ACCEPTED) {
            revert CnInvalidTransition();
        }
        delete _slot[conversationId][msg.sender];
        c.live -= 1;
        emit ContractNetSlot(conversationId, msg.sender, CN_SLOT_NONE, act);
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

contract ManualCnParticipant is ManualCnReceived {
    struct Session {
        uint8 phase;
        address manager;
        uint64 replyBy;
    }

    mapping(bytes32 conversationId => Session) internal _cn;

    event ContractNetParticipantPhase(
        bytes32 indexed conversationId, uint8 phase, uint8 performative
    );

    function session(bytes32 conversationId) external view returns (Session memory) {
        return _cn[conversationId];
    }

    function onCfp(bytes32 conversationId, uint64 replyBy, bytes calldata content) external {
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
        emit ContractNetParticipantPhase(conversationId, CN_PART_CFPED, CN_ACT_CFP);
        _received(conversationId, CN_ACT_CFP, replyBy, content);
    }

    function propose(bytes32 conversationId, bytes calldata content) external {
        Session storage s = _cn[conversationId];
        if (s.phase != CN_PART_CFPED) {
            revert CnInvalidTransition();
        }
        address manager = s.manager;
        s.phase = CN_PART_PROPOSED;
        emit ContractNetParticipantPhase(conversationId, CN_PART_PROPOSED, CN_ACT_PROPOSE);
        IManualCnManager(manager).onPropose(conversationId, content);
    }

    function refuse(bytes32 conversationId) external {
        Session storage s = _cn[conversationId];
        if (s.phase != CN_PART_CFPED) {
            revert CnInvalidTransition();
        }
        address manager = s.manager;
        delete _cn[conversationId];
        emit ContractNetParticipantPhase(conversationId, CN_PART_NONE, CN_ACT_REFUSE);
        IManualCnManager(manager).onRefuse(conversationId);
    }

    function inform(bytes32 conversationId, bytes calldata content) external {
        Session storage s = _cn[conversationId];
        if (s.phase != CN_PART_ACCEPTED) {
            revert CnInvalidTransition();
        }
        address manager = s.manager;
        delete _cn[conversationId];
        emit ContractNetParticipantPhase(conversationId, CN_PART_NONE, CN_ACT_INFORM);
        IManualCnManager(manager).onInform(conversationId, content);
    }

    function failure(bytes32 conversationId, bytes calldata content) external {
        Session storage s = _cn[conversationId];
        if (s.phase != CN_PART_ACCEPTED) {
            revert CnInvalidTransition();
        }
        address manager = s.manager;
        delete _cn[conversationId];
        emit ContractNetParticipantPhase(conversationId, CN_PART_NONE, CN_ACT_FAILURE);
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
        emit ContractNetParticipantPhase(conversationId, CN_PART_ACCEPTED, CN_ACT_ACCEPT);
        _receivedEmpty(conversationId, CN_ACT_ACCEPT);
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
        emit ContractNetParticipantPhase(conversationId, CN_PART_NONE, CN_ACT_REJECT);
        _receivedEmpty(conversationId, CN_ACT_REJECT);
    }
}
// RQ3:END
