--[[
reddle_links.lua and reddle_ui_links.lua -- what a tapped link means (§5.9).

Classification is where this feature lives or dies: a URI misread as external
sends the reader to a QR code instead of a post, and one misread as a Reddit
link sends them to a spinner. Every shape below was taken from real body_html.
--]]

local ui_fakes = require("spec.support.ui_fakes")
local rec = ui_fakes.install()

local Links = require("reddle_links")
-- An earlier spec file may already have pulled the router in, which would have
-- captured *its* UIManager fake -- and then every widget this file shows lands in
-- a recorder we are not looking at. Force a fresh copy against our own fakes.
package.loaded["reddle_ui_links"] = nil
local Router = require("reddle_ui_links")
local Html = require("reddle_html")

local function kind(uri)
    local k = Links.classify(uri)
    return k
end

local function payload(uri)
    local _, p = Links.classify(uri)
    return p
end

describe("reddle_links", function()

    describe("our own scheme", function()
        it("reads a listing row back as an index", function()
            assert_equal("post", kind("reddle:post:3"))
            assert_equal(3, payload("reddle:post:3"))
        end)

        -- By id, not position: expanding one stub renumbers every row below it.
        it("reads a more stub as an id", function()
            assert_equal("more", kind("reddle:more:t1_abc"))
            assert_equal("t1_abc", payload("reddle:more:t1_abc"))
        end)

        it("refuses an index that is not a number, rather than opening post nil", function()
            assert_nil(kind("reddle:post:seven"))
        end)

        it("carries a comment id verbatim for continue-thread", function()
            assert_equal("continue", kind("reddle:continue:h4x0r"))
            assert_equal("h4x0r", payload("reddle:continue:h4x0r"))
        end)

        it("ignores a verb it does not know instead of guessing", function()
            assert_nil(kind("reddle:explode:1"))
        end)

        it("round-trips through href()", function()
            assert_equal("more", kind(Links.href("more", "zz9")))
            assert_equal("zz9", payload(Links.href("more", "zz9")))
        end)
    end)

    describe("images", function()
        it("recognises an extension", function()
            assert_equal("image", kind("https://example.com/cat.JPG"))
            assert_equal("image", kind("https://example.com/a/b/c.webp"))
        end)

        it("recognises i.redd.it with no extension at all", function()
            assert_equal("image", kind("https://i.redd.it/abc123"))
        end)

        -- The one that would have shipped broken: preview URLs end .png but carry
        -- a signed query, and the href arrives HTML-escaped.
        it("sees past a signed query string", function()
            assert_equal("image",
                kind("https://preview.redd.it/x.png?width=640&amp;s=deadbeef"))
        end)

        it("unescapes the url it hands back, or the signature will not verify", function()
            local url = payload("https://preview.redd.it/x.png?width=640&amp;s=deadbeef")
            assert_equal("https://preview.redd.it/x.png?width=640&s=deadbeef", url)
        end)

        it("does not call a reddit post an image because the title ends in .png", function()
            assert_equal("reddit_post",
                kind("https://www.reddit.com/r/kindle/comments/abc123/my_cat_png/"))
        end)
    end)

    describe("reddit links", function()
        it("reads the canonical post url", function()
            local k, p = Links.classify("https://www.reddit.com/r/kindle/comments/abc123/slug/")
            assert_equal("reddit_post", k)
            assert_equal("abc123", p.id)
            assert_equal("kindle", p.subreddit)
        end)

        it("reads old.reddit and np.reddit the same way", function()
            assert_equal("reddit_post", kind("https://old.reddit.com/r/x/comments/q1w2e3/t/"))
            assert_equal("reddit_post", kind("https://np.reddit.com/r/x/comments/q1w2e3/t/"))
        end)

        it("reads a redd.it short link", function()
            local k, p = Links.classify("https://redd.it/abc123")
            assert_equal("reddit_post", k)
            assert_equal("abc123", p.id)
            assert_nil(p.subreddit)
        end)

        it("reads a relative post link, which is how reddit writes them in bodies", function()
            local k, p = Links.classify("/r/kindle/comments/abc123/slug/")
            assert_equal("reddit_post", k)
            assert_equal("abc123", p.id)
        end)

        it("reads a subreddit mention", function()
            assert_equal("reddit_sub", kind("/r/koreader"))
            assert_equal("koreader", payload("/r/koreader/"))
        end)

        it("reads a user mention in both spellings", function()
            assert_equal("someone", payload("/u/someone"))
            assert_equal("someone", payload("https://www.reddit.com/user/someone"))
        end)

        it("handles a protocol-relative host", function()
            assert_equal("reddit_post", kind("//www.reddit.com/r/x/comments/abc123/t/"))
        end)

        -- notreddit.com must not match on a suffix test done carelessly.
        it("does not mistake a lookalike domain for reddit", function()
            assert_equal("external", kind("https://notreddit.com/r/x/comments/abc123/t/"))
        end)
    end)

    describe("everything else", function()
        it("is external", function()
            assert_equal("external", kind("https://example.com/article"))
        end)

        it("treats a non-http scheme as external rather than following it", function()
            assert_equal("external", kind("mailto:someone@example.com"))
        end)

        it("ignores a relative path that is not a reddit shape", function()
            assert_nil(kind("/settings"))
        end)

        it("ignores an empty href", function()
            assert_nil(kind(""))
            assert_nil(kind(nil))
        end)
    end)
end)

