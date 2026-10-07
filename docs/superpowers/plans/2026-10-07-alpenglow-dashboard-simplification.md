# Plain-Language Alpenglow Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the technical Alpenglow collector panels with a truthful, plain-language inclusion-rate, vote-count, and history view.

**Architecture:** Keep the existing schema-v2 RPC-derived fields and dashboard scoping. Migrate panel IDs 168–172 idempotently into three panels, gate all displayed inclusion data on collector readiness and a positive denominator, and preserve gaps instead of fabricating zeroes. The root dashboard JSON remains the canonical file; `grafana/solana-community-validator-dashboard.json` is its tracked symlink.

**Tech Stack:** Bash tests, jq dashboard transformation, Grafana 9.2 JSON, PromQL/VictoriaMetrics.

**Spec:** `docs/superpowers/specs/2026-10-07-alpenglow-dashboard-simplification-design.md`

## Global Constraints

- The primary view must show estimated inclusion rate, included count, estimated possible count, estimated missed count, and inclusion-rate history.
- Warm-up and unavailable intervals must show `Collecting vote data` or a gap, never a fabricated `0%`.
- Every new panel must identify the signal as an RPC-derived estimate from a bounded reference cohort and not direct certificate telemetry.
- Every query must retain exact `cluster`, `genesis`, `consensus="alpenglow"`, `pubkey`, and `vote_account` scoping after `scope_nodemonitor` runs.
- Tower panels and their `consensus="tower"` scoping must remain unchanged.
- Remove panel IDs `170` and `172`; reuse `168`, `169`, and `171`.
- Add no collector fields, metric labels, dependencies, or Grafana plugins.
- Preserve dashboard transformation idempotence and bounded history resolution.
- Do not modify or stage the unrelated `.superpowers/` directory.

---

### Task 1: Replace technical Alpenglow panels with the operator view

**Files:**
- Modify: `tests/test-dashboard.sh:247-276`
- Modify: `grafana/enhance-dashboard.jq:105-137,292-295,670-732`
- Regenerate: `Solana Community Validator Dashboard-1623239777455.json`
- Verify symlink: `grafana/solana-community-validator-dashboard.json`

**Interfaces:**
- Consumes: existing `nodemonitor_alpenglowObservedReady`, `Included`, `Expected`, and `Missed` gauges.
- Produces: panel `168` rate stat, panel `169` three-value count stat, and panel `171` rate-history time series.

- [ ] **Step 1: Replace the old dashboard assertions with failing plain-language assertions**

In `tests/test-dashboard.sh`, replace the old panel-168-through-172 block with assertions equivalent to:

```jq
any(.panels[];
  .id == 168
  and .title == "Alpenglow vote inclusion rate"
  and .type == "stat"
  and .fieldConfig.defaults.unit == "percent"
  and .fieldConfig.defaults.noValue == "Collecting vote data"
  and (.description | contains("RPC-derived estimate"))
  and (.description | contains("not direct certificate telemetry"))
  and (.targets[0].expr | contains("nodemonitor_alpenglowObservedIncluded"))
  and (.targets[0].expr | contains("nodemonitor_alpenglowObservedExpected"))
  and (.targets[0].expr | contains("nodemonitor_alpenglowObservedReady"))
)
and any(.panels[];
  .id == 169
  and .title == "Alpenglow vote counts"
  and .type == "stat"
  and .fieldConfig.defaults.noValue == "Collecting vote data"
  and ([.targets[].legendFormat] == ["Included", "Estimated possible", "Estimated missed"])
  and ([.targets[].expr] | all(.[]; contains("nodemonitor_alpenglowObservedReady")))
)
and any(.panels[];
  .id == 171
  and .title == "Alpenglow inclusion rate history"
  and .type == "timeseries"
  and .fieldConfig.defaults.unit == "percent"
  and .fieldConfig.defaults.custom.spanNulls == false
  and (.targets[0].expr | contains("nodemonitor_alpenglowObservedIncluded"))
  and (.targets[0].expr | contains("nodemonitor_alpenglowObservedExpected"))
  and (.targets[0].expr | contains("nodemonitor_alpenglowObservedReady"))
)
and ([.panels[].id] | index(170) == null)
and ([.panels[].id] | index(172) == null)
and ([.panels[].title // ""] | all(.[];
  test("opportunities|observed shortfall|unattributed accounts|observed inclusion readiness|observed snapshot slot"; "i") | not
))
```

Also assert every new target contains the transformed `cluster`, `genesis`, `consensus="alpenglow"`, `pubkey`, and `vote_account` selectors.

- [ ] **Step 2: Run the dashboard test and verify RED**

Run:

```bash
bash tests/test-dashboard.sh
```

