# 状态

> 这是当前状态的唯一权威记录。任何其它文件与它冲突时以本文件为准。
> 由 `scripts/check_status.sh` 校验，不得手工放任漂移。
> `verified-at-commit` 是最后一次运行验证时的**代码**提交；仅改文档的提交之后
> HEAD 会领先它一格，脚本会提示但不视为失败。

## 机器可读当前状态

| key | value |
|---|---|
| verified-at-commit | 069f22d |
| toolchain | Swift 6.1.2 / Xcode 16.4 |
| platform | macOS 15, arm64 only |
| debug-tests | 230 |
| release-tests | 230 |
| release-build | pass |
| live-requests-this-round | 0 |

## 关卡

| Gate | 状态 |
|---|---|
| Gate A 无账号歌词 probe | live-passed |
| Gate B 登录与 Keychain | live-passed |
| Gate C 播放（完整恢复矩阵） | hold |
| Gate D1 打包与签名 | implemented-offline |
| Gate E 观察窗口 | hold |
| xeapi | hold |

## 功能

状态取值只有 `implemented-offline`、`live-passed`、`live-failed`、`hold`、`retired`。

| 功能 | 状态 |
|---|---|
| 官方登录页 + Keychain 会话 | live-passed |
| 我的歌单分页 | live-passed |
| 歌单曲目详情（分批 ≤1000） | live-passed |
| 红心 / 取消红心 | live-passed |
| 发现四节（每日歌曲/每日歌单/推荐歌单/排行榜） | live-passed |
| 听歌排行 | live-passed |
| 相似歌曲 | live-passed |
| 歌单写组（创建/改名/删除/增删曲目） | live-passed |
| 歌单收藏 / 取消收藏（不带反作弊 token） | implemented-offline |
| 歌曲搜索（cloudsearch） | implemented-offline |
| 红心三态（unknown / liked / not liked） | implemented-offline |
| 单曲播放与队列、定时播放、本地 seek | implemented-offline |
| 逐行歌词 | hold |
| Now Playing / Remote Command | hold |
| GRDB 持久化 | hold |
| 心动模式 | hold |

## 未验证与已知限制

- `/api/batch` 的内层子响应状态未取得一手证据；rename 只检查顶层 `code == 200`，
  因此**不宣称**已证明保留 description 与 tags。
- 收藏歌单不发送反作弊 token。是否被服务端接受需 live 判定；`-460` 即标记为
  unsupported 并停用，不实现指纹伪造。
- Gate C 的完整恢复矩阵（自然 URL 过期、Wi-Fi 切换、sleep/wake、音频设备切换、
  快速切歌）尚未在固定 artifact 上逐项记录。
- Now Playing 与媒体键未接入，因此系统播放状态与 app 状态尚未统一。
- 在上述三项完成前，本项目不称为 internal alpha。
