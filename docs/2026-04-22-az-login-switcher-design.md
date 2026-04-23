# az-login-switcher — Design Spec

## Problem
Switching between Azure tenants/subscriptions requires remembering tenant IDs, running multiple CLI commands, and manually navigating to the portal. PIM role activation adds more manual steps.

## Solution
A macOS menu bar widget (NSPopover + SwiftUI) that reads a YAML config of tenants/subscriptions, provides one-click login, auto-selects subscriptions, discovers and activates PIM roles, and opens portal links.

## Architecture

### Data Layer (Pure Functions / Calculations)
- **ConfigLoader** — reads `~/.az-login-switcher.yaml`, decodes via Yams into Codable structs
- **AzCLI** — stateless wrapper around `Foundation.Process` for az commands, returns typed `Result<T, Error>`
- **PIMService** — stateless functions for PIM REST API via `az rest`
- **PortalURL** — pure function: `(tenantId, subscriptionId) → URL`

### State Layer (Data)
- **AppState** (`@Observable`) — current login status, active tenant, subscriptions, PIM roles, errors
- **Config** — loaded once at startup, reloaded on file change (optional)

### UI Layer (Actions)
- **StatusBarController** — owns `NSStatusItem` + `NSPopover`, manages popover lifecycle
- **MainView** — SwiftUI: tenant list, subscription buttons, PIM panel, portal links
- **No dock icon** — `NSApplication.setActivationPolicy(.accessory)` + `LSUIElement=true`

### Execution
- **Background mode** (default): runs `az login` via `Process`, shows spinner in popover
- **Terminal mode** (option): opens Terminal.app with the az command via `open -a Terminal`

## YAML Config Shape

```yaml
tenants:
  - name: "Dev Testing"
    tenantId: "aabbccdd-1111-2222-3333-444455556666"
    subscriptions:
      - name: "Dev Sub"
        id: "11111111-aaaa-bbbb-cccc-ddddeeee0001"
      - name: "Prod Sub"
        id: "11111111-aaaa-bbbb-cccc-ddddeeee0002"
    pim:
      justification: "dev testing"
      duration: "PT8H"
```

## Key Flows

### Login Flow
1. User clicks tenant in popover
2. App runs `az login --tenant <tenantId>` (background or terminal)
3. On success: `az account set --subscription <first-sub-id>`
4. Update AppState with login status
5. Trigger PIM discovery

### PIM Flow
1. After login: `az ad signed-in-user show` → get principalId
2. `az rest GET .../roleEligibilityScheduleInstances?$filter=asTarget()` → eligible roles
3. Parse role names from roleDefinitionId
4. Show in popover with "Activate" button per role
5. Activation: `az rest PUT .../roleAssignmentScheduleRequests/{uuid}` with justification/duration from YAML

### Portal Flow
- URL format: `https://portal.azure.com/#@<tenantId>/resource/subscriptions/<subId>/overview`
- Opens via `NSWorkspace.shared.open(url)`

## Dependencies
- **Yams** (6.2.1+) — YAML parsing
- **macOS 13+** — for modern SwiftUI features
- **Swift 5.9+**
- **az CLI** — must be pre-installed

## Project Structure
```
az-login-switcher/
├── Package.swift
├── Sources/AzLoginSwitcher/
│   ├── main.swift                 # NSApplication entry
│   ├── AppDelegate.swift          # NSStatusItem + NSPopover
│   ├── Config/
│   │   ├── ConfigLoader.swift     # YAML → Config model
│   │   └── ConfigModels.swift     # Codable structs
│   ├── Services/
│   │   ├── AzCLI.swift            # az command runner
│   │   ├── PIMService.swift       # PIM discovery/activation
│   │   └── ShellExecutor.swift    # Process wrapper
│   ├── State/
│   │   └── AppState.swift         # @Observable state
│   └── Views/
│       ├── MainView.swift         # Root popover view
│       ├── TenantListView.swift   # Tenant selection
│       ├── SubscriptionView.swift # Sub list + portal links
│       └── PIMView.swift          # PIM roles + activate
├── build.sh                       # Creates .app bundle
└── docs/
```
