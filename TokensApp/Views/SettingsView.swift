import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("设置").font(.title2.weight(.medium))
                Text("让统计安静地留在后台").font(.callout).foregroundStyle(.secondary)

                GroupBox("采集") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("自动采集间隔")
                            Text("菜单栏与窗口使用同一份统计结果").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("间隔", selection: Binding(
                            get: { Int(state.interval / 60) },
                            set: { state.interval = TimeInterval($0 * 60) })) {
                            Text("每 10 分钟").tag(10)
                            Text("每 5 分钟").tag(5)
                        }
                        .frame(maxWidth: 140)
                    }
                    .padding(.vertical, 4)
                    Divider()
                    HStack {
                        VStack(alignment: .leading) {
                            Text("日期归属")
                            Text("按此时区划分每日用量").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(state.timeZoneID).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("显示与启动") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("菜单栏显示")
                            Text("始终显示今日的本机统计").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("菜单栏", selection: $state.menuMetric) {
                            Text("今日 Token").tag(MenuMetric.tokens)
                            Text("今日估算费用").tag(MenuMetric.cost)
                        }
                        .frame(maxWidth: 160)
                    }
                    .padding(.vertical, 4)
                    Divider()
                    HStack {
                        VStack(alignment: .leading) {
                            Text("小组件主指标")
                            Text("小号与中号使用相同指标").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("费用", isOn: $state.widgetShowCost)
                    }
                    .padding(.vertical, 4)
                    Divider()
                    HStack {
                        VStack(alignment: .leading) {
                            Text("登录时启动")
                            Text("关闭统计窗口后，仍可从菜单栏查看").font(.caption).foregroundStyle(.secondary)
                            if let err = state.loginError {
                                Text(err).font(.caption).foregroundStyle(.red)
                            } else {
                                Text(state.loginEnabled ? "已启用" : "未启用").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("登录时启动", isOn: Binding(
                            get: { state.loginEnabled },
                            set: { state.setLoginEnabled($0) }))
                            .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Image(systemName: "internaldrive")
                    Text("用量统计保存在这台 Mac 上。")
                }
                .font(.callout).foregroundStyle(.secondary)

                HStack {
                    Text("更新于 \(Format.updatedText(state.lastSuccessAt))")
                    Spacer()
                    Text("统计保存在本机").foregroundStyle(.secondary)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle("设置")
        .onAppear { state.refreshLoginStatus() }
    }
}
