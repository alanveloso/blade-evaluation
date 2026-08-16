// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// RQ3:PROTOCOL
import {Agent} from "blade/core/Agent.sol";
import {RequestAgent} from "blade/core/RequestAgent.sol";
import {Message} from "blade/core/Message.sol";
import {Performative} from "blade/core/Performative.sol";
import {Protocol} from "blade/core/Protocol.sol";

/// @dev Population B: thin native wrapper. Protocol machine stays in Core (population A).
contract BladeRequester is RequestAgent {
    constructor() Agent(address(0)) {}

    function startRequest(address participant, bytes32 conversationId, bytes calldata content)
        external
    {
        Message memory outbound;
        outbound.performative = uint8(Performative.Request);
        outbound.protocol = uint8(Protocol.FipaRequest);
        outbound.conversationId = conversationId;
        // RQ3:POLICY
        outbound.content = content;
        // RQ3:END
        _startRequest(participant, outbound);
    }
}

contract BladeParticipant is RequestAgent {
    constructor() Agent(address(0)) {}

    function refuse(Message calldata inbound, address to, bytes calldata content) external {
        _reply(inbound, to, _out(inbound, uint8(Performative.Refuse), content));
    }

    function inform(Message calldata inbound, address to, bytes calldata content) external {
        _reply(inbound, to, _out(inbound, uint8(Performative.Inform), content));
    }

    function agree(Message calldata inbound, address to) external {
        _reply(inbound, to, _out(inbound, uint8(Performative.Agree), ""));
    }

    function failure(Message calldata inbound, address to, bytes calldata content) external {
        _reply(inbound, to, _out(inbound, uint8(Performative.Failure), content));
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
        outbound.content = content;
    }
}
// RQ3:END
