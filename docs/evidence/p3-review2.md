# P3 second review

Independent PASS61 scheduler + PASS13 real synthetic runner + build success. Cancellation/drain, dynamic menu/action and filter fixes retained. Not accepted yet:

- maybePriceRefresh checks lastPriceAttempt only after completion; while fetch pending, another applySuccess/onAppear cancels existing task and starts another on same runner. Set attempt before dispatch and guard managed in-flight task; defer clears it. Cancellation should not masquerade as network failure.
- RangeProjection.rangeTotal only takes entries and returns nil for empty, lacking coverage. Return zero for fully covered empty range, nil for missing/partly uncovered past days; actual AppState must pass snapshot and requested days. Add production projection executable tests, now included check-app script as Tests/ProjectionChecks.swift plus Shared/RangeProjection, sample path arg.
- Configuration change hides main in-memory snapshot but leaves group widget-snapshot.json intact; extension would continue disabled-source data. Explicitly invalidate only this app-owned Widget artifact and reload; P4 will show missing placeholder. Never replace with fabricated zero. Surface failures.
- scan.json and scan-record.json written separately can mismatch after interrupted second write. Avoid redundant sidecar: selected clients and timezone already exist in snapshot.sources/timezone (collector explicit selection). Derive saved config from those, one atomic response artifact; verify returned snapshot matches captured request before accepting. No unshipped compatibility layer.
- Old generation scan errors still call setError after selection switch. Gate error application as well as success; quit completion must not schedule new pending scans.
