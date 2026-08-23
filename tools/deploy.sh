#!/usr/bin/env bash
# Copy the plugin onto a device over SSH.
#
#   ./tools/deploy.sh root@192.168.0.242 -p 2222
#   REDDLE_KOREADER=/mnt/us/koreader ./tools/deploy.sh root@device
#
# Only the files that ship are copied -- spec/, tools/ and assets/ stay here.
# Nothing on the device is deleted except the plugin directory itself, so the
# settings file and the saved-post archive survive a redeploy.
set -euo pipefail

TARGET=""
PORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    # ssh spells this -p and scp spells it -P, which is the whole reason this
    # takes a port of its own instead of forwarding raw ssh options.
    -p|-P|--port) PORT="$2"; shift 2 ;;
    -h|--help)    echo "usage: $0 user@host [-p PORT]"; exit 0 ;;
    -*)           echo "unknown option: $1" >&2; exit 2 ;;
    *)            TARGET="$1"; shift ;;
  esac
done
[[ -n "$TARGET" ]] || { echo "usage: $0 user@host [-p PORT]" >&2; exit 2; }

KOREADER="${REDDLE_KOREADER:-/mnt/us/koreader}"
DEST="${KOREADER}/plugins/reddle.koplugin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# One authenticated connection, reused by every command below: dropbear asks for
# a password per connection, and a deploy that prompts four times is a deploy
# nobody runs twice.
CTL="$(mktemp -u "${TMPDIR:-/tmp}/reddle-deploy.XXXXXX")"
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=${CTL}" -o ControlPersist=120)
[[ -n "$PORT" ]] && SSH_OPTS+=(-p "$PORT")
SCP_OPTS=(-o ControlMaster=auto -o "ControlPath=${CTL}" -o ControlPersist=120)
[[ -n "$PORT" ]] && SCP_OPTS+=(-P "$PORT")

cleanup() { ssh "${SSH_OPTS[@]}" -O exit "$TARGET" 2>/dev/null || true; }
trap cleanup EXIT

# Fail here rather than half way through a copy that leaves a broken plugin.
ssh "${SSH_OPTS[@]}" "$TARGET" "test -d '${KOREADER}/plugins'" || {
  echo "no ${KOREADER}/plugins on ${TARGET} -- set REDDLE_KOREADER" >&2; exit 1; }

echo "deploying to ${TARGET}:${DEST}"
ssh "${SSH_OPTS[@]}" "$TARGET" "rm -rf '${DEST}' && mkdir -p '${DEST}'"
scp -q "${SCP_OPTS[@]}" "$ROOT"/*.lua "$ROOT/OWNER" "$ROOT/LICENSE" "$TARGET:${DEST}/"
# Translations ship with the plugin (the release zip carries them too); without
# these the device silently runs English whatever language KOReader is set to.
if [ -d "$ROOT/l10n" ]; then
  scp -qr "${SCP_OPTS[@]}" "$ROOT/l10n" "$TARGET:${DEST}/"
fi

echo "copied $(ssh "${SSH_OPTS[@]}" "$TARGET" "ls '${DEST}' | wc -l" | tr -d ' ') files"
echo "restart KOReader on the device to load it."
