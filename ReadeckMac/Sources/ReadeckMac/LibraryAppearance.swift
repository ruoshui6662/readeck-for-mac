import AppKit
import SwiftUI

enum LibraryAppearance {
    /// No override in the collection, or when reading follows the system.
    static func preferredScheme(readerTheme: String?) -> ColorScheme? {
        switch readerTheme {
        case "dark": .dark
        case "light", "sepia": .light
        default: nil
        }
    }

    static func windowBackground(in scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.12, green: 0.123, blue: 0.13) : Color(white: 0.995)
    }

    static func sidebarBackground(in scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.145 : 0.975)
    }
}

/// Keep the native split-view chrome. A neutral backplate limits desktop tint
/// without adding another rounded container, border or shadow.
struct LibrarySidebarSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            LibraryAppearance.sidebarBackground(in: scheme)
            if !reduceTransparency && contrast != .increased {
                LibrarySidebarMaterial().opacity(0.16)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LibrarySidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
