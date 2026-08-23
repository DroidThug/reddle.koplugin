--[[
TextViewer, with a stylesheet we control and taps we can hear (DESIGN.md §5.5).

TextViewer owns the title bar, the button table, paging and the font-size menu,
but closes two doors:

  1. It hardcodes the CSS it hands to ScrollHtmlWidget. Emitting our own <style>
     does not work either -- setContent wraps the body in one it builds itself,
     and MuPDF discards a stylesheet found in there. So the only way to style
     Reddit's markup is to get a real sheet to setContent.

  2. ScrollHtmlWidget accepts html_link_tapped_callback and HtmlBoxWidget
     hit-tests links against MuPDF's own boxes, but TextViewer never passes one,
     so links inside it are inert.

Both are re-applied on top of what TextViewer builds. Overriding init rather than
patching after :new is what makes it stick: TextViewer calls self:init(true) on
every font-size change, rebuilding the ScrollHtmlWidget.
--]]

local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("reddle_gettext")

local ReddleReader = TextViewer:extend{
    reddle_css = nil,   -- appended to the base sheet below
    on_link = nil,      -- function(link) -- link.uri is the href
    on_hold_link = nil, -- function(link) -- long-press; return true if consumed
    menu_items = nil,   -- function() -> ButtonDialog rows, shown above the display settings
    resource_dir = nil, -- what MuPDF resolves url() against, for @font-face (§5.10.1)
    -- How far outside a link's own box a tap still counts as that link, as a
    -- multiple of the link's line height. 0 (the default) is MuPDF's own
    -- behaviour, exactly. See pickLink.
    tap_slop = 0,
}

--- How far either side of the reader setDocument will look for its anchor. A
--- fold or an expansion moves things by a page or two, so the anchor is nearly
--- always within one or two; beyond that it is almost certainly gone.
ReddleReader.ANCHOR_SEARCH_PAGES = 12

--- Which link a tap meant.
---
--- MuPDF gives one box per line of laid-out text inside an anchor, never a box
--- over a block. Everything around the text -- padding, the gap after a short
--- title, the border -- falls through to tap-to-turn-page, which on the listing
--- meant tapping a post turned the page instead.
---
--- KOReader's version is containment only. This adds a second pass: if no box
--- contains the point, take the nearest one vertically within `slop` line
--- heights. Nearest rather than first, so the gap between two cards resolves to
--- whichever is closer.
---
--- The fallback ignores x, which is right for a listing where every target spans
--- the width. That is why slop is opt-in per screen: in prose a near-miss on an
--- inline link should stay a page turn.
function ReddleReader.pickLink(links, pos, slop)
    if type(links) ~= "table" or not pos then return nil end
    for _, l in ipairs(links) do
        if pos.x >= l.x0 and pos.x < l.x1 and pos.y >= l.y0 and pos.y < l.y1 then
            return l
        end
    end
    if not slop or slop <= 0 then return nil end

    local best, best_gap
    for _, l in ipairs(links) do
        local gap
        if pos.y < l.y0 then gap = l.y0 - pos.y
        elseif pos.y >= l.y1 then gap = pos.y - l.y1
        else gap = 0 end
        -- Scaled by the line's own height, so this holds at any font size.
        if gap <= (l.y1 - l.y0) * slop and (not best_gap or gap < best_gap) then
            best, best_gap = l, gap
        end
    end
    return best
end

--- TextViewer's own body rules. setContent replaces the css argument rather than
--- merging, so losing these shows up as changed line spacing and lost
--- justification -- which reads as "the font looks different" rather than a bug.
function ReddleReader:baseCss()
    return table.concat({
        "@page { margin: 0; }\n",
        "body { margin: 0; line-height: 1.3;",
        self.justified and " text-align: justify;" or "",
        self.monospace_font and " font-family: monospace;" or "",
        " }\n",
    })
end

