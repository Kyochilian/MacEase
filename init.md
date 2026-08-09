# MacEase 初始探索与开发可行性基线

> 状态：设计阶段结论汇总；开发可行性复核完成
> 创建日期：2026-08-04
> 最近复核：2026-08-09
> 本文档记录调研结论、已确认决策、实现边界、技术架构、验证关卡、路线图与风险登记册。
> **调研结论具有时效性**：网易云的接口、协议与风控策略可能随时变化。涉及私有接口的结论在实现前必须按本文的证据规则重新验证。

> 当前实现状态和下一次执行顺序保存在本地 `docs/next-session.md`；本文保留设计依据，
> 不重复维护每次 live probe 的明细。

---

## 零、证据规则与阅读方式

本文把证据分为四级：

| 等级 | 含义 | 例子 |
|---|---|---|
| A | 官方文档、SDK 头文件或可重复的本机实验 | Apple SDK availability、SecKey golden vector |
| B | 当前版本的一手源码或带日期的实际响应 | `api-enhanced` 当前主线、MusicBox 当前源码 |
| C | 多个独立社区报告形成的强信号 | scrobble 后账号处罚报告 |
| D | 推断、市场解释或尚未复现实验 | star 对需求的含义、未来协议迁移时间 |

写作规则：

- A/B 级事实可以作为实现依据，但私有服务行为仍要标注最后验证日期。
- C 级证据用于风险规避，不能写成严格因果证明。
- D 级内容只能作为假设，不能进入不可逆架构决策。
- Cookie 寿命、错误码、URL 有效期、音质返回和协议默认值都视为**当前观察**，不是稳定契约。
- 第二节中的确认决策仍然有效；本次复核只修正过度确定的理由、补足实现路径与验证关卡。

本次复核环境：macOS 15.5、Xcode 16.4、Swift 6.1.2、macOS 15.5 SDK。涉及 macOS 26+ 的 API 与兼容性仍需用对应 Xcode/SDK 重新验证。

---

## 一、调研结论摘要

### 1.0 目标用户与核心任务

MacEase 的首要用户是重视 macOS 原生交互、系统媒体控制和稳定播放的网易云用户，以及重视逐行/逐词歌词体验的用户。需要混合本地音乐的用户属于次要范围，只支持用户主动选择并合法持有的文件，不把本地库扩展成自动抓取、下载或解灰路径。

v1 围绕五个核心任务收敛：

1. 通过官方网页完成可清除、可诊断的登录与会话恢复。
2. 读取用户歌单、搜索内容，并清楚区分未登录、无权限、灰色和服务异常。
3. 可靠播放账号有权访问的曲目，处理 URL 过期、seek、切歌、网络和系统生命周期变化。
4. 提供可降级、可访问且性能可控的歌词体验。
5. 让 UI、播放队列、Now Playing、Remote Command 和本地持久状态保持一致。

成功不依赖复刻官方客户端的全部内容页；任何不能直接提升上述任务、却会增加私有 endpoint、账号副作用或长期维护面的功能默认后置。

### 1.1 产品机会：缺少成熟可信的原生方案，而不是“从来没人做过”

原生项目并非不存在：

- `xjbeta/NeteaseMusic-macOS` 是 AppKit + Swift 的历史项目。
- `zeyugao/MusicBox` 是仍有近期提交的 SwiftUI + AVPlayer 客户端，包含登录、缓存、歌词与 Sparkle。
- `QinSwiftUI` 是早期 SwiftUI 尝试。
- MeloX、LyricsX 等项目分别验证了 Apple 平台音乐体验和歌词产品的表现空间。

更准确的机会描述是：

> 截至 2026-08，尚未形成一个持续维护、签名公证、播放链路成熟、系统整合完整并获得广泛采用的原生 macOS 网易云客户端。

缺口不在“没人写过”，而在于很少有项目同时处理好私有协议、账号会话、音频边界、原生体验、发布工程与长期维护。

MeloX 的关注增长只能证明高质感原生歌词界面具有传播力，不能证明日活、账号风险接受度、macOS 用户规模或长期留存。MacEase 的产品假设需要通过 dogfood 和受控 beta 验证，不能用 GitHub star 代替。

### 1.2 主流 GUI 竞品多为 Electron，但原生实现并不免测试

YesPlayMusic、AlgerMusicPlayer、lx-music-desktop、VutronMusic 等 GUI 项目以 Web/Electron 技术为主；go-musicfox 则是 Go TUI。社区 issue 显示，部分项目长期受到 Gatekeeper、Apple Silicon 打包、白屏、快捷键与系统整合问题影响。

原生实现的真实优势是：

- 减少 Chromium、Node、桥接和跨平台打包层级。
- 直接使用 SwiftUI、AppKit、MediaPlayer、CoreAudio、WebKit 和系统生命周期 API。
- 更容易提供符合 macOS 习惯的菜单、快捷键、窗口与辅助功能。

但原生应用仍会受到 SwiftUI 回归、AppKit 焦点与窗口行为、WebKit Cookie 变化、CoreAudio 设备切换、签名公证、Sparkle、Intel/Apple Silicon 和新系统行为变化影响。发布前必须建立系统、架构、显示器与音频设备测试矩阵。

### 1.3 账号风控：scrobble 是不可接受风险，但不是已证明的唯一根因

2024 年以来，多个第三方客户端用户报告账号警告或临时冻结。YesPlayMusic issue #2383 等社区材料对网易侧听歌打卡接口与账号处罚形成了高可信度关联；移除调用后未再触发的报告是强烈工程信号，但不是受控实验。

因此本项目采用结果导向的边界：

| 行为 | 结论 |
|---|---|
| 网易侧听歌打卡 / 播放记录上报 | 永久不实现 |
| 每日签到、后台自动任务 | 永久不实现 |
| 自动刷歌、挂机、频率压力测试 | 永久禁止 |
| 纯读取、搜索、播放 | 风险较低，但不能宣称绝对安全 |
| 用户明确触发的收藏等写操作 | v1 默认不做，单独评估后才能加入 |

不提供隐藏开关或“默认关闭”的实现。收益很低而账号后果很高时，删除能力比增加配置更可靠。

### 1.4 登录：WKWebView 是首选候选，不是稳定公开契约

截至 2026-08，手机号密码、短信和自实现扫码都存在验证码、环境异常或频率限制问题。`https://music.163.com/login` 当前可访问，MusicBox 也在使用 WKWebView + `WKHTTPCookieStore`，但这仍不是网易承诺的第三方登录接口。

首选方案保持不变：

1. `WKWebView` 加载官方登录页。
2. 通过 `WKHTTPCookieStore` 读取 HttpOnly 在内的允许 Cookie。
3. 将必要凭证写入 Keychain。
4. 手动 Cookie 导入只作为高级用户保底。

新增约束：

