import SwiftUI

@main
struct TokensApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Tokly", id: "tokens-main") {
            ContentView()
                .environmentObject(state)
                .onAppear {
                    delegate.state = state
                    state.onAppear()
                }
        }
        .defaultSize(width: 980, height: 640)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            Label(state.todayMenuTitle(), systemImage: "chart.bar")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    private var replied = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await self.state?.prepareForQuit()
            self.replyOnce(to: sender)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak sender] in
            guard let sender else { return }
            self.replyOnce(to: sender)
        }
        return .terminateLater
    }

    @MainActor
    private func replyOnce(to sender: NSApplication) {
        guard !replied else { return }
        replied = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var tab: Tab = .overview

    enum Tab: String {
        case overview, models, sources, widgets, settings
    }

    var body: some View {
        Group {
            if !state.hasOnboarded {
                OnboardingView()
            } else {
                NavigationSplitView {
                    List(selection: $tab) {
                        Label("总览", systemImage: "chart.column").tag(Tab.overview)
                        Label("模型", systemImage: "square.stack").tag(Tab.models)
                        Label("来源", systemImage: "folder").tag(Tab.sources)
                        Label("小组件", systemImage: "rectangle.on.rectangle").tag(Tab.widgets)
                        Label("设置", systemImage: "gear").tag(Tab.settings)
                    }
                    .navigationTitle("Tokly")
                } detail: {
                    detailView
                        .sheet(item: Binding(
                            get: { state.selectedModel },
                            set: { state.selectedModel = $0 })) { sel in
                            ModelDetailSheet(
                                clientId: sel.clientId, modelId: sel.modelId,
                                range: sel.range, onDone: { state.selectedModel = nil })
                        }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onOpenURL { url in
            if url.scheme == (Bundle.main.object(forInfoDictionaryKey: "ToklyURLScheme") as? String ?? "tokensmacos"), url.host == "today" {
                state.openToday()
                openWindow(id: "tokens-main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch tab {
        case .overview: OverviewView()
        case .models: ModelsView()
        case .sources: SourcesView()
        case .widgets: WidgetsView()
        case .settings: SettingsView()
        }
    }
}
