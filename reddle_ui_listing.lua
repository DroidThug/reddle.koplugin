--[[
The post list screen (DESIGN.md §5.1, §5.7).

Rewritten 2026-08-16. It was a KOReader Menu, and it hit the same wall the comment
view did: MenuItem is one line (menu.lua strips newlines unconditionally), so the
title and the byline had to share a line, which is what made the screen read as
noise. Menu also gives no control over weight or size, so there was no way to make
the byline recede.

So the listing is a document too: bold title on its own line, byline quiet
underneath, and the title is an anchor -- MuPDF hit-tests links against its own
boxes, so tapping one opens that post (§5.5).

What we give up, and what replaces it:
  - long-press to sort          -> a Sort button, which also carries the time
                                   window that `top` and `controversial` need
  - Menu's "items per page"     -> TextViewer's own font size setting
  - jump-to-first-new on paging -> setDocument keeps the reader's position while
                                   the list grows underneath them
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Html = require("reddle_html")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Listing = require("reddle_listing")
local NetworkMgr = require("ui/network/manager")
local RichText = require("reddle_ui_richtext")
local UIManager = require("ui/uimanager")
local _ = require("reddle_gettext")
local T = require("ffi/util").template

local M = {}

--- In line heights. The card is 0.4em padding + 1px border + 0.55em margin above
--- and below its text, so one full line either way covers the whole card and then
--- some -- which is safe, because pickLink takes the *nearest* link rather than
--- the first one in range.
M.TAP_SLOP = 1.0

function M.css()
    return Html.CSS .. Listing.LISTING_CSS
end

--- The Reddle entries in a screen's title-bar menu.
---
--- `links` is the router main.lua builds; a screen opened without one gets no
--- navigation rather than a menu full of dead buttons.
--- `on_search` is passed by a screen that already has a listing to search
--- within; without one this falls back to the router's global search, so the
--- entry is there from inside a thread too.
function M.navButtons(links, on_search)
    if type(links) ~= "table" then return {} end
    local rows = {}
    local function add(text, callback)
        if callback then rows[#rows + 1] = { { text = text, callback = callback } } end
    end
    add(_("Front page"), links.open_front)
    add(_("Go to subreddit…"), links.ask_subreddit)
    add(_("Search…"), on_search or links.search)
    add(_("Saved posts"), links.open_saved)
    return rows
end

--- api, subreddit, sort, time, on_select(post), on_sort(sort, time), on_hold(post)
function M.open(o)
    local view = {
        listing = Listing.new{ api = o.api, subreddit = o.subreddit, query = o.query,
            sort = o.sort, time = o.time, anonymous = o.anonymous },
        on_select = o.on_select,
        on_sort = o.on_sort,
        on_hold = o.on_hold,
        links = o.links,
        api = o.api,
        read = o.read,
    }
    M.refresh(view, true)
    return view
end

--- Fetch and paint. `initial` reloads from the top; otherwise append a page.
function M.refresh(view, initial)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = T(_("Loading %1…"), view.listing:title()) }
        UIManager:show(info)
        UIManager:forceRePaint()

        local ok, err = initial and view.listing:reload() or view.listing:loadMore()
        UIManager:close(info)

        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not load %1:\n%2"), view.listing:title(), tostring(err)),
                timeout = 8 })
            if not view.viewer then return end   -- nothing on screen to fall back to
        end
        M.render(view, not initial)
    end)
end

function M.documentHtml(view)
    -- Stamped at render time, not at fetch time, so a post opened and backed out
    -- of is already marked when the listing repaints behind it.
    if view.read and view.listing.posts then
        view.read:apply(view.listing.posts)
    end
    local body = view.listing:bodyHtml()
    if not view.listing.exhausted then
        body = body .. '<p class="meta">' .. _("Use “Load more” below for the next page.") .. "</p>"
    end
    return Html.rawDocument(body, Listing.LISTING_CSS)
end