- 登录 WebView 优先使用 `WKWebsiteDataStore.nonPersistent()`；Apple SDK 明确说明该模式不向文件系统写入网站数据。
- WebKit 对象由 `@MainActor LoginCoordinator` 管理，不能直接塞进普通 actor。
- 登录页域名和跳转必须白名单化，外部链接交给默认浏览器，拒绝未知 scheme，不注入任意 JavaScript bridge。
- Cookie 名称、刷新时间和组合视为不透明服务端状态；不再写死“某 Cookie 固定多久刷新”。
- 必须提供完整退出：删除 Keychain、当前登录 WebView 数据和账号缓存。
- “游客模式”不是 v1 硬要求。只有公开读取接口无需伪造设备身份且实测稳定时才加入；否则保留清晰的未登录/本地模式即可。

### 1.5 API 与协议：xeapi 已进入核心播放路径，既不是“必然全面迁移”，也不再只是远期监控项

weapi/eapi 仍有大量接口实现，但 2026-08-05 的 `api-enhanced` 主线中，`module/song_url_v1.js` 已默认选择 `xeapi`，调用者仍可显式覆盖 crypto mode。这意味着：

- 不能断言所有接口一定会迁移 xeapi。
- 也不能继续把 xeapi 仅列为未来风险；核心播放端点已经需要验证。
- P0 必须分别测试 `song_url_v1` 的 eapi 与 xeapi 路径，记录账号、音质和稳定性差异。

当前 xeapi 一手源码显示其不仅是几项 CryptoKit 原语，还包含：

- 动态公钥获取和版本/`sk` 生命周期。
- X25519 ECDH 与 HKDF-SHA256 风格派生。
- AES-128-GCM 密钥信封。
- 静态与动态 AES-ECB 双层加密、中间混淆变换。
- 会话响应头复用、gzip 响应处理。
- Android UA、app version、device id 等设备语义。

原生 Swift 在密码学原语层面可行：CryptoKit 覆盖 X25519、HMAC/HKDF 和 AES-GCM；CommonCrypto 覆盖 AES-CBC/ECB；Security 覆盖 raw RSA；gzip 可走 zlib。但真正风险在公钥/会话生命周期、请求字节精确性和设备身份策略，而不是“Swift 能不能算 AES”。

如果核心播放只能依赖伪造且不稳定的 Android 反爬身份、受保护 token 或进一步逆向加固 SDK，视为公开发布的 Go/No-Go 关卡，不默认硬闯。

### 1.6 weapi raw RSA 已验证不需要自写大整数

Apple Security 框架公开提供 `SecKeyAlgorithm.rsaEncryptionRaw`。本次复核用网易现有 1024-bit 公钥和固定 16 字节输入做了本机实验：

- `SecKeyCreateWithData` 可直接导入现有 SPKI 公钥。
- `SecKeyCreateEncryptedData(..., .rsaEncryptionRaw, ...)` 返回固定 128 字节结果。
- 输出与 Node `RSA_NO_PADDING` 对同一左侧零填充输入的结果完全一致。

因此 weapi 实现顺序改为：

1. 固定 golden vectors。
2. 使用 `SecKeyAlgorithm.rsaEncryptionRaw`。
3. 验证字节序、明文倒序、左填充与固定长度 hex。
4. 只有官方框架在目标系统上出现不可兼容行为时才暂停并重新评估；任何非 Swift 密码库都需要显式重开已确认的架构决策。
5. 不自写 BigUInt，也不因单个 POC 失败自动切换 FFI 或 sidecar。

### 1.7 播放可行，但自定义缓存是独立子项目

AVPlayer 足以承担 v0.1 的基础播放。`AVAssetResourceLoader` 的官方接口明确要求实现者面对：

- 多个并发 loading request。
- requested offset/length 与随机访问。
- cancellation、redirect、content information。
- byte range 支持与内容长度。
- 资源 renewal/过期。

MusicBox 当前实现虽然能边下边播，但本质上从头顺序下载完整文件，只能读取已经缓存的区间，并把完整文件保留在用户 Caches 目录；这不能直接复制到 MacEase，也不满足本项目的临时音频约束。

因此采用分期策略：

- v0.1 先直接使用 AVPlayer 播放短期 URL，建立 URL 重新解析和进度恢复状态机。
- 播放状态稳定后再实现支持 Range 的临时分块缓存。
- 音频只允许写入进程级临时目录，启动、退出、超限和过期都主动清理；不得落到 `~/Library/Caches`、Music 或 Documents。
- 如果直接播放 + URL 恢复已经达到可靠性目标，自定义缓存仍需用数据证明收益后再扩大实现，而不是为“架构完整”而过早增加复杂度。

### 1.8 法律、许可与分发：风险被降低，但不能判定为“极低”

不解灰、不下载、不破解、不自动写账号行为显著降低了风险；但私有 API、Cookie 提取、服务替代、商标、服务条款和临时音频缓存仍有实质不确定性。公开 DMCA 或诉讼记录不能覆盖私人律师函、商店投诉、证书投诉与未公开处理。

Homebrew 5.0.0 宣布、6.0.0 再次确认将在 2026-09 禁用无法通过 Gatekeeper 检查的 cask，但这只是安装体验环境变化，不是确定性市场窗口。Homebrew 当前政策还要求：

- 最新 macOS 可用且声明的架构都能工作。
- 有独立于 Homebrew 的公开存在和持续维护。
- 通常达到 30 forks / 30 watchers / 75 stars；仓库所有者自荐通常是三倍门槛。
- 满足指标不保证收录，Homebrew 可因实质法律、基础设施、安全或持续性风险拒绝或移除。

GitHub Releases 是主分发渠道；Homebrew 只作为后续附加渠道，不进入项目 Go/No-Go 判断。

MIT 许可证允许商业使用。MacEase 保持 MIT，但 README 不再写“禁止商用”或“仅供学习研究即可免责”。项目自身不收费、不捐赠、不赞助；对第三方商业 fork 的约束只能通过商标、签名和“官方发布渠道”政策处理，不能覆盖 MIT 权利。

### 1.9 总体结论：Conditional Go

项目具备完成内部可用版本的技术条件，公开版本的主要阻塞不在 SwiftUI，而在：

1. 官方 Web 登录与会话能否长期恢复。
2. 核心播放端点的 eapi/xeapi 可行性与账号风险。
3. AVPlayer URL 过期、seek、网络切换和设备变化的恢复质量。
4. 签名、公证、Sparkle 与 App Sandbox 的组合选择。
5. 单人维护是否能坚持严格 endpoint 和功能边界。

6–8 周仍是合理的内部 alpha 目标；公开 v1 只在完成受控 beta 和发布关卡后决定。若协议没有突发变化，单人从正式编码到公开 v1 的规划量级约为 12–20 周，但这只是排期包络，不是承诺或事实证明。

---

## 二、已确认的决策

