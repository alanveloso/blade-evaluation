# Off-chain agents on BLADE (FIPA Request)

Minimal, local demonstration that two **independent off-chain processes** interact
only through BLADE, using the official Core at

`4b60b86159e89baccd24a859ca62e7039a8c8be2`

(the corrected E2 Core). This directory is additive. It does not modify BLADE Core,
nor the E0 / E1 / E2 campaigns, manifests, or historical results.

The in-tree `examples/RequestExample.sol` replies from `_onReceive` inside the
delivery transaction. That pattern does **not** show an external decision. The
wrappers here record the inbound Request and wait for a later operator transaction.

## Architecture

```text
Agent A (Python process)
    → DemoRequester  (BLADE RequestAgent)
        → DemoParticipant (BLADE RequestAgent)
            → Agent B (Python process)

Agent B (Python process)
    → DemoParticipant
        → DemoRequester
            → Agent A
```

The blockchain is the only protocol channel. The two processes do not send
Request / Inform / Refuse to each other over sockets, files, or shared memory.
A small harness starts Anvil, deploys the wrappers, and later runs a **validation
probe** (unauthorized `handle`). That probe is not an agent.

## Policies (deterministic, local)

| Agent | Input | Decision |
|---|---|---|
| A | start-up | request service `0x01`, then `0x00`, then open two probe conversations |
| B | payload `0x01` | Inform (`0xc0ffee`) with the live session token |
| B | payload `0x00` | Refuse (`0xb1`) with the live session token |
| B | payload `0x03` | Inform with a **wrong** token (Core must revert) |
| B | payload `0x04` | Inform with the **previous** token of a reused `conversationId` (Core must revert) |

## Cases

- **A — served.** A requests; B observes after delivery; B Informs in a later transaction; both sessions clear.
- **B — refused.** Same path with Refuse.
- **C — invalid.** Unauthorized sender; wrong correlation token; stale token after `conversationId` reuse. Each attempt reverts in Core and leaves the live session unchanged.

## Requirements

- Sibling clone of [alanveloso/blade](https://github.com/alanveloso/blade) at the E2 commit above (`../../blade` from this directory).
- Foundry 1.7.1 (`forge`, `anvil`, `cast`) and Python 3.10+.
- No paid APIs, public networks, or extra Python packages.

## Run

From this directory:

```bash
./run.sh
```

Equivalent:

```bash
python3 scripts/verify_core.py
forge test -vv
python3 scripts/run_demo.py
```

`run.sh` / `scripts/run_demo.py` will:

1. Refuse to run if Core is not E2 or if `blade/src` is dirty.
2. Run the Foundry suite (`test/OffchainDemo.t.sol`).
3. Start Anvil (`cancun`).
4. Deploy `DemoRequester` (operator = Anvil account 0) and `DemoParticipant` (operator = account 1).
5. Start Agent B, then Agent A, as separate OS processes.
6. Run the unauthorized-sender probe.
7. Write `reports/execution-report.md`, `reports/execution-report.json`, and `reports/example-output.txt`.

## Layout

| Path | Role |
|---|---|
| `src/DemoRequester.sol` | Operator-gated `request`; records inbound terminal acts |
| `src/DemoParticipant.sol` | Records the Request and waits; `respond` calls Core `_reply` |
| `script/Deploy.s.sol` | Local deploy |
| `test/OffchainDemo.t.sol` | Cases A/B/C, no auto-reply, operator gating, events |
| `agents/requester.py` | Agent A |
| `agents/provider.py` | Agent B |
| `scripts/run_demo.py` | One-command harness |
| `scripts/probe_invalid.py` | Unauthorized `handle` probe |
| `scripts/verify_core.py` | E2 pin + clean tree |
| `reports/` | Execution evidence and the scientific note |

Application functions (`request`, `respond`) are restricted to each contract's
operator. Protocol validation (performative, peer, correlation, transitions,
cleanup) is not reimplemented; it remains in `RequestAgent` / `Agent`.

## What this does *not* show

The run supports the claim that external participants can decide off-chain while
BLADE executes FIPA Request checks on-chain. It does **not** show cognitive
autonomy, higher productivity, or unrestricted generality.
