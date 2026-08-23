--[[
What a tapped link means (DESIGN.md §5.9).

Every tappable thing in Reddle is an anchor: MuPDF hit-tests anchors against its
own layout boxes, and that is the only per-element tap targeting a rendered
document offers. Taps arrive here as a URI.

  - Ours, on the `reddle:` scheme, minted by whoever rendered the document:
    `reddle:post:3` is the fourth row of the listing on screen.
  - Reddit's, from inside a post or comment body. These can be anything.

Kept out of the widgets because it is pure string work with a lot of edge cases
(protocol-relative hrefs, preview.redd.it query signatures, relative /r/ links).
--]]

local Html = require("reddle_html")

local M = {}

M.SCHEME = "reddle:"

-- Extensions worth handing to ImageViewer. Kept in step with reddle_ui_post's
-- own list, which decides whether a *post* is an image post.
M.IMAGE_EXT = { jpg = true, jpeg = true, png = true, gif = true, webp = true }

-- Hosts that serve an image regardless of what the path looks like.
M.IMAGE_HOSTS = {
    ["i.redd.it"] = true,
    ["preview.redd.it"] = true,
    ["i.imgur.com"] = true,
    ["external-preview.redd.it"] = true,
}

--- Reddit's own domains, in every form the site emits.
local function isRedditHost(host)
    if not host then return false end
    host = host:lower():gsub("^www%.", "")
    return host == "reddit.com" or host == "redd.it"
        or host:match("%.reddit%.com$") ~= nil   -- old., np., new., sh.
end

--- Split a URI into scheme, host and path. Nothing fancy: enough to classify.
function M.parse(uri)
    uri = tostring(uri or "")
    -- Reddit escapes hrefs inside *_html, so a preview URL arrives carrying
    -- &amp; between its query parameters. Fetching that verbatim gets a 403:
    -- the signature is computed over the real query string.
    uri = Html.unescape(uri)
    local scheme, rest = uri:match("^(%a[%w+.-]*)://(.*)$")
    if not rest then
        -- Protocol-relative (//i.redd.it/x.png) -- Reddit still emits these.
        rest = uri:match("^//(.*)$")
        if rest then scheme = "https" end
    end
    if rest then
        local host, path = rest:match("^([^/]+)(.*)$")
        return scheme, (host or rest):lower(), (path ~= "" and path or "/")
    end
    -- A scheme with no authority: mailto:, tel:, and anything else that is not
    -- ours to open. Caught here so classify can refuse it rather than reading it
    -- as a relative path.
    local opaque = uri:match("^%a[%w+.-]*:")
    if opaque and not uri:match("^reddle:") then
        return opaque:sub(1, -2):lower(), nil, uri
    end
    return nil, nil, uri   -- relative: /r/kindle, /u/someone
end

function M.isImageUrl(uri)
    local scheme, host, path = M.parse(uri)
    if scheme and scheme ~= "http" and scheme ~= "https" then return false end
    if host and M.IMAGE_HOSTS[host] then return true end
    -- Strip the query before looking at the extension: preview.redd.it paths end
    -- .png but carry ?width=640&s=<signature>.
    local ext = tostring(path or ""):gsub("%?.*$", ""):gsub("#.*$", ""):lower():match("%.(%a+)$")
    return ext ~= nil and M.IMAGE_EXT[ext] == true
end

--- A Reddit post id out of any of the shapes Reddit links to one by.
--- Returns id, subreddit (subreddit may be nil -- /comments/<id> is valid).
function M.postIdFrom(path)
    path = tostring(path or "")
    local sub, id = path:match("^/r/([%w_]+)/comments/(%w+)")
    if id then return id, sub end
    id = path:match("^/comments/(%w+)")
    if id then return id, nil end
    return nil, nil
end

--- kind, payload.
---
--- kinds:
---   "post"        payload = index into the listing on screen
---   "more"        payload = id of the `more` stub to expand
---   "continue"    payload = comment id to re-root the thread at
---   "collapse"    payload = comment id to fold or unfold
---   "comment"     payload = comment fullname (t1_...) -- for §8, voting
---   "image"       payload = url
---   "reddit_post" payload = { id = , subreddit = }
---   "reddit_sub"  payload = subreddit name
---   "reddit_user" payload = username
---   "external"    payload = url
---   nil           unrecognised; the caller should do nothing
function M.classify(uri)
    uri = tostring(uri or "")
    if uri == "" then return nil end

    -- Ours first: no network, no ambiguity.
    local verb, arg = uri:match("^reddle:(%a+):(.+)$")
    if verb then
        if verb == "post" then
            -- The listing's rows are ours and are never renumbered under a
            -- rendered document, so position is the honest key there.
            local n = tonumber(arg)
            return n and verb or nil, n
        end
        if verb == "more" or verb == "continue"
                or verb == "comment" or verb == "collapse" then
            return verb, arg
        end
        return nil
    end

    if M.isImageUrl(uri) then return "image", Html.unescape(uri) end

    local scheme, host, path = M.parse(uri)
    if scheme and scheme ~= "http" and scheme ~= "https" then
        -- mailto:, and anything else sanitize let through. Not ours to open.
        return "external", uri
    end

    -- A relative href (no host) inside a Reddit body is by definition a Reddit
    -- link -- that is the only reason Reddit emits one.
    if host == nil or isRedditHost(host) then
        if host == "redd.it" then
            local id = path:match("^/(%w+)")
            if id then return "reddit_post", { id = id } end
        end
        local id, sub = M.postIdFrom(path)
        if id then return "reddit_post", { id = id, subreddit = sub } end
        local user = path:match("^/u/([%w_-]+)") or path:match("^/user/([%w_-]+)")
        if user then return "reddit_user", user end
        local only_sub = path:match("^/r/([%w_]+)/?$")
        if only_sub then return "reddit_sub", only_sub end
        if host == nil then return nil end   -- some other relative path: ignore
    end

    return "external", Html.unescape(uri)
end

--- Minting the synthetic hrefs, so the format lives in one place.
function M.href(verb, arg) return M.SCHEME .. verb .. ":" .. tostring(arg) end

return M
