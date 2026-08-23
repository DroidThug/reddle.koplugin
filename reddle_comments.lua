--[[
Comment-tree view-model (DESIGN.md §5.2).

Reddit hands back a tree whose last child is often a `more` stub holding IDs
rather than content. It is flattened once, here, into a depth-tagged list:

    { kind = "comment" | "more" | "continue", depth = N, ... }

Indentation is capped at MAX_DEPTH; deeper replies become a "continue thread"
row rather than being squeezed into a few columns.
--]]

local Html = require("reddle_html")
local Markdown = require("reddle_markdown")

local M = {}

M.MAX_DEPTH = 4          -- §5.2: cap indentation, don't squeeze text
M.INDENT = "  "
M.PREVIEW_LINES = 4

local function ageOf(created_utc, now)
    local Listing = require("reddle_listing")
    return Listing.formatAge(created_utc, now)
end

--- Walk one Listing's children, appending rows. Recursive over `replies`.
local function walk(children, depth, out, now, opts)
    if type(children) ~= "table" then return end
    for _, child in ipairs(children) do
        local d = child.data or {}
        if child.kind == "t1" then
            if depth > opts.max_depth then
                -- Everything below the cap becomes one row, not a squeezed column.
                out[#out + 1] = {
                    kind = "continue",
                    depth = opts.max_depth,
                    id = d.id,
                    fullname = d.id and ("t1_" .. d.id) or nil,
                }
                return
            end
            out[#out + 1] = {
                kind = "comment",
                depth = depth,
                id = d.id,
                fullname = d.id and ("t1_" .. d.id) or nil,
                author = d.author or "[deleted]",
                score = tonumber(d.score),
                -- Both: `age` is what renders, `created_utc` is what survives
                -- being written to disk. A saved thread re-derives its ages on
                -- open (reddle_archive), or every comment in it would still
                -- claim to be "2h" old a month later.
                created_utc = tonumber(d.created_utc),
                age = ageOf(d.created_utc, now),
                -- plain text for the collapsed Menu row, HTML for the full view
                body = Html.hasMarkup(d.body_html) and Html.toText(d.body_html)
                    or Markdown.toText(d.body or ""),
                body_html = d.body_html,
            }
            local replies = d.replies
            if type(replies) == "table" and type(replies.data) == "table" then
                walk(replies.data.children, depth + 1, out, now, opts)
            end
        elseif child.kind == "more" then
            local count = tonumber(d.count) or 0
            -- Reddit uses a zero-count "more" with id t1__ for continue-thread links
            out[#out + 1] = {
                kind = "more",
                depth = math.min(depth, opts.max_depth),
                id = d.id,
                count = count,
                children = d.children or {},
            }
        end
    end
end

--- The /r/x/comments/y response is [post_listing, comment_listing].
-- Returns rows, post
function M.parse(response, opts)
    opts = opts or {}
    opts.max_depth = opts.max_depth or M.MAX_DEPTH
    local now = opts.now or os.time()

    if type(response) ~= "table" then return {}, nil end
    local post_listing, comment_listing = response[1], response[2]
    local post
    if type(post_listing) == "table" and type(post_listing.data) == "table"
            and type(post_listing.data.children) == "table"
            and post_listing.data.children[1] then
        post = post_listing.data.children[1].data
    end

    local rows = {}
    if type(comment_listing) == "table" and type(comment_listing.data) == "table" then
        walk(comment_listing.data.children, 0, rows, now, opts)
    end
    return rows, post
end

--- The two-line Menu label for a row: byline, then the body preview.
--- Recompute every row's displayed age from its stored timestamp. Used when a
--- thread comes off disk rather than off the wire: `age` was formatted at save
--- time and is stale by definition.
function M.reage(rows, now)
    if type(rows) ~= "table" then return rows end
    for _, row in ipairs(rows) do
        if row.created_utc then row.age = ageOf(row.created_utc, now) end
    end
    return rows
end

