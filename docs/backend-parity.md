# 后端能力对照表

> 本表回答一个问题：对标项目已有的网易云后端能力，MacEase 现在处于哪一档。
> 它不描述计划、不描述 UI，也不替代 [status.md](status.md)。
> 测试数、关卡结论和 verified commit 只在 `status.md` 维护一份，本表不重复。
>
> 对标基线：`missuo/kumone@6bc24e8`（2026-08-27 固定）。
> MacEase 基线：见 `status.md` 的 `verified-at-commit`。
> 已实现端点的请求合同在 [endpoint-registry.md](endpoint-registry.md)。
>
> `scripts/check_parity.sh` 校验本表每个状态格都取自下面的词表。

## 状态词

| 状态 | 含义 |
|---|---|
| `historical-live-observed` | 已实现；维护者曾在**更早的固定 artifact** 上记录过成功的 live 观察。原始记录不在公开仓库，**不等于**当前 HEAD 已通过 live 验收。 |
| `implemented-offline` | 已实现，只有离线测试。没有任何 live 验收。 |
| `probe-only` | 只存在于 Gate harness / probe，未接入产品后端，app 不调用。 |
| `missing` | 未实现。 |
| `hold` | 已规划且被有意冻结，解冻需要先满足前置条件。 |
| `experimental-nonshipping` | 只允许进入实验 target，正式 app 依赖图中不得出现。 |
| `excluded` | 有意排除。不是"以后再做"，是不做。 |

执行手册使用简写 `LIVE` / `OFFLINE` / `PROBE` / `MISSING` / `HOLD` / `EXP` / `EXCLUDE`，
按上表逐行对应。本表用完整词，因为 `LIVE` 会被读成"当前 HEAD 已通过 live 验收"，
而这不是任何一行现在能宣称的事情。

## 1. 认证与会话

| 能力 | 端点 | 状态 |
|---|---|---|
| 官方网页登录（WKWebView 提取 Cookie） | 非 API | `historical-live-observed` |
| 账号状态 / 取 userId | `weapi /w/nuser/account/get` | `historical-live-observed` |
| Keychain 会话恢复 | 非 API | `historical-live-observed` |
| 事务式会话清除与全 app 清理 | 非 API | `implemented-offline` |
| 原生二维码 key | `weapi /login/qrcode/unikey` | `missing` |
| 二维码状态轮询 | `weapi /login/qrcode/client/login` | `missing` |
| 发送短信验证码 | `weapi /sms/captcha/sent` | `missing` |
| 短信验证码登录 | `weapi /w/login/cellphone` | `missing` |
| 服务端退出登录 | `weapi /logout` | `missing` |
| 登录 token 刷新 | `weapi /login/token/refresh` | `missing` |

Web 登录保持为默认入口。QR 与 SMS 属于补充入口，不替代它。
本地清除必须独立于服务端 logout 可靠执行。

## 2. 用户音乐库与账号数据

| 能力 | 端点 | 状态 |
|---|---|---|
| 我的歌单分页 | `weapi /user/playlist` | `historical-live-observed` |
| 歌单曲目详情（每批 ≤ 1000） | `weapi /v3/song/detail` | `historical-live-observed` |
| 红心歌曲 ID 集合 | `weapi /song/like/get` | `historical-live-observed` |
| 红心 / 取消红心 | `weapi /radio/like` | `historical-live-observed` |
| 听歌排行 | `weapi /v1/play/record` | `historical-live-observed` |
| 收藏专辑列表 | `weapi /album/sublist` | `missing` |
| 关注歌手列表 | `weapi /artist/sublist` | `missing` |
| 云盘歌曲列表与容量 | `weapi /v1/cloud/get` | `missing` |
| 删除云盘歌曲 | `weapi /cloud/del` | `missing` |
| 云盘上传 | — | `excluded` |

## 3. 歌单、推荐与探索

