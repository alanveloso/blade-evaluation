# F3 raw record schema

Schema version **2**. Field meanings are those used in the published `data/raw/*.jsonl` files.

Generation identity is carried by `experiment_spec_id` and `core_sha`.

| Field | Published campaign value |
|---|---|
| `experiment_spec_id` | `blade-core-eval-v2` |
| `schema_version` | `2` |
| `analysis_version` | `1` |
| `phase` | `f3` |
| `core_sha` | `c145305a3ca76f52a64b62a0cb731283dbba9638` |

`reply_by` on Contract Net rows is the CFP proposal-collection deadline (`1700001100`). Accept/reject `Message.replyBy = 0` is the Core encoding.

Complete-interaction gas is the sum of top-level `receipt.gasUsed` on `interaction_tx` rows (deployment excluded). Relative overhead is `(BLADE − purpose-built) / purpose-built`.
