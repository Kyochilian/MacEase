# 测试

所有测试完全离线：不发网络请求，不启动 AppKit / WebKit / AVPlayer。
唯一的例外是 `NeteaseKitTests` 中的 Keychain 测试，它们在随机 service 名下
读写自己的临时 item 并在结束时删除。

## 运行

```sh
cd Packages/MacEaseCore
swift test
swift test -c release
swift build -c release
```

`scripts/check_links.sh` 校验 README 与 `docs/` 中的相对链接和脚本路径都存在。
`scripts/check_status.sh` 只核对 `docs/status.md` 中记录的测试数量；无参数时自己重跑
两套测试，CI 则用 `--debug-count` / `--release-count` 传入它已经测得的数字，避免第二
次全量构建。它不验证其它状态字段。
`scripts/check_parity.sh` 校验 `docs/backend-parity.md` 的每个状态格都取自其状态词表，
且汇总计数与各表一致。

## 目标划分

| Target | 覆盖 |
|---|---|
| `NeteaseKitTests` | 请求 golden 字节、响应分类、加密向量、不可信输入、凭据不变量 |
| `MacEaseAppCoreTests` | 操作仲裁、会话迁移、分页与曲目一致性、播放恢复、协调器守卫 |

## 必须保持的性质

这些不是实现细节，改动它们需要单独理由：

- **请求 golden 字节不变。** 任何重构都不得改变已锁定的请求体。修改端点合同
  必须同时更新 golden test 并记录一手证据。
- **不可信输入只分类不终止。** 非 HTTP 响应、非法 Keychain 内容、空/截断/超大
  压缩体、错误长度的密钥都返回 typed error。
  验收：`grep -RInE 'as!|try!|precondition\(|fatalError\(' Packages/MacEaseCore/Sources`
  在 Sources 下无结果。
- **fail-closed preflight / postflight。** 请求前后各校验一次 Keychain 与已验证
  账号一致，不一致就不发请求 / 不发布结果。
- **零自动重试。** 失败一次即停并显示分类结果。
- **generation / intent token 防迟到写回。** 被取代的任务不得写状态。
- **已发出的写不被静默取消。** 结果不明时进入 `outcomeUnknown`，既不报成功也不报失败。

## live 请求

默认预算为 0。任何 live 检查都需要维护者显式触发，使用专用测试账号，并事先固定：
提交 SHA、请求数上限、停止条件。结论回写到 `docs/status.md` 与
`docs/endpoint-registry.md`。
