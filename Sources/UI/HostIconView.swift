import AppKit
import SwiftUI

/// Renders a host's icon. Prefers the actual installed app's icon (via
/// `NSWorkspace.shared.icon(forFile:)` keyed by bundleIdentifier or the
/// process-strategy executable's containing .app bundle), and falls back
/// to the SF Symbol stored in `HostConfig.icon` when the app can't be
/// located.
struct HostIconView: View {
    let host: HostConfig
    var size: CGFloat = 16

    var body: some View {
        if let nsImage = host.resolvedAppIcon() {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: host.icon)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// Same idea but driven by in-flight editor state (bundleIdentifier and
/// executable path strings, not a fully-formed HostConfig). Lets the
/// editor preview live updates as the user types.
struct EditorIconPreview: View {
    let bundleIdentifier: String
    let executable: String
    let sfSymbolFallback: String
    var size: CGFloat = 32

    var body: some View {
        if let nsImage = resolveAppIcon(
            bundleIdentifier: bundleIdentifier,
            executable: executable
        ) {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: sfSymbolFallback)
                .foregroundStyle(.secondary)
                .font(.system(size: size * 0.7))
                .frame(width: size, height: size)
        }
    }
}

extension HostConfig {
    func resolvedAppIcon() -> NSImage? {
        let executable: String
        switch strategy {
        case .builtin: executable = ""
        case .process(let exe, _): executable = exe
        }
        return resolveAppIcon(
            bundleIdentifier: bundleIdentifier ?? "",
            executable: executable
        )
    }
}

/// Standalone resolver shared by HostConfig and the editor preview.
func resolveAppIcon(bundleIdentifier: String, executable: String) -> NSImage? {
    if !bundleIdentifier.isEmpty,
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    // For process-strategy hosts whose executable lives inside an .app
    // bundle (e.g. /Applications/Ghostty.app/Contents/MacOS/ghostty),
    // walk up the path until we find the bundle and ask NSWorkspace
    // for its icon.
    if !executable.isEmpty {
        var current = URL(fileURLWithPath: executable)
        while current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent()
            if current.pathExtension == "app" {
                return NSWorkspace.shared.icon(forFile: current.path)
            }
        }
    }
    return nil
}
