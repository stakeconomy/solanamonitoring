# Release report

## 2026-10-07 — Alpenglow v3 cache validation and advancing-path performance

- Root cause: the normal advancing collector path repeatedly reparsed and rewrote the same state with per-account `jq` processes (75 `jq` executions observed before this fix), while the repeated-snapshot shortcut validated only cache keys and could preserve malformed exact-key cache values.
- Correctness: every fast return now validates leader-cache value type, canonical decimal encoding, signed-64 bounds, epoch bounds, strict ordering, and uniqueness. Invalid caches normalize/refetch; successor state receives the same full cache validation before rename.
- Performance: the same-epoch advancing path now validates/extracts the large state once, performs exact integer learner arithmetic in Bash, and applies all account/counter mutations in one `jq` pass. A live advancing trace used 13 `jq` executions / 36 total `execve` calls.
- RED: the new production-shaped advancing n=100 benchmark exceeded a 45-second harness timeout before optimization.
- GREEN benchmark: `production-shaped advancing timing: n=100 median=0.670s p99=0.840s max=0.847s state_bytes=383619`.
- Full-epoch regression: the 432,000-slot worst-case schedule fetch/persist test is independently bounded by a 10-second timeout and passes.
- Focused regression: malformed repeated-snapshot cache values are covered for object, scalar, null, duplicate, descending, overflow, pre-epoch, epoch-end, and noncanonical decimal forms.
- Live local Testnet RPC: 10 advancing samples were `1.040, 1.045, 1.011, 1.041, 1.015, 1.017, 1.025, 1.026, 1.033, 0.996s` (median `1.026s`, max `1.045s`) on a 65,151-byte selected-cohort state. The local RPC intermittently returned all nine requested account values as `null`; the collector correctly failed closed with no state mutation on those snapshots.
- Verification passed: focused collector tests, monitor tests, dashboard tests, Telegraf configuration tests, Bash syntax, ShellCheck, benchmark gate, and `git diff --check`.
