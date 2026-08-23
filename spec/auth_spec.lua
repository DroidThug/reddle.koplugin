local Auth = require("reddle_auth")
local Identity = require("reddle_identity")
local stubs = require("spec.support.stubs")
local json = require("spec.support.json")

local function authWith(store_data, responses, now)
    local store = stubs.store(store_data)
    local t = stubs.transport(responses)
    local clock = { t = now or 1000 }
    local auth = Auth.new{
        store = store, transport = t.fn, json = json,
        now = function() return clock.t end,
    }
    return auth, store, t, clock
end

describe("reddle_auth", function()

    describe("base64", function()
        it("matches the RFC 4648 test vectors", function()
            assert_equal("", Auth.base64(""))
            assert_equal("Zg==", Auth.base64("f"))
            assert_equal("Zm8=", Auth.base64("fo"))
            assert_equal("Zm9v", Auth.base64("foo"))
            assert_equal("Zm9vYg==", Auth.base64("foob"))
            assert_equal("Zm9vYmE=", Auth.base64("fooba"))
            assert_equal("Zm9vYmFy", Auth.base64("foobar"))
        end)

        it("encodes the installed-app basic credential (client_id + empty secret)", function()
            -- The trailing colon is what makes it a non-confidential client.
            assert_equal("bXljbGllbnRpZDo=", Auth.base64("myclientid:"))
        end)
    end)

    describe("getAccessToken", function()
        it("refuses without credentials and never hits the network", function()
            local auth, _, t = authWith({}, { { body = "{}" } })
            local token, err = auth:getAccessToken()
            assert_nil(token)
            assert_match("no credentials", err)
            assert_equal(0, #t.requests)
        end)

        it("reuses a cached token that is not near expiry", function()
            local auth, _, t = authWith(
                { client_id = "cid", refresh_token = "rt", access_token = "cached", expires_at = 5000 },
                { { body = "{}" } }, 1000)
            assert_equal("cached", auth:getAccessToken())
            assert_equal(0, #t.requests)
        end)

        it("refreshes inside the 5 minute margin", function()
            -- expires_at 1200, now 1000 -> 200s left, inside REFRESH_MARGIN
            local auth, store, t = authWith(
                { client_id = "cid", refresh_token = "rt", access_token = "old", expires_at = 1200 },
                { { body = '{"access_token":"new","expires_in":3600}' } }, 1000)
            assert_equal("new", auth:getAccessToken())
            assert_equal(1, #t.requests)
            assert_equal("new", store.data.access_token)
            assert_equal(4600, store.data.expires_at)
        end)

        it("does not refresh just outside the margin", function()
            -- expires_at 1301, now 1000 -> 301s left
            local auth, _, t = authWith(
                { client_id = "cid", refresh_token = "rt", access_token = "old", expires_at = 1301 },
                { { body = '{"access_token":"new"}' } }, 1000)
            assert_equal("old", auth:getAccessToken())
            assert_equal(0, #t.requests)
        end)

        it("POSTs the refresh grant with Basic auth and the RedReader UA", function()
            local auth, _, t = authWith(
                { client_id = "myclientid", refresh_token = "rt-123" },
                { { body = '{"access_token":"new","expires_in":3600}' } })
            auth:getAccessToken()
            local req = t.requests[1]
            assert_equal("https://www.reddit.com/api/v1/access_token", req.url)
            assert_equal("POST", req.method)
            assert_equal("Basic bXljbGllbnRpZDo=", req.headers["Authorization"])
            assert_equal(Identity.userAgent(), req.headers["User-Agent"])
            assert_equal("grant_type=refresh_token&refresh_token=rt-123", req.body)
            assert_equal("application/x-www-form-urlencoded", req.headers["Content-Type"])
        end)

        it("defaults to a one hour lifetime when expires_in is missing", function()
            local auth, store = authWith(
                { client_id = "cid", refresh_token = "rt" },
                { { body = '{"access_token":"new"}' } }, 1000)
            auth:getAccessToken()
            assert_equal(4600, store.data.expires_at)
        end)

        it("reports the failure when Reddit rejects the refresh token", function()
            local auth, store = authWith(
                { client_id = "cid", refresh_token = "revoked" },
                { { body = '{"message":"Unauthorized","error":401}', code = 401 } })
            local token, err = auth:getAccessToken()
            assert_nil(token)
            assert_match("token refresh failed", err)
            assert_match("401", err)
            assert_nil(store.data.access_token)
        end)

        it("treats a 200 without access_token as a failure", function()
            local auth = authWith(
                { client_id = "cid", refresh_token = "rt" },
                { { body = '{"error":"invalid_grant"}', code = 200 } })
            local token, err = auth:getAccessToken()
            assert_nil(token)
            assert_match("token refresh failed", err)
        end)
    end)

    -- The call the desktop bridge used to make for us. Doing it on the device is
    -- what lets pairing work from a browser alone (DESIGN.md §3.3d).
    describe("exchangeCode", function()
        local function ok_response()
            return { { body = '{"access_token":"at","refresh_token":"RT-NEW","expires_in":3600}' } }
        end

        it("trades an authorization code for a refresh token", function()
            local auth, _, t = authWith({}, ok_response())
            assert_equal("RT-NEW", auth:exchangeCode("cid", "AUTH-1"))
            assert_equal(1, #t.requests)
            assert_match("grant_type=authorization_code", t.requests[1].body)
            assert_match("code=AUTH%-1", t.requests[1].body)
        end)

        it("sends the active identity's redirect URI by default", function()
            local auth, _, t = authWith({}, ok_response())
            local before = Identity.active
            Identity.active = "redreader"
            auth:exchangeCode("cid", "AUTH-1")
            Identity.active = before
            -- Percent-encoded: the raw value carries ":" and "/".
            assert_match("redirect_uri=redreader%%3A%%2F%%2F", t.requests[1].body)
        end)

        it("uses an explicitly given redirect URI instead", function()
            -- The pairing page can pick an identity per-pairing, and Reddit
            -- checks this against the registration the code was issued for.
            local auth, _, t = authWith({}, ok_response())
            auth:exchangeCode("cid", "AUTH-1", "dystopia://response")
            assert_match("redirect_uri=dystopia%%3A%%2F%%2Fresponse", t.requests[1].body)
        end)

        it("authenticates as a non-confidential client", function()
            local auth, _, t = authWith({}, ok_response())
            auth:exchangeCode("myclientid", "AUTH-1")
            assert_match("bXljbGllbnRpZDo=", t.requests[1].headers.Authorization or "")
        end)

        it("keeps the hyphens in a code intact", function()
            local auth, _, t = authWith({}, ok_response())
            auth:exchangeCode("cid", "PSgal3YBwWIMK2TzSinH-mM53adHkQ")
            assert_match("code=PSgal3YBwWIMK2TzSinH%-mM53adHkQ", t.requests[1].body)
        end)

        it("saves nothing by itself -- the caller decides", function()
            local auth, store = authWith({}, ok_response())
            auth:exchangeCode("cid", "AUTH-1")
            assert_nil(store:readSetting("refresh_token"))
        end)

        it("refuses an empty client ID or code without hitting the network", function()
            local auth, _, t = authWith({}, ok_response())
            assert_nil(auth:exchangeCode("", "AUTH"))
            assert_nil(auth:exchangeCode("cid", ""))
            assert_nil(auth:exchangeCode("cid", nil))
            assert_equal(0, #t.requests)
        end)

        it("reports Reddit's error field on a rejected code", function()
            local auth = authWith({}, { { body = '{"error":"invalid_grant"}' } })
            local token, err = auth:exchangeCode("cid", "STALE")
            assert_nil(token)
            assert_match("invalid_grant", err)
        end)

        it("never puts the code itself in the error message", function()
            -- Errors get shown on screen and can end up in a bug report.
            local auth = authWith({}, { { body = '{"error":"invalid_grant"}' } })
            local _, err = auth:exchangeCode("cid", "SECRET-CODE")
            assert_true(err:find("SECRET") == nil, "error leaked the code: " .. err)
        end)
    end)

    describe("urlEncode", function()
        it("leaves the unreserved characters a code is made of alone", function()
            assert_equal("aZ09-_.~", Auth.urlEncode("aZ09-_.~"))
        end)

        it("escapes what a redirect URI is made of", function()
            assert_equal("redreader%3A%2F%2Frr_oauth_redir",
                Auth.urlEncode("redreader://rr_oauth_redir"))
        end)
    end)

    describe("redirectUri", function()
        it("comes from the identity module, not a local constant", function()
            -- must hold whichever identity is active, since switching is the point
            local before = Identity.active
            assert_equal(Identity.redirectUri(), Auth.redirectUri())
            Identity.active = "own"
            assert_equal("http://localhost:8080", Auth.redirectUri())
            Identity.active = "redreader"
            assert_equal("redreader://rr_oauth_redir", Auth.redirectUri())
            Identity.active = before
        end)
    end)

    describe("invalidate", function()
        it("drops the cached access token but keeps the refresh token", function()
            local auth, store = authWith(
                { client_id = "cid", refresh_token = "rt", access_token = "tok", expires_at = 9999 },
                { { body = "{}" } })
            auth:invalidate()
            assert_nil(store.data.access_token)
            assert_nil(store.data.expires_at)
            assert_equal("rt", store.data.refresh_token)
            assert_equal(1, store.flushes)
        end)
    end)

    describe("save", function()
        it("stores pairing results and clears any stale access token", function()
            local auth, store = authWith(
                { access_token = "stale", expires_at = 1 }, { { body = "{}" } })
            auth:save("new-cid", "new-rt")
            assert_equal("new-cid", store.data.client_id)
            assert_equal("new-rt", store.data.refresh_token)
            assert_nil(store.data.access_token)
            assert_nil(store.data.expires_at)
            assert_true(store.flushes >= 1)
        end)

        it("makes hasCredentials true", function()
            local auth = authWith({}, { { body = "{}" } })
            assert_false(auth:hasCredentials())
            auth:save("cid", "rt")
            assert_true(auth:hasCredentials())
        end)
    end)
end)

--[[
Anonymous access. Reddit's installed_client grant mints an app-only token from a
client ID alone -- no account, no browser, no authorization code to capture,
which is the hardest part of setting Reddle up.

Verified live against the API: token_type bearer, scope "*", expires_in 86400,
and no refresh_token in the response.
--]]
describe("reddle_auth anonymous", function()
    local function anon(responses)
        local store = stubs.store()
        local t = stubs.transport(responses or {
            { body = '{"access_token":"anon-tok","expires_in":86400,"scope":"*"}' },
        })
        return Auth.new{ store = store, transport = t.fn, json = json,
                         now = function() return 1000 end }, t, store
    end

    it("treats a client ID on its own as usable credentials", function()
        local auth, _, store = anon()
        store:saveSetting("client_id", "cid")
        assert_true(auth:hasCredentials())
        assert_false(auth:hasAccount())
        assert_equal(Auth.ANONYMOUS, auth:mode())
    end)

    it("is not set up at all with no client ID", function()
        local auth = anon()
        assert_false(auth:hasCredentials())
        assert_nil(auth:mode())
    end)

    it("counts a refresh token as an account", function()
        local auth, _, store = anon()
        store:saveSetting("client_id", "cid")
        store:saveSetting("refresh_token", "rt")
        assert_true(auth:hasAccount())
        assert_equal(Auth.ACCOUNT, auth:mode())
    end)

    it("asks Reddit for an app-only token when there is no refresh token", function()
        local auth, t, store = anon()
        store:saveSetting("client_id", "cid")
        assert_equal("anon-tok", auth:getAccessToken())
        local req = t.requests[1]
        assert_match("grant_type=https%%3A%%2F%%2Foauth%.reddit%.com%%2Fgrants%%2Finstalled_client",
            req.body)
        assert_match("device_id=DO_NOT_TRACK_THIS_DEVICE", req.body)
        -- Installed app: client ID as the username, empty password.
        assert_match("^Basic ", req.headers["Authorization"])
    end)

    it("caches the anonymous token for its full day", function()
        local auth, t, store = anon()
        store:saveSetting("client_id", "cid")
        auth:getAccessToken()
        auth:getAccessToken()
        assert_equal(1, #t.requests, "a day-long token must not be re-minted per call")
    end)

    it("mints another when it expires, since there is no refresh token", function()
        local store = stubs.store()
        local t = stubs.transport{
            { body = '{"access_token":"one","expires_in":100}' },
            { body = '{"access_token":"two","expires_in":100}' },
        }
        local at = 1000
        local auth = Auth.new{ store = store, transport = t.fn, json = json,
                               now = function() return at end }
        store:saveSetting("client_id", "cid")
        assert_equal("one", auth:getAccessToken())
        at = 5000
        assert_equal("two", auth:getAccessToken())
    end)

    it("names the anonymous failure as its own, not as a refresh", function()
        local store = stubs.store()
        local t = stubs.transport{ { body = '{"error":"invalid_grant"}', code = 401 } }
        local auth = Auth.new{ store = store, transport = t.fn, json = json }
        store:saveSetting("client_id", "cid")
        local tok, err = auth:getAccessToken()
        assert_nil(tok)
        assert_match("anonymous sign%-in failed", err)
    end)

    it("drops a stale refresh token when switching to anonymous", function()
        -- Otherwise the next request quietly signs in as whoever paired last.
        local auth, _, store = anon()
        store:saveSetting("client_id", "old")
        store:saveSetting("refresh_token", "someone-elses")
        assert_true(auth:saveAnonymous("new"))
        assert_nil(store:readSetting("refresh_token"))
        assert_equal("new", store:readSetting("client_id"))
        assert_equal(Auth.ANONYMOUS, auth:mode())
    end)

    it("refuses an empty client ID rather than storing nothing", function()
        local auth = anon()
        assert_false(auth:saveAnonymous(""))
        assert_false(auth:saveAnonymous(nil))
    end)
end)
