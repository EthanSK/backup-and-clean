#!/bin/bash
#
# Creates a macOS .app bundle that launches backup-and-clean in Terminal.
# The .app is needed so you can double-click it from Finder.
#
# Usage: ./create-app.sh [--output <path>] [--script <path>] [--config <path>]
#
# Defaults:
#   --output  ~/Desktop/Backup and Clean.app
#   --script  (auto-detected from this repo)
#   --config  ~/.backup-and-clean.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

OUTPUT_PATH="$HOME/Desktop/Backup and Clean.app"
MAIN_SCRIPT="$REPO_DIR/backup-and-clean.sh"
CONFIG_PATH="$HOME/.backup-and-clean.env"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_PATH="$2"; shift 2 ;;
        --script) MAIN_SCRIPT="$2"; shift 2 ;;
        --config) CONFIG_PATH="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

APP_NAME=$(basename "$OUTPUT_PATH" .app)

echo "Creating $OUTPUT_PATH..."

# Create app structure
mkdir -p "$OUTPUT_PATH/Contents/MacOS"

# Create Info.plist
cat > "$OUTPUT_PATH/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>launcher.sh</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.backup-and-clean</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
</dict>
</plist>
PLIST

# Create launcher that opens in Terminal (needed for volume access permissions)
cat > "$OUTPUT_PATH/Contents/MacOS/launcher.sh" << 'LAUNCHER'
#!/bin/bash

MAIN_SCRIPT="__MAIN_SCRIPT__"
CONFIG_PATH="__CONFIG_PATH__"

if [ ! -f "$MAIN_SCRIPT" ]; then
    osascript -e 'display dialog "Script not found at:\n'"$MAIN_SCRIPT"'" buttons {"OK"} default button "OK" with icon stop'
    exit 1
fi

if [ ! -x "$MAIN_SCRIPT" ]; then
    chmod +x "$MAIN_SCRIPT" 2>/dev/null
fi

osascript -e 'tell application "Terminal"
    activate
    do script "\"'"$MAIN_SCRIPT"'\" --config \"'"$CONFIG_PATH"'\" ; exit"
end tell'
LAUNCHER

# Replace placeholders
sed -i '' "s|__MAIN_SCRIPT__|$MAIN_SCRIPT|g" "$OUTPUT_PATH/Contents/MacOS/launcher.sh"
sed -i '' "s|__CONFIG_PATH__|$CONFIG_PATH|g" "$OUTPUT_PATH/Contents/MacOS/launcher.sh"

chmod +x "$OUTPUT_PATH/Contents/MacOS/launcher.sh"

echo "Done! App created at: $OUTPUT_PATH"
echo "Script: $MAIN_SCRIPT"
echo "Config: $CONFIG_PATH"
