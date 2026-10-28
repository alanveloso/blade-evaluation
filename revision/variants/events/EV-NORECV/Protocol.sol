// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev FIPA interaction-protocol tokens as uint8. 0 = omitted.
enum Protocol {
    None,
    FipaRequest, // fipa-request
    FipaContractNet // fipa-contract-net
}
