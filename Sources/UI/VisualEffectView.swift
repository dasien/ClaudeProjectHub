import AppKit
import SwiftUI

/// SwiftUI bridge for `NSVisualEffectView`. Lets us pick a specific
/// material (e.g. `.titlebar`) that SwiftUI's built-in `.regularMaterial`
/// etc. don't expose directly, and forces the effect to render with
/// `behindWindow` blending so it looks consistent against a transparent
/// hub window.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
