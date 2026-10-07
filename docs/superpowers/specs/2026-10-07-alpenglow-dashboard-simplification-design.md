# Alpenglow Dashboard Simplification Design

**Date:** October 7, 2026

## Goal

Make the RPC-only Alpenglow section answer one operator question clearly: **Are my votes being included?**

Keep the existing observed/inferred metric semantics. Do not imply certificate-direct Votor evidence or identify validators that supposedly rejected a vote.

## Primary view

Replace the five technical panels—readiness, unattributed accounts, reference accounts, interval counts, and snapshot slot—with three understandable panels:

1. **Alpenglow vote inclusion rate**
   - Large percentage.
   - Formula: `included / estimated possible × 100`.
   - Emit no value when the collector is not ready or the estimated denominator is zero.
   - No-value text: **Collecting vote data**.

2. **Alpenglow vote counts**
   - Three values in one stat panel:
     - **Included**
     - **Estimated possible**
     - **Estimated missed**
   - No-value text: **Collecting vote data**.

3. **Alpenglow inclusion rate history**
   - One percentage line over the selected dashboard range.
   - Gaps remain gaps; unavailable intervals are not rewritten as zero.

## Language

Use plain operator language:

- `included` → **Included**
- `expected` → **Estimated possible**
- `missed` → **Estimated missed**
- `ready=0` → **Collecting vote data**

Do not display these collector terms as primary panels:

- opportunities
- observed shortfall
- unattributed accounts
- observed inclusion readiness
- observed snapshot slot

Reference count, unattributed coverage, readiness, and snapshot slot remain available in VictoriaMetrics and collector output for diagnostics, but do not compete with the primary dashboard.

## Truthfulness

Every panel description must say that the value is an **RPC-derived estimate** based on a bounded reference cohort and is not direct certificate telemetry.

The dashboard must not show which validator allegedly failed to include a vote. Standard RPC does not provide evidence for that attribution.

## Scope and isolation

- Apply only to `consensus="alpenglow"` series.
- Keep exact `cluster`, `genesis`, `pubkey`, and `vote_account` scoping.
- Keep Tower panels unchanged and restricted to `consensus="tower"`.
- Keep legacy untagged reporters outside the schema-v2 view.
- Add no new metric labels or collector fields.

## Grafana implementation

Use native Grafana stat and time-series panels only.

- Reuse panel IDs `168`, `169`, and `171` for the three new panels.
- Remove technical panels `170` and `172` from the enhanced dashboard.
- Gate inclusion-rate queries with readiness and a positive denominator so warm-up produces no value rather than `0%`.
- Clamp the displayed current and historical percentage to `100%`. The reference-derived denominator can occasionally be lower than the monitored validator's raw included count; the raw count panel remains available to expose that estimator overshoot.
- Treat old-panel migration and already-migrated detection separately: remove IDs `168`–`172`, add only `168`, `169`, and `171`, and make repeated enhancement byte-idempotent.
- A fresh dashboard without either Alpenglow panel set must shift lower panels by 12 rows; the history panel at `y=59`, height `8` occupies rows through `66`.
- `grafana/solana-community-validator-dashboard.json` is a symlink to the canonical root JSON, so regeneration updates one dashboard artifact while preserving both repository paths.
- Preserve bounded history resolution and existing dashboard layout/idempotence checks.

## Verification

- Regenerate the canonical dashboard JSON through the Grafana symlink and verify the root target and symlink still resolve to the same content.
- Assert the three plain-language panels and exact scoped PromQL queries.
- Assert panel IDs `170` and `172` are absent.
- Assert old technical titles and legends are absent.
- Assert Tower panel queries remain unchanged and consensus-scoped.
- Run dashboard, monitor, and Telegraf tests plus syntax and diff checks.
