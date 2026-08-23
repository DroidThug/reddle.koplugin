--[[
Post and comments as one scrolling document (DESIGN.md §5.6).

They used to be two screens: a post, with a "Comments (80)" button that closed it
and opened a Menu. That made reading a thread a mode switch, and it meant there
was no way back to the post except closing everything.

Now it is one document -- header, post body, rule, thread -- so scrolling down
from the post continues into the comments and scrolling back up returns to it. No
navigation to learn, and one fewer screen to maintain.

The alternative considered was to keep two screens and catch the scroll at the
edges: ScrollHtmlWidget deliberately lets onScrollUp/onScrollDown propagate when
it cannot scroll further (scrollhtmlwidget.lua:219), which is how the dictionary
popup moves between results. That would work, but it makes a page-turn sometimes
mean "navigate", which on e-ink -- where a repaint already looks like a jump --
is a worse thing to be ambiguous about.

The cost: comments are fetched before anything is shown, so there is a wait on
opening a post where previously the post appeared at once. Worth it for one tap
instead of two; if it proves annoying, the fix is to show the post immediately and
swap in the full document via ReddleReader:setDocument once the fetch lands.
--]]

local Comments = require("reddle_comments")
local Html = require("reddle_html")
local InfoMessage = require("ui/widget/infomessage")
local Markdown = require("reddle_markdown")
local NetworkMgr = require("ui/network/manager")
local Post = require("reddle_ui_post")
local RichText = require("reddle_ui_richtext")
local UIManager = require("ui/uimanager")
local _ = require("reddle_gettext")
local T = require("ffi/util").template

local M = {}

