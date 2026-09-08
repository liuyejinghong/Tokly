import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var draft: Set<String> = ["codex", "claude", "opencode"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("开始统计这台 Mac 的用量").font(.title.weight(.medium))
                Text("选择本机数据来源，Token 与估算费用会汇总到一起。只读取本机已有记录，不同步账号数据。")
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(SourceRegistry.orderedForOnboarding) { entry in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading) {
                                Text(entry.displayName).font(.headline)
                                Text(entry.pathHint).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("纳入统计", isOn: Binding(
                                get: { draft.contains(entry.id) },
                                set: { if $0 { draft.insert(entry.id) } else { draft.remove(entry.id) } }))
                                .labelsHidden()
                        }
                        .padding(10)
                        Divider()
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
                HStack {
                    Text("本机读取，本机保存").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("开始统计") {
                        state.enabledClients = draft
                        state.completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.isEmpty)
                }
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .onAppear { draft = state.enabledClients }
    }
}
