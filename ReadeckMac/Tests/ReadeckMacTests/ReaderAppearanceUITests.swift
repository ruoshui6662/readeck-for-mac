import AppKit
import SwiftUI
import XCTest
@testable import ReadeckMac

@MainActor
final class ReaderAppearanceUITests: XCTestCase {
    func testPrimaryPanelIsCompactAndSliderEditsPersistWithoutResettingAdvancedValues() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let suite="appearance-qa-"+UUID().uuidString
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences=ReaderPreferences(defaults:defaults)
        preferences.style.paragraphSpacing=1.25
        let host=NSHostingView(rootView:ReaderAppearanceView().environmentObject(preferences))
        host.sizingOptions=[]
        let window=NSWindow(contentRect:NSRect(x:100,y:100,width:300,height:340),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for:.milliseconds(200))
        let sliders=descendants(host,as:NSSlider.self)
        XCTAssertEqual(sliders.count,3,"Only font size, line spacing and column width belong in the primary panel")
        XCTAssertTrue(sliders.allSatisfy { $0.numberOfTickMarks == 0 },"Avoid visual tick-dot noise")
        let ordered = sliders.sorted { host.convert($0.bounds, from: $0).minY < host.convert($1.bounds, from: $1).minY }
        let size=try XCTUnwrap(ordered.first)
        // SwiftUI maps the native continuous track to 0...1.
        size.doubleValue=size.minValue+(size.maxValue-size.minValue)*(24-12)/18
        XCTAssertTrue(size.sendAction(size.action,to:size.target))
        XCTAssertEqual(preferences.style.fontSize,24)
        window.makeFirstResponder(size)
        let right=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\u{F703}",charactersIgnoringModifiers:"\u{F703}",isARepeat:false,keyCode:124))
        window.sendEvent(right)
        XCTAssertEqual(preferences.style.fontSize,25,"Keyboard arrows must move exactly one size step")
        XCTAssertEqual(ReaderPreferences(defaults:defaults).style.paragraphSpacing,1.25)
        let line=try XCTUnwrap(ordered.dropFirst().first)
        line.doubleValue=line.minValue+(line.maxValue-line.minValue)*0.63
        XCTAssertTrue(line.sendAction(line.action,to:line.target))
        XCTAssertEqual(preferences.style.lineHeight,1.8,accuracy:0.0001)
        window.makeFirstResponder(line)
        window.sendEvent(right)
        XCTAssertEqual(preferences.style.lineHeight,1.9,accuracy:0.0001,"Keyboard adjustment must also work with fractional steps")
        _ = line.accessibilityPerformIncrement()
        XCTAssertEqual(preferences.style.lineHeight,2.0,accuracy:0.0001,"Assistive adjustment must advance the same step")
        let preset=try XCTUnwrap(descendants(host,as:NSSegmentedControl.self).first { $0.accessibilityLabel() == AppLanguage.text("排版预设") })
        preset.selectedSegment=1
        XCTAssertTrue(preset.sendAction(preset.action,to:preset.target))
        XCTAssertEqual(preferences.style.fontSize,17)
        XCTAssertEqual(ReaderPreferences(defaults:defaults).style.paragraphSpacing,1.25)
        try await Task.sleep(for:.milliseconds(80))
        try snapshot(host,"settings-light")
        window.appearance=NSAppearance(named:.darkAqua);host.appearance=window.appearance
        try await Task.sleep(for:.milliseconds(100))
        try snapshot(host,"settings-dark")

    }
    func testMoreLayoutLabelExpandsAndCollapsesInActualPopover() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let suite = "appearance-popover-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ReaderPreferences(defaults: defaults)
        let controller = NSHostingController(rootView: AppearancePopoverFixture().environmentObject(preferences))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 400, height: 100))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let content = try XCTUnwrap(window.contentView)
        try click(NSPoint(x: content.bounds.midX, y: content.bounds.midY), in: content, window: window)
        try await Task.sleep(for: .milliseconds(300))
        let popover = try XCTUnwrap(NSApp.windows.first { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") })
        defer { popover.close() }
        let panel = try XCTUnwrap(popover.contentView)
        XCTAssertEqual(descendants(panel, as: NSSlider.self).count, 3)
        try snapshot(panel, "popover-before")
        let collapsedHeight = popover.frame.height
        preferences.style.paragraphSpacing = 1.25
        // The whole More Layout row, including its text, must respond to a click.
        try click(NSPoint(x: 65, y: 240), in: panel, window: popover)
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(panel, "popover-after-label")
        XCTAssertEqual(descendants(panel, as: NSSlider.self).count, 7, "Clicking the More Layout text must reveal advanced controls")
        XCTAssertGreaterThan(popover.frame.height, collapsedHeight + 150, "Popover must grow automatically without manually resizing the test window")
        try click(NSPoint(x: 65, y: 240), in: panel, window: popover)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(descendants(panel, as: NSSlider.self).count, 3, "Clicking the text again must collapse the layout controls")
        XCTAssertEqual(popover.frame.height, collapsedHeight, accuracy: 2)
        // The unused trailing area is part of the same disclosure row.
        try click(NSPoint(x: 280, y: 240), in: panel, window: popover)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(descendants(panel, as: NSSlider.self).count, 7)
        try click(NSPoint(x: 33, y: 240), in: panel, window: popover)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(descendants(panel, as: NSSlider.self).count, 3, "The arrow must still collapse the same row")
        XCTAssertEqual(ReaderPreferences(defaults: defaults).style.paragraphSpacing, 1.25, "Toggling disclosure must preserve saved reading settings")
        try snapshot(panel, "popover-collapsed-again")
    }

    private func click(_ fromTop: NSPoint, in view: NSView, window: NSWindow) throws {
        let point = NSPoint(x: fromTop.x, y: view.isFlipped ? fromTop.y : view.bounds.maxY - fromTop.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    private func descendants<T:NSView>(_ view:NSView,as type:T.Type)->[T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0,as:type) }
    }
    private func snapshot(_ view:NSView,_ name:String) throws {
        guard let output=ProcessInfo.processInfo.environment["READECK_APPEARANCE_QA_DIR"] else{return}
        let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        view.layoutSubtreeIfNeeded()
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(name+".png"))
    }
}

private struct AppearancePopoverFixture: View {
    @State private var showAppearance = false
    var body: some View {
        SymbolButton(title: "排版", symbol: .appearance) { showAppearance.toggle() }
            .popover(isPresented: $showAppearance) { ReaderAppearanceView() }
            .frame(width: 400, height: 100)
    }
}
