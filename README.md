# MacEase

MacEase（Mac + Ease）是一个面向 macOS 的非官方网易云音乐第三方客户端，使用 Swift、SwiftUI 和 Apple 原生框架开发。本项目独立于 NetEase, Inc. 与网易云音乐，未获其关联、授权或背书。

项目当前处于可行性验证阶段，尚无产品 UI 或公开二进制版本。完整研究、架构和风险依据见 [init.md](init.md)。

## 当前范围

- macOS 15+，SwiftUI 优先，必要时使用 AppKit。
- 所有网易网络请求集中在 `NeteaseKit`。
- 原生 Swift 实现 weapi/eapi；仅为核心播放验证 xeapi。
- 官方登录页 `WKWebView`、Keychain 会话、AVPlayer 播放。
- GitHub Releases + Developer ID + notarization + Sparkle 2；不进入 Mac App Store。

## 永久边界

- 不实现 scrobble（听歌打卡）、每日签到或后台自动账号行为。
- 不实现解灰、VIP/音质授权绕过、`.ncm` 解密、下载或离线音频。
- 不使用公共 API 实例、第三方音源、Node 网关或 bundled sidecar。
- 音频只允许使用自动清理的进程级临时缓存，不跨启动保存。
- 不提供收费、捐赠、赞助或其他 monetization 渠道。

第三方客户端登录和私有接口可能触发账号风控。验证只使用专用测试账号，测试无异常也不代表绝对安全。

## 构建验证包

需要 Xcode 16.4+ 与 Swift 6.1+：

```sh
cd Packages/MacEaseCore
swift build
swift test
swift test -c release
```

当前 Phase 0 文档：

- [Endpoint policy](docs/phase0/endpoint-policy.md)
- [Clean-room rules](docs/phase0/clean-room.md)
- [Test matrix](docs/phase0/test-matrix.md)
- [Account-risk protocol](docs/phase0/account-risk.md)
- [Go / No-Go gates](docs/phase0/go-no-go.md)
- [Crypto vectors](docs/phase0/crypto-vectors.md)

## 发布与许可

当前没有官方二进制版本。开始发布后，项目仓库的 GitHub Releases 是唯一官方发布渠道，签名校验方法会随首个版本公布。

代码采用 [MIT License](LICENSE)。第三方来源与许可状态见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
