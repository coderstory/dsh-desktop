# DSH Desktop Bridge — 计划

## 背景

DshDesktop wrapper 当前用 `AgentIdleWatcher` 通过 WKWebView 的 JS 探针读 DOM
`data-streaming` 标志判定 agent 是否在响应，闲置时通过 `UNUserNotificationCenter`
弹原生通知。问题是判据不可靠（DOM flag 在工具调用/多 agent/插件干扰下会假
idle → "乱发"）。

本次**不修复 wrapper 内的判据**——把判据迁移到 dsh 插件，让插件监听 dsh driver
的**真实 agent 状态事件**（`agent/status`），通过 IPC 让 wrapper 弹原生通知。

## 调研发现（2026-08-17）

参考 dsh 官方文档（`docs/agent-lifecycle.md`、`docs/architecture.md`、
`docs/user/develop/basic/index.zh.md`、`docs/user/develop/framework/events.zh.md`）：

- **插件形态**：TS module，`export const name` + `export function apply(ctx: Context, config?)`
- **类型导入**：`import type { Context } from '@deepseek-ai/cordis'`（type-only，零运行时依赖）
- **本地插件注册**：cordis.yml 用 `- insert:` + 绝对路径
- **agent finished 信号**（精确）：`agent/status` event，driver 在 turn start 时发
  `{ running: true }`，turn end 时发 `{ running: false }`——这是**框架级权威事件**
- **生命周期清理**：`ctx.effect(() => () => cleanup)` 在插件 unload 时自动调用

插件可监听到 `agent/status` 比读 DOM `data-streaming` **可靠性高一个数量级**——后者
是 UI 状态，前者是 driver 的真实状态机。这同时解决了"乱发"的根因。

## 设计目标

1. wrapper 和 dsh 插件之间有**稳定的双向 IPC**（unix domain socket）
2. wrapper 暴露少量 RPC（**当前只 4 个**，够完成通知用），未来扩展留口
3. 通道本身**不耦合**任何具体业务逻辑——只做消息路由
4. wrapper 重启 / dsh 重启都能**优雅重连**
5. 协议简单到能 1 小时讲清，无第三方依赖

## 非目标（明确不做）

- 不搬 WKWebView 包装、Cmd+C/V/X/A forward、启动 dsh、健康检查、菜单栏、
  LaunchAtLogin、SettingsView 到插件——这些必须留在 native
- 不修改 idle 判定逻辑本身（判据重写是下一轮，本次只换触发点）
- 不发布 npm 包（`../plugins/` 本地路径引用就够了）
- 不做 HTTP 通道（unix socket 简单可靠，HTTP 端口冲突 + CORS 是麻烦）
- 不做消息加密（`127.0.0.1` 同机 + dsh 信任链够用）

## 架构

```
┌─────────────────┐  unix socket    ┌──────────────────────┐
│  dsh 插件         │ ───────────────▶│  DshDesktop wrapper │
│  dsh-desktop-    │  JSON-RPC/      │                      │
│  bridge          │  NDJSON         │  DSHBridge.swift     │
│                  │ ◀───────────────│  (NSSocket server)   │
│  - 判据 (未来)    │                 │                      │
│  - 触发 notify   │                 │  - UNUserNotification │
└─────────────────┘                 │  - 单实例 socket bind │
                                    └──────────────────────┘
```

### 通道选型：Unix domain socket

- 文件位置：`~/Library/Application Support/ai.deepseek.dsh.desktop/bridge.sock`
- 不用 `/tmp`——避免系统清理 + 多用户冲突
- 协议：**JSON-RPC 风格 + NDJSON**（一行一 JSON 对象）
- 单 socket 多连接并发；每连接 `readline` 解析

### RPC 方法（第一阶段只 4 个）

| 方法 | 方向 | params | 用途 |
|---|---|---|---|
| `hello` | client → server | `{protocol: 1}` | 握手；版本不匹配则断开 |
| `notify` | client → server | `{title, body}` | 弹原生通知 |
| `prefs.get` | client → server | `{key: "notificationsEnabled"}` | 读 wrapper 持久化 pref |
| `prefs.set` | client → server | `{key, value}` | 写 wrapper 持久化 pref |