function M.rowText(row, preview_lines)
    local indent = M.INDENT:rep(row.depth or 0)
    if row.kind == "more" then
        local n = row.count or 0
        return indent .. (n > 0
            and string.format("↳ %d more repl%s", n, n == 1 and "y" or "ies")
            or "↳ continue thread")
    end
    if row.kind == "continue" then
        return indent .. "↳ continue thread"
    end

    local score = row.score and tostring(row.score) or "?"
    local byline = string.format("%su/%s · %s · %s", indent, row.author, score, row.age or "")
    -- One line only: MenuItem strips newlines (see reddle_listing.rowFor). The body
    -- follows the byline; Menu wraps it across items_max_lines by width.
    local body = Markdown.preview(row.body, preview_lines or M.PREVIEW_LINES)
    body = body:gsub("%s*\n%s*", " ")
    return byline .. "  " .. body
end

--- Rows in KOReader Menu item shape.
function M.toItems(rows, preview_lines)
    local items = {}
    for i, row in ipairs(rows) do
        -- NB: `cond and nil or "›"` would always yield "›" -- nil is falsy in Lua.
        local mandatory
        if row.kind ~= "comment" then mandatory = "›" end
        items[i] = {
            text = M.rowText(row, preview_lines),
            row = row,
            mandatory = mandatory,
        }
    end
    return items
end

--- Indentation for the document view. Menu could not express threading at all
--- (one line per item, no indent control); a document can, via margins.
M.INDENT_EM = 1.1

--- The indent, as an inline `style` value.
---
--- Belt and braces, and deliberately so. A class-based stylesheet is the clean
--- way to do this, but our <style> now rides inside the <body> MuPDF builds for
--- us (see reddle_html), and whether MuPDF collects a stylesheet from there is
--- not verifiable from this machine. An inline `style` attribute needs no
--- cascade at all. So threading -- the thing that was actually broken on the
--- device -- is set both ways, and survives either answer.
function M.indentStyle(depth)
    if not depth or depth <= 0 then return "" end
    return string.format("margin-left: %.1fem; border-left: 1px solid #999; padding-left: 0.4em;",
        depth * M.INDENT_EM)
end

