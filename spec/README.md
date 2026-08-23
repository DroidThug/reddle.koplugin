# Tests

```sh
luajit spec/run.lua          # 176 unit tests, no device, no network
luajit spec/screens.lua      # renders every screen from the real code
./spec/bridge_spec.sh        # 32 tests for tools/reddle-bridge.sh, curl shimmed
REDDLE_CLIENT_ID=... ./spec/live_test.sh [sub]   # real Reddit API, read-only
```

No busted, no bats, no luarocks: this machine has none of them, and a plugin that
has to survive on a Kindle shouldn't grow a test-only dependency tree. The harness
is `spec/support/harness.lua` (~90 lines).

## What each layer can actually prove

**`spec/run.lua` — unit.** Runs under LuaJIT, the same runtime KOReader uses, with
KOReader's modules faked via `package.loaded`. It covers the code that has no
device dependencies:

- `reddle_api` — header construction (the RedReader UA and lowercase `bearer` are
  asserted on the table the code *passes*, not on what a fake returns), URL and
  query building, `X-Ratelimit-*` parsing, refresh-and-retry-once on 401.
- `reddle_auth` — base64 against the RFC 4648 vectors, the 5-minute refresh
  margin on both sides, the refresh grant's exact body and Basic credential,
  failure paths.
- `reddle_pair` — the **real** module, driven with literal HTTP request bytes and
  a fake socket. This is deliberate: the behaviour worth testing is that
  `SimpleTCPServer` hands the callback only the header block and leaves the body
  in the socket, so the Content-Length read is covered for real.

**`spec/bridge_spec.sh` — shell.** `curl` is shimmed onto `PATH` and `HOME` is a
sandbox, so nothing leaves the machine. Covers the OAuth URL shape (code flow,
`duration=permanent`), state validation against forged callbacks, `#_` fragment
stripping, config/env/CLI precedence, and the device POST.

**`spec/live_test.sh` — integration, live.** Read-only. Two modes:

- **app-only** (client ID alone) uses Reddit's `installed_client` grant, so it needs
  no user approval. Covers listings, pagination, comments, rate limits and the
  User-Agent rules.
- **user** (`REDDLE_REFRESH_TOKEN` set) adds `/api/v1/me` and subscriptions.

It reads the active identity from `reddle_identity.lua` via `tools/identity.sh`, so
it always tests what the plugin actually sends.

A real **user-mode** run on 2026-08-15 (client ID `yH0aTn…`, after a live OAuth approval):

```
  ok    user: client ID is valid and issues an access token
          expires_in=86400s  scope=read mysubreddits identity history
  ok    Reddit sends X-Ratelimit-* (the signal reddle_api.parseRateLimit reads)
          used=1 remaining=9999.0 reset=117s
  note  budget for this window is ~10000, well above the standard 1000/10min
  ok    GET /r/kindle/hot returns a Listing
  ok    listing carries an 'after' cursor (t3_1voz6fe)
  ok    the 'after' cursor advances (reddle_api.nextCursor contract)
  ok    comments endpoint returns the [post, comments] pair
  ok    lowercase 'bearer' works (what reddle_api sends)
  ok    an empty User-Agent is rejected (HTTP 403) -- the header is mandatory
  ok    a UA containing 'isfun' is blocked (HTTP 403)
  ok    GET /api/v1/me -> u/xhuh
  ok    GET /subreddits/mine/subscriber -> 5 subs

  11 passed, 0 failed, 3 notes
```

## Live-established facts (2026-08-15)

These came out of the live run and are now encoded in the unit tests and DESIGN.md §3.2:

- An empty `User-Agent` is rejected with **403**; the header is mandatory.
- A UA containing `isfun` is rejected with **403** — Reddit blocklists dead-app UAs.
- The UA is otherwise not bound to the client ID per-request (a `KOReader/…` UA works).
- Both `bearer` and `Bearer` are accepted.
- Unauthenticated requests to `oauth.reddit.com` get **403**.
- The exempted client ID has a ~10,000/10-min budget vs the standard 1,000.
- **`redreader://rr_oauth_redir` is the redirect URI registered against this App ID** --
  confirmed by a real authorization that completed and returned a refresh token.
- `duration=permanent` with `response_type=code` does return a `refresh_token` for an
  installed app (empty client secret), and the resulting access token lasts 86400s.

## What none of this proves

The unit suite is green and that says nothing about the device paths. Still
unverified, and unverifiable without a Kindle:

- **TLS from Lua** — `socket.http` against `https://oauth.reddit.com` through
  LuaSec. `reddle_http.lua` is the only file the tests never load.
- **`UIManager:insertZMQ`** actually driving `SimpleTCPServer` in the real loop.
- **The iptables hole.** Tests assert only that we *don't* shell out on
  non-Kindle devices; whether the rules work on a Kindle is untested.
- Every widget in `main.lua`.

If the live test passes and the unit suite passes, the remaining risk is
concentrated in exactly those four things.

## Mutation checks

The suite was verified by breaking the code on purpose and confirming tests fail:

| Mutation | Result |
|---|---|
| Drop the `User-Agent` header | 5 failures |
| `bearer` → `Bearer` | 3 failures |
| Retry 401 in a loop instead of once | 1 failure |
| Skip the pairing code check | 1 failure |
| Refresh margin 300 → 30 | 1 failure |
| Corrupt the base64 tail | 3 failures |
| Remove the Content-Length cap | **survived at first** |

The last one found a bad test — it passed because the oversized read failed
anyway. It now asserts the socket is never asked for the attacker-supplied
length, and kills the mutant (2 failures).
