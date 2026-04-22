# az-login-switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar widget that manages Azure tenant login, subscription selection, PIM role activation, and portal navigation — all driven by a YAML config file.

**Architecture:** NSPopover + SwiftUI views hosted from an NSStatusItem. Pure data layer (Codable config, typed CLI results) with side-effect-isolated services (ShellExecutor → AzCLI → PIMService). State managed via `@Observable` AppState.

**Tech Stack:** Swift 5.9+, macOS 15+ (Sequoia), SPM, Yams (YAML), Foundation.Process, SwiftUI, AppKit (NSStatusItem/NSPopover)

**Design Principles:**
- **Grokking Simplicity**: data (ConfigModels) vs calculations (PortalURL, config parsing) vs actions (ShellExecutor, AzCLI, PIMService) — kept strictly separate
- **APoSD**: deep modules with simple interfaces; ShellExecutor hides Process/Pipe; AzCLI hides command details; PIMService hides REST API

**Key Design Decisions (from review):**
- **macOS 15+ target** — targeting Sequoia; unlocks latest SwiftUI APIs and `@Observable`
- **Per-tenant session state** — `AppState` tracks `[tenantId: TenantSession]` not global state, so multi-tenant workflows don't clobber each other
- **Split shell protocols** — `ShellExecuting` for capture-output commands; separate `LoginLauncher` for interactive Terminal.app mode (different semantics)
- **az CLI path resolution** — probe `/opt/homebrew/bin/az`, `/usr/local/bin/az`, `PATH` lookup; GUI apps don't inherit shell PATH
- **Pipe safety** — read stdout/stderr concurrently to avoid deadlocks on large output
- **Config validation** — require ≥1 subscription per tenant
- **@MainActor on AppState** — gate concurrent actions, prevent double-login races

---

## File Map

| File | Responsibility |
|------|---------------|
| `Package.swift` | SPM manifest: executable target + Yams dependency + test target |
| `Sources/AzLoginSwitcher/main.swift` | NSApplication entry, `.accessory` policy, no dock icon |
| `Sources/AzLoginSwitcher/AppDelegate.swift` | NSStatusItem + NSPopover lifecycle |
| `Sources/AzLoginSwitcher/Config/ConfigModels.swift` | Codable structs: `AppConfig`, `TenantConfig`, `SubscriptionConfig`, `PIMConfig` |
| `Sources/AzLoginSwitcher/Config/ConfigLoader.swift` | Read YAML from `~/.az-login-switcher.yaml`, decode via Yams, return `Result<AppConfig, Error>` |
| `Sources/AzLoginSwitcher/Services/ShellExecutor.swift` | Process wrapper: `run(executable:args:) async → ShellResult` |
| `Sources/AzLoginSwitcher/Services/LoginLauncher.swift` | Opens Terminal.app with az command via AppleScript |
| `Sources/AzLoginSwitcher/Services/Protocols.swift` | `ShellExecuting`, `LoginLaunching`, `URLOpening` protocols |
| `Sources/AzLoginSwitcher/Services/AzCLI.swift` | Typed az commands: `login(tenant:)`, `setSubscription(id:)`, `listSubscriptions()`, `getSignedInUser()` |
| `Sources/AzLoginSwitcher/Services/PIMService.swift` | Discover eligible roles, list active assignments, activate role |
| `Sources/AzLoginSwitcher/Services/PortalURL.swift` | Pure function: `(tenantId, subscriptionId?) → URL` |
| `Sources/AzLoginSwitcher/State/AppState.swift` | `@Observable`: login status, active tenant, subscriptions, PIM roles, errors |
| `Sources/AzLoginSwitcher/Views/MainView.swift` | Root popover view: tenant list + status |
| `Sources/AzLoginSwitcher/Views/TenantRow.swift` | Single tenant row with login button + status indicator |
| `Sources/AzLoginSwitcher/Views/SubscriptionSection.swift` | List of subscriptions with set-active + open-portal buttons |
| `Sources/AzLoginSwitcher/Views/PIMSection.swift` | Eligible PIM roles with activate buttons + status |
| `Tests/AzLoginSwitcherTests/ConfigModelsTests.swift` | YAML decoding, edge cases, missing optional fields |
| `Tests/AzLoginSwitcherTests/PortalURLTests.swift` | URL construction variants |
| `Tests/AzLoginSwitcherTests/AzCLITests.swift` | JSON parsing of az output (mock ShellExecutor) |
| `Tests/AzLoginSwitcherTests/PIMServiceTests.swift` | PIM response parsing, activation request body |
| `build.sh` | Compile release, wrap in `.app` bundle with `Info.plist` (LSUIElement=true) |
| `example-config.yaml` | Documented example YAML config |

