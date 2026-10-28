// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Agent} from "./Agent.sol";
import {ContractNetLib} from "./ContractNetLib.sol";
import {Message} from "./Message.sol";
import {Performative} from "./Performative.sol";
import {Protocol} from "./Protocol.sol";

/// @title Participant role for the supported FIPA Contract Net interaction subset.
/// @dev Abstract: the leaf calls `Agent` once.
abstract contract ContractNetParticipant is Agent {
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

    /// @dev True when this capability owns the inbound CN message (new CFP or live participant session).
    function _handleContractNetParticipantInbound(Message calldata message)
        internal
        returns (bool)
    {
        if (message.protocol != uint8(Protocol.FipaContractNet)) {
            return false;
        }
        Session storage s = _cn[message.conversationId];
        Performative act = Performative(message.performative);
        if (s.phase == ContractNetLib.PART_NONE) {
            if (act != Performative.Cfp) {
                return false;
            }
            ContractNetLib.requireCfpFields(
                message.protocol, message.performative, message.conversationId, message.replyBy
            );
            s.phase = ContractNetLib.PART_CFPED;
            s.manager = msg.sender;
            s.replyBy = message.replyBy;
            emit ContractNetParticipantPhase(message.conversationId, s.phase, message.performative);
            return true;
        }
        if (msg.sender != s.manager || message.logicalSender != bytes32(0)) {
            revert ContractNetLib.UnexpectedPeer();
        }
        if (act == Performative.AcceptProposal) {
            if (s.phase != ContractNetLib.PART_PROPOSED) {
                revert ContractNetLib.InvalidTransition();
            }
            s.phase = ContractNetLib.PART_ACCEPTED;
            emit ContractNetParticipantPhase(message.conversationId, s.phase, message.performative);
            return true;
        }
        if (act == Performative.RejectProposal) {
            if (s.phase != ContractNetLib.PART_PROPOSED) {
                revert ContractNetLib.InvalidTransition();
            }
            delete _cn[message.conversationId];
            emit ContractNetParticipantPhase(
                message.conversationId, ContractNetLib.PART_NONE, message.performative
            );
            return true;
        }
        if (act == Performative.NotUnderstood) {
            delete _cn[message.conversationId];
            emit ContractNetParticipantPhase(
                message.conversationId, ContractNetLib.PART_NONE, message.performative
            );
            return true;
        }
        revert ContractNetLib.InvalidTransition();
    }

    /// @dev True when outbound is a CN participant continuation this capability must validate.
    function _handleContractNetParticipantReply(
        Message calldata,
        address to,
        Message memory outbound
    ) internal returns (bool) {
        if (outbound.protocol != uint8(Protocol.FipaContractNet)) {
            return false;
        }
        Session storage s = _cn[outbound.conversationId];
        if (s.phase == ContractNetLib.PART_NONE) {
            revert ContractNetLib.InvalidTransition();
        }
        if (to != s.manager) {
            revert ContractNetLib.UnexpectedPeer();
        }
        Performative act = Performative(outbound.performative);
        if (act == Performative.Propose) {
            if (s.phase != ContractNetLib.PART_CFPED) {
                revert ContractNetLib.InvalidTransition();
            }
            s.phase = ContractNetLib.PART_PROPOSED;
        } else if (act == Performative.Refuse) {
            if (s.phase != ContractNetLib.PART_CFPED) {
                revert ContractNetLib.InvalidTransition();
            }
            delete _cn[outbound.conversationId];
        } else if (act == Performative.NotUnderstood) {
            delete _cn[outbound.conversationId];
        } else if (act == Performative.Inform || act == Performative.Failure) {
            if (s.phase != ContractNetLib.PART_ACCEPTED) {
                revert ContractNetLib.InvalidTransition();
            }
            delete _cn[outbound.conversationId];
        } else {
            revert ContractNetLib.InvalidTransition();
        }
        emit ContractNetParticipantPhase(
            outbound.conversationId, _cn[outbound.conversationId].phase, outbound.performative
        );
        return true;
    }

    function _onInbound(Message calldata message) internal virtual override {
        if (message.protocol == uint8(Protocol.FipaContractNet)) {
            if (!_handleContractNetParticipantInbound(message)) {
                ContractNetLib.requireCfpFields(
                    message.protocol, message.performative, message.conversationId, message.replyBy
                );
            }
            return;
        }
        super._onInbound(message);
    }

    function _reply(Message calldata inbound, address to, Message memory outbound)
        internal
        virtual
        override
    {
        _handleContractNetParticipantReply(inbound, to, outbound);
        super._reply(inbound, to, outbound);
    }

    /// @dev Permissionless housekeeping. Not a FIPA act. Deletes expired CFPED only.
    function expire(bytes32 conversationId) external {
        Session storage s = _cn[conversationId];
        if (s.phase != ContractNetLib.PART_CFPED) {
            revert ContractNetLib.InvalidTransition();
        }
        if (!ContractNetLib.isLate(s.replyBy)) {
            revert ContractNetLib.InvalidTransition();
        }
        delete _cn[conversationId];
    }

    function _respond(Message calldata inbound, address to, Message memory outbound) internal {
        _reply(inbound, to, outbound);
    }
}
