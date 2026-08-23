--[[
HTML sanitising for the post/comment views.

spec/fixtures/rich_html.json was captured live on 2026-08-15 and contains the
tags Reddit actually emits: h1, ul, li, strong, em, blockquote, a, div.md,
SC_OFF comments and escaped entities.
--]]

local Html = require("reddle_html")
local json = require("spec.support.json")

local function richFixture()
    local root = arg[0]:match("(.*)/spec/run%.lua") or "."
    local f = assert(io.open(root .. "/spec/fixtures/rich_html.json", "r"))
    local body = f:read("*a"); f:close()
    return json.decode(body)
end

describe("reddle_html", function()

    describe("keeps the formatting Reddit supports", function()
        it("keeps bold and italic", function()
            assert_match("<strong>", Html.sanitize("<p><strong>bold</strong></p>"))
            assert_match("<em>", Html.sanitize("<p><em>italic</em></p>"))
        end)

        it("keeps strikethrough", function()
            assert_match("<del>", Html.sanitize("<del>gone</del>"))
        end)

        it("keeps superscript and subscript", function()
            assert_match("<sup>", Html.sanitize("<sup>note</sup>"))
            assert_match("<sub>", Html.sanitize("<sub>2</sub>"))
        end)

        it("keeps underline if it ever appears", function()
            assert_match("<u>", Html.sanitize("<u>under</u>"))
        end)

        it("keeps every heading level", function()
            for i = 1, 6 do
                local tag = "h" .. i
                assert_match("<" .. tag .. ">", Html.sanitize("<" .. tag .. ">T</" .. tag .. ">"))
            end
        end)

        it("keeps lists, quotes and code", function()
            local out = Html.sanitize("<ul><li>a</li></ul><blockquote><p>q</p></blockquote><pre><code>x</code></pre>")
            assert_match("<ul>", out)
            assert_match("<li>", out)
            assert_match("<blockquote>", out)
            assert_match("<pre>", out)
            assert_match("<code>", out)
        end)

        it("keeps tables", function()
            local out = Html.sanitize("<table><tr><th>a</th><td>b</td></tr></table>")
            assert_match("<table>", out)
            assert_match("<th>", out)
        end)
    end)

    describe("sanitising", function()
        it("drops Reddit's SC_OFF wrapper comments", function()
            local out = Html.sanitize("<!-- SC_OFF --><div class=\"md\"><p>hi</p></div><!-- SC_ON -->")
            assert_false(out:find("SC_OFF") ~= nil)
            assert_match("<p>hi</p>", out)
        end)

        it("strips scripts and their contents entirely", function()
            local out = Html.sanitize("<p>a</p><script>evil()</script><p>b</p>")
            assert_false(out:find("evil", 1, true) ~= nil)
            assert_match("<p>a</p>", out)
            assert_match("<p>b</p>", out)
        end)

        it("strips style blocks so ours is the only styling", function()
            assert_false(Html.sanitize("<style>p{color:red}</style><p>x</p>"):find("color:red", 1, true) ~= nil)
        end)

        it("unwraps unknown tags but keeps their text", function()
            local out = Html.sanitize("<marquee>still readable</marquee>")
            assert_false(out:find("marquee", 1, true) ~= nil)
            assert_match("still readable", out)
        end)

        it("drops attributes, which are all noise to us", function()
            local out = Html.sanitize('<p class="md" style="color:red" onclick="x()">hi</p>')
            assert_equal("<p>hi</p>", out)
        end)

        it("keeps href on links, but only http(s)", function()
            assert_match('<a href="https://example.com">',
                Html.sanitize('<a href="https://example.com" rel="nofollow">x</a>'))
            assert_equal("<a>x</a>", Html.sanitize('<a href="javascript:alert(1)">x</a>'))
            assert_equal("<a>x</a>", Html.sanitize('<a href="file:///etc/passwd">x</a>'))
        end)

        it("marks spoilers rather than hiding them forever", function()
            -- there is no tap-to-reveal inside a rendered page
            local out = Html.sanitize('<span class="md-spoiler-text">the butler</span>')
            assert_match("%[spoiler%]", out)
            assert_match("the butler", out)
        end)

        it("survives empty and nil input", function()
            assert_equal("", Html.sanitize(nil))
            assert_equal("", Html.sanitize(""))
        end)
    end)

    describe("document", function()
        it("prefixes the body with our e-ink stylesheet", function()
            local doc = Html.document("<p>hi</p>")
            assert_match("<style>", doc)
            assert_match("blockquote", doc, "stylesheet missing")
            assert_match("<p>hi</p>", doc)
        end)

        it("emits a fragment, never a document", function()
            -- HtmlBoxWidget:setContent supplies <html><head><style>…<body> itself
            -- and puts ours *inside* that body, where MuPDF discards the CSS.
            -- Shipping our own scaffold is what broke styling on the device.
            for _, doc in ipairs({ Html.document("<p>hi</p>"), Html.rawDocument("<p>hi</p>") }) do
                assert_false(doc:find("<html", 1, true) ~= nil, "must not emit <html>")
                assert_false(doc:find("<head", 1, true) ~= nil, "must not emit <head>")
                assert_false(doc:find("<body", 1, true) ~= nil, "must not emit <body>")
            end
        end)

        it("sanitises what it wraps", function()
            -- plain find: "x()" as a pattern would match the x in "text-align"
            local doc = Html.document("<script>x()</script><p>a</p>")
            assert_false(doc:find("x()", 1, true) ~= nil)
            assert_false(doc:find("<script", 1, true) ~= nil)
            assert_match("<p>a</p>", doc)
        end)
    end)

    describe("toText", function()
        it("renders lists and paragraphs for the collapsed rows", function()
            local text = Html.toText("<p>intro</p><ul><li>one</li><li>two</li></ul>")
            assert_match("intro", text)
            assert_match("• one", text)
            assert_match("• two", text)
            assert_false(text:find("<") ~= nil, "no tags should survive")
        end)

        it("decodes entities", function()
            assert_equal("it's & more", Html.toText("<p>it&#39;s &amp; more</p>"))
        end)

        it("turns br into a newline", function()
            assert_equal("a\nb", Html.toText("a<br/>b"))
        end)
    end)

    describe("hasMarkup", function()
        it("is true only when there are tags", function()
            assert_true(Html.hasMarkup("<p>x</p>"))
            assert_false(Html.hasMarkup("plain text"))
            assert_false(Html.hasMarkup(nil))
            assert_false(Html.hasMarkup(""))
        end)
    end)

    describe("the live fixture", function()
        it("keeps every tag Reddit sent that we care about", function()
            local posts = richFixture()
            assert_true(#posts > 0, "fixture is empty")
            local all = {}
            for _, p in ipairs(posts) do all[#all + 1] = Html.sanitize(p.selftext_html) end
            local out = table.concat(all)
            assert_match("<h1>", out)
            assert_match("<strong>", out)
            assert_match("<li>", out)
            assert_match("<blockquote>", out)
        end)

        it("leaves no class or style attributes behind", function()
            for _, p in ipairs(richFixture()) do
                local out = Html.sanitize(p.selftext_html)
                assert_false(out:find('class="md"') ~= nil, "wrapper class survived")
                assert_false(out:find("style=") ~= nil, "inline style survived")
            end
        end)

        it("produces readable plain text too", function()
            local text = Html.toText(richFixture()[1].selftext_html)
            assert_true(#text > 40)
            assert_false(text:find("<") ~= nil)
        end)
    end)
end)