---

## Task 1: Project Scaffold + Build Infrastructure

**Files:** `Package.swift`, `main.swift`, `AppDelegate.swift`, `build.sh`

- [ ] **Step 1:** Create `Package.swift` with swift-tools-version 5.9, macOS 15 platform
  - Executable target `AzLoginSwitcher` depending on `Yams` (from: "6.2.1")
  - Test target `AzLoginSwitcherTests` depending on `AzLoginSwitcher`
- [ ] **Step 2:** Create `main.swift` — `NSApplication.shared`, set `.accessory` activation policy, create `AppDelegate`, call `app.run()`
- [ ] **Step 3:** Create minimal `AppDelegate.swift` — `applicationDidFinishLaunching` sets up `NSStatusItem` with system symbol `"cloud"`, creates `NSPopover` with placeholder SwiftUI Text view
- [ ] **Step 4:** Run `swift build` — verify it compiles clean
- [ ] **Step 5:** Create `build.sh` — compiles release, creates `.app` bundle structure (`Contents/MacOS/`, `Contents/Resources/`), writes `Info.plist` with `LSUIElement=true`, copies binary
- [ ] **Step 6:** Run `swift build` and `./build.sh`, verify `.app` bundle is created and launches as menu bar icon (no dock icon)
- [ ] **Step 7:** Commit: `"feat: project scaffold with menu bar app shell"`

---

## Task 2: Config Models + Loader (Calculation — Pure)

**Files:** `Config/ConfigModels.swift`, `Config/ConfigLoader.swift`, `Tests/.../ConfigModelsTests.swift`

- [ ] **Step 1:** Write parameterized tests for `ConfigModels` YAML decoding
  - Valid full config (all fields)
  - Minimal config (no PIM section — optional)
  - Multiple tenants with multiple subscriptions
  - Invalid YAML (missing required `tenantId`) → error
  - Empty subscriptions list → validation error (require ≥1 subscription per tenant)
