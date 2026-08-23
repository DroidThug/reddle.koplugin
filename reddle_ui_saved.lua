--[[
Saved posts, on screen (DESIGN.md §6).

Three jobs: offering to save what is currently open, listing what has been saved,
and reopening a saved post without touching the network.

**API-call discipline**, which is the whole reason this is worth doing on a device
with a slow radio:

  * Saving from an open thread costs **zero** calls. The post and its comment
    rows are already in memory; they are written straight to disk.
  * Saving from a listing has only the summary, so it saves that and marks the
    comments missing rather than fetching them behind the reader's back.
  * Images are fetched only when explicitly asked for, one call each.
  * "Fetch missing" wraps a single connectivity window around the whole batch,
    rather than waking the radio once per item.
--]]

local Archive = require("reddle_archive")
local ButtonDialog = require("ui/widget/buttondialog")
local Comments = require("reddle_comments")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Listing = require("reddle_listing")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local UiListing = require("reddle_ui_listing")
local _ = require("reddle_gettext")
local T = require("ffi/util").template

local M = {}

--- Offer to save what is on screen. `rows` is nil when called from a listing,
--- where the comments have not been fetched and will not be fetched for this.
function M.saveDialog(opts)
    local store, post, rows = opts.store, opts.post, opts.rows
    local image_url = opts.image_url
    local saved = store:isSaved(post.id)

    local function finish(ok, err, with_image)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not save: %1"), tostring(err)), timeout = 6 })
            return
        end
        if with_image and image_url then
            M.fetchImage(store, post.id, image_url, opts.transport, function()
                UIManager:show(InfoMessage:new{ text = _("Saved with image.") })
            end)
        else
            UIManager:show(InfoMessage:new{ text = _("Saved.") })
        end
        if opts.on_change then opts.on_change() end
    end

    local buttons = {}
    -- What gets written is what is in memory, stubs and all. A thread arrives
    -- capped at depth 5 / 200 comments, so on a big post this is a slice.
    local pending = rows and Comments.pendingRequests(rows) or 0
    -- Settings and about > Offline save limit. Zero is a deliberate choice, not
    -- a missing value: it means never spend calls on saving.
    local budget = M.budget(opts)

    -- Completing the thread leads when there is something to complete: this is
    -- the only moment the reader is online, and an archive that stops halfway
    -- fails at exactly the point where it cannot be repaired.
    if pending > 0 and opts.api and budget > 0 then
        buttons[#buttons + 1] = { {
            text = pending <= budget
                and T(_("Post and all comments (~%1 requests)"), tostring(pending))
                or T(_("Post and more comments (%1 of ~%2 requests)"),
                     tostring(budget), tostring(pending)),
            callback = function()
                UIManager:close(M.dialog)
                M.saveComplete(opts, finish)
            end,
        } }
    end

    -- Instant, offline, and the common case.
    buttons[#buttons + 1] = { {
        text = _("Post only"),
        callback = function()
            UIManager:close(M.dialog)
            finish(store:save(post, nil, { image_url = image_url }))
        end,
    } }
    if rows and #rows > 0 then
        buttons[#buttons + 1] = { {
            text = pending > 0
                and T(_("Post and comments (%1 loaded)"), tostring(#rows))
                or T(_("Post and comments (%1)"), tostring(#rows)),
            callback = function()
                UIManager:close(M.dialog)
                finish(store:save(post, rows, { image_url = image_url }))
            end,
        } }
    end
    if image_url then
        buttons[#buttons + 1] = { {
            text = (rows and #rows > 0) and _("Post, comments and image")
                or _("Post and image"),
            callback = function()
                UIManager:close(M.dialog)
                local ok, err = store:save(post, rows, { image_url = image_url })
                finish(ok, err, true)
            end,
        } }
    end
    if saved then
        buttons[#buttons + 1] = { {
            text = _("Remove from saved"),
            callback = function()
                UIManager:close(M.dialog)
                store:delete(post.subreddit, post.id)
                UIManager:show(InfoMessage:new{ text = _("Removed.") })
                if opts.on_change then opts.on_change() end
            end,
        } }
    end
    buttons[#buttons + 1] = { { text = _("Cancel"),
        callback = function() UIManager:close(M.dialog) end } }

    local title = saved and _("Already saved — save again?") or _("Save for offline")
    if pending > 0 then
        title = title .. "\n" .. _("Only part of the thread is loaded.")
    end
    M.dialog = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(M.dialog)
end

--- How many requests one save may spend. Absent means the caller did not thread
--- the setting through, which must not silently mean "none".
function M.budget(opts)
    local n = tonumber(opts and opts.save_expand_max)
    if n and n >= 0 then return math.floor(n) end
    return Comments.MAX_EXPANDS_SAVE
end

--- Fetch the outstanding branches, then save the whole thread.
---
--- `rows` is mutated in place, so the screen behind the dialog shows the fuller
--- thread afterwards rather than silently disagreeing with what is on disk.
--- Bounded: if the ceiling is reached the record is written anyway, marked with
--- what is still outstanding, and "Fetch missing" can finish it later.
function M.saveComplete(opts, finish)
    local store, post, rows = opts.store, opts.post, opts.rows
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Fetching the rest of the thread…") }
        UIManager:show(info)
        UIManager:forceRePaint()

        local _expanded, remaining = Comments.expandBranches(
            opts.api, "t3_" .. tostring(post.id), rows, { max = M.budget(opts) })
        UIManager:close(info)

        local ok, err = store:save(post, rows, { image_url = opts.image_url })
        if ok and remaining > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Saved, but %1 more requests would be needed to finish.\nUse “Fetch missing” on the Saved screen."),
                    tostring(remaining)),
                timeout = 8 })
            if opts.on_change then opts.on_change() end
            return
        end
        finish(ok, err)
    end)
