import SwiftUI

@main
struct ClaudeProjectHubApp: App {
    @StateObject private var sessionStore: SessionStore
    @StateObject private var windowManager: WindowManager
    @StateObject private var hostRegistry: HostRegistry
    @StateObject private var lifecycleMonitor: SessionLifecycleMonitor
    @StateObject private var launcherService: SessionLauncherService

    @AppStorage("appearance") private var appearance: String = "system"

    init() {
        let store = SessionStore()
        let manager = WindowManager()
        let registry = HostRegistry()
        let monitor = SessionLifecycleMonitor(store: store, windowManager: manager)
        _sessionStore = StateObject(wrappedValue: store)
        _windowManager = StateObject(wrappedValue: manager)
        _hostRegistry = StateObject(wrappedValue: registry)
        _lifecycleMonitor = StateObject(wrappedValue: monitor)
        _launcherService = StateObject(wrappedValue: SessionLauncherService(
            store: store,
            windowManager: manager,
            hostRegistry: registry
        ))
    }

    var body: some Scene {
        WindowGroup("Claude Project Hub") {
            MainView()
                .environmentObject(sessionStore)
                .environmentObject(windowManager)
                .environmentObject(hostRegistry)
                .environmentObject(lifecycleMonitor)
                .environmentObject(launcherService)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    lifecycleMonitor.start()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environmentObject(hostRegistry)
                .preferredColorScheme(preferredColorScheme)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil // follow system
        }
    }
}