| # | 决策项 | 结论 | 复核后的理由 |
|---|---|---|---|
| 1 | 项目形态 | **公开开源产品** | GitHub Releases + Developer ID + notarization + Sparkle 2。Homebrew 是可选渠道，不是立项依据。 |
| 2 | 产品边界 | **纯网易云客户端**，不做多源 provider | 保持产品聚焦，避免插件、音源与法律面爆炸；所有网易 API 调用集中在 `NeteaseKit`。 |
| 3 | API 接入 | **Swift 原生直连** | 原生实现 weapi/eapi；对确有需要的 endpoint 原生实现 xeapi。无 Node gateway、无 bundled sidecar。 |
| 4 | 登录方式 | **WKWebView 官方登录页 + Keychain；手动 Cookie 兜底** | 当前最合理候选，但按非公开能力设计：隔离、可诊断、可完全清除。 |
| 5 | 风控姿态 | **不实现网易 scrobble 与每日签到** | 社区证据足以形成不可接受风险；不需要证明“必封”才删除非核心高风险能力。 |
| 6 | 灰色歌曲 | **不解灰；本地文件显式关联回退** | 不引入第三方音源、下载或授权绕过；本地文件必须由用户合法持有并主动选择。 |
| 7 | 开发节奏 | **6–8 周内部 alpha，不承诺公开日期** | 先验证协议、登录、播放、账号和发布工程，再进入受控 beta。 |
| 8 | 最低系统 | **macOS 15 Sequoia+** | `TextRenderer` 与 `sizeThatFits` 在 macOS 15 SDK 可用；仍需用目标硬件做性能验证。 |
| 9 | UI 框架 | **SwiftUI 为主 + AppKit 逃生舱** | 原生 API 降低桥接成本，但复杂列表、窗口、菜单和焦点问题保留 AppKit 路径。 |
| 10 | 播放与缓存 | **AVPlayer；先直连恢复，后临时分块缓存** | v0.1 先稳定状态机。最终缓存仅在临时目录、受容量和生命周期约束，不形成离线音频。 |
| 11 | 数据层 | **GRDB** | 需要显式 schema、迁移、事务、批量写入和 FTS；删除无可复现工程支撑的精确 benchmark 数字。 |
| 12 | 差异化重点 | **逐字歌词 + 可靠播放 + 深度系统整合** | 歌词负责第一印象，可靠播放决定留存，系统整合体现原生价值。 |
| 13 | 开源许可 | **MIT** | 接受商业 fork；另行制定商标和官方构建政策。不得再用 README “禁止商用”覆盖许可证。 |
| 14 | 运营方式 | **透明、专业、无 monetization** | GitHub Discussions/Issues 为主要社区；设置联系与安全邮箱、隐私政策和下架请求流程；不开捐赠、赞助或收费。 |
| 15 | 项目名 | **MacEase 已确认** | README 必须解释为 “Mac + Ease”，声明与 NetEase, Inc. 无关联；图标避免网易品牌元素，并做基础商标检索。 |

### v1 明确非目标

- 网易 scrobble、每日签到和任何后台自动账号行为。
- 解灰、VIP 解锁、`.ncm` 解密、下载或离线保存。
- 任意插件、自定义 API server、多服务 provider。
- 评论、MV、播客/电台、云盘上传。
- EQ、交叉淡化、gapless 承诺、bit-perfect、独占 DAC、空间音频宣传。
- MCP server、Shortcuts、AppleScript、iOS、watchOS。
- 音频指纹与全自动本地文件匹配。
- 任何 Last.fm/ListenBrainz 等 scrobble 集成；当前项目边界统一不做播放上报。

### 已确认推迟

- **菜单栏歌词 + mini player**：v1.1 第一顺位，不提前塞进 v1.0。
- **桌面歌词**：v1.1 之后；涉及多显示器、窗口层级、Space、锁定和辅助功能。
- **Shortcuts / AppleScript / MCP**：稳定公开版本之后再单独评估。

---

## 三、技术架构基线

### 3.1 模块边界：一个本地 SPM package，少量 targets

原草案的职责边界合理，但不应一开始建立大量独立 package。初始结构采用一个本地 Swift package 承载核心 targets：

```text
MacEase.app
├── AppCore                         生命周期、依赖组装、路由、全局错误
├── Features/*                      Library / Search / Player / Lyrics / Settings
├── SystemIntegration               Now Playing / Remote Commands / CoreAudio / Sleep
├── DesignSystem                    初期仅为 app 内目录
└── Packages/MacEaseCore            单一 Package.swift
    ├── CoreDomain                  Track / Album / Artist / Playlist / Session value types
    ├── NeteaseKit                  Crypto / Transport / Endpoint / Credential / DTO mapping
    ├── PlaybackKit                 AssetResolver / recovery policy / temp cache
    ├── PersistenceKit              GRDB schema / migration / repositories
    └── LyricsKit                   Parser / timeline / synchronization / renderer model
```

边界规则：

- 所有程序化网易 API 请求只能由 `NeteaseKit` 发出；官方登录页和媒体传输分别由
  `WKWebView`、`AVPlayer` 直接完成。
- WKWebView 登录实现位于最小 `MacEaseSession` target，由真实 app 与 Gate B harness
  共同复用；UI 仍留在各 executable target，它只把结构化凭证交给 `NeteaseKit`。
- AVPlayer 留在 app 侧 `@MainActor PlaybackController`；`PlaybackKit` 提供可测试的解析、恢复和缓存逻辑。
- `SystemIntegration` 初期留在 app target，避免为少量生命周期代码过早增加 package。
- 只有出现第二个 app target 或明确复用需求时，才拆独立 DesignSystem/SystemIntegration package。

### 3.2 Endpoint 目录与风险白名单

每个允许的接口都必须记录下列合同字段。它们是审查清单，不要求为了少量 endpoint
建立通用运行时 descriptor、repository 或 provider 框架；固定常量和专用请求函数即可：

```swift
struct EndpointDescriptor<Response: Decodable & Sendable>: Sendable {
    let path: String
    let method: HTTPMethod
    let cryptoMode: CryptoMode
    let authentication: AuthenticationRequirement
    let effect: EndpointEffect
    let retryPolicy: RetryPolicy
    let responseEncoding: ResponseEncoding
}

enum EndpointEffect: Sendable {
    case publicRead
    case authenticatedRead
    case explicitUserMutation
}
```

规则：

- shipping target 只编译允许接口；scrobble、签到、解灰、下载绕过等 endpoint **根本不定义**，而不是定义成 `.prohibited` 后运行时拒绝。
- 每个 endpoint 显式选择 weapi/eapi/xeapi，禁止 HTTP client 隐式猜测。
- v0.1 不做自动重试；失败后只允许用户显式重试。
- 新增 endpoint 的 PR 必须说明用户价值、账号副作用、认证要求、最后验证日期和测试账号结果。
- v0.1 endpoint 集合保持最小：登录状态、用户歌单读取、歌单详情、搜索、歌曲 URL、歌词；专辑/艺人详情按 UI 需要再加。
- 每日推荐、私人 FM 和收藏写操作不进入 v0.1。

