# az-login-switcher

> [!CAUTION]
> **⚠️ This project was entirely vibe-coded with AI assistance. It has NOT been professionally reviewed, audited, or tested for production use. Do NOT use this without proper vetting, security review, and thorough testing. Use at your own risk.**

A macOS menu bar app for switching Azure tenants, managing subscriptions, activating PIM roles, and opening Azure Portal — all from your menu bar in seconds.

## Prerequisites

- **macOS** 15 or later
- **Azure CLI** (`az`) installed
- **Swift** 5.9 or later

## Build

```bash
swift build -c release
./build.sh
open build/AzLoginSwitcher.app
```

## Configuration

Copy `example-config.yaml` to `~/.az-login-switcher.yaml` and edit with your tenant and subscription details.

**Configuration fields:**
- `tenants` — List of Azure tenants to manage
  - `name` — Friendly name for the tenant
  - `tenantId` — Azure AD tenant ID (UUID)
  - `subscriptions` — Subscriptions within this tenant
    - `name` — Display name for the subscription
    - `id` — Subscription ID (UUID)
  - `pim` (optional) — Privileged Identity Management settings
    - `justification` — Reason for activation (required for PIM)
    - `duration` — How long to activate the role (ISO 8601 format, e.g., `PT8H`)

## Usage

1. Click the cloud icon in the menu bar
2. Select a tenant to log in
3. Switch between subscriptions
4. Activate PIM roles (if configured)
5. Open Azure Portal with one click

## Features

- **Tenant switching** — Quickly switch between Azure AD tenants
- **Subscription management** — View and switch subscriptions within a tenant
- **PIM activation** — Activate privileged roles with justification
- **Portal links** — Open Azure Portal directly to your active subscription
- **Background login** — Authenticate without interrupting your workflow
- **Terminal integration** — Optionally open a terminal with the active context
