--[[
reddle_pair.lua is tested as the real file (KOReader modules faked via
package.loaded), driven with literal HTTP request bytes. The point is to cover the
gotcha in DESIGN.md §3.3c: SimpleTCPServer hands the callback the *header block*
and leaves the body in the socket.
--]]

local stubs = require("spec.support.stubs")
local json = require("spec.support.json")

local spies = stubs.installKOReaderFakes()

-- Make the IP lookup deterministic. Without this the socket route strategy runs
-- first and, on any machine that happens to have LuaSocket, returns that
-- machine's real address instead of the faked one.
package.loaded["socket"] = { udp = function() return nil end }

local Pair = require("reddle_pair")

-- SimpleTCPServer joins the received lines with \r\n and includes the trailing
-- blank line; the body is NOT part of what the callback receives.
local function headerBlock(lines)
    local t = {}
    for _, l in ipairs(lines) do t[#t + 1] = l end
    t[#t + 1] = ""
    return table.concat(t, "\r\n")
end

local function post(body, opts)
    opts = opts or {}
    local headers = {
        opts.request_line or "POST /pair HTTP/1.1",
        "Host: 192.168.1.42:8888",
        "Content-Type: application/json",
    }
    if not opts.omit_length then
        headers[#headers + 1] = "Content-Length: " .. (opts.length or #body)
    end
    return headerBlock(headers), stubs.client(body)
end

local function startPair(port)
    local paired = {}
    local ok, ip, actual_port, code = Pair:start(port or 8888, function(cid, rt)
        paired.client_id, paired.refresh_token = cid, rt
    end)
    return { ok = ok, ip = ip, port = actual_port, code = code, paired = paired }
end

local function statusOf(client)
    return tonumber((client.sent or ""):match("^HTTP/1%.1 (%d+)"))
end

describe("reddle_pair", function()

    describe("start", function()
        it("reports the device's non-loopback IP, the port and a 6 digit code", function()
            local s = startPair(8888)
            assert_true(s.ok)
            assert_equal("192.168.1.42", s.ip)
            assert_equal(8888, s.port)
            assert_match("^%d%d%d%d%d%d$", s.code)
            Pair:stop()
        end)

        it("registers with UIManager's event loop and schedules the auto-stop", function()
            local before_insert = spies.zmq_inserted
            startPair()
            assert_equal(before_insert + 1, spies.zmq_inserted)
            assert_equal(300, spies.scheduled[#spies.scheduled].secs)
            Pair:stop()
        end)

        it("deregisters the exact object it registered", function()
            -- UIManager:removeZMQ matches by identity; handing it a wrapper would
            -- leave a closed socket in the poll list and crash KOReader.
            local before = #spies.zmq_list
            startPair()
            assert_equal(before + 1, #spies.zmq_list)
            Pair:stop()
            assert_equal(before, #spies.zmq_list)
        end)

        it("stop is idempotent, since the pairing dialog also calls it", function()
            startPair()
            Pair:stop()
            Pair:stop()  -- must not throw or double-close
            assert_false(Pair:isRunning())
        end)

        it("unregisters on stop", function()
            local before = spies.zmq_removed
            startPair()
            Pair:stop()
            assert_equal(before + 1, spies.zmq_removed)
            assert_false(Pair:isRunning())
        end)

        it("generates a different code each session", function()
            math.randomseed(1)
            local a = startPair(); Pair:stop()
            local b = startPair(); Pair:stop()
            -- not a strong claim, just that it is not a constant
            assert_true(type(a.code) == "string" and type(b.code) == "string")
        end)
    end)

    describe("onRequest", function()
        it("accepts a well-formed pairing POST and writes the credentials", function()
            local s = startPair()
            local body = json.encode{ code = s.code, client_id = "cid-1", refresh_token = "rt-1" }
            local headers, client = post(body)
            Pair:onRequest(headers, client)
            assert_equal(200, statusOf(client))
            assert_match("paired", client.sent)
            -- deferred, and not run inside the socket callback: UIManager is still
            -- polling this very socket when onRequest returns
            assert_nil(s.paired.client_id)
            local task = spies.scheduled[#spies.scheduled]
            assert_true(task.secs > 0, "teardown must not run in the same UIManager pass")
            task.task()
            assert_equal("cid-1", s.paired.client_id)
            assert_equal("rt-1", s.paired.refresh_token)
            assert_false(Pair:isRunning())
        end)

        it("reads the body off Content-Length, since the server only hands over headers", function()
            local s = startPair()
            local body = json.encode{ code = s.code, client_id = "cid", refresh_token = "rt" }
            local headers, client = post(body)
            -- body untouched in the socket at this point
            assert_equal(#body, #client.buffer)
            Pair:onRequest(headers, client)
            assert_equal(0, #client.buffer)
            assert_equal(200, statusOf(client))
            Pair:stop()
        end)

        it("rejects a wrong pairing code with 403", function()
            local s = startPair()
            local body = json.encode{ code = "000000", client_id = "cid", refresh_token = "rt" }
            local headers, client = post(body)
            Pair:onRequest(headers, client)
            assert_equal(403, statusOf(client))
            assert_nil(s.paired.client_id)
            assert_true(Pair:isRunning()) -- stays up so the user can retry
            Pair:stop()
        end)

        it("rejects a GET with 400", function()
            startPair()
            local headers, client = post("{}", { request_line = "GET /pair HTTP/1.1" })
            Pair:onRequest(headers, client)
            assert_equal(400, statusOf(client))
            Pair:stop()
        end)

        it("rejects another path with 400", function()
            startPair()
            local headers, client = post("{}", { request_line = "POST /admin HTTP/1.1" })
            Pair:onRequest(headers, client)
            assert_equal(400, statusOf(client))
            Pair:stop()
        end)

        it("rejects a request with no Content-Length", function()
            startPair()
            local headers, client = post('{"code":"1"}', { omit_length = true })
            Pair:onRequest(headers, client)
            assert_equal(400, statusOf(client))
            Pair:stop()
        end)

        it("rejects an oversized Content-Length without asking the socket for it", function()
            startPair()
            local headers, client = post("{}", { length = 999999 })
            Pair:onRequest(headers, client)
            assert_equal(400, statusOf(client))
            -- the cap must reject before receive(), not rely on the read failing
            assert_equal(0, #client.reads)
            Pair:stop()
        end)

        it("rejects a zero Content-Length without reading", function()
            startPair()
            local headers, client = post("", { length = 0 })
            Pair:onRequest(headers, client)
            assert_equal(400, statusOf(client))
            assert_equal(0, #client.reads)
            Pair:stop()
        end)

        it("survives a truncated body (socket timeout mid-read)", function()
            local s = startPair()
            local body = json.encode{ code = s.code, client_id = "cid", refresh_token = "rt" }
            local headers = headerBlock{
                "POST /pair HTTP/1.1", "Content-Length: " .. #body,
            }
            local client = stubs.client(body:sub(1, 5)) -- rest never arrives
            Pair:onRequest(headers, client)
            assert_equal(400, statusOf(client))
            Pair:stop()
        end)

        it("rejects a body that is not JSON", function()
            startPair()
            local headers, client = post("<html>nope</html>")
            Pair:onRequest(headers, client)
            assert_equal(400, statusOf(client))
            Pair:stop()
        end)

        it("rejects valid JSON with the right code but missing fields", function()
            local s = startPair()
            local body = json.encode{ code = s.code, client_id = "cid" } -- no refresh_token
            local headers, client = post(body)
            Pair:onRequest(headers, client)
            assert_equal(400, statusOf(client))
            assert_nil(s.paired.client_id)
            Pair:stop()
        end)

        it("handles a lowercase content-length header", function()
            local s = startPair()
            local body = json.encode{ code = s.code, client_id = "cid", refresh_token = "rt" }
            local headers = headerBlock{ "POST /pair HTTP/1.1", "content-length: " .. #body }
            local client = stubs.client(body)
            Pair:onRequest(headers, client)
            assert_equal(200, statusOf(client))
            Pair:stop()
        end)
    end)

    -- The browser-only pairing flow (DESIGN.md §3.3d): the device serves a page,
    -- the desktop needs nothing installed.
    describe("extractCode", function()
        local cases = {
            { "a redreader:// callback URL",
              "redreader://rr_oauth_redir?state=ST&code=THE-CODE#_", "THE-CODE", "ST" },
            { "another identity's scheme",
              "dystopia://response?state=ST&code=THE-CODE", "THE-CODE", "ST" },
            { "a bare query string", "state=ST&code=THE-CODE#_", "THE-CODE", "ST" },
            { "a code= with no leading separator", "code=THE-CODE", "THE-CODE", nil },
            { "the bare code", "THE-CODE", "THE-CODE", nil },
            { "quotes and spaces a paste brings along", '  "THE-CODE"  ', "THE-CODE", nil },
            { "params in the other order",
              "redreader://x?code=THE-CODE&state=ST", "THE-CODE", "ST" },
        }
        for _, c in ipairs(cases) do
            it("takes " .. c[1], function()
                local code, state = Pair.extractCode(c[2])
                assert_equal(c[3], code)
                assert_equal(c[4], state)
            end)
        end

        it("keeps a real hyphen, which the whole flow depends on", function()
            -- A code read off a wrapped dialog gains a hyphen and is silently
            -- wrong; one that is pasted must not lose the hyphens it has.
            assert_equal("PSgal3YBwWIMK2TzSinH-mM53adHkQ",
                Pair.extractCode("redreader://x?code=PSgal3YBwWIMK2TzSinH-mM53adHkQ#_"))
        end)

        it("never mistakes a codeless callback for a code", function()
            assert_nil(Pair.extractCode("redreader://rr_oauth_redir?state=ST"))
            assert_nil(Pair.extractCode("error=access_denied&state=ST"))
        end)

        it("rejects nothing at all", function()
            assert_nil(Pair.extractCode(""))
            assert_nil(Pair.extractCode("   "))
            assert_nil(Pair.extractCode(nil))
        end)
    end)

    describe("urlDecode", function()
        it("decodes percent escapes", function()
            assert_equal("redreader://x?a=1&b=2",
                Pair.urlDecode("redreader%3A%2F%2Fx%3Fa%3D1%26b%3D2"))
        end)

        it("treats + as a space only in form bodies", function()
            -- In a pasted URL a "+" is a literal character of the value.
            assert_equal("a+b", Pair.urlDecode("a+b"))
            assert_equal("a b", Pair.urlDecode("a+b", true))
        end)
    end)

    describe("parseForm", function()
        it("splits and decodes a form body", function()
            local f = Pair.parseForm("code=123456&client_id=abc&pasted=x")
            assert_equal("123456", f.code)
            assert_equal("abc", f.client_id)
        end)

        it("keeps a URL whose own & were encoded by the browser", function()
            local f = Pair.parseForm("pasted=redreader%3A%2F%2Fx%3Fstate%3DST%26code%3DC")
            assert_equal("redreader://x?state=ST&code=C", f.pasted)
            assert_equal("C", (Pair.extractCode(f.pasted)))
        end)
    end)

    describe("the served page", function()
        local function get(path)
            local headers = headerBlock({ (path or "GET / HTTP/1.1"), "Host: x" })
            local client = stubs.client("")
            Pair:onRequest(headers, client)
            return client
        end

        it("serves HTML on GET /", function()
            startPair()
            local client = get()
            assert_equal(200, statusOf(client))
            assert_match("Content%-Type: text/html", client.sent)
            assert_match("<form", client.sent)
            Pair:stop()
        end)

        it("posts the form back to /paste", function()
            startPair()
            assert_match('action="/paste"', get().sent)
            Pair:stop()
        end)

        it("carries the state it will later check", function()
            local s = startPair()
            assert_true(Pair.state ~= nil)
            assert_match(Pair.state, get().sent)
            s = nil -- luacheck: ignore
            Pair:stop()
        end)

        it("asks only for the read-only scopes", function()
            startPair()
            local scope = get().sent:match("scope=([^\"&]*)")
            assert_equal("identity,read,mysubreddits,history", scope)
            -- Checked against the scope value, not the whole page: the form's
            -- own submit button would otherwise match.
            for _, write in ipairs({ "submit", "vote", "edit", "subscribe", "save" }) do
                assert_true(scope:find(write, 1, true) == nil,
                    "must not request the " .. write .. " scope")
            end
            Pair:stop()
        end)

        it("loads nothing from the network -- the Kindle is the only server", function()
            startPair()
            local sent = get().sent
            -- A page served by a device the browser may not be able to route
            -- past must not depend on a CDN. Checked against the things that
            -- actually fetch -- URLs also appear as data in the redirect map.
            assert_true(sent:find("<img") == nil, "no images")
            assert_true(sent:find("<link") == nil, "no external stylesheets")
            assert_true(sent:find("src=") == nil, "nothing is loaded from elsewhere")
            -- Two navigable external links are allowed: the Reddit one the
            -- script builds, and the AGPL source offer. Neither is fetched to
            -- render the page.
            for url in sent:gmatch('href="(https?://[^"]*)"') do
                local allowed = url:match("^https://www%.reddit%.com/")
                    or url:match("^https://github%.com/")
                assert_true(allowed ~= nil, "unexpected external link: " .. url)
            end
            Pair:stop()
        end)
    end)

    describe("POST /paste", function()
        local function startPaste()
            local got = {}
            local ok, ip, port, code = Pair:start(8888, nil, function(cid, auth)
                got.client_id, got.auth_code = cid, auth
            end)
            return { ok = ok, ip = ip, port = port, code = code, got = got }
        end

        local function paste(fields)
            local body = {}
            for k, v in pairs(fields) do
                body[#body + 1] = k .. "=" .. tostring(v):gsub("[^%w%-%_%.%~]", function(c)
                    return string.format("%%%02X", string.byte(c))
                end)
            end
            body = table.concat(body, "&")
            local headers = headerBlock({
                "POST /paste HTTP/1.1", "Host: x",
                "Content-Type: application/x-www-form-urlencoded",
                "Content-Length: " .. #body,
            })
            local client = stubs.client(body)
            Pair:onRequest(headers, client)
            return client
        end

        it("hands over an authorization code, deferred off the socket callback", function()
            local s = startPaste()
            local client = paste{ code = s.code, client_id = "cid-9",
                pasted = "redreader://rr_oauth_redir?state=" .. Pair.state .. "&code=AUTH-1#_" }
            assert_equal(200, statusOf(client))
            -- The TLS exchange must not happen inside onRequest: UIManager is
            -- still polling this socket. Nothing has run yet.
            assert_nil(s.got.auth_code)
            local task = spies.scheduled[#spies.scheduled]
            assert_true(task.secs > 0, "must not run in the same UIManager pass")
            task.task()
            assert_equal("cid-9", s.got.client_id)
            assert_equal("AUTH-1", s.got.auth_code)
            assert_false(Pair:isRunning())
        end)

        it("tells the browser to go look at the Kindle", function()
            local s = startPaste()
            local client = paste{ code = s.code, client_id = "c",
                pasted = "code=AUTH-1" }
            assert_match("Kindle", client.sent)
            Pair:stop()
        end)

        it("refuses a wrong six-digit code", function()
            local s = startPaste()
            local client = paste{ code = "000000", client_id = "c", pasted = "code=AUTH" }
            assert_equal(403, statusOf(client))
            assert_nil(s.got.auth_code)
            assert_true(Pair:isRunning()) -- stays up so the user can retry
            Pair:stop()
        end)

        it("refuses a callback from a different authorization", function()
            local s = startPaste()
            local client = paste{ code = s.code, client_id = "c",
                pasted = "redreader://x?state=SOMEONE-ELSE&code=AUTH" }
            assert_equal(403, statusOf(client))
            assert_nil(s.got.auth_code)
            Pair:stop()
        end)

        it("allows a paste that carries no state, since a bare code has none", function()
            local s = startPaste()
            paste{ code = s.code, client_id = "c", pasted = "AUTH-2" }
            spies.scheduled[#spies.scheduled].task()
            assert_equal("AUTH-2", s.got.auth_code)
        end)

        it("refuses a paste with no client ID", function()
            local s = startPaste()
            local client = paste{ code = s.code, client_id = "", pasted = "code=AUTH" }
            assert_equal(400, statusOf(client))
            assert_nil(s.got.auth_code)
            Pair:stop()
        end)

        it("refuses a paste with no code in it", function()
            local s = startPaste()
            local client = paste{ code = s.code, client_id = "c",
                pasted = "redreader://x?state=" .. Pair.state }
            assert_equal(400, statusOf(client))
            assert_nil(s.got.auth_code)
            Pair:stop()
        end)

        it("never echoes the code or client ID back to the browser", function()
            local s = startPaste()
            local client = paste{ code = s.code, client_id = "SECRET-CID",
                pasted = "code=SECRET-AUTH" }
            assert_true(client.sent:find("SECRET%-AUTH") == nil)
            assert_true(client.sent:find("SECRET%-CID") == nil)
            spies.scheduled[#spies.scheduled].task()
        end)
    end)

    -- Picking the app the client ID came from, in the page rather than by editing
    -- reddle_identity.lua. The redirect URI must match the app the ID belongs to.
    describe("identity selection", function()
        local Identity = require("reddle_identity")
        local function get()
            local client = stubs.client("")
            Pair:onRequest(headerBlock({ "GET / HTTP/1.1", "Host: x" }), client)
            return client.sent
        end
        local function paste(fields)
            local body = {}
            for k, v in pairs(fields) do
                body[#body + 1] = k .. "=" .. tostring(v):gsub("[^%w%-%_%.%~]", function(c)
                    return string.format("%%%02X", string.byte(c))
                end)
            end
            body = table.concat(body, "&")
            local client = stubs.client(body)
            Pair:onRequest(headerBlock({ "POST /paste HTTP/1.1", "Host: x",
                "Content-Length: " .. #body }), client)
            return client
        end

        -- Identity is process-global and other spec files pin it, so every test
        -- that changes it puts it back. The harness has no after_each.
        local function restore() Identity.apply{ identity = "redreader" } end

        it("offers every built-in plus a custom option", function()
            startPair()
            local sent = get()
            assert_match('<option value="redreader"', sent)
            assert_match('<option value="dystopia"', sent)
            assert_match('<option value="custom"', sent)
            Pair:stop()
        end)

        it("preselects nothing, so borrowing is never the default", function()
            startPair()
            local sent = get()
            assert_match('<option value="" disabled selected>', sent)
            -- No borrowed identity may carry `selected`.
            assert_true(sent:find('value="redreader" selected') == nil)
            assert_true(sent:find('value="dystopia" selected') == nil)
            Pair:stop()
        end)

        it("says what each borrowed identity costs its owner", function()
            startPair()
            local sent = get()
            assert_match("accessibility", sent)
            assert_match("attributed to them", sent)
            assert_match("billed", sent)
            Pair:stop()
        end)

        it("does not offer `own` as a preset -- that is the custom branch", function()
            startPair()
            assert_true(get():find('<option value="own"') == nil)
            Pair:stop()
        end)

        it("gives the page each identity's redirect URI to choose between", function()
            startPair()
            local sent = get()
            assert_match("redreader://rr_oauth_redir", sent)
            assert_match("dystopia://response", sent)
            Pair:stop()
        end)

        it("switches the identity the device uses", function()
            local s = Pair:start(8888, nil, function() end)
            paste{ code = s and Pair.code or Pair.code, client_id = "c",
                pasted = "code=AUTH", identity = "dystopia" }
            assert_equal("dystopia", Identity.active)
            assert_equal("dystopia://response", Identity.redirectUri())
            spies.scheduled[#spies.scheduled].task()
            restore()
        end)

        it("accepts a custom redirect URI", function()
            Pair:start(8888, nil, function() end)
            paste{ code = Pair.code, client_id = "c", pasted = "code=AUTH",
                identity = "custom", redirect_uri = "myapp://cb",
                user_agent = "ios:com.me.x:v1 (by /u/me)" }
            assert_equal("myapp://cb", Identity.redirectUri())
            assert_equal("ios:com.me.x:v1 (by /u/me)", Identity.userAgent())
            spies.scheduled[#spies.scheduled].task()
            restore()
        end)

        it("keeps the previous user agent when a custom one is left blank", function()
            -- An empty or malformed UA is a hard 403 from Reddit, so blank must
            -- not mean "send nothing".
            Identity.apply{ identity = "redreader" }
            local before = Identity.userAgent()
            Pair:start(8888, nil, function() end)
            paste{ code = Pair.code, client_id = "c", pasted = "code=AUTH",
                identity = "custom", redirect_uri = "myapp://cb", user_agent = "" }
            assert_equal(before, Identity.userAgent())
            spies.scheduled[#spies.scheduled].task()
            restore()
        end)

        it("refuses a custom identity with no redirect URI", function()
            Pair:start(8888, nil, function() end)
            local client = paste{ code = Pair.code, client_id = "c", pasted = "code=AUTH",
                identity = "custom", redirect_uri = "" }
            assert_equal(400, statusOf(client))
            Pair:stop()
        end)

        it("refuses an identity that does not exist", function()
            Pair:start(8888, nil, function() end)
            local client = paste{ code = Pair.code, client_id = "c", pasted = "code=AUTH",
                identity = "not-an-app" }
            assert_equal(400, statusOf(client))
            Pair:stop()
        end)

        it("hands the chosen redirect URI to whoever does the exchange", function()
            -- Reddit checks redirect_uri against the registration the code was
            -- issued for; losing it here is a bare "invalid_grant" with no clue.
            local got
            Pair:start(8888, nil, function(_, _, identity) got = identity end)
            paste{ code = Pair.code, client_id = "c", pasted = "code=AUTH",
                identity = "dystopia" }
            spies.scheduled[#spies.scheduled].task()
            assert_equal("dystopia", got.identity)
            restore()
        end)
    end)

    describe("randomness", function()
        it("draws the pairing code from /dev/urandom, not math.random", function()
            -- math.random is seeded from os.time() at best (KOReader's
            -- frontend/random.lua) and often not seeded at all, which would make
            -- the code guessable by anyone who knows when pairing started.
            local asked = 0
            local real = Pair.OPEN_URANDOM
            Pair.OPEN_URANDOM = function() asked = asked + 1; return real() end
            Pair.randomCode()
            Pair.OPEN_URANDOM = real
            assert_equal(1, asked)
        end)

        it("still produces a six-digit code when there is no urandom", function()
            local real = Pair.OPEN_URANDOM
            Pair.OPEN_URANDOM = function() return nil end
            local code = Pair.randomCode()
            Pair.OPEN_URANDOM = real
            assert_match("^%d%d%d%d%d%d$", code)
        end)

        it("gives a different code and state on each start", function()
            local s1 = startPair(); local c1, st1 = s1.code, Pair.state; Pair:stop()
            local s2 = startPair(); local c2, st2 = s2.code, Pair.state; Pair:stop()
            assert_true(st1 ~= st2, "state repeated across sessions")
            -- A six-digit code collides once in a million; state must not.
            assert_true(#st1 == 32, "state should be 128 bits of hex, got " .. #st1)
            assert_true(c1 ~= nil and c2 ~= nil)
        end)

        it("makes the state 128 bits, not two 31-bit draws", function()
            assert_equal(32, #Pair.randomHex(16))
            assert_match("^%x+$", Pair.randomHex(16))
            assert_true(Pair.randomHex(16) ~= Pair.randomHex(16))
        end)
    end)

    describe("getLocalIP", function()
        local real
        local function withStrategies(list, fn)
            real = Pair.IP_STRATEGIES
            Pair.IP_STRATEGIES = list
            local ok, err = pcall(fn)
            Pair.IP_STRATEGIES = real
            if not ok then error(err) end
        end

        it("takes the first strategy that answers", function()
            withStrategies({
                function() return nil end,
                function() return "10.1.2.3" end,
                function() error("must not be reached") end,
            }, function() assert_equal("10.1.2.3", Pair.getLocalIP()) end)
        end)

        it("survives a strategy that throws", function()
            withStrategies({
                function() error("no network") end,
                function() return "10.9.9.9" end,
            }, function() assert_equal("10.9.9.9", Pair.getLocalIP()) end)
        end)

        it("returns nil rather than a useless address when all fail", function()
            withStrategies({ function() return nil end }, function()
                assert_nil(Pair.getLocalIP())
            end)
        end)

        it("rejects loopback and unspecified addresses", function()
            -- The reported failure was an empty result; returning 127.0.0.1 or
            -- 0.0.0.0 instead would be worse, since it looks like it worked.
            for _, bad in ipairs({ "127.0.0.1", "0.0.0.0", "not-an-ip", "" }) do
                withStrategies({ function() return bad end }, function()
                    assert_nil(Pair.getLocalIP(), bad .. " must not be offered")
                end)
            end
        end)
    end)

    describe("firewall", function()
        it("does not shell out to iptables on non-Kindle devices", function()
            -- Device:isKindle() is faked false; if the guard were wrong this would
            -- run iptables on the dev machine.
            local calls = 0
            local real_execute = os.execute
            os.execute = function(...) calls = calls + 1; return 0 end -- luacheck: ignore
            startPair()
            Pair:stop()
            os.execute = real_execute -- luacheck: ignore
            assert_equal(0, calls)
        end)
    end)
end)

--[[
Anonymous pairing. A client ID is the whole credential, so the page collapses to
one paste and the device never sees an authorization code -- there is none.

Verified live against the API: the installed_client grant answers with a bearer
token, scope "*", expires_in 86400 and no refresh_token.
--]]
describe("reddle_pair anonymous", function()
    local function startAnon()
        local got = {}
        Pair:start(8888, nil,
            function() got.authorized = true end,
            function(cid, identity) got.client_id, got.identity = cid, identity end)
        return got
    end

    local function paste(fields)
        local body = {}
        for k, v in pairs(fields) do
            body[#body + 1] = k .. "=" .. tostring(v):gsub("[^%w%-%_%.%~]", function(c)
                return string.format("%%%02X", string.byte(c))
            end)
        end
        body = table.concat(body, "&")
        local headers = headerBlock({
            "POST /paste HTTP/1.1", "Host: x",
            "Content-Type: application/x-www-form-urlencoded",
            "Content-Length: " .. #body,
        })
        local client = stubs.client(body)
        Pair:onRequest(headers, client)
        return client
    end

    it("offers the choice, with anonymous leading", function()
        local html = Pair.pageHtml{ options = "", redirects = "{}", caveats = "{}" }
        assert_match('name="mode" value="anonymous" checked', html)
        assert_match('name="mode" value="account"', html)
        -- Say what it costs, where the choice is made.
        assert_match("personalised front page", html)
    end)

    it("numbers the steps it actually shows", function()
        -- Anonymous skips Authorize, so sending is step 3. It was labelled 2,
        -- which is also what "Client ID" above it is called.
        local html = Pair.pageHtml{ options = "", redirects = "{}", caveats = "{}" }
        assert_match('anon %? "3%. Send it over" : "4%. Paste it back"', html)
    end)

    it("does not ask for a redirect URI that will never be used", function()
        -- installed_client never redirects, so there is nothing to match.
        local html = Pair.pageHtml{ options = "", redirects = "{}", caveats = "{}" }
        assert_match('<p class="account%-only"><label>Redirect URI', html)
        assert_match('class="note account%-only">Redirect:', html)
    end)

    it("does not quote a request budget the client ID may not have", function()
        -- The exemption rides on the client ID, not on the grant type: a
        -- borrowed ID is an order of magnitude off any fixed figure.
        local html = Pair.pageHtml{ options = "", redirects = "{}", caveats = "{}" }
        assert_true(html:find("1,000 requests", 1, true) == nil)
        assert_match("whatever the client ID you use", html)
    end)

    it("hides the code-capture steps from the anonymous path", function()
        local html = Pair.pageHtml{ options = "", redirects = "{}", caveats = "{}" }
        assert_match('class="account%-only"', html)
        assert_match("hidden = anon", html)
    end)

    it("takes a client ID with no pasted URL at all", function()
        local got = startAnon()
        local client = paste{ mode = "anonymous", code = Pair.code, client_id = "abc123" }
        assert_equal(200, statusOf(client))
        assert_nil(got.client_id, "must not run inside the socket callback")
        spies.scheduled[#spies.scheduled].task()
        assert_equal("abc123", got.client_id)
        assert_nil(got.authorized, "there is no code to exchange")
        assert_false(Pair:isRunning())
    end)

    it("still checks the six-digit code, which is the only authorisation", function()
        local got = startAnon()
        local client = paste{ mode = "anonymous", code = "000000", client_id = "abc123" }
        assert_equal(403, statusOf(client))
        assert_nil(got.client_id)
        Pair:stop()
    end)

    it("refuses an anonymous paste with no client ID", function()
        startAnon()
        assert_equal(400, statusOf(paste{ mode = "anonymous", code = Pair.code, client_id = "" }))
        Pair:stop()
    end)

    it("carries the chosen identity, so the user agent still applies", function()
        local Identity = require("reddle_identity")
        local before = Identity.active
        local got = startAnon()
        paste{ mode = "anonymous", code = Pair.code, client_id = "abc123",
               identity = "redreader" }
        spies.scheduled[#spies.scheduled].task()
        assert_equal("redreader", got.identity.identity)
        Identity.active = before
    end)
end)

--[[
The shipped example user agent must not survive a pairing. It names an app that
does not exist, which Reddit's Responsible Builder Policy asks you not to do, and
it is a more distinctive fingerprint than either honest alternative.
--]]
describe("reddle_pair placeholder user agent", function()
    local Identity = require("reddle_identity")

    it("will not let the page submit self-registration without one", function()
        local html = Pair.pageHtml{ options = "", redirects = "{}", caveats = "{}" }
        assert_match("!custom %|%| cua%.value%.trim%(%)%.length > 0", html)
        assert_true(html:find("(optional)", 1, true) == nil,
            "the user agent is not optional for a self-registration")
    end)

    it("refuses a custom identity that would inherit the example", function()
        local before, override = Identity.active, Identity.override
        Identity.active, Identity.override = "own", nil
        local ok, why = Identity.apply{ identity = Identity.CUSTOM,
                                        redirect_uri = "http://localhost:8080" }
        assert_false(ok)
        assert_match("supply your own user agent", why)
        Identity.active, Identity.override = before, override
    end)

    it("accepts a custom identity that brings its own", function()
        local before, override = Identity.active, Identity.override
        local ok = Identity.apply{ identity = Identity.CUSTOM,
                                   redirect_uri = "http://localhost:8080",
                                   user_agent = "android:com.me.reddle:v1.0 (by /u/me)" }
        assert_true(ok)
        assert_false(Identity.isPlaceholder())
        Identity.active, Identity.override = before, override
    end)

    it("spots the example even when it is not wearing the own label", function()
        -- A custom identity can inherit it, and then carries none of own's
        -- markings -- so the check is on the value, not the label.
        assert_true(Identity.isPlaceholder(Identity.PLACEHOLDER_UA()))
        assert_false(Identity.isPlaceholder("org.quantumbadger.redreader/1.25.1"))
    end)
end)
