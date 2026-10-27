#!/bin/bash
# Builds FocusCore, focusctl, focus-nmh and the test runner with swiftc directly.
# Usage: ./build.sh [test|app]   (app also assembles .build/FocusBlocker.app)
set -euo pipefail
cd "$(dirname "$0")"
OUT=.build
mkdir -p "$OUT"
FLAGS=(-O -swift-version 5 -target arm64-apple-macosx13.0)

swiftc "${FLAGS[@]}" -parse-as-library -enable-testing -module-name FocusCore \
  -emit-module -emit-module-path "$OUT/FocusCore.swiftmodule" \
  -emit-library -static -o "$OUT/libFocusCore.a" Sources/FocusCore/*.swift

swiftc "${FLAGS[@]}" -I "$OUT" -L "$OUT" -lFocusCore -o "$OUT/focusctl" Sources/focusctl/*.swift
swiftc "${FLAGS[@]}" -I "$OUT" -L "$OUT" -lFocusCore -o "$OUT/focus-nmh" Sources/focus-nmh/*.swift
swiftc "${FLAGS[@]}" -I "$OUT" -L "$OUT" -lFocusCore -o "$OUT/focus-agent" Sources/focus-agent/*.swift
echo "built $OUT/focusctl $OUT/focus-nmh $OUT/focus-agent"

if [[ "${1:-}" == "test" ]]; then
  swiftc "${FLAGS[@]}" -I "$OUT" -L "$OUT" -lFocusCore -o "$OUT/focus-tests" Tests/FocusCoreTests/*.swift
  "$OUT/focus-tests"
  node --test Tests/extension/*.test.mjs
fi

if [[ "${1:-}" == "app" ]]; then
  APP="$OUT/FocusBlocker.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
  swiftc "${FLAGS[@]}" -parse-as-library -I "$OUT" -L "$OUT" -lFocusCore \
    -o "$APP/Contents/MacOS/FocusBlocker" Sources/FocusBlockerApp/*.swift
  cp "$OUT/focusctl" "$OUT/focus-nmh" "$APP/Contents/Helpers/"
  # The agent is its own small app (no Dock icon) so macOS can attribute notification permission to it.
  AGENT_APP="$APP/Contents/Library/LoginItems/FocusBlockerAgent.app"
  mkdir -p "$AGENT_APP/Contents/MacOS"
  cp "$OUT/focus-agent" "$AGENT_APP/Contents/MacOS/"
  cat > "$AGENT_APP/Contents/Info.plist" <<AGENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.focusblocker.agent</string>
  <key>CFBundleName</key><string>Focus Blocker</string>
  <key>CFBundleDisplayName</key><string>Focus Blocker</string>
  <key>CFBundleExecutable</key><string>focus-agent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
AGENTPLIST
  # Registered by the app through SMAppService.agent; macOS asks the user to allow it in Login Items.
  cat > "$APP/Contents/Library/LaunchAgents/com.focusblocker.agent.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.focusblocker.agent</string>
  <key>BundleProgram</key><string>Contents/Library/LoginItems/FocusBlockerAgent.app/Contents/MacOS/focus-agent</string>
  <key>AssociatedBundleIdentifiers</key><array><string>com.focusblocker.app</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
AGENT
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.focusblocker.app</string>
  <key>CFBundleName</key><string>FocusBlocker</string>
  <key>CFBundleDisplayName</key><string>Focus Blocker</string>
  <key>CFBundleExecutable</key><string>FocusBlocker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  # Ad-hoc signature: enough to run locally. A Developer ID is only needed to distribute or for system extensions.
  codesign --force --sign - "$APP/Contents/Helpers/focusctl" "$APP/Contents/Helpers/focus-nmh"
  codesign --force --sign - "$AGENT_APP"
  codesign --force --sign - "$APP"
  echo "built $APP"
fi
