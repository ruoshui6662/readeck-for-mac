import SwiftUI

/// Interface vocabulary shared by toolbars, menus, sidebars and status views.
enum AppSymbol: String, CaseIterable {
    case sidebar = "sidebar.left", back = "chevron.left"
    case inbox = "tray", unread = "circle", reading = "book"
    case star = "star", starred = "star.fill", archive = "archivebox", unarchive = "tray.and.arrow.up"
    case collection = "line.3.horizontal.decrease.circle"
    case save = "plus", select = "checkmark.square", unselected = "square", selected = "checkmark.square.fill"
    case category = "folder", tag = "tag", pin = "pin", pinned = "pin.fill"
    case capture = "arrow.down.doc", history = "clock.arrow.circlepath"
    case cards = "square.grid.2x2", list = "list.bullet", search = "magnifyingglass", more = "ellipsis"
    case appearance = "textformat.size", notes = "note.text", highlight = "highlighter"
    case lightTheme = "sun.max", darkTheme = "moon"
    case readerSidebar = "sidebar.right"
    case edit = "square.and.pencil", copy = "doc.on.doc", external = "arrow.up.right.square", info = "info.circle"
    case settings = "gearshape", connection = "network", cache = "internaldrive"
    case sync = "arrow.triangle.2.circlepath", retry = "arrow.clockwise"
    case waiting = "clock", confirmed = "checkmark.circle", skipped = "minus.circle"
    case warning = "exclamationmark.triangle", delete = "trash", close = "xmark"
}

struct ToolbarIconLabel: View {
    let title: String
    let symbol: AppSymbol
    var body: some View {
        Label {
            Text(AppLanguage.text(title))
        } icon: {
            if symbol == .appearance {
                ReaderAppearanceGlyph()
            } else {
                Image(systemName: symbol.rawValue).resizable().scaledToFit()
                    .frame(width: 16, height: 16)
            }
        }
            .labelStyle(.iconOnly).font(.system(size: 16, weight: .regular))
            .symbolRenderingMode(.monochrome)
    }
}

/// Literal Latin typography stays recognizable in every system language.
struct ReaderAppearanceGlyph: View {
    var body: some View {
        Text(verbatim: "Aa")
            .font(.system(size: 17, weight: .medium, design: .serif))
            .tracking(-0.8)
            .fixedSize()
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Toolbar menus use the same symbol treatment as adjacent action buttons.
    func toolbarIconMenuStyle() -> some View {
        menuStyle(.borderlessButton).menuIndicator(.hidden)
    }
}

struct SymbolButton: View {
    let title: String
    let symbol: AppSymbol
    var explanation: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ToolbarIconLabel(title: title, symbol: symbol)
        }
        .help(AppLanguage.text(explanation ?? title))
        .accessibilityLabel(AppLanguage.text(title))
    }
}

enum ToolbarSizing {
    // Measured detail width, including the effect of sidebar resizing.
    static func showsLayout(at width: CGFloat) -> Bool { width >= 650 }
    static func showsSecondary(at width: CGFloat) -> Bool { width >= 700 }
}
