--[[
reddle_emoji.lua -- glyphs this device cannot draw (§5.10).

A missing glyph is silent: the reader gets an empty box and no reason for it.
The rule these specs enforce is that we only ever substitute what somebody
watched fail on hardware, and that we never touch anything else.
--]]

local Emoji = require("reddle_emoji")
local Html = require("reddle_html")
local Listing = require("reddle_listing")

local PIN = "\240\159\147\140"      -- U+1F4CC, confirmed tofu on a Paperwhite 5
local FACE = "\240\159\152\128"     -- U+1F600, likewise
local HOOK = "\226\134\179"         -- U+21B3, renders -- and we already ship it

describe("reddle_emoji", function()

    describe("substitute", function()
        it("replaces the glyphs confirmed missing on the device", function()
            assert_equal("[pinned] Read this", Emoji.substitute(PIN .. " Read this"))
            assert_equal("hello :)", Emoji.substitute("hello " .. FACE))
        end)

        it("leaves a glyph the device can draw alone", function()
            assert_equal(HOOK .. " continue thread",
                Emoji.substitute(HOOK .. " continue thread"))
        end)

        -- Both were mapped on a guess until the device drew them fine. Coverage
        -- in U+1F300+ is per glyph, not per block, so inference is worth little
        -- and a measurement outranks it.
        it("leaves the emoji the device turned out to have", function()
            local fire = "\240\159\148\165"    -- U+1F525, renders
            local skull = "\240\159\146\128"   -- U+1F480, renders
            assert_equal(fire, Emoji.substitute(fire))
            assert_equal(skull, Emoji.substitute(skull))
        end)

        it("replaces the ones it does not have", function()
            assert_equal("[+1]", Emoji.substitute("\240\159\145\141"))
            assert_equal("[rocket]", Emoji.substitute("\240\159\154\128"))
            assert_equal("[winner]", Emoji.substitute("\240\159\143\134"))
        end)

        -- The conservative half of the design: we have no font coverage table,
        -- so anything unmapped is left as it is rather than mangled on a guess.
        it("passes an unmapped emoji through untouched", function()
            local unknown = "\240\159\166\145"   -- U+1F991 squid
            assert_equal("a " .. unknown .. " b", Emoji.substitute("a " .. unknown .. " b"))
        end)

        it("leaves plain ascii exactly as it found it", function()
            local s = "nothing to do here <b>at all</b>"
            assert_equal(s, Emoji.substitute(s))
        end)

        it("replaces every occurrence, not just the first", function()
            assert_equal("[pinned][pinned]", Emoji.substitute(PIN .. PIN))
        end)

        it("survives nil and empty input", function()
            assert_equal("", Emoji.substitute(nil))
            assert_equal("", Emoji.substitute(""))
        end)
    end)

    describe("applyToHtml", function()
        it("rewrites text but not markup", function()
            local out = Emoji.applyToHtml("<p>" .. PIN .. "</p>")
            assert_equal("<p>[pinned]</p>", out)
        end)

        -- The reason this is not a blanket gsub: an href with an emoji in it
        -- would be rewritten into a link that goes somewhere else.
        it("never touches an attribute", function()
            local href = '<a href="https://example.com/' .. PIN .. '">x</a>'
            assert_equal(href, Emoji.applyToHtml(href))
        end)

        it("handles text on both sides of a tag", function()
            assert_equal("[pinned]<b>:)</b>[pinned]",
                Emoji.applyToHtml(PIN .. "<b>" .. FACE .. "</b>" .. PIN))
        end)
    end)

    describe("where it is applied", function()
        it("reaches comment and post bodies, through sanitize", function()
            assert_match("%[pinned%]", Html.sanitize("<p>" .. PIN .. "</p>"))
        end)

        it("reaches the plain-text fallback too", function()
            assert_match("%[pinned%]", Html.toText("<p>" .. PIN .. "</p>"))
        end)

        -- Titles reach the screen by two different routes and need different
        -- treatment: the Menu row is plain text and can only take a placeholder,
        -- the card is markup and can carry the font.
        it("reaches listing titles on the plain-text path", function()
            local row = Listing.rowFor({ data = { title = PIN .. " Weekly thread" } }, os.time())
            assert_match("%[pinned%] Weekly thread", row.text)
        end)

        it("reaches listing titles on the html path", function()
            local html = Listing.htmlFor({ data = { title = PIN .. " Weekly" } }, os.time(), 1)
            assert_match("%[pinned%] Weekly", html)
        end)
    end)

    describe("our own markup", function()
        -- We were drawing the pin ourselves on every stickied post, so the one
        -- confirmed-missing glyph on the front page was one we put there.
        it("no longer emits a pin glyph of its own", function()
            local html = Listing.htmlFor(
                { data = { title = "Stickied", author = "mod", stickied = true,
                           num_comments = 0, score = 1, created_utc = os.time() } },
                os.time(), 1)
            assert_true(html:find(PIN, 1, true) == nil, "should not draw a pin glyph")
            assert_match("pinned", html, "but should still say it is pinned")
        end)
    end)
end)

