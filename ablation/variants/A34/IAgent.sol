// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Message} from "./Message.sol";

/// @notice Inbound compact ACL. Transport sender is `msg.sender`; this contract is the receiver.
interface IAgent {
    function handle(Message calldata message) external;
}
