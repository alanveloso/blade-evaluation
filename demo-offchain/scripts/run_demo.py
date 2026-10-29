#!/usr/bin/env python3
"""Single-command local demonstration: Anvil + Foundry tests + two off-chain agents."""

from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from agents.common import (  # noqa: E402
    ACCOUNT_0,
    ACCOUNT_1,
    CORE_COMMIT,
    KEY_0,
    KEY_1,
    PHASE_NONE,
    PHASE_REQUESTED,
    init_ids,
    outcome,
    pending,
    request_status,
)

CORE_PATH = ROOT.parents[1] / "blade"
RUN_DIR = ROOT / "run"
REPORTS = ROOT / "reports"


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def run(args: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    env = kwargs.pop("env", os.environ.copy())
    env.setdefault("FOUNDRY_DISABLE_NIGHTLY_WARNING", "1")
    return subprocess.run(args, text=True, env=env, **kwargs)


def run_check(args: list[str], **kwargs) -> str:
    completed = run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    return completed.stdout


def wait_http(url: str, timeout: float = 15.0) -> None:
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        probe = run(
            ["cast", "block-number", "--rpc-url", url],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if probe.returncode == 0:
            return
        last = probe.stderr
        time.sleep(0.1)
    raise RuntimeError(f"anvil did not become ready: {last}")


def parse_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    records = []
    for line in path.read_text().splitlines():
        if line.strip():
            records.append(json.loads(line))
    return records


def hex_to_int(value) -> int:
    if value is None:
        return 0
    if isinstance(value, int):
        return value
    return int(str(value), 0)


def main() -> int:
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    REPORTS.mkdir(parents=True, exist_ok=True)
    for leftover in RUN_DIR.glob("*"):
        if leftover.is_file():
            leftover.unlink()

    verify = run(
        [sys.executable, str(ROOT / "scripts" / "verify_core.py")],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    verify_out = verify.stdout
    if verify.returncode != 0:
        sys.stdout.write(verify_out)
        return verify.returncode

    print("== forge test ==")
    tests = run(
        ["forge", "test", "-vv"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    tests_out = tests.stdout
    print(tests_out)
    if tests.returncode != 0:
        return tests.returncode

    port = find_free_port()
    rpc = f"http://127.0.0.1:{port}"
    anvil = subprocess.Popen(
        [
            "anvil",
            "--port",
            str(port),
            "--hardfork",
            "cancun",
            "--silent",
        ],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    children: list[subprocess.Popen] = []
    stop_file = RUN_DIR / "stop-provider"
    try:
        wait_http(rpc)
        env = os.environ.copy()
        env["REQUESTER_OPERATOR"] = ACCOUNT_0
        env["PARTICIPANT_OPERATOR"] = ACCOUNT_1
        env["FOUNDRY_DISABLE_NIGHTLY_WARNING"] = "1"
        print("== deploy ==")
        deploy = run(
            [
                "forge",
                "script",
                "script/Deploy.s.sol:DeployDemo",
                "--rpc-url",
                rpc,
                "--broadcast",
                "--private-key",
                KEY_0,
                "-vv",
            ],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        print(deploy.stdout)
        if deploy.returncode != 0:
            return deploy.returncode

        broadcast = ROOT / "broadcast" / "Deploy.s.sol" / "31337" / "run-latest.json"
        created = [
            tx["contractAddress"]
            for tx in json.loads(broadcast.read_text())["transactions"]
            if tx.get("transactionType") == "CREATE"
        ]
        if len(created) < 2:
            raise RuntimeError(f"expected two CREATE receipts, got {created}")
        requester, participant = created[0], created[1]
        ids = init_ids()
        print(f"requester   {requester}")
        print(f"participant {participant}")

        requester_cfg = RUN_DIR / "requester.json"
        provider_cfg = RUN_DIR / "provider.json"
        probe_cfg = RUN_DIR / "probe.json"
        requester_log = RUN_DIR / "requester.jsonl"
        provider_log = RUN_DIR / "provider.jsonl"
        probe_log = RUN_DIR / "probe.jsonl"
        requester_cfg.write_text(
            json.dumps(
                {
                    "rpc": rpc,
                    "private_key": KEY_0,
                    "contract": requester,
                    "participant_contract": participant,
                    "log": str(requester_log),
                    "cases": ["A", "B", "C-wrong", "C-stale"],
                    "timeout_sec": 40,
                },
                indent=2,
            )
        )
        provider_cfg.write_text(
            json.dumps(
                {
                    "rpc": rpc,
                    "private_key": KEY_1,
                    "contract": participant,
                    "log": str(provider_log),
                    "stop_file": str(stop_file),
                    "poll_sec": 0.2,
                },
                indent=2,
            )
        )
        probe_cfg.write_text(
            json.dumps(
                {
                    "rpc": rpc,
                    "requester": requester,
                    "participant": participant,
                    "log": str(probe_log),
                },
                indent=2,
            )
        )

        provider_proc = subprocess.Popen(
            [sys.executable, "-u", str(ROOT / "agents" / "provider.py"), "--config", str(provider_cfg)],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        children.append(provider_proc)
        time.sleep(0.4)
        requester_proc = subprocess.Popen(
            [sys.executable, "-u", str(ROOT / "agents" / "requester.py"), "--config", str(requester_cfg)],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        children.append(requester_proc)
        requester_code = requester_proc.wait(timeout=60)
        requester_out = requester_proc.stdout.read() if requester_proc.stdout else ""
        print("== requester process ==")
        print(requester_out)
        if requester_code != 0:
            for label, path in (
                ("requester log", requester_log),
                ("provider log", provider_log),
            ):
                if path.exists():
                    print(f"== {label} ==")
                    print(path.read_text())
            raise RuntimeError(f"requester exited {requester_code}")

        print("== case C unauthorized probe ==")
        probe = run(
            [sys.executable, str(ROOT / "scripts" / "probe_invalid.py"), "--config", str(probe_cfg)],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        print(probe.stdout)
        if probe.returncode != 0:
            raise RuntimeError("unauthorized probe failed")

        stop_file.write_text("stop\n")
        try:
            provider_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            provider_proc.send_signal(signal.SIGTERM)
            provider_proc.wait(timeout=5)
        provider_out = provider_proc.stdout.read() if provider_proc.stdout else ""
        print("== provider process ==")
        print(provider_out)

        a_logs = parse_jsonl(requester_log)
        b_logs = parse_jsonl(provider_log)
        c_logs = parse_jsonl(probe_log)
        chain = {
            "A": {
                "requester": request_status(rpc, requester, ids["A"]),
                "participant": request_status(rpc, participant, ids["A"]),
                "pending": pending(rpc, participant, ids["A"]),
                "outcome": outcome(rpc, requester, ids["A"]),
            },
            "B": {
                "requester": request_status(rpc, requester, ids["B"]),
                "participant": request_status(rpc, participant, ids["B"]),
                "pending": pending(rpc, participant, ids["B"]),
                "outcome": outcome(rpc, requester, ids["B"]),
            },
            "C": {
                "requester": request_status(rpc, requester, ids["C"]),
                "participant": request_status(rpc, participant, ids["C"]),
                "pending": pending(rpc, participant, ids["C"]),
                "outcome": outcome(rpc, requester, ids["C"]),
            },
        }
        report = build_report(
            rpc=rpc,
            requester=requester,
            participant=participant,
            ids=ids,
            a_logs=a_logs,
            b_logs=b_logs,
            c_logs=c_logs,
            chain=chain,
            tests_out=tests_out,
            verify_out=verify_out,
        )
        (RUN_DIR / "report.json").write_text(json.dumps(report, indent=2))
        markdown = render_report(report)
        (REPORTS / "execution-report.md").write_text(markdown)
        (REPORTS / "example-output.txt").write_text(
            "\n".join(
                [
                    verify_out.strip(),
                    "",
                    tests_out.strip(),
                    "",
                    f"requester {requester}",
                    f"participant {participant}",
                    "",
                    "--- requester log ---",
                    requester_log.read_text().strip(),
                    "",
                    "--- provider log ---",
                    provider_log.read_text().strip(),
                    "",
                    "--- probe log ---",
                    probe_log.read_text().strip() if probe_log.exists() else "",
                    "",
                    "--- final chain state ---",
                    json.dumps(chain, indent=2),
                ]
            )
            + "\n"
        )
        shutil.copyfile(RUN_DIR / "report.json", REPORTS / "execution-report.json")
        for src, dst in (
            (requester_log, REPORTS / "example-requester.jsonl"),
            (provider_log, REPORTS / "example-provider.jsonl"),
            (probe_log, REPORTS / "example-probe.jsonl"),
        ):
            if src.exists():
                shutil.copyfile(src, dst)
        print(markdown)
        if not report["all_passed"]:
            return 1
        print("OK: off-chain demonstration completed.")
        return 0
    finally:
        stop_file.write_text("stop\n")
        for child in children:
            if child.poll() is None:
                child.send_signal(signal.SIGTERM)
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
        if anvil.poll() is None:
            anvil.send_signal(signal.SIGTERM)
            try:
                anvil.wait(timeout=3)
            except subprocess.TimeoutExpired:
                anvil.kill()


def build_report(**kwargs) -> dict:
    a_logs = kwargs["a_logs"]
    b_logs = kwargs["b_logs"]
    c_logs = kwargs["c_logs"]
    chain = kwargs["chain"]
    ids = kwargs["ids"]

    def first(logs, event, **fields):
        for rec in logs:
            if rec.get("event") != event:
                continue
            if all(rec.get(k) == v for k, v in fields.items()):
                return rec
        return None

    def all_events(logs, event):
        return [rec for rec in logs if rec.get("event") == event]

    req_a = first(a_logs, "request_sent", case="A")
    out_a = first(a_logs, "outcome_observed", case="A")
    req_b = first(a_logs, "request_sent", case="B")
    out_b = first(a_logs, "outcome_observed", case="B")
    obs = all_events(b_logs, "observed_request")
    sent = all_events(b_logs, "response_sent")
    rejected = all_events(b_logs, "response_rejected_by_core")
    unauth = c_logs[0] if c_logs else {}

    pid_a = first(a_logs, "start",).get("pid") if first(a_logs, "start") else None
    pid_b = first(b_logs, "start").get("pid") if first(b_logs, "start") else None

    checks = []

    def check(name: str, ok: bool, detail):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    check("distinct_processes", pid_a and pid_b and pid_a != pid_b, {"pid_A": pid_a, "pid_B": pid_b})
    check(
        "case_A_inform",
        bool(
            req_a
            and out_a
            and out_a.get("performative") == 4
            and out_a.get("phase_after") == PHASE_NONE
            and out_a.get("correlation") == req_a.get("token")
        ),
        {"request": req_a, "outcome": out_a},
    )
    check(
        "case_A_later_block",
        bool(req_a and out_a and hex_to_int(out_a.get("outcome_block")) > hex_to_int(req_a.get("block"))),
        {
            "request_block": req_a.get("block") if req_a else None,
            "outcome_block": out_a.get("outcome_block") if out_a else None,
        },
    )
    check(
        "case_B_refuse",
        bool(req_b and out_b and out_b.get("performative") == 2 and chain["B"]["requester"]["phase"] == PHASE_NONE),
        {"request": req_b, "outcome": out_b, "final": chain["B"]},
    )
    check("case_C_wrong_token_rejected", len(rejected) >= 1, rejected)
    check("case_C_stale_rejected", len(rejected) >= 2, rejected)
    check(
        "case_C_unauthorized",
        bool(unauth.get("state_unchanged")),
        unauth,
    )
    check(
        "case_C_state_still_requested",
        chain["C"]["requester"]["phase"] == PHASE_REQUESTED
        and chain["C"]["participant"]["phase"] == PHASE_REQUESTED
        and not chain["C"]["outcome"]["present"],
        chain["C"],
    )
    check(
        "reused_A_still_requested",
        chain["A"]["requester"]["phase"] == PHASE_REQUESTED
        and chain["A"]["requester"]["replyWith"] != (req_a.get("token") if req_a else None),
        {"first_token": req_a.get("token") if req_a else None, "now": chain["A"]},
    )
    check(
        "provider_observed_before_response",
        all(
            any(o.get("conversation_id", "").lower() == s.get("conversation_id", "").lower() for o in obs)
            for s in sent
        )
        and bool(obs),
        {"observed": len(obs), "sent": len(sent), "rejected": len(rejected)},
    )

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "core_commit": CORE_COMMIT,
        "rpc": kwargs["rpc"],
        "contracts": {
            "requester": kwargs["requester"],
            "participant": kwargs["participant"],
            "requester_operator": ACCOUNT_0,
            "participant_operator": ACCOUNT_1,
        },
        "conversation_ids": ids,
        "processes": {"agent_A": pid_a, "agent_B": pid_b},
        "checks": checks,
        "all_passed": all(c["ok"] for c in checks),
        "forge_tests": "PASS" if "passed" in kwargs["tests_out"] else kwargs["tests_out"][-500:],
        "core_verification": kwargs["verify_out"].strip().splitlines()[-1],
        "agent_A_log": a_logs,
        "agent_B_log": b_logs,
        "probe_log": c_logs,
        "final_chain_state": chain,
    }


def render_report(report: dict) -> str:
    lines = [
        "# Off-chain agent demonstration — execution report",
        "",
        f"Generated: `{report['generated_at']}`",
        f"BLADE Core: `{report['core_commit']}`",
        f"Requester contract: `{report['contracts']['requester']}`",
        f"Participant contract: `{report['contracts']['participant']}`",
        f"Agent A process: `{report['processes']['agent_A']}`",
        f"Agent B process: `{report['processes']['agent_B']}`",
        "",
        "## Conversation identifiers",
        "",
    ]
    for key, value in report["conversation_ids"].items():
        lines.append(f"- Case {key}: `{value}`")
    lines += ["", "## Checks", ""]
    for check in report["checks"]:
        mark = "PASS" if check["ok"] else "FAIL"
        lines.append(f"- **{mark}** `{check['name']}`")
    seq = []
    for rec in report.get("agent_A_log", []):
        if rec.get("event") in {"request_sent", "outcome_observed"}:
            seq.append(("A", rec))
    for rec in report.get("agent_B_log", []):
        if rec.get("event") in {"observed_request", "response_sent", "response_rejected_by_core"}:
            seq.append(("B", rec))
    seq.sort(key=lambda item: item[1].get("unix_ts", 0))
    lines += ["", "## Chronological interaction", ""]
    for agent, rec in seq:
        event = rec.get("event")
        cid = rec.get("conversation_id", "")[:10]
        extra = rec.get("tx") or rec.get("decision") or rec.get("performative")
        lines.append(
            f"- Agent {agent} `{event}` case={rec.get('case', rec.get('action', ''))} "
            f"block={rec.get('block', rec.get('outcome_block', rec.get('received_block')))} "
            f"id={cid}… {extra}"
        )
    lines += [
        "",
        f"Overall: **{'PASS' if report['all_passed'] else 'FAIL'}**",
        "",
        "## Architecture",
        "",
        "Agent A (off-chain process) → DemoRequester (BLADE Request) → "
        "DemoParticipant (BLADE Request) → Agent B (off-chain process).",
        "The reverse path carries Inform / Refuse. The two processes do not exchange protocol",
        "decisions except through the chain. `RequestExample.sol` auto-replies in `_onReceive`;",
        "these wrappers do not.",
        "",
        "## Policies",
        "",
        "- Agent A: request payload `0x01` (accept path), then `0x00` (refuse path), then",
        "  `0x03` / `0x04` to open conversations that Agent B will answer incorrectly.",
        "- Agent B: `0x01` → Inform; `0x00` → Refuse; `0x03` → Inform with a wrong token;",
        "  `0x04` → Inform with the previous token of a reused `conversationId`.",
        "",
        "## Limitations",
        "",
        "This run shows independent off-chain decisions plus on-chain FIPA Request validation.",
        "It does not show cognitive autonomy, productivity gains, or unrestricted generality.",
        "",
    ]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write(f"run_demo failed: {exc}\n")
        raise
