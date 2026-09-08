# P3 first review

Independent check-app: PASS48 and BUILD SUCCEEDED. Implementation not accepted yet.

1. CollectorRunner.run Task.sleep can throw CancellationError before process.terminate, leaving child running; timeout only signals then returns without reaping. AppDelegate terminateNow schedules asynchronous cancellation that may never run; detached price task is untracked. Fix cancellation/quit cleanup with actual synthetic process tests.
2. enabledClients persisted empty is reset to three defaults on restart. Changed selection keeps old snapshot used by unfiltered menu/widget and chart paths; persisted snapshot not checked against enabled set/timezone. Scope last success to its request; never relabel old sources as new. Do not scan when empty; ignore stale successes and errors.
3. rangeTotal returns zero for uncovered requested range. After midnight yesterday snapshot becomes Today0 rather than unknown/dated stale. lastSuccessAt uses Date()/file mtime instead of generatedAt. Preserve coverage/freshness; surface private/widget write errors currently swallowed.
4. Overview today and month daily chart ignore client filter; client tree is latest single day even when range is week/month. Weekly future and missing-cost charts emit zero marks. Use consistent filtered range projection, nil absent marks, range-client/model totals. Models table shares need label that denominator is selected total.
5. MenuBarExtra title static Tokens ignores menuMetric setting. Open window button only activates app without openWindow; deep link does not ensure closed window reopened; Models buttons set selectedModel but sheet only attached Overview. Connect these native actions, add explicit quit, dynamic today metric label.
6. onAppear and wake can enqueue two scans for one trigger (nil/day changed plus due). Day change has no direct notification/timer beyond cadence. Daily price gate only records successes so failures retry each scan; refresh failures hidden. Compose one trigger decision, day change signal, last attempt daily cap, surface price state without blocking tokens.

Checks must exercise production seams, not only helpers unused by AppState. No real user data or app launch by worker. Synthetic process fixture execution now explicitly permitted via check-app script. Visual/runtime acceptance remains Codex.
