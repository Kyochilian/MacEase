# 架构

> 适用提交：`main`。本文件描述当前实际结构，不是计划。

MacEase 是单一本地 Swift package（`Packages/MacEaseCore`）加一个 app target，
不拆分为多个 package。

```text
Packages/MacEaseCore/
  Sources/
    NeteaseKit/            协议层：加密、请求构造、响应分类、凭据、Keychain
    MacEaseAppCore/        应用状态层：操作仲裁、会话状态机、协调器、播放
    MacEaseSession/        WebKit 登录页与会话持有者
    MacEase/               SwiftUI app target
    Gate*Probe / Gate*Harness/   一次性验证 harness，不属于 app
  Tests/
    NeteaseKitTests/       协议合同与不可信输入
    MacEaseAppCoreTests/   协调器、仲裁、会话迁移、分页、播放恢复
```

依赖方向严格单向：

```text
MacEase → MacEaseSession → MacEaseAppCore → NeteaseKit
MacEase → MacEaseAppCore
MacEase → NeteaseKit       （Package.swift 中的直接依赖）
```

`MacEaseAppCore` 不 import AppKit、WebKit 或 SwiftUI。它目前仍包含
`AVPlayerAudioOutput` 这一 AVFoundation 适配器；测试注入 fake，不启动真实播放器。

## 分层约束

- 所有程序化网易请求集中在 `NeteaseKit`。app 层通过 `NeteaseTransporting` 协议使用它，
  测试注入 fake，永不发真实请求。
- 协调器不构造 `URLSession` 或 `CredentialVault`。`MacEaseApp` 创建唯一一份
  transport、vault、arbiter 并注入所有模块；PlaybackController 默认使用一个
  `AVPlayerAudioOutput`，测试改注入 fake。
- View 只发送 intent 并渲染 state，不持有请求规则。
- `status` 字符串只用于显示。任何逻辑分支都不读取或比较它。

## 关键不变量

| 不变量 | 落点 |
|---|---|
| 写请求与破坏性会话迁移互斥；独立 read/播放解析可并发且有并发上限 | `OperationArbiter` |
| 已发出的写请求不会被静默取消；结果不明时进入 `outcomeUnknown` | `OperationArbiter` |
| 会话状态整体提交，临时失败不破坏已确认状态 | `SessionReducer` |
| 分页游标来自服务器返回，不来自可见数组长度 | `PlaylistCollection` |
| 写后本地状态要么完全一致，要么明确 stale 并停止分页 | `PlaylistCollection` / `PlaylistTrackCollection` |
| 可恢复播放失败始终保留显式重解析入口 | `PlaybackAttempt` |
| 请求前后各校验一次 Keychain 与已验证账号一致 | `SessionGuardedCoordinator` |
| 失败即停，无自动重试、无后台轮询、无预取（除启动一次 Discover 预取） | 各协调器 |
| 不可信输入（响应、Keychain、压缩体）只分类不终止进程 | `NeteaseCryptoError`、`NeteaseTransportError`、`CredentialVaultError` |

## 会话状态机

`SessionSnapshot.Presence` 只有四种取值：`unknown`、`absent`、`storedUnvalidated`、
`validated(account)`。当 Keychain 读取失败时，`.unknown` 也用于表达“是否仍存储
item 未知”，而不是猜测为存在。所有迁移经过 `SessionReducer.reduce(_:_:)`，返回
`SessionMutationResult`；app 层据此决定是否清空 session-scoped 数据：

| 结果 | 清空播放与已加载数据 |
|---|---|
| `unchangedValidated` | 否 |
| `rejected` | 否 |
| `credentialReplaced` | 是 |
| `signedOut` | 是 |
| `storedUnvalidated` | 是 |
| `storedPresenceUnknown` | 是 |

## 操作仲裁

`OperationEffect` 区分 `read`、`write`、`sessionMutation`、`playbackResolution`。
只有 `write` 与 `sessionMutation` 占用独占 slot；read 与播放解析按各 coordinator 的
loading/intent 状态管理，并受 `OperationArbiter` 的读并发上限约束
（`defaultMaximumConcurrentReads`），超出上限的读被拒绝而不是排队，因此单次用户操作
不会扩大为不受控的请求突发。read 端非空时 `write`/`sessionMutation` 无法开始；
`promote(_:name:)` 让唯一的活跃 read 原子升级为 session mutation，中间不留出让
其它操作插入的空隙。本地 pause / seek / volume / mute 不占用仲裁。写请求一旦标记
`requestSent`，放弃它不会报告成功或失败，而是记录一条 `UnresolvedOutcome`，由用户
显式确认后清除。仲裁不提供自动核对请求。
