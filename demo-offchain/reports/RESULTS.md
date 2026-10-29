# Results (local Anvil run)

Toolchain: Foundry/Anvil 1.7.1, solc 0.8.26, Cancun, Core `4b60b86`.
Command: `./run.sh`. Official Core sources were not modified.

## Automated tests

`forge test` in this directory: **8/8 PASS**.

| Test | What it shows |
|---|---|
| `test_requestDoesNotAutoReply` | After `request`, both sides stay `Requested` |
| `test_caseA_informInLaterTransaction` | Inform is a later transaction; sessions clear |
| `test_caseB_refuseInLaterTransaction` | Refuse is a later transaction; sessions clear |
| `test_caseC_unauthorizedSenderLeavesState` | Third party `handle` → `UnexpectedPeer` |
| `test_caseC_wrongTokenLeavesState` | Wrong `inReplyTo` → `ReplyWithMismatch` |
| `test_caseC_staleTokenAfterConversationIdReuse` | Old token rejected; new token still live |
| `test_applicationFunctionsAreOperatorGated` | Only each operator may `request` / `respond` |
| `test_identitiesRolesAndEvents` | Peers, roles, token, `Received`, `RequestAdvanced` |

## Live processes

- Agent A pid 59623, operator `0xf39F…2266`, contract `0x5FbD…0aa3`
- Agent B pid 59556, operator `0x7099…79C8`, contract `0xe7f1…0512`
- Decision of B is logged after the Request transaction and is sent in a later block (Case A: request block 3, Inform block 4; Case B: 5 then 6).

## Cases

- **A served.** Inform `0xc0ffee`, token match, both FSMs return to `None`.
- **B refused.** Refuse `0xb1`, token match, both FSMs return to `None`.
- **C rejected.** Wrong token and stale token → `ReplyWithMismatch`; unauthorized sender → `UnexpectedPeer`. Live sessions stay `Requested`.

## Claim supported / not supported

Supported: two external processes can decide independently while BLADE executes
FIPA Request checks on-chain.

Not supported: cognitive autonomy, productivity, FIPA completeness, public-network
operation. See `scientific-note.md`.