--- Verified on hardware 2026-08-16: font-size and color in a passed stylesheet
--- both render, so the byline can recede instead of competing with the comment.
--- Grey on e-ink is genuinely lighter, not dithered mush, at this size.
function M.documentCss(max_depth)
    local css = {
        ".by { margin: 0.7em 0 0.15em 0; }",
        -- The byline is an anchor (it folds the comment) but must not read as a
        -- link: a thread of underlined blue-grey bylines would be unreadable, and
        -- every one of them is a link, so the cue carries no information.
        ".by a { text-decoration: none; color: #000000; }",
        -- Grey, so it reads as chrome rather than as part of the byline.
        ".fold { color: #666666; }",
        -- .meta itself lives in Html.CSS: the post header wants the same treatment.
        ".stub { font-style: italic; font-size: 0.85em; color: #666666; margin: 0.3em 0; }",
        -- Darker than the row around it and underlined: a stub is a tap target,
        -- and the only cue e-ink gives us for that is weight.
        ".stub a { color: #333333; text-decoration: underline; }",
        -- The gap between sibling comments has to beat the gap between paragraphs
        -- *within* one, or a long comment reads as several.
        ".c { margin-bottom: 0.7em; }",
        ".c p { margin: 0 0 0.35em 0; }",
    }
    for d = 0, (max_depth or M.MAX_DEPTH) do
        if d == 0 then
            -- A hairline above each top-level comment separates conversations
            -- without boxing every reply, which nested would be far too much ink.
            css[#css + 1] = ".d0 { margin-left: 0; border-top: 1px solid #999999; " ..
                "padding-top: 0.5em; }"
        else
            css[#css + 1] = string.format(
                ".d%d { margin-left: %.1fem; border-left: 1px solid #999999; " ..
                "padding-left: 0.4em; }", d, d * M.INDENT_EM)
        end
    end
    return table.concat(css, "\n")
end

--- The full sheet for the thread view, to be handed to the widget rather than
--- embedded in the body -- which is where MuPDF ignores it (§5.2.2).
function M.css()
    local Html = require("reddle_html")
    return Html.CSS .. M.documentCss()
end

local function esc(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- The whole thread as one HTML document: full comment bodies, real indentation,
--- and the reader gets TextViewer's own font-size control for free.
function M.toHtml(rows, opts)
    return require("reddle_html").rawDocument(M.bodyHtml(rows, opts), M.documentCss())
end

--- How many rows a collapsed comment hides: itself excluded, everything nested
--- under it included, stubs and all.
function M.subtreeSize(rows, index)
    local depth = rows[index] and rows[index].depth or 0
    local n = 0
    for i = index + 1, #rows do
        if (rows[i].depth or 0) <= depth then break end
        n = n + 1
    end
    return n
end

--- Just the comment markup, with no stylesheet and no wrapper, so the thread view
--- can put a post above it in the same document (§5.6).
---
--- opts.collapsed is a set of comment ids the reader has folded. A folded comment
--- keeps its byline -- that is the thing you tap to unfold it -- and swallows its
--- whole subtree. Keyed by id rather than by position because expanding a stub
--- somewhere else in the thread renumbers every row after it.
function M.bodyHtml(rows, opts)
    opts = opts or {}
    local collapsed = opts.collapsed or {}
    local Html = require("reddle_html")
    local out = {}
    if opts.header then out[#out + 1] = opts.header end
    local Links = require("reddle_links")
    local i, n = 1, #rows
    while i <= n do
        local row = rows[i]
        local d = math.min(row.depth or 0, M.MAX_DEPTH)
        if row.kind == "comment" then
            local folded = row.id ~= nil and collapsed[row.id] == true
            local hidden = folded and M.subtreeSize(rows, i) or 0
            local body = ""
            if not folded then
                body = Html.hasMarkup(row.body_html) and Html.sanitize(row.body_html)
                    or ("<p>" .. esc(row.body):gsub("\n", "<br/>") .. "</p>")
            end

            -- The whole byline is the fold control: it spans the comment's
            -- width, which is the widest tap target a thread has when the
            -- competing gesture is "turn the page". The triangle is the only cue
            -- -- underlining every byline would carry no information, since they
            -- are all links -- and it doubles as the open/closed state.
            local marker = folded and "▸ " or "▾ "
            local by = string.format(
                '<span class="fold">%s</span><b>u/%s</b><span class="meta"> · %s · %s%s</span>',
                marker, esc(row.author), esc(row.score or "?"), esc(row.age or ""),
                folded and ("  +" .. tostring(hidden + 1)) or "")
            if row.id then
                by = '<a href="' .. Links.href("collapse", row.id) .. '">' .. by .. "</a>"
            end

            -- <b>/<i> rather than a class for the same reason as the inline
            -- indent: literal tags are the only styling MuPDF definitely honoured
            -- on the device.
            out[#out + 1] = string.format(
                '<div class="c d%d" style="%s"><p class="by">%s</p>%s</div>',
                d, M.indentStyle(d), by, body)

            if folded then i = i + hidden end
        else
            -- A stub is the one row in the thread that is *only* an instruction,
            -- so it had better be the thing you tap. It used to read "use 'Load
            -- all replies'" -- pointing at a button, from text that looks exactly
            -- like something you would press.
            local href
            if row.kind == "more" and #(row.children or {}) > 0
                    and row.id and row.id ~= "" and row.id ~= "_" then
                -- By id, not by position. Expanding one stub splices its replies
                -- into `rows` in place of it, which shifts the index of every
                -- stub below -- so a position minted into one document can name a
                -- different branch in the next. Reddit always stamps a real
                -- `more` with an id; one without simply stays untappable rather
                -- than becoming a tap that opens the wrong thread.
                href = Links.href("more", row.id)
            else
                local target = M.continueTargetFor(rows, i)
                if target then href = Links.href("continue", target) end
            end
            local label = esc(M.stubLabel(row))
            out[#out + 1] = string.format(
                '<div class="c d%d" style="%s"><p class="stub">%s</p></div>',
                d, M.indentStyle(d),
                href and ('<a href="' .. href .. '">' .. label .. "</a>")
                    or ("<i>" .. label .. "</i>"))
        end
        i = i + 1
    end
    return table.concat(out, "\n")
end

--- Where a `more` stub is now, given the id it had when it was rendered.
--- Returns nil once it has been expanded away, which is the answer a second tap
--- on a stale document should get.
-- Reddit rejects oversized morechildren calls; keep each batch modest.
M.MORE_BATCH = 40
-- One tap on "Load all replies" should not fire twenty requests at a shared
-- rate limit. Saving for offline is allowed more, because the alternative is an
-- archive that stops halfway when the reader has no way to fetch the rest.
M.MAX_EXPANDS = 6
M.MAX_EXPANDS_SAVE = 25

--- Expand outstanding `more` branches in place, one request each.
---
--- `api` is injected, so this is testable without a network and is shared by the
--- three callers that need it: the "Load all replies" button, saving a thread
--- for offline, and repairing a partial record from the Saved screen.
---
--- opts: max (request ceiling), on_progress(done, total), now
--- Returns expanded, remaining -- `remaining` non-zero means the ceiling was hit
--- and the thread is still a slice.
function M.expandBranches(api, link_fullname, rows, opts)
    opts = opts or {}
    local max = opts.max or M.MAX_EXPANDS
    local total = M.pendingRequests(rows)
    local expanded = 0

    for _ = 1, max do
        local pending = M.pendingStubs(rows)
        if #pending == 0 then break end
        local stub = pending[1]
        local body, n = M.moreChildrenBody(link_fullname, stub.row, M.MORE_BATCH)
        if n == 0 then break end
        local res = api:get("/api/morechildren", {
            api_type = body.api_type, link_id = body.link_id, children = body.children,
        })
        local things = res and res.json and res.json.data and res.json.data.things
        -- Stop on the first failure rather than hammering a rate limit that has
        -- already said no.
        if not things then break end
        M.spliceMore(rows, stub.index, things, { now = opts.now, consumed = n })
        expanded = expanded + 1
        if opts.on_progress then opts.on_progress(expanded, total) end
    end

    return expanded, M.pendingRequests(rows)
end

function M.stubIndexById(rows, id)
    if not id then return nil end
    for i, r in ipairs(rows) do
        if r.kind == "more" and r.id == id then return i end
    end
    return nil
end

--- Which comment a "continue thread" row should re-root the view at.
---
--- Two shapes end up here. Our own depth-cap row knows the comment it stands in
--- for, so it carries the id. Reddit's zero-count `more` (id "_") does not: it
--- means "this branch continues" and the branch is whatever comment it is nested
--- under, so we look back for the nearest ancestor -- the closest preceding
--- comment shallower than the stub.
function M.continueTargetFor(rows, index)
    local row = rows[index]
    if not row then return nil end
    if row.id and row.id ~= "" and row.id ~= "_" then return row.id end
    local depth = row.depth or 0
    for i = index - 1, 1, -1 do
        local r = rows[i]
        if r.kind == "comment" and (r.depth or 0) < depth then return r.id end
    end
    return nil
end

--- Same thread as plain text, for KOReader builds that cannot render HTML.
function M.toPlainText(rows, opts)
    opts = opts or {}
    local out = {}
    if opts.header then out[#out + 1] = opts.header end
    for _, row in ipairs(rows) do
        local indent = M.INDENT:rep(math.min(row.depth or 0, M.MAX_DEPTH))
        if row.kind == "comment" then
            out[#out + 1] = string.format("%su/%s · %s · %s",
                indent, row.author, tostring(row.score or "?"), row.age or "")
            local body = tostring(row.body or "")
            out[#out + 1] = (body:gsub("([^\n]+)", indent .. "%1"))
            out[#out + 1] = ""
        else
            out[#out + 1] = indent .. M.stubLabel(row)
            out[#out + 1] = ""
        end
    end
    return table.concat(out, "\n")
end

function M.stubLabel(row)
    local n = row.count or 0
    if row.kind == "more" and n > 0 then
        return string.format("↳ %d more repl%s", n, n == 1 and "y" or "ies")
    end
    return "↳ continue thread"
end

--- Every `more` stub still in the list, for a bulk expand.
function M.pendingStubs(rows)
    local stubs = {}
    for i, r in ipairs(rows) do
        if r.kind == "more" and #(r.children or {}) > 0 then
            stubs[#stubs + 1] = { index = i, row = r }
        end
    end
    return stubs
end

--- Turn an /api/morechildren `things` array into rows and splice them in place of
--- the `more` row at `index`.
---
--- The subtlety: Comments.parse gives each thing's replies depths *relative* to
--- that thing (0, 1, 2...), while Reddit stamps each thing with its *absolute*
--- depth in the thread. Offsetting by the absolute depth is what keeps an
--- expanded branch indented; overwriting with it flattens the whole branch into
--- one column.
function M.spliceMore(rows, index, things, opts)
    opts = opts or {}
    local max_depth = opts.max_depth or M.MAX_DEPTH
    local fallback = rows[index] and rows[index].depth or 0

    local added = {}
    for _, thing in ipairs(things or {}) do
        local base = tonumber(thing.data and thing.data.depth) or fallback
        local parsed = M.parse({ {}, { data = { children = { thing } } } },
            { now = opts.now, max_depth = max_depth })
        for _, r in ipairs(parsed) do
            r.depth = math.min(base + r.depth, max_depth)
            added[#added + 1] = r
        end
    end

    -- Reddit caps how many children one morechildren call may name, so a large
    -- branch is consumed in batches. `opts.consumed` says how many of this
    -- stub's ids were actually asked for; the rest have to stay as a stub or
    -- they are dropped on the floor -- silently, since removing the stub also
    -- removes the only record that they exist.
    local stub = rows[index]
    local leftover
    if opts.consumed and stub and stub.kind == "more" then
        local rest = {}
        for i = opts.consumed + 1, #(stub.children or {}) do
            rest[#rest + 1] = stub.children[i]
        end
        if #rest > 0 then
            -- Reddit's `count` is hidden *comments*, not hidden ids: a branch of
            -- 40 ids can stand for hundreds of replies. Subtracting what was
            -- actually added keeps the "+N" on the stub roughly honest, and the
            -- id count is the floor, since each id is at least one comment.
            local left = math.max((stub.count or 0) - #added, #rest)
            leftover = { kind = "more", depth = stub.depth, id = stub.id,
                         count = left, children = rest }
        end
    end

    if rows[index] then table.remove(rows, index) end
    for i = #added, 1, -1 do table.insert(rows, index, added[i]) end
    if leftover then table.insert(rows, index + #added, leftover) end
    return #added
end

--- How many requests completing this thread would take, rather than how many
--- branches are outstanding. A branch of 300 is eight calls, not one, and the
--- number on the save button is a promise about what it is going to spend.
function M.pendingRequests(rows)
    local n = 0
    for _, stub in ipairs(M.pendingStubs(rows)) do
        n = n + math.ceil(#stub.row.children / M.MORE_BATCH)
    end
    return n
end

--- Query for an /api/morechildren call for a `more` row.
--- Reddit documents this as a POST but answers a GET too (verified live
--- 2026-08-15), which is why reddle_api only needs an authed GET. Keep batches
--- small so the URL stays sane.
function M.moreChildrenBody(link_fullname, row, limit)
    local ids = {}
    for i, id in ipairs(row.children or {}) do
        if limit and i > limit then break end
        ids[#ids + 1] = id
    end
    return {
        api_type = "json",
        link_id = link_fullname,
        children = table.concat(ids, ","),
    }, #ids
end

return M