end

--- Injectable so the specs never read a real file.
M.readFile = function(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return body
end

--- One image, one call -- or none, if the reader has already looked at it.
---
--- Viewing an image writes it to cache/reddle (reddle_ui_post). Saving used to
--- download the same bytes again, which on a slow radio is the difference
--- between a save that is instant and one that waits.
function M.fetchImage(store, id, url, transport, done)
    local cached = require("reddle_ui_post").cachedFile(url)
    if cached then
        local body = M.readFile(cached)
        if body and #body > 0 then
            local ok = store:saveImage(id, url, body)
            if ok then
                if done then done() end
                return
            end
        end
    end
    if not transport then return end
    NetworkMgr:runWhenOnline(function()
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
        local ok, err = store:saveImage(id, url, body)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not store the image: %1"), tostring(err)), timeout = 5 })
            return
        end
        if done then done() end
    end)
end

--- The Saved screen. `subreddit` nil means everything.
function M.openList(opts)
    local store = opts.store
    local children = store:children(opts.subreddit)
    local title = opts.subreddit and T(_("Saved · r/%1"), opts.subreddit) or _("Saved")
    local view = {
        listing = Archive.savedListing(children, title),
        links = opts.links,
        read = opts.read,
        on_select = function(summary) M.openSaved(opts, summary) end,
        -- Long-press a card to act on it without opening it. Deleting is the
        -- one thing you want from a list rather than from inside a post, and a
        -- hold is the only spare gesture here -- tap already opens, and a
        -- per-card Remove button would put a control on every row of a screen
        -- whose whole job is to be readable.
        on_hold = function(summary) M.postActions(opts, view, summary) end,
    }
    view.buttons_table = { { {
        text = _("Fetch missing"),
        callback = function() M.fetchMissing(opts, view) end,
    } } }
    UiListing.render(view)
    return view
end

--- What a long-press on a saved card offers.
function M.postActions(opts, view, summary)
    local dialog
    local missing = Archive.describeMissing(summary)
    local buttons = { { {
        text = _("Open"),
        callback = function() UIManager:close(dialog); M.openSaved(opts, summary) end,
    } } }
    if missing then
        buttons[#buttons + 1] = { {
            text = T(_("Fetch %1"), missing),
            callback = function()
                UIManager:close(dialog)
                M.fetchOne(opts, view, summary)
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Remove from saved"),
        callback = function()
            UIManager:close(dialog)
            M.confirmRemove(opts, view, summary)
        end,
    } }
    buttons[#buttons + 1] = { { text = _("Cancel"),
        callback = function() UIManager:close(dialog) end } }

    dialog = ButtonDialog:new{
        title = Listing.oneLine(summary.title or _("Saved post")),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Deleting is irreversible and re-fetching needs the network, so it asks --
--- but only once, and the prompt names the post rather than saying "this item".
function M.confirmRemove(opts, view, summary)
    UIManager:show(ConfirmBox:new{
        text = T(_("Remove “%1” from saved?\n\nThe copy on this device is deleted."),
            Listing.oneLine(summary.title or "")),
        ok_text = _("Remove"),
        ok_callback = function()
            opts.store:delete(summary.subreddit, summary.id)
            UIManager:show(InfoMessage:new{ text = _("Removed."), timeout = 2 })
            -- No view when this is invoked from the post screen itself: that
            -- screen closes, and there is no list behind it to repaint.
            if view then M.reload(opts, view) end
        end,
    })
end

--- Reopen a saved post from disk. Deliberately does not go through
--- reddle_ui_thread.load: that is the network path, and the point of a saved
--- post is that it opens with the radio off.
function M.openSaved(opts, summary)
    local Thread = require("reddle_ui_thread")
    local store = opts.store
    local record = store:load(summary.subreddit, summary.id)
    if not record then
        UIManager:show(InfoMessage:new{
            text = _("That saved post could not be read."), timeout = 5 })
        return
    end
    local post = Archive.postOf(record) or summary
    local rows = record.comments or {}
    -- Ages were formatted when the record was written; recompute or every
    -- comment in a month-old archive still claims to be two hours old.
    Comments.reage(rows)

    local view = {
        post = post,
        rows = rows,
        subreddit = post.subreddit,
        age = Listing.formatAge(post.created_utc),
        collapsed = {},
        api = opts.api,
        transport = opts.transport,
        links = opts.links,
        image_opts = opts.image_opts,
        offline = true,
        store = store,
        image_file = store:imageFile(post.id, summary.image_url or record.image
            and record.image.url),
        image_url = summary.image_url or (record.image and record.image.url),
        on_change = opts.on_change,
    }
    Thread.render(view)
    return view
end

--- Fetch whatever one saved post is missing. Assumes it is already online --
--- callers own the connectivity window, so a batch does not open one per item.
--- Returns true if anything was filled in.
function M.fillOne(opts, summary)
    local store = opts.store
    local did = false
    for _j, what in ipairs(Archive.missing(summary)) do
        if what == "comments" then
            -- /comments/<id> resolves without the subreddit, so a record saved
            -- from a link with no subreddit still fills in.
            local path = (summary.subreddit and summary.subreddit ~= "")
                and string.format("/r/%s/comments/%s", summary.subreddit, summary.id)
                or string.format("/comments/%s", summary.id)
            local res = opts.api:get(path, { depth = Comments.MAX_DEPTH + 1, limit = 200 })
            if res then
                local rows = Comments.parse(res)
                -- That response is capped the same way the original save was, so
                -- fetching it again on its own would reproduce the same slice.
                Comments.expandBranches(opts.api, "t3_" .. tostring(summary.id), rows,
                    { max = M.budget(opts) })
                if store:addComments(summary.subreddit, summary.id, rows) then did = true end
            end
        elseif what == "more comments" then
            -- Already have part of the thread: expand what is on disk rather
            -- than re-requesting the whole listing.
            local record = store:load(summary.subreddit, summary.id)
            local rows = record and record.comments
            if rows then
                local expanded = Comments.expandBranches(
                    opts.api, "t3_" .. tostring(summary.id), rows,
                    { max = M.budget(opts) })
                if expanded > 0
                    and store:addComments(summary.subreddit, summary.id, rows) then
                    did = true
                end
            end
        elseif what == "image" and summary.image_url then
            local body, code = opts.transport{ url = summary.image_url, timeouts = "file",
                headers = require("reddle_api").fileHeaders() }
            if code == 200 and body and #body > 0 then
                if store:saveImage(summary.id, summary.image_url, body) then did = true end
            end
        end
    end
    return did
end

--- One post, from the long-press menu.
function M.fetchOne(opts, view, summary)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Fetching…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local did = M.fillOne(opts, summary)
        UIManager:close(info)
        UIManager:show(InfoMessage:new{
            text = did and _("Fetched.") or _("Could not fetch that."), timeout = 4 })
        M.reload(opts, view)
    end)