### 3.3 加密与协议实现

#### weapi

```text
params    = Base64(AES-CBC(Base64(AES-CBC(JSON, presetKey, iv)), secretKey, iv))
encSecKey = HEX_FIXED_WIDTH(RSA_RAW(reverse(secretKey)))
```

- AES-CBC 使用 CommonCrypto。
- raw RSA 使用 Security `.rsaEncryptionRaw`；已用本机 golden vector 与 Node 结果对齐。
- secret key 可先固定用于 deterministic tests，生产是否随机由抓包兼容性验证决定。
- 不引入自写大整数。

#### eapi

```text
digest = MD5("nobody" + path + "use" + JSON + "md5forencrypt")
text   = path + "-36cd479b6b5-" + JSON + "-36cd479b6b5-" + digest
params = HEX_UPPER(AES-128-ECB(PKCS7(text), key="e82ckenh8dichen8"))
```

- AES-ECB 与 MD5 通过 CommonCrypto 实现。
- gzip/加密响应按 endpoint descriptor 声明，不用全局猜测。
- 参数 JSON 的键顺序、编码和路径必须纳入 golden vectors。

#### xeapi

P0 只实现核心播放所需最小集合：

- 公钥状态获取与 HMAC 完整性校验。
- B/S/R 构建。
- X25519、派生、AES-GCM、AES-ECB、中间变换。
- session header 保存和失效。
- 响应 AES 解密与 gzip。

禁止直接复制 AI 逆向文字作为实现。以当前可运行源码、抓包和跨语言 golden vectors 为准。需要特别验证：

- key-get endpoint 的真实包装方式。
- deviceId、UA、app version 与登录 Cookie 的一致性。
- session key 是 ASCII 字节还是 hex 解码值。
- JSON 字段插入顺序和 URL encoding。
- eapi fallback 是否仍能获取合法播放 URL。

#### 回退顺序

1. Apple Security/CryptoKit/CommonCrypto/zlib。
2. 修正协议理解与 golden vectors。
3. 若 Apple 框架确实缺少必要原语，停止该路径并提交明确的架构决策记录；weapi/eapi 的协议、序列化和编排仍保持 Swift 原生。
4. 静态 FFI、XPC 或独立 sidecar 都不在当前计划内，不得作为失败后的自动回退。

### 3.4 登录、Cookie 与凭证

并发与生命周期拆分：

```text
@MainActor LoginCoordinator
    └── WKWebView / WKWebsiteDataStore / WKHTTPCookieStore

CredentialVault actor
    └── Keychain CRUD / account namespace / redacted snapshot

NeteaseSession actor
    └── immutable credential snapshot / request serialization / auth state
```

会话威胁模型：

| 威胁 | 主要控制 |
|---|---|
| 登录页跳转到非预期来源或调用未知 scheme | 导航域名/scheme 白名单；外部链接交给默认浏览器；不暴露任意 JS bridge |
| Cookie 泄露到普通存储、日志、诊断或 crash 上下文 | Keychain 白名单存储；集中脱敏；针对日志和诊断包做回归测试 |
| 向无关 endpoint 或 host 发送过量 Cookie | descriptor 声明认证需求；按 endpoint 构造最小 header；host 白名单 |
| 多账号数据、Cookie 或缓存串号 | Keychain account namespace、数据库逻辑命名空间、切换账号时清空内存 snapshot |
| 过期凭证被重复请求并触发风控 | 零自动重试、条件删除匹配凭证、明确转入重新登录状态 |
| 登出后仍残留可恢复会话 | 删除 Keychain、WebKit 数据、账号缓存与内存状态，并用登录状态 endpoint 验证 |

约束：

- Keychain 使用本机限定的访问属性，默认不经 iCloud 同步。
- Cookie 以结构化白名单存储；不把完整 Cookie header 放进 UserDefaults、GRDB 或日志。
- 手动导入使用 secure field，不回显完整值，按第一个 `=` 分割 name/value，避免破坏 token 中的特殊字符。
- 导入后立即调用登录状态验证；失败不持久化。
- 运行时只发送 endpoint 所需的最小 Cookie/header，不从参考项目复制整套随机设备字段。
- 优先沿用官方 Web 登录产生的身份语义；若 xeapi 需要 Android 身份，必须单独记录和评估，不能与 Web 会话静默混用。
- 登录失败必须分为：页面加载、Cookie 缺失、会话无效、接口风控、网络和服务响应异常。

### 3.5 播放状态、URL 恢复与缓存

Xcode 16.4 SDK 将 `AVPlayer` 标为 UI actor，因此播放器本体不放进普通 actor：

```text
@MainActor PlaybackController
├── AVPlayer / AVPlayerItem
├── observable UI snapshot
├── periodic time observer
├── queue commands
└── Now Playing event emission

PlaybackAssetResolver actor
├── track ID -> short-lived asset
├── actual quality / format / trial range
└── explicit URL refresh and failure classification

PlaybackRecoveryPolicy (pure Sendable reducer)
└── resolving / preparing / playing / paused / stalled / recovering / failed

AudioTempCache actor (后期)
└── range map / temp files / limits / purge
```

`ResolvedAsset` 至少包含：

- track ID，而不是把 CDN URL 当长期身份。
- URL、观察到的过期时间和允许 host。
- 实际音质、容器/codec、文件大小。
- 试听区间。
- 重新解析所需账号上下文。

恢复流程：

1. 捕获资源不可达、403/404、stalled 或过期信号。
2. 保存用户期望状态与当前位置。
3. 用 track ID 重新解析 URL。
4. 重建 AVPlayerItem。
5. seek 到原位置。
6. 只有用户仍希望播放时才恢复。
7. 限制恢复次数和时间窗口，避免无限循环。

缓存分期：

- Alpha：直接 URL + AVFoundation 网络缓冲，不写自定义音频缓存。
- Beta：实现 `AVAssetResourceLoader` POC，必须通过 Range、并发 request、取消、redirect、renewal、seek 和 URL 重取测试。
- Public v1：若 POC 明确提升可靠性，再启用 bounded temp cache；否则保留直接播放恢复并继续验证。
- 缓存路径使用 `FileManager.default.temporaryDirectory/MacEase/Audio/<launch-id>`；启动、退出、容量超限、年龄超限都清理。
- 不在用户 Library Caches、Music、Documents 留下完整或部分音频，不提供导出。

音质策略：

- 只展示服务端实际返回的音质和格式。
- v1 优先验证 standard/higher/exhigh/lossless/hires 中实际可解码的结果。
- 不承诺 `jymaster`、`sky`、`dolby`，不宣传 Spatial Audio、bit-perfect 或无损直通。
- 外接 DAC、采样率自动切换、独占设备不在 v1 范围。

ATS：

- P0 记录实际音频和封面 host、HTTP/HTTPS 与 redirect 链。
- 只为确实需要的网易域名配置最小 `NSExceptionDomains`；禁止 `NSAllowsArbitraryLoads`。
- 若返回未知第三方 host，默认拒绝并记录脱敏诊断。

