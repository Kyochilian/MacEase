# 状态

> 这是公开仓库的状态摘要。`scripts/check_status.sh` 只重跑 Debug/Release 测试并
> 核对下表中的测试数量；它不验证平台、构建、关卡或 live 结论。
> `verified-at-commit` 标识被验证的代码截面；工作树复核尚未提交时会明确这样记录。
> 该字段仅作提示，不由脚本判定通过或失败。

## 机器可读当前状态

| key | value |
|---|---|
| verified-at-commit | working-tree (SYS-001 in progress) |
| toolchain | Swift 6.1.2 / Xcode 16.4 |
| platform | macOS 15, arm64 only |
| debug-tests | 291 |
| release-tests | 291 |
| release-build | pass |
| live-requests-this-round | 0 |

## 关卡

| Gate | 状态 |
|---|---|
| Gate A 无账号歌词 probe | historical-live-observed |
| Gate B 登录与 Keychain | historical-live-observed |
| Gate C 播放（完整恢复矩阵） | hold |
| Gate D0 app 组装与本地签名 | implemented-offline |
| Gate D1 Developer ID / notarization / Sparkle 分发 | hold |
| Gate E 观察窗口 | hold |
| xeapi | hold |

## 功能

`historical-live-observed` 表示维护者曾在早期固定 artifact 上记录成功观察；原始记录
不在公开仓库，且该状态不等于当前 HEAD 已通过 live 验收。其它状态为
`implemented-offline`、`hold`、`retired`。

下表只列已实现或已明确规划的功能。与对标项目的完整能力差距（含尚未实现的端点）
见 [backend-parity.md](backend-parity.md)。

| 功能 | 状态 |
|---|---|
| 官方登录页 + Keychain 会话 | historical-live-observed |
| 我的歌单分页 | historical-live-observed |
| 歌单曲目详情（分批 ≤1000） | historical-live-observed |
| 红心 / 取消红心 | historical-live-observed |
| 发现四节（每日歌曲/每日歌单/推荐歌单/排行榜） | historical-live-observed |
| 听歌排行 | historical-live-observed |
| 相似歌曲 | historical-live-observed |
| 歌单写组（创建/改名/删除/增删曲目） | historical-live-observed |
| 歌单收藏 / 取消收藏（不带反作弊 token） | implemented-offline |
| 歌曲搜索（cloudsearch） | implemented-offline |
| 红心三态（unknown / liked / not liked） | implemented-offline |
| 写操作 unknown / remote-only 结果分类 | implemented-offline |
| 事务式会话失效与全 app 清理 | implemented-offline |
| 显式播放恢复与 stale callback 隔离 | implemented-offline |
| 单曲播放与队列、定时播放、本地 seek | implemented-offline |
| 逐行歌词 | hold |
| Now Playing / Remote Command | implemented-offline |
| GRDB 持久化 | hold |
| 心动模式 | hold |

## 未验证与已知限制

- `/api/batch` 的内层子响应状态未取得一手证据；rename 只检查顶层 `code == 200`，
  因此**不宣称**已证明保留 description 与 tags。
- 收藏歌单不发送反作弊 token。是否被服务端接受需 live 判定；`-460` 即标记为
  unsupported 并停用，不实现指纹伪造。
- Gate C 的完整恢复矩阵（自然 URL 过期、Wi-Fi 切换、sleep/wake、音频设备切换、
  快速切歌）尚未在固定 artifact 上逐项记录。
- Gate D0 仅证明 arm64 本地 app/harness 组装、plist、ad-hoc Hardened Runtime 与
  strict 签名检查；它不代表 Gate D1 的 Developer ID、公证、Gatekeeper 或 Sparkle
  分发链路已完成。
- Now Playing 与媒体键已接入并有离线测试，但**未在真机验证**：系统播放信息、媒体键与
  蓝牙遥控的实际行为仍需固定 artifact 上的人工矩阵。当前投影不含专辑与封面，因为
  `PlaylistTrack` 没有这两个字段；它们随 canonical Track 与图片管线一起补齐。
- 在 Gate C 与上述真机验证完成前，本项目不称为 internal alpha。
