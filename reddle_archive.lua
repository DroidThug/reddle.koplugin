--[[
Saved posts — the offline archive (DESIGN.md §6).

Pure model: paths, record shape, and the index. The caller passes the filesystem
adapter (reddle_store.lua), so all of this runs under plain LuaJIT.

    index.json                     every saved post, listing fields only
    posts/<subreddit>/<id>.json    the record: post, comments, metadata
    images/<id>.<ext>              saved images

Two constraints:

  * Timestamps are persisted, never formatted ages. reddle_comments.parse bakes
    "2h" into each row, so records store created_utc and re-age on open.
  * The index is separate from the records, and holds only what a listing row
    needs -- opening the Saved menu must not read every record.
  * Images go here rather than cache/reddle, which is trimmed to a byte budget
    oldest-first (reddle_ui_post). An archive whose pictures evict is not an
    archive.
--]]

local M = {}

M.VERSION = 1
M.INDEX = "index.json"

--- Reddit ids are [a-z0-9]+ and subreddits [A-Za-z0-9_]+, but a record's path is
--- built from data the API gave us, so treat both as untrusted: anything that
--- could climb out of the archive root is replaced rather than rejected, so a
--- weird subreddit name cannot make a post unsaveable.
function M.safeName(s)
    s = tostring(s or "")
    s = s:gsub("[^%w%-_]", "_")
    if s == "" then s = "_" end
    return s:sub(1, 64)
end

function M.postPath(root, subreddit, id)
    return string.format("%s/posts/%s/%s.json", root, M.safeName(subreddit), M.safeName(id))
end

function M.indexPath(root)
    return root .. "/" .. M.INDEX
end

