--[[
What happens when a link is tapped (DESIGN.md §5.9).

reddle_links decides what a URI *is*; this decides what to do about it, which
needs KOReader and so lives apart from it.

The interesting case is the one with no good answer: a link out to the open web.
A Kindle running KOReader has no browser worth the name, and even if it did,
loading a modern page over a Kindle's radio onto a 6" grayscale panel is not a
thing anyone wants. So rather than fail silently -- or worse, look like a bug --
an external link says plainly that it cannot be opened here and offers a QR code.
Point a phone at it and the link continues on a device that can follow it. That
is the honest bridge between a reader that deliberately cannot browse and a web
that assumes everything can.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Links = require("reddle_links")
local UIManager = require("ui/uimanager")
local _ = require("reddle_gettext")
local T = require("ffi/util").template

local M = {}

--- Long URLs are the norm (tracking parameters, signatures) and a Paperwhite is
--- narrow. Show enough to recognise where it goes; the QR carries the whole thing.
M.URL_DISPLAY = 120

function M.shorten(url)
    url = tostring(url or "")
    if #url <= M.URL_DISPLAY then return url end
    return url:sub(1, M.URL_DISPLAY - 1) .. "…"
end

--- The QR code itself. Sized from the screen: QRWidget falls back to one pixel
--- per module when given neither width nor height, which on a 300dpi panel is a
--- code about a centimetre across that no phone will read.
function M.showQR(url)
    local ok, QRMessage = pcall(require, "ui/widget/qrmessage")
    if not ok or not QRMessage then
        UIManager:show(InfoMessage:new{
            text = T(_("This KOReader has no QR support.\n\n%1"), url), timeout = 20 })
        return
    end
    local Screen = require("device").screen
    local size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    UIManager:show(QRMessage:new{ text = url, width = size, height = size })
end

--- "This goes somewhere I cannot take you. Want it on your phone?"
function M.external(url, opts)
    opts = opts or {}
    local dialog
    dialog = ButtonDialog:new{
        title = table.concat({
            opts.reason or _("This link goes outside Reddit, and there is no browser here."),
            "", M.shorten(url),
        }, "\n"),
        title_align = "left",
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("QR code"),
                callback = function()
                    UIManager:close(dialog)
                    M.showQR(url)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    return dialog
end

--- ctx may carry a handler per kind (see reddle_links.classify) plus:
---   api, transport   -- for the defaults below
---   open_subreddit(name)
---
--- Returns true when the tap was consumed, so a caller can tell "not a link I
--- know" from "handled".
function M.handle(uri, ctx)
    ctx = ctx or {}
    local kind, payload = Links.classify(uri)
    if not kind then return false end

    local handler = ctx[kind]
    if handler then
        handler(payload)
        return true
    end

    if kind == "image" then
        require("reddle_ui_post").showImage(payload, ctx.transport)
        return true
    end

    if kind == "reddit_post" then
        if not ctx.api then return false end
        require("reddle_ui_thread").openById{
            api = ctx.api,
            id = payload.id,
            subreddit = payload.subreddit,
            transport = ctx.transport,
            links = ctx,
        }
        return true
    end

    if kind == "reddit_sub" then
        if ctx.open_subreddit then
            ctx.open_subreddit(payload)
        else
            UIManager:show(InfoMessage:new{
                text = T(_("r/%1 — open it from the Reddle menu."), payload), timeout = 5 })
        end
        return true
    end

    if kind == "reddit_user" then
        -- No profile screen yet (TODO.md). The QR at least gets you there.
        M.external("https://www.reddit.com/user/" .. payload, {
            reason = T(_("Profiles are not supported yet (u/%1)."), payload),
        })
        return true
    end

    if kind == "external" then
        M.external(payload)
        return true
    end

    return false
end

return M