--- The whole thread: post above, comments below, one stylesheet for both.
function M.documentHtml(post, rows, age, collapsed)
    -- The post sits in a card, so where it ends and the thread begins is a shape
    -- rather than a rule you have to read. The old <hr/> between them did the same
    -- job less clearly, and looked like a comment separator.
    local parts = {
        '<div class="card postcard">', Post.headerHtml(post, age),
        Post.bodyHtml(post), "</div>",
    }
    if #rows > 0 then
        parts[#parts + 1] = Comments.bodyHtml(rows, { collapsed = collapsed })
    else
        parts[#parts + 1] = '<p class="meta">' .. _("No comments yet.") .. "</p>"
    end
    -- RichText hands M.css() to HtmlBoxWidget as its actual stylesheet. Do not
    -- also put a <style> element in this body: unlike the rendering probe (where
    -- the scoped @font-face works), that nested stylesheet made MuPDF discard
    -- the preceding font-face rule, leaving emoji as replacement diamonds.
    return table.concat(parts)
end

--- The thread sheet: comment rules plus the post card's own spacing.
function M.css()
    return Comments.documentCss() .. [[
.postcard { margin-bottom: 0.9em; }
.postcard p { margin: 0 0 0.4em 0; }
]]
end

function M.documentText(post, rows, age)
    local parts = { Post.fullText(post, age) }
    if #rows > 0 then
        parts[#parts + 1] = "\n" .. Markdown.RULE .. "\n"
        parts[#parts + 1] = Comments.toPlainText(rows)
    end
    return table.concat(parts, "\n")
end

--- opts: api, post, subreddit, age, transport, links (link context, §5.9)
function M.open(opts)
    local view = {
        api = opts.api,
        post = opts.post,
        subreddit = opts.subreddit or opts.post.subreddit,
        age = opts.age,
        transport = opts.transport,
        links = opts.links,
        store = opts.store,
        save_expand_max = opts.save_expand_max,
        image_opts = opts.image_opts,
        cache = opts.cache,
        rows = {},
        collapsed = {},   -- comment ids the reader has folded
    }
    M.load(view)
    return view
end

--- The same screen, reached from a link rather than from the listing: all we
--- have is an id, so the post itself comes out of the comments response (which
--- carries it as the first Listing anyway -- we were throwing it away).
---
--- opts: api, id, subreddit (optional), comment (optional), transport, links
function M.openById(opts)
    local view = {
        api = opts.api,
        post = { id = opts.id, subreddit = opts.subreddit },
        subreddit = opts.subreddit,
        comment = opts.comment,
        transport = opts.transport,
        links = opts.links,
        store = opts.store,
        save_expand_max = opts.save_expand_max,
        image_opts = opts.image_opts,
        cache = opts.cache,
        rows = {},
        collapsed = {},   -- comment ids the reader has folded
    }
    M.load(view)
    return view
end

--- What identifies one fetched thread. The re-rooted view of a branch is a
--- different document from the whole thread, so it caches separately.
function M.cacheKey(view)
    return tostring(view.post and view.post.id) .. "/" .. tostring(view.comment or "")
end

function M.load(view)
    -- A thread fetched a moment ago is reused without a request, and without
    -- waking the radio: backing out of a post by accident and opening it again
    -- is a misclick, not a reason to spend a call.
    local hit = view.cache and view.cache:get(M.cacheKey(view))
    if hit then
        view.rows = hit.rows
        if type(hit.post) == "table" and hit.post.id then
            view.post = hit.post
            view.subreddit = hit.post.subreddit or view.subreddit
        end
        -- Ages were formatted when it was fetched; a thread reopened nine
        -- minutes later must not still claim its comments are "2h" old.
        Comments.reage(view.rows)
        view.age = require("reddle_listing").formatAge(view.post.created_utc)
        M.render(view)
        return
    end

    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Loading comments…") }
        UIManager:show(info)
        UIManager:forceRePaint()

        -- /comments/<id> works without the subreddit; Reddit resolves it. That is
        -- what makes a bare redd.it link openable.
        local path = (view.subreddit and view.subreddit ~= "")
            and string.format("/r/%s/comments/%s", view.subreddit, view.post.id)
            or string.format("/comments/%s", view.post.id)
        local params = { depth = Comments.MAX_DEPTH + 1, limit = 200 }
        if view.comment then
            -- Re-rooted at one comment: no ancestors, just this branch.
            params.comment = view.comment
            params.context = 0
        end
        local res, code, err = view.api:get(path, params)
        UIManager:close(info)

        if not res then
            -- The post is still worth reading even when the thread will not load.
            UIManager:show(InfoMessage:new{
                text = T(_("Could not load comments (%1)."), tostring(err or code)), timeout = 6 })
            view.rows = {}
        else
            local rows, post = Comments.parse(res)
            view.rows = rows
            -- Prefer the fetched post: it is authoritative, and when we arrived
            -- by id it is the only copy there is.
            if type(post) == "table" and post.id then
                view.post = post
                view.subreddit = post.subreddit or view.subreddit
                view.age = require("reddle_listing").formatAge(post.created_utc)
            end
            -- Stored by reference, so replies expanded later are still there on
            -- the way back rather than being fetched a second time.
            if view.cache then
                view.cache:put(M.cacheKey(view), { rows = view.rows, post = view.post })
            end
        end
        M.render(view)
    end)
end

function M.render(view)
    local buttons = {}
    local row = {}

    local img = view.image_url or Post.imageUrl(view.post, view.image_opts)
    if img then
        row[#row + 1] = {
            -- A saved post shows its own copy; only a live one goes to the net.
            text = view.image_file and _("Image (saved)")
                or T(_("Image (%1)"), Markdown.host(img) or "?"),
            callback = function()
                if view.image_file then
                    Post.showFile(view.image_file)
                else
                    Post.showImage(img, view.transport)
                end
            end,
        }
    end

    -- Expanding a stub is a network call, so it is not offered offline; the
    -- saved screen's "Fetch missing" is the way to fill a record in.
    local pending = not view.offline and Comments.pendingStubs(view.rows) or {}
    if #pending > 0 then
        row[#row + 1] = {
            text = T(_("Load all replies (%1)"), tostring(#pending)),
            callback = function()
                if view.viewer then UIManager:close(view.viewer) end
                M.expandAll(view)
            end,
        }
    end
    if view.offline and view.store then
        -- On a saved post, removing it is a first-class action rather than
        -- something buried in a save dialog you would have no reason to open.
        row[#row + 1] = {
            text = _("Remove"),
            callback = function()
                require("reddle_ui_saved").confirmRemove(
                    { store = view.store }, nil, view.post)
                if view.viewer then UIManager:close(view.viewer) end
            end,
        }
    elseif view.store then
        row[#row + 1] = {
            text = view.store:isSaved(view.post.id) and _("Saved ✓") or _("Save"),
            callback = function()
                require("reddle_ui_saved").saveDialog{
                    store = view.store,
                    post = view.post,
                    -- Already in memory: saving this costs no API calls. The
                    -- api is for the other branch, which completes the thread
                    -- first -- and is not offered on a saved post.
                    rows = view.rows,
                    api = not view.offline and view.api or nil,
                    save_expand_max = view.save_expand_max,
                    image_url = img,
                    transport = view.transport,
                    on_change = function() M.redraw(view) end,
                }
            end,
        }
    end
    if #row > 0 then buttons[#buttons + 1] = row end

    view.viewer = RichText.show{
        title = view.post.subreddit and ("r/" .. view.post.subreddit) or _("Post"),
        html = M.documentHtml(view.post, view.rows, view.age, view.collapsed),
        text = M.documentText(view.post, view.rows, view.age),
        css = Html.CSS .. M.css(),
        buttons_table = #buttons > 0 and buttons or nil,
        pre_rendered = true,   -- already a whole document; do not wrap it again
        menu_items = function()
            return require("reddle_ui_listing").navButtons(view.links)
        end,
        on_link = function(link) M.onLink(view, link and link.uri) end,
    }
    return view.viewer
end

--- Every tap inside the thread lands here (§5.9). Stubs are ours; everything
--- else came out of a post or comment body and goes to the router.
function M.onLink(view, uri)
    local Links = require("reddle_links")
    local kind, payload = Links.classify(uri)
    -- Collapsing is pure local state, so it works on a saved post exactly as it
    -- does on a live one. Expanding and re-rooting are network calls: offline
    -- they say so rather than failing obscurely somewhere in the API layer.
    if kind == "collapse" then
        M.toggleCollapse(view, payload)
        return true
    end
    if view.offline and (kind == "more" or kind == "continue") then
        UIManager:show(InfoMessage:new{
            text = _("Those replies were not saved.\nUse “Fetch missing” on the Saved screen."),
            timeout = 5 })
        return true
    end
    if kind == "more" then
        M.expandStub(view, payload)
        return true
    end
    if kind == "continue" then
        M.continueFrom(view, payload)
        return true
    end
    local ctx = {}
    for k, v in pairs(view.links or {}) do ctx[k] = v end
    ctx.api = ctx.api or view.api
    ctx.transport = ctx.transport or view.transport
    return require("reddle_ui_links").handle(uri, ctx)
end

--- Fold or unfold one comment and everything under it.
---
--- Purely local: nothing is fetched, the rows do not move, only what we draw
--- changes. So it is a document swap that holds the reader's position, which is
--- what makes folding a long branch feel like the thread closing up around you
--- rather than the screen being replaced.
function M.toggleCollapse(view, comment_id)
    if not comment_id then return end
    view.collapsed = view.collapsed or {}
    view.collapsed[comment_id] = (not view.collapsed[comment_id]) or nil
    -- The byline that was tapped is a link, and it is still a link once folded,
    -- so it is the one thing in the new document guaranteed to be where the
    -- reader was looking.
    M.redraw(view, require("reddle_links").href("collapse", comment_id))
end

--- One stub, not all of them: tapping "12 more replies" should load those twelve.
function M.expandStub(view, stub_id)
    local index = Comments.stubIndexById(view.rows, stub_id)
    local row = index and view.rows[index]
    if not row or #(row.children or {}) == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nothing more to load."), timeout = 3 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Loading replies…") }
        UIManager:show(info)
        UIManager:forceRePaint()

        local body = Comments.moreChildrenBody("t3_" .. view.post.id, row, Comments.MORE_BATCH)
        local res = view.api:get("/api/morechildren", {
            api_type = body.api_type, link_id = body.link_id, children = body.children,
        })
        local things = res and res.json and res.json.data and res.json.data.things
        UIManager:close(info)
        if not things then
            UIManager:show(InfoMessage:new{ text = _("Could not load those replies."), timeout = 4 })
            return
        end
        -- Look the stub up again rather than trusting the index we had before the
        -- request: runWhenOnline can hold this callback until Wi-Fi comes up, and
        -- another expansion in the meantime would have moved it.
        local at = Comments.stubIndexById(view.rows, stub_id)
        if not at then return end
        -- The stub itself is about to be replaced, so anchor on the comment
        -- above it: that is what the reader was looking at, and the replies
        -- appear underneath it rather than the screen jumping.
        local anchor
        for i = at - 1, 1, -1 do
            local row = view.rows[i]
            if row.kind == "comment" and row.id then
                anchor = require("reddle_links").href("collapse", row.id)
                break
            end
        end
        Comments.spliceMore(view.rows, at, things)
        M.redraw(view, anchor)
    end)
end

--- A branch too deep to indent becomes its own screen, rooted at that comment.
function M.continueFrom(view, comment_id)
    M.openById{
        api = view.api,
        id = view.post.id,
        subreddit = view.subreddit,
        comment = comment_id,
        transport = view.transport,
        links = view.links,
    }
end

--- Swap the document in place, keeping the reader where they were -- expanding a
--- stub halfway down a thread should not throw them back to the post.
---
--- The "Load all replies (N)" button keeps its old count until the next full
--- render: TextViewer builds its button table once. Deliberate -- holding the
--- reader's place partway down a thread is worth more than a live number, and the
--- stubs themselves, which are the accurate count, are now tappable in place.
--- `anchor` is a link uri to land on. Without one this falls back to holding the
--- scroll ratio, which is only right when the document grew at the end.
function M.redraw(view, anchor)
    if view.viewer and view.viewer.setDocument then
        view.viewer:setDocument(
            M.documentHtml(view.post, view.rows, view.age, view.collapsed),
            { keep_position = true, anchor = anchor })
        return view.viewer
    end
    if view.viewer then UIManager:close(view.viewer) end
    return M.render(view)
end

--- Expand every outstanding `more` stub, then re-render once.
function M.expandAll(view)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Loading replies…") }
        UIManager:show(info)
        UIManager:forceRePaint()

        local expanded, remaining = Comments.expandBranches(
            view.api, "t3_" .. view.post.id, view.rows, { max = Comments.MAX_EXPANDS })

        UIManager:close(info)
        if expanded == 0 then
            UIManager:show(InfoMessage:new{ text = _("Nothing more to load."), timeout = 4 })
        elseif remaining > 0 then
            -- The ceiling exists so one tap cannot spend the whole rate limit,
            -- but silently stopping short reads as "that is the whole thread".
            UIManager:show(InfoMessage:new{
                text = T(_("Loaded %1 batch(es). About %2 more to go — tap again."),
                    tostring(expanded), tostring(remaining)),
                timeout = 4 })
        end
        M.render(view)
    end)
end

return M
