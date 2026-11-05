#!/usr/bin/env python3
"""Build ablation/variants-e3 from the E3 BLADE checkout (A0 == src/core) + factor ports.

Usage:
  export BLADE_REPO=../blade   # optional; defaults to sibling blade or outputs/cores/<E3_SHA>
  python3 revision/scripts/generate_ablation_e3.py
"""
from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
E3_SHA = "f9ebfd36937abe66b35496ead25aa980e3c4b527"
OUT = ROOT / "ablation" / "variants-e3"


def e3_core() -> Path:
    env = os.environ.get("BLADE_REPO")
    if env:
        p = Path(env).resolve() / "src" / "core"
        if p.is_dir():
            return p
    cached = ROOT / "outputs" / "cores" / E3_SHA / "src" / "core"
    if cached.is_dir():
        return cached
    sys.exit(f"E3 core not found (set BLADE_REPO or populate outputs/cores/{E3_SHA})")


def patch_a1_agent(text: str) -> str:
    pat = re.compile(
        r"    /// @dev Internal native delivery.*?\n"
        r"    /// The peer still observes.*?\n"
        r"(?:    /// is an external call.*?\n)?"
        r"    function _send\(address to, Message memory message\) internal virtual \{\n"
        r"        if \(message\.logicalSender != bytes32\(0\)\) \{\n"
        r"            revert UnauthorizedLogicalSender\(\);\n"
        r"        \}\n"
        r"        MessageLib\.validateFields\(message\.protocol, message\.conversationId\);\n"
        r"        IAgent\(to\)\.handle\(message\);\n"
        r"    \}",
        re.S,
    )
    new = """    error DispatchNotInternal();

    /// @dev Ablation A1: restore an external self-call before peer `handle`.
    /// The peer still observes this contract as `msg.sender`.
    function _send(address to, Message memory message) internal virtual {
        if (message.logicalSender != bytes32(0)) {
            revert UnauthorizedLogicalSender();
        }
        MessageLib.validateFields(message.protocol, message.conversationId);
        this._dispatch(to, message);
    }

    function _dispatch(address to, Message memory message) external {
        if (msg.sender != address(this)) {
            revert DispatchNotInternal();
        }
        IAgent(to).handle(message);
    }"""
    text2, n = pat.subn(new, text, count=1)
    if n != 1:
        sys.exit(f"A1 Agent patch failed (n={n})")
    return text2


def patch_a2_agent_handle(text: str) -> str:
    old = """    function handle(Message calldata message) external {
        MessageLib.validateFields(message.protocol, message.conversationId);
        _authenticate(message);"""
    new = """    function handle(Message calldata message) external {
        // Ablation A2: copy full calldata Message (including dynamic content) into memory for validation.
        Message memory copied = message;
        MessageLib.validate(copied);
        _authenticate(message);"""
    if old not in text:
        sys.exit("A2 Agent handle patch failed")
    return text.replace(old, new, 1)


def patch_a2_participant(text: str) -> str:
    old = """            ContractNetLib.requireCfpFields(
                message.protocol, message.performative, message.conversationId, message.replyBy
            );"""
    new = """            {
                Message memory copied = message;
                ContractNetLib.requireCfp(copied);
            }"""
    if old not in text:
        sys.exit("A2 participant patch failed")
    return text.replace(old, new, 1)


def patch_a3_lib(text: str) -> str:
    if "requireNoDuplicates" in text:
        return text
    addon = """
    function requireNoDuplicates(address[] calldata a) internal pure {
        uint256 n = a.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (a[i] == a[j]) {
                    revert DuplicateEvaluateEntry();
                }
            }
        }
    }

    function contains(address[] calldata a, address x) internal pure returns (bool) {
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] == x) {
                return true;
            }
        }
        return false;
    }

    function requireDisjoint(address[] calldata a, address[] calldata b) internal pure {
        for (uint256 i = 0; i < a.length; i++) {
            if (contains(b, a[i])) {
                revert OverlappingEvaluateLists();
            }
        }
    }
"""
    idx = text.rstrip().rfind("}")
    return text.rstrip()[:idx] + addon + "}\n"


