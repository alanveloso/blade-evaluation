// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Selected FIPA communicative-act tokens as uint8. No `call-for-proposal` alias.
enum Performative {
    Request, // request
    Agree, // agree
    Refuse, // refuse
    Failure, // failure
    Inform, // inform
    NotUnderstood, // not-understood
    Cancel, // cancel
    Cfp, // cfp
    Propose, // propose
    AcceptProposal, // accept-proposal
    RejectProposal // reject-proposal
}
