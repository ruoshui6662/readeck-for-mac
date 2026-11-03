# Readeck Mac

[简体中文](README.md) | [English](README.en.md)

A native macOS read-it-later client for self-hosted [Readeck](https://codeberg.org/readeck/readeck). Built with SwiftUI and WebKit, it uses the Readeck API to organize your library, customize your reading experience, highlight and annotate articles, and queue local changes for synchronization when a connection becomes available.

The project is under development. Website capture and NAS synchronization may have limitations depending on the source site and your environment. Xiaohongshu capture is currently on hold, and CSDN support is not yet complete.

## Getting started

Building and testing require macOS 26 or later, Xcode, and Swift 6.2:

```sh
cd ReadeckMac
swift run ReadeckMac
swift test
```

To build a local app:

```sh
cd ReadeckMac
zsh scripts/build-app.sh
```

The build uses an ad hoc signature by default and does not require a paid Apple Developer account for personal use. macOS may ask for Keychain or local network access again after a rebuild. When you first launch the app, enter your Readeck server address and API token. HTTP transmits the token without encryption and should be used only on trusted networks; HTTPS uses system certificate validation.

For additional feature and technical details, see the [client documentation](ReadeckMac/README.md). The [repository structure](docs/REPOSITORY.md) describes the workspace archives and what is included in the public repository. These documents are currently in Chinese.

## License

This project's code is licensed under the [GNU Affero General Public License v3.0 only (AGPL-3.0-only)](LICENSE). Third-party components and assets have their own licenses: see the [SwiftSoup license](ReadeckMac/Sources/ReadeckMac/Resources/Licenses/SwiftSoup.txt), the [license for the project referenced by the WeChat page adapter](ReadeckMac/Sources/ReadeckMac/Resources/Licenses/wechat-article-exporter.txt), and the [artwork credits](ReadeckMac/Sources/ReadeckMac/Resources/Artwork/CREDITS.md). The Readeck server is a separate upstream project governed by its own license; its source code is not included in this repository.

Readeck Mac is an independent client project. No official affiliation with or endorsement by the upstream Readeck project is claimed.
