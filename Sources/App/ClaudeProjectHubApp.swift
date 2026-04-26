import SwiftUI

@main
struct ClaudeProjectHubApp: App {
    @StateObject private var sessionStore: SessionStore
    @StateObject private var windowManager: WindowManager
    @StateObject private var lifecycleMonitor: SessionLifecycleMonitor
    @StateObject private var launcherService: SessionLauncherService

    init() {
        let store = SessionStore()
        let manager = WindowManager()
        let monitor = SessionLifecycleMonitor(store: store, windowManager: manager)
        _sessionStore = StateObject(wrappedValue: store)
        _windowManager = StateObject(wrappedValue: manager)
        _lifecycleMonitor = StateObject(wrappedValue: monitor)
        _launcherService = StateObject(wrappedValue: SessionLauncherService(
            store: store,
            windowManager: manager
        ))
    }

    var body: some Scene {
        WindowGroup("Claude Project Hub") {
            MainView()
                .environmentObject(sessionStore)
                .environmentObject(windowManager)
                .environmentObject(lifecycleMonitor)
                .environmentObject(launcherService)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    lifecycleMonitor.start()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