function ReddleReader:init(reinit)
    -- Lay the document out once, not twice. TextViewer's init would otherwise
    -- lay out the whole thread with its own CSS and we would immediately do it
    -- again with ours; MuPDF layout is the expensive part of opening a thread.
    -- There is no hook to get CSS in first, so TextViewer builds the widget
    -- around an empty body and the real document arrives below. self.text is put
    -- back immediately -- re-init and Find both read it.
    local full = self.text
    local defer = self.reddle_css ~= nil
        and type(full) == "string"
        and self.html_text_formats[self.text_format or ""] ~= nil
    if defer then self.text = "" end

    TextViewer.init(self, reinit)

    if defer then self.text = full end

    -- is_txt means the plain-text path: no MuPDF, nothing to style.
    if self.is_txt then return end
    local scroll = self.scroll_widget
    local htmlbox = scroll and scroll.htmlbox_widget
    if not htmlbox then return end

    if self.on_link then
        scroll.html_link_tapped_callback = self.on_link
        htmlbox.html_link_tapped_callback = self.on_link
    end

    -- TextViewer already routes HoldRelease to the html widget for text
    -- selection, and the gesture carries a position, so the lookup that resolves
    -- a tap resolves a hold. Only wrapped when a screen asks: taking the gesture
    -- costs select-word-and-look-up wherever it is installed.
    if self.on_hold_link then
        local on_hold_link = self.on_hold_link
        local inherited = htmlbox.onHoldReleaseText
        htmlbox.onHoldReleaseText = function(hb, callback, ges)
            local pos = ges and ges.pos
            local link = pos and hb:getLinkByPosition(pos)
            if link and on_hold_link(link) then return true end
            -- Not on a link: fall through, so selecting text still works.
            if inherited then return inherited(hb, callback, ges) end
            return false
        end
    end

    -- An instance field, so it wins over the class method without patching
    -- KOReader. Only installed when a screen asks for slop.
    if (self.tap_slop or 0) > 0 then
        local slop = self.tap_slop
        htmlbox.getLinkByPosition = function(hb, pos)
            local page = hb.document:openPage(hb.page_number)
            local links = page:getPageLinks()
            page:close()
            return ReddleReader.pickLink(links, pos, slop)
        end
    end

    if self.reddle_css then
        local css = self:baseCss() .. self.reddle_css
        scroll.css = css
        scroll.html_body = full   -- the widget was built around a placeholder
        -- Logged because the cost scales with thread length and is only
        -- measurable on the device.
        local started = time.now()
        -- The trailing args are setContent(body, css, font_size, is_xhtml,
        -- no_css_fixes, html_resource_directory) -- the last one is the only way
        -- to give MuPDF a font it does not already know about.
        htmlbox:setContent(scroll.html_body, css, scroll.default_font_size,
            nil, nil, self.resource_dir)
        scroll:resetScroll()
        logger.info(string.format("reddle: styled relayout of %d bytes in %.0f ms",
            #(scroll.html_body or ""), time.to_ms(time.since(started))))
    end
end

--- The title bar's menu, with navigation in front of KOReader's display
--- settings. Without it, getting from a thread to another subreddit means
--- closing everything and going back through Tools.
function ReddleReader:onShowMenu()
    if not self.show_menu then return end
    if not self.menu_items then return TextViewer.onShowMenu(self) end

    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local rows = {}
    for _i, row in ipairs(self.menu_items(self) or {}) do
        local out = {}
        for j, button in ipairs(row) do
            local callback = button.callback
            out[j] = {
                text = button.text,
                text_func = button.text_func,
                enabled_func = button.enabled_func,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    if callback then callback() end
                end,
            }
        end
        rows[#rows + 1] = out
    end
    rows[#rows + 1] = { {
        text = _("Display settings"),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            TextViewer.onShowMenu(self)
        end,
    } }

    dialog = ButtonDialog:new{ title = _("Reddle"), buttons = rows }
    UIManager:show(dialog)
end

--- Which page a link with this uri was laid out on, or nil if it is not in the
--- document. Searched outwards from `near`, because the caller is asking about
--- something that was on screen a moment ago and is almost certainly still
--- within a page or two of it.
function ReddleReader:pageOfLink(uri, near)
    if not uri then return nil end
    local scroll = self.scroll_widget
    local htmlbox = scroll and scroll.htmlbox_widget
    local doc = htmlbox and htmlbox.document
    local count = htmlbox and htmlbox.page_count or 0
    if not doc or count < 1 then return nil end

    -- Bounded, because the miss is the expensive case: an anchor that is no
    -- longer in the document would otherwise open and close every page through
    -- MuPDF, and on a long thread that is a freeze the reader reads as a crash.
    -- Falling through to the ratio is a wrong position; a freeze is a broken app.
    near = math.max(1, math.min(count, near or 1))
    local order = { near }
    for d = 1, math.min(count, ReddleReader.ANCHOR_SEARCH_PAGES) do
        if near - d >= 1 then order[#order + 1] = near - d end
        if near + d <= count then order[#order + 1] = near + d end
    end

    for _, p in ipairs(order) do
        local ok, links = pcall(function()
            local page = doc:openPage(p)
            local got = page:getPageLinks()
            page:close()
            return got
        end)
        if ok then
            for _, l in ipairs(links or {}) do
                if l.uri == uri then return p end
            end
        end
    end
    return nil
end

--- Replace the document in place, without tearing the screen down.
---
--- Closing and reopening the viewer to show more posts costs a full-screen e-ink
--- repaint and drops the reader back at the top of the list.
---
--- `opts.anchor` is a link uri to land on, and is the accurate option: it is
--- where the reader actually was. `opts.keep_position` is the fallback, and it
--- holds a *ratio* rather than a position -- fine when the document only grew at
--- the end, wrong as soon as its length changes elsewhere. Collapsing a branch
--- below the reader shortens the document without moving anything above them, so
--- the same ratio resolves to an earlier page and the thread appears to scroll
--- itself back up.
function ReddleReader:setDocument(html, opts)
    opts = opts or {}
    self.text = html
    if self.is_txt then return end
    local scroll = self.scroll_widget
    local htmlbox = scroll and scroll.htmlbox_widget
    if not htmlbox then return end

    local was_page, was_count = htmlbox.page_number, htmlbox.page_count
    scroll.html_body = html
    htmlbox:setContent(html, scroll.css, scroll.default_font_size,
        nil, nil, self.resource_dir)

    -- Drop the rendered bitmap, or the screen keeps showing the old document.
    --
    -- setContent swaps the document but leaves htmlbox.bb alone, and
    -- HtmlBoxWidget:_render() returns immediately whenever a bitmap already
    -- exists -- so paintTo happily blits the previous thread. The only thing
    -- that frees it is ScrollHtmlWidget:scrollToRatio, and that early-returns
    -- when the page it computes is the page we are already on. resetScroll has
    -- just set page 1, so *every* swap that ends on page 1 skipped the free:
    -- collapsing a comment while the post is still on screen redrew nothing.
    if htmlbox.freeBb then htmlbox:freeBb() end

    scroll:resetScroll()

    local anchor_page = opts.anchor and self:pageOfLink(opts.anchor, was_page)
    if opts.anchor then
        -- Logged because it cannot be checked off-device: KOReader only ever
        -- opens the *current* page to read links, so whether MuPDF returns them
        -- for an arbitrary page index is a question the device answers. A nil
        -- here every time means pageOfLink is not working and the ratio branch
        -- below -- the one this exists to avoid -- is what actually runs.
        logger.info("reddle: anchor", tostring(opts.anchor), "resolved to page",
            tostring(anchor_page), "of", tostring(htmlbox.page_count),
            "(was", tostring(was_page), "of", tostring(was_count) .. ")")
    end
    if anchor_page and (htmlbox.page_count or 0) > 0 then
        scroll:scrollToRatio((anchor_page - 1) / htmlbox.page_count)
    elseif opts.keep_position and was_page and was_page > 1 and was_count and was_count > 0 then
        scroll:scrollToRatio((was_page - 1) / was_count)
    end
    UIManager:setDirty(self, "partial")
end

return ReddleReader