| 能力 | 端点 | 状态 |
|---|---|---|
| 每日推荐歌曲 | `weapi /v3/discovery/recommend/songs` | `historical-live-observed` |
| 每日推荐歌单 | `weapi /v1/discovery/recommend/resource` | `historical-live-observed` |
| 推荐歌单 | `weapi /personalized/playlist` | `historical-live-observed` |
| 榜单摘要 | `eapi /toplist` | `historical-live-observed` |
| 歌单详情（权威 track ID 全序） | `eapi /v6/playlist/detail` | `historical-live-observed` |
| 创建公开歌单 | `weapi /playlist/create` | `historical-live-observed` |
| 删除歌单 | `weapi /playlist/remove` | `historical-live-observed` |
| 歌单增删曲目 | `eapi /playlist/manipulate/tracks` | `historical-live-observed` |
| 歌单改名（只发 name 子请求） | `eapi /batch` | `historical-live-observed` |
| 收藏 / 取消收藏歌单（不带反作弊 token） | `eapi /playlist/subscribe`、`/playlist/unsubscribe` | `implemented-offline` |
| 创建隐私歌单（`privacy=10`） | `weapi /playlist/create` | `missing` |
| 分类歌单 | `weapi /playlist/list` | `missing` |
| 精品歌单（`lasttime` 游标） | `weapi /playlist/highquality/list` | `missing` |
| 雷达歌单组合 | 复用歌单详情 | `missing` |
| 私人 FM | `weapi /v1/radio/get` | `missing` |
| FM 不喜欢 | `weapi /radio/trash/add` | `missing` |
| 心动模式队列 | `weapi /playmode/intelligence/list` | `hold` |

心动模式在红心状态为 `unknown` 时必须禁用，因此它排在红心三态之后。

## 4. 播放、歌词与曲目

| 能力 | 端点 | 状态 |
|---|---|---|
| 播放 URL 解析 | `eapi /song/enhance/player/url/v1` | `implemented-offline` |
| 五档音质（standard…hires） | 同上 | `implemented-offline` |
| 相似歌曲（legacy `artists` 字段） | `weapi /v1/discovery/simiSong` | `historical-live-observed` |
| 单曲播放、队列、本地 seek、定时停止 | 非 API | `implemented-offline` |
| 显式播放恢复与 stale callback 隔离 | 非 API | `implemented-offline` |
| LRC 歌词 | `eapi /song/lyric/v1` | `probe-only` |
| YRC 逐字歌词 | 同上 | `missing` |
| 翻译与罗马音对齐 | 同上 | `missing` |
| 歌词 v1 → classic 显式 fallback | `/song/lyric` | `missing` |
| 听歌上报 scrobble | `eapi /feedback/weblog` | `experimental-nonshipping` |
| 播放 URL 自动降级到 standard | — | `excluded` |
| 播放失败自动跳过下一首 | — | `excluded` |
| 第三方解灰 / 音源替换 | — | `excluded` |
| 下载、离线保存、`.ncm` 解密 | — | `excluded` |
| 桌面歌词窗口 | — | `excluded` |

`probe-only` 对歌词是准确的：`/song/lyric/v1` 只被 Gate A probe 调用，
app 没有歌词后端。probe 只区分"有/无可用歌词"，不解析时间轴。

scrobble 记为 `experimental-nonshipping` 是**目标态**，当前尚未建立该 target；
在建立之前正式 app 无任何调用路径，这一点由 CI 的依赖图检查保证。

## 5. 专辑、歌手与搜索

