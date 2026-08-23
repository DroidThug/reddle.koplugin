#!/usr/bin/env bash
# Reddle desktop bridge (DESIGN.md §3.3a / §3.3c).
#
# Two jobs:
#   1. Be the handler for redreader:// so the browser hands us the OAuth code.
#   2. Exchange it for a refresh token and push that to the Kindle's pairing listener.
#
# Usage:
#   reddle-bridge.sh auth                          # print the authorize URL, save state
#   reddle-bridge.sh "redreader://...?code=..."     # handler mode (browser invokes this)
#   reddle-bridge.sh pair --device 192.168.1.42 --code 123456
#                                                  # push an ALREADY-OBTAINED refresh
#                                                  # token to the device. No OAuth.
# The port defaults to 8888 (the plugin's default) when you omit it.
#
# The Kindle target can also come from the environment, so the handler (which the
# browser invokes with no arguments of ours) still knows where to send things:
#   export REDDLE_DEVICE=192.168.1.42:8888
#   export REDDLE_PAIR_CODE=123456
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Identity (user agent + redirect URI) comes from reddle_identity.lua -- one
# source of truth shared with the plugin. See tools/identity.sh.
. "${ROOT}/tools/identity.sh"
reddle_identity_load "$ROOT" || exit 1

CLIENT_ID="${REDDLE_CLIENT_ID:-}"
DEVICE="${REDDLE_DEVICE:-${REDDLE_KINDLE:-}}"
PAIR_CODE="${REDDLE_PAIR_CODE:-}"
REDIRECT_URI="$REDDLE_REDIRECT_URI"
USER_AGENT="$REDDLE_UA"
SCOPE="${REDDLE_SCOPE:-identity,read,mysubreddits,history}"  # write scopes are not used yet; override with REDDLE_SCOPE
STATE_DIR="${HOME}/.config/reddle"
STATE_FILE="${STATE_DIR}/oauth_state"
CONF_FILE="${STATE_DIR}/config"

# Handler mode gets no environment from the browser on some setups, so persist
# the target between `auth` and the callback. Precedence, lowest to highest:
# saved config < environment < command line. (Sourcing the config unconditionally
# used to clobber the environment, which made `REDDLE_CLIENT_ID= … ` a no-op.)
if [[ -f "$CONF_FILE" ]]; then
  . "$CONF_FILE"
  [[ -n "${REDDLE_CLIENT_ID+set}" ]] && CLIENT_ID="$REDDLE_CLIENT_ID"
  [[ -n "${REDDLE_KINDLE+set}" ]]    && DEVICE="$REDDLE_KINDLE"
  [[ -n "${REDDLE_DEVICE+set}" ]]    && DEVICE="$REDDLE_DEVICE"
  # Last, so the environment still wins: a config written before the
  # --kindle -> --device rename says KINDLE=, and nothing read that key
  # afterwards, so the remembered address was silently dropped.
  [[ -z "$DEVICE" && -n "${KINDLE:-}" ]] && DEVICE="$KINDLE"
  [[ -n "${REDDLE_PAIR_CODE+set}" ]] && PAIR_CODE="$REDDLE_PAIR_CODE"
  true
fi

MODE="callback"
URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    auth)       MODE="auth"; shift ;;
    pair)       MODE="pair"; shift ;;
    --device|--kindle) DEVICE="$2"; shift 2 ;;   # --kindle kept: it is what the old docs said
    --code)     PAIR_CODE="$2"; shift 2 ;;
    --client-id) CLIENT_ID="$2"; shift 2 ;;
    --*) echo "unknown option: $1" >&2; exit 2 ;;
    # Anything else is the callback, in whatever shape the user captured it: a
    # redreader:// or dystopia:// URL, a query string, or the bare code. It is
    # validated in callback mode, not here -- see extract_code.
    *)          URL="$1"; shift ;;
  esac
done

[[ -n "$CLIENT_ID" ]] || { echo "Set REDDLE_CLIENT_ID (see DESIGN.md §3.2)." >&2; exit 1; }

# The device listens on 8888 unless changed in Reddle ▸ Pairing port. Without this
# a bare IP would POST to port 80 and simply hang.
if [[ -n "$DEVICE" && "$DEVICE" != *:* ]]; then
  DEVICE="${DEVICE}:8888"
fi

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

