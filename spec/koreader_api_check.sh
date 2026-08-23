#!/usr/bin/env bash
# Verify every KOReader method our UI files call actually exists.
#
# The unit specs fake KOReader, so a method we invented (Menu:setTitle) passes
# every test and then crashes KOReader to the Kindle home screen. This is the
# only check that catches that class of bug off-device.
#
#   KOREADER_SRC=/path/to/koreader ./spec/koreader_api_check.sh
#
# Skips (exit 0) when no KOReader checkout is available.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${KOREADER_SRC:-}"
if [[ -z "$SRC" ]]; then
  for c in "$ROOT/../koreader" "$HOME/src/koreader" /tmp/koreader; do
    [[ -d "$c/frontend/ui/widget" ]] && { SRC="$c"; break; }
  done
fi
if [[ ! -d "${SRC}/frontend/ui/widget" ]]; then
  echo "spec/koreader_api_check.sh: no KOReader source found, skipping."
  echo "  set KOREADER_SRC=/path/to/koreader to enable (git clone --depth 1 https://github.com/koreader/koreader)"
  exit 0
fi

PASS=0; FAIL=0
echo; echo "spec/koreader_api_check.sh  (against ${SRC})"

# <our file> <base widget file> <base class name>
check_widget() {
  local file="$1" base="$2" class="$3"
  local ours
  ours="$(grep -o "^function [A-Za-z]*:[a-zA-Z_]*" "$file" | sed 's/.*://' | sort -u)"
  for m in $(grep -o 'self:[a-zA-Z_]*' "$file" | sed 's/self://' | sort -u); do
    if grep -q "^function ${class}:${m}\b" "$base"; then
      PASS=$((PASS+1))
    elif printf '%s\n' "$ours" | grep -qx "$m"; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1))
      echo "  MISSING  $(basename "$file") calls self:${m}() -- not on ${class}, not defined locally"
    fi
  done
}

check_widget "$ROOT/reddle_ui_listing.lua"  "$SRC/frontend/ui/widget/menu.lua" "Menu"
check_widget "$ROOT/reddle_ui_reader.lua" "$SRC/frontend/ui/widget/textviewer.lua" "TextViewer"

# Which KOReader is this? Checking against a version you do not run is how
# reddle_ui_listing.lua ended up calling a method that existed only in master.
# KOReader has no version literal to grep: Version:getCurrentRevision() reads a
# `git-rev` file written at build time, and falls back to `git describe`. Reading
# frontend/version.lua found neither, so this used to report the checkout's
# directory name as if it were a version -- which looks like an answer.
VER=""
[[ -f "$SRC/git-rev" ]] && VER="$(head -1 "$SRC/git-rev")"
[[ -z "$VER" ]] && VER="$(git -C "$SRC" describe --tags 2>/dev/null)"
if [[ -z "$VER" ]]; then
  echo "  WARNING: cannot tell which KOReader this is (no git-rev, no tags --"
  echo "  a --depth 1 clone has neither). The contracts below were checked, but"
  echo "  not against a known version. Before a release, point KOREADER_SRC at"
  echo "  the same build as the device: git clone --branch <ver> koreader"
else
  echo "  (KOReader source: ${VER} -- must match the device you deploy to)"
fi

