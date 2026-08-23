local Api = require("reddle_api")
local Identity = require("reddle_identity")
local stubs = require("spec.support.stubs")
local json = require("spec.support.json")

describe("reddle_api", function()

    describe("buildHeaders", function()
        it("always sends RedReader's User-Agent", function()
            -- The trap from DESIGN.md §4.1: KOReader's socketutil monkey-patches a
            -- global http.USERAGENT, so an omitted header silently becomes
            -- "KOReader/..." and the exemption stops applying.
            local h = Api.buildHeaders{}
            assert_equal(Identity.userAgent(), h["User-Agent"])
        end)

        it("sets it on authenticated requests too", function()
            local h = Api.buildHeaders{ token = "abc" }
            assert_equal(Identity.userAgent(), h["User-Agent"])
        end)

        it("uses lowercase 'bearer' exactly as Reddit documents", function()
            local h = Api.buildHeaders{ token = "abc" }
            assert_equal("bearer abc", h["Authorization"])
        end)

        it("uses 'Basic' for the token endpoint", function()
            local h = Api.buildHeaders{ basic = "Zm9vOg==" }
            assert_equal("Basic Zm9vOg==", h["Authorization"])
        end)

        it("sets Content-Type and Content-Length when there is a body", function()
            local h = Api.buildHeaders{ body = "grant_type=refresh_token" }
            assert_equal("application/x-www-form-urlencoded", h["Content-Type"])
            assert_equal("24", h["Content-Length"])
        end)

        it("omits Content-Length when there is no body", function()
            assert_nil(Api.buildHeaders{}["Content-Length"])
        end)

        it("lets extra headers through but keeps the UA", function()
            local h = Api.buildHeaders{ extra = { ["X-Test"] = "1" } }
            assert_equal("1", h["X-Test"])
            assert_equal(Identity.userAgent(), h["User-Agent"])
        end)
    end)

    describe("buildUrl", function()
        it("returns a bare url with no query", function()
            assert_equal("https://oauth.reddit.com/api/v1/me",
                Api.buildUrl(Api.OAUTH_HOST, "/api/v1/me"))
        end)

        it("orders params deterministically", function()
            local url = Api.buildUrl(Api.OAUTH_HOST, "/r/lua/hot", { limit = 25, after = "t3_abc", raw_json = 1 })
            assert_equal("https://oauth.reddit.com/r/lua/hot?after=t3_abc&limit=25&raw_json=1", url)
        end)

        it("percent-encodes values", function()
            local url = Api.buildUrl(Api.OAUTH_HOST, "/search", { q = "e ink & kindle" })
            assert_equal("https://oauth.reddit.com/search?q=e%20ink%20%26%20kindle", url)
        end)

        it("skips nil and false params", function()
            local url = Api.buildUrl(Api.OAUTH_HOST, "/x", { a = 1, b = false })
            assert_equal("https://oauth.reddit.com/x?a=1", url)
        end)
    end)

    describe("parseRateLimit", function()
        it("reads the headers Reddit sends", function()
            local rl = Api.parseRateLimit{
                ["x-ratelimit-used"] = "4", ["x-ratelimit-remaining"] = "96.0", ["x-ratelimit-reset"] = "412",
            }
            assert_equal(4, rl.used)
            assert_equal(96, rl.remaining)
            assert_equal(412, rl.reset)
        end)

        it("returns nil when the headers are absent", function()
            assert_nil(Api.parseRateLimit{ ["content-type"] = "application/json" })
        end)

        it("survives a non-table", function()
            assert_nil(Api.parseRateLimit(nil))
        end)

        it("backs off only when the shared quota is nearly gone", function()
            assert_false(Api.shouldBackOff{ remaining = 50 })
            assert_true(Api.shouldBackOff{ remaining = 3 })
            assert_false(Api.shouldBackOff(nil))
        end)
    end)

    describe("call", function()
        it("turns Reddit's escaped emoji surrogate pairs into UTF-8 before decoding", function()
            local raw = '{"body_html":"<p>\\uD83D\\uDE80 launch</p>"}'
            local t = stubs.transport{ { body = raw, code = 200 } }
            local api = Api.new{ transport = t.fn, json = json }
            local res, code, returned_raw = api:call{ url = "https://oauth.reddit.com/x" }
            assert_equal(200, code)
            assert_equal("<p>\240\159\154\128 launch</p>", res.body_html)
            -- Keep the unmodified payload for diagnostics and API error reports.
            assert_equal(raw, returned_raw)
        end)

        it("decodes a 200 and records the rate limit", function()
            local t = stubs.transport{ {
                body = '{"name":"spez"}', code = 200,
                headers = { ["x-ratelimit-remaining"] = "88" },
            } }
            local api = Api.new{ transport = t.fn, json = json }
            local res, code = api:call{ url = "https://oauth.reddit.com/api/v1/me", token = "tok" }
            assert_equal("spez", res.name)
            assert_equal(200, code)
            assert_equal(88, api.ratelimit.remaining)
        end)

        it("returns nil plus the raw body on a non-200", function()
            local t = stubs.transport{ { body = "you broke it", code = 503 } }
            local api = Api.new{ transport = t.fn, json = json }
            local res, code, raw = api:call{ url = "https://x/y" }
            assert_nil(res)
            assert_equal(503, code)
            assert_equal("you broke it", raw)
        end)

        it("does not throw when a 200 body is not JSON", function()
            -- Captive portals return 200 with HTML (DESIGN.md §7).
            local t = stubs.transport{ { body = "<html>login here</html>", code = 200 } }
            local api = Api.new{ transport = t.fn, json = json }
            local res, code, raw = api:call{ url = "https://x/y" }
            assert_nil(res)
            assert_equal(200, code)
            assert_match("login here", raw)
        end)
    end)

    describe("get", function()
        local function apiWith(responses, token_seq)
            local t = stubs.transport(responses)
            local calls = { invalidated = 0 }
            local auth = {
                getAccessToken = function()
                    calls.tokens = (calls.tokens or 0) + 1
                    return (token_seq or { "tok" })[calls.tokens] or "tok"
                end,
                invalidate = function() calls.invalidated = calls.invalidated + 1 end,
            }
            return Api.new{ transport = t.fn, json = json, auth = auth }, t, calls
        end

        it("always adds raw_json=1", function()
            local api, t = apiWith{ { body = '{"ok":true}' } }
            api:get("/api/v1/me")
            assert_match("raw_json=1", t.requests[1].url)
        end)

        it("sends the bearer token and the RedReader UA", function()
            local api, t = apiWith{ { body = '{"ok":true}' } }
            api:get("/api/v1/me")
            assert_equal("bearer tok", t.requests[1].headers["Authorization"])
            assert_equal(Identity.userAgent(), t.requests[1].headers["User-Agent"])
        end)

        it("refreshes and retries exactly once on 401", function()
            local api, t, calls = apiWith(
                { { body = "", code = 401 }, { body = '{"name":"spez"}', code = 200 } },
                { "stale", "fresh" })
            local res = api:get("/api/v1/me")
            assert_equal("spez", res.name)
            assert_equal(2, #t.requests)
            assert_equal(1, calls.invalidated)
            assert_equal("bearer stale", t.requests[1].headers["Authorization"])
            assert_equal("bearer fresh", t.requests[2].headers["Authorization"])
        end)

        it("gives up after a second 401 instead of looping", function()
            local api, t = apiWith{ { body = "", code = 401 }, { body = "", code = 401 } }
            local res, code = api:get("/api/v1/me")
            assert_nil(res)
            assert_equal(401, code)
            assert_equal(2, #t.requests)
        end)

        it("reports the auth error without calling the network", function()
            local t = stubs.transport{ { body = "" } }
            local api = Api.new{ transport = t.fn, json = json, auth = {
                getAccessToken = function() return nil, "no credentials" end,
                invalidate = function() end,
            } }
            local res, _, err = api:get("/api/v1/me")
            assert_nil(res)
            assert_equal("no credentials", err)
            assert_equal(0, #t.requests)
        end)
    end)

    describe("scrubNulls", function()
        -- KOReader's JSON decoder returns a function sentinel for JSON null. It is
        -- truthy, so it survives `if x then` and then crashes on indexing -- this is
        -- what killed the post view on the device.
        local NULL = function() end

        it("turns the null sentinel into a real nil", function()
            local t = Api.scrubNulls{ selftext_html = NULL, title = "keep" }
            assert_nil(t.selftext_html)
            assert_equal("keep", t.title)
        end)

        it("reaches into nested tables and arrays", function()
            local t = Api.scrubNulls{
                data = { after = NULL, children = { { data = { body_html = NULL, id = "x" } } } },
            }
            assert_nil(t.data.after)
            assert_nil(t.data.children[1].data.body_html)
            assert_equal("x", t.data.children[1].data.id)
        end)

        it("leaves real values alone", function()
            local t = Api.scrubNulls{ n = 0, f = false, s = "", tbl = {} }
            assert_equal(0, t.n)
            assert_equal(false, t.f)
            assert_equal("", t.s)
            assert_true(type(t.tbl) == "table")
        end)

        it("survives scalars and nil", function()
            assert_equal("x", Api.scrubNulls("x"))
            assert_nil(Api.scrubNulls(nil))
            assert_nil(Api.scrubNulls(NULL))
        end)

        it("is applied to every decoded response", function()
            local t = stubs.transport{ { body = '{"a":1}' } }
            local decoded = { data = { after = NULL } }
            local api = Api.new{ transport = t.fn, json = { decode = function() return decoded end } }
            local res = api:call{ url = "https://x/y" }
            assert_nil(res.data.after, "Api:call must scrub before handing the table on")
        end)

        it("stops a null cursor from being sent as an `after` parameter", function()
            -- Reddit sends "after": null on the last page; unscrubbed that is truthy
            -- and would be concatenated into the URL as "function: 0x...".
            local listing = Api.scrubNulls{ data = { after = NULL } }
            assert_nil(Api.nextCursor(listing))
        end)
    end)

    describe("nextCursor", function()
        it("returns the listing's after", function()
            assert_equal("t3_abc", Api.nextCursor{ data = { after = "t3_abc" } })
        end)

        it("returns nil at the end of a listing", function()
            assert_nil(Api.nextCursor{ data = { after = nil } })
            assert_nil(Api.nextCursor{ data = { after = "" } })
            assert_nil(Api.nextCursor{})
            assert_nil(Api.nextCursor("nonsense"))
        end)
    end)

    describe("identity", function()
        it("pins RedReader's exact strings (patcheddit's SpoofClientPatch defaults)", function()
            local rr = Identity.identities.redreader
            assert_equal("org.quantumbadger.redreader/1.25.1", rr.user_agent)
            assert_equal("redreader://rr_oauth_redir", rr.redirect_uri)
        end)

        it("pins Dystopia's strings (Apollo-Reborn docs; app's own UA)", function()
            local d = Identity.identities.dystopia
            -- No space before "(by" -- Dystopia's real UA, copied verbatim.
            assert_equal("ios:com.CarbonDev.Dystopia:v1.0.1(by /u/DystopiaForReddit)", d.user_agent)
            assert_equal("dystopia://response", d.redirect_uri)
        end)

        it("resolves the active identity through one switch", function()
            local before = Identity.active
            Identity.active = "dystopia"
            assert_equal("ios:com.CarbonDev.Dystopia:v1.0.1(by /u/DystopiaForReddit)",
                Api.buildHeaders{}["User-Agent"])
            Identity.active = before
            assert_equal(Identity.identities[before].user_agent, Api.buildHeaders{}["User-Agent"])
        end)

        it("never sends an empty user agent (live-verified: HTTP 403)", function()
            for name, id in pairs(Identity.identities) do
                assert_true(#id.user_agent > 0, name .. " user_agent")
                assert_true(#id.redirect_uri > 0, name .. " redirect_uri")
            end
        end)

        it("errors loudly on an unknown active identity", function()
            local before = Identity.active
            Identity.active = "nope"
            local ok = pcall(Identity.current)
            Identity.active = before
            assert_false(ok)
        end)
    end)
end)

--[[
Masking. Every request Reddle makes must present the chosen identity, including
the ones that do not go through Api:get -- images are fetched from Reddit's own
CDN, from the same address, seconds after the API call that produced the link.
--]]
describe("reddle_api.fileHeaders", function()
    it("carries the identity's user agent", function()
        assert_equal(Identity.userAgent(), Api.fileHeaders()["User-Agent"])
    end)

    it("never attaches the token, since the host may not be Reddit's", function()
        -- A post can link an image anywhere. Sending the bearer token to
        -- whatever host a stranger put in a post would hand it over.
        local h = Api.fileHeaders()
        assert_nil(h["Authorization"])
        assert_nil(h["Cookie"])
    end)

    it("tracks the active identity rather than pinning one", function()
        local before = Identity.active
        Identity.active = "dystopia"
        assert_equal("ios:com.CarbonDev.Dystopia:v1.0.1(by /u/DystopiaForReddit)",
            Api.fileHeaders()["User-Agent"])
        Identity.active = before
    end)
end)

describe("reddle_identity.isPlaceholder", function()
    it("flags the shipped example, which identifies nobody", function()
        local before = Identity.active
        Identity.active = "own"
        assert_true(Identity.isPlaceholder())
        assert_match("com%.example", Identity.userAgent())
        Identity.active = before
    end)

    it("does not flag a real identity", function()
        local before = Identity.active
        for _i, name in ipairs({ "redreader", "dystopia" }) do
            Identity.active = name
            assert_false(Identity.isPlaceholder(), name)
        end
        Identity.active = before
    end)

    it("clears once a user agent is actually supplied", function()
        -- Self-registration goes through the custom branch, which is what the
        -- pairing page's "My own registration" selects; the bare `own` entry is
        -- only the example it starts from.
        local before = Identity.active
        Identity.apply{ identity = Identity.CUSTOM,
                        redirect_uri = "http://localhost:8080",
                        user_agent = "android:com.me.reddle:v1.0 (by /u/me)" }
        assert_false(Identity.isPlaceholder())
        Identity.override, Identity.active = nil, before
    end)
end)
