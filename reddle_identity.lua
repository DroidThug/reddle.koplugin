--[[
Which app Reddle presents as. Change M.active to switch; nothing else may
hard-code a user agent or redirect URI. reddle_api and reddle_auth read from
here, and tools/identity.sh parses this file so the desktop cannot disagree with
the device.

The client ID is not here. It is per-install, arrives through pairing, and lives
in the settings file; only the strings Reddit sees are configured here.

Measured against the live API:
  - an empty User-Agent gets HTTP 403; the header is mandatory
  - a UA containing "isfun" gets HTTP 403; Reddit blocklists dead-app UAs
  - the UA is not otherwise bound to the client ID per-request
--]]

local M = {}

M.identities = {
    -- patcheddit's documented fallback: RedReader's identity, whose client ID
    -- carries a non-commercial/accessibility exemption. These exact strings are
    -- the defaults hard-coded in patcheddit's SpoofClientPatch.kt, so they are
    -- also what every other patcheddit user sends.
    redreader = {
        label = "RedReader (patcheddit default)",
        user_agent = "org.quantumbadger.redreader/1.25.1",
        redirect_uri = "redreader://rr_oauth_redir",
        -- RedReader's own master is at versionName 1.26, but 1.25.1 is
        -- patcheddit's constant and therefore the value that blends in.
        client_id_hint = "install RedReader, authorize it, take the App ID from the confirmation email",
    },

    -- Dystopia is the other client the Apollo-Reborn project documents as a
    -- source of a working client ID, obtained the same way as RedReader's:
    -- authorize the real app once and read the App ID out of Reddit's email.
    --
    -- Redirect URI from Apollo-Reborn's docs, user agent supplied by the app's
    -- own string (2026-08-20). Note the missing space before "(by" -- that is
    -- Dystopia's actual UA, not a typo here, and it is copied verbatim because
    -- the point of a borrowed identity is to match what the real client sends.
    dystopia = {
        label = "Dystopia",
        user_agent = "ios:com.CarbonDev.Dystopia:v1.0.1(by /u/DystopiaForReddit)",
        redirect_uri = "dystopia://response",
        client_id_hint = "install Dystopia, authorize it, take the App ID from the confirmation email",
    },

    -- Register your own at https://www.reddit.com/prefs/apps/ (type: installed
    -- app). This is the only honest option per Reddit's UA rule, and it unlocks
    -- the http://localhost redirect, which makes the desktop flow far simpler
    -- (DESIGN.md §3.3b). Edit the placeholders before selecting it.
    own = {
        label = "Self-registered",
        -- An example, not a value to send. It is what goes out if nobody
        -- supplies a real one, which is why M.isPlaceholder exists: a user agent
        -- naming a fictional app and a fictional user identifies nobody, and is
        -- a more distinctive fingerprint than either honest alternative.
        placeholder = true,
        user_agent = "android:com.example.reddle:v1.0 (by /u/your_username)",
        redirect_uri = "http://localhost:8080",
        client_id_hint = "from your own app registration at reddit.com/prefs/apps",
    },
}

--- Which identity is in use. This is the switch.
---
--- Deliberately NOT a borrowed one. A default is an endorsement, and it is what
--- most people would ship with without ever making a decision -- so presenting
--- somebody else's registration as the out-of-the-box choice is not something
--- this project wants to do. The borrowed identities remain available and are
--- offered in the pairing page; picking one is a conscious act.
---
--- The placeholder user agent below is also a deliberate failure mode: if it
--- ever reaches Reddit unedited it earns a loud 403 rather than quietly
--- impersonating an example app.
M.active = "own"

--- OAuth scopes, comma-separated as Reddit's authorize endpoint wants them.
--- Read-only on purpose (README, "Scope"): no vote, submit, edit or subscribe.
--- Both the device's pairing page and tools/reddle-bridge.sh read this, so the
--- two can never ask for different permissions.
M.SCOPE = "identity,read,mysubreddits,history"

--- A custom identity chosen at pairing time, if any. Set from settings at
--- startup (main.lua) and by the pairing page. Kept separate from M.identities
--- so the built-in catalogue stays a constant that the shell tools can parse.
M.override = nil

M.CUSTOM = "custom"

--- Apply a stored or freshly-chosen identity. Accepts:
---   { identity = "redreader" }                        a built-in
---   { identity = "custom", redirect_uri = "x://y",    your own registration
---     user_agent = "..." }                            (user_agent optional)
--- Returns ok, err -- callers must not let a bad stored value break startup.
function M.apply(opts)
    opts = opts or {}
    local name = opts.identity
    if name == nil or name == "" then return true end
    if name == M.CUSTOM then
        local uri = opts.redirect_uri
        if type(uri) ~= "string" or not uri:match("^%a[%w+.-]*:") then
            return false, "a custom identity needs a redirect URI like scheme://path"
        end
        -- Keeping the previous user agent is the safer default: an empty or
        -- malformed one is a hard 403 from Reddit.
        local ua = (type(opts.user_agent) == "string" and opts.user_agent ~= "")
            and opts.user_agent or M.userAgent()
        -- Refused rather than accepted-and-warned. This is the moment the choice
        -- is made and the moment a real answer is to hand; letting it through
        -- means every later request names an app that does not exist.
        if M.isPlaceholder(ua) then
            return false, "supply your own user agent, like " ..
                "android:com.you.reddle:v1.0 (by /u/you)"
        end
        M.override = {
            label = "Custom",
            redirect_uri = uri,
            user_agent = ua,
        }
        M.active = M.CUSTOM
        return true
    end
    if not M.identities[name] then
        return false, "unknown identity: " .. tostring(name)
    end
    M.override, M.active = nil, name
    return true
end

function M.current()
    if M.active == M.CUSTOM and M.override then return M.override end
    local id = M.identities[M.active]
    if not id then
        error("reddle_identity: unknown identity '" .. tostring(M.active) .. "'")
    end
    return id
end

--- Borrowed identities offered as presets in the pairing page. `own` is not
--- here: choosing it means supplying a redirect URI and user agent, which is
--- what the page's "Custom" branch already does.
function M.names()
    return { "redreader", "dystopia" }
end

--- What each preset costs someone else, shown at the point of choice. Not a
--- legal notice -- a fact the person choosing is entitled to know.
M.CAVEATS = {
    redreader = "Rate-limit exemption granted to RedReader for accessibility. "
        .. "Traffic under it is attributed to them, and abuse puts their exemption at risk.",
    dystopia = "Dystopia's developer may be billed for calls made under their client ID.",
}

--- The example user agent, as a value. Compared against rather than flagged,
--- because a custom identity that supplied no user agent inherits whatever was
--- active -- so the placeholder can end up on an identity that is not `own`,
--- carrying none of its markings.
function M.PLACEHOLDER_UA()
    return M.identities.own.user_agent
end

--- True when the active identity is still sending the shipped example user
--- agent. Reddit's Responsible Builder Policy asks that you not misrepresent how
--- you are accessing its data, and this misrepresents it by accident.
function M.isPlaceholder(user_agent)
    if user_agent ~= nil then return user_agent == M.PLACEHOLDER_UA() end
    local ok, current = pcall(M.current)
    return ok and current.user_agent == M.PLACEHOLDER_UA()
end

function M.userAgent()
    return M.current().user_agent
end

function M.redirectUri()
    return M.current().redirect_uri
end

return M
