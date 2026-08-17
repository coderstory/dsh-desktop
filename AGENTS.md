# AGENTS.md — DshDesktop 智能体简报

面向任何接手 dsh-desktop 继续开发的 agent（或未来的我自己）。读这个文件
能省下几个小时 "翻 git log + 猜架构 + 试错" 的时间。

## 项目一句话

`DshDesktop` 是一个原生 macOS SwiftUI 包装器，把
[`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness) 的
Web UI (`dsh web`) 装进一个 `WKWebView`。macOS 13+ → 25+，Swift 6 严格并发。

## 关键工程事实

- **包管理**：SwiftPM（`Package.swift`，swift-tools 6.0）
- **部署目标**：`.macOS(.v15)` (macOS 25.0)
- **CFBundleDisplayName**：`DshDesktop`（窗口标题 + Finder/menu bar 名字）
- **CFBundleIdentifier**：`ai.deepseek.dsh.desktop`（保留——package 身份，不变）
- **架构**：MVVM-light，StateObject 单源真相
  - `DshApp` 拥有 `process` / `prefs` / `idleWatcher` 三个 @StateObject
  - `ContentView` 是薄 view，从 DshApp 通过 init 接收
  - `AppDelegate` 单一职责：状态栏项 + 菜单 + 窗口代理
- **状态机**：`DshProcess.State { idle, starting, running, exited, failed(String) }`
- **依赖注入**：`Preferences.init(defaults:)` 接受 UserDefaults；`LaunchConfig.current(preferences:)` 接受 prefs
- **关键模式**：`DshProcess.releaseOwnership()` 把 `ownsChild` 翻成 false，让 `start()` 跳过 spawn

## 严格规则（CRITICAL — 不可违反）

1. **不要启动 DshDesktop.app** — 单实例守护会激活已有实例；但更重要的是，
   dsh 当前正在用户环境里跑，启动 wrapper 会让 spawn 行为走"复用"分支或
   spawn 新进程，**会干扰用户当前的工作流**。如果用户没明确让你启动，
   **不要 `open` 也不要跑 `./scripts/smoke-test.sh`**（那个脚本会 spawn wrapper）。
2. **可以跑** `swift build`、`swift test`、`git` 操作、读文件、写文件、commit。
3. **dsline-chat 的 cordis.patch.yml 是用户手动恢复的** — 它原本是
   `[]`（空数组）导致 dsh 启动失败。我们用 README 里的正确内容覆盖
   修复了。如果再次看到 dsh 启动失败 "failed to read overlay ... dsline-chat/cordis.patch.yml"，
   那是又被覆写了。
4. **禁止使用 subagent_fork 做代码/测试/文档写入** — subagent 适合
   只读调研（grep、读源码、查文档、查 git log）；动手活（写代码、跑
   build/test、commit、改 plan、改 AGENTS.md）必须在主对话里直接做。
   理由：subagent 的中间步骤不透明，review 难度高；多次来回 subagent
   会让上下文分裂，难以保持单一真理源。
   - **额外约束**：禁止把当前会话内容作为子任务的 prompt 来源。
     `subagent_fork` 会把"当前已完成的所有 turn"作为种子上下文传给
     子任务，意味着子任务能看见我们正在讨论的设计、bug、计划——这违反
     "上下文来源显式、可审计"的原则。任何发给 subagent 的任务描述
     **必须自包含**：列出文件路径、列出预期行为、列出成功条件；不要让
     子任务去"理解上下文"或"接着我们的思路做"。

## 用户当前的环境

- **dsh 在跑**（手动启动的外部 dsh，端口 3080）
- **dsh 装了一堆插件**：`dsh-mnemon`（15s 轮询 + rAF，最重）、
  `dsh-community-hot`（轮询）、`dsh-task-status`（2× 轮询）、`dsh-cost-meter`、
  `dsh-client-auto-continue`（3× 一次性 timeout）、`dsline-chat`、
  `dsh-superpowers`、以及 `dsh-*` 命名空间下的更多
- **dsh 配置位置**：`~/.dsh/`，profile 在 `~/.dsh/profiles/web/`
- **项目目录布局**（用户用 `CodeSource/` 做多 repo 根）：
  ```
  /Users/coderstory/CodeSource/
  ├── dsh-desktop/                  # 这个仓库（wrapper）
  └── plugins/                     # 兄弟目录（用户自己管理 dsh 插件）
  ```

> **Wrapper 不再绑定 dsh 插件**（自 `[Unreleased]` 起）。用户自己
> 管理 `~/.dsh/profiles/web/` 下的 dsh 插件。

## 跑命令

```bash
# 测试（不启动 wrapper，安全）
swift test
swift test -Xswiftc -warnings-as-errors

# 构建 + bundle + sign + 装到 /Applications
swift build -c release
./scripts/bundle.sh
./scripts/sign.sh
rm -rf /Applications/DshDesktop.app
cp -R build/DshDesktop.app /Applications/

# **不要** ./scripts/smoke-test.sh（会启动 + kill wrapper + cascade 杀 dsh）
# **不要** open /Applications/DshDesktop.app
```

## 文件结构

```
Sources/DshDesktop/
├── DshApp.swift              # @main + AppDelegate
├── ContentView.swift         # 薄 view
├── DSHWebView.swift          # NSViewRepresentable
├── DshProcess.swift          # 状态机 + spawn 生命周期
├── DshHealthCheck.swift      # 端口探测
├── DshLocator.swift          # 找 dsh binary（login shell fallback）
├── DshHealthMonitor.swift    # 15s 端口 liveness poll
├── HotkeyRouter.swift        # Cmd+C/V/X/A → WKWebView forwarder
├── DSHBridge.swift           # unix domain socket server (RPC: notify, prefs.*) — pending
├── DSHPluginDetector.swift   # cordis.yml/patch.yml inspection + auto-install/reenable
├── AgentIdleWatcher.swift    # DOM 轮询 + 状态机
├── LaunchAtLogin.swift       # SMAppService
├── LaunchConfig.swift        # CLI parser
├── Notifications.swift       # UNUserNotificationCenter
├── Preferences.swift         # UserDefaults 持久化
├── PreferencesView.swift     # Settings scene
├── PerformanceMonitor.swift  # 10s in-page perf poll
├── Diagnostics.swift         # 报告生成
├── ShellRunner.swift         # async shell exec
├── Logger.swift              # os.log 分类
├── Overlays/                 # 视图组件
│   ├── LoadingOverlay.swift
│   └── FailedOverlay.swift
└── Resources/
    ├── en.lproj/Localizable.strings
    ├── zh-Hans.lproj/Localizable.strings
    ├── AppIcon.svg / .icns
    └── MenuBarIconTemplate.svg / .png / @2x.png

# 没有 DshPlugins.swift / 没有 Resources/dsh-plugins/ —— 用户自己管 dsh 插件
└── README.md

scripts/
├── build-icons.sh            # 资源生成
├── bundle.sh                 # swift build -c release + 拼 DshDesktop.app
├── sign.sh                   # ad-hoc 签名（开发者分发前换成 Developer ID）
├── dmg.sh                    # 构建 UDZO DMG（drag-to-Applications UX）
└── smoke-test.sh            # ⚠️ 不用 — 会启动 + kill wrapper
```

## 测试

76 个测试，13 个 suite。**不要为了"完整测试"跑 `smoke-test.sh`**——会启动 wrapper 然后 kill。

```bash
swift test 2>&1 | tail -3
# 期望: 76/76 通过 + -warnings-as-errors clean
```

测试覆盖：
- `DshProcess` (10) — 状态机 + releaseOwnership + start in external mode
- `DshHealthCheck` (4) — waitUntilReady 真实网络栈
- `DshLocator` (4) — 找 dsh binary
- `LaunchConfig` (10) — CLI 解析
- `Preferences` (7) — UserDefaults 持久化 + 输入消毒
- `AgentIdleWatcher` (14) — DOM 轮询 + 状态机
- `LaunchAtLogin` (5) — SMAppService toggle
- `ShellRunner` (4) — async shell exec
- `PerformanceMonitor` (8) — 生命周期 + Codable
- `DshHealthMonitor` (6) — 端口 liveness
- `SmokeTests` (1) — basic compile check

## 实现细节（高价值参考）

- **DshLocator** 用 login shell（`zsh -l -c` + source `~/.zshrc`、`bash -l -c` + source `~/.bashrc`、
  仅 login shell 备份、`npm config get prefix` + check `<prefix>/bin/dsh` 跨 shell、
  最后 `env which` 兜底）。GUI app 从 Finder 启动时 PATH 只有
  `/usr/bin:/bin:/usr/sbin:/sbin`，npm global bin 不可见；
  `zsh -l` 不会 source `~/.zshrc`（interactive config），所以第二个策略显式 source。
  `npm config get prefix` 是不依赖 shell init 的最后兜底。
  用户也可传 `--dsh-path <abs>` 完全跳过 shell 查找。
- **DshProcess.markFailedExternally(reason)** — guard 在 `.exited / .failed` 状态时
  静默忽略。`DshHealthMonitor` 用它把"dsh 死了"转成 .failed。
- **DshProcess.start()**（无 spawn 模式）—— `if ownsChild else { state = .running; return }`。
- **Cordis patch 生成** — wrapper 启动时写 `/tmp/dsh-desktop-bg-throttle-UUID.yml`，
  内容用单引号包绝对路径（`name: '/abs/path/to/index.ts'`），dsh 读后注入插件。
  wrapper 退出时清理 patch 文件。
- **AgentIdleWatcher 改造 v2** —— 不拦截 rAF（浏览器已自动停）、跳过 delay<50ms 的
  setTimeout（微任务不该被冻）、暴露 `protect(id)` API 让关键 plugin 豁免自己的 timer。
  Plugin 测试：用户的 dsh-mnemon / dsh-community-hot / dsh-task-status 的轮询被清，
  dsh-cost-meter / dsh-client-auto-continue / dsline-chat 的一次性 timer 通过。

## 已知不做的（out of scope）

- **Sparkle 自动更新** — 需要 Apple Developer ID 签名
- **公证 (notarization)** — 需要 Developer ID + Apple ID
- **App Store 上架** — 需要完整 metadata + 审核
- **代码签名 Developer ID** — 需要 Apple Developer Program 账号（$99/年）
- **窗口状态独立恢复**（多窗口场景）—— 现在 `setFrameAutosaveName` 用了固定 name，
  多窗口会冲突

## 待做 polish（不缺失，是 nice-to-have）

- ContentView 拆出 DshSession ObservableObject（状态机 + overlay + startFlow 分开）
- AppDelegate 拆 MenuBarController / UpdateController
- SwiftUI Preview 支持
- 可访问性标签（按钮 / 菜单 / overlay）
- 代码覆盖率 + xcrun
- SwiftLint 配置 + pre-commit hook

## Git 约定

- 单 commit per logical change
- commit message 第一行 ≤ 70 字符，body 详细说明 what + why
- `feat:` / `fix:` / `docs:` / `build:` / `refactor:` / `test:` / `chore:` 前缀
- 不用 emoji，不用 Co-Authored-By

## 提交历史摘要

到目前为止 17+ 个 commit，分成几个主题：
- Tasks 1-7：原始 7 个 phase（WKWebView 包装、菜单、preferences、health、perf、single-instance、diagnostics、smoke-test）
- Phase 8-10：i18n、CI、Settings UI
- macOS 25 升级：deployment target + swift-tools 6
- bg-throttle dsh 插件：v1 + v2（含 rAF 不拦截 + protect API）
- Plugin 移到 `../plugins/`

## 性能基线

```
Build:  ~7秒  (swift build -c release)
Test:   ~0.7秒  (77 tests, 13 suites)
Bundle: ~2秒
Install: copy 操作
```

## DSH Bridge Protocol（dsh 插件 ↔ wrapper IPC）

Phase 1+：未来 wrapper 通过 unix domain socket 暴露少量 RPC 给 dsh 插件，
让插件用 dsh driver 的权威 `agent/status` 事件触发原生通知，替代 wrapper
之前那个不可靠的 DOM `data-streaming` 探针。

**位置**：`~/Library/Application Support/ai.deepseek.dsh.desktop/bridge.sock`
（macOS；Linux 暂未实现）。**协议版本**：`bridge-v1`，JSON-RPC 风格 + NDJSON。

**当前 RPC 方法**：
- `hello({protocol: 1})` → 客户端握手；不匹配版本即断
- `notify({title, body})` → 弹原生通知
- `prefs.get({key})` / `prefs.set({key, value})` → wrapper 持久化 prefs

**判据**：插件监听 `agent/status` 事件（dsh driver 的
`@deepseek-ai/dsh-agent-loop/lib/index.js` 在 turn 边界处 emit
`{ status: 'idle' | 'running' }`），`busy → idle` 转换时调 `notify`。
**严禁在 wrapper 里继续读 DOM `data-streaming`**——那是"乱发"的根因。
payload 字段名是 `status`（字符串），不是 `running`（布尔）——这是从
dsh 源码 grep 确认过的，之前子任务猜错过。

**插件存在性**：`DSHPluginDetector` 在每次 `DshApp.init()` 同步跑一次，五种
状态（`.installedCurrent` / `.installedOutdated` / `.notInstalled` /
`.disabled` / `.brokenPath`）。init() 路径只做**非阻塞**检测 +
自动 install（仅对安全的 `.notInstalled`），不弹 alert——NSAlert.runModal()
在 SwiftUI 早期启动 window race 时会卡住整个 launch sequence（已修，见
下方 LaunchPathTests）。交互式 alert 仍保留，但**只**走控制菜单 ▸
Check Bridge Plugin… 路径。`.notInstalled` / `.disabled` 时 wrapper
自动写 patch（用户在 alert 里点 Install / Re-enable）。

**Do not regress this**: `Tests/DshDesktopTests/LaunchPathTests.swift` 用文本
guard 锁住"init() 不许引用 NSAlert / runModal / checkBridgePluginAndAlertIfNeeded"。
如果未来要把 alert 加回 init()，先想清楚怎么安全地 post 到主 runloop（`DispatchQueue.main.async` + `RunLoop.main.perform` 之类）再改。

完整设计：`docs/superpowers/plans/2026-08-17-dsh-desktop-bridge.md`。
插件 shell：兄弟仓库 [dsh-plugins/dsh-desktop-bridge](https://github.com/coderstory/dsh-plugins/tree/main/dsh-desktop-bridge)，
本仓库只通过 unix-domain socket 与之通信。

## 故障排查

| 症状 | 原因 / 修复 |
|---|---|
| 通知乱发（在工具调用之间、状态抖动时弹通知）| 老的 DOM `data-streaming` 探针路径。装上 dsh-desktop-bridge 插件并启用（启动时 alert 点 Install，然后**手动重启 dsh**让 patch 生效）。详见 DSH Bridge Protocol 节。|
| dsh 启动失败 "failed to read overlay ... cordis.patch.yml" | 用户的 dsline-chat 插件 cordis.patch.yml 被覆写为空 `[]`。修复：写入 README 里的正确内容 |
| GUI app 找不到 dsh | DshLocator 用 login shell 查找；如果还失败，看 os.log 的 `dsh-desktop` subsystem |
| 端口 3080 已占用 | wrapper 的 pre-check 应检测到并 releaseOwnership 复用 |
| 单实例守护失效 | 查 `Bundle.main.bundleIdentifier` 是否是 `ai.deepseek.dsh.desktop`（Info.plist）|
| bg-throttle 没加载 | dsh 启动日志里找 `[bg-throttle v2] loaded`；patch 文件路径要绝对 |

## 联系 / 引用

- dsh 源码：`/Users/coderstory/.global-npm/lib/node_modules/@deepseek-ai/dsh/`
- dsh 用户配置：`/Users/coderstory/.dsh/`
- 兄弟插件 repo：`/Users/coderstory/CodeSource/plugins/`
- 之前的 spec/plan 文档：`docs/superpowers/specs/` + `docs/superpowers/plans/`