def patch_a3_manager(text: str) -> str:
    old_cfp = """        // Validate and stage membership in one O(N) pass. Any later revert rolls back all slots/events.
        for (uint256 i = 0; i < n; i++) {
            address p = participants[i];
            if (p == address(0) || p.code.length == 0) {
                revert ContractNetLib.InvalidParticipant(p);
            }
            if (_slot[conversationId][p] != ContractNetLib.SLOT_NONE) {
                revert ContractNetLib.DuplicateParticipant();
            }
            _slot[conversationId][p] = ContractNetLib.SLOT_INVITED;
            emit ContractNetSlot(
                conversationId, p, ContractNetLib.SLOT_INVITED, uint8(Performative.Cfp)
            );
        }"""
    new_cfp = """        // Ablation A3: historical nested duplicate scan, then slot staging.
        for (uint256 i = 0; i < n; i++) {
            address p = participants[i];
            if (p == address(0) || p.code.length == 0) {
                revert ContractNetLib.InvalidParticipant(p);
            }
            for (uint256 j = 0; j < i; j++) {
                if (participants[j] == p) {
                    revert ContractNetLib.DuplicateParticipant();
                }
            }
        }
        for (uint256 i = 0; i < n; i++) {
            address p = participants[i];
            _slot[conversationId][p] = ContractNetLib.SLOT_INVITED;
            emit ContractNetSlot(
                conversationId, p, ContractNetLib.SLOT_INVITED, uint8(Performative.Cfp)
            );
        }"""
    if old_cfp not in text:
        sys.exit("A3 manager cfp patch failed")
    text = text.replace(old_cfp, new_cfp, 1)
    old_ev = """        ContractNetLib.requireWindowClosed(c.replyBy);

        if (accept.length + reject.length + silent.length != c.live) {
            revert ContractNetLib.IncompleteEvaluation();
        }

        // Mutating while validating makes duplicates and overlaps fail naturally: a second occurrence
        // no longer has the required pre-evaluation slot. Reverts restore the entire transaction.
        for (uint256 i = 0; i < silent.length; i++) {"""
    new_ev = """        ContractNetLib.requireWindowClosed(c.replyBy);

        ContractNetLib.requireNoDuplicates(accept);
        ContractNetLib.requireNoDuplicates(reject);
        ContractNetLib.requireNoDuplicates(silent);
        ContractNetLib.requireDisjoint(accept, reject);
        ContractNetLib.requireDisjoint(accept, silent);
        ContractNetLib.requireDisjoint(reject, silent);

        if (accept.length + reject.length + silent.length != c.live) {
            revert ContractNetLib.IncompleteEvaluation();
        }

        for (uint256 i = 0; i < silent.length; i++) {"""
    if old_ev not in text:
        sys.exit("A3 manager evaluate patch failed")
    return text.replace(old_ev, new_ev, 1)


def patch_a4_manager(text: str) -> str:
    old = """        // One logical live-count update instead of one storage write per rejected/silent participant.
        uint32 accepted = uint32(accept.length);
        if (c.live != accepted) {
            c.live = accepted;
        }
        c.evaluated = true;
        _maybeClear(conversationId);"""
    if old not in text:
        old = """        uint32 accepted = uint32(accept.length);
        if (c.live != accepted) {
            c.live = accepted;
        }
        c.evaluated = true;
        _maybeClear(conversationId);"""
        if old not in text:
            sys.exit("A4 manager patch anchor not found")
    new = """        // Ablation A4: one live -= 1 write per rejected/silent participant.
        c.evaluated = true;
        for (uint256 i = 0; i < silent.length; i++) {
            c.live -= 1;
        }
        for (uint256 i = 0; i < reject.length; i++) {
            c.live -= 1;
        }
        _maybeClear(conversationId);"""
    return text.replace(old, new, 1)


def main() -> None:
    core = e3_core()
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    a0 = OUT / "A0"
    a0.mkdir()
    for f in sorted(core.glob("*.sol")):
        shutil.copyfile(f, a0 / f.name)

    def copy_a0(name: str) -> Path:
        d = OUT / name
        d.mkdir()
        for f in a0.glob("*.sol"):
            shutil.copyfile(f, d / f.name)
        return d

    d = copy_a0("A1")
    (d / "Agent.sol").write_text(patch_a1_agent((d / "Agent.sol").read_text()))

    d = copy_a0("A2")
    (d / "Agent.sol").write_text(patch_a2_agent_handle((d / "Agent.sol").read_text()))
    (d / "ContractNetParticipant.sol").write_text(
        patch_a2_participant((d / "ContractNetParticipant.sol").read_text())
    )

    d = copy_a0("A3")
    (d / "ContractNetLib.sol").write_text(patch_a3_lib((d / "ContractNetLib.sol").read_text()))
    (d / "ContractNetManager.sol").write_text(
        patch_a3_manager((d / "ContractNetManager.sol").read_text())
    )

    d = copy_a0("A4")
    (d / "ContractNetManager.sol").write_text(
        patch_a4_manager((d / "ContractNetManager.sol").read_text())
    )

    d = copy_a0("A5")
    t = patch_a2_agent_handle((d / "Agent.sol").read_text())
    (d / "Agent.sol").write_text(patch_a1_agent(t))
    (d / "ContractNetParticipant.sol").write_text(
        patch_a2_participant((d / "ContractNetParticipant.sol").read_text())
    )
    (d / "ContractNetLib.sol").write_text(patch_a3_lib((d / "ContractNetLib.sol").read_text()))
    mgr = patch_a4_manager(patch_a3_manager((d / "ContractNetManager.sol").read_text()))
    (d / "ContractNetManager.sol").write_text(mgr)

    d = copy_a0("A34")
    (d / "ContractNetLib.sol").write_text(patch_a3_lib((d / "ContractNetLib.sol").read_text()))
    mgr = patch_a4_manager(patch_a3_manager((d / "ContractNetManager.sol").read_text()))
    (d / "ContractNetManager.sol").write_text(mgr)

    print("wrote", OUT, "from", core)


if __name__ == "__main__":
    main()
