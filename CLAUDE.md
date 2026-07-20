# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A macOS menu bar app (Swift/SwiftUI) for managing Azure CLI sessions — tenant login, subscription switching, PIM role activation, and portal navigation. Reads config from `~/.az-login-switcher.yaml`. Requires `az` CLI installed on the host.

This project was entirely vibe-coded with AI. It has no professional review or audit.

## Build & Run

```bash
# Build release binary (requires macOS 15+, Swift 5.9+, Python 3 with Pillow)
swift build -c release

# Build .app bundle (generates icon, compiles, creates bundle, ad-hoc signs)
./build.sh
open build/AzLoginSwitcher.app

# Run tests
swift test

# Run a single test
swift test --filter AzLoginSwitcherTests.AzCLITests/testListSubscriptions
```

The `build.sh` script: generates the app icon via `scripts/make_icon.py`, runs `swift build -c release`, then assembles a `.app` bundle under `build/` with `Info.plist` (`LSUIElement=true` for no dock icon) and ad-hoc codesigning.

## Architecture

**Entry point:** `main.swift` creates an `NSApplication` with `.accessory` policy (menu bar only, no dock icon). `AppDelegate` sets up the `NSStatusItem` (cloud icon) and a `MenuBarPanel` (custom `NSPanel` subclass) hosting SwiftUI views.

**State management — FSM pattern via `ActionRunner`:**
- `ActionRunner` (`@MainActor @Observable`) is the central state machine. It owns all mutable state and is the single entry point for user actions via `send(_ event: AppEvent)`.
- Uses a two-level FSM: top-level `FSMState` (`.idle` / `.busy(AzAction)`) prevents concurrent operations, and each `AzAction` has its own phase lifecycle (`pending → running → succeeded/failed/partialSuccess`).
- Views are read-only consumers of `ActionRunner` projections (`config`, `tenantCaches`, `azureContext`, etc.).

**Layered service design (data → calculations → actions):**
- **Config layer** (`Config/`): `ConfigModels` (Codable structs) + `ConfigLoader` (YAML via Yams). Config is loaded from `~/.az-login-switcher.yaml`.
- **Services** (`Services/`): Side-effect-isolated modules injected via protocols.
  - `ShellExecutor` → `ShellExecuting` protocol: wraps `Foundation.Process`, reads stdout/stderr concurrently to avoid pipe deadlocks.
  - `AzCLI`: typed wrappers around `az` commands (login, set subscription, list subscriptions, get user). Resolves `az` path at init since GUI apps don't inherit shell PATH.
  - `PIMService`: discovers eligible PIM roles and activates them via `az rest` calls to Azure ARM API.
  - `BrowserService`: detects installed browsers, opens URLs in specific browsers.
  - `PortalURL`: pure function mapping (tenantId, subscriptionId) → Azure Portal URL.
- **State** (`State/`): `ActionRunner` (FSM), `TenantCache` (per-tenant session data), `AzureContext` (current az CLI context), `AzAction` (action lifecycle model), `ActionLogger` (writes verbose logs to `~/Library/Logs/az-login-switcher/`).
- **Views** (`Views/`): SwiftUI views that read from `ActionRunner` and dispatch `AppEvent`s. `MainView` → `TenantRow` → `SubscriptionSection` / `PIMSection`.

**Key design decisions:**
- **Binary tenant status (green/grey):** Tenant status is derived from `azureContext.currentTenantId`, not per-tenant flags. Green = this tenant matches `az account show` output, grey = everything else. `ActionRunner.isActiveTenant(_:)` is the single source of truth.
- **Async reload:** The `.loadConfig` event triggers an async `.reload` FSM action that loads YAML config, restores persisted state, then probes `az account show` to refresh `azureContext`. This replaces the old synchronous config load.
- Per-tenant caching (`TenantCache`) stores discovered subscriptions, active subscription, PIM roles, and signed-in user — but not login status (which is derived from `azureContext`).
- `az` CLI path probed at `/opt/homebrew/bin/az`, `/usr/local/bin/az`, then `which az` — necessary because `.app` bundles don't inherit shell PATH.
- All az CLI interactions go through `ActionRunner.runAz()` which logs commands, stdout, stderr, exit codes, and durations.
- `MenuBarPanel` is a custom `NSPanel` (not `NSPopover`) for better click-outside-to-close behavior and positioning.

## Dependencies

- **Yams** (6.2.1+): YAML parsing for config file. Only external SPM dependency.

## CI/CD

GitHub Actions workflow (`.github/workflows/release.yml`) triggers on push to `main`. Builds the app on `macos-15`, generates icon, ad-hoc signs, creates both `.zip` and `.dmg` artifacts, and publishes a GitHub Release with auto-generated tag.
