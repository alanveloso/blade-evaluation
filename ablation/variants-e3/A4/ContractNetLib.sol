// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Message} from "./Message.sol";
import {Performative} from "./Performative.sol";
import {Protocol} from "./Protocol.sol";

/// @dev Shared Contract Net checks. Not a multi-agent router.
library ContractNetLib {
    error InvalidCfp();
    error EmptyParticipants();
    error DuplicateParticipant();
    error DuplicateEvaluateEntry();
    error OverlappingEvaluateLists();
    error EvaluationTooEarly();
    error IncompleteEvaluation();
    error InvalidTransition();
    error UnexpectedPeer();
    error ReplyByRequired();
    error InvalidParticipant(address participant);

    uint8 internal constant SLOT_NONE = 0;
    uint8 internal constant SLOT_INVITED = 1;
    uint8 internal constant SLOT_PROPOSED = 2;
    uint8 internal constant SLOT_ACCEPTED = 3;

    uint8 internal constant PART_NONE = 0;
    uint8 internal constant PART_CFPED = 1;
    uint8 internal constant PART_PROPOSED = 2;
    uint8 internal constant PART_ACCEPTED = 3;

    /// @dev Field-only CFP validation is usable from calldata without copying dynamic `content`.
    function requireCfpFields(
        uint8 protocol,
        uint8 performative,
        bytes32 conversationId,
        uint64 replyBy
    ) internal pure {
        if (protocol != uint8(Protocol.FipaContractNet)) {
            revert InvalidCfp();
        }
        if (performative != uint8(Performative.Cfp)) {
            revert InvalidCfp();
        }
        if (conversationId == bytes32(0)) {
            revert InvalidCfp();
        }
        if (replyBy == 0) {
            revert ReplyByRequired();
        }
    }

    function requireCfp(Message memory m) internal pure {
        requireCfpFields(m.protocol, m.performative, m.conversationId, m.replyBy);
    }

    function isLate(uint64 replyBy) internal view returns (bool) {
        return block.timestamp > replyBy;
    }

    function requireWindowClosed(uint64 replyBy) internal view {
        if (!isLate(replyBy)) {
            revert EvaluationTooEarly();
        }
    }
}
