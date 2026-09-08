import SwiftUI
import AppKit

@MainActor
final class SandboxCheck: ObservableObject {
    @Published var message = "选择合成日志目录，再执行采集。已保存的授权会在重启后恢复。"
    @Published var selected: [String] = []
    @Published var running = false
    private var bookmarks: [String: Data]
    private let destinations = ["codex": ".codex/sessions", "claude": ".claude/projects", "opencode": ".local/share/opencode"]

    init() {
        bookmarks = UserDefaults.standard.dictionary(forKey: "sourceBookmarks") as? [String: Data] ?? [:]
        selected = bookmarks.keys.sorted()
    }

    func choose(_ client: String) {
        let panel = NSOpenPanel()
        panel.title = "授权 \(client) 日志目录（只读）"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            bookmarks[client] = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarks, forKey: "sourceBookmarks")
            selected = bookmarks.keys.sorted()
            message = "已保存 \(client) 只读目录授权"
        } catch { message = "授权保存失败：\(error)" }
    }

    func clear() {
        bookmarks.removeAll()
        UserDefaults.standard.removeObject(forKey: "sourceBookmarks")
        selected = []
        message = "已清除保存的授权"
    }

    func run(negative: Bool = false) {
        guard !running else { return }
        running = true
        Task {
            defer { running = false }
            var active: [URL] = []
            defer { active.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("SandboxCheck", isDirectory: true)
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let home = support.appendingPathComponent("home", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                for relative in destinations.values {
                    let link = home.appendingPathComponent(relative)
                    if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                        try FileManager.default.removeItem(at: link)
                    }
                }
                if !negative {
                    guard !bookmarks.isEmpty else { throw CheckError.noGrant }
                    for client in bookmarks.keys.sorted() {
                        var stale = false
                        let url = try URL(resolvingBookmarkData: bookmarks[client]!, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                        guard url.startAccessingSecurityScopedResource() else { throw CheckError.invalidGrant(client) }
                        active.append(url)
                        if stale {
                            bookmarks[client] = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                            UserDefaults.standard.set(bookmarks, forKey: "sourceBookmarks")
                        }
                        guard let relative = destinations[client] else { throw CheckError.invalidGrant(client) }
                        let link = home.appendingPathComponent(relative)
                        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
                    }
                }
                let scanHome: String
                let clients: String
                if negative {
                    guard let denied = Bundle.main.object(forInfoDictionaryKey: "ProbeDeniedHome") as? String else { throw CheckError.noGrant }
                    scanHome = denied
                    clients = "codex"
                } else {
                    scanHome = home.path
                    clients = selected.joined(separator: ",")
                }
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tokens-collector")
                let args = ["scan", "--home", scanHome, "--config-dir", support.appendingPathComponent("config").path,
                            "--timezone", "Asia/Shanghai", "--since", "2026-09-01", "--until", "2026-09-30", "--hourly-date", "2026-09-08", "--clients", clients]
                let (code, output, diagnostics) = try await Self.collect(helper: helper, args: args)
                var result: [String: Any] = ["exitCode": code, "negativeProbe": negative, "savedGrantCount": bookmarks.count,
                                             "appHome": NSHomeDirectory(), "diagnostics": diagnostics]
                if let data = try? JSONSerialization.jsonObject(with: output) as? [String: Any] {
                    result["snapshot"] = data
                }
                let encoded = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try encoded.write(to: support.appendingPathComponent("last-result.json"), options: .atomic)
                if negative {
                    message = code != 0 && output.isEmpty ? "PASS：未授权目录读取被拒绝" : "FAIL：未授权目录竟然可读"
                } else if code == 0 {
                    let root = try JSONSerialization.jsonObject(with: output) as! [String: Any]
                    let daily = root["daily"] as? [[String: Any]] ?? []
                    var total: Int64 = 0
                    for day in daily {
                        for client in day["clients"] as? [[String: Any]] ?? [] {
                            for model in client["models"] as? [[String: Any]] ?? [] {
                                for value in (model["tokens"] as? [String: NSNumber] ?? [:]).values { total += value.int64Value }
                            }
                        }
                    }
                    message = "PASS：沙盒采集成功 · \(total) Token · \(bookmarks.count) 个已恢复授权"
                } else { message = "FAIL：采集退出\(code) · \(diagnostics)" }
            } catch { message = "FAIL：\(error)" }
        }
    }

    enum CheckError: Error { case noGrant, invalidGrant(String) }

    nonisolated static func collect(helper: URL, args: [String]) async throws -> (Int32, Data, String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = helper
            process.arguments = args
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            async let output: Data = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let diagnostics: Data = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
            process.waitUntilExit()
            return await (process.terminationStatus, output, String(data: diagnostics, encoding: .utf8) ?? "")
        }.value
    }
}

@main
struct SandboxCheckApp: App {
    @StateObject private var state = SandboxCheck()
    var body: some Scene {
        Window("Tokly 沙盒验证", id: "sandbox-check") {
            VStack(alignment: .leading, spacing: 16) {
                Text("沙盒目录授权与真实采集器验证").font(.title2)
                HStack {
                    Button("授权 Codex") { state.choose("codex") }
                    Button("授权 Claude") { state.choose("claude") }
                    Button("授权 OpenCode") { state.choose("opencode") }
                }.disabled(state.running)
                Text("已保存：\(state.selected.joined(separator: ", "))")
                HStack {
                    Button("执行采集") { state.run() }
                    Button("验证未授权读取") { state.run(negative: true) }
                    Button("清除授权") { state.clear() }
                }.disabled(state.running)
                Text(state.running ? "采集中…" : state.message).textSelection(.enabled)
            }.padding(24).frame(width: 700, height: 250)
        }
    }
}
