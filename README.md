# MacEase

MacEase（Mac + Ease）是一个面向 macOS 的非官方网易云音乐第三方客户端，使用 Swift、SwiftUI 和 Apple 原生框架开发。本项目独立于 NetEase, Inc. 与网易云音乐，未获其关联、授权或背书。

项目已完成可行性验证并进入最小 Phase 2 app foundation，尚无公开二进制版本；仓库
同时保留 Gate A 无账号读取 probe、Gate B 登录和 Gate C eapi 播放技术 harness。
完整 Gate C、Gate E 与发行关卡仍为 Hold；研究、边界和路线图依据见 [init.md](init.md)。

## 当前范围

- macOS 15+，当前发行目标为 Apple Silicon（arm64）；SwiftUI 优先，必要时使用 AppKit。
- 所有程序化网易 API 请求集中在 `NeteaseKit`；官方登录页和媒体传输分别由
  `WKWebView`、`AVPlayer` 直接完成。
- 原生 Swift 实现 weapi/eapi；当前 Android-identity xeapi 路径 No-Go，整体 live xeapi 仍为 Hold。
- 官方登录页 `WKWebView`、Keychain 会话、AVPlayer 播放。
- 最小 `MacEase.app` 已复用验证过的登录/会话实现，并加入只读、手动分页的我的歌单
  与歌单曲目详情；详情显式执行 `playlistDetail` + `songDetail`，每批最多 1000 首，后续
  批次只由用户点击触发，不自动请求、不重试。
- Gate E 固定源提交 `c2ea0e7` 的 arm64 Debug/Release 测试各 36 项通过；当前固定源码
  `efc0e71` 的 Debug/Release 测试各 50 项通过。完整 eapi Gate C 仍 Hold。
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

组装 Phase 0 验证包（Sandbox Gate B GUI 与签名 Gate C CLI）：

```sh
./scripts/package_phase0_harness.sh
open -n .build/MacEasePhase0Harness.app
.build/MacEasePhase0Harness.app/Contents/MacOS/GateCPlaybackProbe
```

组装当前最小 app（ad-hoc Hardened Runtime，仅用于本地开发验证）：

```sh
./scripts/package_macease_app.sh --arch arm64 --build 1
open -n .build/MacEase.app
```

Gate 台账与交接记录保存在本地工作区的 `docs/`，不属于公开源码发布内容。

## 发布与许可

当前没有官方二进制版本。开始发布后，项目仓库的 GitHub Releases 是唯一官方发布渠道，签名校验方法会随首个版本公布。

代码采用 [MIT License](LICENSE)。第三方来源与许可状态见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