--- Keep the extension so ImageViewer can tell a PNG from a JPEG; fall back to
--- .jpg rather than nothing, since a file with no extension may not open.
function M.imagePath(root, id, url)
    local ext = tostring(url or ""):match("%.(%a%a%a?%a?)$")
    ext = (ext and #ext <= 4) and ext:lower() or "jpg"
    return string.format("%s/images/%s.%s", root, M.safeName(id), ext)
end

--- The listing-shaped summary held in the index. Deliberately small: this is
--- read in full every time the Saved menu opens.
function M.summaryOf(post, opts)
    opts = opts or {}
    return {
        id = post.id,
        subreddit = post.subreddit,
        title = post.title,
        author = post.author,
        score = tonumber(post.score),
        num_comments = tonumber(post.num_comments),
        created_utc = tonumber(post.created_utc),
        saved_at = opts.saved_at,
        domain = post.domain,
        over_18 = post.over_18 and true or nil,
        is_self = post.is_self and true or nil,
        has_comments = opts.has_comments and true or false,
        -- Unexpanded `more` branches at save time. Without this a thread saved
        -- as a slice looks complete: has_comments is true, so nothing reports it
        -- missing and nothing can repair it -- and the reader finds out offline,
        -- where they can do least about it.
        pending = (opts.pending or 0) > 0 and opts.pending or nil,
        has_image = opts.has_image and true or false,
        image_url = opts.image_url,
    }
end

--- Branches Reddit has not sent yet. A `more` row with no children left is a
--- stub that has already been expanded away, and is not a gap.
function M.pendingBranches(rows)
    local n = 0
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if row.kind == "more" and #(row.children or {}) > 0 then n = n + 1 end
    end
    return n
end

--- A full record. `rows` may be nil (saved without comments) and is stored as
--- given -- reddle_comments rows already carry created_utc, which is what makes
--- re-aging possible.
---
--- `link_fullname` is not decoration: expanding a `more` stub later needs it
--- (Comments.moreChildrenBody), and a saved thread is full of unexpanded stubs.
function M.record(post, rows, opts)
    opts = opts or {}
    return {
        version = M.VERSION,
        saved_at = opts.saved_at,
        link_fullname = post.id and ("t3_" .. post.id) or nil,
        -- Wrapped so reddle_listing.htmlFor(child, ...) renders a saved listing
        -- through exactly the same path as a live one.
        post = { kind = "t3", data = post },
        comments = rows,
        image = opts.image_url and { url = opts.image_url, file = opts.image_file } or nil,
    }
end

--- The post table back out of a record, tolerating both shapes so a record
--- written by an older version still opens.
function M.postOf(record)
    if type(record) ~= "table" then return nil end
    if type(record.post) == "table" then
        return record.post.data or record.post
    end
    return nil
end

--- Index helpers. The index is a plain array so its order is the saved order;
--- newest-first is applied at render time.
function M.upsert(index, summary)
    index = type(index) == "table" and index or {}
    for i, row in ipairs(index) do
        if row.id == summary.id then
            index[i] = summary
            return index
        end
    end
    index[#index + 1] = summary
    return index
end

function M.remove(index, id)
    index = type(index) == "table" and index or {}
    for i, row in ipairs(index) do
        if row.id == id then
            table.remove(index, i)
            return index
        end
    end
    return index
end

function M.find(index, id)
    for _, row in ipairs(type(index) == "table" and index or {}) do
        if row.id == id then return row end
    end
    return nil
end

function M.isSaved(index, id)
    return M.find(index, id) ~= nil
end

--- Subreddits present, with counts, for the Saved submenu. Sorted so the menu
--- does not reshuffle between openings.
function M.subreddits(index)
    local counts, names = {}, {}
    for _, row in ipairs(type(index) == "table" and index or {}) do
        local name = row.subreddit or "?"
        if not counts[name] then names[#names + 1] = name end
        counts[name] = (counts[name] or 0) + 1
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    local out = {}
    for i, name in ipairs(names) do out[i] = { subreddit = name, count = counts[name] } end
    return out
end

--- Newest save first, optionally limited to one subreddit. Returns listing-shaped
--- children so the saved screens can reuse reddle_listing's renderer unchanged.
function M.children(index, subreddit)
    local rows = {}
    for _, row in ipairs(type(index) == "table" and index or {}) do
        if not subreddit or row.subreddit == subreddit then rows[#rows + 1] = row end
    end
    table.sort(rows, function(a, b)
        return (a.saved_at or 0) > (b.saved_at or 0)
    end)
    local out = {}
    for i, row in ipairs(rows) do
        out[i] = { kind = "t3", data = row }
    end
    return out
end

--- What a saved post is still missing, for the "fetch later" affordance.
function M.missing(summary)
    if type(summary) ~= "table" then return {} end
    local out = {}
    if not summary.has_comments and (summary.num_comments or 0) > 0 then
        out[#out + 1] = "comments"
    elseif (summary.pending or 0) > 0 then
        -- Saved, but only part of the thread.
        out[#out + 1] = "more comments"
    end
    if summary.image_url and not summary.has_image then out[#out + 1] = "image" end
    return out
end

function M.describeMissing(summary)
    local missing = M.missing(summary)
    if #missing == 0 then return nil end
    return table.concat(missing, " and ")
end

--- A saved set dressed up as the object reddle_ui_listing renders.
---
--- The live listing screen only ever asks a Listing for five things, so meeting
--- that interface gets the saved screens the same cards, tap targets, emoji
--- handling and byline layout for free -- which is the whole requirement that
--- saved posts look like online ones. `exhausted` is true because there is no
--- next page to fetch: this is everything, at once.
function M.savedListing(children, title)
    local Listing = require("reddle_listing")
    local now = os.time()
    for _, child in ipairs(children) do
        -- Marked here rather than at save time so the note tracks the record's
        -- current state after a later fetch fills it in.
        --
        -- "not saved", not "no": the byline next to it already says how many
        -- comments the post has, so a note reading "no comments" on a post with
        -- 47 of them contradicts the line above it.
        local missing = M.describeMissing(child.data)
        child.data.reddle_note = missing and (missing .. " not saved") or nil
    end
    return {
        exhausted = true,
        saved = true,
        posts = children,
        title = function() return title end,
        isEmpty = function() return #children == 0 end,
        postAt = function(_, i) return children[i] and children[i].data or nil end,
        bodyHtml = function()
            if #children == 0 then
                return '<p class="meta">' .. "Nothing saved yet." .. "</p>"
            end
            local out = {}
            for i, child in ipairs(children) do
                out[i] = Listing.htmlFor(child, now, i)
            end
            return table.concat(out, "\n")
        end,
        bodyText = function()
            if #children == 0 then return "Nothing saved yet." end
            local out = {}
            for i, child in ipairs(children) do
                out[i] = string.format("%d. %s", i, Listing.rowFor(child, now).text)
            end
            return table.concat(out, "\n\n")
        end,
    }
end

return M
