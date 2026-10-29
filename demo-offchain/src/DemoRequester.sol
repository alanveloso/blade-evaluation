// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Agent} from "blade/core/Agent.sol";
import {RequestAgent} from "blade/core/RequestAgent.sol";
import {Message} from "blade/core/Message.sol";
import {Performative} from "blade/core/Performative.sol";
import {Protocol} from "blade/core/Protocol.sol";

/// @title Off-chain initiator wrapper. Does not decide for the peer and does not auto-reply.
/// @dev Protocol FSM, correlation and peer checks stay in `RequestAgent`. This contract only
///      exposes `request` to its operator and records inbound terminal acts for observation.
contract DemoRequester is RequestAgent {
    struct Outcome {
        bool present;
        uint8 performative;
        bytes32 correlation;
        uint64 blockNumber;
        bytes content;
    }

    address public immutable operator;
    mapping(bytes32 conversationId => Outcome) private _outcomes;

    error NotOperator();
    error ZeroOperator();

    event ResultObserved(
        bytes32 indexed conversationId,
        uint8 performative,
        bytes32 correlation,
        uint64 blockNumber,
        bytes content
    );

    constructor(address operator_) Agent(address(0)) {
        if (operator_ == address(0)) revert ZeroOperator();
        operator = operator_;
    }

    function outcomes(bytes32 conversationId) external view returns (Outcome memory) {
        return _outcomes[conversationId];
    }

    function request(address participant, bytes32 conversationId, bytes calldata content) external {
        if (msg.sender != operator) revert NotOperator();
        delete _outcomes[conversationId];
        Message memory outbound;
        outbound.performative = uint8(Performative.Request);
        outbound.protocol = uint8(Protocol.FipaRequest);
        outbound.conversationId = conversationId;
        outbound.content = content;
        _startRequest(participant, outbound);
    }

    /// @dev Record the peer's terminal act. Never replies from this hook.
    function _onReceive(Message calldata inbound) internal override {
        if (inbound.performative == uint8(Performative.Request)) {
            return;
        }
        _outcomes[inbound.conversationId] = Outcome({
            present: true,
            performative: inbound.performative,
            correlation: inbound.inReplyTo,
            blockNumber: uint64(block.number),
            content: inbound.content
        });
        emit ResultObserved(
            inbound.conversationId,
            inbound.performative,
            inbound.inReplyTo,
            uint64(block.number),
            inbound.content
        );
    }
}
