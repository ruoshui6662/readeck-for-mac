// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReadeckMac",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "ReadeckMac", targets: ["ReadeckMac"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3")],
    targets: [
        .executableTarget(name: "ReadeckMac", dependencies: ["SwiftSoup"], resources: [.copy("Resources/Artwork"), .copy("Resources/Branding"), .copy("Resources/Licenses"), .process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj")], linkerSettings: [
            .linkedFramework("SwiftUI"),
            .linkedFramework("WebKit"),
            .linkedFramework("CryptoKit"),
            .linkedFramework("Security"),
            .linkedLibrary("sqlite3")
        ]),
        .testTarget(name: "ReadeckMacTests", dependencies: ["ReadeckMac"])
    ],
    swiftLanguageModes: [.v5]
)
