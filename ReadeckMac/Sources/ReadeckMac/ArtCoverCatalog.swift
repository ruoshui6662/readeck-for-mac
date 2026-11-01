import Foundation
import CryptoKit

struct ArtCover: Decodable, Identifiable {
    let id: String
    let filename: String
    let title: String
    let artist: String
    let source: String
    let license: String
    let isPublicDomain: Bool
    let sha256: String
}

enum AppResources {
    static var bundle: Bundle {
        Bundle.main.url(forResource: "artworks", withExtension: "json", subdirectory: "Artwork") != nil ? .main : .module
    }
}

enum ArtCoverCatalog {
    static let shared: [ArtCover] = (try? load()) ?? []
    static func load() throws -> [ArtCover] {
        guard let url = AppResources.bundle.url(forResource: "artworks", withExtension: "json", subdirectory: "Artwork") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([ArtCover].self, from: Data(contentsOf: url))
    }
    static func artwork(for identity: String, in items: [ArtCover]) -> ArtCover {
        precondition(!items.isEmpty)
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return items[Int(hash % UInt64(items.count))]
    }
    static func imageURL(for item: ArtCover) -> URL? {
        AppResources.bundle.url(forResource: item.filename, withExtension: nil, subdirectory: "Artwork")
    }
}

enum AppLanguage {
    static func text(_ key: String, languages: [String] = Locale.preferredLanguages) -> String {
        let language = Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: languages).first ?? "en"
        guard let path = AppResources.bundle.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
