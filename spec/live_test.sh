#!/usr/bin/env bash
# Live smoke test against the real Reddit API (DESIGN.md §4).
#
# READ-ONLY BY DESIGN. Never votes, saves, submits, edits or subscribes.
#
# Two modes:
#   app-only  (client ID only)   -- no user approval needed. Reddit's
#                                   installed_client grant. Covers listings,
#                                   pagination, comments, rate limits, UA rules.
#   user      (+ refresh token)  -- adds identity and subscription endpoints.
#
# Usage:
#   export REDDLE_CLIENT_ID=...
#   export REDDLE_REFRESH_TOKEN=...      # optional; enables user mode
#   ./spec/live_test.sh [subreddit]
#
# Secrets come from the environment or ~/.config/reddle/config, never argv.
set -uo pipefail

SUB="${1:-kindle}"
CONF="${HOME}/.config/reddle/config"
PASS=0; FAIL=0; NOTE=0

ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [[ -n "${2:-}" ]] && echo "          ${2:0:300}"; }
note() { NOTE=$((NOTE+1)); echo "  note  $1"; }
info() { echo "          $1"; }

command -v jq >/dev/null || { echo "needs jq: brew install jq" >&2; exit 2; }

CLIENT_ID="${REDDLE_CLIENT_ID:-}"
REFRESH="${REDDLE_REFRESH_TOKEN:-}"
[[ -z "$CLIENT_ID" && -f "$CONF" ]] && { . "$CONF"; CLIENT_ID="${CLIENT_ID:-}"; }
[[ -n "$CLIENT_ID" ]] || { echo "Set REDDLE_CLIENT_ID." >&2; exit 1; }

