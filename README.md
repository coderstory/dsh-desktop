# DshDesktop

一个原生 macOS 包装器，把 [`dsh --profile web`](https://github.com/deepseek-ai/deepseek-harness) 的 Web UI 装进 `WKWebView`。wrapper 以子进程方式拉起 dsh、显示 Web UI，并常驻菜单栏——尽量不打扰你的工作。

[![build & test](https://github.com/coderstory/dsh-desktop/actions/workflows/build.yml/badge.svg)](https://github.com/coderstory/dsh-desktop/actions/workflows/build.yml)

## 功能

- **原生窗口** — SwiftUI + `WKWebView`；原生 macOS 交通灯、拖动、缩放等。
- **常驻菜单栏** — 关掉窗口，wrapper 仍在菜单栏存活；点图标 →「Show dsh」即可重新打开。
- **单实例** — 再启动一份会聚焦已有窗口并退出。
- **自动拉起或复用** — 若 dsh 已在配置端口提供服务，wrapper 直接连上而不拉起；否则自行拉起 dsh。
- **健康监测** — dsh 中途挂掉时，wrapper 侦测到端口失效并弹出「dsh stopped responding」遮罩，附 Restart 按钮。
- **系统通知** — dsh agent 完成对您最后一条提示的响应后弹一条 macOS 横幅（在 Settings 中开关）。
- **诊断报告** — `dsh ▸ Save Diagnostic Report…` 把 wrapper 状态（prefs、进程状态、最近 os.log）写成纯文本快照，便于提交 bug 报告。
- **更新 dsh** — `dsh ▸ Update dsh…` 执行 `npm update -g @deepseek-ai/dsh` 并反馈结果。
- **开机启动** — 在 dsh 菜单切换；由 `SMAppService` 支撑（现代做法，不用已废弃的 SMLoginItem）。
- **本地化** — 英文 + 简体中文。

## 环境要求

- macOS 25.0+（Tahoe 或更新）
- Xcode 27+ 工具链（Swift 6.4）
- 已安装 `dsh` 且在 shell 的 `$PATH` 里

## 构建与安装

```bash
./scripts/bundle.sh     # swift build -c release + 组装 DshDesktop.app
./scripts/sign.sh       # ad-hoc 签名
./scripts/dmg.sh        # 可选：打 UDZO DMG 用于分发

# 直接从构建产物运行：
open build/DshDesktop.app

# 或安装到 /Applications：
cp -R build/DshDesktop.app /Applications/
open /Applications/DshDesktop.app
```

## CLI 参数

| 参数 | 作用 |
|---|---|
| `--port <N>` | dsh 监听的 TCP 端口（默认 3080，或来自 Preferences） |
| `--dsh-path <P>` | dsh 可执行文件的绝对路径；跳过基于 shell 的 `which` 查找（若你的 `PATH` 设在 `~/.zshrc` 而 wrapper 的 login shell 不 source 它，请用它） |
| `--no-spawn` | 不拉起 dsh；连到 `--port` 上由外部管理的 dsh |
| `--debug` | 输出详细 os.log（subsystem `ai.deepseek.dsh.desktop`） |
| `--help`、`-h` | 打印帮助并退出 |

未知参数会被静默忽略（这样测试运行器可以传 `--test-bundle-path` 等）。

## 代码里的「设计模式」

| 模式 | 位置 |
|---|---|
| 状态机 | `DshProcess.State`（idle / starting / running / exited / failed） |
| 策略 | `DshLocator` 依次尝试 login shell（zsh、bash）再 `env which` 兜底 |
| 仓储 | `Preferences` 抽象 `UserDefaults` 并做输入消毒 |
| MVVM（轻量） | `DshApp` 以 `@StateObject` 持有 `process` / `prefs` / `idleWatcher`，经 init 传给 `ContentView` |
| 观察者 | `@Published` + SwiftUI `.onChange` 做热重载 |
| 状态 | SwiftUI Window + Settings 窗口、菜单栏用 `NSStatusItem` |
| Sendable | `WhichFunc`、`LoginItemProviding`、`TestHTTPServer` 标注以适配 Swift 6 严格并发 |
| DI | `Preferences.init(defaults:)` 注入 `UserDefaults`；`LaunchConfig.current(preferences:)` 注入 prefs |

## 测试

```bash
swift test                          # 64 个测试，10 个 suite
swift test -Xswiftc -warnings-as-errors
```

## License

MIT。见 `LICENSE`。