### 3.6 歌词模型、同步与渲染

统一不可变时间轴：

```text
LyricDocument
├── metadata
├── lines[]
│   ├── start / end
│   ├── role
│   ├── text / translation / romanization
│   └── tokens[] { text, start, duration }
└── userOffset
```

实现原则：

- YRC、LRC、翻译和罗马音先映射到统一模型，再进入 UI。
- 使用 AVPlayer periodic time observer 或统一播放时钟，不用高频 SwiftUI `Timer` 轮询。
- `TextRenderer`、`sizeThatFits`、RunSlice 与 `disablesSubpixelQuantization` 已在 macOS 15 SDK 确认可用。
- 逐字符能力不等于每个字符都叠加昂贵 blur/glow；只对可见行和必要 token 做复杂效果。
- 无逐词数据回退逐行；无歌词提供稳定空状态。
- 支持歌词 offset、点击行跳转、Reduce Motion、Reduce Transparency、Increase Contrast 和 VoiceOver 纯文本路径。
- 在 60Hz/120Hz、集显/不同 Apple Silicon 档位上用 Instruments 建立性能基线。

### 3.7 系统集成是独立子系统

| 能力 | 实现与边界 |
|---|---|
| Now Playing | `MPNowPlayingInfoCenter`；曲目、播放/暂停、seek、rate、repeat/shuffle、artwork 完成时更新 |
| 媒体键/耳机线控 | `MPRemoteCommandCenter`；按真实能力启用命令并返回准确状态 |
| 输出设备变化 | macOS 上 `AVAudioSession` 不可用；使用 CoreAudio default output/device alive/jack 等 property listener |
| 休眠/唤醒 | `NSWorkspace` 通知；休眠前暂停，唤醒后保持暂停并重新验证 URL |
| Dock 菜单 | `applicationDockMenu(_:)` |
| 全局快捷键 | 受控依赖或 Carbon/AppKit 封装；处理冲突和用户重设 |
| 防休眠 | 默认不阻止系统睡眠；除非出现明确且经验证的用户需求 |

输出设备策略不能只写“蓝牙断开就暂停”：

- 明确物理耳机断开可暂停。
- HDMI、显示器或扩展坞切换默认不立即暂停。
- 蓝牙短暂重连需要防抖。
- 不在设备重连后自动播放。
- 所有策略可关闭，并在真机矩阵验证。

### 3.8 数据层与 Swift 并发

GRDB 负责：

- 服务器实体缓存与失效时间。
- 每账号关联数据和逻辑命名空间。
- 本地播放队列。
- 本地文件 bookmark/关联。
- 用户设置与非敏感诊断索引。

删除“5 万行 0.8s vs 19s”等无法复现的数字。实现前建立项目自己的 benchmark：相同模型、事务方式、硬件、构建配置和多次运行结果。

并发规则：

- UI model、LoginCoordinator、PlaybackController：`@MainActor @Observable`。
- 网络 session、CredentialVault、AssetResolver、AudioTempCache：actor 或明确串行 executor。
- GRDB 使用其 DatabaseQueue/DatabasePool 隔离，不再额外包装成可变全局单例。
- DTO 解码与映射离开主线程；图片与歌词处理使用有界并发。
- 环境注入的是协议和生命周期受控实例，不是任意位置可写的 singleton。
- 不引入 TCA；理由是项目规模和单人维护成本，而不是引用无法复现的构建时间对比。
- 万行列表先用稳定 identity 和增量更新实测；若 SwiftUI Table/List 不达标，再把 `TrackListView` 内部替换为 NSTableView，不预先断言一定失败。

### 3.9 发布、安全与供应链

#### App Sandbox

Developer ID 分发不强制 App Sandbox，但它会影响本地文件、Sparkle helper、全局快捷键和 CoreAudio 验证。P0 必须做最小 sandboxed build：

- WKWebView 登录和网络。
- Keychain。
- AVPlayer。
- CoreAudio 只读设备监听。
- 用户选择本地文件 + security-scoped bookmark。

若全部通过，优先启用 App Sandbox；若不启用，必须在文档中记录具体阻塞和额外安全措施，不能仅因配置麻烦而跳过。
Sparkle 2 sandbox/XPC、更新签名与安装升级链路属于 Gate D1 发布验证，不以本地
ad-hoc P0 构建替代。

#### 更新与签名

- Developer ID 签名、Hardened Runtime、notarization、stapling。
- Sparkle 2 使用 HTTPS appcast + EdDSA 更新签名。
- 更新私钥离线保存；CI 只接触最小必要凭证。
- Sparkle 支持 sandbox，但需要正确的 XPC/helper/entitlement 配置，属于发布关卡而非最后一天接入项。
- 干净机器验证首次安装、升级、回滚/撤回策略、arm64/x86_64 声明与签名。
- 不以“专用账号避免 App Store 拒审”为安全策略；采用正常的证书、角色、CI secret 和续期治理。

#### 日志与凭证

日志和诊断包默认禁止包含：

- Cookie、Authorization、完整请求体、登录 URL 参数。
- 完整 CDN URL、用户 ID 组合、本地文件绝对路径。
- device token、Sparkle 私钥或测试账号信息。

诊断导出前二次脱敏，并向用户说明包含字段。Issue 模板明确提醒不要上传 Cookie。

#### 第三方代码边界

| 项目 | 当前许可观察 | 使用方式 |
|---|---|---|
| api-enhanced | MIT | endpoint/协议对照和 golden vectors；不整体嵌入 server、解灰、签到、IP 功能 |
| NeteaseCloudMusicAPI-Swift | README 标注 MIT，但仓库未附许可证正文 | 只做行为与输出对照；在上游补全或澄清前不复制代码 |
| MusicBox | 未发现项目级许可证；部分文件引用仓库中不存在的 `LICENSE` folder | 研究行为和踩坑，不复制缓存/API 实现 |
| MeloX / go-musicfox / HyPlayer | GPL-3.0 | 研究产品行为，独立实现 |
| AMLL | AGPL-3.0 | 研究视觉与数据模型，独立实现 |
| LyricsX | MPL-2.0 | 行为参考；若复用代码需逐文件履行义务，v1 默认不复制 |

仓库至少维护 `THIRD_PARTY_NOTICES`、依赖锁定/更新流程和关键代码来源记录。SBOM 可在公开 beta 前生成，不作为 alpha 阻塞。

---

## 四、路线图与验证关卡

### Phase 0 — 证据与边界（2–3 天）

输出物：

- v0.1 endpoint 白名单与永久禁止清单。
- 第三方许可矩阵和 clean-room 规则。
- 支持的系统、架构、显示器和音频设备矩阵。
- 账号风险测试约束。
- v1 非目标和 Go/No-Go 条件。
- App Sandbox 验证清单。

此阶段不做产品 UI，只允许最小测试 harness。

### Phase 1 — 技术探索（2–3 周）

