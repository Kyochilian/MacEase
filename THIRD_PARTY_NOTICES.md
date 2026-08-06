# Third-party notices and research ledger

当前最小验证包尚未分发第三方源码或二进制依赖。Apple 系统框架由目标操作系统提供，不在本文件重复列出。

下表是截至 2026-08-06 的研究来源，不表示其代码已被复制或随 MacEase 分发：


| Project                                     | Snapshot / license observation        | MacEase usage                                         |
| ------------------------------------------- | ------------------------------------- | ----------------------------------------------------- |
| `NeteaseCloudMusicApiEnhanced/api-enhanced` | `5b780addbafe`, MIT                   | Endpoint/协议对照和 golden vectors；不嵌入 server、解灰、签到或 IP 功能 |
| `NeteaseCloudMusicAPI-Swift`                | `8626b8fe6281`; README 标注 MIT         | 仅行为与输出对照；澄清前不复制代码                                     |
| `zeyugao/MusicBox`                          | `db1f50859496`; 未发现项目级许可证             | 研究登录、播放和缓存边界                                          |
| `MeloX`, `go-musicfox`, `HyPlayer`          | GPL-3.0                               | 只研究产品行为，独立实现                                          |
| `AMLL`                                      | AGPL-3.0                              | 只研究视觉与数据模型，独立实现                                       |
| `LyricsX`                                   | MPL-2.0                               | 默认仅行为参考；代码复用需逐文件评估                                    |
| `Sparkle 2`                                 | research snapshot `303db889480f`; MIT | 计划用于更新；加入依赖时记录准确版本与许可证                                |


新增 shipping 依赖时必须在合并前补充包名、锁定版本、版权、许可证文本位置、用途和修改情况。详细规则见 [docs/phase0/clean-room.md](docs/phase0/clean-room.md)。