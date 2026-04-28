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

/// Resolves a bundle identifier to its app icon. Returns nil when the
/// bundle id is empty or the app isn't installed.
func resolveAppIcon(bundleIdentifier: String) -> NSImage? {
    guard !bundleIdentifier.isEmpty,
          let url = NSWorkspace.shared.urlForApplication(
              withBundleIdentifier: bundleIdentifier
          ) else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
}
