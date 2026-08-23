--[[
Reddit API layer.

No KOReader or LuaSocket requires: takes a `transport` function (reddle_http.lua)
and a JSON codec, so it runs under plain LuaJIT in spec/. See M.buildHeaders for
the header set, which is the part that must not drift.
--]]

local Identity = require("reddle_identity")

local M = {}

M.OAUTH_HOST = "https://oauth.reddit.com"
M.TOKEN_URL = "https://www.reddit.com/api/v1/access_token"

-- Which app we present as is configured in reddle_identity.lua -- never hard-code
-- it here. Note that KOReader's socketutil monkey-patches a global http.USERAGENT
-- to "KOReader/...", so this header must be set explicitly on *every* request:
-- LuaSocket only injects its own default when the header is absent. Verified live:
-- an empty User-Agent is rejected with HTTP 403.
function M.userAgent()
    return Identity.userAgent()
end

--- Headers for fetching a file straight off a CDN: the identity's user agent
--- and deliberately nothing else.
---
--- Two reasons this exists rather than each caller passing nil. Omitting headers
--- entirely does not mean "no User-Agent": KOReader's socketutil monkey-patches
--- a global http.USERAGENT, so LuaSocket fills in "KOReader/..." and the image
--- fetch contradicts the API call that produced the link, from the same address,
--- seconds later. And these URLs are not all Reddit's -- a post can link
--- anywhere -- so the token must never be attached to one.
function M.fileHeaders()
    return { ["User-Agent"] = M.userAgent() }
end

function M.buildHeaders(opts)
    opts = opts or {}
    local headers = { ["User-Agent"] = M.userAgent() }
    if opts.token then
        -- lowercase "bearer" is what Reddit's own docs specify
        headers["Authorization"] = "bearer " .. opts.token
    elseif opts.basic then
        headers["Authorization"] = "Basic " .. opts.basic
    end
    if opts.body then
        headers["Content-Type"] = opts.content_type or "application/x-www-form-urlencoded"
        headers["Content-Length"] = tostring(#opts.body)
    end
    for k, v in pairs(opts.extra or {}) do
        headers[k] = v
    end
    return headers
end

function M.urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Sorted key order so the same query table always yields the same URL (testable,
-- and it makes cache keys stable).
function M.buildUrl(host, path, query)
    query = query or {}
    local q = {}
    for k in pairs(query) do q[#q + 1] = k end
    table.sort(q)
    local parts = {}
    for _, k in ipairs(q) do
        local v = query[k]
        if v ~= nil and v ~= false then
            parts[#parts + 1] = M.urlencode(k) .. "=" .. M.urlencode(v)
        end
    end
    if #parts == 0 then return host .. path end
    return host .. path .. "?" .. table.concat(parts, "&")
end

--- Reddit sends these on every response; the client ID is shared with other
-- patcheddit users, so the quota is shared too (DESIGN.md §4.3).
function M.parseRateLimit(headers)
    if type(headers) ~= "table" then return nil end
    local function num(name)
        local v = headers[name] or headers[name:lower()]
        return v and tonumber(v) or nil
    end
    local used, remaining, reset = num("x-ratelimit-used"), num("x-ratelimit-remaining"), num("x-ratelimit-reset")
    if not (used or remaining or reset) then return nil end
    return { used = used, remaining = remaining, reset = reset }
end

M.BACKOFF_THRESHOLD = 10

function M.shouldBackOff(rl)
    return rl ~= nil and rl.remaining ~= nil and rl.remaining < M.BACKOFF_THRESHOLD
end

--- KOReader's JSON decoder represents JSON `null` as a sentinel *function*, not as
--- nil. It is therefore truthy: `if post.selftext_html then ... end` passes, and the
--- next indexing operation dies with "attempt to index a function value" -- which is
--- exactly how the post view crashed on the device. Reddit sends null constantly
--- (selftext_html on link posts, `after` at the end of a listing, body_html on
--- deleted comments), so scrub it once here at the boundary.
local function scrub(v, depth)
    local t = type(v)
    if t == "function" or t == "userdata" then return nil end
    if t ~= "table" or depth > 32 then return v end
    for k, val in pairs(v) do
        v[k] = scrub(val, depth + 1)   -- assigning nil during pairs() is safe in Lua
    end
    return v
end

function M.scrubNulls(decoded)
    return scrub(decoded, 0)
end

--- Turn JSON's escaped UTF-16 surrogate pairs into ordinary UTF-8 before the
--- device JSON decoder sees them. Reddit still emits these for supplementary
--- characters (emoji) even with raw_json=1; KOReader's decoder replaces each
--- surrogate half with U+FFFD, leaving a row of diamond-question-mark glyphs
--- that the renderer can no longer recover. Literal UTF-8 is left untouched.
local function utf8Codepoint(cp)
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40)
end

function M.decodeSurrogatePairs(raw)
    if type(raw) ~= "string" or not raw:find("\\u", 1, true) then return raw end
    return (raw:gsub("\\u([dD][89AaBb][%x][%x])\\u([dD][c-fC-F][%x][%x])",
        function(high, low)
            local hi, lo = tonumber(high, 16), tonumber(low, 16)
            return utf8Codepoint(0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00))
        end))
end

local Api = {}
Api.__index = Api

--- deps: transport (required), json (required, .decode), auth (optional)
function M.new(deps)
    return setmetatable({
        transport = assert(deps.transport, "transport required"),
        json = assert(deps.json, "json codec required"),
        auth = deps.auth,
        ratelimit = nil,
    }, Api)
end

--- Raw call. Returns decoded_table|nil, code, raw_body
function Api:call(opts)
    local headers = M.buildHeaders{
        token = opts.token,
        basic = opts.basic,
        body = opts.body,
        content_type = opts.content_type,
        extra = opts.headers,
    }
    local raw, code, resp_headers = self.transport{
        url = opts.url,
        method = opts.method or "GET",
        headers = headers,
        body = opts.body,
        timeouts = opts.timeouts,
    }
    local rl = M.parseRateLimit(resp_headers)
    if rl then self.ratelimit = rl end
    if code ~= 200 then return nil, code, raw end
    local ok, decoded = pcall(self.json.decode, M.decodeSurrogatePairs(raw))
    if not ok then return nil, code, raw end
    return M.scrubNulls(decoded), code, raw
end

--- Authenticated GET against oauth.reddit.com, with a single refresh-and-retry
-- on 401 (DESIGN.md §3.4: refresh once, then give up -- never loop).
function Api:get(path, query)
    query = query or {}
    query.raw_json = 1 -- else Reddit HTML-escapes &<> in every body
    local url = M.buildUrl(M.OAUTH_HOST, path, query)

    local token, err = self.auth:getAccessToken()
    if not token then return nil, nil, err end

    local decoded, code, raw = self:call{ url = url, token = token }
    if code == 401 then
        self.auth:invalidate()
        token, err = self.auth:getAccessToken()
        if not token then return nil, code, err end
        decoded, code, raw = self:call{ url = url, token = token }
    end
    return decoded, code, raw
end

--- Cursor pagination: hand back the listing's `after` for the next call.
function M.nextCursor(listing)
    if type(listing) ~= "table" or type(listing.data) ~= "table" then return nil end
    local after = listing.data.after
    if after == nil or after == "" then return nil end
    return after
end

M.Api = Api
return M
