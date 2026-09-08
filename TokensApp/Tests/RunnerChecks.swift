import Foundation
import Darwin

// Synthetic runner checks: exercise the production CollectorRunner seam
// against the fixture executable path given as argv[1]. No real helper,
// no HOME, no network.
@main
struct RunnerChecks {
    static var passes = 0
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        if cond {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(msg)")
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    static func readPid(_ path: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return pid
    }

    static func nap(_ nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    static func waitForRunnerPid(_ runner: CollectorRunner) async -> pid_t? {
        for _ in 0..<200 {
            if let pid = runner.currentProcessIdentifier { return pid }
            await nap(50_000_000)
        }
        return nil
    }

    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            print("FAIL: fixture path required as first argument")
            exit(1)
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-checks-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. Dual-pipe large output drains fully without deadlock.
        do {
            let runner = CollectorRunner()
            let (data, err) = try await runner.run(
                executableURL: fixture, arguments: ["big", "3000000"], timeout: 30)
            check(data.count == 3000000, "stdout drained fully (\(data.count))")
            check(err.utf8.count == 3000000, "stderr drained fully (\(err.utf8.count))")
        } catch {
            check(false, "big output drains: \(error)")
        }

        // 2. Task cancellation terminates and reaps the child.
        do {
            let runner = CollectorRunner()
            let pidfile = work.appendingPathComponent("cancel.pid").path
            let task = Task {
                try await runner.run(
                    executableURL: fixture,
                    arguments: ["sleep", "60", "--pidfile", pidfile], timeout: 60)
            }
            if let pid = await waitForRunnerPid(runner) {
                check(isAlive(pid), "fixture running before cancel")
                if let filePid = readPid(pidfile) {
                    check(filePid == pid, "fixture reports its own pid")
                } else {
                    check(false, "fixture pidfile written")
                }
                task.cancel()
                let result = await task.result
                switch result {
                case .failure(let error as RunnerError):
                    check(error == .cancelled, "cancel surfaces .cancelled")
                case .failure(let error):
                    check(false, "cancel surfaces .cancelled (got \(error))")
                case .success:
                    check(false, "cancel does not succeed")
                }
                await nap(300_000_000)
                check(!isAlive(pid), "cancelled child reaped")
            } else {
                print("DIAG: runner pid never appeared; task done=\(task.isCancelled)")
                check(false, "cancel fixture started")
                task.cancel()
                _ = await task.result
            }
        }

        // 3. Timeout kills even a SIGTERM-resistant child.
        do {
            let runner = CollectorRunner()
            let pidfile = work.appendingPathComponent("timeout.pid").path
            let runTask = Task {
                try await runner.run(
                    executableURL: fixture,
                    arguments: ["sleep", "60", "--ignore-term", "--pidfile", pidfile], timeout: 1)
            }
            let start = Date()
            let result = await runTask.result
            switch result {
            case .failure(let error as RunnerError):
                check(error == .timedOut, "timeout surfaces .timedOut")
            case .failure(let error):
                check(false, "timeout surfaces .timedOut (got \(error))")
            case .success:
                check(false, "timeout throws")
            }
            check(Date().timeIntervalSince(start) < 20, "timeout cleanup bounded")
            if let pid = readPid(pidfile) {
                await nap(300_000_000)
                check(!isAlive(pid), "SIGTERM-resistant child reaped via SIGKILL")
            } else {
                check(false, "timeout fixture pid recorded")
            }
        }

        // 4. Nonzero exit surfaces code + stderr.
        do {
            let runner = CollectorRunner()
            do {
                _ = try await runner.run(
                    executableURL: fixture, arguments: ["exit", "3", "boom happened"], timeout: 10)
                check(false, "nonzero exit throws")
            } catch let error as RunnerError {
                switch error {
                case .failed(let code, let stderr):
                    check(code == 3, "exit code preserved")
                    check(stderr.contains("boom happened"), "stderr preserved")
                default:
                    check(false, "nonzero exit is .failed (got \(error))")
                }
            } catch {
                check(false, "nonzero exit is .failed (got \(error))")
            }
        }

        // 5. Missing executable.
        do {
            let runner = CollectorRunner()
            do {
                _ = try await runner.run(
                    executableURL: URL(fileURLWithPath: "/nonexistent/tokens-collector"),
                    arguments: [], timeout: 5)
                check(false, "missing helper throws")
            } catch let error as RunnerError {
                check(error == .helperMissing, "missing helper surfaces .helperMissing")
            } catch {
                check(false, "missing helper surfaces .helperMissing (got \(error))")
            }
        }

        // 6. Empty stdout is a bad-output failure, not a silent zero.
        do {
            let runner = CollectorRunner()
            do {
                _ = try await runner.run(
                    executableURL: fixture, arguments: ["exit", "0"], timeout: 10)
                check(false, "empty stdout throws")
            } catch let error as RunnerError {
                check(error == .badOutput("空输出"), "empty stdout is .badOutput")
            } catch {
                check(false, "empty stdout is .badOutput (got \(error))")
            }
        }

        print("PASS \(passes) runner checks, FAIL \(failures)")
        if failures > 0 { exit(1) }
    }
}
