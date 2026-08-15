# DshDesktop

A minimal native macOS wrapper around the `dsh --profile web` service.

## Requirements

- macOS 13 or later
- Xcode 15+ (for Swift 5.9 toolchain)
- `dsh` installed and available on `$PATH`

## Build

```bash
./scripts/bundle.sh     # swift build -c release + assemble DshDesktop.app
./scripts/sign.sh       # ad-hoc sign
open build/DshDesktop.app
```

## Test

```bash
swift test
```

## What it does

Spawns `dsh --profile web` as a child process and shows the web UI inside a
`WKWebView` in a SwiftUI window with title "dsh". Hardcoded to port 3080.

## Layout

```
Sources/DshDesktop/
  DshApp.swift          # @main, menu, lifecycle
  ContentView.swift     # ZStack with WebView + starting/failed overlays
  DSHWebView.swift      # WKWebView wrapper
  DshProcess.swift      # child Process + state machine
  DshHealthCheck.swift  # port 3080 polling

scripts/
  bundle.sh             # SwiftPM output → .app bundle
  sign.sh               # ad-hoc sign

Tests/DshDesktopTests/
  DshProcessTests.swift
  DshHealthCheckTests.swift
  SmokeTests.swift
```

## Notes

- First run requires right-click → Open (Gatekeeper on ad-hoc-signed apps).
- `dsh` must be on `$PATH` inherited from your shell — if you launch from Finder
  and `dsh` is only in `.zshrc`, open Terminal once and run
  `open build/DshDesktop.app` from there.
- See `docs/superpowers/specs/2026-08-15-dsh-desktop-wrapper-design.md` for
  the design rationale.
