#!/usr/bin/env bash
# take_screenshots.sh
# Builds the KenopsiaScreenshots UI test suite, runs it in the simulator,
# and extracts the captured screenshots from the .xcresult bundle.
#
# Usage:
#   ./scripts/take_screenshots.sh [device_name]
#
# Examples:
#   ./scripts/take_screenshots.sh
#   ./scripts/take_screenshots.sh "iPhone 17 Pro"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$ROOT_DIR/Kenopsia.xcodeproj"
SCHEME="KenopsiaScreenshots"
OUTPUT_DIR="$ROOT_DIR/screenshots"

DEFAULT_DEVICES=(
    "iPhone 17 Pro"
    "iPhone 17 Pro Max"
    "iPad Pro 13-inch (M5)"
)

# MARK: - Extraction helper (must be defined before the main loop calls it)
extract_screenshots() {
    local bundle="$1"
    local dest="$2"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    # Export all attachments into a temp dir; xcresulttool generates a manifest.json
    xcrun xcresulttool export attachments \
        --path "$bundle" \
        --output-path "$tmp_dir" \
        2>/dev/null

    local manifest="$tmp_dir/manifest.json"
    if [[ ! -f "$manifest" ]]; then
        echo "  No attachments found (tests may have failed)."
        rm -rf "$tmp_dir"
        return
    fi

    # Move files from temp dir to dest, renaming by the attachment name in manifest
    python3 - "$tmp_dir" "$dest" << 'PYEOF'
import sys, json, re, shutil, pathlib

tmp  = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
dest.mkdir(parents=True, exist_ok=True)

# manifest.json is a list of test-entry objects, each containing an attachments list
manifest = json.loads((tmp / "manifest.json").read_text())

for test_entry in manifest:
    for att in test_entry.get("attachments", []):
        src_name  = att.get("exportedFileName", "")
        suggested = att.get("suggestedHumanReadableName", src_name)
        src = tmp / src_name
        if not src.exists():
            continue
        # Strip trailing _<index>_<UUID> added by xcresulttool, keep clean prefix
        # e.g. "01_library_artists_0_CF218DBB-24A4-448C-9FE0-72E329B80507.png"
        #   -> "01_library_artists.png"
        stem = pathlib.Path(suggested).stem
        clean = re.sub(r'_\d+_[0-9A-Fa-f\-]{36}$', '', stem) or stem
        ext  = pathlib.Path(suggested).suffix or ".png"
        dst  = dest / f"{clean}{ext}"
        shutil.copy2(src, dst)
        print(f"  Saved: {dst.name}")
PYEOF

    rm -rf "$tmp_dir"
}

# MARK: - Main

if [[ $# -ge 1 ]]; then
    DEVICES=("$1")
else
    DEVICES=("${DEFAULT_DEVICES[@]}")
fi

mkdir -p "$OUTPUT_DIR"

for DEVICE in "${DEVICES[@]}"; do
    echo ""
    echo "=== Capturing screenshots on: $DEVICE ==="

    SAFE="${DEVICE// /_}"
    SAFE="${SAFE//(/}"
    SAFE="${SAFE//)/}"
    DEVICE_DIR="$OUTPUT_DIR/$SAFE"
    BUNDLE="$OUTPUT_DIR/${SAFE}.xcresult"

    rm -rf "$BUNDLE"
    mkdir -p "$DEVICE_DIR"

    echo "--- Building and running tests..."
    # Pre-boot the simulator so app launch is fast and setup timeouts aren't hit.
    DEVICE_UDID=$(xcrun simctl list devices available | grep "$DEVICE" | grep -oE '[A-F0-9-]{36}' | head -1)
    if [[ -n "$DEVICE_UDID" ]]; then
        xcrun simctl boot "$DEVICE_UDID" 2>/dev/null || true
        sleep 3
    fi
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,name=$DEVICE" \
        -resultBundlePath "$BUNDLE" \
        -only-testing:KenopsiaScreenshots \
        2>&1 | grep -E "Test (Case|Suite)|error:|BUILD (FAILED|SUCCEEDED)|Executed" || true

    if [[ ! -d "$BUNDLE" ]]; then
        echo "ERROR: Result bundle not found at $BUNDLE"
        continue
    fi

    echo "--- Extracting screenshots..."
    extract_screenshots "$BUNDLE" "$DEVICE_DIR"
    echo "--- Saved to: $DEVICE_DIR"
done

echo ""
echo "=== Done. All screenshots in: $OUTPUT_DIR ==="