--- Repaint. `keep_position` swaps the document in place instead of reopening the
--- screen, so paging does not throw the reader back to the top.
function M.render(view, keep_position)
    if view.viewer and keep_position and view.viewer.setDocument then
        view.viewer:setDocument(M.documentHtml(view), { keep_position = true })
        return view.viewer
    end
    if view.viewer then UIManager:close(view.viewer) end

    -- Sort and search are network operations; a saved set has neither a server
    -- to ask nor a next page, so the offline screen carries whatever its caller
    -- gave it instead (reddle_ui_saved).
    local buttons = view.listing.saved and (view.buttons_table or {}) or { {
        { text = _("Sort"), callback = function() M.sortDialog(view) end },
        { text = _("Search"), callback = function() M.searchDialog(view) end },
    } }
    if not view.listing.exhausted then
        buttons[1][#buttons[1] + 1] = {
            text = _("Load more"),
            callback = function() M.refresh(view, false) end,
        }
    end

    view.viewer = RichText.show{
        title = view.listing:title(),
        html = M.documentHtml(view),
        text = view.listing:bodyText(),
        css = M.css(),
        buttons_table = #buttons > 0 and buttons or nil,
        pre_rendered = true,
        menu_items = function()
            return M.navButtons(view.links,
                not view.listing.saved and function() M.searchDialog(view) end or nil)
        end,
        on_link = function(link) M.onLink(view, link) end,
        on_hold_link = view.on_hold and function(link)
            local index = Listing.postIndexFromHref(link and link.uri)
            local post = index and view.listing:postAt(index)
            if not post then return false end   -- fall through to text selection
            view.on_hold(post)
            return true
        end or nil,
        -- Every target on this screen spans the width, and everything between
        -- them -- card padding, the border, the gap to the next card -- is dead
        -- space that used to turn the page. One line height of slop swallows all
        -- of it, and a tap in the gap between two cards goes to the nearer one.
        tap_slop = M.TAP_SLOP,
    }
    return view.viewer
end

function M.onLink(view, link)
    local uri = link and link.uri
    local index = Listing.postIndexFromHref(uri)
    if index then
        local post = view.listing:postAt(index)
        if post and view.on_select then view.on_select(post) end
        return true
    end
    -- Nothing else in a listing document is a link today, but search results can
    -- carry a crosspost title, and the router is the one place that decides.
    return require("reddle_ui_links").handle(uri, view.links or { api = view.api })
end

--- Sort, with the time window folded in: picking `top` alone is meaningless
--- without knowing over what period, so those rows carry it.
function M.sortDialog(view)
    local buttons = {}
    local current = view.listing.sort
    local sorts = view.listing:isSearch() and Listing.SEARCH_SORTS
        or Listing.sortsFor(view.listing.subreddit)

    for _, sort in ipairs(sorts) do
        local mark = (sort == current) and "• " or ""
        if Listing.TIMED[sort] then
            local row = {}
            for _, t in ipairs(Listing.TIMES) do
                row[#row + 1] = {
                    text = ((sort == current and t == view.listing.time) and "• " or "")
                        .. sort:sub(1, 3) .. " " .. t,
                    callback = function()
                        UIManager:close(view.sort_dialog)
                        M.applySort(view, sort, t)
                    end,
                }
            end
            -- six windows is too many for one row on a Paperwhite
            buttons[#buttons + 1] = { row[1], row[2], row[3] }
            buttons[#buttons + 1] = { row[4], row[5], row[6] }
        else
            buttons[#buttons + 1] = { {
                text = mark .. sort,
                callback = function()
                    UIManager:close(view.sort_dialog)
                    M.applySort(view, sort)
                end,
            } }
        end
    end

    view.sort_dialog = ButtonDialog:new{ title = _("Sort by"), buttons = buttons }
    UIManager:show(view.sort_dialog)
end

function M.applySort(view, sort, time)
    NetworkMgr:runWhenOnline(function()
        local ok, err = view.listing:setSort(sort, time)
        if not ok then
            UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 8 })
            return
        end
        -- Remember it: picking a sort every time you open the app is a chore.
        -- Search sorts are deliberately not remembered -- "relevance" is not a
        -- browsing preference.
        if view.on_sort and not view.listing:isSearch() then
            view.on_sort(view.listing.sort, view.listing.time)
        end
        M.render(view)   -- new sort: a new list, so start at the top
    end)
end

function M.searchDialog(view)
    local dialog
    dialog = InputDialog:new{
        title = _("Search"),
        input = view.listing.query or "",
        input_hint = _("words to look for"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = view.listing.subreddit and T(_("In r/%1"), view.listing.subreddit)
                    or _("Search all"),
                is_enter_default = true,
                callback = function()
                    local q = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if q == "" then return end
                    UIManager:close(dialog)
                    M.applySearch(view, q, view.listing.subreddit)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M.applySearch(view, query, subreddit)
    view.listing = Listing.new{
        api = view.api, subreddit = subreddit, query = query,
        sort = Listing.DEFAULT_SEARCH_SORT,
    }
    if view.viewer then UIManager:close(view.viewer); view.viewer = nil end
    M.refresh(view, true)
end

return M
