# MacEase

MacEase 是使用 Apple 原生技术开发的 macOS 网易云音乐第三方客户端，采用 MIT
许可证。本文只定义产品范围；实现状态见 [docs/status.md](docs/status.md)，后续计划见
[docs/plan.md](docs/plan.md)。

> 本项目除 README.md 外的 Markdown 都是本地工作文件，不纳入 Git 或 GitHub。

## 长期规则

- 使用 Swift、SwiftUI 和 Apple 原生框架，不使用任何跨平台框架，例如 Electron。
- 只服务网易云音乐，不建立多音源抽象；网络协议统一由 `NeteaseKit` 承担。
- 目标平台为 macOS 15 和 Apple Silicon，界面遵循 macOS 原生设计。
- 公开版本通过 GitHub Releases 和 Homebrew 分发。

## 目标用户与核心任务

面向希望在 macOS 上使用完整网易云音乐能力、同时保留系统原生体验的用户。功能完成
标准是覆盖 `missuo/kumone@6bc24e8` 已实现的全部产品能力，唯一例外为桌面歌词。

- 登录与账号：初期使用 WKWebView 官方登录页；后续增加原生二维码、短信验证码、
  服务端退出、Token 刷新和 Keychain 会话恢复。
- 音乐库：用户歌单、红心、听歌记录与排行、专辑收藏、歌手关注、云盘及全部用户明确
  发起的创建、编辑、收藏、删除操作。
- 发现：每日推荐、推荐歌单、榜单、分类与精品歌单、雷达、新歌、相似歌曲与歌手、
  私人 FM、FM trash 和心动模式。
- 搜索与详情：歌曲、专辑、歌手、歌单搜索及建议；专辑、歌手、歌单完整详情。
- 播放：五档音质、队列与播放模式、seek、定时停止、播放恢复、临时缓存、下载与
  离线播放。
- 歌词：LRC、YRC、翻译、罗马音和应用内逐行逐词歌词；逐行逐词 UI 属于大后期工作。
- 账号反馈：听歌上报（scrobble）、听歌记录和排行。
- 系统整合：Now Playing、媒体键、蓝牙遥控、音频设备切换、sleep/wake、Dock 菜单、
  快捷键、队列恢复和原生通知。

## 永久排除

- 桌面歌词窗口。

## 本地文档

- [AGENTS.md](AGENTS.md)：长期工程规则。
- [docs/status.md](docs/status.md)：唯一的实现现状。
- [docs/plan.md](docs/plan.md)：唯一的功能与开发计划。
