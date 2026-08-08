# MacEase

MacEase（Mac + Ease）是一个面向 macOS 的非官方网易云音乐第三方客户端，使用 Swift、SwiftUI 和 Apple 原生框架开发。本项目独立于 NetEase, Inc. 与网易云音乐，未获其关联、授权或背书。

项目当前处于可行性验证阶段，尚无产品 UI 或公开二进制版本；仓库包含协议测试、
Gate A 无账号读取 probe，以及 Gate B 登录与 Gate C eapi 播放技术 harness。当前
关卡和下一次执行顺序见 [docs/next-session.md](docs/next-session.md)，研究与架构依据见 [init.md](init.md)。

## 当前范围

- macOS 15+，当前发行目标为 Apple Silicon（arm64）；SwiftUI 优先，必要时使用 AppKit。
- 所有网易网络请求集中在 `NeteaseKit`。
- 原生 Swift 实现 weapi/eapi；当前 Android-identity xeapi 路径 No-Go，整体 live xeapi 仍为 Hold。
- 官方登录页 `WKWebView`、Keychain 会话、AVPlayer 播放。
- 固定源提交 `38da8da` 的 arm64 Debug/Release 测试各 33 项通过；eapi 已执行切片 Go，完整 eapi Gate C 仍 Hold。
- GitHub Releases + Developer ID + notarization + Sparkle 2；不进入 Mac App Store。

## 永久边界

- 不实现 scrobble（听歌打卡）、每日签到或后台自动账号行为。
- 不实现解灰、VIP/音质授权绕过、`.ncm` 解密、下载或离线音频。
- 不使用公共 API 实例、第三方音源、Node 网关或 bundled sidecar。
- 当前直接使用 AVPlayer 的短期 URL，不跨启动保存音频；未来若启用缓存，只能放在自动清理的进程临时目录。
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

运行 Gate B 登录与 Gate C eapi 播放 harness：

```sh
cd Packages/MacEaseCore
swift run GateBLoginHarness
```

运行 Gate A 无 Cookie、无重试歌词 probe：

```sh
cd Packages/MacEaseCore
swift run GateALyricsProbe
```

组装并运行 Phase 0 App Sandbox harness：

```sh
./scripts/package_phase0_harness.sh
open -n .build/MacEasePhase0Harness.app
```

当前验证文档：

- [Phase 0 baseline](docs/phase0/README.md)
- [Endpoint policy](docs/phase0/endpoint-policy.md)
- [Phase 0 validation](docs/phase0/validation.md)
- [Gate A protocol evidence](docs/gatea/README.md)
- [Gate B login harness](docs/gateb/README.md)
- [Gate C eapi playback evidence](docs/gatec/README.md)
- [Gate D release engineering](docs/gated/README.md)
- [Gate E account-risk observation](docs/gatee/README.md)
- [Next-session handoff](docs/next-session.md)

## 发布与许可

当前没有官方二进制版本。开始发布后，项目仓库的 GitHub Releases 是唯一官方发布渠道，签名校验方法会随首个版本公布。

代码采用 [MIT License](LICENSE)。第三方来源与许可状态见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