#### Gate A：协议与加密

- weapi/eapi/xeapi 固定 golden vectors。
- Security raw RSA 单元测试保留本次已验证结果。
- CommonCrypto AES-CBC/ECB、MD5。
- CryptoKit X25519/HMAC/AES-GCM。
- zlib gzip。
- 选择最小公开读取 endpoint 进行 live 验证。

通过标准：离线向量跨 Swift/Node 完全一致；任何协议差异都能定位到序列化、加密或传输层。

#### Gate B：登录与会话

- 非持久 WKWebView 完成官方页面登录。
- `WKHTTPCookieStore` 提取白名单凭证。
- Keychain 保存，重启后恢复。
- 会话失效诊断和重新登录。
- 手动 Cookie 导入。
- 完整登出与删除。

通过标准：不依赖自实现密码、短信或扫码；不把 Cookie 写入普通存储或日志。

#### Gate C：核心播放

分别验证 eapi 与 xeapi：

- 免费账号、VIP 测试账号。
- MP3、FLAC 和实际返回的其他格式。
- standard/higher/exhigh/lossless/hires 的权限与降级。
- 拖动、连续切歌、网络切换、睡眠/唤醒。
- 自然观察到旧 URL 返回 403/404 后的显式重新解析和进度恢复；不构造风险样本。
- 试听片段、灰色歌曲、无权限和 Cookie 失效错误分类。
- 实际 CDN host、ATS、redirect 与 Range 行为。

停止条件：核心播放只能通过不稳定设备伪装、受保护 token 或不可接受的账号风险完成。

当前执行状态：eapi 聚合切片已有 VIP/free 五档、VIP Range/play-stop、显式刷新、
free 快速切档、网络恢复和睡眠/唤醒，以及 VIP 快速切歌证据；FLAC 可听确认与已知灰色
样本分类也已完成。一次完整 TTL+余量等待后旧 URL 仍返回有效 Range，因此完整 eapi
Gate C 仍缺实际失效恢复及安全 trial/permission-denied 样本。允许并行开发不增加
live 风险的 Phase 2 foundation 与 Gate D app bootstrap，但这不构成 internal alpha：
播放可靠性宣称仍由完整 Gate C 阻塞，internal alpha 仍由 Gate C/Gate E 阻塞，发行仍由
Gate D 阻塞。当前 Android-identity xeapi 路径为 No-Go，live xeapi 独立保持 Hold。
实时状态与执行顺序保存在本地 `docs/next-session.md`。

#### Gate D：发布工程

- Release 构建与 Hardened Runtime。
- sandboxed/unsandboxed 最小矩阵对比并做决定。
- Developer ID/notarization/stapling 流程演练。
- Sparkle 测试 appcast 和签名更新。
- 干净用户账号安装和升级。
- 决定 Universal 2 或 Apple Silicon-only，并与测试能力一致。

#### Gate E：账号风险（与后续阶段并行至少 2–4 周）

使用专门测试账号：

- 不 scrobble、不签到、不自动收藏、不后台轮询。
- 不伪造 IP、不频繁登录、不压力测试。
- 记录 endpoint、频率、响应异常和账号提示，不记录敏感值。

测试无异常不能证明绝对安全，但能发现高概率问题。若同一最小读取/播放集合反复触发处罚且无法消除，停止公开发布。

### Phase 2 — 内部 alpha（4–8 周）

Phase 2 的离线和低风险 foundation 可与未完成的证据关卡并行实现；只有完整 Gate C、
Gate E 的 alpha 检查点和对应发布前置条件满足后，才能把构建称为 internal alpha。

范围：

- 登录、登出、会话恢复。
- 我的歌单、歌单详情、搜索。
- 播放队列、顺序/循环/随机、直接 URL 播放与恢复。
- 逐行歌词。
- Now Playing、基础媒体键。
- GRDB 缓存、设置、错误与脱敏诊断。

当前已完成原生 app 会话、我的歌单分页，以及显式的歌单详情两阶段离线切片：首批最多
执行一次 `playlistDetail` 和一次 `songDetail`，超过 1000 首只允许用户手动加载下一批。
该进度不等于 internal alpha；新详情 endpoint 尚无 live 批准，完整 Gate C、Gate D1 和
Gate E 仍按各自退出条件保持 Hold。

不做：高级歌词动画、自定义音频缓存、本地自动匹配、菜单栏播放器、推荐/私人 FM、评论与下载。

退出条件：

- 连续日常使用不频繁重登。
- URL 过期和网络恢复不破坏队列。
- 连续播放/切歌无明显状态错乱。
- 无敏感日志泄露。
- 账号无风控提示。
- 核心错误可被用户理解并导出脱敏诊断。

### Phase 3 — 受控 beta（4–6 周）

增加：

- YRC 逐词、翻译、罗马音、辅助功能与性能分档。
- 本地文件手动关联和 security-scoped bookmark。
- 全局快捷键、Dock 菜单、CoreAudio 输出策略。
- 临时 Range cache POC；只有通过完整测试才进入默认路径。
- 签名更新通道和发布自动化。

少量邀请测试，重点收集登录失败、播放恢复、不同账号权限、CPU/GPU/内存、不同 Mac/系统/音频设备、账号提示和更新失败。

### Phase 4 — 公开 v1.0

只有满足以下条件才发布：

- 一个完整版本经过至少 2–4 周受控测试。
- 登录、重登和完整退出可用；无已知 Cookie 泄露。
- 核心 endpoint 白名单稳定，无高概率账号警告。
- 播放恢复、seek、连续切歌和系统状态同步达到日常可用。
- 签名、公证、Sparkle、隐私政策和第三方 notices 完成。
- 支持架构和最新 macOS 经过实际验证。
- 名称/图标基础商标检索和外部法律风险复核完成。

### v1.1+

优先级：

1. 菜单栏 mini player。
2. 菜单栏单行歌词。
3. 桌面歌词。
4. 本地文件匹配优化。
5. Shortcuts / AppleScript，稳定后再评估。

---

## 五、红线、治理与应急

### 技术与产品红线

- ❌ 不实现网易 scrobble、每日签到或任何定时账号行为。
- ❌ 不实现解灰、VIP 解锁、音质授权绕过、`.ncm` 解密。
- ❌ 不提供下载或离线音频；临时缓存必须自动清理。
- ❌ 不硬编码公共 API instance 或第三方音源。
- ❌ 不提供任意插件、自定义音源或代理配置教程。
- ❌ 不做 App Store 分发。
- ❌ 不提供收费、捐赠、赞助或其他 monetization 渠道。
- ❌ 不把 GPL/AGPL/无许可证项目代码复制进 MIT 仓库。

### README 与品牌必做项

