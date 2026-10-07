# Alpenglow Observed Metrics Schema v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use openclaw-imports:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify the standalone two-second RPC-derived Alpenglow inclusion estimator, its bounded persistent state, shadow Telegraf configuration, and schema-v3 Grafana queries without breaking the existing schema-v2 collector during rollout.

**Architecture:** Add a new `scripts/alpenglow-observed-vote-inclusion-v3.sh` executable. It owns one locked JSON state file and emits one `alpenglow_observed` cumulative-counter line. Keep the existing helper and `monitor.sh` ABI unchanged for shadow rollout; wire v3 through a separate Telegraf input and migrate dashboard source queries to rolling schema-v3 counters.

**Tech Stack:** Bash, curl, jq, flock, Influx line protocol, Telegraf `inputs.exec`, Grafana JSON/jq, shell fixture tests.

**Spec:** `docs/superpowers/specs/2026-10-07-alpenglow-observed-v3-design.md`

## Global Constraints

- Exact Testnet genesis: `4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY`.
- Exact Testnet schedule: `432000,432000,true,14,524256`.
- New script path: `scripts/alpenglow-observed-vote-inclusion-v3.sh`; do not alter the legacy helper's positional ABI.
- Maximum two RPC requests per invocation: one mandatory batch and at most one optional request.
- Default cadence/config: `2s`, RPC timeout `0.7`, reference count `8`, rate samples `20`, Telegraf fail-safe timeout `10s`.
- All potentially large persisted integers are canonical decimal strings; never use jq `tonumber` on them.
- State updates use non-blocking `flock`, same-directory mode-0600 temporary file, and atomic rename.
- Measurement tags are bounded to cluster, genesis, consensus, pubkey, vote_account, and schema.
- Cumulative invariants: `expected == included + missed` and `included <= expected`.
- No daemon, replay queue, pending-gap queue, quorum, peer attribution, or direct-certificate claim.
- Schema-v2 collection remains active throughout shadow rollout.

---

### Task 1: Standalone CLI, isolation, and cold state

**Files:**
- Create: `scripts/alpenglow-observed-vote-inclusion-v3.sh`
- Create: `tests/test-alpenglow-observed-v3.sh`
- Create/modify: `tests/fixtures/mock-alpenglow-v3-curl`

**Interfaces:**
- Consumes CLI flags from the spec.
- Produces one `alpenglow_observed,...` line and v3 JSON state.

- [ ] **Step 1: Write RED tests for help, argument validation, cold start, exact tags/fields, ownership proof, Mainnet/Tower rejection, malformed batch IDs, fixed schedule rejection, corrupt-state refusal, lock contention, and atomic state mode.**

Use a fixture dispatcher keyed by JSON-RPC method/id. Assert the cold state contains zero string totals, monitored baseline, empty/null reference baselines, exact config/schedule, and no legacy field names.

- [ ] **Step 2: Run the focused test and confirm expected failures.**

Run: `bash tests/test-alpenglow-observed-v3.sh`
Expected: FAIL because the v3 script and fixture do not exist.

- [ ] **Step 3: Implement the minimal CLI and mandatory batch.**

Required helper boundaries inside the script:

```bash
usage
fail_usage
require_commands
is_u63_decimal
checked_add
checked_sub
rpc_call
influx_tag
validate_core_state
write_state_atomic
emit_measurement
```

The mandatory batch must use unique IDs for `getGenesisHash`, `getAgGenesisCert`, `getEpochSchedule`, and finalized `getMultipleAccounts`. Write stdout only after the state rename succeeds.

- [ ] **Step 4: Run focused RED→GREEN and syntax checks.**

Run:

