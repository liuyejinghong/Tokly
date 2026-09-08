import SwiftUI
import AppKit
import WidgetKit

@MainActor
final class PrepModel: ObservableObject {
    @Published var snapshot: PrepSnapshot?
    @Published var errorMessage: String?
    @Published var lastSuccess: Date?
    @Published var pendingUpdate = false
    @Published var lastWriteWasActive: Bool?

    private static let baseTokens: Int64 = 160
    private static let stepTokens: Int64 = 160

    private static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }

    static func formatTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return timeFormatter.string(from: date)
    }

    /// Load only; never writes. Distinguishes missing snapshot from bad data via thrown errors.
    func load() {
        do {
            let read = try PrepStore.read()
            snapshot = read
            lastSuccess = Date()
            errorMessage = nil
        } catch {
            snapshot = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Synthetic reset: tokens=160, revision=1.
    func writeBase() {
        do {
            let next = PrepSnapshot(tokens: Self.baseTokens, updatedAt: Date(), revision: 1)
            lastWriteWasActive = NSApp.isActive
            try PrepStore.write(next)
            snapshot = next
            lastSuccess = Date()
            errorMessage = nil
            WidgetCenter.shared.reloadTimelines(ofKind: PrepStore.widgetKind)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Schedules increment() after 15 seconds without activating any window.
    func scheduleDelayedIncrement() {
        guard !pendingUpdate else { return }
        pendingUpdate = true
        // Hide after the UI action completes, before the delayed write.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.hide(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.pendingUpdate = false
            self.increment()
        }
    }

    /// Read persisted snapshot first, then tokens+=160 and revision+=1.
    func increment() {
        do {
            var current = try PrepStore.read()
            current.tokens += Self.stepTokens
            current.revision += 1
            current.updatedAt = Date()
            lastWriteWasActive = NSApp.isActive
            try PrepStore.write(current)
            snapshot = current
            lastSuccess = Date()
            errorMessage = nil
            WidgetCenter.shared.reloadTimelines(ofKind: PrepStore.widgetKind)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct PrepContentView: View {
    @EnvironmentObject var model: PrepModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tokens 前置验证")
                .font(.headline)
            Text("合成数据，仅验证用")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            if let snapshot = model.snapshot {
                Text("Token：\(snapshot.tokens)")
                Text("Revision：\(snapshot.revision)")
                Text("快照时间：\(PrepModel.formatTime(snapshot.updatedAt))")
            } else {
                Text("暂无有效快照")
                    .foregroundStyle(.secondary)
            }
            Text("最近成功读取：\(PrepModel.formatTime(model.lastSuccess))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let active = model.lastWriteWasActive {
                Text("写入时前台：\(active ? "是" : "否")")
                    .font(.caption)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            HStack(spacing: 8) {
                Button("写入 160 Token") { model.writeBase() }
                Button("增加 160 Token") { model.increment() }
                Button("重新读取") { model.load() }
            }
            HStack(spacing: 8) {
                Button("15秒后增加160") { model.scheduleDelayedIncrement() }
                    .disabled(model.pendingUpdate)
                if model.pendingUpdate {
                    Text("等待后台更新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(minWidth: 300)
        .onAppear { model.load() }
    }
}

@main
struct PrepApp: App {
    @StateObject private var model = PrepModel()

    var body: some Scene {
        Window("Tokens 前置验证", id: "tokens-prep-main") {
            PrepContentView()
                .environmentObject(model)
                .onOpenURL { _ in model.load() }
        }
        .defaultSize(width: 560, height: 300)
        MenuBarExtra("Tokens 前置验证", systemImage: "chart.bar") {
            PrepContentView()
                .environmentObject(model)
        }
    }
}
