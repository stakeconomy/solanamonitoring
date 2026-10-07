# Alpenglow Monitoring Schema v3

## Scope

Schema v3 is the standalone, two-second Alpenglow observed-inclusion stream. Its measurement: `alpenglow_observed`. It runs beside the one-minute schema-v2 `nodemonitor` collector during shadow and dashboard cutover.

This signal is an **RPC-derived estimate using a bounded reference cohort; not direct certificate telemetry**. It is also not direct Votor telemetry. It must not be presented as a proof of certificate participation.

## Series identity

Every emitted line carries these fixed tags:

- `cluster=testnet`
- `genesis=4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY`
- `consensus=alpenglow`
- `pubkey=<configured validator identity>`
- `vote_account=<configured vote account>`
- `schema=3`

The collector emits nothing unless the exact Testnet genesis, Alpenglow certificate RPC, vote-program owner, parsed vote-account type, and configured identity-to-vote-account relationship are all proved by the current RPC snapshot.

## Fields

Each successful sample contains all eight integer fields:

| Field | Meaning |
| --- | --- |
| `included_total` | Cumulative estimated inclusions for the monitored vote account |
| `expected_total` | Cumulative estimated opportunities, using the maximum of the monitored and usable-reference counts |
| `missed_total` | Cumulative estimated misses; invariant: `expected_total = included_total + missed_total` |
| `unattributed_slots_total` | Cumulative slots in advancing gaps that could not be attributed safely |
| `ready` | `1` when the latest gap was attributed, otherwise `0` |
| `observed_slot` | Finalized slot of the latest account snapshot |
| `last_attributed_slot` | Last finalized slot whose advancing gap was attributed; zero before the first attribution |
| `usable_references` | Clean reference accounts with known counts in the latest gap |

The four `*_total` values are cumulative counters. They are never rewritten from later learner evidence and must be queried with a rolling counter function such as PromQL `increase()`. The remaining fields describe the current sample and are not cumulative counters.

A clean zero-opportunity gap is attributed and emits `ready=1` without increasing the totals. That differs from stale collection and from an unattributed gap.

## Collection and state contract

The production cadence and fixed parser settings are:

- interval: `2s`
- Telegraf timeout: `10s` (bounded full-epoch schedule-refresh fail-safe; non-blocking locking prevents overlap)
- per-RPC timeout: `0.7s`
- reference count: `8`
- rate-learning samples: `20`

The canonical dashboard refreshes every `5s` so its five-second freshness state is observable without a manual refresh. The v3 Telegraf input disables collection jitter, and the community output flushes every `2s` without flush jitter, so buffering does not manufacture stale status. This increases dashboard and output cadence; the tradeoff is intentional, while collector cadence remains `2s` and historical panels retain bounded resolution.
- state: `/home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json`

Each invocation performs one mandatory JSON-RPC batch and at most one optional request. The collector takes a non-blocking lock, writes state to a same-directory temporary file, sets mode `0600`, and renames it atomically before emitting stdout. Lock contention exits successfully with no output and no state mutation.

State is owned and writable by the validator user. Do not share the v3 state file with schema v2, copy v2 interval state into v3 cumulative totals, edit totals manually, or reuse one state path for multiple identities or vote accounts.

## Interpretation limits

The denominator is estimated from a bounded reference cohort. References can collectively miss an opportunity, and a multi-gap GCD learner can retain a common multiplier. The estimate may therefore undercount included and expected events. A one-slot positive clean gap is the only direct atomic-increment observation available to this RPC model.

Keep the disclosure **RPC-derived estimate using a bounded reference cohort; not direct certificate telemetry** anywhere these fields are displayed.
