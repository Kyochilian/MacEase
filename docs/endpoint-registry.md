# 端点登记表

> 本表由 `Sources/NeteaseKit/NeteaseSession.swift` 的实际常量整理，
> 新增端点必须同时更新本表、golden test 与 `THIRD_PARTY_NOTICES.md` 的证据来源。
> 2026-08-26 已对照本地 `api-enhanced` commit `a7e8d485f31c` 的相关 `module/*.js`、
> `util/option.js`、`util/request.js` 与 `util/config.json`。
> 本表只列**已实现**的端点；尚未实现的能力见
> [backend-parity.md](backend-parity.md)。

## 规则

- weapi URL 由 canonical API path 按 `'/weapi/' + path.substr(5)` 推导，
  即去掉开头的 `/api/`。禁止照抄二手 URL 字面量。
- eapi URL 为 `https://interfacepc.music.163.com/eapi/` + 同样规则的路径，
  加密时使用未经改写的 `/api/...` path。
- 成功仅认 `code == 200`。任何其它值分类为 `NeteaseServiceError` 并停止。
- **retry policy 一律为 none。** 参考实现在 512 上自动重发，MacEase 不复制。
- 已有证据支持凭据失效语义的 service `301` 仅限 account-status 验证、
  `user/playlist` 首页读取和 `songURL` 播放解析；详情、Discover、likelist 与其它
  端点的 `301` 只分类，不清除凭据。该列表不是对未来端点的推测性泛化。
- 当前参考实现的 `song_url_v1` 默认 xeapi、`likelist` 默认 eapi；MacEase 分别保留
  历史固定 artifact 使用的 eapi 与 weapi 路径，不在运行时猜测或回退协议。当前 HEAD
  的 live 验收仍须单独进行。

## weapi

| Endpoint | URL | Effect | 用途 |
|---|---|---|---|
| account status | `music.163.com/weapi/w/nuser/account/get` | read | 验证会话与取 userId |
| user playlists | `music.163.com/weapi/user/playlist` | read | 我的歌单分页 |
| song detail | `music.163.com/weapi/v3/song/detail` | read | 曲目元数据，每批 ≤ 1000 |
| liked song ids | `music.163.com/weapi/song/like/get` | read | 红心歌曲 ID 集合 |
| play record | `music.163.com/weapi/v1/play/record` | read | 听歌排行（服务器侧数据） |
| daily songs | `music.163.com/weapi/v3/discovery/recommend/songs` | read | 每日推荐歌曲 |
| daily playlists | `music.163.com/weapi/v1/discovery/recommend/resource` | read | 每日推荐歌单 |
| personalized playlists | `music.163.com/weapi/personalized/playlist` | read | 推荐歌单 |
| similar songs | `music.163.com/weapi/v1/discovery/simiSong` | read | 相似歌曲，响应用 legacy `artists` 字段 |
| like song | `music.163.com/weapi/radio/like` | write | 红心 / 取消红心 |
| create playlist | `music.163.com/weapi/playlist/create` | write | 新建歌单 |
| delete playlist | `music.163.com/weapi/playlist/remove` | write | 删除歌单 |

## eapi

| Endpoint | crypto path | Effect | 用途 |
|---|---|---|---|
| song url | `/api/song/enhance/player/url/v1` | playbackResolution | 解析短时效播放 URL |
| playlist detail | `/api/v6/playlist/detail` | read | 歌单曲目 ID 全序 |
| toplist | `/api/toplist` | read | 排行榜列表 |
| cloudsearch | `/api/cloudsearch/pc` | read | 歌曲搜索，响应用现代 `ar` 字段 |
| manipulate tracks | `/api/playlist/manipulate/tracks` | write | 歌单增删曲目 |
| batch | `/api/batch` | write | 仅发 `/api/playlist/update/name` 子请求 |
| playlist subscribe | `/api/playlist/subscribe` | write | 收藏歌单 |
| playlist unsubscribe | `/api/playlist/unsubscribe` | write | 取消收藏 |
| song lyric | `/api/song/lyric/v1` | read | 仅用于 Gate A probe，未接入 app |

## 未验证与保留项

| 项 | 状态 |
|---|---|
| `/api/batch` 内层子响应状态 | **未验证**。当前只检查顶层 `code == 200`。是否存在「顶层 200、子请求失败」需一手脱敏响应证据；在此之前不宣称 rename 已证明保留 description/tags。 |
| playlist subscribe / unsubscribe | 已实现且不发送反作弊 token。是否被服务端接受需 live 判定；`-460` 即视为需要 token，功能停用而非补指纹。 |
| xeapi | 全部 Hold。错误处理已完成不等于批准 live。 |
| 歌词 `lrc` / `yrc` 内层字段 | 本地权威参考文档与 tests 锁定最小 `lyric: String`；空对象和空字符串不是内容。时间轴、翻译与逐字字段仍需一手脱敏样本后再接入 app。 |
| `freeTrialInfo` 内层字段 | **未验证**。参考实现本身只判断非 null，MacEase 收紧为「必须是对象」；非对象值记为非试听而不使整次解析失败。 |

## 请求预算

每个按钮的文案标注它会发出的请求数。除以下一处外没有隐式请求：

- 首次成功验证后，Discover 四节各发一次预取（共 ≤ 4 次），本次 app 运行内只发生一次，
  遇到第一个错误即停止。

不存在自动重试、后台轮询、写后自动刷新或第二 endpoint fallback。
