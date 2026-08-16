// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// RQ3:PROTOCOL
import {ContractNetManager} from "blade/core/ContractNetManager.sol";
import {ContractNetParticipant} from "blade/core/ContractNetParticipant.sol";
import {Message} from "blade/core/Message.sol";
import {Performative} from "blade/core/Performative.sol";
import {Protocol} from "blade/core/Protocol.sol";

contract BladeManager is ContractNetManager {
    constructor() ContractNetManager(address(0)) {}

    function cfp(
        address[] calldata participants,
        bytes32 conversationId,
        uint64 replyBy,
        bytes calldata content
    ) external {
        Message memory message;
        message.performative = uint8(Performative.Cfp);
        message.protocol = uint8(Protocol.FipaContractNet);
        message.conversationId = conversationId;
        message.replyBy = replyBy;
        // RQ3:POLICY
        message.content = content;
        // RQ3:END
        _cfp(participants, message);
    }

    function evaluate(
        bytes32 conversationId,
        address[] calldata accept,
        address[] calldata reject,
        address[] calldata silent
    ) external {
        _evaluate(conversationId, accept, reject, silent);
    }
}

contract BladeCnParticipant is ContractNetParticipant {
    constructor() ContractNetParticipant(address(0)) {}

    function propose(Message calldata inbound, address manager, bytes calldata content) external {
        _respond(inbound, manager, _out(inbound, uint8(Performative.Propose), content));
    }

    function refuse(Message calldata inbound, address manager) external {
        _respond(inbound, manager, _out(inbound, uint8(Performative.Refuse), ""));
    }

    function inform(Message calldata inbound, address manager, bytes calldata content) external {
        _respond(inbound, manager, _out(inbound, uint8(Performative.Inform), content));
    }

    function failure(Message calldata inbound, address manager, bytes calldata content) external {
        _respond(inbound, manager, _out(inbound, uint8(Performative.Failure), content));
    }

    function _out(Message calldata inbound, uint8 act, bytes memory content)
        internal
        pure
        returns (Message memory outbound)
    {
        outbound.performative = act;
        outbound.protocol = inbound.protocol;
        outbound.conversationId = inbound.conversationId;
        outbound.inReplyTo = inbound.replyWith;
        outbound.replyBy = inbound.replyBy;
        outbound.content = content;
    }
}
// RQ3:END