# Pick up whatever reddle-bridge.sh last wrote, so a successful pairing run flows
# straight into user mode without exporting anything by hand.
if [[ -z "$REFRESH" ]]; then
  for cand in "${TMPDIR:-/tmp}/reddle.lua" "${TMPDIR:-/tmp}reddle.lua" "/tmp/reddle.lua"; do
    if [[ -f "$cand" ]]; then
      REFRESH="$(sed -n 's/.*\["refresh_token"\] = "\([^"]*\)".*/\1/p' "$cand" | head -1)"
      [[ -n "$REFRESH" ]] && { echo "  (refresh token from ${cand})"; break; }
    fi
  done
fi

# Same source of truth as the plugin: reddle_identity.lua.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT}/tools/identity.sh"
reddle_identity_load "$ROOT" || exit 1
UA="${REDDLE_USER_AGENT:-$REDDLE_UA}"
HDR="$(mktemp)"; trap 'rm -f "$HDR"' EXIT

echo
echo "spec/live_test.sh -- read-only, live against oauth.reddit.com"
echo "identity=${REDDLE_IDENTITY}  client_id=${CLIENT_ID:0:6}…"
echo "ua=${UA}"
echo

# --- token -------------------------------------------------------------------
if [[ -n "$REFRESH" ]]; then
  MODE="user"
  TJ="$(curl -sS -A "$UA" -u "${CLIENT_ID}:" \
        --data-urlencode grant_type=refresh_token \
        --data-urlencode "refresh_token=${REFRESH}" \
        https://www.reddit.com/api/v1/access_token)"
else
  MODE="app-only"
  TJ="$(curl -sS -A "$UA" -u "${CLIENT_ID}:" \
        -d grant_type=https://oauth.reddit.com/grants/installed_client \
        -d device_id=DO_NOT_TRACK_THIS_DEVICE \
        https://www.reddit.com/api/v1/access_token)"
fi

TOKEN="$(printf '%s' "$TJ" | jq -r '.access_token // empty')"
if [[ -n "$TOKEN" ]]; then
  ok "${MODE}: client ID is valid and issues an access token"
  info "expires_in=$(printf '%s' "$TJ" | jq -r '.expires_in')s  scope=$(printf '%s' "$TJ" | jq -r '.scope')"
else
  bad "${MODE}: token request" "$TJ"; echo; exit 1
fi

get() { curl -sS -D "$HDR" -A "$UA" -H "Authorization: bearer ${TOKEN}" "https://oauth.reddit.com$1"; }
hdr() { grep -i "^$1:" "$HDR" | tr -d '\r' | cut -d' ' -f2-; }

# --- rate limits -------------------------------------------------------------
P1="$(get "/r/${SUB}/hot?limit=3&raw_json=1")"
REM="$(hdr x-ratelimit-remaining)"; USED="$(hdr x-ratelimit-used)"; RESET="$(hdr x-ratelimit-reset)"
if [[ -n "$REM" ]]; then
  ok "Reddit sends X-Ratelimit-* (the signal reddle_api.parseRateLimit reads)"
  info "used=${USED} remaining=${REM} reset=${RESET}s"
  WINDOW="$(printf '%.0f' "$(echo "${REM:-0} + ${USED:-0}" | bc 2>/dev/null || echo 0)")"
  if [[ "$WINDOW" -gt 1000 ]]; then
    note "budget for this window is ~${WINDOW}, well above the standard 1000/10min"
    info "consistent with an exempted client ID, not the plain free tier"
  fi
else
  bad "Reddit sends X-Ratelimit-*" "no headers; parseRateLimit will see nil"
fi

# --- listings ----------------------------------------------------------------
KIND="$(printf '%s' "$P1" | jq -r '.kind // empty')"
IDS1="$(printf '%s' "$P1" | jq -r '[.data.children[].data.id] | join(",")')"
AFTER="$(printf '%s' "$P1" | jq -r '.data.after // empty')"
[[ "$KIND" == "Listing" ]] && ok "GET /r/${SUB}/hot returns a Listing" || bad "GET /r/${SUB}/hot" "$P1"
[[ -n "$AFTER" ]] && ok "listing carries an 'after' cursor (${AFTER})" || bad "listing carries an 'after' cursor"
info "page 1: ${IDS1}"

if [[ -n "$AFTER" ]]; then
  IDS2="$(get "/r/${SUB}/hot?limit=3&after=${AFTER}&raw_json=1" | jq -r '[.data.children[].data.id] | join(",")')"
  info "page 2: ${IDS2}"
  [[ -n "$IDS2" && "$IDS1" != "$IDS2" ]] \
    && ok "the 'after' cursor advances (reddle_api.nextCursor contract)" \
    || bad "the 'after' cursor advances" "page1=${IDS1} page2=${IDS2}"
fi

# --- comments ----------------------------------------------------------------
PID="$(printf '%s' "$P1" | jq -r '.data.children[0].data.id // empty')"
if [[ -n "$PID" ]]; then
  CM="$(get "/r/${SUB}/comments/${PID}?depth=3&limit=20&raw_json=1")"
  LEN="$(printf '%s' "$CM" | jq -r 'length')"
  MORE="$(printf '%s' "$CM" | jq -r '[.. | objects | select(.kind? == "more")] | length')"
  [[ "$LEN" == "2" ]] \
    && { ok "comments endpoint returns the [post, comments] pair"; info "'more' stubs needing /api/morechildren: ${MORE}"; } \
    || bad "comments endpoint returns the [post, comments] pair" "length=${LEN}"
fi

# --- header rules ------------------------------------------------------------
probe() { # <ua> <auth-scheme>
  curl -sS -o /dev/null -w '%{http_code}' -A "$1" \
    -H "Authorization: $2 ${TOKEN}" "https://oauth.reddit.com/r/${SUB}/hot?limit=1&raw_json=1"
}
[[ "$(probe "$UA" bearer)" == "200" ]] \
  && ok "lowercase 'bearer' works (what reddle_api sends)" \
  || bad "lowercase 'bearer' works"

[[ "$(probe "$UA" Bearer)" == "200" ]] \
  && note "capital 'Bearer' also works -- Reddit is not case-sensitive here" \
  || note "capital 'Bearer' is rejected; the lowercase form is load-bearing"

C_EMPTY="$(probe "" bearer)"
[[ "$C_EMPTY" == "200" ]] \
  && note "an empty User-Agent is accepted (HTTP ${C_EMPTY})" \
  || ok "an empty User-Agent is rejected (HTTP ${C_EMPTY}) -- the header is mandatory"

C_BLOCKED="$(probe "android:com.andrewshu.android.reddit:v5.0 (isfun)" bearer)"
[[ "$C_BLOCKED" == "200" ]] \
  && note "a UA containing 'isfun' is accepted here" \
  || ok "a UA containing 'isfun' is blocked (HTTP ${C_BLOCKED}) -- Reddit blocklists dead-app UAs"

C_KO="$(probe "KOReader/2024.11" bearer)"
[[ "$C_KO" == "200" ]] \
  && note "a KOReader UA is also accepted (HTTP 200) -- the UA is not tied to the client ID per-request," \
  || note "a KOReader UA is rejected (HTTP ${C_KO})"
[[ "$C_KO" == "200" ]] && info "but reddle_api still sets it explicitly: socketutil would otherwise leak KOReader's"

# --- user-scoped endpoints ---------------------------------------------------
if [[ "$MODE" == "user" ]]; then
  ME="$(get /api/v1/me?raw_json=1)"
  NAME="$(printf '%s' "$ME" | jq -r '.name // empty')"
  [[ -n "$NAME" ]] && ok "GET /api/v1/me -> u/${NAME}" || bad "GET /api/v1/me" "$ME"
  SUBS="$(get '/subreddits/mine/subscriber?limit=5&raw_json=1')"
  N="$(printf '%s' "$SUBS" | jq -r '.data.children | length' 2>/dev/null)"
  [[ "$N" =~ ^[0-9]+$ ]] && ok "GET /subreddits/mine/subscriber -> ${N} subs" || bad "GET /subreddits/mine/subscriber" "$SUBS"
else
  ME_KEYS="$(get /api/v1/me?raw_json=1 | jq -c 'keys')"
  note "app-only mode: /api/v1/me returns ${ME_KEYS} -- no user identity, as expected"
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' -A "$UA" -H "Authorization: bearer ${TOKEN}" \
          "https://oauth.reddit.com/subreddits/mine/subscriber?limit=5&raw_json=1")"
  note "app-only mode: /subreddits/mine/subscriber -> HTTP ${CODE} (needs a user token)"
  info "set REDDLE_REFRESH_TOKEN to cover the user-scoped endpoints"
fi

echo
echo "${PASS} passed, ${FAIL} failed, ${NOTE} notes"
[[ $FAIL -eq 0 ]]
