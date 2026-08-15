# Changelog

All notable changes to DshDesktop are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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