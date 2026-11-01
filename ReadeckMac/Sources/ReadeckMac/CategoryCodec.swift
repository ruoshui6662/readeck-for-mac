import Foundation

enum CategoryCodec {
    static let legacyPrefix = "mac-category/"
    static let readablePrefix = "分类/"

    struct Assignment {
        let names: [String]
        let hasConflict: Bool
        var category: String? { !hasConflict && names.count == 1 ? names[0] : nil }
    }

    static func isCategoryLabel(_ label: String) -> Bool {
        label.hasPrefix(readablePrefix) || label.hasPrefix(legacyPrefix)
    }

    static func assignment(in labels: [String]) -> Assignment {
        let categoryLabels = labels.filter { isCategoryLabel($0) }
        let decoded = categoryLabels.compactMap(name(from:))
        let names = Array(Set(decoded)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Assignment(names: names, hasConflict: names.count > 1 || decoded.count != categoryLabels.count)
    }

    static func labelsForWrite(_ labels: [String]) throws -> [String] {
        let assignment = assignment(in: labels)
        guard !assignment.hasConflict else { throw TaxonomyError.invalid("每篇文章只能选择一个分类，请先整理分类冲突。") }
        return LabelCatalog.unique(replacingCategory(in: labels, with: assignment.category))
    }

    static func label(for name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return readablePrefix + clean
    }

    static func name(from label: String) -> String? {
        if label.hasPrefix(readablePrefix) {
            let value = String(label.dropFirst(readablePrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let validated = try? ManagedLabelKind.category.validatedName(value), validated == value else { return nil }
            return value
        }
        guard label.hasPrefix(legacyPrefix) else { return nil }
        let encoded = String(label.dropFirst(legacyPrefix.count))
        guard !encoded.isEmpty, let name = encoded.removingPercentEncoding,
              let validated = try? ManagedLabelKind.category.validatedName(name), validated == name else { return nil }
        return name
    }

    static func replacingCategory(in labels: [String], with name: String?) -> [String] {
        var result = labels.filter { !isCategoryLabel($0) }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(label(for: name))
        }
        return result
    }
}
