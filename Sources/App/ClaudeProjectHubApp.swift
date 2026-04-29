import SwiftUI

@main
struct ClaudeProjectHubApp: App {
    @StateObject private var sessionStore: SessionStore
    @StateObject private var windowManager: WindowManager
    @StateObject private var hostRegistry: HostRegistry
    @StateObject private var lifecycleMonitor: SessionLifecycleMonitor
    @StateObject private var launcherService: SessionLauncherService
    @StateObject private var dockController: DockController
    @StateObject private var externalScanner: ExternalSessionScanner

    @AppStorage("appearance") private var appearance: String = "system"

    init() {
        let store = SessionStore()
        let manager = WindowManager()
        let registry = HostRegistry()
        let monitor = SessionLifecycleMonitor(store: store, windowManager: manager)
        let dock = DockController()
        let scanner = ExternalSessionScanner(store: store, hostRegistry: registry)
        _sessionStore = StateObject(wrappedValue: store)
        _windowManager = StateObject(wrappedValue: manager)
        _hostRegistry = StateObject(wrappedValue: registry)
        _lifecycleMonitor = StateObject(wrappedValue: monitor)
        _dockController = StateObject(wrappedValue: dock)
        _externalScanner = StateObject(wrappedValue: scanner)
        _launcherService = StateObject(wrappedValue: SessionLauncherService(
            store: store,
            windowManager: manager,
            hostRegistry: registry,
            dockController: dock
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
                .environmentObject(dockController)
                .environmentObject(externalScanner)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    lifecycleMonitor.start()
                    externalScanner.start()
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
