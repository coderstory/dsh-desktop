# Changelog

All notable changes to DshDesktop are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- **Deployment target raised to macOS 25.0** (was macOS 13.0). Unlocks
  `SettingsLink`-era SwiftUI APIs, looser Swift 6 strict-concurrency
  behavior, and `swift-tools-version 6.0` features.
- `AgentIdleWatcher.pollInterval` is now a settable public `var` so
  the running watcher picks up changes from `Preferences` on the next tick.
- `Preferences` no longer `@MainActor`; UI consumers read `@Published`
  properties on main thread automatically via SwiftUI view updates.

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