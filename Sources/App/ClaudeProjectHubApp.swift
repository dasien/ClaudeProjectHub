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
    @StateObject private var pricingRegistry: ModelPricingRegistry
    @StateObject private var attentionService: AttentionService
    @StateObject private var sessionCatalog: SessionCatalog

    @AppStorage("appearance") private var appearance: String = "system"

    init() {
        let store = SessionStore()
        let manager = WindowManager()
        let registry = HostRegistry()
        let monitor = SessionLifecycleMonitor(store: store, windowManager: manager)
        let dock = DockController(store: store)
        let scanner = ExternalSessionScanner(store: store, hostRegistry: registry)
        let pricing = ModelPricingRegistry()
        let attention = AttentionService(store: store, hostRegistry: registry)
        let catalog = SessionCatalog(store: store, hostRegistry: registry, pricing: pricing)
        _sessionStore = StateObject(wrappedValue: store)
        _windowManager = StateObject(wrappedValue: manager)
        _hostRegistry = StateObject(wrappedValue: registry)
        _lifecycleMonitor = StateObject(wrappedValue: monitor)
        _dockController = StateObject(wrappedValue: dock)
        _externalScanner = StateObject(wrappedValue: scanner)
        _pricingRegistry = StateObject(wrappedValue: pricing)
        _attentionService = StateObject(wrappedValue: attention)
        _sessionCatalog = StateObject(wrappedValue: catalog)
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
                .environmentObject(pricingRegistry)
                .environmentObject(attentionService)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    lifecycleMonitor.start()
                    externalScanner.start()
                    attentionService.requestAuthorizationIfNeeded()
                    Task { await launcherService.reattachAll() }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // Cmd-Shift-F: hand keyboard focus from the hub to the
            // currently-selected session's host window. Lets the
            // user select with click-or-arrow-keys and then "drop
            // into" the docked terminal/IDE without a mouse round-
            // trip into the foreign window. windowManager.focus()
            // does the activate + AX raise; it works for both
            // docked and free-floating running sessions.
            CommandGroup(after: .windowList) {
                Button("Focus Active Session") {
                    if let id = sessionStore.selectedSessionID {
                        windowManager.focus(id)
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(sessionStore.selectedSessionID == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(hostRegistry)
                .preferredColorScheme(preferredColorScheme)
        }

        // "Get Info" popout — one window per session id. macOS lets
        // multiple instances coexist (though we route the same id to
        // the same window).
        WindowGroup("Session Info", id: "session-info", for: Session.ID.self) { $sessionID in
            if let id = sessionID {
                SessionInfoView(sessionID: id)
                    .environmentObject(sessionStore)
                    .environmentObject(hostRegistry)
                    .environmentObject(pricingRegistry)
                    .preferredColorScheme(preferredColorScheme)
            }
        }

        // Cross-session dashboard. Single-instance — Window (not
        // WindowGroup) — because there's only one logical dashboard
        // view of the machine's sessions. Re-opening (Cmd-Shift-D or
        // Window menu) just raises the existing window.
        Window("Sessions Dashboard", id: "sessions-dashboard") {
            SessionsDashboardView()
                .environmentObject(sessionCatalog)
                .preferredColorScheme(preferredColorScheme)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil // follow system
        }
    }
}