响应格式（标准 JSON-RPC 2.0）：

```json
{"jsonrpc":"2.0","id":1,"result":true}
{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}
```

### 关键不变量

1. **单 socket bind**——EADDRINUSE 立即报错（与 wrapper 单实例守护共存）
2. **启动时清理残留**——发现 `bridge.sock` 但无 listener，先验证再删除
3. **连接上限**——单 wrapper 最多 16 个并发连接
4. **消息大小限制**——每条 ≤ 1 MiB（防插件拖死 wrapper）
5. **协议握手**——客户端连上后第一条必须是 `hello`，否则 1s 后断开
6. **优雅断开**——wrapper 退出前给所有连接发 `goodbye` 事件 + 200ms
   清理时间，再 unlink socket
7. **socket 文件权限**——`0600`（仅当前用户）

## 文件改动

| 文件 | 操作 | 行数估算 |
|---|---|---|
| `Sources/DshDesktop/DSHBridge.swift` | 新增 | ~250 |
| `Sources/DshDesktop/Notifications.swift` | 改 1 处（注入 bridge 引用） | ~10 |
| `Sources/DshDesktop/AgentIdleWatcher.swift` | 不动（仍用 `Notifications.notify`，未来插件直接调 bridge 时删） | 0 |
| `Sources/DshDesktop/DshApp.swift` | 改 1 处（`init` 启动 bridge） | ~5 |
| `Tests/DshDesktopTests/DSHBridgeTests.swift` | 新增 | ~200 |
| `AGENTS.md` | 追加"bridge 协议"章节 | ~30 |
| `CHANGELOG.md` | 追加 Unreleased 条目 | ~5 |
| `/Users/coderstory/CodeSource/plugins/dsh-desktop-bridge/` | 新增插件（package.json + index.ts + README） | ~250 |
| **合计** | | **~750 行（含测试 + 文档）** |

## 实施步骤

### Phase 0（已完成）：插件存在性检测 + 安装/恢复机制

在用户允许"未来渐进迁移"之前，wrapper 必须能在启动时自动确认插件到位，
否则第一步迁移就会断通知。这块已经做完：

- `Sources/DshDesktop/DSHPluginDetector.swift`（约 280 行）：
  - 读 `~/.dsh/profiles/web/cordis.yml` 和 `cordis.patch.yml`，
    自实现的 YAML patch-row tokenizer（不依赖 Yams）
  - 五种判定状态：`.installedCurrent` / `.installedOutdated` /
    `.notInstalled` / `.disabled` / `.brokenPath`
  - `installPatchEntry(at:)` 和 `reenablePatchEntry(at:)` 两个公开 mutator
- `Sources/DshDesktop/DshApp.swift::checkBridgePluginAndAlertIfNeeded()`：
  - `DshApp.init()` 末尾同步调用一次
  - 控制菜单加 "Check Bridge Plugin…" 手动重新触发
  - 五种状态各自有 NSAlert 反馈；`.notInstalled` 和 `.disabled` 提供
    "Install" / "Re-enable" 按钮让 wrapper 自己写 patch
- `Tests/DshDesktopTests/DSHPluginDetectorTests.swift`：13 个测试覆盖
  五种状态、multi-field inline YAML、install 幂等、reenable 行内翻转、保留
  用户原有内容

### Phase 1: wrapper 端 bridge server

1. `DSHBridge.swift`：socket path 解析、`socket()` + `bind()` + `listen()`、
   accept loop、NDJSON 读、`hello` 握手、RPC dispatch、连接池
2. `DshApp.swift`：`init()` 末尾启动 bridge（早于窗口显示）
3. 单元测试：mock socket、4 个 RPC、握手失败、断连重连

### Phase 2: wrapper 端通知改造（最小改动）

- 第一阶段**不改 `AgentIdleWatcher`**——它继续通过 `Notifications.notify`
  触发。这保证了**既有行为不变**，bridge 是 additive capability
- 第二阶段（未来的 PR）让插件调 `notify`，wrapper 端逐步废弃 watcher

### Phase 3: dsh 插件