| 能力 | 端点 | 状态 |
|---|---|---|
| 歌曲搜索 | `eapi /cloudsearch/pc`（`type=1`） | `implemented-offline` |
| 专辑搜索 | 同上（`type=10`） | `missing` |
| 歌手搜索 | 同上（`type=100`） | `missing` |
| 歌单搜索 | 同上（`type=1000`） | `missing` |
| 搜索建议（debounce + 可取消） | `weapi /search/suggest/web` | `missing` |
| 默认搜索词 | `eapi /search/defaultkeyword/get` | `missing` |
| 专辑详情与曲目 | `weapi /v1/album/{id}` | `missing` |
| 专辑动态 / 收藏状态 | `eapi /album/detail/dynamic` | `missing` |
| 新碟 | `weapi /album/new` | `missing` |
| 收藏 / 取消收藏专辑 | `weapi /album/sub`、`/album/unsub` | `missing` |
| 歌手详情与热门歌曲 | `weapi /v1/artist/{id}` | `missing` |
| 歌手专辑分页 | `weapi /artist/albums/{id}` | `missing` |
| 关注 / 取消关注歌手 | `weapi /artist/sub`、`/artist/unsub` | `missing` |
| 热门歌手 | `weapi /toplist/artist` | `missing` |
| 相似歌手 | `weapi /discovery/simiArtist` | `missing` |
| 推荐新歌 | `weapi /personalized/newsong` | `missing` |

## 6. 非 API 但属于后端完成的子系统

| 子系统 | 状态 | 说明 |
|---|---|---|
| 操作仲裁（写互斥、读并发有上限、sent-write unknown） | `implemented-offline` | `OperationArbiter` |
| 会话状态机与三态存储存在性 | `implemented-offline` | `SessionReducer` |
| 红心三态（unknown / liked / not liked） | `implemented-offline` | `LikedSongs` |
| 写操作 unknown / remote-only 结果分类 | `implemented-offline` | `OperationArbiter` |
| 类型化播放失败与可恢复 allow-list | `implemented-offline` | `PlaybackFailureClassifier` |
| 类型化错误层级与超时策略 | `hold` | 当前错误分类分散在各 coordinator |
| Now Playing 状态投影 | `implemented-offline` | `PlaybackSnapshot` + `NowPlayingCoordinator`；无专辑与封面，随 canonical Track 补齐 |
| Remote Command / 媒体键 | `implemented-offline` | play/pause/toggle/next/previous/seek/like，均先经投影校验再转为 intent |
| CoreAudio 输出设备变化 | `missing` | — |
| sleep / wake | `probe-only` | 只在 Gate B harness 的 `PlaybackProbeCoordinator` |
| 播放队列与上下文持久化 | `missing` | — |
| GRDB 持久化与账号隔离 | `hold` | — |
| 图片管线（内存/磁盘缓存、请求合并） | `missing` | — |
| 歌词后端（解析、时间轴、offset） | `hold` | 依赖播放时钟 |
| 脱敏诊断与有限环形日志 | `missing` | 当前只有 `status` 显示字符串 |
| Dock 菜单与本地快捷键 | `missing` | — |
| 本地 ad-hoc 打包与签名 | `implemented-offline` | Gate D0 |
| Developer ID / 公证 / staple | `hold` | Gate D1 |
| Sparkle 2 更新 | `hold` | Gate D1 |
| Gate E 观察窗口 | `hold` | 依赖端点冻结 |

## 7. 明确排除项

以下不属于"对齐后端能力"，不因为对标项目有就实现：

- 第三方解灰、UnblockNeteaseMusic、任何第三方音源。
- VIP、版权或音质授权绕过。
- 下载、离线保存、`.ncm` 解密。
- 自动重试（含 512 加倍 ID 重发）、自动 endpoint fallback、失败自动跳歌。
- 伪造官方 appver、deviceId、osver、分辨率或 Android 身份。
- 桌面歌词窗口。
- iOS 版本。
- 后台轮询与自动刷新。

## 8. 汇总

统计范围是第 1–6 节的能力表。第 7 节是列表而非表格，其中的排除项已在第 1–6 节
对应位置各计一次，不重复计数。

| 状态 | 条目数 |
|---|---|
| `historical-live-observed` | 18 |
| `implemented-offline` | 15 |
| `probe-only` | 2 |
| `missing` | 39 |
| `hold` | 7 |
| `experimental-nonshipping` | 1 |
| `excluded` | 6 |

计数由 `scripts/check_parity.sh` 校验，与上面各表保持一致。
