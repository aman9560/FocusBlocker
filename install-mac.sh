#!/bin/bash
# FocusBlocker installer for macOS (Apple silicon, macOS 13 or later).
#
#   curl -fsSL https://raw.githubusercontent.com/aman9560/FocusBlocker/main/install-mac.sh | bash
#
# From a checkout, to install a build you made yourself:
#   ./build.sh app && ./install-mac.sh --app .build/FocusBlocker.app
#
# Why this avoids the "can't be opened because Apple cannot check it" warning: that warning is triggered by the
# quarantine flag a web browser puts on downloaded files. curl doesn't set it, and this script also removes it
# from the installed app. FocusBlocker is signed ad hoc rather than with a paid Developer ID, which is why a
# browser download is flagged; there is nothing to bypass when it is installed this way.
#
# Options:
#   --app PATH         install this FocusBlocker.app instead of downloading the latest release
#   --dest DIR         install into DIR (default /Applications, or ~/Applications if that isn't writable)
#   --no-chrome-host   don't register the Chrome native messaging host
#   --no-open          don't launch the app afterwards
#   --version TAG      download a specific release (for example v0.2.2) instead of the latest
#   --force            update even while a focus session is running
set -euo pipefail

REPO="aman9560/FocusBlocker"
APP_NAME="FocusBlocker.app"
EXTENSION_ID="mchnpkbnifalondddkmcbplnlebaebmd"   # pinned by the key in the extension's manifest.json
DEST="/Applications"
SOURCE_APP=""
VERSION="latest"
INSTALL_HOST=1
OPEN_APP=1
FORCE=0

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)            SOURCE_APP="${2:?--app needs a path}"; shift 2 ;;
    --dest)           DEST="${2:?--dest needs a folder}"; shift 2 ;;
    --version)        VERSION="${2:?--version needs a tag}"; shift 2 ;;
    --no-chrome-host) INSTALL_HOST=0; shift ;;
    --no-open)        OPEN_APP=0; shift ;;
    --force)          FORCE=1; shift ;;
    -h|--help)        sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                fail "unknown option: $1 (try --help)" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "This installer is for macOS. On Windows use install-windows.ps1."
[[ "$(uname -m)" == "arm64" ]] || fail "FocusBlocker is built for Apple silicon Macs."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || fail "FocusBlocker needs macOS 13 or later (this Mac has $(sw_vers -productVersion))."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. Get the app -----------------------------------------------------------------------------------------------
if [[ -n "$SOURCE_APP" ]]; then
  [[ -d "$SOURCE_APP" ]] || fail "$SOURCE_APP not found. Build it first with ./build.sh app"
  say "Installing $SOURCE_APP"
else
  if [[ "$VERSION" == "latest" ]]; then
    base="https://github.com/$REPO/releases/latest/download"
  else
    base="https://github.com/$REPO/releases/download/$VERSION"
  fi
  say "Downloading FocusBlocker ($VERSION)"
  curl -fL --progress-bar -o "$WORK/app.zip" "$base/FocusBlocker-macOS-arm64.zip" \
    || fail "Download failed. Check your connection, or that release $VERSION exists."
  ditto -x -k "$WORK/app.zip" "$WORK/extracted"
  SOURCE_APP="$(find "$WORK/extracted" -maxdepth 2 -name "$APP_NAME" -type d | head -n 1)"
  [[ -n "$SOURCE_APP" ]] || fail "The download didn't contain $APP_NAME."
fi

# --- 2. Choose where to install ------------------------------------------------------------------------------------
if [[ ! -w "$DEST" ]]; then
  if [[ "$DEST" == "/Applications" ]]; then
    warn "/Applications isn't writable for this account; installing into ~/Applications instead."
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
  else
    fail "$DEST isn't writable."
  fi
fi
TARGET="$DEST/$APP_NAME"

# --- 3. Stop a running copy, then replace it -----------------------------------------------------------------------
# Replacing the app would stop the background agent that enforces a running session, so refuse unless told otherwise.
if [[ -x "$TARGET/Contents/Helpers/focusctl" && "$FORCE" -ne 1 ]]; then
  if "$TARGET/Contents/Helpers/focusctl" status 2>/dev/null | grep -q '^●'; then
    fail "A FocusBlocker session is running. Finish it first (updating would stop its enforcement), or re-run with --force."
  fi
fi
if pgrep -f "$APP_NAME/Contents/MacOS/FocusBlocker" >/dev/null 2>&1; then
  say "Closing the running FocusBlocker"
  osascript -e 'tell application id "com.focusblocker.app" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$APP_NAME/Contents/MacOS/FocusBlocker" >/dev/null 2>&1 || break
    sleep 1
  done
fi
# An active session is never interrupted by an update: closing the app doesn't end it, and the state lives outside the app.
if [[ -e "$TARGET" ]]; then
  say "Replacing the existing $APP_NAME (your blocklists and settings are kept)"
  rm -rf "$TARGET"
fi
ditto "$SOURCE_APP" "$TARGET"

# --- 4. Clear the download warning ---------------------------------------------------------------------------------
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
codesign --verify --deep --strict "$TARGET" 2>/dev/null \
  || fail "The installed app's signature doesn't verify; the download may be damaged. Run the installer again."
say "Installed $TARGET"

# --- 5. Chrome: native messaging host and extension files ----------------------------------------------------------
if (( INSTALL_HOST )); then
  say "Registering the Chrome connection"
  if "$TARGET/Contents/Helpers/focusctl" chrome install-host --extension-id "$EXTENSION_ID" >/dev/null; then
    echo "    Chrome can now talk to FocusBlocker."
  else
    warn "Couldn't register the Chrome host. Run: $TARGET/Contents/Helpers/focusctl chrome install-host --extension-id $EXTENSION_ID"
  fi

  EXT_DIR="$HOME/FocusBlocker-Chrome-Extension"
  if [[ -f "$(dirname "$0")/Extension/manifest.json" && -z "${FOCUSBLOCKER_FORCE_DOWNLOAD:-}" ]]; then
    rm -rf "$EXT_DIR"; ditto "$(dirname "$0")/Extension" "$EXT_DIR"
  elif curl -fsSL -o "$WORK/extension.zip" "https://github.com/$REPO/releases/latest/download/FocusBlocker-Chrome-Extension.zip"; then
    rm -rf "$WORK/ext" "$EXT_DIR"; ditto -x -k "$WORK/extension.zip" "$WORK/ext"
    ditto "$(find "$WORK/ext" -name manifest.json -not -path '*/__MACOSX/*' | head -n 1 | xargs dirname)" "$EXT_DIR"
  else
    warn "Couldn't download the Chrome extension; get FocusBlocker-Chrome-Extension.zip from the release page."
  fi
  [[ -f "$EXT_DIR/manifest.json" ]] && say "Chrome extension files are in $EXT_DIR (keep this folder)"
fi

# --- 6. Done -------------------------------------------------------------------------------------------------------
if (( OPEN_APP )); then open "$TARGET"; fi

cat <<EOF

FocusBlocker is installed. Two quick things remain, and macOS requires you to do both yourself:

  1. In FocusBlocker, open Protection and click "Turn on agent", then allow it in
     System Settings > General > Login Items. The agent is what closes blocked apps.
  2. To block websites in Chrome, open chrome://extensions, turn on Developer mode, click
     "Load unpacked", and choose: $HOME/FocusBlocker-Chrome-Extension
     Then open the extension's Details and turn on "Allow in Incognito".

EOF
