import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var readerPreferences: ReaderPreferences
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("library.layout") private var layout = LibraryLayout.cards
    @AppStorage("library.list.density") private var listDensity = LibraryListDensity.standard
    @AppStorage("library.list.thumbnails") private var listThumbnails = true
    @AppStorage("library.sortOrder") private var sortOrder = LibrarySortOrder.recent
    @StateObject private var annotationWorkspace = AnnotationWorkspace()
    @State private var section: SidebarSelection? = .inbox
    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var showEditor = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showLabelManager = false
    @State private var showCaptureTasks = false
    @State private var showSyncNotice = true
    @State private var syncNoticeHovered = false
    @State private var syncNoticeTimer = 0
    @State private var renamingBookmark: Bookmark?
    @State private var deletingBookmark: Bookmark?
    @State private var bulkSelection = LibrarySelection()
    @State private var bulkEditor: BulkEditorRequest?
    @State private var bulkDeletion: BulkEditorRequest?
    @State private var showBulkResults = false
    @State private var resultsConnectionID = ""
    @State private var collectionWidth: CGFloat = 660

    private var selectedBookmark: Bookmark? {
        model.bookmarks.first { $0.id == selectedID } ?? model.searchResults?.first { $0.id == selectedID }
    }

    private var canPresentTaxonomy: Bool {
        !annotationWorkspace.hasPresentedAlert && !showLabelManager && !model.showSaveSheet && !showEditor && renamingBookmark == nil && deletingBookmark == nil && !showCaptureTasks && bulkEditor == nil && bulkDeletion == nil && !showBulkResults && !model.isApplyingBulk
    }

    @ViewBuilder
    private var libraryGridView: some View {
        let connectionID = model.client?.storageInstance
        BookmarkGridView(bookmarks: displayed, pending: section == .inbox ? model.pending : [], client: model.client,
                         onOpen: { selectedID = $0.id },
                         onRename: { bulkSelection.end();renamingBookmark = $0 },
                         onDelete: { bulkSelection.end();deletingBookmark = $0 }, selection: $bulkSelection,
                         onContextOrganize: { openBulkEditor(contextBookmarks($0)) },
                         onContextAction: { item, intent in performBulk(contextBookmarks(item), intent: intent) },
                         onContextDelete: { prepareBulkDelete(contextBookmarks($0)) },
                         onPatch: { item, patch in
                             guard let connectionID, model.client?.storageInstance == connectionID, !model.isApplyingBulk else { return }
                             await model.updateBookmark(item, patch: patch)
                         }, onOrganize: { openBulkEditor([$0]) }, actionsDisabled: model.isApplyingBulk)
    }

    @ViewBuilder
    private var libraryListView: some View {
        let connectionID = model.client?.storageInstance
        BookmarkListView(selectedID: $selectedID, bookmarks: displayed,
                         pending: section == .inbox ? model.pending : [],
                         onRename: { bulkSelection.end();renamingBookmark = $0 },
                         onDelete: { bulkSelection.end();deletingBookmark = $0 }, selection: $bulkSelection,
                         onContextOrganize: { openBulkEditor(contextBookmarks($0)) },
                         onContextAction: { item, intent in performBulk(contextBookmarks(item), intent: intent) },
                         onContextDelete: { prepareBulkDelete(contextBookmarks($0)) },
                         client: model.client, density: listDensity, thumbnails: listThumbnails,
                         sortOrder: $sortOrder,
                         onPatch: { item, patch in
                             guard let connectionID, model.client?.storageInstance == connectionID, !model.isApplyingBulk else { return }
                             await model.updateBookmark(item, patch: patch)
                         },
                         onOrganize: { openBulkEditor([$0]) }, actionsDisabled: model.isApplyingBulk)
    }

    private var displayed: [Bookmark] {
        let source: [Bookmark]
        if searchText.isEmpty {
            source = model.bookmarks
        } else if let online = model.searchResults {
            source = online
        } else {
            source = model.bookmarks.filter { item in
                [item.displayTitle, item.displaySite, item.description ?? "", item.url]
                    .contains { $0.localizedCaseInsensitiveContains(searchText) } ||
                    item.labelValues.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        let selected = source.filter { item in
            switch section ?? .inbox {
            case .inbox: item.isArchived != true
            case .unread: (item.readProgress ?? 0) == 0 && item.isArchived != true
            case .reading: (1...99).contains(item.readProgress ?? 0)
            case .favorites: item.isMarked == true
            case .archive: item.isArchived == true
            case let .category(name): CategoryCodec.assignment(in: item.labelValues).category == name
            case .categoryConflicts: CategoryCodec.assignment(in: item.labelValues).hasConflict
            case let .tag(name): item.labelValues.contains(name)
            case .collection: model.collectionIDs.contains(item.id)
            }
        }
        return sortOrder.sorted(selected)
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: Binding(get: { section }, set: { value in
                annotationWorkspace.navigate { section = value; selectedID = nil }
            }), bookmarks: model.bookmarks, collections: model.collections,
                        catalog: model.labelCatalog, onManage: { showLabelManager = true })
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !needsSyncAttention, let lastSync = model.lastSyncAt {
                        HStack(spacing: 6) {
                            Image(systemName: AppSymbol.confirmed.rawValue)
                            Text("已同步 · \(Text(lastSync, style: .relative))前")
                            Spacer()
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
        } detail: {
            if let item = selectedBookmark {
                readerContent(item)
            } else {
                collectionContent
            }
        }
    }

    private func readerContent(_ item: Bookmark) -> some View {
                ReaderView(model: model, workspace: annotationWorkspace, bookmark: item,
                           onBack: { annotationWorkspace.navigate { selectedID = nil } }, onEdit: { showEditor = true },
                           onRename: { renamingBookmark = item },
                           onDelete: { deletingBookmark = item },
                           commandsEnabled: canPresentTaxonomy)
                    .id(item.id)
    }

    private var collectionContent: some View {
                Group {
                    if layout == .cards {
                        libraryGridView
                    } else {
                        libraryListView
                    }
                }
                .modifier(CollectionSelectionKeys(selection: $bulkSelection, visibleIDs: displayed.map(\.id)))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { collectionWidth = $0 }
                .navigationTitle(title)
                .background {
                    // Search registers a system toolbar item independently of
                    // ToolbarContent. Limit that registration to browsing without
                    // replacing the scrolling collection when selection changes.
                    if !bulkSelection.isSelecting {
                        Color.clear.frame(width: 0, height: 0)
                            .searchable(text: collectionSearchText, isPresented: collectionSearchPresented, placement: .toolbar, prompt: "搜索收藏")
                    }
                }
                .toolbar { libraryToolbar }
    }

    var body: some View {
        navigationContent
        .containerBackground(LibraryAppearance.windowBackground(in: colorScheme), for: .window)
        .preferredColorScheme(LibraryAppearance.preferredScheme(readerTheme: selectedBookmark == nil ? nil : readerPreferences.style.theme))
        .focusedSceneValue(\.taxonomyPresentation, canPresentTaxonomy && !bulkSelection.isSelecting ? $showLabelManager : nil)
        .focusedSceneValue(\.libraryCommands, canPresentTaxonomy ? commandContext : nil)
        .sheet(item: $bulkEditor) { request in
            BulkOrganizationView(model: model, request: request) { bulkSelection.end() }
        }
        .sheet(isPresented: $showBulkResults) { BulkResultsView(model: model, connectionID: resultsConnectionID) }
        .alert("永久删除所选文章？", isPresented: Binding(get: { bulkDeletion != nil }, set: { if !$0 { bulkDeletion = nil } })) {
            Button("取消", role: .cancel) { bulkDeletion = nil }
            Button("永久删除", role: .destructive) {
                if let request = bulkDeletion {
                    bulkDeletion = nil
                    performBulk(request.bookmarks, intent: .delete, batchID: request.id, connectionID: request.connectionID)
                }
            }
        } message: {
            Text(bulkDeletionMessage)
        }
        .sheet(isPresented: $showCaptureTasks) { CaptureTasksView(model: model) }
        .sheet(isPresented: $model.showSaveSheet) { SaveBookmarkView(model: model) }
        .sheet(isPresented: $showEditor) {
            if let item = selectedBookmark { BookmarkEditorView(model: model, bookmark: item) }
        }
        .sheet(item: $renamingBookmark) { item in
            BookmarkRenameView(model: model, bookmark: item)
        }
        .sheet(isPresented: $showLabelManager) {
            VStack(alignment: .trailing, spacing: 0) {
                LabelManagementView(model: model)
                Button("完成") { showLabelManager = false }.keyboardShortcut(.cancelAction)
                    .padding(.horizontal, 20).padding(.bottom, 18)
            }.frame(width: 460, height: 470)
        }
        .alert("永久删除文章？", isPresented: Binding(get: { deletingBookmark != nil }, set: { if !$0 { deletingBookmark = nil } })) {
            Button("取消", role: .cancel) { deletingBookmark = nil }
            Button("永久删除", role: .destructive) {
                if let item = deletingBookmark {
                    Task { if await model.deleteBookmark(item) { selectedID = nil } }
                }
                deletingBookmark = nil
            }
        } message: {
            Text("“\(deletingBookmark?.displayTitle ?? "")”及其划线批注将在同步后从 NAS 删除，此操作无法撤销。")
        }
        .overlay(alignment: .bottomTrailing) {
            if needsSyncAttention && showSyncNotice {
                synchronizationFooter
                    .padding(18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onHover { hovering in
                        syncNoticeHovered = hovering
                        syncNoticeTimer += 1
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSyncNotice)
        .onChange(of: syncNoticeIdentity) { _, _ in
            if needsSyncAttention { showSyncNotice = true; syncNoticeTimer += 1 }
        }
        .task(id: syncNoticeTimer) {
            guard showSyncNotice, needsSyncAttention, !syncNoticeHovered else { return }
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, !syncNoticeHovered else { return }
            showSyncNotice = false
        }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.search(searchText)
        }
        .task(id: section) {
            if case let .collection(id) = section { await model.loadCollection(id: id) }
        }
        .onChange(of: section) { _, _ in selectedID = nil;bulkSelection.end() }
        .onChange(of: bulkSelection.isSelecting) { _, selecting in if selecting { searchPresented = false } }
        .onChange(of: searchText) { _, _ in bulkSelection.end() }
        .onChange(of: selectedID) { _, id in if id != nil { bulkSelection.end() } }
        .onChange(of: displayed.map(\.id)) { _, ids in bulkSelection.reconcile(visibleIDs: ids) }
        .onChange(of: model.client?.storageInstance) { _, _ in clearBulkPresentation() }
        .onChange(of: model.connected) { _, value in if !value { clearBulkPresentation() } }
        .onChange(of: model.labelCatalog.tags) { _, values in
            if case let .tag(name) = section, !values.contains(name) { section = .inbox }
        }
        .onChange(of: model.labelCatalog.categories) { _, values in
            if case let .category(name) = section, !values.contains(name) { section = .inbox }
        }
    }

    private var needsSyncAttention: Bool {
        model.bulkMessage != nil || model.isSyncing || model.syncMessage != nil || model.nextRetryAt != nil ||
        !model.pending.isEmpty || !model.pendingMutations.isEmpty || !model.libraryActions.isEmpty ||
        model.captureJobs.contains(where: { $0.stage != .complete && $0.stage != .cancelled })
    }

    private var syncNoticeIdentity: String {
        [model.syncMessage ?? "", model.bulkMessage ?? "", String(model.isSyncing),
         String(model.pending.count), String(model.pendingMutations.count), String(model.libraryActions.count),
         model.captureJobs.map { $0.id + $0.stage.rawValue }.sorted().joined(separator: ","),
         model.conflictBookmarkID ?? "", model.missingBookmarkID ?? ""].joined(separator: "|")
    }

    private var captureNoticeOnly: Bool {
        model.captureJobs.contains { $0.stage != .complete && $0.stage != .cancelled } &&
        model.bulkMessage == nil && !model.isSyncing && model.syncMessage == nil && model.nextRetryAt == nil &&
        model.pending.isEmpty && model.pendingMutations.isEmpty && model.libraryActions.isEmpty &&
        model.conflictBookmarkID == nil && model.missingBookmarkID == nil
    }

    @ViewBuilder
    private var synchronizationFooter: some View {
            if needsSyncAttention && captureNoticeOnly {
                HStack(spacing: 10) {
                    Image(systemName: AppSymbol.capture.rawValue)
                        .foregroundStyle(.secondary)
                    Text("有未完成的采集任务")
                        .font(.callout.weight(.medium))
                    Button("查看") { showCaptureTasks = true }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .help("查看采集任务")
                    Button { showSyncNotice = false } label: {
                        Image(systemName: "xmark").font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
            } else if needsSyncAttention {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("同步与采集").font(.caption.weight(.semibold))
                        Spacer(minLength: 8)
                        Button { showSyncNotice = false } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
                    }
                    if let message = model.bulkMessage {
                        HStack {
                            Text(message).lineLimit(2)
                            Spacer()
                            if !model.bulkOperations.isEmpty { Button("查看批量记录") { openBulkResults() } }
                            Button { model.bulkMessage = nil } label: { Image(systemName: AppSymbol.close.rawValue) }.buttonStyle(.plain).help("关闭提示")
                        }
                    }
                    if let message = model.syncMessage {
                        Label(message, systemImage: AppSymbol.info.rawValue).lineLimit(2)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        if model.isSyncing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在与 NAS 同步…")
                            }
                        } else if let retryAt = model.nextRetryAt {
                            Text("\(Text(retryAt, style: .relative))后自动重试")
                        }
                        if !model.pending.isEmpty {
                            Text("\(model.pending.count) 个网页待发送")
                        }
                        if !model.pendingMutations.isEmpty {
                            Text("\(model.pendingMutations.count) 处更改待同步")
                        }
                        if !model.libraryActions.isEmpty { Text("\(model.libraryActions.count) 项操作待同步") }
                    }
                    HStack(spacing: 10) {
                        if model.captureJobs.contains(where: { $0.stage != .complete && $0.stage != .cancelled }) {
                            Button("查看采集任务") { showCaptureTasks = true }
                        }
                        if model.isSyncing {
                            Button("取消同步") { model.cancelSync() }
                        } else if model.needsLocalNetworkPermission {
                            Link("检查局域网权限", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                            Button("重试") { Task { await model.sync() } }
                        } else if model.missingBookmarkID != nil {
                            Button("丢弃本机更改") { Task { await model.discardMissingBookmark() } }
                                .help("服务端已删除此收藏；移除本机收藏和待同步更改")
                        } else if model.conflictBookmarkID != nil {
                            Button("采用本机") { Task { await model.resolveConflict(keepLocal: true) } }
                                .help("用本机更改覆盖服务端对应字段")
                            Button("采用服务端") { Task { await model.resolveConflict(keepLocal: false) } }
                                .help("丢弃本机待同步更改，保留服务端版本")
                        } else if model.syncMessage != nil || model.nextRetryAt != nil || !model.pending.isEmpty || !model.pendingMutations.isEmpty || !model.libraryActions.isEmpty {
                            Button("重试") { Task { await model.sync() } }
                                .disabled(model.isSyncing)
                        }
                        if model.syncMessage != nil {
                            Button { model.syncMessage = nil } label: { Image(systemName: AppSymbol.close.rawValue) }
                                .buttonStyle(.plain)
                                .help("关闭提示")
                        }
                    }
                }
                .font(.caption)
                .padding(12)
                .frame(maxWidth: 340, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
            }
        }

    private var bulkDeletionMessage: String {
        let books = bulkDeletion?.bookmarks ?? []
        return BulkText.format("将永久删除 %lld 篇文章及其划线批注，无法撤销。", books.count) + "\n" + books.prefix(3).map(\.displayTitle).joined(separator: "\n")
    }

    private var bulkBookmarks: [Bookmark] { displayed.filter { bulkSelection.ids.contains($0.id) } }

    private var commandContext: LibraryCommandContext {
        LibraryCommandContext(isReading: selectedBookmark != nil, canSelect: !displayed.isEmpty,
            isSelecting: bulkSelection.isSelecting, isFocused: columnVisibility == .detailOnly,
            isPresentingAlert: annotationWorkspace.hasPresentedAlert) { action in
            switch action {
            case .select: if bulkSelection.isSelecting { bulkSelection.end() } else { bulkSelection.begin() }
            case .cards: layout = .cards
            case .list: layout = .list
            case .captureTasks: showCaptureTasks = true
            case .bulkResults: openBulkResults()
            case .taxonomy: showLabelManager = true
            case .focus: columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
    }

    // Keep the same collection/search state mounted while removing search UI.
    // Entering selection freezes the current query rather than clearing its filter.
    private var collectionSearchText: Binding<String> {
        Binding(get: { searchText }, set: { value in
            if !bulkSelection.isSelecting { searchText = value }
        })
    }
    private var collectionSearchPresented: Binding<Bool> {
        Binding(get: { !bulkSelection.isSelecting && searchPresented }, set: { value in
            searchPresented = !bulkSelection.isSelecting && value
        })
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if bulkSelection.isSelecting { selectionToolbar }
        else { browsingToolbar }
    }

    @ToolbarContentBuilder
    private var browsingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            SymbolButton(title: "保存网页", symbol: .save, explanation: "保存网页（⌘N）") { model.showSaveSheet = true }.disabled(model.isApplyingBulk)
            SymbolButton(title: "选择文章", symbol: .select) { bulkSelection.begin() }.disabled(displayed.isEmpty || model.isApplyingBulk)
            // Borderless Menu is narrower than native buttons. Reserve space on
            // the trailing edge so the last glyph has the same visual inset.
            Menu { libraryMoreMenu } label: {
                ToolbarIconLabel(title: "更多资料库操作", symbol: .more)
                    .padding(.trailing, 7)
            }
                .toolbarIconMenuStyle().help("更多资料库操作").accessibilityLabel("更多资料库操作")
            if ToolbarSizing.showsLayout(at: collectionWidth) {
                Picker("显示方式", selection: $layout) {
                    Label("卡片", systemImage: AppSymbol.cards.rawValue).tag(LibraryLayout.cards)
                    Label("列表", systemImage: AppSymbol.list.rawValue).tag(LibraryLayout.list)
                }.pickerStyle(.segmented).labelStyle(.iconOnly).frame(width: 76).help("切换卡片或列表")
            }
        }.sharedBackgroundVisibility(.visible)
        DefaultToolbarItem(kind: .search, placement: .primaryAction)
    }

    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        ToolbarItem(id: "library.selection.count", placement: .primaryAction) {
            Text("已选 \(bulkSelection.ids.count) 篇").font(.callout).foregroundStyle(.secondary)
        }.sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .primaryAction) {
            if collectionWidth < 540 {
                SymbolButton(title: "分类与标签…", symbol: .category) { openBulkEditor(bulkBookmarks) }.disabled(bulkBookmarks.isEmpty || model.isApplyingBulk)
            } else {
                SymbolButton(title: "分类", symbol: .category) { openBulkEditor(bulkBookmarks, focus: .category) }.disabled(bulkBookmarks.isEmpty || model.isApplyingBulk)
                SymbolButton(title: "标签", symbol: .tag) { openBulkEditor(bulkBookmarks, focus: .tags) }.disabled(bulkBookmarks.isEmpty || model.isApplyingBulk)
            }
            if ToolbarSizing.showsSecondary(at: collectionWidth) {
                Menu { bulkStarActions } label: { ToolbarIconLabel(title: "星标", symbol: .star) }
                    .toolbarIconMenuStyle().help("批量设置或取消星标").accessibilityLabel("星标").disabled(bulkBookmarks.isEmpty || model.isApplyingBulk)
                Menu { bulkArchiveActions } label: { ToolbarIconLabel(title: "归档", symbol: .archive) }
                    .toolbarIconMenuStyle().help("批量归档或移回收件箱").accessibilityLabel("归档").disabled(bulkBookmarks.isEmpty || model.isApplyingBulk)
            }
            Menu { selectionMoreMenu } label: { ToolbarIconLabel(title: "更多所选文章操作", symbol: .more) }
                .toolbarIconMenuStyle().help("更多所选文章操作").accessibilityLabel("更多所选文章操作").disabled(model.isApplyingBulk)
        }.sharedBackgroundVisibility(.visible)
        ToolbarItem(id: "library.selection.done", placement: .primaryAction) {
            Button("完成") { bulkSelection.end() }.keyboardShortcut(.cancelAction)
                .help("完成选择").accessibilityLabel("完成选择").disabled(model.isApplyingBulk)
        }.sharedBackgroundVisibility(.hidden)
    }

    private var bulkStarActions: some View { BulkStarActions { performBulk(bulkBookmarks, intent: $0) } }
    private var bulkArchiveActions: some View { BulkArchiveActions { performBulk(bulkBookmarks, intent: $0) } }
    @ViewBuilder private var selectionMoreMenu: some View {
        if !ToolbarSizing.showsSecondary(at: collectionWidth) {
            Menu { bulkStarActions } label: { Label("星标", systemImage: AppSymbol.star.rawValue) }.disabled(bulkBookmarks.isEmpty)
            Menu { bulkArchiveActions } label: { Label("归档", systemImage: AppSymbol.archive.rawValue) }.disabled(bulkBookmarks.isEmpty)
            Divider()
        }
        Button("全选当前列表") { bulkSelection.selectAll(displayed.map(\.id)) }
        Button("清除选择") { bulkSelection.end();bulkSelection.begin() }
        Button("查看批量记录") { openBulkResults() }
        Divider()
        Button("永久删除所选文章…", role: .destructive) { prepareBulkDelete(bulkBookmarks) }.disabled(bulkBookmarks.isEmpty)
    }

    @ViewBuilder private var libraryMoreMenu: some View {
        Button { Task { await model.sync() } } label: { Label("立即同步", systemImage: AppSymbol.sync.rawValue) }.disabled(model.isSyncing)
        if model.isSyncing { Button("取消同步") { model.cancelSync() } }
        Button { showCaptureTasks = true } label: { Label("采集任务…", systemImage: AppSymbol.capture.rawValue) }
        if needsSyncAttention {
            Button("同步状态…") { showSyncNotice = true; syncNoticeTimer += 1 }
        }
        Button { openBulkResults() } label: { Label("批量整理记录…", systemImage: AppSymbol.history.rawValue) }
        Divider()
        Button { showLabelManager = true } label: { Label("分类与标签…", systemImage: AppSymbol.category.rawValue) }
        if !ToolbarSizing.showsLayout(at: collectionWidth) {
            Divider()
            Picker("显示方式", selection: $layout) {
                Label("卡片", systemImage: AppSymbol.cards.rawValue).tag(LibraryLayout.cards)
                Label("列表", systemImage: AppSymbol.list.rawValue).tag(LibraryLayout.list)
            }
        }
        Divider()
        Picker("排序", selection: $sortOrder) {
            ForEach(LibrarySortOrder.allCases) { Text(AppLanguage.text($0.label)).tag($0) }
        }
        if layout == .list {
            Picker("列表密度", selection: $listDensity) {
                Text("标准").tag(LibraryListDensity.standard)
                Text("紧凑").tag(LibraryListDensity.compact)
            }
            Toggle("显示缩略图", isOn: $listThumbnails)
        }
        Divider()
        SettingsLink { Label("设置…", systemImage: AppSymbol.settings.rawValue) }
    }

    private func contextBookmarks(_ item: Bookmark) -> [Bookmark] {
        if bulkSelection.isSelecting, bulkSelection.ids.contains(item.id) { return bulkBookmarks }
        bulkSelection.selectOnly(item.id);return [item]
    }
    private func openBulkEditor(_ items: [Bookmark], focus: BulkEditorFocus? = nil) {
        guard !items.isEmpty, let client = model.client else { return }
        model.bulkError = nil
        bulkEditor = BulkEditorRequest(connectionID: client.storageInstance, bookmarks: items, focus: focus)
    }
    private func prepareBulkDelete(_ items: [Bookmark]) {
        guard !items.isEmpty, let client = model.client else { return }
        bulkDeletion = BulkEditorRequest(connectionID: client.storageInstance, bookmarks: items)
    }
    private func performBulk(_ items: [Bookmark], intent: BulkEditIntent, batchID: String = UUID().uuidString, connectionID: String? = nil) {
        guard !items.isEmpty, let owner = connectionID ?? model.client?.storageInstance else { return }
        Task {
            guard model.client?.storageInstance == owner else { return }
            let saved = await model.applyBulk(id: batchID, bookmarks: items, intent: intent)
            if saved, model.client?.storageInstance == owner { bulkSelection.end() }
        }
    }
    private func openBulkResults() {
        resultsConnectionID = model.client?.storageInstance ?? "";showBulkResults = true
    }
    private func clearBulkPresentation() {
        bulkSelection.end();bulkEditor = nil;bulkDeletion = nil;showBulkResults = false
    }

    private var title: String {
        switch section ?? .inbox {
        case .inbox: "收件箱"
        case .unread: "未读"
        case .reading: "阅读中"
        case .favorites: "星标"
        case .archive: "已归档"
        case .categoryConflicts: "分类待整理"
        case let .category(name), let .tag(name): name
        case let .collection(id): model.collections.first { $0.id == id }?.name ?? "智能列表"
        }
    }
}