```bash
bash -n scripts/alpenglow-observed-vote-inclusion-v3.sh tests/test-alpenglow-observed-v3.sh tests/fixtures/mock-alpenglow-v3-curl
bash tests/test-alpenglow-observed-v3.sh
```

Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add scripts/alpenglow-observed-vote-inclusion-v3.sh tests/test-alpenglow-observed-v3.sh tests/fixtures/mock-alpenglow-v3-curl
git commit -m "feat: add Alpenglow observed v3 collector shell"
```

---

### Task 2: Cohort, schedules, learners, and cumulative transitions

**Files:**
- Modify: `scripts/alpenglow-observed-vote-inclusion-v3.sh`
- Modify: `tests/test-alpenglow-observed-v3.sh`
- Modify: `tests/fixtures/mock-alpenglow-v3-curl`
- Add fixtures as needed under `tests/fixtures/alpenglow-v3-*.json`

**Interfaces:**
- Consumes valid v3 state and RPC snapshots.
- Produces cumulative included/expected/missed/unattributed totals.

- [ ] **Step 1: Add one failing vertical test at a time for cohort discovery, null-baseline initialization, stable membership, same-invocation repair, bounded 600-account selection, and the two-request ceiling.**

Run each new named shell test case immediately and record its expected failure before implementation.

- [ ] **Step 2: Implement cohort selection in one bounded jq pass.**

Retain valid persisted votes in order, exclude monitored vote, fill vacancies from active current accounts, and create explicit null-baseline records. Never invoke jq once per candidate.

- [ ] **Step 3: Add RED tests for exact epochCredits parsing and state precision.**

Cover object numeric epoch/string credits, migration marker, ordered unique epochs, unsafe numeric forms, legacy safe arrays, values above `9007199254740991`, and signed-64 overflow.

- [ ] **Step 4: Implement exact parsing without jq numeric conversion of large strings.**

Keep epoch/slot/credit/totals as strings across jq/Bash boundaries. Use lexical length/range checks before Bash arithmetic.

- [ ] **Step 5: Add RED tests for leader-cache normalization, node rotation, own/reference leader contamination, reward-delay `+7/+8/+9`, repeated/regressing slots, baseline-slot mismatch, epoch rollover, and optional-call isolation.**

- [ ] **Step 6: Implement schedule fetching and deterministic baseline advancement.**

Persist absolute leader slots keyed by node identity. Normalize only the leader-cache subsection when invalid. Every initialized account baseline must share the monitored slot after a successful advancing snapshot.

- [ ] **Step 7: Add RED tests for zero gaps, learner warmup, one-slot promotion, twenty-sample GCD promotion, contradictions, restart recovery, own-inclusive denominator, rate-samples changes, reference-count changes, and identity/vote rotation.**

- [ ] **Step 8: Implement cumulative accounting.**

Use:

```text
included_gap = monitored_count
expected_gap = max(included_gap, clean reference counts)
missed_gap = expected_gap - included_gap
```

A zero/zero gap is attributed. Unknown spans increment unattributed slots exactly once. Preserve cumulative invariants after every state write.

- [ ] **Step 9: Run the focused suite and a repeated runtime/process-count gate.**

Run:

```bash
bash tests/test-alpenglow-observed-v3.sh
for _ in $(seq 1 30); do /usr/bin/time -f '%e' bash tests/test-alpenglow-observed-v3.sh >/dev/null; done
```

Expected: all cases pass; no tested collector path makes more than two fixture RPC calls; bounded-cohort parser count is independent of 600 candidates.

- [ ] **Step 10: Commit.**

```bash
git add scripts/alpenglow-observed-vote-inclusion-v3.sh tests/test-alpenglow-observed-v3.sh tests/fixtures
git commit -m "feat: persist cumulative Alpenglow inclusion estimates"
```

---

### Task 3: Shadow Telegraf and least-privilege installation

**Files:**
- Modify: `telegraf/solana-monitoring.conf.example`
- Modify: `tests/test-telegraf.sh`
- Modify: `README.md`
- Modify: `docs/installation.md`
- Create: `docs/alpenglow-monitoring-schema-v3.md`
- Modify: `docs/alpenglow-monitoring-migration.md`

**Interfaces:**
- Produces a separate two-second Telegraf input and exact-argument sudoers documentation.
- Preserves the one-minute schema-v2 input and rule.

- [ ] **Step 1: Add RED assertions for a second input with exact script path, fixed arguments/state path, `interval="2s"`, `timeout="10s"`, and `--rpc-timeout 0.7`.**

Also assert the old `monitor.sh` input still exists and the new sudoers example binds every production argument.

- [ ] **Step 2: Run RED.**

Run: `bash tests/test-telegraf.sh`
Expected: FAIL because v3 input/docs are absent.

- [ ] **Step 3: Add the shadow input and installation/migration documentation.**

Document `visudo -c`, `sudo -ll -U telegraf`, altered-argument rejection probes, exact-command shadow execution, 24-hour shadow gate, and phase-two/phase-three rollback.

- [ ] **Step 4: Run GREEN and config parse.**

```bash
bash tests/test-telegraf.sh
command -v telegraf >/dev/null && telegraf --config telegraf/solana-monitoring.conf.example --test --input-filter exec --output-filter discard
```

- [ ] **Step 5: Commit.**

```bash
git add telegraf/solana-monitoring.conf.example tests/test-telegraf.sh README.md docs/installation.md docs/alpenglow-monitoring-schema-v3.md docs/alpenglow-monitoring-migration.md
git commit -m "feat: add shadow Alpenglow v3 Telegraf input"
```

---

### Task 4: Schema-v3 Grafana panels

**Files:**
- Modify: `grafana/enhance-dashboard.jq`
- Modify: `grafana/solana-community-validator-dashboard.json`
- Modify: `Solana Community Validator Dashboard-1623239777455.json`
- Modify: `tests/test-dashboard.sh`

**Interfaces:**
- Consumes `alpenglow_observed_*` schema-3 series.
- Produces rolling ten-minute rate/count/history and current collection status.

- [ ] **Step 1: Replace dashboard expectations with RED assertions for exact schema-v3 selectors.**

Assert:

```text
increase(alpenglow_observed_included_total{...,schema="3"}[10m])
increase(alpenglow_observed_expected_total{...,schema="3"}[10m])
increase(alpenglow_observed_missed_total{...,schema="3"}[10m])
time() - timestamp(alpenglow_observed_observed_slot{...,schema="3"})
```

Assert no `clamp_max`, no legacy Alpenglow query in the migrated panels, five-second stale threshold, count rounding, status mappings, and the disclosure phrase in every panel description.

- [ ] **Step 2: Run RED.**

Run: `bash tests/test-dashboard.sh`
Expected: FAIL on old schema-v2 queries.

- [ ] **Step 3: Update the jq migration and canonical JSON.**

Keep panel IDs stable where practical, add a compact collection-status panel without overlapping existing layout, and preserve every Tower panel/query unchanged.

- [ ] **Step 4: Verify GREEN, migration, layout, and byte idempotence.**

```bash
bash tests/test-dashboard.sh
jq -e . grafana/solana-community-validator-dashboard.json >/dev/null
```

- [ ] **Step 5: Commit.**

```bash
git add grafana/enhance-dashboard.jq grafana/solana-community-validator-dashboard.json 'Solana Community Validator Dashboard-1623239777455.json' tests/test-dashboard.sh
git commit -m "feat: graph cumulative Alpenglow inclusion estimates"
```

---

### Task 5: Whole-branch verification and release evidence

**Files:**
- Modify only files required by findings.

- [ ] **Step 1: Run syntax and all project suites.**

```bash
bash -n monitor.sh scripts/alpenglow-observed-vote-inclusion.sh scripts/alpenglow-observed-vote-inclusion-v3.sh tests/test-monitor.sh tests/test-alpenglow-observed-v3.sh tests/test-dashboard.sh tests/test-telegraf.sh
bash tests/test-monitor.sh
bash tests/test-alpenglow-observed-v3.sh
bash tests/test-dashboard.sh
bash tests/test-telegraf.sh
git diff --check
```

- [ ] **Step 2: Verify live local RPC schedule and one bounded shadow invocation without installing system configuration.**

Use a temporary v3 state path and the validator identity/vote account already supplied by the operator. Confirm one valid line, all eight fields, schema-3 tags, state mode `0600`, and runtime. Do not replace production state or Telegraf config.

- [ ] **Step 3: Independently review the full implementation against the spec.**

Block on isolation, counter invariants, integer precision, lock/write races, more than two RPC calls, legacy ABI breakage, unbounded labels/processes, misleading dashboard semantics, or missing migration rollback.

- [ ] **Step 4: Fix findings with RED regressions and rerun the full suite.**

- [ ] **Step 5: Commit and push the verified branch.**

```bash
git status --short
git log --oneline --decorate -8
GIT_SSH_COMMAND="ssh -i ~/.ssh/github" git push origin main
```

Report HEAD, origin/main, verification commands, live-shadow result, and that production cutover remains gated on 24-hour shadow evidence.
