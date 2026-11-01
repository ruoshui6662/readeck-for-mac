# Readeck Mac 客户端

SwiftUI 原生客户端，通过 Readeck API 访问自托管资料库。当前面向个人使用，仍在开发和验证中。

## 环境与运行

- macOS 26 或更高版本，Xcode 与 Swift 6.2。
- 一个可访问的 Readeck 服务及 API Token。
- 运行 `swift run ReadeckMac`，或用 `zsh scripts/build-app.sh` 构建本地应用；`swift test` 运行测试。
- 未配置开发签名时，构建脚本使用临时签名。重建后系统可能重新请求钥匙串和局域网授权。

## 功能与数据

支持收藏列表、分类与标签、阅读、阅读样式、划线与批注，以及本地待同步队列。Token 保存于 macOS 钥匙串；正文和部分任务数据缓存在本地。支持 HTTP 和 HTTPS；HTTP 明文传输令牌，应仅在可信网络中使用。支持站点与内容完整性取决于源站和服务端，微信等特殊站点需要额外验证；小红书一键采集目前暂缓。

分类通过 Readeck 标签表达，服务端显示 `分类/名称`。该约定不是服务端原生文件夹，其他客户端可以看到这些标签。

## 第三方资源

微信页面类型适配参考了 [wechat-article-exporter 的 renderer](https://github.com/wechat-article/wechat-article-exporter/blob/master/shared/utils/renderer.ts)；其原始 MIT 许可证和版权声明保留于 `Sources/ReadeckMac/Resources/Licenses/wechat-article-exporter.txt`。该项目不是运行时依赖。

项目依赖 [SwiftSoup](https://github.com/scinfu/SwiftSoup)，使用 MIT 许可证，原始许可文本在 `Sources/ReadeckMac/Resources/Licenses/SwiftSoup.txt`。内置备选封面采用芝加哥艺术博物馆开放资源，作品来源、许可信息和校验值见 `Sources/ReadeckMac/Resources/Artwork/`。本客户端代码采用 AGPL-3.0-only；Readeck 上游服务是独立项目，本仓库不包含服务端源码。

提交或分享日志前，请自行移除 Token、内网地址、个人文章、截图和其他私有数据。测试中的 `example.com`、示例令牌和局域网地址均为虚构数据。
