import SwiftUI

/// Both collection layouts use identical commands, ordering and symbols.
struct BookmarkQuickActions: View {
    let item: Bookmark
    let revealed: Bool
    var inline = true
    var persistentStar = true
    let idPrefix: String
    let onOpen: () -> Void
    let onOrganize: (() -> Void)?
    let onRename: () -> Void
    let onDelete: () -> Void
    let onPatch: (Bookmark, BookmarkPatch) async -> Void
    var disabled = false
    var onFocusChange: (Bool) -> Void = { _ in }
    @FocusState private var focusedAction: String?
    @State private var changing = false
    private var shown: Bool { revealed || focusedAction != nil }

    var body: some View {
        HStack(spacing: 0) {
            if inline {
                actionButton(item.isMarked == true ? "取消星标" : "设为星标",
                    symbol: item.isMarked == true ? .starred : .star, id: "star",
                    visible: shown || (persistentStar && item.isMarked == true)) {
                        patch(BookmarkPatch(isMarked: item.isMarked != true))
                    }.foregroundStyle(item.isMarked == true ? Color.orange.opacity(0.85) : .secondary)
                actionButton(item.isArchived == true ? "移回收件箱" : "归档",
                    symbol: item.isArchived == true ? .unarchive : .archive, id: "archive", visible: shown) {
                        patch(BookmarkPatch(isArchived: item.isArchived != true))
                    }
            }
            Menu {
                BookmarkActionsMenu(item: item, onOpen: onOpen, onOrganize: onOrganize,
                    onRename: onRename, onDelete: onDelete, onPatch: patch)
            } label: {
                Image(systemName: AppSymbol.more.rawValue).font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("更多文章操作").accessibilityLabel(AppLanguage.text("更多文章操作") + "：" + item.displayTitle)
            .accessibilityIdentifier(idPrefix + ".more." + item.id)
            .focused($focusedAction, equals: "more")
            .opacity(!inline || shown ? 1 : 0).allowsHitTesting(!inline || shown)
        }
        .frame(width: inline ? 88 : 28, alignment: .trailing)
        .disabled(changing || disabled)
        .onChange(of: focusedAction) { _, value in onFocusChange(value != nil) }
        .onDisappear { onFocusChange(false) }
    }
    private func actionButton(_ title: String, symbol: AppSymbol, id: String, visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol.rawValue).font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(AppLanguage.text(title)).accessibilityLabel(AppLanguage.text(title))
            .accessibilityIdentifier(idPrefix + "." + id + "." + item.id)
            .focusable()
            .focused($focusedAction, equals: id)
            .onKeyPress(.space) { action(); return .handled }
            .opacity(visible ? 1 : 0).allowsHitTesting(visible)
    }
    private func patch(_ value: BookmarkPatch) {
        guard !changing && !disabled else { return }
        changing = true
        Task { await onPatch(item, value); changing = false }
    }
}

/// Cards, list rows and their right-click menus share this single action list.
struct BookmarkActionsMenu: View {
    let item: Bookmark
    let onOpen: () -> Void
    let onOrganize: (() -> Void)?
    let onRename: () -> Void
    let onDelete: () -> Void
    let onPatch: (BookmarkPatch) -> Void
    var body: some View {
        Button("打开阅读", action: onOpen)
        Button(AppLanguage.text(item.isMarked == true ? "取消星标" : "设为星标")) { onPatch(BookmarkPatch(isMarked: item.isMarked != true)) }
        Button(AppLanguage.text(item.isArchived == true ? "移回收件箱" : "归档")) { onPatch(BookmarkPatch(isArchived: item.isArchived != true)) }
        if (item.readProgress ?? 0) < 100 { Button("标记为已读") { onPatch(BookmarkPatch(readProgress: 100)) } }
        Divider()
        if let onOrganize { Button("分类与标签…", action: onOrganize) }
        Button("重命名文章…", action: onRename)
        Divider()
        Button("删除文章…", role: .destructive, action: onDelete)
    }
}