- [ ] **Step 2:** Run tests, verify they fail (models don't exist yet)
- [ ] **Step 3:** Implement `ConfigModels.swift`
  - `AppConfig` with `tenants: [TenantConfig]`
  - `TenantConfig` with `name: String`, `tenantId: String`, `subscriptions: [SubscriptionConfig]`, `pim: PIMConfig?`
  - `SubscriptionConfig` with `name: String`, `id: String`
  - `PIMConfig` with `justification: String`, `duration: String` (ISO 8601, e.g. "PT8H")
  - All `Codable` + `Equatable`
- [ ] **Step 4:** Implement `ConfigLoader.swift`
  - `loadConfig(from path: String) -> Result<AppConfig, ConfigError>`
  - `defaultConfigPath()` → resolves `~/.az-login-switcher.yaml`
  - `ConfigError` enum: `fileNotFound`, `parseError(String)`, `validationError(String)`
- [ ] **Step 5:** Run tests, verify all pass
- [ ] **Step 6:** Commit: `"feat: YAML config models and loader with tests"`

---

## Task 3: Shell Executor + Login Launcher (Action — Isolated Side Effects)

**Files:** `Services/ShellExecutor.swift`, `Services/LoginLauncher.swift`, protocols for testability

- [ ] **Step 1:** Define `ShellExecuting` protocol with `func run(executable: String, arguments: [String]) async throws -> ShellResult`
  - `ShellResult`: `stdout: String`, `stderr: String`, `exitCode: Int32`
  - Protocol enables mock injection for testing consumers (AzCLI, PIMService)
- [ ] **Step 2:** Implement `ShellExecutor` conforming to `ShellExecuting`
  - Uses `Foundation.Process` + `Pipe` for stdout/stderr
  - **Read stdout and stderr concurrently** (DispatchGroup or async let) to avoid pipe deadlocks on large output
  - Runs on background thread (not main actor)
  - **az path resolution:** probe `/opt/homebrew/bin/az`, `/usr/local/bin/az`, then `PATH` — GUI `.app` bundles don't inherit shell PATH
- [ ] **Step 3:** Define separate `LoginLaunching` protocol with `func launchInTerminal(command: String, arguments: [String]) async throws`
  - Different semantics: does NOT capture output, opens Terminal.app interactively
  - **Not substitutable** with `ShellExecuting` — intentionally separate
- [ ] **Step 4:** Implement `TerminalLoginLauncher` conforming to `LoginLaunching`
  - Uses `osascript` with AppleScript `tell application "Terminal" to do script "..."` (NOT `open -a Terminal` which doesn't reliably execute commands)
- [ ] **Step 5:** Define `URLOpening` protocol with `func open(_ url: URL)` — wraps `NSWorkspace.shared.open()` for testability
- [ ] **Step 6:** Manual test: call `ShellExecutor.run(executable: "/bin/echo", arguments: ["hello"])` from a test, verify stdout
- [ ] **Step 7:** Commit: `"feat: shell executor, terminal launcher, and URL opener with protocols for DI"`

---

## Task 4: AzCLI Service (Action — Depends on ShellExecutor)

**Files:** `Services/AzCLI.swift`, `Tests/.../AzCLITests.swift`

- [ ] **Step 1:** Write parameterized tests using a `MockShellExecutor`
  - `listSubscriptions()` — mock returns JSON array, verify parsed `[AzSubscription]`
  - `getSignedInUser()` — mock returns JSON object, verify parsed `AzUser` (principalId, upn)
  - `login(tenantId:)` — verify correct arguments passed (`["login", "--tenant", "<id>"]`)
  - `setSubscription(id:)` — verify correct arguments
  - Error case: non-zero exit code → typed `AzCLIError`
  - Error case: invalid JSON → parse error
- [ ] **Step 2:** Run tests, verify they fail
- [ ] **Step 3:** Implement `AzCLI` class
  - Takes `ShellExecuting` via init (dependency injection)
  - `login(tenantId:) async throws` — runs `az login --tenant <id>`
  - `setSubscription(id:) async throws` — runs `az account set -s <id>`
  - `listSubscriptions() async throws -> [AzSubscription]` — runs `az account list -o json`, decodes
  - `getSignedInUser() async throws -> AzUser` — runs `az ad signed-in-user show -o json`, decodes
  - `checkInstalled() async -> Bool` — runs `which az`
  - All JSON decoding uses Codable structs (`AzSubscription`, `AzUser`)
- [ ] **Step 4:** Define `AzSubscription` Codable: `id`, `name`, `tenantId`, `isDefault`, `state`
- [ ] **Step 5:** Define `AzUser` Codable: `id` (principalId), `userPrincipalName`
- [ ] **Step 6:** Run tests, verify all pass
- [ ] **Step 7:** Commit: `"feat: az CLI service with typed commands and tests"`

---

## Task 5: Portal URL Builder (Calculation — Pure, No Dependencies)

**Files:** `Services/PortalURL.swift`, `Tests/.../PortalURLTests.swift`

- [ ] **Step 1:** Write parameterized tests
  - `portalURL(tenantId:)` → `https://portal.azure.com/#@<tenantId>/home`
  - `portalURL(tenantId:, subscriptionId:)` → `https://portal.azure.com/#@<tenantId>/resource/subscriptions/<subId>/overview`
  - Edge case: special characters in tenant ID (shouldn't happen, but defensive)
- [ ] **Step 2:** Run tests, verify fail
- [ ] **Step 3:** Implement `PortalURL` as enum with static functions (pure calculations, no state)
- [ ] **Step 4:** Run tests, verify pass
- [ ] **Step 5:** Commit: `"feat: portal URL builder with tests"`

---

## Task 6: PIM Service (Action — Depends on ShellExecutor, AzCLI)

**Files:** `Services/PIMService.swift`, `Tests/.../PIMServiceTests.swift`

- [ ] **Step 1:** Write parameterized tests using `MockShellExecutor`
  - `discoverEligibleRoles(scope:)` — mock returns PIM eligibility JSON, verify parsed `[PIMEligibleRole]`
  - `discoverEligibleRoles` with empty response → empty array
  - `activateRole(...)` — verify correct PUT URL, request body structure (principalId, roleDefinitionId, requestType=SelfActivate, justification, duration)
  - `listActiveAssignments()` — mock returns active PIM JSON, verify parsed
  - Error case: activation failure (non-200) → typed error
- [ ] **Step 2:** Run tests, verify fail
- [ ] **Step 3:** Define PIM models
  - `PIMEligibleRole`: `id`, `roleDefinitionId`, `scope`, `roleName` (requires role-definition lookup — `roleDefinitionId` is an ARM resource ID, not a display name)
  - `PIMActivationRequest`: `principalId`, `roleDefinitionId`, `linkedScheduleId`, `justification`, `duration`
  - `PIMActivationResult`: `status`, `expiresAt`
- [ ] **Step 4:** Implement `PIMService`
  - Takes `ShellExecuting` via init
  - `discoverEligibleRoles(subscriptionId:) async throws -> [PIMEligibleRole]`
    - Calls `az rest GET .../roleEligibilityScheduleInstances?$filter=asTarget()&api-version=2020-10-01`
    - Scoped to `/subscriptions/<id>`
    - **Role name resolution:** extract roleDefinitionId from eligibility response, then call `az role definition list --name <id> --scope /subscriptions/<subId>` to get display name; cache results to avoid repeated lookups
  - `activateRole(subscriptionId:, role:, principalId:, justification:, duration:) async throws -> PIMActivationResult`
    - Generates UUID for request ID
    - Calls `az rest PUT .../roleAssignmentScheduleRequests/<uuid>?api-version=2020-10-01`
    - Body matches the pattern from login.azcli
  - `listActiveAssignments(subscriptionId:) async throws -> [PIMActiveRole]`
    - Filters by `assignmentType == "Activated"`
- [ ] **Step 5:** Run tests, verify pass
- [ ] **Step 6:** Commit: `"feat: PIM service for role discovery and activation with tests"`

---

## Task 7: App State (Mutable State — Minimal Surface)

**Files:** `State/AppState.swift`

- [ ] **Step 1:** Implement `AppState` as `@MainActor @Observable` class
  - **Per-tenant session state** (not global — avoids clobbering when switching tenants):
    - `config: AppConfig?` — loaded YAML config
    - `configError: String?` — if config failed to load
    - `tenantSessions: [String: TenantSession]` — keyed by tenantId
  - **`TenantSession` struct:**
    - `loginStatus: LoginStatus` — enum: `.idle`, `.loggingIn`, `.loggedIn`, `.failed(String)`
    - `subscriptions: [AzSubscription]` — from `az account list` after login
    - `activeSubscription: AzSubscription?` — currently set subscription
    - `eligiblePIMRoles: [PIMEligibleRole]` — discovered after login
    - `pimRoleStatuses: [String: PIMRoleStatus]` — keyed by role ID
    - `signedInUser: AzUser?`
  - **Actions (async methods — @MainActor ensures no races):**
    - `loadConfig()` — calls ConfigLoader, sets config/configError
    - `loginToTenant(_:, useTerminal: Bool)` — calls AzCLI.login, then setSubscription, then discoverPIM; guards against double-login
    - `setActiveSubscription(_:, tenantId:)` — calls AzCLI.setSubscription
    - `activatePIMRole(_:, for tenant:)` — calls PIMService.activateRole with tenant's PIM config
    - `openPortal(tenant:, subscription:)` — delegates to injected `URLOpening` protocol (not NSWorkspace directly)
  - **Dependencies (injected via init):** `AzCLI`, `PIMService`, `ConfigLoader`, `URLOpening`
- [ ] **Step 2:** Verify it compiles with `swift build`
- [ ] **Step 3:** Commit: `"feat: observable app state orchestrating all services"`

---

## Task 8: SwiftUI Views

**Files:** `Views/MainView.swift`, `Views/TenantRow.swift`, `Views/SubscriptionSection.swift`, `Views/PIMSection.swift`

- [ ] **Step 1:** Implement `MainView` — root popover view
  - If config error → show error message + "Open config file" button
  - If no config → show "Create config at ~/.az-login-switcher.yaml" instructions
  - Otherwise → `List` of `TenantRow` for each tenant in config
  - Bottom: Quit button, Reload config button
  - Fixed frame: width 350, max height 500

- [ ] **Step 2:** Implement `TenantRow`
  - Shows tenant name + login status indicator (colored dot: gray=idle, yellow=logging in, green=logged in, red=failed)
  - "Login" button (primary action) — calls `appState.loginToTenant()`
  - Gear icon button for "Login in Terminal" alternative
  - When logged in: expands to show `SubscriptionSection` and `PIMSection`

- [ ] **Step 3:** Implement `SubscriptionSection`
  - Shows each subscription from tenant config
  - Active subscription highlighted with checkmark
  - Each row has:
    - "Set Active" button (or checkmark if already active)
    - "Portal" button → opens portal URL in browser
  - Shows loading spinner during subscription switch

- [ ] **Step 4:** Implement `PIMSection`
  - Header: "PIM Roles" with count badge
  - Shows each eligible role with:
    - Role name (parsed from roleDefinitionId)
    - Scope (subscription name)
    - Status indicator (idle/activating/active with expiry/failed)
    - "Activate" button (disabled if already active or activating)
  - If no eligible roles → show "No eligible PIM roles" text

- [ ] **Step 5:** Wire views into `AppDelegate` — replace placeholder with `MainView(appState:)`
- [ ] **Step 6:** Run `swift build`, verify compilation
- [ ] **Step 7:** Manual test: run the app, verify popover opens, shows config or error
- [ ] **Step 8:** Commit: `"feat: SwiftUI views for tenant, subscription, and PIM management"`

---

## Task 9: Example Config + README

**Files:** `example-config.yaml`, `README.md`

- [ ] **Step 1:** Create `example-config.yaml` with 2 example tenants, each with 2 subscriptions, one with PIM config
- [ ] **Step 2:** Create `README.md`
  - What it does (one paragraph)
  - Prerequisites: macOS 15+, az CLI installed, Swift 5.9+
  - Build: `swift build -c release && ./build.sh`
  - Config: copy `example-config.yaml` to `~/.az-login-switcher.yaml`, edit with your tenants
  - Usage: click menu bar icon, select tenant, login, manage subscriptions and PIM
- [ ] **Step 3:** Commit: `"docs: example config and README"`

---

## Task 10: Integration Testing + Polish

- [ ] **Step 1:** Manual integration test checklist:
  - App launches as menu bar icon (no dock icon)
  - Popover opens/closes on click
  - Config loads from `~/.az-login-switcher.yaml`
  - Config error shown gracefully if file missing/malformed
  - Login triggers `az login --tenant` and opens browser
  - After login, first subscription auto-selected
  - Subscription switching works
  - Portal links open correct URLs
  - PIM roles discovered and displayed
  - PIM activation works with justification/duration from config
  - "Login in Terminal" option opens Terminal.app
  - Quit button works
  - Reload config button works
- [ ] **Step 2:** Fix any issues found
- [ ] **Step 3:** Final commit: `"feat: az-login-switcher v1.0"`

---

## Dependency Graph

```
Task 1 (scaffold)
├── Task 2 (config) ──────────┐
├── Task 3 (shell executor) ──┤
│   ├── Task 4 (az CLI) ──────┤
│   └── Task 6 (PIM service) ─┤
├── Task 5 (portal URL) ──────┤
│                              ▼
│                     Task 7 (app state)
│                              │
│                     Task 8 (views)
│                              │
│                     Task 9 (docs)
│                              │
│                     Task 10 (integration)
```

**Parallelizable:** Tasks 2, 3, 5 can run in parallel after Task 1. Tasks 4 and 6 can run in parallel after Task 3.
