#!/usr/bin/env bash
# Register redreader:// on macOS so the browser hands the OAuth callback to
# reddle-bridge.sh (DESIGN.md §3.3a).
#
# macOS only registers URL schemes from an app bundle, and it delivers the URL as
# an Apple Event ("GetURL"), not argv -- so a bare shell script cannot be the
# handler. The smallest thing that can is an AppleScript applet with an
# `on open location` handler, which is what this builds.
#
#   ./install-handler.sh            # build + register into ~/Applications
#   ./install-handler.sh --uninstall
set -euo pipefail

APP_NAME="Reddle Bridge"
BUNDLE_ID="dev.reddle.bridge"
APP_DIR="${HOME}/Applications/${APP_NAME}.app"
BRIDGE="$(cd "$(dirname "$0")/.." && pwd)/reddle-bridge.sh"
PLIST="${APP_DIR}/Contents/Info.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ "${1:-}" == "--uninstall" ]]; then
  "$LSREGISTER" -u "$APP_DIR" 2>/dev/null || true
  rm -rf "$APP_DIR"
  echo "Unregistered and removed ${APP_DIR}"
  exit 0
fi

[[ -x "$BRIDGE" ]] || { echo "Not executable: $BRIDGE (chmod +x it)" >&2; exit 1; }

SRC="$(mktemp -t reddle_handler).applescript"
cat > "$SRC" <<ASCRIPT
on open location this_URL
    try
        set out to do shell script quoted form of "${BRIDGE}" & " " & quoted form of this_URL
        display notification out with title "Reddle"
    on error err_msg
        display notification err_msg with title "Reddle" subtitle "Pairing failed"
    end try
end open location
ASCRIPT

rm -rf "$APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
osacompile -o "$APP_DIR" "$SRC"
rm -f "$SRC"

# osacompile writes its own Info.plist, which has no CFBundleIdentifier at all --
# so Add first and only fall back to Set if the key somehow exists.
plist_put() { # <entry> <type> <value>
    /usr/libexec/PlistBuddy -c "Add $1 $2 $3" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set $1 $3" "$PLIST"
}
plist_put ":CFBundleIdentifier" string "${BUNDLE_ID}"
plist_put ":LSUIElement" bool true
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string 'RedReader OAuth callback'" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string redreader" "$PLIST"

# osacompile ad-hoc signs the bundle; editing Info.plist invalidates that, and
# macOS will refuse to launch a bundle whose signature no longer matches.
codesign --force --sign - "$APP_DIR" 2>/dev/null || true

"$LSREGISTER" -f "$APP_DIR"

cat <<EOF
Installed ${APP_DIR} and registered scheme "redreader".

Verify:  ${LSREGISTER} -dump | grep -i -A3 redreader
Test:    open "redreader://rr_oauth_redir?state=x&code=y"
         -> expect a "state mismatch" notification, which means the chain works.
Force default if another app claims the scheme:
         brew install duti && duti -s ${BUNDLE_ID} redreader

Untested on hardware/macOS in this session -- verify before relying on it.
EOF