Expected: failure in the new Alpenglow operator-view assertion because the dashboard still contains readiness, unattributed, reference, interval-count, and snapshot-slot panels.

- [ ] **Step 3: Implement idempotent panel migration in the jq source**

In `grafana/enhance-dashboard.jq`:

1. Replace `observed_inclusion_panel` with a time-series panel using ID `171`, title `Alpenglow inclusion rate history`, percent unit, `spanNulls: false`, and one target named `Inclusion rate`.
2. Use a raw history expression of this form before automatic scope expansion:

```promql
(
  100 * nodemonitor_alpenglowObservedIncluded{consensus="alpenglow",pubkey="$pubkey"}
  / nodemonitor_alpenglowObservedExpected{consensus="alpenglow",pubkey="$pubkey"}
)
and nodemonitor_alpenglowObservedReady{consensus="alpenglow",pubkey="$pubkey"} == 1
and nodemonitor_alpenglowObservedExpected{consensus="alpenglow",pubkey="$pubkey"} > 0
```

3. Define the migration states separately:

```jq
(any(.panels[]; ([168,169,170,171,172] | index(.id)) != null)) as $observed_inclusion_present
| (
    any(.panels[]; .id == 168 and .title == "Alpenglow vote inclusion rate")
    and any(.panels[]; .id == 169 and .title == "Alpenglow vote counts")
    and any(.panels[]; .id == 171 and .title == "Alpenglow inclusion rate history")
    and (all(.panels[]; .id != 170 and .id != 172))
  ) as $observed_inclusion_done
```

4. If the new view is already present, do nothing. If any old Alpenglow panel is present, remove IDs `168`, `169`, `170`, `171`, and `172`, then shift existing lower panels at `y >= 66` down by one row because the new section is one row taller than the old section. If none is present, shift panels at `y >= 55` by 12 rows once; the history panel at `y=59`, height `8` occupies rows through `66`. Then add:
   - ID `168`, `Alpenglow vote inclusion rate`, stat, `8×4` at `(0,55)`, percent, no-value `Collecting vote data`.
   - ID `169`, `Alpenglow vote counts`, stat, `16×4` at `(8,55)`, three targets, no-value `Collecting vote data`.
   - ID `171`, history, `24×8` at `(0,59)`.
5. Rate stat expression:

```promql
(
  100 * last_over_time(nodemonitor_alpenglowObservedIncluded{consensus="alpenglow",pubkey="$pubkey"}[5m])
  / last_over_time(nodemonitor_alpenglowObservedExpected{consensus="alpenglow",pubkey="$pubkey"}[5m])
)
and last_over_time(nodemonitor_alpenglowObservedReady{consensus="alpenglow",pubkey="$pubkey"}[5m]) == 1
and last_over_time(nodemonitor_alpenglowObservedExpected{consensus="alpenglow",pubkey="$pubkey"}[5m]) > 0
```

6. Each count target uses `last_over_time(<metric>[5m])` and is gated with both readiness equal to one and expected greater than zero. Legends are exactly `Included`, `Estimated possible`, and `Estimated missed`.
7. Update the generic stat normalization so panels `168` and `169` retain `Collecting vote data`; every other stat keeps `No recent data`.
8. Descriptions must contain the phrases `RPC-derived estimate` and `not direct certificate telemetry`.

- [ ] **Step 4: Regenerate the canonical dashboard**

Run the enhancement through a temporary file so the symlink target is updated atomically:

```bash
tmp="$(mktemp)"
jq -f grafana/enhance-dashboard.jq grafana/solana-community-validator-dashboard.json >"$tmp"
mv "$tmp" 'Solana Community Validator Dashboard-1623239777455.json'
```

Verify the symlink still resolves to the canonical root file:

```bash
stat -c '%N' grafana/solana-community-validator-dashboard.json
```

Expected: `grafana/solana-community-validator-dashboard.json -> ../Solana Community Validator Dashboard-1623239777455.json`.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
bash tests/test-dashboard.sh
```

Expected: `dashboard tests passed`.

- [ ] **Step 6: Run full verification**

Run:

```bash
bash -n monitor.sh scripts/alpenglow-observed-vote-inclusion.sh tests/test-monitor.sh tests/test-dashboard.sh tests/test-telegraf.sh
bash tests/test-monitor.sh
bash tests/test-dashboard.sh
bash tests/test-telegraf.sh
git diff --check
```

Expected output includes:

```text
monitor tests passed
dashboard tests passed
telegraf configuration tests passed
```

- [ ] **Step 7: Commit the implementation**

```bash
git add grafana/enhance-dashboard.jq tests/test-dashboard.sh 'Solana Community Validator Dashboard-1623239777455.json'
git commit -m "feat: simplify Alpenglow inclusion dashboard"
```