# When the browser invokes this via the redreader:// handler there is no terminal
# to print to, so every invocation leaves a trace. Never log the URL's code= or
# any token -- just enough to see that the chain fired.
LOG="${STATE_DIR}/bridge.log"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }
log "invoked mode=${MODE} args=$# url=$([[ -n "$URL" ]] && echo "yes" || echo "no")"

save_conf() {
  umask 077
  {
    echo "CLIENT_ID='${CLIENT_ID}'"
    echo "DEVICE='${DEVICE}'"
    # PAIR_CODE is deliberately NOT saved: the Kindle generates a fresh one every
    # time the pairing screen opens, so a remembered code is always a stale code.
    # NB: a bare `[[ ... ]] && echo` as the last line would return 1 when REFRESH is
    # empty, and `set -e` would take the whole script down with it.
    if [[ -n "${REFRESH:-}" ]]; then echo "SAVED_REFRESH='${REFRESH}'"; fi
  } > "$CONF_FILE"
}

if [[ "$MODE" == "auth" ]]; then
  STATE="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  umask 077; printf '%s' "$STATE" > "$STATE_FILE"
  save_conf
  cat <<EOF
Open this and approve:

https://www.reddit.com/api/v1/authorize.compact?client_id=${CLIENT_ID}&response_type=code&state=${STATE}&redirect_uri=${REDIRECT_URI}&duration=permanent&scope=${SCOPE}

Identity:      ${REDDLE_IDENTITY} -- ${USER_AGENT}
Target device: ${DEVICE:-<not set: pass --device IP:PORT>}   code: ${PAIR_CODE:-<not set>}
EOF
  exit 0
fi

# Push to the device. Plaintext over the LAN by design -- see DESIGN.md §3.3c.
push_to_kindle() {
  local body http_code
  body="$(printf '{"code":"%s","client_id":"%s","refresh_token":"%s"}' \
    "$PAIR_CODE" "$CLIENT_ID" "$REFRESH")"
  http_code="$(curl -sS -o /tmp/reddle_pair_resp -w '%{http_code}' \
    --connect-timeout 5 --max-time 15 \
    -X POST "http://${DEVICE}/pair" \
    -H "Content-Type: application/json" \
    --data "$body")"
  if [[ "$http_code" == "200" ]]; then
    log "paired with ${DEVICE}"
    echo "Paired with ${DEVICE}."
    rm -f /tmp/reddle_pair_resp
  else
    echo "Kindle returned HTTP ${http_code}: $(cat /tmp/reddle_pair_resp 2>/dev/null)" >&2
    if [[ "$http_code" == "000" ]]; then
      echo "Nothing answered at http://${DEVICE}/pair -- check the IP and that the" >&2
      echo "pairing screen is still open (it stops after 5 minutes)." >&2
    else
      echo "Is the pairing screen still open, and does the code match?" >&2
    fi
    exit 1
  fi
}

