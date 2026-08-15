# Changelog

All notable changes to DshDesktop are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- **`DshLocator.whichDefault` uses login shell** (`zsh -l -c "command -v dsh"`,
  then `bash -l -c …`, then plain `env which dsh` as fallback). GUI apps
  launched from Finder/Dock inherit a minimal PATH missing npm-global
  bin (e.g. `~/.global-npm/bin`); login shells source `~/.zshrc` /
  `~/.bash_profile` and expose the full user PATH. Fixes "dsh not found"
  on launch even when dsh is installed.

### Added
- **`Preferences.pausePollingWhenHidden`** — when ON, `AgentIdleWatcher`
  polling is paused when the main window is hidden (close button) and
  resumed on `windowDidBecomeKey`. Saves the (negligible) polling CPU
  during background; dsh's own plugin CPU is unaffected — the help
  string is explicit about this.
- **`AgentIdleWatcher.pause()` / `start()`** — pause/resume the polling
  task without touching `state`. Idempotent.

### Changed
- **Deployment target raised to macOS 25.0** (was macOS 13.0). Unlocks
  `SettingsLink`-era SwiftUI APIs, looser Swift 6 strict-concurrency
  behavior, and `swift-tools-version 6.0` features.
- `AgentIdleWatcher.pollInterval` is now a settable public `var` so
  the running watcher picks up changes from `Preferences` on the next tick.
- `Preferences` no longer `@MainActor`; UI consumers read `@Published`
  properties on main thread automatically via SwiftUI view updates.
- **Refactored file structure** — `Sources/DshDesktop/` now has
  subdirectories: `Overlays/` (LoadingOverlay, FailedOverlay) and
  `WebView/` (DSHWebView+IdleProbe). Single-responsibility views,
  WKWebView idle-probe JS centralized in a typed extension
  (`WKWebView.dshIsAgentStreaming()`).
- **Refactored ownership** — `DshApp` now owns `process`, `prefs`,
  and `idleWatcher` as `@StateObject` (single source of truth) and
  passes them to `ContentView` via init. Hot-reload
  (`.onChange(of: prefs.pollingIntervalSeconds)`) fires in `DshApp.body`.
- **DshProcess supports ownership release** — `releaseOwnership()` flips
  `ownsChild` from true to false for pre-check reuse (see
  `ContentView.startFlow`).
- `ContentView.startFlow` does a 1.5s pre-check on port 3080 (or
  configured port) — if dsh is already serving, releases ownership and
  reuses the existing instance instead of spawning. Matches the original
  "if 3080 refused, first launch dsh web" requirement.

### Added
- **`Settings` scene** with `PreferencesView` (port field, notifications
  toggle, polling-interval slider, Reset to Defaults). Opens via Cmd+,.
- `LaunchConfig.port` is now `Int?`; `resolvedPort` falls back to
  `Preferences.shared.port` when no CLI override.
- `Preferences` model: persists port / notificationsEnabled /
  pollingIntervalSeconds to UserDefaults with input sanitization
  (range clamp + port bounds).
- `DshLocator.WhichFunc` is now `@Sendable` (Swift 6 strict-concurrency).
- `TestHTTPServer` is `@unchecked Sendable` (Swift 6 strict-concurrency).
- `PreferencesTests` (7 tests): defaults, persistence, invalid-value
  sanitization, range clamping, reset.
- `MutableFlag` test helper for shared-mutable-Bool across closures.

### Fixed
- `onChange(of:perform:)` migrated to two-arg form (macOS 14+ API).
- `DshLocator.whichDefault` / `Preferences.shared` sendability for
  Swift 6 concurrency.

## [Unreleased]
- Custom app icon and menu bar icon (Design C: connected nodes + amber "d")
- Menu restructure: `dsh` (Restart / Refresh / Update) + `Quick Links` (GitHub Repo)
- NSStatusItem (menu bar icon) with custom template image
- Window close hides window; menu bar icon + "Show dsh" reopens
- ShellRunner helper for async shell command execution (TDD, 4 tests)
- `dsh ▸ Update dsh…` menu item (runs `npm update -g @deepseek-ai/dsh`)
- `scripts/build-icons.sh` regenerates icon assets from SVG sources
- `scripts/dmg.sh` produces UDZO read-only DMG with Applications link
- System notification when dsh agent finishes responding (Task 8)
- LICENSE (MIT) and CHANGELOG

### Changed
- Menu bar icon is now a custom template image (auto light/dark)
- Window close no longer terminates app (`applicationShouldTerminateAfterLastWindowClosed = false`)
- App icon path: `Sources/DshDesktop/Resources/AppIcon.icns`

## [0.1.0] - 2026-08-15

### Added
- Initial release: Swift Package wrapping `dsh --profile web` on port 3080
- SwiftUI scene with WKWebView + starting/waiting/failed overlays
- `DshProcess` (child Process lifecycle + state machine, TDD)
- `DshHealthCheck` (port polling, TDD with Network.framework test server)
- `scripts/bundle.sh` + `scripts/sign.sh` (ad-hoc signed .app)
- 19 tests across 3 suites (`swift test -warnings-as-errors` clean)