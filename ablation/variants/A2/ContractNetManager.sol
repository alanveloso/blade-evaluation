// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Agent} from "./Agent.sol";
import {ContractNetLib} from "./ContractNetLib.sol";
import {Message} from "./Message.sol";
import {Performative} from "./Performative.sol";
import {Protocol} from "./Protocol.sol";

/// @title Manager role for the supported FIPA Contract Net interaction subset.
/// @dev Does not store a full `Message` or `content`. Abstract: the leaf calls `Agent` once.
abstract contract ContractNetManager is Agent {
    /// @dev Root record. Slots: conversationId => participant => Invited|Proposed|Accepted.
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

    /// @dev Explicit 1:N CFP. Same `conversationId` on every `handle`. Application decision primitive.
    /// Duplicate detection reuses the per-participant mapping instead of an O(N^2) array scan.
    function _cfp(address[] calldata participants, Message memory message) internal {
        ContractNetLib.requireCfp(message);
        uint256 n = participants.length;
        if (n == 0) {
            revert ContractNetLib.EmptyParticipants();
        }
        Conversation storage c = _net[message.conversationId];
        if (c.invited != 0 || c.live != 0) {
            revert ContractNetLib.InvalidTransition();
        }

        // Validate and stage membership in one O(N) pass. Any later revert rolls back all slots/events.
        for (uint256 i = 0; i < n; i++) {
            address p = participants[i];
            if (p == address(0) || p.code.length == 0) {
                revert ContractNetLib.InvalidParticipant(p);
            }
            if (_slot[message.conversationId][p] != ContractNetLib.SLOT_NONE) {
                revert ContractNetLib.DuplicateParticipant();
            }
            _slot[message.conversationId][p] = ContractNetLib.SLOT_INVITED;
            emit ContractNetSlot(
                message.conversationId, p, ContractNetLib.SLOT_INVITED, uint8(Performative.Cfp)
            );
        }

        c.replyBy = message.replyBy;
        c.evaluated = false;
        c.live = uint32(n);
        c.invited = uint32(n);

        for (uint256 i = 0; i < n; i++) {
            _send(participants[i], message);
        }
    }

    /// @dev Tx-triggered finalization after `replyBy`. CEI: all checks/effects, then participant `handle`s.
    /// Duplicate/overlap detection is implicit in state transitions, avoiding O(N^2) list scans.
    function _evaluate(
        bytes32 conversationId,
        address[] calldata accept,
        address[] calldata reject,
        address[] calldata silent
    ) internal {
        Conversation storage c = _net[conversationId];
        if (c.invited == 0 && c.live == 0) {
            revert ContractNetLib.InvalidTransition();
        }
        if (c.evaluated) {
            revert ContractNetLib.InvalidTransition();
        }
        ContractNetLib.requireWindowClosed(c.replyBy);

        if (accept.length + reject.length + silent.length != c.live) {
            revert ContractNetLib.IncompleteEvaluation();
        }

        // Mutating while validating makes duplicates and overlaps fail naturally: a second occurrence
        // no longer has the required pre-evaluation slot. Reverts restore the entire transaction.
        for (uint256 i = 0; i < silent.length; i++) {
            address p = silent[i];
            if (_slot[conversationId][p] != ContractNetLib.SLOT_INVITED) {
                revert ContractNetLib.InvalidTransition();
            }
            delete _slot[conversationId][p];
        }
        for (uint256 i = 0; i < reject.length; i++) {
            address p = reject[i];
            if (_slot[conversationId][p] != ContractNetLib.SLOT_PROPOSED) {
                revert ContractNetLib.InvalidTransition();
            }
            delete _slot[conversationId][p];
            emit ContractNetSlot(
                conversationId, p, ContractNetLib.SLOT_NONE, uint8(Performative.RejectProposal)
            );
        }
        for (uint256 i = 0; i < accept.length; i++) {
            address p = accept[i];
            if (_slot[conversationId][p] != ContractNetLib.SLOT_PROPOSED) {
                revert ContractNetLib.InvalidTransition();
            }
            _slot[conversationId][p] = ContractNetLib.SLOT_ACCEPTED;
            emit ContractNetSlot(
                conversationId, p, ContractNetLib.SLOT_ACCEPTED, uint8(Performative.AcceptProposal)
            );
        }

        // One logical live-count update instead of one storage write per rejected/silent participant.
        uint32 accepted = uint32(accept.length);
        if (c.live != accepted) {
            c.live = accepted;
        }
        c.evaluated = true;
        _maybeClear(conversationId);

        for (uint256 i = 0; i < reject.length; i++) {
            // The CFP deadline governs proposal collection; it is not copied into the later
            // accept/reject decision message.
            _send(reject[i], _act(conversationId, uint8(Performative.RejectProposal), 0));
        }
        for (uint256 i = 0; i < accept.length; i++) {
            _send(accept[i], _act(conversationId, uint8(Performative.AcceptProposal), 0));
        }
    }

    /// @dev True when this agent has a live manager conversation for `conversationId`.
    function _handleContractNetManagerInbound(Message calldata message) internal returns (bool) {
        if (message.protocol != uint8(Protocol.FipaContractNet)) {
            return false;
        }
        Conversation storage c = _net[message.conversationId];
        if (c.invited == 0 && c.live == 0) {
            return false;
        }
        if (message.logicalSender != bytes32(0)) {
            revert ContractNetLib.UnexpectedPeer();
        }
        uint8 slot = _slot[message.conversationId][msg.sender];
        if (slot == ContractNetLib.SLOT_NONE) {
            revert ContractNetLib.UnexpectedPeer();
        }
        Performative act = Performative(message.performative);
        if (act == Performative.Propose) {
            if (slot != ContractNetLib.SLOT_INVITED) {
                revert ContractNetLib.UnexpectedPeer();
            }
            if (ContractNetLib.isLate(c.replyBy)) {
                delete _slot[message.conversationId][msg.sender];
                c.live -= 1;
                emit ContractNetSlot(
                    message.conversationId,
                    msg.sender,
                    ContractNetLib.SLOT_NONE,
                    uint8(Performative.RejectProposal)
                );
                _send(
                    msg.sender, _act(message.conversationId, uint8(Performative.RejectProposal), 0)
                );
                _maybeClear(message.conversationId);
                return true;
            }
            _slot[message.conversationId][msg.sender] = ContractNetLib.SLOT_PROPOSED;
            emit ContractNetSlot(
                message.conversationId,
                msg.sender,
                ContractNetLib.SLOT_PROPOSED,
                uint8(Performative.Propose)
            );
            return true;
        }
        if (act == Performative.Refuse) {
            if (slot != ContractNetLib.SLOT_INVITED) {
                revert ContractNetLib.InvalidTransition();
            }
            delete _slot[message.conversationId][msg.sender];
            c.live -= 1;
            emit ContractNetSlot(
                message.conversationId,
                msg.sender,
                ContractNetLib.SLOT_NONE,
                uint8(Performative.Refuse)
            );
            _maybeClear(message.conversationId);
            return true;
        }
        if (act == Performative.NotUnderstood) {
            delete _slot[message.conversationId][msg.sender];
            c.live -= 1;
            emit ContractNetSlot(
                message.conversationId,
                msg.sender,
                ContractNetLib.SLOT_NONE,
                uint8(Performative.NotUnderstood)
            );
            _maybeClear(message.conversationId);
            return true;
        }
        if (act == Performative.Inform || act == Performative.Failure) {
            if (slot != ContractNetLib.SLOT_ACCEPTED) {
                revert ContractNetLib.InvalidTransition();
            }
            delete _slot[message.conversationId][msg.sender];
            c.live -= 1;
            emit ContractNetSlot(
                message.conversationId, msg.sender, ContractNetLib.SLOT_NONE, uint8(act)
            );
            _maybeClear(message.conversationId);
            return true;
        }
        revert ContractNetLib.InvalidTransition();
    }

    function _onInbound(Message calldata message) internal virtual override {
        if (message.protocol == uint8(Protocol.FipaContractNet)) {
            if (!_handleContractNetManagerInbound(message)) {
                revert ContractNetLib.InvalidTransition();
            }
            return;
        }
        super._onInbound(message);
    }

    function _maybeClear(bytes32 conversationId) internal {
        Conversation storage c = _net[conversationId];
        if (c.live != 0) {
            return;
        }
        delete _net[conversationId];
    }

    function _act(bytes32 conversationId, uint8 performative, uint64 replyBy)
        internal
        pure
        returns (Message memory m)
    {
        m.performative = performative;
        m.protocol = uint8(Protocol.FipaContractNet);
        m.conversationId = conversationId;
        m.replyBy = replyBy;
    }
}
