import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("数据来源").font(.title2.weight(.medium))
                        Text(state.usesDirectoryGrants ? "只读取已授权的客户端日志目录" : "自动发现这台 Mac 上的用量记录").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新检测") { state.requestScan(userInitiated: true) }
                        .disabled(state.isScanning)
                }
                if let err = state.lastError {
                    ErrorBanner(message: err, snapshotLabel: state.lastSuccessAt.map { "上次成功 " + Format.updatedText($0) }, onRetry: { state.retry() })
                }
                if let error = state.directoryAccessError { Text(error).font(.caption).foregroundStyle(.orange) }
                VStack(spacing: 0) {
                    ForEach(state.availableSources) { entry in
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
                                if state.usesDirectoryGrants { SourceDirectoryControls(client: entry.id) }
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
        if !state.enabledClients.contains(id) {
            Text("未启用").font(.caption2).foregroundStyle(.secondary)
        } else if state.usesDirectoryGrants && !state.hasDirectoryGrant(client: id) {
            Text("未授权").font(.caption2).foregroundStyle(.secondary)
        } else if state.filteredSnapshot() == nil {
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

struct SourceDirectoryControls: View {
    @EnvironmentObject var state: AppState
    let client: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SourceDirectoryRole.all.filter { $0.client == client }) { role in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.label).font(.caption)
                        Text(state.directoryPath(role: role.id) ?? "尚未授权")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button(state.directoryPath(role: role.id) == nil ? "选择目录" : "更改") {
                        state.authorizeDirectory(role: role)
                    }.font(.caption)
                        .accessibilityLabel("选择\(SourceRegistry.displayName(for: client))\(role.label)")
                    if state.directoryPath(role: role.id) != nil {
                        Button("移除") { state.removeDirectory(role: role.id) }.font(.caption)
                            .accessibilityLabel("移除\(SourceRegistry.displayName(for: client))\(role.label)授权")
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
