import Foundation

enum ManagedLabelKind: String, CaseIterable, Identifiable {
    case category, tag
    var id: String { rawValue }
    var title: String { self == .category ? "分类" : "标签" }
    var symbol: String { self == .category ? "folder" : "tag" }
    func serverLabel(_ name: String) -> String { self == .category ? CategoryCodec.label(for: name) : name }

    func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TaxonomyError.invalid("请输入\(title)名称。") }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else { throw TaxonomyError.invalid("名称不能包含换行或控制字符。") }
        if self == .tag, CategoryCodec.isCategoryLabel(name) { throw TaxonomyError.invalid("这个前缀用于分类，请使用其他标签名称。") }
        if self == .category, name == "未分类" { throw TaxonomyError.invalid("“未分类”表示没有分类，请使用其他名称。") }
        return name
    }
}

enum TaxonomyError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

struct LabelPreferences: Codable, Equatable {
    var pinned: [String] = []
    var recent: [String] = []
    var managedCategories: [String] = []
    var managedTags: [String] = []
    var revision = 0

    init() {}
    private enum CodingKeys: String, CodingKey { case pinned, recent, managedCategories, managedTags, revision }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try values.decodeIfPresent([String].self, forKey: .pinned) ?? []
        recent = try values.decodeIfPresent([String].self, forKey: .recent) ?? []
        managedCategories = try values.decodeIfPresent([String].self, forKey: .managedCategories) ?? []
        managedTags = try values.decodeIfPresent([String].self, forKey: .managedTags) ?? []
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }

    mutating func addManagedLabel(_ value: String, kind: ManagedLabelKind) throws {
        let name = try kind.validatedName(value)
        let existing = kind == .category ? managedCategories : managedTags
        guard !existing.contains(name) else { throw TaxonomyError.invalid("这个\(kind.title)已存在。") }
        if kind == .category { managedCategories.append(name) }
        else { managedTags.append(name) }
        revision += 1
    }

    mutating func togglePin(_ name: String) {
        guard !name.isEmpty, !CategoryCodec.isCategoryLabel(name) else { return }
        if pinned.contains(name) { pinned.removeAll { $0 == name } }
        else { pinned.append(name) }
        revision += 1
    }

    mutating func recordUse(_ names: [String]) {
        let used = LabelCatalog.unique(names.filter { !CategoryCodec.isCategoryLabel($0) && !$0.isEmpty })
        guard !used.isEmpty else { return }
        recent = Array((used + recent.filter { !used.contains($0) }).prefix(12))
        revision += 1
    }
}

struct LabelCatalog {
    let tags: [String]
    let categories: [String]
    let preferences: LabelPreferences

    init(bookmarks: [Bookmark], pending: [PendingSave], remoteNames: [String], preferences: LabelPreferences) {
        self.preferences = preferences
        let names = bookmarks.flatMap(\.labelValues) + pending.flatMap(\.labels) + remoteNames
            + preferences.pinned + preferences.recent + preferences.managedTags
            + preferences.managedCategories.map(CategoryCodec.label(for:))
        tags = Set(names.filter { !CategoryCodec.isCategoryLabel($0) && !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        categories = Set(names.compactMap(CategoryCodec.name(from:)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func matchingTags(_ query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? tags : tags.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func cleanedTags(_ values: [String]) -> [String] {
        unique(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !CategoryCodec.isCategoryLabel($0) })
    }
}