1. `plugins/dsh-desktop-bridge/package.json`：cordis plugin 入口
2. `plugins/dsh-desktop-bridge/index.ts`：
   - 启动时连 `bridge.sock`，发 `hello`
   - 重连退避（1s → 2s → 5s → 10s 封顶）
   - 暴露 `client.notify(title, body)` API
   - 暂时**不接判据**——只暴露 API，留 `console.log('hello from bridge')` 占位
3. README：说明在 `~/.dsh/profiles/web/cordis.yml` 里挂上

### Phase 4: 集成验证

**macOS-friendly sandbox runner** at `dsh-plugins/dsh-desktop-bridge/test/sandbox/run.mjs`:
spins up dsh + the plugin in an isolated `DSH_HOME` under `/tmp/`,
polls the port, asserts the plugin loads. Inspired by
[Sutera-Diffusus/dsh-sandbox-tester](https://github.com/Sutera-Diffusus/dsh-sandbox-tester)
but stripped of the Windows-only `robocopy` / `PowerShell` /
`Get-NetTCPConnection` layers. The sandbox caught two real integration
bugs that the unit tests missed (see plugin repo's commit `fdd4ab0`).

End-to-end manual check (requires user to actually launch the wrapper):
  - `log show --predicate 'subsystem == "ai.deepseek.dsh.desktop"' --last 5m`
    should show "DSHBridge: listening on …" on launch and the matching
    `onQuit` line on quit
  - In dsh, run a small task end-to-end; on completion the macOS
    notification banner should appear (the bug that motivated the
    whole rewrite)

## 风险与回滚

| 风险 | 缓解 |
|---|---|
| socket 文件权限 / sandbox 问题 | macOS GUI app 在 user session，`0600` 应该 OK；如失败降级到 0700 + group |
| `Application Support` 目录首次写时被 sandbox 拦 | wrapper 已在写 `~/Library/Application Support/ai.deepseek.dsh.desktop/` 吗？查一下 |
| 插件连不上 bridge | wrapper 进程挂了？socket 残留？给出明确的错误日志 |
| 协议版本不同步 | `hello` 时传 `protocol: 1`，wrapper 返回协议版本，客户端不兼容则断 |
| 端口冲突 | 不适用（用 socket 文件） |

回滚：删 `DSHBridge.swift` + 移除 `DshApp.init()` 调用，wrapper 回到无 bridge 状态。
插件独立存在，不影响 wrapper。

## 测试策略

### Unit（swift test）

- `DSHBridgeTests`：
  - `testHelloMissing_closesConnection`
  - `testHelloProtocolMismatch_closesConnection`
  - `testNotify_returnsTrue`
  - `testNotify_routesToUNUserNotificationCenter`（用 mock）
  - `testUnknownMethod_returnsError`
  - `testMessageTooLarge_disconnects`
  - `testBindError_whenSocketInUse`
  - `testGracefulShutdown_sendsGoodbye`

### 集成（用户手测）

- 启动 wrapper，启 dsh，确认插件连上（日志）
- 在插件手动触发 `client.notify('test', 'bridge works')`
- 验证 wrapper log + 系统通知横幅

### 不做的测试

- 不模拟 dsh 内部事件总线（要 dsh 源码支持，太重）
- 不做压力测试（最多 16 连接 × 几 Hz 调 notify 不需要）

## 验收标准

- [ ] `swift test` 67 + 新增 ≥ 8 = 75+ 全过；`-warnings-as-errors` 干净
- [ ] `swift build -c release` 干净
- [ ] bundle + sign + 装到 `/Applications/`
- [ ] 启动后 `log show` 看得到 `DSHBridge: listening on ...bridge.sock`
- [ ] 插件启起来后 `log show` 看得到 `bridge: connected (protocol=1)`
- [ ] 插件手动调 `notify` 能弹系统通知

## 后续（不在本次范围）

1. 插件侧接入判据：监听 dsh 事件总线判定 agent finished → 调 `notify`
2. 删除 wrapper 的 `AgentIdleWatcher`（被插件取代）
3. 暴露更多 RPC：`dsh.restart`、`dsh.update`、`prefs.get/set` 全套
4. 单进程多 dsh 实例支持（目前 wrapper 是单实例守护，bridge 也跟着单实例）