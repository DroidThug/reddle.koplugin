--[[
Token lifecycle. The strings Reddit sees (user agent, redirect URI) live in
reddle_identity.lua.

No KOReader requires: takes a store (LuaSettings-shaped), a transport and a
clock, so it runs under plain LuaJIT.
--]]

local Api = require("reddle_api")
local Identity = require("reddle_identity")

local M = {}

--- The registered redirect URI for the active identity (reddle_identity.lua).
function M.redirectUri()
    return Identity.redirectUri()
end

M.REFRESH_MARGIN = 300 -- refresh this many seconds before expiry

-- Pure-Lua base64 so we don't depend on KOReader's `mime` off-device.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.base64(data)
    local out, n = {}, #data
    local i = 1
    while i + 2 <= n do
        local a, b, c = data:byte(i, i + 2)
        local v = a * 65536 + b * 256 + c
        out[#out + 1] = B64:sub(math.floor(v / 262144) % 64 + 1, math.floor(v / 262144) % 64 + 1)
            .. B64:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
            .. B64:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
            .. B64:sub(v % 64 + 1, v % 64 + 1)
        i = i + 3
    end
    local rest = n - i + 1
    if rest == 1 then
        local a = data:byte(i)
        local v = a * 16
        out[#out + 1] = B64:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
            .. B64:sub(v % 64 + 1, v % 64 + 1) .. "=="
    elseif rest == 2 then
        local a, b = data:byte(i, i + 1)
        local v = (a * 256 + b) * 4
        out[#out + 1] = B64:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
            .. B64:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
            .. B64:sub(v % 64 + 1, v % 64 + 1) .. "="
    end
    return table.concat(out)
end

local Auth = {}
Auth.__index = Auth

--- deps: store (readSetting/saveSetting/delSetting/flush), transport, json,
--- now (optional clock, defaults to os.time)
function M.new(deps)
    return setmetatable({
        store = assert(deps.store, "store required"),
        transport = assert(deps.transport, "transport required"),
        json = assert(deps.json, "json codec required"),
        now = deps.now or os.time,
    }, Auth)
end

--- The two ways Reddle can talk to Reddit.
---
--- "anonymous" needs a client ID and nothing else: Reddit's installed_client
--- grant mints an app-only token with no account behind it, so there is no
--- browser step and no authorization code to capture -- which is the hardest
--- part of setting this up. It costs the personalised front page and
--- subscriptions, because those are account state and cannot be had without an
--- account. Reddle's own saved posts are on disk, so they still work.
M.ANONYMOUS = "anonymous"
M.ACCOUNT = "account"

--- Reddit's own constant. The name is the API's, not a claim Reddle makes: it
--- asks Reddit not to tie the token to a device identity.
M.DEVICE_ID = "DO_NOT_TRACK_THIS_DEVICE"
M.INSTALLED_CLIENT_GRANT = "https://oauth.reddit.com/grants/installed_client"

function Auth:mode()
    if self.store:readSetting("refresh_token") ~= nil then return M.ACCOUNT end
    if self.store:readSetting("client_id") ~= nil then return M.ANONYMOUS end
    return nil
end

--- Anything Reddle can make a request with. Anonymous counts: a client ID alone
--- is enough to read Reddit.
function Auth:hasCredentials()
    return self.store:readSetting("client_id") ~= nil
end

--- Specifically signed in as somebody, which is what the personalised front
--- page and "Log out" are about.
function Auth:hasAccount()
    return self.store:readSetting("client_id") ~= nil
        and self.store:readSetting("refresh_token") ~= nil
end

--- Drop the cached access token (call after a 401).
function Auth:invalidate()
    self.store:delSetting("access_token")
    self.store:delSetting("expires_at")
    self.store:flush()
end

--- Forget the account, keeping everything that is not a credential.
---
--- The client ID and the chosen identity stay: they identify the *app*, not the
--- user, and making someone re-paste a client ID to switch accounts is pure
--- friction. Saved posts are untouched -- they are on disk, not in here.
---
--- This does NOT revoke anything at Reddit. The refresh token stops being on the
--- device, but it remains valid until revoked at reddit.com/prefs/apps, and the
--- UI has to say so.
function Auth:clear()
    self.store:delSetting("refresh_token")
    self.store:delSetting("access_token")
    self.store:delSetting("expires_at")
    self.store:flush()
end

function Auth:save(client_id, refresh_token)
    self.store:saveSetting("client_id", client_id)
    if refresh_token then
        self.store:saveSetting("refresh_token", refresh_token)
    else
        -- Anonymous: a leftover refresh token would silently sign the reader
        -- back in as whoever paired last.
        self.store:delSetting("refresh_token")
    end
    self.store:delSetting("access_token")
    self.store:delSetting("expires_at")
    self.store:flush()
end

--- Store a client ID and nothing else. That is all anonymous access needs.
function Auth:saveAnonymous(client_id)
    if type(client_id) ~= "string" or client_id == "" then
        return false, "no client ID"
    end
    self:save(client_id, nil)
    return true
end

--- Percent-encode for a form body. Reddit's codes carry "-" and "_", which are
--- unreserved and must survive untouched; the redirect URI carries ":" and "/",
--- which must not.
function M.urlEncode(s)
    return (tostring(s or ""):gsub("[^%w%-%_%.%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- Trade an authorization code for a refresh token.
---
--- Done on the device, which is what lets pairing work from a browser alone: the
--- far side only ever handles a single-use code, and the long-lived credential
--- never crosses the LAN.
---
--- `redirect_uri` defaults to the active identity's. Reddit checks it against the
--- registration the code was issued for, and a mismatch is a bare
--- "invalid_grant" with nothing to say why.
---
--- Returns refresh_token or nil, err. Saves nothing.
function Auth:exchangeCode(client_id, auth_code, redirect_uri)
    if type(client_id) ~= "string" or client_id == "" then
        return nil, "no client ID"
    end
    if type(auth_code) ~= "string" or auth_code == "" then
        return nil, "no authorization code"
    end
    if type(redirect_uri) ~= "string" or redirect_uri == "" then
        redirect_uri = M.redirectUri()
    end
    local body = "grant_type=authorization_code"
        .. "&code=" .. M.urlEncode(auth_code)
        .. "&redirect_uri=" .. M.urlEncode(redirect_uri)
    local api = Api.new{ transport = self.transport, json = self.json }
    local res, code, raw = api:call{
        url = Api.TOKEN_URL,
        method = "POST",
        basic = M.base64(client_id .. ":"),   -- installed app: empty password
        body = body,
    }
    if not res or not res.refresh_token then
        -- `raw` can contain the code; Reddit's errors here are short and
        -- generic ("invalid_grant"), so surface the field, never the body.
        local why = (type(res) == "table" and res.error) or ("HTTP " .. tostring(code))
        if not res and not code then why = tostring(raw) end
        return nil, "authorization failed: " .. tostring(why)
    end
    return res.refresh_token
end

--- Returns token or nil, err
function Auth:getAccessToken()
    if not self:hasCredentials() then
        return nil, "no credentials: pair first"
    end

    local token = self.store:readSetting("access_token")
    local expires_at = self.store:readSetting("expires_at") or 0
    if token and self.now() < expires_at - M.REFRESH_MARGIN then
        return token
    end

    local client_id = self.store:readSetting("client_id")
    local refresh = self.store:readSetting("refresh_token")
    -- Anonymous tokens have no refresh token and are not meant to: they last a
    -- day and another one is a single request away, so expiry just mints again.
    local body = refresh
        and ("grant_type=refresh_token&refresh_token=" .. refresh)
        or ("grant_type=" .. M.urlEncode(M.INSTALLED_CLIENT_GRANT)
            .. "&device_id=" .. M.urlEncode(M.DEVICE_ID))
    -- installed app == non-confidential client: empty password, hence the colon
    local api = Api.new{ transport = self.transport, json = self.json }
    local res, code, raw = api:call{
        url = Api.TOKEN_URL,
        method = "POST",
        basic = M.base64(client_id .. ":"),
        body = body,
    }
    if not res or not res.access_token then
        local what = refresh and "token refresh" or "anonymous sign-in"
        return nil, string.format("%s failed (HTTP %s): %s",
            what, tostring(code), tostring(raw))
    end
    self.store:saveSetting("access_token", res.access_token)
    self.store:saveSetting("expires_at", self.now() + (tonumber(res.expires_in) or 3600))
    self.store:flush()
    return res.access_token
end

M.Auth = Auth
return M