--[[
The font is the real fix; substitution is damage control for its absence.
--]]
describe("reddle_emoji.hasFont", function()
    local function withFontList(fonts, fn)
        local saved = package.loaded["fontlist"]
        local saved_flag = Emoji._font_path
        package.loaded["fontlist"] = fonts and {
            getFontList = function() return fonts end,
        } or nil
        Emoji._font_path = nil
        local ok, err = pcall(fn)
        package.loaded["fontlist"] = saved
        Emoji._font_path = saved_flag
        if not ok then error(err, 0) end
    end

    it("stops substituting once an emoji font is installed", function()
        withFontList({ "/koreader/fonts/emoji/NotoEmoji-Regular.ttf" }, function()
            assert_true(Emoji.hasFont())
            assert_equal(PIN, Emoji.substitute(PIN), "a real pin beats [pinned]")
        end)
    end)

    -- MuPDF chooses a font per *run*, not per glyph, so `serif, ReddleEmoji`
    -- would just use serif. The font has to land on the emoji themselves.
    it("wraps emoji in a span so the font can be scoped to them", function()
        withFontList({ "/koreader/fonts/emoji/NotoEmoji-Regular.ttf" }, function()
            assert_equal('<span class="e">' .. PIN .. "</span>", Emoji.markup(PIN))
            assert_equal('<p><span class="e">' .. PIN .. "</span></p>",
                Emoji.applyToHtml("<p>" .. PIN .. "</p>"))
        end)
    end)

    it("leaves the prose around an emoji in the reading font", function()
        withFontList({ "/koreader/fonts/emoji/NotoEmoji-Regular.ttf" }, function()
            -- The probe put font-family on a whole paragraph and the Latin text
            -- came out in Noto Emoji's own Latin glyphs. Only the emoji is wrapped.
            assert_equal('look <span class="e">' .. PIN .. "</span> here",
                Emoji.markup("look " .. PIN .. " here"))
        end)
    end)

    it("drops variation selectors rather than risking a stray box", function()
        withFontList({ "/koreader/fonts/emoji/NotoEmoji-Regular.ttf" }, function()
            local vs16 = "\239\184\143"
            assert_equal('<span class="e">' .. PIN .. "</span>", Emoji.markup(PIN .. vs16))
        end)
    end)

    it("does not wrap the glyphs the reading font already draws", function()
        withFontList({ "/koreader/fonts/emoji/NotoEmoji-Regular.ttf" }, function()
            -- Swapping a familiar arrow for Noto Emoji's would be a regression.
            assert_equal(HOOK, Emoji.markup(HOOK))
        end)
    end)

    it("falls back to placeholders in markup when there is no font", function()
        withFontList({ "/koreader/fonts/noto/NotoSans-Regular.ttf" }, function()
            assert_equal("[pinned]", Emoji.markup(PIN))
        end)
    end)

    it("matches any emoji font, not one hardcoded path", function()
        withFontList({ "/somewhere/else/Symbola-Emoji.ttf" }, function()
            assert_true(Emoji.hasFont())
            assert_equal("/somewhere/else/Symbola-Emoji.ttf", Emoji.fontPath())
        end)
    end)

    -- MuPDF never scans the font directory, so the only way to reach a font it
    -- does not already know is an @font-face rule plus a resource directory
    -- (§5.10.1). Both halves come from the same lookup.
    it("splits the path into what an @font-face rule needs", function()
        withFontList({ "/koreader/fonts/emoji/NotoEmoji-Regular.ttf" }, function()
            local face = Emoji.fontFace("ReddleEmoji")
            assert_equal("/koreader/fonts/emoji", face.dir)
            assert_equal("NotoEmoji-Regular.ttf", face.file)
            assert_match('font%-family: "ReddleEmoji"', face.css)
            -- url() is resolved against dir, so it must stay a bare filename.
            assert_match('src: url%("NotoEmoji%-Regular.ttf"%)', face.css)
        end)
    end)

    it("has no font face to offer when there is no font", function()
        withFontList({ "/koreader/fonts/noto/NotoSans-Regular.ttf" }, function()
            assert_nil(Emoji.fontFace())
        end)
    end)

    it("substitutes when the font list has no emoji font", function()
        withFontList({ "/koreader/fonts/noto/NotoSans-Regular.ttf" }, function()
            assert_false(Emoji.hasFont())
            assert_equal("[pinned]", Emoji.substitute(PIN))
        end)
    end)

    -- "Cannot tell" has to mean "substitute": off-device, and on a KOReader
    -- whose fontlist blows up, the placeholder is the safe answer.
    it("substitutes when it cannot tell", function()
        withFontList(nil, function()
            assert_false(Emoji.hasFont())
            assert_equal("[pinned]", Emoji.substitute(PIN))
        end)
    end)
end)
