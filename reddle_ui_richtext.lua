--[[
Showing formatted text on whatever KOReader we are running on.

TextViewer gained `text_format = "html"` (ScrollHtmlWidget -> MuPDF) only in newer
builds. On v2026.03 the field is silently ignored and the raw HTML source is shown
as plain text -- which is exactly what happened on the device. So: detect, and fall
back to structured plain text rather than shipping markup at the reader.

DESIGN.md §5.4.
--]]

local Html = require("reddle_html")
local Reader = require("reddle_ui_reader")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")

local M = {}

--- Does this KOReader's TextViewer render HTML?
function M.canRenderHtml()
    if M._can ~= nil then return M._can end
    -- html_text_formats is the table TextViewer consults for text_format
    M._can = TextViewer.html_text_formats ~= nil and TextViewer.html_text_formats.html == true
    return M._can
end

--- opts: title, html, text (plain fallback), buttons_table,
---       pre_rendered (html is already a full document -- do not wrap/sanitise again),
---       css (stylesheet that actually reaches MuPDF -- see reddle_ui_reader),
---       on_link (function(link), for tappable elements),
---       menu_items (function() -> button rows for the title bar's menu),
---       tap_slop (how far outside a link a tap still counts -- see reddle_ui_reader),
---       resource_dir (what MuPDF resolves url() against, for @font-face)
function M.show(opts)
    local viewer
    if M.canRenderHtml() and Html.hasMarkup(opts.html) then
        -- Every HTML view wants emoji, and none of them should have to remember
        -- to ask: the @font-face rule and the resource directory it resolves
        -- against are two halves of one thing, and splitting them across call
        -- sites is how one screen ends up with emoji and another with blanks.
        local css = opts.css or Html.CSS
        local dir = opts.resource_dir
        local emoji = require("reddle_emoji").style()
        if emoji then
            css = emoji.css .. css
            dir = dir or emoji.dir
        end
        viewer = Reader:new{
            title = opts.title,
            text = opts.pre_rendered and opts.html or Html.document(opts.html),
            text_format = "html",
            buttons_table = opts.buttons_table,
            reddle_css = css,
            on_link = opts.on_link,
            on_hold_link = opts.on_hold_link,
            menu_items = opts.menu_items,
            tap_slop = opts.tap_slop,
            resource_dir = dir,
        }
    else
        local text = opts.text
        if (not text or text == "") and Html.hasMarkup(opts.html) then
            text = Html.toText(opts.html)
        end
        viewer = TextViewer:new{
            title = opts.title,
            text = text or "",
            buttons_table = opts.buttons_table,
        }
    end
    UIManager:show(viewer)
    return viewer
end

return M
