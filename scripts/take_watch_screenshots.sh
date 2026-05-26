#!/usr/bin/env bash
# take_watch_screenshots.sh
# Builds KenopsiaWatch for the simulator, installs it, launches with --demo-mode,
# and captures a screenshot via simctl.
#
# Usage:
#   ./scripts/take_watch_screenshots.sh ["Apple Watch Series 11 (46mm)"]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$ROOT_DIR/Kenopsia.xcodeproj"
OUTPUT_DIR="$ROOT_DIR/screenshots"
DERIVED_DATA="$ROOT_DIR/.build/watch-screenshots"

DEVICE="${1:-Apple Watch Series 11 (46mm)}"
SAFE="${DEVICE// /_}"
SAFE="${SAFE//(/}"
SAFE="${SAFE//)/}"
DEVICE_DIR="$OUTPUT_DIR/AppleWatch_$SAFE"
mkdir -p "$DEVICE_DIR"

echo ""
echo "=== Capturing Watch screenshot on: $DEVICE ==="

# 1. Build the Watch app for the simulator
echo "--- Building KenopsiaWatch..."
xcodebuild build \
    -project "$PROJECT" \
    -scheme KenopsiaWatchApp \
    -destination "platform=watchOS Simulator,name=$DEVICE" \
    -derivedDataPath "$DERIVED_DATA" \
    2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

# 2. Locate the built .app bundle
APP_PATH=$(find "$DERIVED_DATA" -name "KenopsiaWatch.app" -not -path "*/PlugIns/*" -type d | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "ERROR: Could not find KenopsiaWatch.app in $DERIVED_DATA"
    exit 1
fi
echo "--- App: $APP_PATH"

# 3. Get the simulator UDID
UDID=$(xcrun simctl list devices available | grep "$DEVICE" | grep -oE '[A-F0-9-]{36}' | head -1)
if [[ -z "$UDID" ]]; then
    echo "ERROR: Simulator not found: $DEVICE"
    exit 1
fi
echo "--- UDID: $UDID"

# 4. Boot, install, launch
echo "--- Booting simulator..."
xcrun simctl boot "$UDID" 2>/dev/null || true
sleep 3

echo "--- Installing app..."
xcrun simctl install "$UDID" "$APP_PATH"

echo "--- Launching with --demo-mode..."
xcrun simctl launch "$UDID" net.mohome.kenopsia.watch --demo-mode
sleep 8   # wait for view to render with injected demo state

# 5. Capture screenshot
OUTPUT_FILE="$DEVICE_DIR/01_watch_now_playing.png"
xcrun simctl io "$UDID" screenshot "$OUTPUT_FILE"
echo "  Saved: 01_watch_now_playing.png"

# 6. Shut down simulator
xcrun simctl shutdown "$UDID" 2>/dev/null || true

echo "--- Saved to: $DEVICE_DIR"
echo ""
echo "=== Done. Watch screenshots in: $DEVICE_DIR ==="

