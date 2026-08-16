# DshDesktop 改动说明（供技术评审）

这份文档梳理本会话对 DshDesktop（原生 macOS SwiftUI 包装器，把
`@deepseek-ai/dsh` 的 Web UI 包进 WKWebView）所做的全部改动，按三个问题
分节。目的是给接手评审的人足够的背景、证据，以及我尚未下定论的疑点。

当前工作区改动（未提交）：

```
 M Sources/DshDesktop/AgentIdleWatcher.swift     （通知误报修复）
 M Sources/DshDesktop/DshApp.swift               （菜单裁剪 + 观察者）
 M Sources/DshDesktop/DshProcess.swift           （外部模式重启接管）
 M Tests/DshDesktopTests/AgentIdleWatcherTests.swift
 ?? Tests/DshDesktopTests/ReproRestartExternalTests.swift
```

测试基线（改动后）：67 个测试 / 11 suite 全过；`swift build -Xswiftc -warnings-as-errors` 干净。

---

## 1. 菜单 "Restart dsh" 点击没反应

### 现象
- 用户在菜单栏「控制 → Restart dsh」点击，看起来"什么都没发生"。

### 排查结论（重要）
- **根本没有代码 bug**。菜单 action `Task { await process.restart() }`
  正常触发，`restart()` = `stop()` + `start()` 也正常执行。
- 实测证据（统一日志，供复现）：用户连点 3 次，每次都成功杀旧 dsh 再起新 dsh：

  ```
  22:37:31  restart() owned → stop() terminating pid 57520 → start() done
  22:37:34  restart() owned → stop() terminating pid 57534 → start() done
  22:37:35  restart() owned → stop() terminating pid 57546 → start() done
  ```
  每次耗时约 0.1 秒（每次都是：杀进程 → 立即重 spawn → WebView 无缝重连）。
- **"没反应"的真相**：重启太快，浏览器来不及显示中断/重载，页面无缝重连，
  看起来就像没点。判定依据是 dsh 的 PID 每次都在换（如 57520→57534→57546→57556）。

### 附带真实改动（保留）
`Sources/DshDesktop/DshProcess.swift` 新增 `restartExternal()`（+63 行）：

- **根因（这里确实有改进空间）**：当包装器处于外部模式（`ownsChild == false`，
  启动时 pre-check 发现 3080 已被别的 dsh 占用而 `releaseOwnership()`），
  原来的 `restart()` 走 `stop()+start()`，两函数开头都是
  `guard ownsChild else { return }` → **外部模式下 Restart 是静默 no-op**。
- **修复**：`restart()` 增加分支——外部模式下调用 `restartExternal()`：
  1. 用 `lsof -tiTCP:<port> -sTCP:LISTEN` 找到占用端口的 PID；
  2. 发 SIGTERM，等待端口释放，超时升 SIGKILL；
  3. 置 `ownsChild = true` 接管，然后 `start()` 自己 spawn 一个新的 dsh。
- **效果**：无论 dsh 是包装器 spawn 的还是外部终端起的，菜单 Restart 现在都真正重启。
- **注意/成本**：这会让包装器在外部模式下点 Restart 时**强杀终端里那个 dsh 进程**，
  违背原 AGENTS.md "不干扰用户手动跑的 dsh"的设计取向——用户明确要求 Restart 生效，
  故覆盖。

- 新增测试 `Tests/DshDesktopTests/ReproRestartExternalTests.swift`：
  起一个真实 python3 http.server 监听测试端口，用外部模式 `ownsChild=false` 的
  `DshProcess` 调 `restart()`，断言：杀掉原监听器 + `ownsChild` 翻 true + 重新 spawn。

---

## 2. 通知功能乱发（任务还在执行就通知）

### 根源
探针（`Sources/DshDesktop/WebView/DSHWebView+IdleProbe.swift`）：

```js
document.querySelector('[data-streaming="true"]') !== null
```

这个 `data-streaming` 属性来自 dsh 前端
`@deepseek-ai/dsh-client-ui-conversation`，源码关键行（lib/client.js）：

```js
// AssistantNodeView → AssistantMarkdown
"data-streaming": streaming || void 0,
// streaming 的真值来源：
streaming: data.status === "running",
```

**结论**：`data-streaming` 只在某个 assistant 消息节点 `data.status === "running"`
（即正在流式输出 markdown）时才挂到 DOM 上。推理阶段、工具调用间隙、该消息
已结算（`completed`/`interrupted`）时，属性消失 → 探针返回 false（表现为 idle）。

