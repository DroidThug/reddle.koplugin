#!/usr/bin/env bash
# Tests for tools/reddle-bridge.sh. No bats on this machine, so: plain asserts.
# Nothing here touches the network -- curl is shimmed on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="${ROOT}/tools/reddle-bridge.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "         $2"; }

assert_contains() { # <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "expected to contain '$3', got: ${2:0:400}"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "should NOT contain '$3', got: ${2:0:400}"; fi
}
assert_status() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi
}

# --- sandbox -----------------------------------------------------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"          # bridge writes ~/.config/reddle
export TMPDIR="$SANDBOX/"

# curl shim: records its argv, replays a canned body.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/curl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG}"
if [[ "$*" == *"/pair"* ]]; then
    printf '%s' "${PAIR_HTTP_CODE:-200}"
    [[ -n "${PAIR_BODY_FILE:-}" ]] && printf 'paired' > "${PAIR_BODY_FILE}"
    exit 0
fi
printf '%s' "${TOKEN_RESPONSE:-{\"access_token\":\"a\",\"refresh_token\":\"RT-123\",\"expires_in\":3600\}}"
SHIM
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH"
export CURL_LOG="$SANDBOX/curl.log"
export REDDLE_CLIENT_ID="test-client-id"

echo
echo "spec/bridge_spec.sh"

# --- auth mode ---------------------------------------------------------------
OUT="$(REDDLE_KINDLE=10.0.0.5:8888 REDDLE_PAIR_CODE=424242 "$BRIDGE" auth 2>&1)"
assert_contains "auth: uses the code flow, not implicit" "$OUT" "response_type=code"
assert_contains "auth: asks for a permanent (refreshable) token" "$OUT" "duration=permanent"
# The default identity is deliberately NOT a borrowed one: a default is an
# endorsement, and nobody should end up using another project's registration
# without choosing to.
assert_not_contains "auth: does not default to a borrowed identity" "$OUT" "redirect_uri=redreader://"
assert_contains "auth: defaults to a self-registered redirect URI" "$OUT" "redirect_uri=http://localhost:8080"

OUT_RR="$(REDDLE_IDENTITY=redreader "$BRIDGE" auth 2>&1)"
assert_contains "auth: REDDLE_IDENTITY selects RedReader's redirect URI" "$OUT_RR" "redirect_uri=redreader://rr_oauth_redir"
assert_contains "auth: and its user agent with it" "$OUT_RR" "org.quantumbadger.redreader"

OUT_DY="$(REDDLE_IDENTITY=dystopia "$BRIDGE" auth 2>&1)"
assert_contains "auth: REDDLE_IDENTITY selects Dystopia too" "$OUT_DY" "redirect_uri=dystopia://response"

# Restore the state file the later callback specs rely on.
OUT="$(REDDLE_KINDLE=10.0.0.5:8888 REDDLE_PAIR_CODE=424242 "$BRIDGE" auth 2>&1)"
assert_contains "auth: uses the compact authorize endpoint" "$OUT" "authorize.compact"
assert_contains "auth: echoes the pairing target" "$OUT" "10.0.0.5:8888"
assert_contains "auth: persists a state file" "$(ls "$SANDBOX/.config/reddle")" "oauth_state"

