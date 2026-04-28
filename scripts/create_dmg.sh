#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-AzLoginSwitcher}"
VOL_NAME="${VOL_NAME:-AzLoginSwitcher}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
ASSET_DIR="$BUILD_DIR/dmg-assets"
RW_DMG="$BUILD_DIR/$APP_NAME-rw.dmg"
FINAL_DMG="${FINAL_DMG:-$ROOT_DIR/$APP_NAME.dmg}"
BACKGROUND_SOURCE="${DMG_BACKGROUND:-}"
BACKGROUND_NAME="background.png"
WINDOW_LEFT="${DMG_WINDOW_LEFT:-200}"
WINDOW_TOP="${DMG_WINDOW_TOP:-120}"
WINDOW_WIDTH="${DMG_WINDOW_WIDTH:-640}"
WINDOW_HEIGHT="${DMG_WINDOW_HEIGHT:-420}"
APP_ICON_X="${DMG_APP_ICON_X:-180}"
APP_ICON_Y="${DMG_APP_ICON_Y:-210}"
APPLICATIONS_ICON_X="${DMG_APPLICATIONS_ICON_X:-460}"
APPLICATIONS_ICON_Y="${DMG_APPLICATIONS_ICON_Y:-210}"
ICON_SIZE="${DMG_ICON_SIZE:-96}"

MOUNT_DIR=""
DEV_ENTRY=""

cleanup() {
    if [[ -n "$DEV_ENTRY" ]]; then
        hdiutil detach "$DEV_ENTRY" -quiet -force 2>/dev/null || true
    elif [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Build only if .app doesn't already exist (CI builds separately)
if [[ -d "$APP_PATH" ]]; then
    echo "Using existing $APP_PATH"
else
    echo "Building $APP_NAME.app..."
    "$ROOT_DIR/build.sh"
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: expected app bundle at $APP_PATH" >&2
    exit 1
fi

echo "Preparing DMG assets..."
rm -rf "$ASSET_DIR" "$RW_DMG" "$FINAL_DMG"
mkdir -p "$ASSET_DIR"

if [[ -n "$BACKGROUND_SOURCE" ]]; then
    echo "Using custom DMG background: $BACKGROUND_SOURCE"
    ditto "$BACKGROUND_SOURCE" "$ASSET_DIR/$BACKGROUND_NAME"
else
    echo "Generating default DMG background..."
    python3 - "$ASSET_DIR/background.ppm" "$WINDOW_WIDTH" "$WINDOW_HEIGHT" <<'PY'
import sys

out_path = sys.argv[1]
width = int(sys.argv[2])
height = int(sys.argv[3])

with open(out_path, "wb") as out:
    out.write(f"P6\n{width} {height}\n255\n".encode())
    for y in range(height):
        for x in range(width):
            t = (x + y) / max(width + height - 2, 1)
            r = int(18 + 24 * t)
            g = int(84 + 52 * t)
            b = int(150 + 70 * t)
            out.write(bytes((r, g, b)))
PY
    sips -s format png "$ASSET_DIR/background.ppm" --out "$ASSET_DIR/$BACKGROUND_NAME" >/dev/null
    rm "$ASSET_DIR/background.ppm"
fi

echo "Creating writable DMG..."
APP_SIZE_MB="$(du -sm "$APP_PATH" | awk '{print $1}')"
DMG_SIZE_MB="${DMG_SIZE_MB:-$((APP_SIZE_MB + 64))}"
if [[ "$DMG_SIZE_MB" -lt 128 ]]; then
    DMG_SIZE_MB=128
fi
hdiutil create \
    -size "${DMG_SIZE_MB}m" \
    -volname "$VOL_NAME" \
    -ov \
    -type UDIF \
    -fs "Journaled HFS+" \
    "$RW_DMG" >/dev/null

echo "Mounting writable DMG..."
ATTACH_PLIST="$BUILD_DIR/dmg-attach.plist"
hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -plist > "$ATTACH_PLIST"
read -r DEV_ENTRY MOUNT_DIR < <(python3 - "$ATTACH_PLIST" <<'PY'
import plistlib, sys

with open(sys.argv[1], "rb") as f:
    data = plistlib.load(f)

dev = ""
mount = ""
for entity in data.get("system-entities", []):
    if not dev and entity.get("dev-entry"):
        dev = entity["dev-entry"]
    if not mount and entity.get("mount-point"):
        mount = entity["mount-point"]
if not mount:
    raise SystemExit("No mount point found")
print(dev, mount)
PY
)
rm "$ATTACH_PLIST"

echo "Copying DMG contents..."
ditto "$APP_PATH" "$MOUNT_DIR/$APP_NAME.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
ditto "$ASSET_DIR/$BACKGROUND_NAME" "$MOUNT_DIR/.background/$BACKGROUND_NAME"

echo "Applying Finder layout..."
# Skip Finder layout in headless/CI environments
if [[ -z "${CI:-}" ]] && [[ -n "${DISPLAY:-}" || "$(uname)" == "Darwin" ]] && pgrep -q Finder 2>/dev/null; then
    set +e
    osascript >/dev/null <<OSA
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {$WINDOW_LEFT, $WINDOW_TOP, $((WINDOW_LEFT + WINDOW_WIDTH)), $((WINDOW_TOP + WINDOW_HEIGHT))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set background picture of viewOptions to file ".background:$BACKGROUND_NAME"
        set position of item "$APP_NAME.app" of container window to {$APP_ICON_X, $APP_ICON_Y}
        set position of item "Applications" of container window to {$APPLICATIONS_ICON_X, $APPLICATIONS_ICON_Y}
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA
LAYOUT_STATUS=$?
    set -e
    if [[ "$LAYOUT_STATUS" -ne 0 ]]; then
        echo "warning: Finder layout AppleScript failed; DMG contents are still valid." >&2
    fi
else
    echo "Skipping Finder layout (headless/CI environment detected)."
fi

sync
hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""
DEV_ENTRY=""

echo "Compressing final DMG..."
hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$FINAL_DMG" >/dev/null
rm "$RW_DMG"

echo "Verifying DMG..."
hdiutil verify "$FINAL_DMG" >/dev/null

echo "✅ DMG created: $FINAL_DMG"