原 `AgentIdleWatcher.tick()` 逻辑"一个 busy→idle 转变就立即发通知"，于是
推理/工具间隙的短暂 idle 读就会被误判成"完成"，提前通知。

### 修复（`Sources/DshDesktop/AgentIdleWatcher.swift`）
加"防抖确认"：

- 新增 `idleConfirmationPolls`（默认 `2`，即需连续 2 个 idle 轮询才算完成，
  按 5s 轮询约 10s）。
- 新增 `idleStreak` 连续 idle 计数，遇 busy 立即归零 → 短暂间隙不再触发。
- 新增 `everBusy` 守卫：从未 busy 过（打开直接 idle）不发通知，避免"一打开就报完成"。
- `reset()`（页面重载时）同步清零 `idleStreak` 与 `everBusy`。

### 测试
`Tests/DshDesktopTests/AgentIdleWatcherTests.swift` 新增 2 个：
- `idleGap_busyIdleBusy_doesNotFireNotification`：短暂 idle 间隙（busy→idle→busy）
  不通知。
- `sustainedIdle_persistsAcrossConfirmations_fires`：持续 idle 跨过确认窗才通知。

### 待确认/悬而未决
- **防抖只缓解症状，未根治**。可靠判断"整个会话/busy"的全局信号仍不明确：
  我搜遍 dsh 前端，`data-streaming` 是唯一可用的 `data-*` streaming 指示，
  `data.status` 是**单条消息**的结算状态，不是会话级工作状态。
  若想更准，需要确认 dsh 是否有"整个 agent 还在干活"的 DOM 信号（如 stop 按钮
  可见性、会话级 running 状态）。目前默认只做了防抖（用延迟换准确）。

---

## 3. 系统菜单（帮助/窗口/显示）没删掉

### 根源
macOS 给所有窗口 app 自动加「文件/编辑/窗口/帮助」（中文环境对应
帮助/窗口/显示）。SwiftUI 的

```swift
CommandGroup(replacing: .newItem) {}
CommandGroup(replacing: .windowList) {}
CommandGroup(replacing: .help) {}
```

**只会清空这些菜单的内容，不会删除菜单本身**（AppKit 仍保留 Help/Window 顶级菜单）。

已有 `DshApp.pruneAutoMenus()` 想从 `NSApp.mainMenu` 硬删，但只靠启动时一次调用，
存在时序问题。

### 证据（统一日志，注意级别已提升）
`pruneAutoMenus` 的 BEFORE/AFTER 日志（运行中真实抓取）：

```
BEFORE menu[0]=DshDesktop menu[1]=显示 menu[2]=控制 menu[3]=Quick Links
       menu[4]=窗口 menu[5]=帮助
removing submenu 显示
removing submenu 窗口
removing submenu 帮助
AFTER — DshDesktop, 控制, Quick Links
```

即：patch 后启动那一刻菜单栏只剩 `DshDesktop / 控制 / Quick Links`，三个系统菜单
确实删了。**但用户重开后仍看到 3 个菜单**，说明 AppKit/SwiftUI 在窗口激活 / scene
重建时又把它插回来了（prune 只在启动跑了有限次）。

### 修复（`Sources/DshDesktop/DshApp.swift`，进行中，本版尚未重装验证）
- 启动时先 `pruneAutoMenus()` 一次；
- 新增 `armPruneObserver()`：监听 `NSMenu.didAddItemNotification`（`NSApp.mainMenu`
  被插入 item 时触发），每次插入即重新 prune，保证无论 AppKit 何时插回都删掉。

### 待确认/悬而未决
- 该 observer 方案**已写入代码但尚未重新打包安装实机验证**（本版改动到一半，
  编译通过但没重装）。需要重新 build+bundle+sign+reinstall 并让用户重开验证。
- 若 `NSMenu.didAddItemNotification` 的 object 传 nil 时带 userInfo 的"菜单"键，
  应进一步限定只处理 mainMenu，避免全系统菜单 item 变化都触发 prune（轻微浪费）。

---

## 通用备注
- 全程遵守项目 AGENTS.md：未启动 wrapper（避免干扰用户当前运行的 dsh）、
  没用 `smoke-test.sh`。
- 未 commit，等评审/用户确认后再按项目 git 约定提交。
