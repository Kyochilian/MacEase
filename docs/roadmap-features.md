# 功能路线图（2026-08-13 确认）

本文档记录 2026-08-13 与维护者确认的功能范围、端点映射与开发顺序。
永久边界（不 scrobble、不签到、不解灰、不缓存离线音频等）见 README，不因本路线图改变。

## 已确认的范围决策

| 决策项 | 结论 |
|---|---|
| 平台 | 仅构建 Apple Silicon（arm64），不提供 Intel 或 Universal 构建 |
| UI 风格 | 严格遵循 macOS Sequoia 15 视觉风格与 Apple/macOS 设计美学；暂不引入 Liquid Glass |
| 登录 | 沿用 WKWebView 官方登录页（其内嵌二维码即扫码登录入口），不实现原生 QR 轮询端点 |
| scrobble | 保持不实现。听歌排行只展示服务器已有数据；MacEase 内播放不计入排行，也不反哺推荐算法 |
| 「不喜欢」语义 | 仅红心/取消红心（`song/like`），不实现 FM trash |
| 请求策略 | 启动时一次性预取首页推荐数据；后续刷新由用户手动触发；仍不自动重试、不后台轮询 |
| 定时播放 | 到时后播完当前曲目再停（提供切换为立即停止的开关）；纯客户端功能 |
| 心动模式 | 仅从红心歌曲切入，以当前曲目为种子 + 我喜欢歌单 pid 生成队列 |
| 播放缓存 | 本轮暂不启用临时目录缓存，继续直接播放短期 URL |

## 开发顺序与端点映射

端点的当前实现与参考 commit 记录在 [endpoint-registry.md](endpoint-registry.md) 和
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。写操作接入前必须登记合同字段、
核对本地权威源码并用专用测试账号验证。

### 第 1 批：基础播放补齐（纯客户端为主）

- 音量调节、播放队列管理、上一首/下一首 — AVPlayer，本地状态
- 播放模式：顺序、循环（单曲/列表）、随机 — 本地队列逻辑
- 定时播放（睡眠定时器）— 本地
- 依赖已有端点：`song/enhance/player/url/v1`（eapi）、`v3/song/detail`（weapi）

### 第 2 批：音乐库读写

- 我喜欢的音乐：`weapi/song/like/get`（likelist）+ 已有歌单详情
- 红心/取消红心：`weapi` `/api/radio/like`（写；不是 `song/like`）
- 歌单编辑：`weapi/playlist/create`、`playlist/remove`、改元信息走 `weapi/batch`、
  `playlist/manipulate/tracks`、`playlist/subscribe`（写；删除需 UI 二次确认）
- 听歌排行：`weapi/v1/play/record`（读，type=0 全部/1 最近一周）

### 第 3 批：推荐与发现（启动预取一次，手动刷新）

- 每日推荐歌曲：`weapi/v3/discovery/recommend/songs`
- 每日推荐歌单：`weapi/v1/discovery/recommend/resource`
- 推荐歌单：`weapi/personalized/playlist`
- 热歌榜及榜单：`toplist` 摘要 + 复用歌单详情（热歌榜 id 3778678）
- 相似歌曲：`weapi/v1/discovery/simiSong`

### 第 4 批：心动模式

- `weapi/playmode/intelligence/list`（参数：种子 songId + 我喜欢歌单 pid）
- 入口仅出现在红心曲目播放态与「我喜欢的音乐」页

## 参考项目

端点路径、已知差异与未验证项维护在 [endpoint-registry.md](endpoint-registry.md)；
参考仓库 commit 与许可红线维护在 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
