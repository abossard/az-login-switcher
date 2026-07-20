# az-login-switcher

> [!CAUTION]
> **⚠️ This project was entirely vibe-coded with AI assistance. It has NOT been professionally reviewed, audited, or tested for production use. Do NOT use this without proper vetting, security review, and thorough testing. Use at your own risk.**

A macOS menu bar app for switching Azure tenants, managing subscriptions, activating PIM roles, and opening Azure Portal — all from your menu bar in seconds.

## Install

### From Release (recommended)

1. Download `AzLoginSwitcher.zip` from [Releases](https://github.com/abossard/az-login-switcher/releases/latest)
2. Unzip and move `AzLoginSwitcher.app` to `/Applications/`
3. On first launch, macOS will block it (unsigned). Fix with:
   ```bash
   xattr -cr /Applications/AzLoginSwitcher.app
   ```
4. Open the app — a cloud icon ☁️ appears in your menu bar

### Build from Source

Requires macOS 15+, Swift 5.9+, Python 3 with Pillow (`pip install Pillow`).

```bash
./build.sh
open build/AzLoginSwitcher.app
```

## Configuration

Copy `example-config.yaml` to `~/.az-login-switcher.yaml` and edit with your tenant and subscription details.

**Configuration fields:**
- `loginBrowser` (optional) — Browser used for interactive Azure CLI login: `safari`, `chrome`, `edge`, or `firefox`. When omitted, installed Edge is preferred. If the selected browser is unavailable, or Edge is unavailable when omitted, Azure CLI uses the system default browser.
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
- **Background login** — Authenticate via browser without interrupting your workflow
- **Browser picker** — Open Azure Portal in Safari, Chrome, Edge, or Firefox
- **Verbose logging** — All commands logged to `~/Library/Logs/az-login-switcher/`
