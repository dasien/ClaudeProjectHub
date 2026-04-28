import SwiftUI

/// Small (i) icon button that opens a popover with explanatory text. Used
/// next to confusing form labels where the field name alone isn't
/// self-explanatory ("ID", "Strategy", etc.). HIG-flavored — Apple uses
/// the same `info.circle` glyph all over System Settings for this purpose.
struct HelpPopover: View {
    let text: String
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $presented, arrowEdge: .top) {
            Text(text)
                .font(.callout)
                .padding(12)
                .frame(maxWidth: 320, alignment: .leading)
        }
    }
}
