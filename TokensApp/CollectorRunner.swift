import Foundation
import Darwin

public enum RunnerError: Error, Equatable, LocalizedError {
    case helperMissing
    case timedOut
    case failed(code: Int32, stderr: String)
    case cancelled
    case badOutput(String)

    public var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "未找到内置采集程序"
        case .timedOut:
            return "采集超时，已保留上次成功统计"
        case .failed(let code, let stderr):
            let tail = stderr.split(separator: "\n").last.map(String.init) ?? ""
            return tail.isEmpty ? "采集失败（退出 \(code)），已保留上次成功统计" : "\(tail)（已保留上次成功统计）"
        case .cancelled:
            return "已取消"
        case .badOutput(let what):
            return "采集结果异常：\(what)（已保留上次成功统计）"
        }
    }
}

public final class CollectorRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?

    public init() {}

    public static func helperURL() -> URL? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let bundled = exe.deletingLastPathComponent().appendingPathComponent("tokens-collector")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return nil
    }

    public func cancel() {
        currentProcess()?.terminate()
    }

    public var currentProcessIdentifier: pid_t? {
        lock.lock(); defer { lock.unlock() }
        guard let process = current, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private func currentProcess() -> Process? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    private func setCurrent(_ process: Process?) {
        lock.lock(); defer { lock.unlock() }
        current = process
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 180
    ) async throws -> (data: Data, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let extra = environment {
            var env = ProcessInfo.processInfo.environment
            env.merge(extra) { _, new in new }
            process.environment = env
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw RunnerError.helperMissing
        }
        setCurrent(process)
        defer {
            if currentProcess() === process { setCurrent(nil) }
        }
        return try await withTaskCancellationHandler {
            try await self.monitor(process: process, outPipe: outPipe, errPipe: errPipe, timeout: timeout)
        } onCancel: {
            process.terminate()
        }
    }

    private func monitor(process: Process, outPipe: Pipe, errPipe: Pipe, timeout: TimeInterval) async throws -> (data: Data, stderr: String) {
        let outTask = Task.detached(priority: .utility) {
            outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errTask = Task.detached(priority: .utility) {
            errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        do {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() > deadline { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                terminateGracefully(process)
                _ = await outTask.value
                _ = await errTask.value
                throw RunnerError.timedOut
            }
            let outData = await outTask.value
            let errData = await errTask.value
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw RunnerError.failed(code: process.terminationStatus, stderr: stderr)
            }
            guard !outData.isEmpty else { throw RunnerError.badOutput("空输出") }
            return (outData, stderr)
        } catch {
            terminateGracefully(process)
            _ = await outTask.value
            _ = await errTask.value
            if error is CancellationError { throw RunnerError.cancelled }
            throw error
        }
    }

    private func terminateGracefully(_ process: Process) {
        if process.isRunning { process.terminate() }
        let termDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < termDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        setCurrent(nil)
    }
}