# Find a refresh token we already have: environment, saved config, or the file the
# last successful auth wrote.
find_refresh() {
  [[ -n "${REFRESH:-}" ]] && return 0
  if [[ -n "${SAVED_REFRESH:-}" ]]; then REFRESH="$SAVED_REFRESH"; return 0; fi
  local f
  for f in "${TMPDIR:-/tmp}/reddle.lua" "${TMPDIR:-/tmp}reddle.lua" "/tmp/reddle.lua"; do
    if [[ -f "$f" ]]; then
      REFRESH="$(sed -n 's/.*\["refresh_token"\] = "\([^"]*\)".*/\1/p' "$f" | head -1)"
      [[ -n "$REFRESH" ]] && { echo "Using the refresh token from ${f}"; return 0; }
    fi
  done
  return 1
}

if [[ "$MODE" == "pair" ]]; then
  [[ -n "$DEVICE" ]]    || { echo "pair needs --device IP[:PORT]" >&2; exit 1; }
  [[ -n "$PAIR_CODE" ]] || { echo "pair needs --code NNNNNN (shown on the Kindle)" >&2; exit 1; }
  if ! find_refresh; then
    echo "No refresh token yet. Run '$0 auth' and approve in a browser first." >&2
    exit 1
  fi
  push_to_kindle
  save_conf   # remember this Kindle (and the token) for next time
  exit 0
fi

# ---- callback mode ----------------------------------------------------------
param() { printf '%s' "$1" | sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p"; }

# What arrives here is whatever the user could get out of a browser, and that
# varies by how they captured it (README, "Getting the code"). Accept all of it:
#
#   redreader://rr_oauth_redir?state=…&code=…#_   a registered scheme handler
#   dystopia://response?state=…&code=…            ditto, other identity
#   state=…&code=…#_                              a copied query string
#   PSgal3YBwWIMK2TzSinH-mM53adHkQ                the bare code
#
# plus surrounding whitespace or quotes, which a paste usually brings along.
# Reddit appends a bare "#_" fragment; everything from "#" on is dropped.
#
# Deliberately NOT accepted: a code transcribed by eye from macOS's "no
# application set to open the URL" dialog. That dialog hyphenates at the wrap
# point and Reddit's codes contain real hyphens, so a transcription silently
# yields a wrong code (DESIGN.md §3.3e). Capture must be copy-paste.
#
# A bare code is the only input with no "=" and no "://" in it. Anything else is
# a URL or a query string, and must actually carry code= -- otherwise a callback
# that arrived without one would be mistaken for a code and sent to Reddit whole.
structured()    { case "$1" in *://*|*=*) return 0 ;; *) return 1 ;; esac; }
extract_code()  { if structured "$1"; then param "&$1" code; else printf '%s' "$1"; fi; }
extract_state() { if structured "$1"; then param "&$1" state; else printf '%s' ""; fi; }
clean() { printf '%s' "$1" | tr -d '\r\n' | sed -e 's/^[[:space:]"'"'"']*//' -e 's/[[:space:]"'"'"']*$//'; }

if [[ -z "$URL" ]]; then
  echo "Paste the whole callback URL, or just the code= value (NOT the 6-digit" >&2
  echo "pairing code). See the README for how to get it out of the browser." >&2
  read -r -p "callback URL or code: " URL
fi

URL="$(clean "$URL")"
[[ -n "$URL" ]] || { echo "nothing pasted" >&2; exit 1; }
CODE="$(clean "$(extract_code "$URL")")"
CODE="${CODE%%#*}"
GOT_STATE="$(extract_state "$URL")"
[[ -n "$CODE" ]] || { echo "no code found in what you pasted" >&2; exit 1; }

# The state check is the only thing standing between us and a forged code, and it
# matters most in handler mode -- argv comes from the browser, and any page can
# invoke a registered scheme. A paste that carries no state= is the user acting
# deliberately, so it is allowed through; one that carries a wrong state is not.
WANT_STATE="$(cat "$STATE_FILE" 2>/dev/null || true)"
if [[ -z "$WANT_STATE" ]]; then
  # Single-use by design: a previous callback (or a test) already consumed it.
  log "REFUSED: no pending state -- already used, or 'auth' was never run"
  echo "No pending authorization. The state is single-use and this one is spent." >&2
  echo "Run '$0 auth' for a fresh URL, then approve it once." >&2
  exit 1
fi
if [[ -n "$GOT_STATE" && "$GOT_STATE" != "$WANT_STATE" ]]; then
  log "REFUSED: state mismatch (possible forgery)"
  echo "state mismatch -- refusing. Run '$0 auth' again." >&2
  exit 1
fi
if [[ -z "$GOT_STATE" ]]; then
  log "no state in pasted input; accepting on the user's say-so"
fi
log "state ok, exchanging code"
rm -f "$STATE_FILE"

RESP="$(curl -sS -X POST https://www.reddit.com/api/v1/access_token \
  -u "${CLIENT_ID}:" -A "${USER_AGENT}" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=${CODE}" \
  --data-urlencode "redirect_uri=${REDIRECT_URI}")"

REFRESH="$(printf '%s' "$RESP" | sed -n 's/.*"refresh_token": *"\([^"]*\)".*/\1/p')"
[[ -n "$REFRESH" ]] || {
  log "FAILED: no refresh_token ($(printf '%s' "$RESP" | tr -d '\n' | cut -c1-120))"
  echo "No refresh_token in response:" >&2; printf '%s\n' "$RESP" >&2; exit 1; }
log "got refresh_token"
save_conf   # so `pair` can re-push it later without another authorization

if [[ -z "$DEVICE" || -z "$PAIR_CODE" ]]; then
  OUT="${TMPDIR:-/tmp}/reddle.lua"
  umask 077
  printf 'return {\n    ["client_id"] = "%s",\n    ["refresh_token"] = "%s",\n}\n' \
    "$CLIENT_ID" "$REFRESH" > "$OUT"
  echo "No --device/--code given. Wrote ${OUT}; copy to /mnt/us/koreader/settings/reddle.lua"
  exit 0
fi

push_to_kindle
