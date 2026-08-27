# MacEase

MacEase（Mac + Ease）是一个面向 macOS 的非官方网易云音乐第三方客户端，使用 Swift、SwiftUI 和 Apple 原生框架开发。本项目独立于 NetEase, Inc. 与网易云音乐，未获其关联、授权或背书。

项目处于 pre-alpha 实现阶段，尚无公开二进制版本；仓库同时保留 Gate A 无账号读取
probe、Gate B 登录和 Gate C eapi 播放技术 harness。完整 Gate C、Gate E 与发行关卡仍为
Hold。当前离线实现与历史 live 观察见 [docs/status.md](docs/status.md)。

## 当前范围

- 仅支持 Apple Silicon（arm64）：不构建、不测试、不发布 Intel（x86_64）或 Universal
  版本，也不支持 Rosetta 场景。macOS 15 Sequoia 及以上。
- UI 严格遵循 macOS Sequoia 15 的系统视觉风格与 Apple/macOS 设计美学（SwiftUI 优先，
  必要时使用 AppKit），暂不引入 Liquid Glass 风格。
- 所有程序化网易 API 请求集中在 `NeteaseKit`；官方登录页和媒体传输分别由
  `WKWebView`、`AVPlayer` 直接完成。端点清单见
  [docs/endpoint-registry.md](docs/endpoint-registry.md)。
- 原生 Swift 实现 weapi/eapi；当前 Android-identity xeapi 路径 No-Go，整体 live xeapi 仍为 Hold。
- 每个按钮标注它发出的请求数。除首次验证后一次性的 Discover 预取外没有隐式请求：
  不自动重试、不后台轮询、不写后自动刷新。
- GitHub Releases + Developer ID + notarization + Sparkle 2；不进入 Mac App Store。

## 功能路线图

已确认的核心功能范围（详见 [docs/roadmap-features.md](docs/roadmap-features.md)，按批次实现）：

1. 登录与主页：WKWebView 官方登录页（内嵌扫码登录）、个人基本信息展示。
2. 基础播放：播放、音量调节、播放队列管理、定时播放（播完当前曲目再停）。
3. 播放模式：顺序、循环、随机、心动模式（仅从红心歌曲切入）。
4. 歌单与音乐库：我喜欢的音乐、听歌排行、收藏与创建的歌单、歌单编辑
  （创建/删除/改元信息/增删曲目/收藏）、红心与取消红心。
5. 推荐与发现：每日推荐、热歌榜、相似歌曲、推荐歌单；启动时一次性预取，
  之后仅由用户手动刷新，仍不自动重试、不后台轮询。

## 永久边界

- 不实现 scrobble（听歌打卡）、每日签到或后台自动账号行为。
- 不实现解灰、VIP/音质授权绕过、`.ncm` 解密、下载或离线音频。
- 不使用公共 API 实例、第三方音源、Node 网关或 bundled sidecar。
- 不实现反作弊 token、设备指纹或官方客户端冒充。
- 当前直接使用 AVPlayer 的短期 URL，不跨启动保存音频；未来若启用缓存，只能放在自动清理的进程临时目录。
- 不提供收费、捐赠、赞助或其他 monetization 渠道。

第三方客户端登录和私有接口可能触发账号风控。验证只使用专用测试账号，测试无异常也不代表绝对安全。

## 构建与验证

需要 macOS 15（arm64）、Xcode 16.4+ 与 Swift 6.1+。以下命令在干净 clone 中即可执行，
全部离线，不发任何网易请求：

```sh
cd Packages/MacEaseCore
swift build
swift test
swift test -c release
swift build -c release
```

仓库自检（相对链接与脚本路径是否已纳入版本控制、状态文档记录的测试数是否仍准确）：

```sh
./scripts/check_links.sh
./scripts/check_status.sh
```

测试的划分与必须保持的性质见 [docs/testing.md](docs/testing.md)；分层与不变量见
[docs/architecture.md](docs/architecture.md)。

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
./scripts/package_macease_app.sh --build 1
open -n .build/MacEase.app
```

Gate 台账、live 观察窗口原始记录与维护者交接笔记保存在本地工作区，不属于公开源码发布内容。

## 发布与许可

当前没有官方二进制版本。开始发布后，项目仓库的 GitHub Releases 是唯一官方发布渠道，签名校验方法会随首个版本公布。

代码采用 [MIT License](LICENSE)。第三方来源与许可状态见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
