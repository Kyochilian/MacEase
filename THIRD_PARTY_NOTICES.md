# Third-party notices and research ledger

当前最小验证包尚未分发第三方源码或二进制依赖。Apple 系统框架由目标操作系统提供，不在本文件重复列出。

下表是 2026-08-06 的研究快照，不表示其代码已被复制或随 MacEase 分发：

| Project | Snapshot / license observation | MacEase usage |
|---|---|---|
| [`api-enhanced`](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced) | `5b780addbafe`, MIT, 2026-08-06 | Endpoint/协议对照和 golden vectors；不嵌入 server、解灰、签到或 IP 功能 |
| [`NeteaseCloudMusicAPI-Swift`](https://github.com/Lincb522/NeteaseCloudMusicAPI-Swift) | `8626b8fe6281`, README 标注 MIT 但无许可证正文, 2026-08-06 | 仅行为与输出对照；澄清前不复制代码 |
| [`MusicBox`](https://github.com/zeyugao/MusicBox) | `db1f50859496`, 未发现项目级许可证, 2026-08-06 | 研究登录、播放和缓存边界 |
| [`MeloX`](https://github.com/youshen2/MeloX), [`go-musicfox`](https://github.com/go-musicfox/go-musicfox), [`HyPlayer`](https://github.com/HyPlayer/HyPlayer) | GPL-3.0, observed 2026-08-06 | 只研究产品行为，独立实现 |
| [`AMLL`](https://github.com/amll-dev/applemusic-like-lyrics) | AGPL-3.0, observed 2026-08-06 | 只研究视觉与数据模型，独立实现 |
| [`LyricsX`](https://github.com/ddddxxx/LyricsX) | MPL-2.0, observed 2026-08-06 | 默认仅行为参考；代码复用需逐文件评估 |
| [`Sparkle 2`](https://github.com/sparkle-project/Sparkle) | `303db889480f`, MIT, 2026-08-06 | 计划用于更新；加入依赖时记录准确版本与许可证 |
## Provenance rules

- Lock source URL, commit/date, and license before merging protocol-critical work.
- Do not copy code, comments, tests, structure, or assets from missing-license,
  GPL/AGPL, or otherwise incompatible sources into the MIT shipping target.
- Compatible-license reuse must retain copyright, license, purpose, and modification
  records; otherwise implement independently with Apple frameworks and repeatable
  vectors.
- AI output is a draft, not protocol or license evidence. Source updates require a new
  recorded validation rather than silent code synchronization.

新增 shipping 依赖时必须补充包名、锁定版本、版权、许可证文本位置、用途和修改情况。
