import AppKit
import SwiftUI

struct ReaderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: AnnotationWorkspace
    @EnvironmentObject private var preferences: ReaderPreferences
    @Environment(\.colorScheme) private var colorScheme
    let bookmark: Bookmark
    var onBack: () -> Void = {}
    var onEdit: () -> Void = {}
    var onRename: () -> Void = {}
    var onDelete: () -> Void = {}
    var commandsEnabled = true
    @State private var html: String?
    @State private var loadError: String?
    @State private var showAppearance = false
    @State private var showInfo = false
    @State private var revealRequest: AnnotationRevealRequest?
    @State private var selectionResetID = UUID()
    @State private var savingSelection = false
    @State private var readerWidth: CGFloat = 650
    @State private var showFind = false
    @State private var findFocusRequest = UUID()
    @State private var findQuery = ""
    @State private var findState = ReaderFindState()
    @State private var headings: [ReaderHeading] = []
    @State private var navigationReady = false
    @State private var currentHeading: Int?
    @State private var showCompactOutline = false
    @State private var outlineVisibility = ReaderOutlineVisibility()
    @State private var outlineFocusRequest = UUID()
    @State private var navigationRequest: ReaderNavigationRequest?

    private var starButton: some View {
        SymbolButton(title: bookmark.isMarked == true ? "取消星标" : "设为星标", symbol: bookmark.isMarked == true ? .starred : .star) { toggleStar() }
            .foregroundStyle(bookmark.isMarked == true ? Color.yellow : Color.primary)
    }
    private var archiveButton: some View {
        SymbolButton(title: bookmark.isArchived == true ? "移回收件箱" : "归档", symbol: bookmark.isArchived == true ? .unarchive : .archive) { toggleArchive() }
    }
    private func toggleStar() { Task { await model.updateBookmark(bookmark, patch: BookmarkPatch(isMarked: bookmark.isMarked != true)) } }
    private func toggleArchive() { Task { await model.updateBookmark(bookmark, patch: BookmarkPatch(isArchived: bookmark.isArchived != true)) } }
    private var readerCommands: ReaderCommandContext {
        ReaderCommandContext(isEnabled: commandsEnabled && !workspace.hasPresentedAlert,
            isMarked: bookmark.isMarked == true, isArchived: bookmark.isArchived == true,
            notesVisible: workspace.isPresented) { action in
            switch action {
            case .appearance: showAppearance = true
            case .notes: toggleReaderInspector()
            case .star: toggleStar()
            case .archive: toggleArchive()
            case .find: openFind()
            case .nextMatch: stepFind(1)
            case .previousMatch: stepFind(-1)
            case .outline: openOutline()
            }
        }
    }

    private var annotationScope: AnnotationScope {
        AnnotationScope(bookmarkID: bookmark.id, connectionID: model.client?.storageInstance ?? "")
    }

    private var style: ReaderStyle {
        var value = preferences.style.normalized
        value.unifiedLayout = !preferences.usesCompatibility(for: annotationScope)
        if value.theme == "system" { value.theme = colorScheme == .dark ? "dark" : "light" }
        return value
    }

    private var pageColor: Color {
        switch style.theme {
        case "dark": Color(red: 0.11, green: 0.11, blue: 0.12)
        case "sepia": Color(red: 0.965, green: 0.945, blue: 0.906)
        default: .white
        }
    }

    private var articleContent: some View {
        Group {
            if bookmark.isProcessing {
                VStack(spacing: 12) {
                    ProgressView("已保存到 NAS，正在提取正文…")
                    Text("完成后会自动显示，也可以先打开原网页阅读。")
                        .font(.callout).foregroundStyle(.secondary)
                    originalLink
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if bookmark.captureFailed {
                ContentUnavailableView {
                    Label("NAS 抓取失败", systemImage: AppSymbol.warning.rawValue)
                } description: { Text("收藏已保存，可以打开原网页阅读，或在 Readeck 网页端重试抓取。") }
                actions: { originalLink }
            } else if bookmark.hasArticle == false {
                ContentUnavailableView { Label("此收藏没有正文", systemImage: "doc.text") }
                description: { Text("可以打开原网页查看内容。") }
                actions: { originalLink }
            } else if let html {
                ReaderWebView(html: html, baseURL: model.client?.address.root ?? URL(string: "about:blank")!,
                              style: style, initialProgress: bookmark.readProgress ?? 0, onProgress: { progress in
                    Task { await model.updateReadingProgress(progress, for: bookmark) }
                }, annotations: model.annotationItems[bookmark.id, default: []], onAnnotationTap: { id in
                    if let item = model.annotationItems[bookmark.id, default: []].first(where: { $0.id == id }) {
                        workspace.open(AnnotationDraft(selection: nil, annotation: item))
                    }
                }, onSelectionAction: handleSelectionAction, revealRequest: revealRequest, selectionResetID: selectionResetID,
                navigationRequest: navigationRequest, onOutline: { headings = $0; navigationReady = true },
                onCurrentHeading: { currentHeading = $0 }, onFindState: { findState = $0 })
            } else if let loadError {
                ContentUnavailableView { Label("文章暂时无法加载", systemImage: AppSymbol.warning.rawValue) }
                description: { Text(loadError) }
                actions: { originalLink }
            } else {
                ProgressView("正在加载文章…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if preferences.outlinePresentation.showsInline(at: geometry.size.width, hasHeadings: !headings.isEmpty) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 4) {
                            ReaderOutlineToggle(collapsed: outlineVisibility.isCollapsed) {
                                withAnimation(.easeInOut(duration: 0.18)) { outlineVisibility.toggle() }
                            }
                            if !outlineVisibility.isCollapsed {
                                Text("目录").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                        if !outlineVisibility.isCollapsed {
                            ReaderOutlineView(headings: headings, isReady: navigationReady, current: currentHeading,
                                immersive: true, focusRequest: outlineFocusRequest, onSelect: selectHeading)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: outlineVisibility.isCollapsed ? 28 : 208)
                    .padding(.leading, 18).padding(.trailing, outlineVisibility.isCollapsed ? 12 : 30).padding(.top, 44)
                }
                // Keep the WebView at a stable structural identity when either
                // directory style or inspector visibility changes.
                articleContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pageColor)
        .safeAreaInset(edge: .top, spacing: 0) {
            if showFind, html != nil {
                ReaderFindBar(query: $findQuery, result: findState, onStep: stepFind, onClose: closeFind, focusRequest: findFocusRequest)
            }
        }
        .task(id: showFind ? findQuery : "") {
            let query = showFind ? findQuery : ""
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            navigationRequest = ReaderNavigationRequest(action: .find(query, 0))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { readerWidth = $0 }
        .onChange(of: preferences.outlinePresentation) { _, value in
            showCompactOutline = false
            if value == .immersive, workspace.isPresented, workspace.panel == .outline { workspace.showList() }
        }
        .onChange(of: inlineOutlineVisible) { _, value in
            if value { showCompactOutline = false }
        }
        .navigationTitle("")
        .toolbar { readerToolbar }
        .focusedSceneValue(\.readerCommands, readerCommands)
        .popover(isPresented: $showInfo) { articleInfo }
        .inspector(isPresented: Binding(get: { workspace.isPresented }, set: { value in
            // SwiftUI can collapse an inspector while the window is resized.
            // Only explicit close/navigation controls may ask to discard a draft.
            if !value && (workspace.hasChanges || workspace.isSaving) { return }
            workspace.setPresented(value)
        })) {
            readerInspector
        }
        .onAppear { workspace.bind(to: annotationScope) }
        .onChange(of: annotationScope) { _, value in workspace.bind(to: value) }
        .task(id: bookmark.articleRequestKey) {
            html = nil
            loadError = nil
            headings = []; currentHeading = nil; navigationReady = false; findState = ReaderFindState(); showCompactOutline = false
            guard !bookmark.isProcessing, bookmark.state != 1, bookmark.hasArticle != false else {
                navigationReady = !bookmark.isProcessing
                return
            }
            do {
                let content = try await model.article(for: bookmark)
                try Task.checkCancellation()
                html = content
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
                navigationReady = true
            }
        }
        .task(id: "\(bookmark.id)|\(bookmark.updated ?? "")") {
            guard !bookmark.isProcessing, bookmark.hasArticle != false else { return }
            await model.loadAnnotations(for: bookmark)
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) { Label("返回收藏列表", systemImage: "chevron.left") }
                    .labelStyle(.iconOnly).help("返回收藏列表（⌘[）")
                    .keyboardShortcut("[", modifiers: .command)
            }
            ToolbarItem(id: "reader.title", placement: .principal) {
                Text(bookmark.displayTitle)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .frame(width: max(80, min(280, readerWidth - (ToolbarSizing.showsSecondary(at: readerWidth) ? 400 : 300))))
                    .clipped().help(bookmark.displayTitle).accessibilityLabel("文章：\(bookmark.displayTitle)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if preferences.outlinePresentation == .immersive, !inlineOutlineVisible {
                    Button(action: openOutline) { Label("文章目录", systemImage: "list.bullet.indent") }
                        .labelStyle(.iconOnly)
                        .help("文章目录").accessibilityLabel("文章目录")
                        .popover(isPresented: $showCompactOutline) {
                            ReaderOutlineView(headings: headings, isReady: navigationReady, current: currentHeading) { heading in
                                selectHeading(heading); showCompactOutline = false
                            }.frame(width: 270, height: 440).background(pageColor)
                        }
                }
                SymbolButton(title: "排版", symbol: .appearance, explanation: "字体、字号、间距与主题") { showAppearance.toggle() }
                    .popover(isPresented: $showAppearance) { ReaderAppearanceView().environmentObject(preferences) }
                SymbolButton(title: style.theme == "dark" ? "切换为亮色" : "切换为暗色",
                             symbol: style.theme == "dark" ? .darkTheme : .lightTheme) {
                    preferences.toggleBrightness(systemIsDark: colorScheme == .dark)
                }
                .accessibilityValue(AppLanguage.text(style.theme == "dark" ? "暗色" : "亮色"))
                Toggle(isOn: Binding(get: { workspace.isPresented }, set: { value in
                    if value != workspace.isPresented { toggleReaderInspector() }
                })) {
                    ToolbarIconLabel(title: preferences.outlinePresentation == .immersive ? "笔记" : "目录与笔记",
                        symbol: preferences.outlinePresentation == .immersive ? .notes : .readerSidebar)
                }.toggleStyle(.button)
                    .help(preferences.outlinePresentation == .immersive ? "查看划线与批注" : "查看目录、划线与批注")
                    .accessibilityLabel(AppLanguage.text(preferences.outlinePresentation == .immersive ? "笔记" : "目录与笔记"))
                    .accessibilityValue(AppLanguage.text(workspace.isPresented ? "已展开" : "已收起"))
            }
            if ToolbarSizing.showsSecondary(at: readerWidth) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) { starButton;archiveButton }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("在文章中查找…", action: openFind).disabled(html == nil)
                    Button("文章目录", action: openOutline)
                    Divider()
                    if !ToolbarSizing.showsSecondary(at: readerWidth) {
                        Button { toggleStar() } label: { Label(AppLanguage.text(bookmark.isMarked == true ? "取消星标" : "设为星标"), systemImage: AppSymbol.star.rawValue) }
                        Button { toggleArchive() } label: { Label(AppLanguage.text(bookmark.isArchived == true ? "移回收件箱" : "归档"), systemImage: bookmark.isArchived == true ? AppSymbol.unarchive.rawValue : AppSymbol.archive.rawValue) }
                        Divider()
                    }
                    Button("分类与标签…", action: onEdit)
                    Button("重命名文章…", action: onRename)
                    Button("文章信息") { showInfo = true }
                    originalLink
                    Button("复制原链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bookmark.url, forType: .string)
                    }
                    Divider()
                    Button {
                        preferences.setCompatibility(!preferences.usesCompatibility(for: annotationScope), for: annotationScope)
                    } label: {
                        Text(preferences.usesCompatibility(for: annotationScope) ? LocalizedStringKey("使用统一排版") : LocalizedStringKey("使用兼容排版"))
                    }
                    Divider()
                    Button("删除文章…", role: .destructive, action: onDelete)
                } label: { ToolbarIconLabel(title: "更多文章操作", symbol: .more) }
                .toolbarIconMenuStyle().help("更多文章操作").accessibilityLabel("更多文章操作")
            }
    }

    private var readerInspector: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if preferences.outlinePresentation == .classic {
                    Picker("阅读侧栏", selection: Binding(get: { workspace.panel }, set: { value in
                        if value == .outline { workspace.showOutline() } else { workspace.showList() }
                    })) {
                        Text("目录").tag(AnnotationWorkspace.Panel.outline)
                        Text("笔记").tag(AnnotationWorkspace.Panel.notes)
                    }.pickerStyle(.segmented).labelsHidden()
                        .disabled(workspace.isSaving || workspace.hasPresentedAlert)
                    } else {
                        Text("笔记").font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    Button { workspace.close() } label: { Image(systemName: AppSymbol.close.rawValue) }
                        .buttonStyle(.plain).help("关闭阅读侧栏").accessibilityLabel("关闭阅读侧栏")
                        .disabled(workspace.isSaving)
                }.padding(12)
                Divider()
                if preferences.outlinePresentation == .classic, workspace.panel == .outline {
                    ReaderOutlineView(headings: headings, isReady: navigationReady, current: currentHeading, onSelect: selectHeading)
                } else {
            AnnotationSidebarView(model: model, workspace: workspace, bookmark: bookmark, onReveal: { item in
                revealRequest = AnnotationRevealRequest(annotationID: item.id)
            }, onSave: { draft, color, note in
                guard workspace.scope == annotationScope else { return false }
                let saved: Bool
                if let annotation = draft.annotation {
                    saved = await model.updateAnnotation(annotation, for: bookmark, color: color, note: note)
                } else if let selected = draft.selection {
                    saved = await model.createAnnotation(selected, for: bookmark, color: color, note: note)
                } else { return false }
                if saved { selectionResetID = UUID() }
                return saved
            }, showsHeader: false)
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 310, max: 370)
    }

    private var inlineOutlineVisible: Bool {
        preferences.outlinePresentation.showsInline(at: readerWidth, hasHeadings: !headings.isEmpty)
    }

    private func selectHeading(_ heading: ReaderHeading) {
        navigationRequest = ReaderNavigationRequest(action: .heading(heading.index))
    }

    private func openOutline() {
        if preferences.outlinePresentation == .classic { workspace.showOutline() }
        else if inlineOutlineVisible {
            outlineVisibility.open()
            outlineFocusRequest = UUID()
        }
        else { showCompactOutline = true }
    }

    private func toggleReaderInspector() {
        if workspace.isPresented { workspace.close() }
        else if preferences.outlinePresentation == .immersive { workspace.showList() }
        else { workspace.setPresented(true) }
    }

    private func stepFind(_ step: Int) {
        guard html != nil else { return }
        showFind = true
        guard !findQuery.isEmpty else { return }
        navigationRequest = ReaderNavigationRequest(action: .find(findQuery, step))
    }

    private func openFind() {
        guard html != nil else { return }
        showFind = true
        findFocusRequest = UUID()
    }

    private func closeFind() {
        showFind = false; findQuery = ""; findState = ReaderFindState()
        navigationRequest = ReaderNavigationRequest(action: .find("", 0))
    }

    private func handleSelectionAction(_ selection: AnnotationSelection, _ action: ReaderSelectionAction) {
        guard workspace.scope == annotationScope else { return }
        switch action {
        case .note:
            workspace.open(AnnotationDraft(selection: selection, annotation: nil))
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selection.text, forType: .string)
        case let .highlight(color):
            guard !savingSelection else { return }
            savingSelection = true
            let owner = annotationScope
            Task {
                guard workspace.scope == owner, annotationScope == owner else { savingSelection = false; return }
                if await model.createAnnotation(selection, for: bookmark, color: color) { selectionResetID = UUID() }
                savingSelection = false
            }
        }
    }

    @ViewBuilder
    private var originalLink: some View {
        if let url = URL(string: bookmark.url) {
            Link(destination: url) { Label("在浏览器打开原网页", systemImage: AppSymbol.external.rawValue) }
        }
    }

    private var articleInfo: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("文章信息").font(.headline); Spacer()
                Button { showInfo = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
            Text(bookmark.displayTitle).font(.title3.weight(.semibold)).textSelection(.enabled)
            LabeledContent("来源", value: bookmark.displaySite)
            if let minutes = bookmark.readingTime, minutes > 0 { LabeledContent("阅读时间", value: "约 \(minutes) 分钟") }
            LabeledContent("阅读进度", value: "\(bookmark.readProgress ?? 0)%")
            Divider()
            Text(bookmark.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            originalLink
        }
        .padding(22).frame(width: 360)
    }
}