describe("reddle_html.allowedHref", function()
    it("keeps http and https", function()
        assert_true(Html.allowedHref("https://example.com"))
        assert_true(Html.allowedHref("http://example.com"))
    end)

    -- The gap this closed: reddit writes subreddit and user mentions as bare
    -- paths, and the old ^https?:// test dropped the href, so the anchor
    -- rendered but could never fire.
    it("keeps the relative forms reddit actually emits", function()
        assert_true(Html.allowedHref("/r/kindle"))
        assert_true(Html.allowedHref("/u/someone"))
        assert_true(Html.allowedHref("/user/someone"))
        assert_true(Html.allowedHref("/comments/abc123"))
    end)

    it("refuses everything else, including the dangerous schemes", function()
        assert_false(Html.allowedHref("javascript:alert(1)"))
        assert_false(Html.allowedHref("data:text/html,<script>"))
        assert_false(Html.allowedHref("file:///mnt/us/koreader/settings/reddle.lua"))
        assert_false(Html.allowedHref("/"))
        assert_false(Html.allowedHref(""))
    end)

    it("survives sanitize end to end", function()
        local out = Html.sanitize('<p><a href="/r/kindle">r/kindle</a> ' ..
            '<a href="javascript:x">no</a></p>')
        assert_match('<a href="/r/kindle">', out)
        assert_match("<a>no</a>", out)
    end)
end)

describe("reddle_ui_links.handle", function()
    local function lastShown()
        return rec.shown[#rec.shown]
    end

    it("says an external link cannot be opened, and offers a QR code", function()
        local n = #rec.shown
        assert_true(Router.handle("https://example.com/x", {}))
        assert_true(#rec.shown > n)
        local dialog = lastShown()
        assert_equal("ButtonDialog", dialog.widget_kind)
        assert_match("no browser here", dialog.title)
        assert_match("https://example%.com/x", dialog.title)
        -- Cancel first: the destructive-looking option should not be the one
        -- under your thumb by default.
        assert_equal("Cancel", dialog.buttons[1][1].text)
        assert_equal("QR code", dialog.buttons[1][2].text)
    end)

    it("shows the QR code when asked", function()
        Router.handle("https://example.com/x", {})
        lastShown().buttons[1][2].callback()
        local qr = lastShown()
        assert_equal("QRMessage", qr.widget_kind)
        assert_equal("https://example.com/x", qr.text)
        -- Sized, or QRWidget draws one pixel per module.
        assert_true(qr.width ~= nil and qr.width > 100)
    end)

    it("truncates a long url for display but encodes the whole one", function()
        local long = "https://example.com/" .. string.rep("a", 300)
        Router.handle(long, {})
        assert_match("…", lastShown().title)
        lastShown().buttons[1][2].callback()
        assert_equal(long, lastShown().text)
    end)

    it("routes a subreddit mention to the listing", function()
        local opened
        assert_true(Router.handle("/r/koreader",
            { open_subreddit = function(s) opened = s end }))
        assert_equal("koreader", opened)
    end)

    it("says so rather than doing nothing when there is nowhere to send a subreddit", function()
        assert_true(Router.handle("/r/koreader", {}))
        assert_match("r/koreader", lastShown().text)
    end)

    it("offers a profile as a QR code, since there is no profile screen yet", function()
        assert_true(Router.handle("/u/someone", {}))
        assert_match("not supported yet", lastShown().title)
        assert_match("u/someone", lastShown().title)
    end)

    it("lets a caller override any kind", function()
        local got
        assert_true(Router.handle("https://example.com/x",
            { external = function(url) got = url end }))
        assert_equal("https://example.com/x", got)
    end)

    it("reports an unrecognised uri as unhandled instead of swallowing it", function()
        assert_false(Router.handle("reddle:nonsense:1", {}))
    end)
end)
