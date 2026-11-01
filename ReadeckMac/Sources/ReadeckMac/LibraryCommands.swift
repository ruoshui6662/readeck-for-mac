import SwiftUI

private struct TaxonomyPresentationKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var taxonomyPresentation: Binding<Bool>? {
        get { self[TaxonomyPresentationKey.self] }
        set { self[TaxonomyPresentationKey.self] = newValue }
    }
    var libraryCommands: LibraryCommandContext? {
        get { self[LibraryCommandKey.self] }
        set { self[LibraryCommandKey.self] = newValue }
    }
    var readerCommands: ReaderCommandContext? {
        get { self[ReaderCommandKey.self] }
        set { self[ReaderCommandKey.self] = newValue }
    }
}

private struct LibraryCommandKey: FocusedValueKey { typealias Value = LibraryCommandContext }
private struct ReaderCommandKey: FocusedValueKey { typealias Value = ReaderCommandContext }

struct ReaderCommandContext {
    enum Action { case appearance, notes, star, archive, find, nextMatch, previousMatch, outline }
    let isEnabled: Bool
    let isMarked: Bool
    let isArchived: Bool
    let notesVisible: Bool
    let onAction: (Action) -> Void
    func perform(_ action: Action) { if isEnabled { onAction(action) } }
}

struct LibraryCommandContext {
    enum Action: Equatable { case select, cards, list, captureTasks, bulkResults, taxonomy, focus }
    let isReading: Bool
    let canSelect: Bool
    let isSelecting: Bool
    let isFocused: Bool
    var isPresentingAlert = false
    let onAction: (Action) -> Void
    func isEnabled(_ action: Action) -> Bool {
        guard !isPresentingAlert else { return false }
        switch action {
        case .select: return !isReading && (isSelecting || canSelect)
        case .cards, .list: return !isReading && !isSelecting
        case .captureTasks, .taxonomy: return !isSelecting
        case .focus: return isReading
        default: return true
        }
    }
    func perform(_ action: Action) { if isEnabled(action) { onAction(action) } }
}

struct LibraryCommands: Commands {
    @ObservedObject var model: AppModel
    @FocusedValue(\.taxonomyPresentation) private var taxonomyPresentation
    @FocusedValue(\.libraryCommands) private var context
    @FocusedValue(\.readerCommands) private var reader

    var body: some Commands {
        CommandMenu(AppLanguage.text("资料库")) {
            Button("立即同步") { Task { await model.sync() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("取消同步") { model.cancelSync() }.disabled(!model.isSyncing)
            Divider()
            command(context?.isSelecting == true ? "完成选择" : "选择文章", action: .select)
            command("采集任务…", action: .captureTasks)
            command("批量整理记录…", action: .bulkResults)
            Divider()
            Button(AppLanguage.text("分类与标签…")) { taxonomyPresentation?.wrappedValue = true }
                .disabled(taxonomyPresentation == nil || taxonomyPresentation?.wrappedValue == true)
        }
        CommandGroup(after: .sidebar) {
            command("卡片", action: .cards)
            command("列表", action: .list)
            Divider()
            command(context?.isFocused == true ? "退出专注阅读" : "专注阅读", action: .focus)
        }
        CommandMenu(AppLanguage.text("文章")) {
            readerCommand("在文章中查找…", action: .find).keyboardShortcut("f", modifiers: .command)
            readerCommand("下一处", action: .nextMatch).keyboardShortcut("g", modifiers: .command)
            readerCommand("上一处", action: .previousMatch).keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            readerCommand("排版…", action: .appearance)
            readerCommand("文章目录", action: .outline)
            readerCommand(reader?.notesVisible == true ? "隐藏阅读侧栏" : "显示阅读侧栏", action: .notes)
            Divider()
            readerCommand(reader?.isMarked == true ? "取消星标" : "设为星标", action: .star)
            readerCommand(reader?.isArchived == true ? "移回收件箱" : "归档", action: .archive)
        }
    }
    private func command(_ title: String, action: LibraryCommandContext.Action) -> some View {
        Button(AppLanguage.text(title)) { context?.perform(action) }
            .disabled(context?.isEnabled(action) != true)
    }
    private func readerCommand(_ title: String, action: ReaderCommandContext.Action) -> some View {
        Button(AppLanguage.text(title)) { reader?.perform(action) }.disabled(reader?.isEnabled != true)
    }
}
