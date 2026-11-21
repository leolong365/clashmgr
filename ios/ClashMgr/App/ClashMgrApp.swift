import SwiftUI

/// 应用入口与四 Tab 根视图。
@main
public struct ClashMgrApp: App {

    @StateObject private var settings: AppSettings
    @StateObject private var store: ConfigStore
    @StateObject private var state: AppState

    public init() {
        let settings = AppSettings()
        let store = ConfigStore()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: store)
        _state = StateObject(wrappedValue: AppState(settings: settings, store: store))
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(settings)
                .environmentObject(store)
        }
    }
}

public struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: Int = 0

    public init() {}

    public var body: some View {
        TabView(selection: $selection) {
            SubscriptionsView()
                .tabItem { Label("订阅", systemImage: "tray.full") }
                .tag(0)

            ProxiesView()
                .tabItem { Label("代理", systemImage: "square.stack.3d.up") }
                .tag(1)

            RulesView()
                .tabItem { Label("规则", systemImage: "list.bullet.rectangle") }
                .tag(2)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .alert("提示", isPresented: Binding(
            get: { state.alertMessage != nil },
            set: { if !$0 { state.alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    /// `clashmgr://refresh` / `clashmgr://switch`
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "clashmgr" else { return }
        switch url.host {
        case "refresh":
            if let sub = state.currentSubscription {
                state.refresh(sub)
            }
        case "subscriptions", "profiles":
            selection = 0
        case "proxies":
            selection = 1
        case "rules":
            selection = 2
        case "settings":
            selection = 3
        default:
            break
        }
    }
}
