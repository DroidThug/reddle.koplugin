--[[
reddle_ui_reader.lua -- the TextViewer subclass that gets a stylesheet to MuPDF
and a tap callback onto links.

These specs cannot prove MuPDF renders anything; that is what the plugin's
"Rendering test" screen is for, and it is how the underlying bug was found. What
they *can* pin is the contract with KOReader: that the sheet arrives via
setContent rather than in the body, that it does not silently drop TextViewer's
own body rules, and that both survive the re-init a font-size change triggers.
--]]

local ui_fakes = require("spec.support.ui_fakes")
local rec = ui_fakes.install()

-- Re-required after the fakes are installed: an earlier spec file may already
-- have loaded this module, in which case it closed over that file's UIManager
-- and nothing it shows would reach the recorder above.
package.loaded["reddle_ui_reader"] = nil
local Reader = require("reddle_ui_reader")

local function open(o)
    o = o or {}
    o.text = o.text or "<p>hi</p>"
    o.text_format = o.text_format or "html"
    return Reader:new(o)
end

local function lastContent(viewer)
    local calls = viewer.scroll_widget.htmlbox_widget.set_content
    return calls[#calls]
end

describe("reddle_ui_reader", function()

    describe("stylesheet", function()
        it("hands the sheet to setContent, which is the only place MuPDF reads it", function()
            local v = open{ reddle_css = ".c { margin-left: 2em; }" }
            assert_match("%.c { margin%-left: 2em; }", lastContent(v).css)
        end)

        it("keeps TextViewer's own body rules, which setContent would replace", function()
            -- setContent does not merge: it builds head from mupdf_css_fixes .. css.
            -- Losing these reads as "the font changed somehow", not as a bug.
            local css = lastContent(open{ reddle_css = ".c {}" }).css
            assert_match("@page { margin: 0; }", css)
            assert_match("line%-height: 1%.3", css)
        end)

        it("honours the reader's justification setting rather than forcing our own", function()
            assert_match("text%-align: justify",
                lastContent(open{ reddle_css = "", justified = true }).css)
            assert_false(lastContent(open{ reddle_css = "", justified = false })
                .css:find("justify", 1, true) ~= nil)
        end)

        it("honours the reader's monospace setting", function()
            assert_match("font%-family: monospace",
                lastContent(open{ reddle_css = "", monospace_font = true }).css)
        end)

        it("restyles the document TextViewer built, not some other text", function()
            local v = open{ text = "<p>the body</p>", reddle_css = ".c {}" }
            assert_equal("<p>the body</p>", lastContent(v).body)
            assert_equal(20, lastContent(v).font_size)
        end)

        it("scrolls back to the top, since relayout invalidates the page number", function()
            assert_equal(1, open{ reddle_css = ".c {}" }.scroll_widget.reset_calls)
        end)

        it("leaves the widget alone when there is nothing to add", function()
            local v = open{}
            -- only TextViewer's own layout, none of ours
            assert_equal(1, #v.scroll_widget.htmlbox_widget.set_content)
            assert_equal("<koreader css>", v.scroll_widget.htmlbox_widget.set_content[1].css)
        end)

        it("lays the document out once, not twice", function()
            -- MuPDF layout is the expensive part of opening a thread. Letting
            -- TextViewer lay out the real body with its CSS, then re-laying it out
            -- with ours, doubles that cost for nothing.
            local v = open{ text = "<p>a long thread</p>", reddle_css = ".c {}" }
            local calls = v.scroll_widget.htmlbox_widget.set_content
            assert_equal(2, #calls)
            assert_equal("", calls[1].body, "TextViewer must lay out a placeholder, not the thread")
            assert_equal("<p>a long thread</p>", calls[2].body)
        end)

        it("restores the text it borrowed, since Find and re-init read it", function()
            local v = open{ text = "<p>body</p>", reddle_css = ".c {}" }
            assert_equal("<p>body</p>", v.text)
            assert_equal("<p>body</p>", v.scroll_widget.html_body)
        end)
    end)

    describe("links", function()
        it("wires the callback onto the widget that does the hit-testing", function()
            local cb = function() end
            local v = open{ on_link = cb }
            -- HtmlBoxWidget:onTapText reads it off itself (htmlboxwidget.lua:463);
            -- ScrollHtmlWidget passes it down when it builds one.
            assert_equal(cb, v.scroll_widget.htmlbox_widget.html_link_tapped_callback)
            assert_equal(cb, v.scroll_widget.html_link_tapped_callback)
        end)
    end)

    describe("re-init", function()
        it("re-applies both when the font size changes", function()
            -- TextViewer calls self:init(true) on a font change (textviewer.lua:815),
            -- rebuilding the ScrollHtmlWidget. Patching after :new would be lost.
            local cb = function() end
            local v = open{ reddle_css = ".c { margin-left: 2em; }", on_link = cb }
            v:init(true)
            assert_equal(2, v.init_calls)
            assert_match("margin%-left: 2em", lastContent(v).css)
            assert_equal(cb, v.scroll_widget.htmlbox_widget.html_link_tapped_callback)
        end)
    end)

    describe("holding the reader's place across a document swap", function()
        --- A viewer sitting on page `at` of `count`, with `links` laid out per page.
        local function at(page, count, links)
            local v = open{ reddle_css = ".c {}" }
            local hb = v.scroll_widget.htmlbox_widget
            hb.page_number, hb.page_count, hb.page_links = page, count, links or {}
            return v, hb
        end

        it("lands on the page the anchor is laid out on", function()
            local v, hb = at(20, 60)
            -- The new document is shorter, and the anchor moved with it.
            hb.next_page_count = 40
            hb.page_links = { [20] = { { uri = "reddle:collapse:t1_x" } } }
            v:setDocument("<p>new</p>", { keep_position = true, anchor = "reddle:collapse:t1_x" })
            -- scrollToRatio computes 1 + floor(count * ratio), so this is page 20.
            assert_equal(19 / 40, v.scroll_widget.ratio)
        end)

        it("does not scroll back up when a branch below the reader is folded", function()
            -- The bug: the ratio was kept, not the position. Collapsing below the
            -- reader shortens the document without moving anything above them, so
            -- 19/60 of a 40-page document is page 13 -- seven pages backwards.
            local v, hb = at(20, 60)
            hb.next_page_count = 40
            hb.page_links = { [20] = { { uri = "reddle:collapse:t1_x" } } }
            v:setDocument("<p>new</p>", { keep_position = true, anchor = "reddle:collapse:t1_x" })
            assert_false(v.scroll_widget.ratio == 19 / 60)
        end)

        it("falls back to the ratio when the anchor is gone", function()
            local v, hb = at(20, 60)
            hb.next_page_count = 40
            v:setDocument("<p>new</p>", { keep_position = true, anchor = "reddle:collapse:missing" })
            assert_equal(19 / 60, v.scroll_widget.ratio)
        end)

        it("searches outwards from where the reader was", function()
            local v, hb = at(10, 20, {
                [3] = { { uri = "reddle:collapse:t1_x" } },
                [11] = { { uri = "reddle:collapse:t1_x" } },
            })
            v:setDocument("<p>new</p>", { anchor = "reddle:collapse:t1_x" })
            assert_equal(10 / 20, v.scroll_widget.ratio)  -- page 11, not page 3
        end)

        it("gives up rather than walking a whole long document", function()
            -- The miss is the expensive case: without a bound this opens every
            -- page through MuPDF, which on a long thread is a visible freeze.
            local v, hb = at(1, 400, { [300] = { { uri = "reddle:collapse:t1_x" } } })
            local opened = 0
            hb.document.openPage = function(_doc, p)
                opened = opened + 1
                return {
                    getPageLinks = function() return hb.page_links[p] or {} end,
                    close = function() end,
                }
            end
            v:setDocument("<p>new</p>", { anchor = "reddle:collapse:t1_x" })
            assert_true(opened <= 2 * Reader.ANCHOR_SEARCH_PAGES + 1,
                "opened " .. opened .. " pages")
            assert_nil(v.scroll_widget.ratio)   -- not found, and no ratio was asked for
        end)

        it("leaves the reader at the top when nothing asked for a position", function()
            local v = at(20, 60)
            v:setDocument("<p>new</p>", {})
            assert_nil(v.scroll_widget.ratio)
        end)
    end)

    describe("repainting after a swap", function()
        it("frees the rendered bitmap, or the old document stays on screen", function()
            -- HtmlBoxWidget:_render() returns early whenever a bitmap exists,
            -- and setContent does not clear it.
            local v = open{ reddle_css = ".c {}" }
            local hb = v.scroll_widget.htmlbox_widget
            assert_equal("rendered", hb.bb)
            v:setDocument("<p>new</p>", { keep_position = true })
            assert_nil(hb.bb, "the stale bitmap survived the swap")
        end)

        it("frees it on the page-1 swap, which is the one that used to skip it", function()
            -- resetScroll sets page 1, and scrollToRatio early-returns when the
            -- page it computes is the page we are on -- so nothing freed the
            -- bitmap and collapsing with the post on screen redrew nothing.
            local v = open{ reddle_css = ".c {}" }
            local hb = v.scroll_widget.htmlbox_widget
            hb.page_number, hb.page_count = 1, 5
            hb.page_links = { [1] = { { uri = "reddle:collapse:t1_x" } } }
            v:setDocument("<p>new</p>",
                { keep_position = true, anchor = "reddle:collapse:t1_x" })
            assert_nil(hb.bb)
            -- Ratio 0 is page 1, which is the page resetScroll just set -- so in
            -- KOReader scrollToRatio returns without freeing or re-rendering
            -- anything. Freeing before this point is what makes the repaint real.
            assert_equal(0, v.scroll_widget.ratio)
        end)
    end)

    describe("title bar menu", function()
        local function shownDialog()
            return ui_fakes.lastShown(rec, "ButtonDialog")
        end

        it("leaves KOReader's own menu alone when a screen adds nothing", function()
            local viewer = open{}
            viewer:onShowMenu()
            assert_equal(1, viewer.show_menu_calls)
        end)

        it("puts a screen's own actions in front of the display settings", function()
            local ran = 0
            local viewer = open{ menu_items = function()
                return { { { text = "Front page", callback = function() ran = ran + 1 end } } }
            end }
            viewer:onShowMenu()
            local dialog = shownDialog()
            assert_equal("Front page", dialog.buttons[1][1].text)
            assert_equal("Display settings", dialog.buttons[2][1].text)
            -- KOReader's menu is not opened until that last row is chosen.
            assert_nil(viewer.show_menu_calls)
            dialog.buttons[1][1].callback()
            assert_equal(1, ran)
            dialog.buttons[2][1].callback()
            assert_equal(1, viewer.show_menu_calls)
        end)
    end)

    describe("plain text", function()
        it("does nothing at all when there is no HTML widget to patch", function()
            local v = open{ text = "plain", text_format = "txt", reddle_css = ".c {}",
                on_link = function() end }
            assert_true(v.is_txt)
            assert_nil(v.scroll_widget)  -- must not throw reaching into a tree that is not there
        end)
    end)
end)

--[[
Tap slop (§5.7.2). MuPDF gives one link box per line of laid-out text, so
everything around the text -- padding, borders, the gap between cards -- is dead
space. pickLink is the geometry that fixes that; it is pure, so it can be checked
without a document.
--]]
describe("ReddleReader.pickLink", function()
    -- Two cards, two text lines each, 20px lines with 10px of dead space between
    -- the cards and 4px between the lines inside one.
    local LINKS = {
        { uri = "reddle:post:1", x0 = 0, x1 = 300, y0 = 100, y1 = 120 },
        { uri = "reddle:post:1", x0 = 0, x1 = 200, y0 = 124, y1 = 144 },
        { uri = "reddle:post:2", x0 = 0, x1 = 300, y0 = 174, y1 = 194 },
        { uri = "reddle:post:2", x0 = 0, x1 = 200, y0 = 198, y1 = 218 },
    }

    local function at(x, y, slop)
        local l = require("reddle_ui_reader").pickLink(LINKS, { x = x, y = y }, slop)
        return l and l.uri or nil
    end

    it("prefers an exact hit, always", function()
        assert_equal("reddle:post:1", at(10, 110, 1.0))
        assert_equal("reddle:post:2", at(10, 180, 1.0))
    end)

    -- The default, and the whole point of it: without slop this is byte-for-byte
    -- MuPDF's own containment test, so prose keeps behaving the way it does.
    it("ignores everything outside the box when slop is off", function()
        assert_nil(at(10, 122, 0))
        assert_nil(at(10, 122, nil))
        assert_nil(at(400, 110, 0), "and x still matters for an exact hit")
    end)

    it("catches the gap between two lines of the same card", function()
        assert_equal("reddle:post:1", at(10, 122, 1.0))
    end)

    it("catches the padding to the right of a short line", function()
        -- x is ignored in the fallback: on a listing every target spans the width.
        assert_equal("reddle:post:1", at(280, 134, 1.0))
    end)

    it("resolves the gap between cards to the nearer one, not the first", function()
        assert_equal("reddle:post:1", at(10, 150, 1.0), "just below card 1")
        assert_equal("reddle:post:2", at(10, 170, 1.0), "just above card 2")
    end)

    it("still gives up when nothing is near enough", function()
        assert_nil(at(10, 400, 1.0))
    end)

    it("scales with the line height rather than assuming pixels", function()
        -- 20px lines: 1.0 slop reaches 20px from a box, 0.2 only 4px. y=160 sits
        -- 16px below card 1 and 14px above card 2.
        assert_equal("reddle:post:2", at(10, 160, 1.0))
        assert_nil(at(10, 160, 0.2))
    end)

    it("survives being handed nothing", function()
        assert_nil(require("reddle_ui_reader").pickLink(nil, { x = 1, y = 1 }, 1))
        assert_nil(require("reddle_ui_reader").pickLink({}, { x = 1, y = 1 }, 1))
        assert_nil(require("reddle_ui_reader").pickLink(LINKS, nil, 1))
    end)
end)
