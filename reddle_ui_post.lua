--[[
The post screen (DESIGN.md §5.1, §5.3).

A TextViewer -- KOReader's paginated text reader -- so we inherit page turns,
font size and the user's reading settings instead of reinventing them. Buttons
below: comments, the image (if any), and the link.

Images follow §5.3: nothing is fetched until asked for. The button says what it
would fetch; tapping downloads, then hands the file to ImageViewer, which does
the e-ink dithering.

Verified on a Paperwhite 5 (2026-08-16). The post is now rendered as part of the
thread document (reddle_ui_thread); what remains here is the composition and the
image handling.
--]]

local DataStorage = require("datastorage")
local Html = require("reddle_html")
local ImageViewer = require("ui/widget/imageviewer")
local InfoMessage = require("ui/widget/infomessage")
local Markdown = require("reddle_markdown")
local RichText = require("reddle_ui_richtext")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("reddle_gettext")
local T = require("ffi/util").template

local M = {}

local IMAGE_EXT = { jpg = true, jpeg = true, png = true, gif = true, webp = true }

--- Titles and usernames are Reddit's text, not markup: escape before composing.
local function esc(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- The original the post points at, or nil if it is not an image at all.
function M.sourceUrl(post)
    if not post then return nil end
    local url = post.url or post.url_overridden_by_dest
    if type(url) ~= "string" then return nil end
    local ext = url:lower():match("%.(%a+)$")
    if ext and IMAGE_EXT[ext] then return url end
    -- i.redd.it links occasionally arrive without an extension
    if url:match("^https?://i%.redd%.it/") then return url end
    return nil
end

--- The sizes Reddit already made, smallest first.
---
--- Reddit generates a ladder of previews (roughly 108 to 1080 wide) alongside
--- the source, so downloading a 4000px photo to look at it on a 1072px screen is
--- a choice rather than a necessity -- and on a device whose radio is the slow
--- part, an expensive one.
function M.imageVariants(post)
    local out = {}
    local images = post and post.preview and post.preview.images
    local first = type(images) == "table" and images[1]
    if type(first) ~= "table" then return out end
    for _i, r in ipairs(first.resolutions or {}) do
        if type(r.url) == "string" and tonumber(r.width) then
            out[#out + 1] = { url = r.url, width = tonumber(r.width) }
        end
    end
    table.sort(out, function(a, b) return a.width < b.width end)
    local src = first.source
    if type(src) == "table" and type(src.url) == "string" then
        out[#out + 1] = { url = src.url, width = tonumber(src.width) or math.huge,
                          source = true }
    end
    return out
end

--- Which URL to actually fetch.
---
--- opts.quality "original" always takes the source. Anything else -- the default
--- -- takes the smallest preview at least as wide as the screen, because a
--- larger one cannot show more on a panel that size. Falls back to the widest
--- available when every preview is too small, and to the source when Reddit
--- offered no previews at all.
---
--- opts.width is the screen width; without it there is nothing to fit to, so the
--- source is the honest answer rather than an arbitrary preview.
function M.imageUrl(post, opts)
    local source = M.sourceUrl(post)
    if not source then return nil end
    opts = opts or {}
    if opts.quality == "original" or not opts.width then return source end

    local variants = M.imageVariants(post)
    local widest
    for _i, v in ipairs(variants) do
        if not v.source then
            widest = v
            if v.width >= opts.width then return v.url end
        end
    end
    return widest and widest.url or source
end

--- The header block above the body: title, byline, and where a link goes.
function M.header(post, age)
    local lines = { Markdown.toText(post.title or "") }
    local byline = string.format("u/%s · r/%s · %s points · %s comments",
        post.author or "[deleted]", post.subreddit or "?",
        tostring(post.score or 0), tostring(post.num_comments or 0))
    if age then byline = byline .. " · " .. age end
    lines[#lines + 1] = byline
    if not post.is_self and post.url then
        local host = Markdown.host(post.url)
        lines[#lines + 1] = "→ " .. (host or post.url)
    end
    return table.concat(lines, "\n")
end

function M.body(post)
    local text = Markdown.toText(post.selftext or "")
    if text ~= "" then return text end
    if M.imageUrl(post) then return _("[image — use the button below]") end
    if post.is_self then return _("(no text)") end
    return "→ " .. tostring(post.url or "")
end

function M.fullText(post, age)
    return M.header(post, age) .. "\n" .. Markdown.RULE .. "\n\n" .. M.body(post)
end

--- HTML form: Reddit already rendered the markdown for us, so bold, italic,
--- strikethrough, superscript, headings, quotes, lists and code all survive
--- (DESIGN.md §5.4). Falls back to the plain-text path when there is no HTML.
--- The post's own markup, sanitised. Separate from the header so the thread view
--- can compose header + body + comments into one scrolling document (§5.6).
function M.bodyHtml(post)
    local body = post.selftext_html
    if not Html.hasMarkup(body) then
        if M.imageUrl(post) then
            body = "<p><em>" .. esc(M.body(post)) .. "</em></p>"
        else
            body = "<p>" .. esc(M.body(post)):gsub("\n", "<br/>") .. "</p>"
        end
    end
    return Html.sanitize(body)
end

--- Title bold, byline quiet. Escaped by hand rather than sanitised: sanitize
--- strips class attributes, which would take class="meta" with it.
function M.headerHtml(post, age)
    local meta = { string.format("u/%s · r/%s · %s points · %s comments",
        post.author or "[deleted]", post.subreddit or "?",
        tostring(post.score or 0), tostring(post.num_comments or 0)) }
    if age then meta[1] = meta[1] .. " · " .. age end
    if not post.is_self and post.url then
        meta[#meta + 1] = "→ " .. (Markdown.host(post.url) or post.url)
    end
    return table.concat({
        "<p><b>", require("reddle_emoji").markup(esc(Markdown.toText(post.title or ""))),
        "</b></p>",
        '<p class="meta">', (esc(table.concat(meta, "\n")):gsub("\n", "<br/>")), "</p>",
    })
end

function M.fullHtml(post, age)
    return Html.rawDocument(M.headerHtml(post, age) .. "<hr/>" .. M.bodyHtml(post))
end

local function cacheDir()
    local dir = DataStorage:getDataDir() .. "/cache/reddle"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(dir)
    end
    return dir
end

--- What the image cache is allowed to occupy. Two decisions in one number: a
--- Kindle's user partition is small and shared with the reader's books, and the
--- cache exists to save a re-download, not to be an archive -- saving is what
--- keeps a picture (reddle_archive).
M.CACHE_BUDGET = 20 * 1024 * 1024

--- Which files to delete to get under `budget`, oldest first.
---
--- Pure, so the policy can be tested without a filesystem. `entries` is a list
--- of { path, size, mtime }. Returns the paths to remove, and the total that
--- would be left.
function M.trimPolicy(entries, budget)
    local total = 0
    for _i, e in ipairs(entries) do total = total + (e.size or 0) end
    if total <= budget then return {}, total end

    local oldest = {}
    for i, e in ipairs(entries) do oldest[i] = e end
    table.sort(oldest, function(a, b) return (a.mtime or 0) < (b.mtime or 0) end)

    local remove = {}
    for _i, e in ipairs(oldest) do
        if total <= budget then break end
        remove[#remove + 1] = e.path
        total = total - (e.size or 0)
    end
    return remove, total
end

--- Enforce the budget. Called after a download, which is the only thing that
--- grows the cache, so it can never drift far over.
function M.trimCache(budget)
    local dir = cacheDir()
    if not lfs.dir then return end
    local entries = {}
    local ok = pcall(function()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local path = dir .. "/" .. name
                local a = lfs.attributes(path)
                if a and a.mode == "file" then
                    entries[#entries + 1] =
                        { path = path, size = a.size or 0, mtime = a.modification or 0 }
                end
            end
        end
    end)
    if not ok then return end
    local remove = M.trimPolicy(entries, budget or M.CACHE_BUDGET)
    for _i, path in ipairs(remove) do os.remove(path) end
    return #remove
end

--- Where a viewed image lands. Exported so saving can reuse a download the
--- reader has already paid for instead of fetching the same bytes twice.
function M.cachePath(url)
    if not url or url == "" then return nil end
    return cacheDir() .. "/" .. url:gsub("[^%w%.]", "_"):sub(-64)
end

--- The cached file for a url, if it is actually there.
function M.cachedFile(url)
    local path = M.cachePath(url)
    if path and lfs.attributes(path, "mode") == "file" then return path end
    return nil
end

--- Show an image already on disk -- the saved-post path, which never touches the
--- network and works with the radio off.
function M.showFile(path)
    if not path or lfs.attributes(path, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{
            text = _("That saved image is missing."), timeout = 5 })
        return
    end
    UIManager:show(ImageViewer:new{ file = path, fullscreen = true, with_title_bar = false })
end

--- Download on demand, then show. Never called unless the reader taps.
function M.showImage(url, transport)
    local path = M.cachePath(url)
    if lfs.attributes(path, "mode") ~= "file" then
        local info = InfoMessage:new{ text = _("Fetching image…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local body, code = transport{ url = url, timeouts = "file",
            headers = require("reddle_api").fileHeaders() }
        UIManager:close(info)
        if code ~= 200 or not body or #body == 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not fetch the image (HTTP %1)."), tostring(code)), timeout = 5 })
            return
        end
        local f = io.open(path, "wb")
        if not f then
            UIManager:show(InfoMessage:new{ text = _("Could not write to the cache."), timeout = 5 })
            return
        end
        f:write(body); f:close()
        -- The only thing that grows the cache, so the only place it has to be
        -- brought back under budget.
        M.trimCache()
    end
    -- ImageViewer scales to the screen and handles e-ink dithering for us.
    UIManager:show(ImageViewer:new{ file = path, fullscreen = true, with_title_bar = false })
end

--- opts: post, age, api, transport, on_comments(post), links (link context, §5.9)
function M.open(opts)
    local post = opts.post
    local buttons = {}
    local viewer  -- captured by the callbacks below; module state would let a
                  -- second post's viewer close the first one's

    local row = {}
    row[#row + 1] = {
        text = T(_("Comments (%1)"), tostring(post.num_comments or 0)),
        callback = function()
            UIManager:close(viewer)
            if opts.on_comments then opts.on_comments(post) end
        end,
    }
    local img = M.imageUrl(post)
    if img then
        row[#row + 1] = {
            text = T(_("Image (%1)"), Markdown.host(img) or "?"),
            callback = function() M.showImage(img, opts.transport) end,
        }
    end
    buttons[#buttons + 1] = row

    viewer = RichText.show{
        title = post.subreddit and ("r/" .. post.subreddit) or _("Post"),
        html = M.fullHtml(post, opts.age),
        text = M.fullText(post, opts.age),   -- used where HTML cannot be rendered
        buttons_table = buttons,
        -- Without this, every link the reader wrote into the post is inert:
        -- ScrollHtmlWidget only hit-tests when it has been given a callback.
        on_link = function(link)
            local ctx = {}
            for k, v in pairs(opts.links or {}) do ctx[k] = v end
            ctx.api = ctx.api or opts.api
            ctx.transport = ctx.transport or opts.transport
            require("reddle_ui_links").handle(link and link.uri, ctx)
        end,
    }
    return viewer
end

return M
