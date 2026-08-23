--[[
Post-listing view-model (DESIGN.md §5.1).

Turns Reddit's Listing JSON into rows, and owns the `after` cursor. No KOReader
requires -- the widget layer is reddle_ui_listing.lua.
--]]

local Api = require("reddle_api")

local M = {}

M.DEFAULT_SORT = "hot"
M.PAGE_SIZE = 25

--- `best` is a front-page sort only: /r/<sub>/best is not a listing Reddit serves.
M.SORTS = { "hot", "new", "top", "rising", "controversial" }
M.FRONT_SORTS = { "best", "hot", "new", "top", "rising", "controversial" }

--- Sorts that take a time window; the rest ignore `t` entirely.
M.TIMED = { top = true, controversial = true }
M.TIMES = { "hour", "day", "week", "month", "year", "all" }
M.DEFAULT_TIME = "day"

--- Search has its own sort vocabulary -- "hot" means something here, "rising"
--- does not.
M.SEARCH_SORTS = { "relevance", "hot", "top", "new", "comments" }
M.DEFAULT_SEARCH_SORT = "relevance"

function M.sortsFor(subreddit)
    return (subreddit and subreddit ~= "") and M.SORTS or M.FRONT_SORTS
end

--- 2203 -> "2.2k". Right-aligned in a narrow column, so keep it to 4 glyphs.
function M.formatScore(n)
    n = tonumber(n) or 0
    if n < 1000 then return tostring(n) end
    if n < 10000 then
        local s = string.format("%.1fk", n / 1000)
        return (s:gsub("%.0k$", "k"))
    end
    if n < 1000000 then return string.format("%dk", math.floor(n / 1000 + 0.5)) end
    local s = string.format("%.1fm", n / 1000000)
    return (s:gsub("%.0m$", "m"))
end

--- Reddit-style relative age. Coarse on purpose: nobody reading on e-ink cares
--- about the difference between 61 and 89 minutes.
function M.formatAge(created_utc, now)
    local secs = (now or os.time()) - (tonumber(created_utc) or 0)
    if secs < 0 then secs = 0 end
    if secs < 60 then return "now" end
    if secs < 3600 then return string.format("%dm", math.floor(secs / 60)) end
    if secs < 86400 then return string.format("%dh", math.floor(secs / 3600)) end
    if secs < 86400 * 30 then return string.format("%dd", math.floor(secs / 86400)) end
    if secs < 86400 * 365 then return string.format("%dmo", math.floor(secs / (86400 * 30))) end
    return string.format("%dy", math.floor(secs / (86400 * 365)))
end

--- Collapse whitespace: Reddit titles can carry newlines, which would break the
--- two-line item layout.
function M.oneLine(s)
    return (tostring(s or ""):gsub("%s+", " "):gsub("^%s", ""):gsub("%s$", ""))
end

