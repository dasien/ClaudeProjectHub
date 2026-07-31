import AppKit
import SwiftUI

/// Renders a host's icon. Looks up the installed app via its bundle
/// identifier (NSWorkspace) and falls back to a generic terminal SF
/// Symbol when the app isn't installed or no bundle id is configured.
struct HostIconView: View {
    let host: HostConfig
    var size: CGFloat = 16

    var body: some View {
        if let nsImage = resolveAppIcon(bundleIdentifier: host.bundleIdentifier ?? "") {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// Same idea but driven by in-flight editor state (a bundleIdentifier
/// string). Lets the editor preview update live as the user picks an
/// app.
struct EditorIconPreview: View {
    let bundleIdentifier: String
    var size: CGFloat = 32

    var body: some View {
        if let nsImage = resolveAppIcon(bundleIdentifier: bundleIdentifier) {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: size * 0.7))
                .frame(width: size, height: size)
        }
    }
}

/// Resolves a bundle identifier to its app icon, via `AppIconCache`.
/// Returns nil when the bundle id is empty or the app isn't installed.
@MainActor
func resolveAppIcon(bundleIdentifier: String) -> NSImage? {
    AppIconCache.shared.icon(forBundleIdentifier: bundleIdentifier)
}

/// Caches bundle identifier → app icon.
///
/// This used to run Launch Services lookups straight from a view body:
/// `urlForApplication` + `icon(forFile:)` measured ~136µs per call, and
/// it happens once per `SessionRow`, `TabChip` and `ExternalSessionRow`
/// — a few milliseconds per render pass at a realistic session count.
///
/// The subtler half is that `NSWorkspace.icon(forFile:)` returns a *new*
/// `NSImage` instance on every call, so `Image(nsImage:)` never compared
/// equal between renders and SwiftUI could never skip the icon subtree.
/// Caching fixes both problems at once: the lookup runs once per bundle
/// id, and every later render gets the identical instance back.
///
/// Misses are cached too. The shipped registry lists 12 hosts and most
/// users have only a few installed, so "not installed" is the common
/// case — especially in Settings → Hosts, which renders every host.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    /// Nested optional is deliberate: the outer level distinguishes
    /// "never looked up" from "looked up, and there's no icon", so a
    /// miss is remembered rather than re-resolved on every render.
    private var icons: [String: NSImage?] = [:]
    private var didLaunchObserver: NSObjectProtocol?

    private init() {
        // Drop an app's entry when that app launches, which is the case
        // that matters: the user installs a host and starts it, and the
        // hub should stop showing the generic fallback glyph for it.
        // Scoped to the one bundle id so an unrelated app launching
        // doesn't throw away the whole cache. Nothing else changes an
        // already-installed app's icon often enough to be worth
        // invalidating for — a hub relaunch covers the rest.
        didLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let bundleID = (
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            )?.bundleIdentifier else { return }
            Task { @MainActor in
                AppIconCache.shared.icons.removeValue(forKey: bundleID)
            }
        }
    }

    func icon(forBundleIdentifier bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        let resolved: NSImage?
        if bundleID.isEmpty {
            resolved = nil
        } else if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) {
            resolved = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            resolved = nil
        }
        icons[bundleID] = resolved
        return resolved
    }
}
