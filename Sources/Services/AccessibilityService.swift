import AppKit
import ApplicationServices

enum AccessibilityService {
    /// Forces a fresh evaluation of trust each time. `AXIsProcessTrusted()`
    /// (no options) caches the result for the lifetime of the process on some
    /// macOS versions, so a grant made after the first call wouldn't be seen.
    static var isTrusted: Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Triggers the macOS Accessibility prompt the first time, registering
    /// the running binary in System Settings → Privacy & Security → Accessibility.
    @discardableResult
    static func requestTrust(promptIfNeeded: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