--- One Menu item from one listing child.
--
-- NB: a Menu item is always ONE line of text. MenuItem does `self.text:gsub("\n", " ")`
-- unconditionally (menu.lua), so the two-line title/byline layout this originally
-- aimed for is not achievable; items_max_lines only allows wrapping by width. The
-- byline therefore follows the title after an em dash, which at least reads as a
-- break rather than running straight on.
function M.rowFor(child, now)
    local d = (type(child) == "table" and child.data) or {}
    local bits = { "u/" .. (d.author or "[deleted]") }
    bits[#bits + 1] = tostring(tonumber(d.num_comments) or 0) .. "c"
    bits[#bits + 1] = M.formatAge(d.created_utc, now)
    if not d.is_self and d.domain and not tostring(d.domain):match("^self%.") then
        bits[#bits + 1] = d.domain
    end
    if d.over_18 then bits[#bits + 1] = "NSFW" end
    if d.stickied then bits[#bits + 1] = "pinned" end
    if d.reddle_note then bits[#bits + 1] = tostring(d.reddle_note) end
    -- The plain-text path has no colour to dim, so it says the word.
    if d.reddle_read then bits[#bits + 1] = "read" end

    return {
        id = d.id,
        fullname = d.id and ("t3_" .. d.id) or nil,
        text = require("reddle_emoji").substitute(M.oneLine(d.title))
            .. "  —  " .. table.concat(bits, " · "),
        mandatory = M.formatScore(d.score),
        post = d,
    }
end

--- Rendering the listing as a document instead of a Menu (§5.7).
---
--- Menu gives one line per item, which is what forced the title and byline onto
--- the same line and made the whole screen read as noise. A document can put the
--- title on its own line in bold and let the byline sit under it, quiet -- and an
--- anchor makes the whole title a tap target.
--- Each post is a card: a hairline box, which is what makes a list of posts read
--- as separate things rather than as one column of text. Deliberately restrained
--- for e-ink -- 1px, no fill, no rounding. Ghosting is not a worry here because
--- paging repaints the region anyway.
M.LISTING_CSS = [[
.post { margin: 0 0 0.55em 0; }
.post p { margin: 0 0 0.2em 0; }
.post p.meta { margin: 0; }
.post a { text-decoration: none; font-weight: bold; }
/* The byline is a tap target too (see htmlFor), but it must not start looking
   like one -- a whole listing of underlined grey would be unreadable. */
.post p.meta a { font-weight: normal; color: #666666; text-decoration: none; }
.pinned { font-style: italic; }
.score { font-weight: bold; color: #333333; }
/* Kindle's inherited link colour is greyish, so make unread titles explicitly
   black rather than looking already-read at a glance. */
.post > p > a { color: #000000; }
/* Read: a single class, not `.post.read` -- compound selectors are not something
   MuPDF's CSS subset can be relied on for (§5.2.2). */
.readtitle { color: #666666; }
.readmark { color: #999999; }
]]

local function esc(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- The tap target for post `index`. Resolved by position, not by id: the reader
--- only ever taps a post that is on screen, and the row order is ours.
function M.postHref(index)
    return "reddle:post:" .. tostring(index)
end

function M.postIndexFromHref(uri)
    local n = tostring(uri or ""):match("^reddle:post:(%d+)$")
    return n and tonumber(n) or nil
end

--- One post as markup. Mirrors rowFor, which still serves the plain-text path.
function M.htmlFor(child, now, index)
    local d = (type(child) == "table" and child.data) or {}
    local bits = { "u/" .. (d.author or "[deleted]") }
    bits[#bits + 1] = tostring(tonumber(d.num_comments) or 0) .. "c"
    bits[#bits + 1] = M.formatAge(d.created_utc, now)
    if not d.is_self and d.domain and not tostring(d.domain):match("^self%.") then
        bits[#bits + 1] = tostring(d.domain)
    end
    if d.over_18 then bits[#bits + 1] = "NSFW" end
    -- Set by the saved-post screens to mark what a record is still missing, so
    -- an incomplete archive is visible in the list rather than only on opening.
    if d.reddle_note then bits[#bits + 1] = tostring(d.reddle_note) end

    -- No pin glyph of our own: U+1F4CC is one of the ones this device cannot
    -- draw, and it draws as blank rather than as a box -- so it was an invisible
    -- character and a stray space. "pinned" is already in the byline below.
    local title = require("reddle_emoji").markup(esc(M.oneLine(d.title)))
    if d.stickied then title = '<span class="pinned">' .. title .. "</span>" end

    -- Read posts are marked two ways, because either alone is too easy to miss
    -- on e-ink: the title goes grey (the visited-link idiom, readable at a
    -- glance down a column) and a small square trails it. U+25AA is in the
    -- U+25xx block this device draws completely -- the same range as the
    -- comment fold triangles.
    --
    -- Not a true corner marker: that needs float or absolute positioning, and
    -- MuPDF's support for either is unverified (see the Rendering test, which
    -- probes both). Trailing the title is in normal flow and cannot fail.
    local card = "post card"
    if d.reddle_read then
        card = card .. " read"
        title = '<span class="readtitle">' .. title .. '</span>'
            .. ' <span class="readmark">\226\150\170</span>'
    end

    -- The score leads and is bold: it is the one number you scan a listing for.
    --
    -- Both lines are anchors to the same post, and that is the fix for the worst
    -- thing about this screen: MuPDF hit-tests taps against the boxes it laid the
    -- *anchor text* into, so with only the title linked, everything else in the
    -- card -- the byline, the padding, the gap after a short title -- fell through
    -- to TextViewer's tap-to-turn-page. Tapping a post you were looking at turned
    -- the page instead. Two anchors cover both text lines of the card.
    local href = M.postHref(index)
    return string.format(
        '<div class="%s"><p><a href="%s">%s</a></p>' ..
        '<p class="meta"><a href="%s"><span class="score">%s</span> · %s</a></p></div>',
        card, href, title, href, esc(M.formatScore(d.score)),
        esc(table.concat(bits, " · ")))
end

local Listing = {}
Listing.__index = Listing

--- deps: api (required), subreddit (nil = front page), sort, limit, now
function M.new(deps)
    local query = deps.query
    if query == "" then query = nil end
    return setmetatable({
        api = assert(deps.api, "api required"),
        subreddit = deps.subreddit,
        query = query,
        sort = deps.sort or (query and M.DEFAULT_SEARCH_SORT or M.DEFAULT_SORT),
        time = deps.time or M.DEFAULT_TIME,
        limit = deps.limit or M.PAGE_SIZE,
        anonymous = deps.anonymous or nil,
        now = deps.now or os.time,
        posts = {},
        cursor = nil,
        exhausted = false,
        error = nil,
    }, Listing)
end

function Listing:isSearch()
    return self.query ~= nil
end

function Listing:path()
    local sub = (self.subreddit and self.subreddit ~= "") and self.subreddit or nil
    if self:isSearch() then
        return sub and ("/r/" .. sub .. "/search") or "/search"
    end
    if sub then return "/r/" .. sub .. "/" .. self.sort end
    return "/" .. self.sort
end

--- Everything but `after`, which loadMore adds: the time window only rides along
--- for the sorts that accept one, and search needs a different set entirely.
function Listing:params()
    local q = { limit = self.limit }
    if self:isSearch() then
        q.q = self.query
        q.sort = self.sort
        q.type = "link"          -- posts, not subreddits or users
        q.raw_json = 1
        if self.subreddit and self.subreddit ~= "" then q.restrict_sr = 1 end
        if M.TIMED[self.sort] or self.sort == "top" then q.t = self.time end
    elseif M.TIMED[self.sort] then
        q.t = self.time
    end
    return q
end

function Listing:title()
    if self:isSearch() then
        local where = (self.subreddit and self.subreddit ~= "") and ("r/" .. self.subreddit)
            or "all"
        return string.format("%s  ·  “%s”", where, self.query)
    end
    -- `anonymous` is set by the caller: /hot with no subreddit is the reader's
    -- own front page when signed in and Reddit's default set when not.
    local where = (self.subreddit and self.subreddit ~= "") and ("r/" .. self.subreddit)
        or (self.anonymous and "Popular" or "Front page")
    local sort = self.sort
    if M.TIMED[sort] then sort = sort .. " · " .. self.time end
    return where .. "  ·  " .. sort
end

--- Replace everything and fetch page one. Returns ok, err.
function Listing:reload()
    self.posts, self.cursor, self.exhausted, self.error = {}, nil, false, nil
    return self:loadMore()
end

--- Fetch the next page and append. Returns ok, err.
function Listing:loadMore()
    if self.exhausted then return true end
    local query = self:params()
    if self.cursor then query.after = self.cursor end

    local res, code, err = self.api:get(self:path(), query)
    if not res then
        self.error = err or ("HTTP " .. tostring(code))
        return false, self.error
    end
    if type(res.data) ~= "table" or type(res.data.children) ~= "table" then
        self.error = "unexpected response shape"
        return false, self.error
    end

    local added = 0
    for _, child in ipairs(res.data.children) do
        if child.kind == "t3" then
            self.posts[#self.posts + 1] = child
            added = added + 1
        end
    end

    self.cursor = Api.nextCursor(res)
    -- No cursor, or a page that added nothing, means there is no more to fetch.
    if not self.cursor or added == 0 then self.exhausted = true end
    self.error = nil
    return true
end

--- Rows for the whole loaded set, in Menu item shape.
function Listing:rows()
    local now = self.now()
    local rows = {}
    for i, child in ipairs(self.posts) do
        rows[i] = M.rowFor(child, now)
    end
    return rows
end

function Listing:isEmpty()
    return #self.posts == 0
end

--- The whole loaded page as one document body (no stylesheet, no wrapper).
function Listing:bodyHtml()
    local now = self.now()
    local out = {}
    for i, child in ipairs(self.posts) do
        out[i] = M.htmlFor(child, now, i)
    end
    if #out == 0 then
        out[1] = '<p class="meta">' .. (self:isSearch() and "Nothing found." or "Nothing here.") .. "</p>"
    end
    return table.concat(out, "\n")
end

--- Plain text, for builds whose TextViewer cannot render HTML.
function Listing:bodyText()
    local now = self.now()
    local out = {}
    for i, child in ipairs(self.posts) do
        local row = M.rowFor(child, now)
        out[i] = string.format("%d. %s", i, row.text)
    end
    if #out == 0 then out[1] = self:isSearch() and "Nothing found." or "Nothing here." end
    return table.concat(out, "\n\n")
end

--- The post behind a tapped link, if it is still on the page.
function Listing:postAt(index)
    local child = self.posts[index]
    return child and child.data or nil
end

function Listing:setSort(sort, time)
    self.sort = sort
    if time then self.time = time end
    return self:reload()
end

function Listing:setTime(time)
    self.time = time
    return self:reload()
end

M.Listing = Listing
return M
