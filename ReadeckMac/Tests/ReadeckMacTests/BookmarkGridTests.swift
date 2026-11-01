import AppKit
import SwiftUI
import XCTest
@testable import ReadeckMac

@MainActor
final class BookmarkGridTests: XCTestCase {
    func testCardsKeepTheirSizeAcrossTwoAndThreeColumnViewports() async throws {
        _ = NSApplication.shared
        let titles = ["在城市中重新发现阅读", "工程专业学位校准“实践导向”评价标尺：从真实问题出发，重新认识长期价值", "AI 时代的数学研究"]
        let books = (0..<7).map { index in
            Bookmark(id: "card-\(index)", url: "https://example.com/\(index)", title: titles[index % titles.count], siteName: index == 2 ? "少数派 · 高品质数字消费指南" : "示例来源", readProgress: index*15, isMarked: index == 2, readingTime: index+1)
        }
        let view = BookmarkGridView(bookmarks: books, pending: [], client: nil, onOpen: { _ in }, onRename: { _ in }, onDelete: { _ in })
        func root(_ scheme: ColorScheme) -> some View {
            view.environment(\.colorScheme, scheme).background(Color(nsColor: .windowBackgroundColor))
        }
        let host = NSHostingView(rootView: root(.light))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host;window.orderFront(nil)
        defer { window.close() }
        var widths: [CGFloat] = []
        let cases: [(String, CGFloat, ColorScheme, Int)] = [("two", 700, .light, 2), ("three", 950, .light, 3),
            ("three-dark", 950, .dark, 3), ("four", 1200, .light, 4), ("narrow", 270, .light, 1)]
        for (name, width, scheme, columns) in cases {
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.rootView = root(scheme)
            window.setContentSize(NSSize(width: width, height: 760))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let metrics = LibraryCardGridMetrics(viewportWidth: width)
            widths.append(metrics.cardWidth)
            XCTAssertEqual(metrics.cardWidth, min(252, width - 48), accuracy: 1)
            XCTAssertEqual(metrics.columns, columns)
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            if let output = ProcessInfo.processInfo.environment["READECK_CARD_QA_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("cards-\(name).png"))
            }
        }
        XCTAssertEqual(widths[0], widths[1], accuracy: 1, "Changing columns must not inflate the cards")
    }
    func testNarrowWideAndBreakpointWidthsNeverOverflowOrInflateCards() {
        for viewport in stride(from: 80.0, through: 1600.0, by: 1) {
            let metrics = LibraryCardGridMetrics(viewportWidth: viewport)
            XCTAssertGreaterThanOrEqual(metrics.columns, 1)
            XCTAssertLessThanOrEqual(metrics.cardWidth, 252)
            XCTAssertLessThanOrEqual(metrics.gridWidth + 2*metrics.horizontalInset, viewport + 0.01)
        }
        let before = LibraryCardGridMetrics(viewportWidth: 839)
        let after = LibraryCardGridMetrics(viewportWidth: 840)
        XCTAssertEqual(before.cardWidth, after.cardWidth)
        XCTAssertEqual(before.columns, 2)
        XCTAssertEqual(after.columns, 3)
        for invalid in [Double.nan, Double.infinity, -50] {
            let value = LibraryCardGridMetrics(viewportWidth: invalid)
            XCTAssertTrue(value.cardWidth.isFinite)
            XCTAssertGreaterThan(value.cardWidth, 0)
        }
    }

}