STATE="$(cat "$SANDBOX/.config/reddle/oauth_state")"
if [[ ${#STATE} -eq 32 ]]; then ok "auth: state is 128 bits of hex"; else bad "auth: state is 128 bits of hex" "len=${#STATE}"; fi

# --- callback: forged / mismatched state -------------------------------------
: > "$CURL_LOG"
OUT="$("$BRIDGE" "redreader://rr_oauth_redir?code=evil&state=not-the-state" 2>&1)"; ST=$?
assert_status "callback: rejects a forged state" 1 "$ST"
assert_contains "callback: says why" "$OUT" "state mismatch"
assert_contains "callback: never called curl for a forged code" "$(cat "$CURL_LOG")" ""
if [[ ! -s "$CURL_LOG" ]]; then ok "callback: no token exchange on forged state"; else bad "callback: no token exchange on forged state" "curl ran: $(cat "$CURL_LOG")"; fi

# --- callback: missing code --------------------------------------------------
OUT="$("$BRIDGE" "redreader://rr_oauth_redir?state=${STATE}" 2>&1)"; ST=$?
assert_status "callback: rejects a callback with no code" 1 "$ST"

# --- callback: every shape the code can arrive in ----------------------------
# What the user can capture varies by browser and method (README, "Getting the
# code"), so the bridge takes the URL, the query string, or the bare code.
paste_gives_code() { # <label> <pasted input>
  : > "$CURL_LOG"
  printf '%s' "$STATE" > "$SANDBOX/.config/reddle/oauth_state"
  REDDLE_KINDLE= REDDLE_PAIR_CODE= "$BRIDGE" "$1" >/dev/null 2>&1
  assert_contains "$2" "$(cat "$CURL_LOG")" "code=THE-CODE"
}
paste_gives_code "redreader://rr_oauth_redir?state=${STATE}&code=THE-CODE#_" \
  "paste: a redreader:// callback URL"
paste_gives_code "dystopia://response?state=${STATE}&code=THE-CODE" \
  "paste: another identity's scheme"
paste_gives_code "state=${STATE}&code=THE-CODE#_" \
  "paste: a bare query string"
paste_gives_code "THE-CODE" \
  "paste: the bare code, no state to check"
paste_gives_code '  "THE-CODE"  ' \
  "paste: strips the quotes and spaces a copy brings along"

# A code that survives the round trip must not pick up the fragment or a stray
# hyphen; the hyphen in THE-CODE is load-bearing (DESIGN.md ss3.3e).
: > "$CURL_LOG"
printf '%s' "$STATE" > "$SANDBOX/.config/reddle/oauth_state"
REDDLE_KINDLE= REDDLE_PAIR_CODE= "$BRIDGE" "state=${STATE}&code=THE-CODE#_" >/dev/null 2>&1
assert_not_contains "paste: never forwards the #_ fragment" "$(cat "$CURL_LOG")" "THE-CODE#"

# A wrong state is refused even when pasted by hand, not just in handler mode.
: > "$CURL_LOG"
printf '%s' "$STATE" > "$SANDBOX/.config/reddle/oauth_state"
OUT="$("$BRIDGE" "state=not-the-state&code=evil" 2>&1)"; ST=$?
assert_status "paste: refuses a pasted URL whose state is wrong" 1 "$ST"
if [[ ! -s "$CURL_LOG" ]]; then ok "paste: no token exchange on a bad pasted state"
else bad "paste: no token exchange on a bad pasted state" "curl ran: $(cat "$CURL_LOG")"; fi

# Nothing at all is a user error, not a code.
: > "$CURL_LOG"
printf '%s' "$STATE" > "$SANDBOX/.config/reddle/oauth_state"
OUT="$(printf '\n' | "$BRIDGE" 2>&1)"; ST=$?
assert_status "paste: an empty paste is refused" 1 "$ST"

# --- callback: happy path, no kindle target ----------------------------------
: > "$CURL_LOG"
printf '%s' "$STATE" > "$SANDBOX/.config/reddle/oauth_state"
OUT="$(REDDLE_KINDLE= REDDLE_PAIR_CODE= "$BRIDGE" "redreader://rr_oauth_redir?code=THE-CODE&state=${STATE}#_" 2>&1)"; ST=$?
assert_status "callback: succeeds without a pairing target" 0 "$ST"
assert_contains "callback: strips the #_ fragment from the code" "$(cat "$CURL_LOG")" "code=THE-CODE"
assert_not_contains "callback: fragment never reaches Reddit" "$(cat "$CURL_LOG")" "THE-CODE#"
assert_contains "callback: sends the active identity's user agent" "$(cat "$CURL_LOG")" "com.example.reddle"
assert_contains "callback: uses installed-app basic auth (empty secret)" "$(cat "$CURL_LOG")" "-u test-client-id:"
assert_contains "callback: exchanges an authorization_code" "$(cat "$CURL_LOG")" "grant_type=authorization_code"
assert_contains "callback: writes a settings file to copy over" "$OUT" "reddle.lua"
assert_contains "callback: settings file holds the refresh token" "$(cat "${TMPDIR}reddle.lua")" "RT-123"
assert_contains "callback: settings file holds the client id" "$(cat "${TMPDIR}reddle.lua")" "test-client-id"

# state must be single-use
OUT="$("$BRIDGE" "redreader://rr_oauth_redir?code=x&state=${STATE}" 2>&1)"; ST=$?
assert_status "callback: the state file is single-use" 1 "$ST"

# --- callback: happy path, pushes to the Kindle ------------------------------
: > "$CURL_LOG"
"$BRIDGE" auth >/dev/null 2>&1
STATE="$(cat "$SANDBOX/.config/reddle/oauth_state")"
: > "$CURL_LOG"
export PAIR_BODY_FILE="$SANDBOX/pairbody"
OUT="$(REDDLE_KINDLE=10.0.0.5:8888 REDDLE_PAIR_CODE=424242 \
      "$BRIDGE" "redreader://rr_oauth_redir?code=C&state=${STATE}" 2>&1)"; ST=$?
assert_status "pair: exits 0 on HTTP 200 from the device" 0 "$ST"
assert_contains "pair: POSTs to the device's /pair endpoint" "$(cat "$CURL_LOG")" "http://10.0.0.5:8888/pair"
assert_contains "pair: sends the one-time code" "$(cat "$CURL_LOG")" '"code":"424242"'
assert_contains "pair: sends the refresh token" "$(cat "$CURL_LOG")" '"refresh_token":"RT-123"'
assert_contains "pair: says it worked" "$OUT" "Paired with 10.0.0.5:8888"

# --- device rejects the pairing code -----------------------------------------
"$BRIDGE" auth >/dev/null 2>&1
STATE="$(cat "$SANDBOX/.config/reddle/oauth_state")"
OUT="$(PAIR_HTTP_CODE=403 REDDLE_KINDLE=10.0.0.5:8888 REDDLE_PAIR_CODE=000000 \
      "$BRIDGE" "redreader://rr_oauth_redir?code=C&state=${STATE}" 2>&1)"; ST=$?
assert_status "pair: fails loudly when the device returns 403" 1 "$ST"
assert_contains "pair: points at the pairing screen on a 403" "$OUT" "pairing screen"

# --- the two bugs from the first real run --------------------------------------
: > "$CURL_LOG"
"$BRIDGE" auth >/dev/null 2>&1
STATE="$(cat "$SANDBOX/.config/reddle/oauth_state")"
OUT="$(REDDLE_KINDLE=192.168.1.42 REDDLE_PAIR_CODE=273189 \
      "$BRIDGE" "redreader://rr_oauth_redir?code=C&state=${STATE}" 2>&1)"
assert_contains "port: a bare IP defaults to 8888, not 80" "$(cat "$CURL_LOG")" "http://192.168.1.42:8888/pair"

# pair mode: push a token we already have, no OAuth round trip
: > "$CURL_LOG"
OUT="$(REDDLE_KINDLE= REDDLE_PAIR_CODE= "$BRIDGE" pair --kindle 10.0.0.9 --code 111222 2>&1)"; ST=$?
assert_status "pair mode: succeeds using the saved refresh token" 0 "$ST"
assert_contains "pair mode: uses the saved token, no token exchange" "$(cat "$CURL_LOG")" "10.0.0.9:8888/pair"
assert_not_contains "pair mode: does not call the token endpoint" "$(cat "$CURL_LOG")" "access_token"
assert_contains "pair mode: sends the pairing code given" "$(cat "$CURL_LOG")" '"code":"111222"'

OUT="$("$BRIDGE" pair --kindle 10.0.0.9 2>&1)"; ST=$?
assert_status "pair mode: refuses without a pairing code" 1 "$ST"
# the target is remembered between runs; the code never is
: > "$CURL_LOG"
OUT="$("$BRIDGE" pair --code 999888 2>&1)"; ST=$?
assert_status "pair mode: reuses the remembered Kindle address" 0 "$ST"
assert_contains "pair mode: remembered target is the last one used" "$(cat "$CURL_LOG")" "10.0.0.9:8888/pair"
assert_not_contains "config: never stores the single-use pairing code" \
  "$(cat "$SANDBOX/.config/reddle/config")" "PAIR_CODE="

# --- reddit rejects the authorization code -----------------------------------
"$BRIDGE" auth >/dev/null 2>&1
STATE="$(cat "$SANDBOX/.config/reddle/oauth_state")"
OUT="$(TOKEN_RESPONSE='{"error":"invalid_grant"}' \
      "$BRIDGE" "redreader://rr_oauth_redir?code=C&state=${STATE}" 2>&1)"; ST=$?
assert_status "exchange: fails when there is no refresh_token" 1 "$ST"
assert_contains "exchange: shows Reddit's error" "$OUT" "invalid_grant"

# --- missing client id -------------------------------------------------------
OUT="$(REDDLE_CLIENT_ID= "$BRIDGE" auth 2>&1)"; ST=$?
assert_status "config: refuses to run without a client id" 1 "$ST"

# --device is the name the docs use now; --kindle still works, because it is
# what every older README and shell history says.
: > "$CURL_LOG"
OUT="$(REDDLE_KINDLE= REDDLE_PAIR_CODE= "$BRIDGE" pair --device 10.0.0.7 --code 111222 2>&1)"; ST=$?
assert_status "pair mode: --device is accepted" 0 "$ST"
assert_contains "pair mode: --device targets the right host" "$(cat "$CURL_LOG")" "10.0.0.7:8888/pair"

: > "$CURL_LOG"
OUT="$(REDDLE_DEVICE=10.0.0.8:8888 REDDLE_PAIR_CODE= "$BRIDGE" pair --code 111222 2>&1)"; ST=$?
assert_status "pair mode: REDDLE_DEVICE is accepted" 0 "$ST"
assert_contains "pair mode: REDDLE_DEVICE targets the right host" "$(cat "$CURL_LOG")" "10.0.0.8:8888/pair"

# A config file written before the --kindle -> --device rename still has to work:
# it stores KINDLE=, and after the rename nothing read that key.
: > "$CURL_LOG"
printf "CLIENT_ID='%s'\nKINDLE='10.0.0.11:8888'\nSAVED_REFRESH='rt-from-before'\n" \
  "$REDDLE_CLIENT_ID" > "$SANDBOX/.config/reddle/config"
OUT="$(REDDLE_KINDLE= REDDLE_DEVICE= REDDLE_PAIR_CODE= "$BRIDGE" pair --code 121212 2>&1)"; ST=$?
assert_status "config: an old KINDLE= entry still names the device" 0 "$ST"
assert_contains "config: and points at the right host" "$(cat "$CURL_LOG")" "10.0.0.11:8888/pair"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]

