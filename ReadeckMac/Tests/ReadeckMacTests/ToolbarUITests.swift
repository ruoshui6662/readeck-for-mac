import AppKit
import SwiftUI
import XCTest
@testable import ReadeckMac

@MainActor
final class ToolbarUITests: XCTestCase {
    func testReadingThemeCoordinatesNativeWindowAndRestoresSystemOnBack() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let originalAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = originalAppearance }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "sidebar-theme-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: temp); defaults.removePersistentDomain(forName: suite) }
        let store = try LocalStore(url: temp.appendingPathComponent("library.sqlite"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ToolbarOfflineProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://sidebar-ui.test/"), token: "test-only", session: URLSession(configuration: config))
        let book = Bookmark(id: "sidebar-book", url: "https://example.com/reading", title: "让阅读回到内容本身", siteName: "阅读笔记", labels: ["分类/科技", "阅读"], readProgress: 0)
        try await store.upsert(book, instance: client.storageInstance)
        try await store.setArticle(String(repeating: "<p>界面保持安静，工具在需要的时候出现。</p>", count: 20), id: book.id, instance: client.storageInstance)
        let model = AppModel(client: client, store: store, cacheDefaults: defaults)
        await model.loadCached(); model.cancelSync()
        let prefs = ReaderPreferences(defaults: defaults)
        prefs.style.theme = "dark"
        let controller = NSHostingController(rootView: LibraryView(model: model).environmentObject(prefs).defaultAppStorage(defaults))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1180, height: 740)); window.makeKeyAndOrderFront(nil)
        defer { window.close(); model.cancelSync() }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua, "Browsing follows the system even when the saved reader theme is dark")
        try snapshot(window, "notes-collection-light")
        try clickContent(NSPoint(x: 400, y: 120), in: window)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(window.toolbar?.items.contains { $0.label == AppLanguage.text("返回收藏列表") } == true, "The real production card must open the reader")
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua, "Dark reading should coordinate native sidebar and toolbar")
        try snapshot(window, "notes-reading-dark")
        try click(try XCTUnwrap(window.toolbar?.items.first { $0.label == AppLanguage.text("切换为亮色") }), in: window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(prefs.style.theme, "light")
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        try click(try XCTUnwrap(window.toolbar?.items.first { $0.label == AppLanguage.text("切换为暗色") }), in: window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(prefs.style.theme, "dark")
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        try click(try XCTUnwrap(window.toolbar?.items.first { $0.label == AppLanguage.text("返回收藏列表") }), in: window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua, "Leaving dark reading must restore a light system")
        XCTAssertEqual(prefs.style.theme, "dark")
        try clickContent(NSPoint(x: 400, y: 120), in: window)
        try await Task.sleep(for: .milliseconds(300))
        NSApp.appearance = NSAppearance(named: .darkAqua)
        prefs.style.theme = "sepia"
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua, "Warm paper uses light native controls even when the system is dark")
        try snapshot(window, "notes-reading-sepia")
        try click(try XCTUnwrap(window.toolbar?.items.first { $0.label == AppLanguage.text("返回收藏列表") }), in: window)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua, "Returning to the collection must release the reader override")
        XCTAssertEqual(prefs.style.theme, "sepia", "Leaving reading must not rewrite the saved theme")
        try snapshot(window, "notes-collection-system-dark")

    }

    func testProductionToolbarRendersInNativeWindowWithoutUserConnection() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "toolbar-qa-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: temp);defaults.removePersistentDomain(forName: suite) }
        let store = try LocalStore(url: temp.appendingPathComponent("library.sqlite"))
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ToolbarOfflineProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://toolbar-ui.test/"), token: "test-only", session: URLSession(configuration: config))
        let book = Bookmark(id: "toolbar-book",url:"https://example.com/reading", title:"清晰的工具，让阅读更专注",siteName:"阅读笔记",labels:["分类/科技","阅读"],readProgress:35)
        try await store.upsert(book,instance:client.storageInstance)
        try await store.setArticle("<p>在阅读中留下一点思考。</p>" + String(repeating:"<p>每个图标有固定的含义，每次操作都能被理解。</p>",count:15),id:book.id,instance:client.storageInstance)
        let model = AppModel(client:client,store:store,cacheDefaults:defaults)
        await model.loadCached();model.cancelSync()
        let prefs = ReaderPreferences(defaults:defaults)
        let root = LibraryView(model:model).environmentObject(prefs).defaultAppStorage(defaults)
            .environment(\.locale,Locale(identifier:"zh-Hans"))
        let controller = NSHostingController(rootView:root)
        let window = NSWindow(contentViewController:controller)
        window.isReleasedWhenClosed = false;window.styleMask = [.titled,.closable,.resizable,.miniaturizable]
        window.setContentSize(NSSize(width:1180,height:700));window.makeKeyAndOrderFront(nil)
        defer { window.close();model.cancelSync() }
        try await Task.sleep(for:.milliseconds(500))
        print("TOOLBAR-QA",window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? [])
        try snapshot(window,"library-wide")
        XCTAssertNotNil(window.toolbar,"The production SwiftUI toolbar must be installed in this window.")
        let field=try XCTUnwrap(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first?.searchField)
        field.stringValue="清晰"
        field.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:field))
        try await Task.sleep(for:.milliseconds(450))
        let select=try XCTUnwrap(window.toolbar?.items.first { $0.label == AppLanguage.text("选择文章") })
        try click(select,in:window)
        try await Task.sleep(for:.milliseconds(180))
        print("SELECTION-ITEMS",window.toolbar?.items.map(\.label) ?? [])
        XCTAssertTrue(window.toolbar?.items.contains { $0.label == AppLanguage.text("分类") } == true)
        assertSelectionHasNoBrowseControls(window)
        try click(try XCTUnwrap(window.toolbar?.items.first { $0.label == AppLanguage.text("分类") }),in:window)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertNil(window.attachedSheet,"No batch editor should open with an empty selection")
        // Native fixture's first card cover, measured in the accepted wide
        // render. Exercise the real selection callback rather than a test hook.
        try clickContent(NSPoint(x:400,y:120),in:window)
        try await Task.sleep(for:.milliseconds(180))
        try snapshot(window,"library-selection")
        window.setContentSize(NSSize(width:880,height:640))
        try await Task.sleep(for:.milliseconds(250))
        assertSelectionHasNoBrowseControls(window)
        try snapshot(window,"library-narrow")
        let done=try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue.contains("library.selection.done") })
        try click(done,in:window)
        try await Task.sleep(for:.milliseconds(220))
        assertBrowsingHasSingleControls(window)
        XCTAssertEqual(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first?.searchField.stringValue,"清晰","Entering selection must preserve the existing search filter")
        defaults.set(LibraryLayout.list.rawValue,forKey:"library.layout")
        try await Task.sleep(for:.milliseconds(200))
        try click(try XCTUnwrap(window.toolbar?.items.first { $0.label == AppLanguage.text("选择文章") }),in:window)
        try await Task.sleep(for:.milliseconds(200))
        assertSelectionHasNoBrowseControls(window)
        let listTable = try XCTUnwrap(findTables(try XCTUnwrap(window.contentView)).max { $0.bounds.width < $1.bounds.width })
        let articleRect = listTable.rect(ofRow: listTable.numberOfRows - 1)
        try clickPoint(listTable.convert(NSPoint(x: 60, y: articleRect.midY), to: nil), in: window)
        try await Task.sleep(for:.milliseconds(180))
        try snapshot(window,"list-selection")
        window.appearance = NSAppearance(named:.darkAqua)
        try await Task.sleep(for:.milliseconds(200))
        try snapshot(window,"library-dark")
        try click(try XCTUnwrap(window.toolbar?.items.first { $0.label == AppLanguage.text("分类") }),in:window)
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertNotNil(window.attachedSheet,"A selected article must enable the real batch editor action")
        try snapshot(window.attachedSheet ?? window,"selected-editor")
        window.close()
        prefs.outlinePresentation = .classic
        prefs.style.theme = "light"
        let workspace=AnnotationWorkspace()
        let reader=ReaderView(model:model,workspace:workspace,bookmark:book).environmentObject(prefs)
        let readerController=NSHostingController(rootView:NavigationStack { reader })
        let readerWindow=NSWindow(contentViewController:readerController)
        readerWindow.isReleasedWhenClosed=false
        readerWindow.setContentSize(NSSize(width:900,height:650));readerWindow.orderFront(nil)
        defer { readerWindow.close() }
        try await Task.sleep(for:.milliseconds(400))
        print("READER-ITEMS",readerWindow.toolbar?.items.map(\.label) ?? [])
        XCTAssertTrue(readerWindow.toolbar?.items.contains { $0.label == AppLanguage.text("目录与笔记") } == true)
        try snapshot(readerWindow,"reader-wide")
        let notes=try XCTUnwrap(readerWindow.toolbar?.items.first { $0.label == AppLanguage.text("目录与笔记") })
        try click(notes,in:readerWindow)
        try await Task.sleep(for:.milliseconds(650))
        try snapshot(readerWindow,"reader-notes")
        XCTAssertTrue(workspace.isPresented)
        readerWindow.setContentSize(NSSize(width: 760, height: 650))
        try await Task.sleep(for: .milliseconds(250))
        for title in ["排版", "目录与笔记", "切换为暗色", "更多文章操作"] {
            XCTAssertTrue(readerWindow.toolbar?.items.contains { $0.label == AppLanguage.text(title) } == true,
                          "Narrow reader with notes must retain \(title)")
        }
        try click(try XCTUnwrap(readerWindow.toolbar?.items.first { $0.label == AppLanguage.text("切换为暗色") }), in: readerWindow)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(prefs.style.theme, "dark", "Quick theme remains actionable beside the notes inspector")
        try click(try await activeItem("目录与笔记", in: readerWindow),in:readerWindow)
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertFalse(workspace.isPresented)
    }
    private func activeItem(_ title: String, in window: NSWindow) async throws -> NSToolbarItem {
        // Theme/inspector changes replace native toolbar views asynchronously.
        // Target the attached control, never a detached item retained during transition.
        for _ in 0..<20 {
            if let item = window.toolbar?.items.first(where: { $0.label == AppLanguage.text(title) && $0.view?.window === window }) { return item }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(window.toolbar?.items.first { $0.label == AppLanguage.text(title) && $0.view?.window === window })
    }
    private func findTables(_ view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(findTables)
    }
    private func clickContent(_ fromTop:NSPoint,in window:NSWindow) throws {
        let content=try XCTUnwrap(window.contentView)
        let point=NSPoint(x:fromTop.x,y:content.isFlipped ? fromTop.y : content.bounds.maxY-fromTop.y)
        try clickPoint(content.convert(point,to:nil),in:window)
    }
    private func assertSelectionHasNoBrowseControls(_ window:NSWindow,file:StaticString=#filePath,line:UInt=#line) {
        let items=window.toolbar?.items ?? []
        let labels=items.map(\.label)
        for title in ["保存网页","选择文章","显示方式","更多资料库操作"] {
            XCTAssertFalse(labels.contains(AppLanguage.text(title)),"Unexpected browsing action: \(title)",file:file,line:line)
        }
        XCTAssertFalse(items.contains { $0 is NSSearchToolbarItem || $0.itemIdentifier.rawValue == "com.apple.SwiftUI.search" },"Native browsing search must not remain in selection mode",file:file,line:line)
    }
    private func assertBrowsingHasSingleControls(_ window:NSWindow,file:StaticString=#filePath,line:UInt=#line) {
        let labels=(window.toolbar?.items ?? []).map(\.label)
        for title in ["保存网页","选择文章","更多资料库操作"] {
            XCTAssertEqual(labels.filter { $0 == AppLanguage.text(title) }.count,1,title,file:file,line:line)
        }
        XCTAssertFalse(labels.contains(AppLanguage.text("更多所选文章操作")),file:file,line:line)
        XCTAssertEqual((window.toolbar?.items ?? []).filter { $0.itemIdentifier.rawValue == "com.apple.SwiftUI.search" }.count,1,file:file,line:line)
    }
    private func click(_ item:NSToolbarItem,in window:NSWindow) throws {
        let view=try XCTUnwrap(item.view)
        let rect=view.convert(view.bounds,to:nil)
        print("CLICK-QA",item.label,rect,view.window === window)
        try clickPoint(NSPoint(x:rect.midX,y:rect.midY),in:window)
    }
    private func clickPoint(_ point:NSPoint,in window:NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            let event=try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
            window.sendEvent(event)
        }
    }
    private func snapshot(_ window:NSWindow,_ name:String) throws {
        guard let output=ProcessInfo.processInfo.environment["READECK_TOOLBAR_QA_DIR"] else{return}
        let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let view=try XCTUnwrap(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(name+".png"))
        let header=NSRect(x:view.bounds.minX,y:view.isFlipped ? view.bounds.minY : view.bounds.maxY-60,width:view.bounds.width,height:60)
        if window.toolbar != nil, let strip=view.bitmapImageRepForCachingDisplay(in:header) {
            view.cacheDisplay(in:header,to:strip)
            try XCTUnwrap(strip.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(name+"-toolbar.png"))
        }
    }
}
private final class ToolbarOfflineProtocol: URLProtocol {
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading(){client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet))}
    override func stopLoading(){}
}
