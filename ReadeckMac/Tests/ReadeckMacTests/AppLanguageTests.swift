import XCTest
@testable import ReadeckMac

final class AppLanguageTests: XCTestCase {
    func testMenusFollowSupportedSystemLanguageWithRegionalFallback() {
        XCTAssertEqual(AppLanguage.text("资料库", languages: ["zh-Hans-US", "en-US"]), "资料库")
        XCTAssertEqual(AppLanguage.text("资料库", languages: ["en-US"]), "Library")
        XCTAssertEqual(AppLanguage.text("保存网页", languages: ["en-GB"]), "Save Webpage")
        XCTAssertEqual(AppLanguage.text("写批注", languages: ["en"]), "Add Note")
        XCTAssertEqual(AppLanguage.text("资料库", languages: ["de-DE", "en-US"]), "Library")
        XCTAssertEqual(AppLanguage.text("资料库", languages: ["de-DE", "zh-Hans-CN", "en-US"]), "资料库")
    }
    func testBulkOrganizationMenusFollowChineseAndEnglishSystemLanguages() {
        XCTAssertEqual(AppLanguage.text("批量整理", languages: ["en-US"]), "Organize Articles")
        XCTAssertEqual(AppLanguage.text("保持原分类", languages: ["en-US"]), "Keep Current Categories")
        XCTAssertEqual(AppLanguage.text("全选当前列表", languages: ["en-US"]), "Select All in Current List")
        XCTAssertEqual(AppLanguage.text("批量整理", languages: ["zh-Hans-CN"]), "批量整理")
    }

    func testListDisplayOptionsAreLocalized() {
        XCTAssertEqual(AppLanguage.text("列表密度", languages: ["en"]), "List Density")
        XCTAssertEqual(AppLanguage.text("显示缩略图", languages: ["en"]), "Show Thumbnails")
        XCTAssertEqual(AppLanguage.text("最近保存", languages: ["en"]), "Recently Saved")
        XCTAssertEqual(AppLanguage.text("%lld 篇收藏", languages: ["en"]), "%lld articles")
        XCTAssertEqual(AppLanguage.text("列表密度", languages: ["zh-Hans"]), "列表密度")
        XCTAssertEqual(AppLanguage.text("标记为已读", languages: ["en"]), "Mark as Read")
    }

}
