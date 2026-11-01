# Readeck Mac

面向自托管 Readeck 的原生 macOS 稍后阅读客户端。使用 SwiftUI、WebKit 和 Readeck API，支持资料库整理、阅读设置、划线与批注，以及断线后的本地待同步队列。

项目仍在开发中；站点采集与 NAS 同步在不同环境下可能存在限制。小红书采集暂缓，CSDN 适配暂未完成。

## 开始使用

需要 macOS 26 或更新版本、Swift 6.2 与 Xcode。运行或测试：

```sh
cd ReadeckMac
swift run ReadeckMac
swift test
```

构建本地应用：

```sh
cd ReadeckMac
zsh scripts/build-app.sh
```

默认使用临时签名，自行使用无须付费开发者账号；重建后 macOS 可能再次请求钥匙串或局域网权限。首次启动输入自己的 Readeck 地址和 API Token。HTTP 会明文传输令牌，应只在可信网络中使用；HTTPS 使用系统证书校验。

功能与技术说明见 [客户端说明](ReadeckMac/README.md)，工作区归档和公开范围见 [仓库结构](docs/REPOSITORY.md)。

## 许可

本项目代码采用 [GNU Affero General Public License v3.0 only（AGPL-3.0-only）](LICENSE)。第三方组件与资源有各自的许可：SwiftSoup 许可证见 [SwiftSoup.txt](ReadeckMac/Sources/ReadeckMac/Resources/Licenses/SwiftSoup.txt)，微信页面类型适配参考的项目许可证见 [wechat-article-exporter.txt](ReadeckMac/Sources/ReadeckMac/Resources/Licenses/wechat-article-exporter.txt)，内置艺术封面来源及许可见 [封面来源](ReadeckMac/Sources/ReadeckMac/Resources/Artwork/CREDITS.md)。Readeck 服务端是独立的上游项目，遵循其自身许可证，本仓库不包含其源码。

Readeck Mac 是独立客户端项目，与 Readeck 上游项目不存在已声明的官方隶属或背书关系。
