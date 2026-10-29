# External off-chain agents interacting through BLADE

## Motivation

Reviewers of the JAAMAS submission asked whether BLADE is relevant to multi-agent
systems, whether agent autonomy is distinct from on-chain protocol execution, and
whether independent off-chain participants can coordinate through the Core. The
in-tree `RequestExample` answers a Request from `_onReceive` in the same
transaction that delivered it. That pattern cannot evidence an external decision.
This note reports a minimal demonstration that keeps the official Core unchanged
and places the decision in two ordinary OS processes.

## Architecture

Two application contracts inherit `RequestAgent` and expose operator-gated
entry points. They do not copy the Request FSM, correlation checks, or transport
authentication.

- Agent A (process) calls `DemoRequester.request`, which calls `_startRequest`.
- Core delivers the Request to `DemoParticipant.handle` in that same transaction,
  records `Requested` on both sides, and emits `Received` / `RequestAdvanced`.
- `DemoParticipant._onReceive` stores the task and returns. It does not call
  `_reply`.
- Agent B (a second process, different key) later observes the pending task,
  applies a local policy, and calls `DemoParticipant.respond`.
- `respond` builds the outbound ACL message and calls `_reply`. Core validates
  the peer, the correlation token, and the transition, then delivers Inform or
  Refuse to the requester in a *subsequent* transaction.
- Agent A observes the recorded outcome.

No direct channel carries protocol decisions between the two processes.

## Experimental procedure

Toolchain: Foundry/Anvil 1.7.1, solc 0.8.26, EVM Cancun, Python 3 standard
library. Core commit `4b60b86159e89baccd24a859ca62e7039a8c8be2`. Command:
`demo-offchain/run.sh`. Foundry tests instantiate the same wrappers with two
EOAs and an explicit block gap (`vm.roll`) between request and response. The
live run starts two OS processes against a local Anvil node.

Cases:

1. Agent A requests payload `0x01`; Agent B Informs with the live token.
2. Agent A requests payload `0x00`; Agent B Refuses with the live token.
3. Invalid attempts: (i) a third EOA calls `handle` with Inform; (ii) Agent B
   sends Inform with a wrong `inReplyTo`; (iii) after `conversationId` reuse,
   Agent B replays the previous token. Each attempt must revert in Core without
   mutating the live session.

## Observed results

A concrete local run (`./run.sh`, Anvil Cancun, Core `4b60b86`) produced two OS
processes (Agent A pid 59623, Agent B pid 59556) and the following chain:

| Step | Block | Actor | Act |
|---|---|---|---|
| 1 | 3 | Agent A → DemoRequester | `request` (`0x01`) |
| 2 | 3 | Core | delivers Request; both sides `Requested`; Agent B has not yet decided |
| 3 | 4 | Agent B → DemoParticipant | `Inform` with the live token |
| 4 | 4 | Agent A | observes Inform; both sessions cleared |
| 5 | 5 | Agent A | `request` (`0x00`) |
| 6 | 6 | Agent B | `Refuse` with the live token; sessions cleared |
| 7 | 7 | Agent A | opens a live Request (`0x03`) |
| 8 | — | Agent B | Inform with a wrong token → `ReplyWithMismatch`; pending remains |
| 9 | — | third EOA | `handle(Inform)` → `UnexpectedPeer`; status hash unchanged |
| 10 | 8 | Agent A | reuses Case A's `conversationId` (`0x04`); Core assigns a new token |
| 11 | — | Agent B | Inform with the *previous* token → `ReplyWithMismatch`; new session stays `Requested` |

Foundry tests (`test/OffchainDemo.t.sol`, 8/8 PASS) reproduce the same three
cases with an explicit `vm.roll` between request and response, plus operator
gating and event checks (`Received`, `RequestAdvanced`). The Core tree remained
unmodified. Full logs: `execution-report.md`, `example-output.txt`.

## Limitations

The policies are deterministic look-ups on a one-byte payload. The demonstration
establishes that *external processes can decide independently while BLADE
enforces Request correlation, authorization, and transitions*. It does not
establish cognitive autonomy, learning, productivity, FIPA completeness, or
behaviour on a public network. Contract Net is out of scope. Abandoned
conversations still strand storage, as in Core E2. The wrappers store the
inbound payload so that the off-chain process can read it; Core itself still
does not persist `content`.
