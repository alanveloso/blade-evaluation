# Off-chain agent demonstration — execution report

Generated: `2026-10-29T13:31:18.041141+00:00`
BLADE Core: `4b60b86159e89baccd24a859ca62e7039a8c8be2`
Requester contract: `0x5fbdb2315678afecb367f032d93f642f64180aa3`
Participant contract: `0xe7f1725e7734ce288f8367e1bb143e90bb3f0512`
Agent A process: `59623`
Agent B process: `59556`

## Conversation identifiers

- Case A: `0xe4984038ea75fb508baebaecdede0777de0df39135477d1bb73535d7bf439766`
- Case B: `0xa57209aeb3d56c11c9acb295b5a15142e6dbb79cffa0be4b54f24d7ac7cf81e3`
- Case C: `0xb56a7d6a28c1d854b5204f67055669f2c3b6443c6b56e86d6d5f551841b73328`

## Checks

- **PASS** `distinct_processes`
- **PASS** `case_A_inform`
- **PASS** `case_A_later_block`
- **PASS** `case_B_refuse`
- **PASS** `case_C_wrong_token_rejected`
- **PASS** `case_C_stale_rejected`
- **PASS** `case_C_unauthorized`
- **PASS** `case_C_state_still_requested`
- **PASS** `reused_A_still_requested`
- **PASS** `provider_observed_before_response`

## Chronological interaction

- Agent A `request_sent` case=A block=3 id=0xe4984038… 0xdef6212585f7f7fbc22275cbd74ecf883388b0e6eccf79ff3c337dc3ce7e541c
- Agent B `observed_request` case= block=3 id=0xe4984038… inform
- Agent B `response_sent` case=inform block=4 id=0xe4984038… 0xc8df412b2dff668871f1e7b1268cd0be3c25a2512cbee896617cb26befcb890c
- Agent A `outcome_observed` case=A block=4 id=0xe4984038… 4
- Agent A `request_sent` case=B block=5 id=0xa57209ae… 0x97930d7774f3ad05dbdeb9443981914359483e79afa8aeb0f0f4a5e2ac9d5c93
- Agent B `observed_request` case= block=5 id=0xa57209ae… refuse
- Agent B `response_sent` case=refuse block=6 id=0xa57209ae… 0xd48054280bdca772adfc6f931cdbb78bd12aee4f65f97604c8b84744e9144cc5
- Agent A `outcome_observed` case=B block=6 id=0xa57209ae… 2
- Agent A `request_sent` case=C-wrong block=7 id=0xb56a7d6a… 0x6b0dae870f28c70fe6bde9ecd860af9cd7241603b49783995e94b5536d47e6ff
- Agent B `observed_request` case= block=7 id=0xb56a7d6a… invalid_wrong_token
- Agent B `response_rejected_by_core` case=invalid_wrong_token block=None id=0xb56a7d6a… None
- Agent A `request_sent` case=C-stale block=8 id=0xe4984038… 0x5157e54b7f382c25687f1632b4376bed532508323591660ce3e210595473ed9b
- Agent B `observed_request` case= block=8 id=0xe4984038… invalid_stale_token
- Agent B `response_rejected_by_core` case=invalid_stale_token block=None id=0xe4984038… None

Overall: **PASS**

## Architecture

Agent A (off-chain process) → DemoRequester (BLADE Request) → DemoParticipant (BLADE Request) → Agent B (off-chain process).
The reverse path carries Inform / Refuse. The two processes do not exchange protocol
decisions except through the chain. `RequestExample.sol` auto-replies in `_onReceive`;
these wrappers do not.

## Policies

- Agent A: request payload `0x01` (accept path), then `0x00` (refuse path), then
  `0x03` / `0x04` to open conversations that Agent B will answer incorrectly.
- Agent B: `0x01` → Inform; `0x00` → Refuse; `0x03` → Inform with a wrong token;
  `0x04` → Inform with the previous token of a reused `conversationId`.

## Limitations

This run shows independent off-chain decisions plus on-chain FIPA Request validation.
It does not show cognitive autonomy, productivity gains, or unrestricted generality.