end

--- Fill in what the archive is missing, in one connectivity window rather than
--- one per post.
function M.fetchMissing(opts, view)
    local store = opts.store
    local todo = {}
    for _i, child in ipairs(view.listing.posts) do
        local summary = child.data
        if #Archive.missing(summary) > 0 then todo[#todo + 1] = summary end
    end
    if #todo == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nothing missing."), timeout = 3 })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{
            text = T(_("Fetching %1 saved post(s)…"), tostring(#todo)) }
        UIManager:show(info)
        UIManager:forceRePaint()

        local filled, failed = 0, 0
        for _i, summary in ipairs(todo) do
            if M.fillOne(opts, summary) then filled = filled + 1 else failed = failed + 1 end
        end

        UIManager:close(info)
        UIManager:show(InfoMessage:new{
            text = failed == 0
                and T(_("Filled in %1 saved post(s)."), tostring(filled))
                or T(_("Filled in %1; %2 could not be fetched."),
                    tostring(filled), tostring(failed)),
            timeout = 6,
        })
        -- Repaint so the "no comments" notes disappear from the rows that now
        -- have them.
        M.reload(opts, view)
    end)
end

function M.reload(opts, view)
    view.listing = Archive.savedListing(opts.store:children(opts.subreddit),
        view.listing:title())
    UiListing.render(view)
end

return M