# Module-level calls: UIManager:x(), Screen:x(), and friends.
declare -a MODCHECKS=(
  "UIManager|$SRC/frontend/ui/uimanager.lua"
  "NetworkMgr|$SRC/frontend/ui/network/manager.lua"
)
for spec in "${MODCHECKS[@]}"; do
  mod="${spec%%|*}"; path="${spec#*|}"
  [[ -f "$path" ]] || continue
  # Plugin sources only ($ROOT/*.lua). The repo root *is* the plugin, so this
  # must not recurse -- spec/ fakes these modules, and scanning it would check
  # the fakes' method names instead of KOReader's.
  for m in $(grep -ho "${mod}:[a-zA-Z_]*" "$ROOT"/*.lua | sed "s/${mod}://" | sort -u); do
    if grep -q "^function [A-Za-z]*:${m}\b" "$path"; then PASS=$((PASS+1))
    else FAIL=$((FAIL+1)); echo "  MISSING  ${mod}:${m}() not found in $(basename "$path")"; fi
  done
done

# reddle_ui_reader reaches *into* the widget tree TextViewer builds, so what it
# depends on is fields and internals, not just method names -- none of which the
# checks above would notice going away. Each of these is load-bearing: lose one
# and comments render unstyled or taps stop reaching links, silently.
contract() {
  local label="$1" pattern="$2" path="$3"
  if grep -qE "$pattern" "$path"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "  MISSING  ${label} -- not found in $(basename "$path")"
  fi
}

TV="$SRC/frontend/ui/widget/textviewer.lua"
SH="$SRC/frontend/ui/widget/scrollhtmlwidget.lua"
HB="$SRC/frontend/ui/widget/htmlboxwidget.lua"
if [[ -f "$TV" && -f "$SH" && -f "$HB" ]]; then
  contract "TextViewer.html_text_formats (capability probe)" "^ *html_text_formats *=" "$TV"
  contract "TextViewer.is_txt (plain-vs-html branch)"        "self\.is_txt *=" "$TV"
  contract "TextViewer.scroll_widget (the widget we patch)"  "self\.scroll_widget *=" "$TV"
  contract "TextViewer re-inits on font change"              "self:init\(true\)" "$TV"
  # The title-bar menu Reddle hangs its navigation off. Overriding onShowMenu
  # only works while TextViewer still owns the icon and still has a method to
  # fall back to for the display settings.
  contract "TextViewer.show_menu (the title bar's left icon)" "^ *show_menu *=" "$TV"
  contract "TextViewer:onShowMenu (we override and delegate)" "^function TextViewer:onShowMenu" "$TV"
  contract "ScrollHtmlWidget.htmlbox_widget"                 "self\.htmlbox_widget *=" "$SH"
  contract "ScrollHtmlWidget:resetScroll"                    "^function ScrollHtmlWidget:resetScroll" "$SH"
  # Why setDocument frees the bitmap by hand. _render() is a no-op while one
  # exists, setContent does not clear it, and scrollToRatio -- the only thing
  # that does -- bails out when the target page is the page already shown. Lose
  # any of these three and a swap that lands on page 1 redraws the old document.
  contract "HtmlBoxWidget:freeBb (we call it after setContent)" \
    "^function HtmlBoxWidget:freeBb" "$HB"
  contract "_render() is a no-op while a bitmap exists" \
    "^function HtmlBoxWidget:_render" "$HB"
  contract "scrollToRatio skips work when already on that page" \
    "page_num == self\.htmlbox_widget\.page_number" "$SH"
  contract "ScrollHtmlWidget.html_body"                      "self\.html_body" "$SH"
  contract "ScrollHtmlWidget.default_font_size"              "self\.default_font_size" "$SH"
  contract "HtmlBoxWidget:setContent(body, css, font_size)"  "^function HtmlBoxWidget:setContent" "$HB"
  contract "HtmlBoxWidget honours html_link_tapped_callback" "self\.html_link_tapped_callback" "$HB"
  # The reason our CSS must go through setContent and not into the body.
  contract "setContent still builds its own <html><body> wrapper" \
    '"<html>%s<body>%s</body></html>"' "$HB"
  # reddle_ui_reader replaces this method on the instance to widen the hit area
  # (§5.7.2), and reimplements its body -- so both the method and what it calls
  # have to still be there.
  contract "HtmlBoxWidget:getLinkByPosition (we override it)" \
    "^function HtmlBoxWidget:getLinkByPosition" "$HB"
  contract "getLinkByPosition opens a page and asks for its links" \
    "getPageLinks\(\)" "$HB"
  contract "HtmlBoxWidget.document / page_number (our override reads both)" \
    "self\.document:openPage\(self\.page_number\)" "$HB"
fi

# The QR code an unsupported link falls back to (§5.9). QRMessage is required
# with pcall, so a KOReader without it degrades rather than crashes -- but if the
# constructor's fields drift, the code renders at one pixel per module and no
# phone will read it, which looks like nothing at all going wrong.
QR="$SRC/frontend/ui/widget/qrmessage.lua"
QW="$SRC/frontend/ui/widget/qrwidget.lua"
if [[ -f "$QR" && -f "$QW" ]]; then
  contract "QRMessage takes text"              "^ *text *=" "$QR"
  contract "QRMessage takes width/height"      "^ *width *=" "$QR"
  contract "QRWidget defaults to 1px per module without a size" "sq_size = 1" "$QW"
fi

# reddle_ui_links sizes that QR off the screen.
DEV="$SRC/frontend/device/generic/device.lua"
[[ -f "$DEV" ]] && contract "Device.screen" "^ *screen *= *nil," "$DEV"

# Log out asks first. ConfirmBox is faked in the unit specs, so nothing there
# would notice these field names drifting.
# The offline save limit is a bounded number, so it gets a spinner rather than a
# text field. Faked in the unit specs, so nothing there would see these drift.
SW="$SRC/frontend/ui/widget/spinwidget.lua"
if [[ -f "$SW" ]]; then
  contract "SpinWidget.value / value_min / value_max" "^ *value_max *=" "$SW"
  contract "SpinWidget.default_value (the reset arrow)" "^ *default_value *=" "$SW"
  contract "SpinWidget.info_text (explains what a request buys)" "^ *info_text *=" "$SW"
  contract "SpinWidget.unit"                            "^ *unit *=" "$SW"
  contract "SpinWidget.callback(spin) gets the value"   "^ *callback *=" "$SW"
fi

CB="$SRC/frontend/ui/widget/confirmbox.lua"
if [[ -f "$CB" ]]; then
  contract "ConfirmBox.ok_callback" "^ *ok_callback *=" "$CB"
  contract "ConfirmBox.ok_text"     "^ *ok_text *=" "$CB"
fi

# The menu fields the Reddle menu leans on. `sub_item_table_func` is the one that
# matters: Saved builds its per-subreddit list at open time, and the static
# `sub_item_table` would be evaluated once at registration and never again --
# exactly the class of mistake that took the reader down over Menu:setTitle.
# These live in touchmenu.lua, not menu.lua -- the main-menu item table is a
# TouchMenu, and that is the file that reads these fields.
TMT="$SRC/frontend/ui/widget/touchmenu.lua"
if [[ -f "$TMT" ]]; then
  contract "menu item sub_item_table_func (Saved builds lazily)" \
    "item\.sub_item_table_func" "$TMT"
  contract "menu item enabled_func (greys out Log out)" "enabled_func" "$TMT"
  contract "menu item text_func"                        "v\.text_func" "$TMT"
  contract "menu item keep_menu_open"                   "item\.keep_menu_open" "$TMT"
fi

echo "  ${PASS} calls verified, ${FAIL} missing"
[[ $FAIL -eq 0 ]]
