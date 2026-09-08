import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("数据来源").font(.title2.weight(.medium))
                        Text("自动发现这台 Mac 上的用量记录").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新检测") { state.requestScan(userInitiated: true) }
                        .disabled(state.isScanning)
                }
                if let err = state.lastError {
                    ErrorBanner(message: err, snapshotLabel: state.lastSuccessAt.map { "上次成功 " + Format.updatedText($0) }, onRetry: { state.retry() })
                }
                VStack(spacing: 0) {
                    ForEach(SourceRegistry.orderedForOnboarding) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Text(String(entry.displayName.prefix(2))).font(.caption).frame(width: 32, height: 32)
                                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.displayName).font(.headline)
                                    statusTag(entry.id)
                                }
                                Text(entry.pathHint).font(.caption2).foregroundStyle(.secondary)
                                Text("仅统计已启用来源在这台设备上的记录；不读取账号数据。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("纳入统计", isOn: Binding(
                                get: { state.enabledClients.contains(entry.id) },
                                set: { state.setEnabled(entry.id, on: $0) }))
                                .labelsHidden()
                        }
                        .padding(12)
                        Divider()
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
                HStack {
                    Text("统计范围").font(.callout)
                    Text("仅统计已启用来源在这台设备上的记录").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(state.enabledClients.count) 个已启用").font(.callout).foregroundStyle(.secondary)
                }
                Text("Codex、Claude Code、OpenCode 已完成本机口径核对；其他来源尚未逐一验证。").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Text("更新于 \(Format.updatedText(state.lastSuccessAt))")
                    Spacer()
                    Text("统计保存在本机").foregroundStyle(.secondary)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle("来源")
    }

    @ViewBuilder
    private func statusTag(_ id: String) -> some View {
        if state.filteredSnapshot() == nil {
            Text("尚未检测").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.secondary)
        } else if let s = state.filteredSnapshot()?.sources.first(where: { $0.clientId == id }) {
            if s.status == .found {
                Text("已发现").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.green)
            } else {
                Text("未发现记录").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("未发现记录").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.secondary)
        }
    }
}
