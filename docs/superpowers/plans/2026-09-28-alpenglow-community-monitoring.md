# Alpenglow-Aware Community Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the shared Stakeconomy community collector and Grafana dashboard safe for simultaneous legacy-mainnet and Alpenglow-testnet ingestion.

**Architecture:** `monitor.sh` derives a canonical cluster and consensus tag from the RPC genesis hash and emits schema-v2 series keyed by cluster, genesis, identity, and vote account. Tower credit fields are emitted only for Tower consensus. The single Grafana dashboard scopes every `nodemonitor` query by the selected cluster, genesis, identity, and vote account, and renders the credit row only when its data has Tower semantics.

**Tech Stack:** Bash, jq, JSON-RPC, Influx line protocol, Telegraf, Prometheus-compatible Grafana queries, shell regression tests.

**Spec:** `docs/alpenglow-monitoring-schema-v2.md`

## Global Constraints

- Preserve the measurement name `nodemonitor`.
- Never infer a cluster from an RPC URL or identity; the actual `getGenesisHash` is authoritative.
- Preserve legacy mainnet Tower fields for existing consumers during the schema-v2 rollout.
- Do not emit zeroes for unavailable production data or non-applicable Alpenglow credit efficiency.
- Do not expose Sentinel-local Votor metrics through the portable community collector.
- Do not mix untagged historical records into tagged mainnet or testnet views.

---

### Task 1: Add a schema-v2 collector identity contract

**Files:**
- Modify: `monitor.sh`
- Modify: `tests/test-monitor.sh`
- Modify: `tests/fixtures/mock-monitor-curl`
- Modify: `README.md`

**Interfaces:**
- Consumes: `getGenesisHash` response already present in the supplemental batch.
- Produces: tags `cluster`, `genesis`, `consensus`, `pubkey`, `vote_account`, `schema=2`; fields `collectorUp` and `genesisMatch`.

- [ ] **Step 1: Write failing collector assertions**

Add assertions for an ordinary fixture run:

```bash
assert_contains "$output" "nodemonitor,cluster=testnet,genesis=4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY,consensus=alpenglow,pubkey=$identity,vote_account=Vote111111111111111111111111111111111111111,schema=2 "
assert_contains "$output" 'collectorUp=1i'
assert_contains "$output" 'genesisMatch=1i'
```

Add an expected-genesis mismatch fixture that asserts `genesisMatch=0i` and the absence of `leaderSlots=` and `activatedStake=`.

- [ ] **Step 2: Run the focused collector test and observe RED**

Run: `bash tests/test-monitor.sh`

Expected: FAIL because the current record has only a `pubkey` tag and no schema-v2 health fields.

- [ ] **Step 3: Implement cluster/consensus resolution**

Add a pure Bash `cluster_metadata_for_genesis` helper that maps exactly:

```bash
5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp -> mainnet-beta tower
4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY -> testnet alpenglow
EtWTRABZaYq6iMfeYKouRu166VU2xqa1 -> devnet unknown
* -> custom unknown
```

Add `SOLANA_EXPECTED_CLUSTER` and `SOLANA_EXPECTED_GENESIS` environment/CLI configuration. Validate an expected genesis before emitting normal fields. Escape tag values according to Influx line protocol before composing the record.

- [ ] **Step 4: Run focused and full collector tests**

Run: `bash tests/test-monitor.sh && bash tests/test-dashboard.sh`

Expected: PASS.

- [ ] **Step 5: Update the supported contract**

Document required tags, the expected-cluster/genesis safeguards, and the fact that untagged historical data is not part of schema v2.

- [ ] **Step 6: Commit**

```bash
git add monitor.sh tests/test-monitor.sh tests/fixtures/mock-monitor-curl README.md docs/alpenglow-monitoring-schema-v2.md
git commit -m "feat: scope community metrics by cluster genesis"
```

### Task 2: Remove false Alpenglow vote-credit efficiency

**Files:**
- Modify: `monitor.sh`
- Modify: `tests/test-monitor.sh`
- Modify: `tests/fixtures/mock-monitor-curl`
- Modify: `README.md`

**Interfaces:**
- Consumes: `consensus` tag from Task 1 and vote-account epoch-credit response.
- Produces: Tower-only compatibility fields and explicit `legacyVoteCreditsTotal`, `legacyVoteCreditsEpoch`, `legacyVoteCreditEfficiencyPct` fields.

- [ ] **Step 1: Write failing assertions for both consensus modes**

Add a mainnet fixture assertion:

```bash
assert_contains "$mainnet_output" 'legacyVoteCreditsTotal=123456i'
assert_contains "$mainnet_output" 'legacyVoteCreditsEpoch=456i'
assert_contains "$mainnet_output" 'legacyVoteCreditEfficiencyPct=12.34'
```

Add an Alpenglow testnet assertion:

```bash
[[ "$testnet_output" != *'credits='* ]] || fail 'Alpenglow must not emit Tower credits'
[[ "$testnet_output" != *'pctVote='* ]] || fail 'Alpenglow must not emit Tower vote-credit efficiency'
```

- [ ] **Step 2: Run the focused test and observe RED**

Run: `bash tests/test-monitor.sh`

Expected: FAIL because testnet currently emits `credits`, `validatorCreditsCurrent`, and `pctVote`.

- [ ] **Step 3: Implement Tower-only emission**

Build the output field list conditionally. When `consensus=tower`, append both compatibility and explicit legacy fields. When `consensus=alpenglow` or `unknown`, omit this field family completely. Do not emit replacement zeros.

- [ ] **Step 4: Run collector and dashboard tests**

