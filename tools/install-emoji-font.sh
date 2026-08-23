#!/usr/bin/env bash
# Install a monochrome emoji font into KOReader, so emoji render instead of
# vanishing.
#
# Why this is needed: KOReader on a Kindle ships fonts chosen for reading prose.
# There is no emoji font, and coverage of the U+1F300+ planes is accidental --
# whatever the other fonts happen to carry. Measured on a Paperwhite 5
# (2026-08-16): U+1F525 and U+1F480 render, U+1F4CC U+1F600 U+1F44D U+1F680
# U+1F3C6 do not, and a missing glyph draws as *nothing at all* -- blank space,
# not a box. So a title made of emoji silently loses half its characters.
#
# Noto Emoji (not Noto *Color* Emoji) is the right font here: it is a normal
# monochrome outline font, so it dithers like text rather than like a photograph,
# and FreeType needs nothing special to draw it. ~1.9 MB, OFL-1.1.
#
# Reddle does not require this. Without it, reddle_emoji substitutes the glyphs
# known to be missing ([rocket], [+1], :) and so on). With it, Reddle detects the
# font and stops substituting -- a real rocket beats "[rocket]".
#
# Usage:
#   ./tools/install-emoji-font.sh /Volumes/Kindle/koreader        # over USB
#   ./tools/install-emoji-font.sh root@192.168.1.42:/mnt/us/koreader
#   ./tools/install-emoji-font.sh root@192.168.1.42:/mnt/us/koreader --port 2222
#
# Restart KOReader afterwards: the font list is built at startup.
#
# To undo: delete the fonts/emoji directory it creates.
set -euo pipefail

FONT_URL="https://github.com/google/fonts/raw/main/ofl/notoemoji/NotoEmoji%5Bwght%5D.ttf"
LICENSE_URL="https://raw.githubusercontent.com/google/fonts/main/ofl/notoemoji/OFL.txt"

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

TARGET="${1:-}"
[[ -z "$TARGET" || "$TARGET" == "-h" || "$TARGET" == "--help" ]] && usage 0

PORT=""
if [[ "${2:-}" == "--port" ]]; then
    PORT="${3:?--port needs a number}"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching Noto Emoji (monochrome)…"
curl -fsSL -o "$TMP/NotoEmoji-Regular.ttf" "$FONT_URL"
curl -fsSL -o "$TMP/LICENSE-NotoEmoji.txt" "$LICENSE_URL"

# A 404 from GitHub arrives as an HTML page with a 200-shaped body in some
# proxies; check we actually got a font before copying it to a device.
if ! head -c 4 "$TMP/NotoEmoji-Regular.ttf" | od -An -c | grep -qE '\\0|true|OTTO'; then
    echo "That download is not a TrueType font -- refusing to install it." >&2
    exit 1
fi
echo "  $(wc -c < "$TMP/NotoEmoji-Regular.ttf") bytes"

if [[ "$TARGET" == *:* ]]; then
    HOST="${TARGET%%:*}"
    PATH_ON_DEVICE="${TARGET#*:}"
    SSH_OPTS=()
    SCP_OPTS=()
    if [[ -n "$PORT" ]]; then
        SSH_OPTS=(-p "$PORT")
        SCP_OPTS=(-P "$PORT")
    fi
    echo "Installing to ${HOST}:${PATH_ON_DEVICE}/fonts/emoji/ …"
    ssh "${SSH_OPTS[@]}" "$HOST" "mkdir -p '${PATH_ON_DEVICE}/fonts/emoji'"
    scp "${SCP_OPTS[@]}" "$TMP/NotoEmoji-Regular.ttf" "$TMP/LICENSE-NotoEmoji.txt" \
        "${HOST}:${PATH_ON_DEVICE}/fonts/emoji/"
else
    [[ -d "$TARGET" ]] || { echo "No such directory: $TARGET" >&2; exit 1; }
    [[ -d "$TARGET/fonts" ]] || {
        echo "$TARGET does not look like a koreader directory (no fonts/)." >&2
        exit 1
    }
    echo "Installing to $TARGET/fonts/emoji/ …"
    mkdir -p "$TARGET/fonts/emoji"
    cp "$TMP/NotoEmoji-Regular.ttf" "$TMP/LICENSE-NotoEmoji.txt" "$TARGET/fonts/emoji/"
fi

echo
echo "Done. Restart KOReader -- the font list is built at startup."
echo "Reddle will notice the font and stop substituting placeholder text."