- 明确说明 **MacEase = Mac + Ease**。
- 明确说明这是独立、非官方第三方项目，与 NetEase, Inc. 及网易云音乐无关联、无背书。
- 说明第三方客户端登录可能触发账号风控。
- 说明不提供解灰、下载、解密、VIP 绕过和网易播放记录上报。
- 说明唯一官方发布渠道为项目 GitHub Releases，并提供签名验证方法。
- 不写“禁止商用”或把“仅供学习研究”当成许可/免责条款。
- 单独制定商标和官方构建政策，防止第三方冒充 MacEase 官方版本。

### 支持与 issue 边界

- 只承诺当前签名发布版在明确声明的 macOS 与架构矩阵上的支持；nightly、自行修改构建和未声明系统按 best-effort 处理。
- Issue 模板要求应用版本、系统、架构、复现步骤和脱敏诊断；不得要求用户提交 Cookie、账号密码、完整 CDN URL 或私有路径。
- scrobble、签到、解灰、VIP/音质授权绕过、`.ncm` 解密、下载、公共 API instance 和第三方音源请求直接按项目红线关闭，不进入产品 backlog。
- 账号警告或冻结先触发 endpoint 停用与风险复核；MacEase 不承诺代用户恢复账号，用户仍应通过网易官方支持渠道处理账号问题。
- 安全漏洞和凭证泄露走私密联系渠道，公开 issue 只保留脱敏后的状态与修复进展。

### 凭证与发布治理

- Developer ID、notarization、Sparkle 私钥采用最小权限和分离存储。
- Release CI 不接触用户 Cookie、测试账号或本地诊断数据。
- 建立安全联系邮箱、隐私政策、侵权/下架请求入口和第三方许可证清单。
- GitHub Discussions 作为主要社区是支持范围选择，不包装成匿名化或规避责任措施。

### 应急预案

- 保持 `ONLINE_SERVICES_ENABLED` 构建边界，能够产出只保留合法本地播放能力的版本。
- 仓库镜像用于灾备和可恢复性；若收到有效停止要求，所有官方分发与镜像按同一响应流程处理。
- 收到律师函、证书投诉或 GitHub notice：保存证据、暂停相关发布、寻求专业法律意见、按明确要求快速收敛，不承诺“配合即可免责”。
- 发现 Cookie 泄露：立即停止发布和更新通道，撤回受影响构建，通知用户登出/重置会话，完成根因修复后再恢复。
- 发现高概率账号风险：禁用相关 endpoint，保留本地模式，不用配置开关把风险转嫁给用户。

---

## 六、风险登记册

| 风险 | 可能性 | 影响 | 主要措施 | 停止/降级条件 |
|---|---|---|---|---|
| 账号警告或冻结 | 中高 | 高 | 最小 endpoint；不 scrobble/签到；受控测试 | 最小读取/播放仍反复触发处罚 |
| 登录流程失效 | 高 | 高 | WebKit 隔离；Cookie 导入；本地模式；诊断 | 无可接受且可恢复的登录方式 |
| xeapi/设备语义不稳定 | 高 | 高 | endpoint 级 crypto；golden vectors；eapi 对照 | 必须依赖受保护 token 或不可接受伪装 |
| API 静默变化 | 高 | 中高 | NeteaseKit 隔离；canary 集成测试；DTO 映射 | 核心接口频繁中断且维护不可持续 |
| 音频 URL/权限差异 | 中高 | 高 | AssetResolver；实际音质展示；错误分类 | 合法账号仍无法稳定取得播放资源 |
| Cookie 泄露 | 低至中 | 极高 | 非持久 WebView；Keychain；日志测试 | 凭证进入日志、数据库、诊断包或 crash report |
| AVPlayer 恢复边界 | 中 | 中高 | MainActor controller；恢复 reducer；设备矩阵 | seek/切歌/过期恢复持续不可控 |
| 临时缓存复杂度 | 中 | 中 | 分期、Range POC、容量/生命周期约束 | POC 无可靠收益或留下持久音频 |
| SwiftUI 歌词性能 | 中 | 中 | 可见范围渲染；性能分档；辅助功能 | 常见支持硬件无法稳定运行 |
| CoreAudio 设备行为 | 中 | 中 | 真机监听与防抖策略 | 无法可靠区分高价值断开场景 |
| App Sandbox + Sparkle | 中 | 中高 | P0 最小构建；XPC/entitlement 验证 | 关键能力阻塞且无可接受缓解 |
| 新 macOS/架构兼容 | 中 | 中高 | beta/正式矩阵；声明真实支持范围 | 无硬件或 CI 能验证却仍声称支持 |
| 法律或平台投诉 | 中 | 高 | 红线；白名单；专业复核；本地模式 | 收到明确停止要求或分发证书受影响 |
| 单人维护耗尽 | 高 | 高 | 严格非目标；少 endpoint；停止条件 | issue/API 维护长期超过可用时间 |
| 许可证污染 | 低至中 | 高 | notices、来源记录、clean-room | 无法证明关键实现来源兼容 |
| Homebrew 不收录 | 中 | 低 | GitHub Releases 为主 | 不影响项目 Go/No-Go |
| 第三方套壳 | 中 | 低 | 商标政策、签名、唯一渠道 | 不通过 MIT 许可强行限制代码使用 |

任何尚未在目标 SDK、硬件和正式系统上验证的新版本都不能预设为低风险。原生实现只减少一部分故障面。

---

## 七、实现阶段未决问题

1. **默认音质**：跟随账号权限自动选择，还是默认较保守档位；必须显示实际返回值并考虑流量。
2. **App Sandbox**：以 Phase 1 Gate D 的最小构建结果决定，优先 sandboxed。
3. **架构支持**：Universal 2 还是 Apple Silicon-only；只能声明有真实测试能力的架构。
4. **用户写操作**：收藏/取消收藏是否进入 v1；任何写 endpoint 都要单独做风控评估。
5. **本地文件关联**：security-scoped bookmark、文件移动后的恢复、匹配阈值；v1 不做音频指纹。
6. **临时音频缓存启用门槛**：直接播放恢复在哪些测试中不足，才值得启用 ResourceLoader 路径。
7. **长列表实现**：以真实 1 万/5 万条数据 benchmark 决定 SwiftUI 还是 NSTableView。
8. **应用图标**：避开红色圆形、相似音波和网易官方视觉；完成基础商标/同名检索。
9. **未登录体验**：只做清晰的 signed-out/local mode，还是增加 public-read guest；不得为 guest 伪造匿名设备身份。

下载、iOS/watchOS、多源 provider 和 scrobble 不再列为普通未决问题；它们已被当前产品边界排除。

---

## 八、成功标准

不以 star、Homebrew 收录、接口数量或功能比官方客户端多来定义成功。公开 v1 的成功标准是：

- 自己和受控测试者能连续数周日常使用。
- 登录失效时有可理解、可恢复、可完全清除的路径。
- URL 过期、网络切换和睡眠不会破坏播放队列。
- AVPlayer、UI、Now Playing 与 Remote Command 状态一致。
- 歌词在支持的常见 Mac 上达到稳定性能并可降级。
- Cookie 不进入普通存储、日志或诊断包。
- 协议变化只影响 `NeteaseKit` 和少数明确边界。
- 关闭在线接口后仍能安全构建和运行本地模式。
- 功能和 endpoint 数量保持在单人可长期维护范围内。

