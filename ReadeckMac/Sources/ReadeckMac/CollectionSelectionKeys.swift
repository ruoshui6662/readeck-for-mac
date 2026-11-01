import SwiftUI

/// Scoped to collection content, outside the searchable toolbar's text field.
struct CollectionSelectionKeys: ViewModifier {
    @Binding var selection: LibrarySelection
    let visibleIDs: [String]
    func body(content: Content) -> some View {
        content.focusable().focusEffectDisabled()
            .onKeyPress("a", phases: .down) { event in
                guard event.modifiers.contains(.command) else { return .ignored }
                selection.selectAll(visibleIDs);return .handled
            }
            .onKeyPress(.escape) {
                guard selection.isSelecting else { return .ignored }
                selection.end();return .handled
            }
    }
}
