// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Agent} from "./Agent.sol";
import {Message} from "./Message.sol";
import {Protocol} from "./Protocol.sol";
import {Performative} from "./Performative.sol";

enum SubscribePhase {
    None,
    Pending,
    Active,
    Cancelling
}

/// @notice Experimental native FIPA Subscribe subset, with optional Agree and correlated cancel acknowledgement.
/// @dev Application controls authorization, notification triggers and content. No timers/scheduling.
/// Cancel is acknowledged by Inform (done); Failure restores the phase before cancellation. No relay support in this subset.
abstract contract SubscribeAgent is Agent {
    struct Subscription {
        SubscribePhase phase;
        bool initiator;
        address peer;
        bytes32 token;
        SubscribePhase resumePhase;
        bytes32 cancelToken;
    }
    mapping(bytes32 => Subscription) internal _subscriptions;
    uint256 private _subscribeNonce;
    error InvalidSubscription();
    error SubscriptionPeer();
    error SubscriptionToken();
    event SubscriptionAdvanced(bytes32 indexed id, SubscribePhase phase, uint8 act);

    function subscription(bytes32 id) external view returns (Subscription memory) {
        return _subscriptions[id];
    }

    function _startSubscribe(address peer, bytes32 id, bytes memory content) internal {
        if (_subscriptions[id].phase != SubscribePhase.None || peer.code.length == 0) {
            revert InvalidSubscription();
        }
        bytes32 token = keccak256(abi.encode(block.chainid, address(this), id, ++_subscribeNonce));
        _subscriptions[id] = Subscription(
            SubscribePhase.Pending, true, peer, token, SubscribePhase.None, bytes32(0)
        );
        Message memory m = _subscriptionMessage(id, Performative.Subscribe, content);
        emit SubscriptionAdvanced(id, SubscribePhase.Pending, m.performative);
        _send(peer, m);
    }

    /// @dev Continuations are constructed from stored peer/token, never caller-supplied envelopes.
    function _subscriptionAct(bytes32 id, Performative act, bytes memory content) internal {
        Subscription memory s = _subscriptions[id];
        if (act == Performative.Cancel) {
            _subscriptions[id].cancelToken =
                keccak256(abi.encode(block.chainid, address(this), id, ++_subscribeNonce));
        }
        Message memory m = _subscriptionMessage(id, act, content);
        _advanceSubscription(id, s.initiator, act);
        _send(s.peer, m);
    }

    function _subscriptionMessage(bytes32 id, Performative act, bytes memory content)
        private
        view
        returns (Message memory m)
    {
        Subscription storage s = _subscriptions[id];
        m.protocol = uint8(Protocol.FipaSubscribe);
        m.performative = uint8(act);
        m.conversationId = id;
        bytes32 correlation = s.phase == SubscribePhase.Cancelling ? s.cancelToken : s.token;
        if (act == Performative.Cancel) {
            m.replyWith = s.cancelToken;
            m.inReplyTo = s.token;
        } else if (s.initiator) {
            m.replyWith = correlation;
        } else {
            m.inReplyTo = correlation;
        }
        m.content = content;
    }

    function _onInbound(Message calldata m) internal virtual override {
        if (m.protocol != uint8(Protocol.FipaSubscribe)) {
            super._onInbound(m);
            return;
        }
        if (m.logicalSender != bytes32(0)) revert SubscriptionPeer();
        Subscription storage s = _subscriptions[m.conversationId];
        if (s.phase == SubscribePhase.None) {
            if (m.performative != uint8(Performative.Subscribe)) revert InvalidSubscription();
            if (m.replyWith == bytes32(0)) revert SubscriptionToken();
            _subscriptions[m.conversationId] = Subscription(
                SubscribePhase.Pending,
                false,
                msg.sender,
                m.replyWith,
                SubscribePhase.None,
                bytes32(0)
            );
            emit SubscriptionAdvanced(m.conversationId, SubscribePhase.Pending, m.performative);
            return;
        }
        if (msg.sender != s.peer) revert SubscriptionPeer();
        if (!s.initiator && m.performative == uint8(Performative.Cancel)) {
            if (m.inReplyTo != s.token || m.replyWith == bytes32(0) || m.replyWith == s.token) {
                revert SubscriptionToken();
            }
            s.cancelToken = m.replyWith;
        } else {
            bytes32 correlation = s.phase == SubscribePhase.Cancelling ? s.cancelToken : s.token;
            if ((s.initiator ? m.inReplyTo : m.replyWith) != correlation) {
                revert SubscriptionToken();
            }
        }
        _advanceSubscription(m.conversationId, !s.initiator, Performative(m.performative));
    }

    function _advanceSubscription(bytes32 id, bool fromInitiator, Performative act) private {
        Subscription storage s = _subscriptions[id];
        SubscribePhase next = s.phase;
        if (next == SubscribePhase.None) revert InvalidSubscription();
        if (act == Performative.NotUnderstood) {
            next = SubscribePhase.None;
        } else if (fromInitiator) {
            if (
                act != Performative.Cancel
                    || (next != SubscribePhase.Active && next != SubscribePhase.Pending)
            ) {
                revert InvalidSubscription();
            }
            s.resumePhase = next;
            next = SubscribePhase.Cancelling;
        } else if (next == SubscribePhase.Pending) {
            if (act == Performative.Agree || act == Performative.Inform) {
                next = SubscribePhase.Active;
            } else if (act == Performative.Refuse || act == Performative.Failure) {
                next = SubscribePhase.None;
            } else {
                revert InvalidSubscription();
            }
        } else if (next == SubscribePhase.Active) {
            if (act == Performative.Failure) next = SubscribePhase.None;
            else if (act != Performative.Inform) revert InvalidSubscription();
        } else {
            if (act == Performative.Inform) {
                next = SubscribePhase.None;
            } else if (act == Performative.Failure) {
                next = s.resumePhase;
                s.resumePhase = SubscribePhase.None;
                s.cancelToken = bytes32(0);
            } else {
                revert InvalidSubscription();
            }
        }
        if (next == SubscribePhase.None) delete _subscriptions[id];
        else s.phase = next;
        emit SubscriptionAdvanced(id, next, uint8(act));
    }
}