Run: `bash tests/test-monitor.sh && bash tests/test-dashboard.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add monitor.sh tests/test-monitor.sh tests/fixtures/mock-monitor-curl README.md
git commit -m "fix: omit Tower vote-credit efficiency on Alpenglow"
```

### Task 3: Preserve production-data provenance

**Files:**
- Modify: `monitor.sh`
- Modify: `tests/test-monitor.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: supplemental batch success/failure state.
- Produces: `productionDataOk`; production fields only after a valid `getBlockProduction` result.

- [ ] **Step 1: Write the failing batch-failure test**

Replace the existing false-zero expectation with:

```bash
assert_contains "$batch_output" 'productionDataOk=0i'
[[ "$batch_output" != *'leaderSlots='* ]] || fail 'failed production RPC must not create zero production metrics'
```

- [ ] **Step 2: Run the focused test and observe RED**

Run: `bash tests/test-monitor.sh`

Expected: FAIL because the collector emits `leaderSlots=0i` after a supplemental batch failure.

- [ ] **Step 3: Implement conditional production fields**

Track supplemental batch validity separately from required vote-account validity. Emit normal non-production fields where supported, `productionDataOk=0`, and no scheduled-slot production family on failure.

- [ ] **Step 4: Run all tests**

Run: `bash tests/test-monitor.sh && bash tests/test-dashboard.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add monitor.sh tests/test-monitor.sh README.md
git commit -m "fix: preserve scheduled-slot production provenance"
```

### Task 4: Scope the Grafana dashboard and correct labels

**Files:**
- Modify: `grafana/solana-community-validator-dashboard.json`
- Modify: `grafana/enhance-dashboard.jq`
- Modify: `grafana/optimize-dashboard.jq`
- Modify: `tests/test-dashboard.sh`

**Interfaces:**
- Consumes: schema-v2 tags and fields from Tasks 1–3.
- Produces: mandatory cluster/genesis/pubkey/vote-account variables and query selectors that cannot return cross-cluster data.

- [ ] **Step 1: Write failing dashboard structural tests**

Add jq assertions that require variables `cluster`, `genesis`, `pubkey`, and `vote_account`; then enumerate every PromQL expression that begins with `nodemonitor_` and fail if its selector lacks `cluster=`, `genesis=`, and `pubkey=` when the panel is validator-specific.

Add assertions that panel titles contain:

```text
Scheduled slots with a block present
Scheduled-slot absence
```

and that the legacy credit-efficiency panel includes a clear Tower-only description.

- [ ] **Step 2: Run the dashboard test and observe RED**

Run: `bash tests/test-dashboard.sh`

Expected: FAIL because the dashboard has no cluster/genesis/vote-account variables and unscoped `nodemonitor_*` selectors.

- [ ] **Step 3: Update variable dependency order and queries**

Add single-select `$cluster` and `$genesis`, then use them in `$pubkey` and `$vote_account` discovery. Use `collectorUp` as the primary tagged series for selector discovery. Add exact tags to each validator query. Do not apply the tags to host-only Telegraf metric queries after the server variable has been resolved.

- [ ] **Step 4: Correct consensus-facing copy**

Rename leader/skip panels to scheduled-slot production terminology and state their `getBlockProduction` provenance. Limit legacy credit panels to `consensus="tower"`; add a text panel explaining that Tower credit efficiency is not defined for Alpenglow.

- [ ] **Step 5: Verify transformation idempotence and dashboard test suite**

Run: `bash tests/test-dashboard.sh`

Expected: `dashboard tests passed`.

- [ ] **Step 6: Commit**

```bash
git add grafana/solana-community-validator-dashboard.json grafana/enhance-dashboard.jq grafana/optimize-dashboard.jq tests/test-dashboard.sh
git commit -m "feat: isolate Grafana metrics by cluster consensus"
```

### Task 5: Publish operational migration guidance and verify the public repository

**Files:**
- Modify: `README.md`
- Modify: `docs/installation.md`
- Modify: `CHANGELOG.md`
- Create: `docs/alpenglow-monitoring-migration.md`

**Interfaces:**
- Consumes: schema-v2 collector and dashboard changes.
- Produces: a no-mixing rollout process for maintainers and community validators.

- [ ] **Step 1: Add migration acceptance checklist**

Document a canary protocol with one mainnet-beta and one testnet validator using the same identity where possible. Require exact inspected tags, no testnet `pctVote`, and an empty result when querying mainnet genesis against a testnet identity series.

- [ ] **Step 2: State historical-data policy**

Document that existing records without `cluster` and `genesis` are legacy-unclassified; they cannot enter normal mainnet/testnet views and must not be attributed from pubkey alone.

- [ ] **Step 3: Run every repository verification command**

Run:

```bash
bash tests/test-monitor.sh
bash tests/test-dashboard.sh
git diff --check
git status --short
```

Expected: both tests pass, no whitespace errors, only intended documentation/source changes before commit.

- [ ] **Step 4: Commit and push**

```bash
git add README.md docs/installation.md CHANGELOG.md docs/alpenglow-monitoring-migration.md
git commit -m "docs: add Alpenglow monitoring migration"
git push origin main
```

- [ ] **Step 5: Verify remote state**

Run:

```bash
git ls-remote origin refs/heads/main
git status --short
git log -1 --oneline
```

Expected: remote main equals local HEAD and working tree is clean.

## Self-review

- Schema identity, credit semantics, production provenance, dashboard scoping, and rollout are covered by Tasks 1–5.
- Every behavior-changing task begins with a test that must fail before implementation.
- New collector values use tagged schema-v2 series rather than a historical-data rewrite.
- There are no placeholder steps or unverified synthetic Alpenglow metrics.
