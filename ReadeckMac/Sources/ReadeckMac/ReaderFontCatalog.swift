import AppKit

struct InstalledReaderFont: Identifiable {
    let familyName: String
    let displayName: String
    let previewName: String

    var id: String { familyName }
    var selectionValue: String { "custom:" + familyName }

    func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || displayName.localizedCaseInsensitiveContains(term) ||
            familyName.localizedCaseInsensitiveContains(term)
    }
}

@MainActor
enum ReaderFontCatalog {
    static func displayName(for family: String) -> String {
        let localized = NSFontManager.shared.localizedName(forFamily: family, face: nil)
        return localized.isEmpty ? family : localized
    }

    static func installed() -> [InstalledReaderFont] {
        let manager = NSFontManager.shared
        return Set(manager.availableFontFamilies).map { family in
            InstalledReaderFont(familyName: family, displayName: displayName(for: family),
                                previewName: manager.font(withFamily: family, traits: [], weight: 5, size: 15)?.fontName ?? family)
        }.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.familyName < $1.familyName : order == .orderedAscending
        }
    }
}