最重要的工程原则：

> 少调用一个不必要的私有接口，比多实现一个页面更有价值；可靠完成一次播放，比覆盖十个社区功能更重要。

---

## 九、对 `MacEase.md` review 的复核结论

### 9.1 十五条核心纠偏

| Review 条目 | 结论 | 吸收方式 |
|---|---|---|
| 原生市场不是空白 | 正确 | 改为“缺少成熟可信方案” |
| star 不能证明需求 | 正确 | 降级为传播/关注信号 |
| 原生不免疫新系统问题 | 正确 | 新增系统/架构/设备矩阵 |
| 系统集成不是零成本 | 正确 | 独立子系统；CoreAudio 真机验证 |
| scrobble 因果写得过满 | 正确 | 改为高可信度关联，永久排除不变 |
| WKWebView 不是稳定契约 | 正确 | 非持久 WebView、诊断、完整退出；不把 guest 设为硬要求 |
| xeapi 不是确定全面迁移 | 只对一半 | 不预测全面迁移，但当前播放 endpoint 已默认 xeapi，必须升为 P0 |
| Swift 不必手写 BigUInt | 正确且已实测 | SecKey raw RSA 与 Node 输出完全一致 |
| Rust sidecar 不应是首个回退 | 正确 | Apple frameworks → 修正协议；任何 FFI 都需显式重开架构决策，sidecar 不在计划内 |
| ResourceLoader 复杂度被低估 | 正确 | 缓存后置并增加 Range/renewal gate |
| AVPlayer “自带空间音频”应删除 | 正确 | 不承诺空间音频、bit-perfect、独占 DAC |
| Homebrew 不是市场窗口 | 正确 | 改为附加分发渠道，加入当前官方收录政策 |
| 法律风险不能判极低 | 正确 | 删除绝对法律推断，加入外部复核和停止流程 |
| 匿名化不是合规 | 正确 | 改为透明运营、最小权限和专业联系渠道 |
| MIT 与禁止商用冲突 | 正确 | 保持已确认 MIT，删除禁商文案，增加商标政策 |

### 9.2 Review 自身需要修正的建议

| Review 建议 | 复核结论 |
|---|---|
| 游客模式必须进入 v1 | 证据不足；会增加匿名 token/设备身份分支。只在无需伪造身份且 public-read 稳定时做。 |
| `SessionVault actor` 直接管理 WebKit | 不适合 Swift 6 严格并发；SDK 将 WebsiteDataStore 标为 UI actor，拆成 `@MainActor LoginCoordinator` + CredentialVault actor。 |
| `PlaybackStateMachine actor` 直接拥有 AVPlayer | 不适合当前 SDK 注解；AVPlayer 是 UI actor。采用 MainActor controller + 纯状态 reducer + 后台 resolver/cache actor。 |
| 第二阶段缓存放 `~/Library/Caches` 且可跨退出保留 | 与项目硬约束冲突；只允许进程级临时目录并主动清理。 |
| 菜单栏 mini player 可提前进 v1.0 | 不采纳；既定决策仍是 v1.1，先守住登录和播放可靠性。 |
| 模块压到 6–8 个 package | 方向对但仍可能过度；采用一个本地 package、少量 targets，app 功能先用目录组织。 |
| 12–20 周是确定估算 | 只能作为规划包络；协议、账号和发布 gate 可能显著改变周期。 |
| Apache-2.0 比 MIT 更推荐 | 不采纳；MIT 是已确认决策，真正要修的是 README 与商标政策。 |
| 音频缓存应完全移出 v1 | 只部分采纳；alpha 后置，但临时缓存仍是既定目标，是否默认启用由可靠性数据决定。 |
| SBOM、依赖机器人全部作为早期硬要求 | 治理方向正确；notices/来源记录优先，完整 SBOM 可在公开 beta 前完成。 |

本次 review 最有价值的贡献是纠正绝对化表述、强调播放状态与发布工程；其主要缺口是没有注意到当前 `song_url_v1` 已默认 xeapi、没有处理 Apple SDK 的 UI-actor 注解，也提出了与临时音频硬约束冲突的持久缓存建议。

---

## 十、参考资料

本轮主要源码快照（均于 2026-08-06 通过 GitHub 镜像读取）：`api-enhanced` `5b780addbafe`、`NeteaseCloudMusicAPI-Swift` `8626b8fe6281`、MusicBox `db1f50859496`、Sparkle `303db889480f`。文中的“当前源码”判断以这些快照为准，不自动外推到未来版本。

### Apple 与发布工程

- Apple Security `SecKeyAlgorithm.rsaEncryptionRaw`：<https://developer.apple.com/documentation/security/seckeyalgorithm/rsaencryptionraw>
- Apple `AVAssetResourceLoader`：<https://developer.apple.com/documentation/avfoundation/avassetresourceloader>
- Apple `WKWebsiteDataStore`：<https://developer.apple.com/documentation/webkit/wkwebsitedatastore>
- Apple SwiftUI `TextRenderer`：<https://developer.apple.com/documentation/swiftui/textrenderer>
- Apple `MPNowPlayingInfoCenter`：<https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter>
- Sparkle 2 sandboxing：<https://sparkle-project.org/documentation/sandboxing/>
- Homebrew Acceptable Casks：<https://docs.brew.sh/Acceptable-Casks>
- Homebrew Package Acceptance Policy：<https://docs.brew.sh/Package-Acceptance-Policy>
- Homebrew 5.0.0 Gatekeeper 时间线：<https://brew.sh/2025/11/12/homebrew-5.0.0/>
- Homebrew 6.0.0 对 Gatekeeper 时间线的再次确认：<https://brew.sh/2026/06/11/homebrew-6.0.0/>
- MIT License：<https://opensource.org/license/mit>

### API 与协议

- `NeteaseCloudMusicApiEnhanced/api-enhanced`：<https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced>
- xeapi issue #174：<https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/issues/174>
- `Lincb522/NeteaseCloudMusicAPI-Swift`：<https://github.com/Lincb522/NeteaseCloudMusicAPI-Swift>
- `chaunsin/netease-cloud-music`：<https://github.com/chaunsin/netease-cloud-music>

### 原生实现与行为参考

- `zeyugao/MusicBox`：<https://github.com/zeyugao/MusicBox>
- `youshen2/MeloX`：<https://github.com/youshen2/MeloX>
- `go-musicfox/go-musicfox`：<https://github.com/go-musicfox/go-musicfox>
- `ddddxxx/LyricsX`：<https://github.com/ddddxxx/LyricsX>
- AMLL：<https://github.com/amll-dev/applemusic-like-lyrics>

### 风控证据

- YesPlayMusic issue #2383：<https://github.com/qier222/YesPlayMusic/issues/2383>
