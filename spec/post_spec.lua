--[[
Post screen composition. The widget itself needs a device; what is testable is
what goes *into* it -- which is where the mistakes live.
--]]

local ui_fakes = require("spec.support.ui_fakes")
local stubs = require("spec.support.stubs")

ui_fakes.clear()
stubs.installKOReaderFakes()
ui_fakes.install()
local Post = require("reddle_ui_post")

describe("reddle_ui_post", function()

    describe("imageUrl", function()
        it("recognises the extensions Reddit actually serves", function()
            assert_equal("https://i.redd.it/a.jpg", Post.imageUrl{ url = "https://i.redd.it/a.jpg" })
            assert_equal("https://x.com/a.PNG", Post.imageUrl{ url = "https://x.com/a.PNG" })
            assert_true(Post.imageUrl{ url = "https://i.redd.it/b.webp" } ~= nil)
        end)

        it("accepts i.redd.it links without an extension", function()
            assert_true(Post.imageUrl{ url = "https://i.redd.it/abcdef" } ~= nil)
        end)

        it("does not claim galleries, videos or articles are images", function()
            assert_nil(Post.imageUrl{ url = "https://www.reddit.com/gallery/abc" })
            assert_nil(Post.imageUrl{ url = "https://v.redd.it/abc" })
            assert_nil(Post.imageUrl{ url = "https://example.com/article" })
            assert_nil(Post.imageUrl{})
            assert_nil(Post.imageUrl(nil))
        end)
    end)

    describe("header", function()
        it("carries everything you need to judge a post", function()
            local h = Post.header({
                title = "A **bold** title", author = "someone", subreddit = "kindle",
                score = 2203, num_comments = 130, is_self = true,
            }, "16h")
            assert_match("A bold title", h)
            assert_match("u/someone", h)
            assert_match("r/kindle", h)
            assert_match("2203 points", h)
            assert_match("130 comments", h)
            assert_match("16h", h)
        end)

        it("shows where a link post points, by host not full URL", function()
            local h = Post.header({ title = "t", is_self = false, url = "https://i.redd.it/a.jpg" })
            assert_match("→ i%.redd%.it", h)
            assert_false(h:find("https://") ~= nil)
        end)

        it("does not show a link line for self posts", function()
            assert_false(Post.header({ title = "t", is_self = true, url = "x" }):find("→") ~= nil)
        end)
    end)

    describe("body", function()
        it("renders selftext through the markdown subset", function()
            assert_equal("quoted", Post.body{ selftext = "*quoted*", is_self = true })
        end)

        it("tells the reader an image is behind the button", function()
            assert_match("image", Post.body{ url = "https://i.redd.it/a.jpg" }:lower())
        end)

        it("says so plainly when a self post has no text", function()
            assert_match("no text", Post.body{ is_self = true, selftext = "" })
        end)

        it("falls back to the destination for a bare link post", function()
            assert_match("example%.com", Post.body{ is_self = false, url = "https://example.com/a" })
        end)
    end)

    describe("fullText", function()
        it("separates header from body with a rule", function()
            local t = Post.fullText({ title = "T", author = "a", subreddit = "s",
                is_self = true, selftext = "body here" }, "1h")
            assert_match("T", t)
            assert_match("────", t)
            assert_match("body here", t)
        end)
    end)
end)

describe("reddle_ui_post html", function()
    local Html = require("reddle_html")

    it("renders Reddit's own HTML so formatting survives", function()
        local doc = Post.fullHtml({
            title = "T", author = "a", subreddit = "s", is_self = true,
            selftext = "**bold** and *italic*",
            selftext_html = "<div class=\"md\"><p><strong>bold</strong> and <em>italic</em></p></div>",
        }, "1h")
        assert_match("<strong>bold</strong>", doc)
        assert_match("<em>italic</em>", doc)
        assert_false(doc:find('class="md"', 1, true) ~= nil, "wrapper class should be stripped")
    end)

    it("falls back to plain text when Reddit sent no HTML", function()
        local doc = Post.fullHtml({ title = "T", author = "a", subreddit = "s",
            is_self = true, selftext = "just text" }, "1h")
        assert_match("just text", doc)
        assert_match("<style>", doc)
    end)

    it("always carries the stylesheet", function()
        assert_match("blockquote", Post.fullHtml({ title = "T", is_self = true, selftext = "x" }))
    end)

    it("keeps the header above a rule", function()
        local doc = Post.fullHtml({ title = "Title Here", author = "bob", subreddit = "kindle",
            score = 12, num_comments = 3, is_self = true, selftext = "body" }, "2h")
        assert_match("Title Here", doc)
        assert_match("u/bob", doc)
        assert_match("<hr/>", doc)
    end)

    it("bolds the title but leaves the byline quiet", function()
        -- The first device build bolded the whole header, byline and link included,
        -- which read as a wall of heavy text above the post.
        local doc = Post.fullHtml({ title = "Title Here", author = "bob", subreddit = "kindle",
            score = 12, num_comments = 3, is_self = true, selftext = "body" }, "2h")
        assert_match("<b>Title Here</b>", doc)
        assert_match('<p class="meta">u/bob', doc)
    end)

    it("keeps class=\"meta\", which sanitize would have stripped", function()
        -- sanitize drops class attributes (Reddit's are not ours to trust), so the
        -- header has to be composed rather than run through it.
        local doc = Post.fullHtml({ title = "T", author = "a", subreddit = "s",
            is_self = true, selftext = "x" }, "1h")
        assert_match('class="meta"', doc)
    end)

    it("still escapes a title carrying markup", function()
        local doc = Post.fullHtml({ title = "<script>x</script>", author = "a",
            subreddit = "s", is_self = true, selftext = "x" }, "1h")
        assert_false(doc:find("<script>", 1, true) ~= nil)
        assert_match("&lt;script&gt;", doc)
    end)

    it("still sanitises the body it composes around", function()
        local doc = Post.fullHtml({ title = "T", author = "a", subreddit = "s", is_self = true,
            selftext = "x", selftext_html = '<div class="md"><script>evil()</script><p>ok</p></div>' }, "1h")
        assert_false(doc:find("<script", 1, true) ~= nil)
        assert_false(doc:find('class="md"', 1, true) ~= nil)
        assert_match("<p>ok</p>", doc)
    end)
end)

--[[
Which image gets downloaded. Reddit ships a ladder of previews next to the
source, so fetching a 4000px photo to look at it on a 1072px panel is a choice.
--]]
describe("reddle_ui_post image sizes", function()
    local function withPreview(widths, source_width)
        local res = {}
        for i, w in ipairs(widths) do
            res[i] = { url = "https://preview.redd.it/x.png?width=" .. w, width = w }
        end
        return {
            url = "https://i.redd.it/original.jpg",
            preview = { images = { {
                source = { url = "https://preview.redd.it/source.png",
                           width = source_width or 4000 },
                resolutions = res,
            } } },
        }
    end

    it("takes the smallest preview that still fills the screen", function()
        local post = withPreview{ 108, 320, 640, 960, 1080 }
        assert_match("width=1080", Post.imageUrl(post, { width = 1072 }))
    end)

    it("does not go smaller than the screen just to save bytes", function()
        local post = withPreview{ 108, 320, 640 }
        -- Every preview is too small, so the widest is the best on offer.
        assert_match("width=640", Post.imageUrl(post, { width = 1072 }))
    end)

    it("takes an exact match rather than the next one up", function()
        local post = withPreview{ 320, 1072, 1080 }
        assert_match("width=1072", Post.imageUrl(post, { width = 1072 }))
    end)

    it("honours a reader who asked for the original", function()
        local post = withPreview{ 108, 1080 }
        assert_equal("https://i.redd.it/original.jpg",
            Post.imageUrl(post, { width = 1072, quality = "original" }))
    end)

    it("falls back to the source when Reddit offered no previews", function()
        assert_equal("https://i.redd.it/original.jpg",
            Post.imageUrl({ url = "https://i.redd.it/original.jpg" }, { width = 1072 }))
    end)

    it("takes the source when there is no screen to fit to", function()
        -- No width means nothing to choose against; guessing a preview would be
        -- worse than the honest full-size answer.
        local post = withPreview{ 108, 1080 }
        assert_equal("https://i.redd.it/original.jpg", Post.imageUrl(post))
    end)

    it("is still nil for a post that is not an image", function()
        assert_nil(Post.imageUrl({ url = "https://example.com/article" }, { width = 1072 }))
        assert_nil(Post.imageUrl(nil, { width = 1072 }))
    end)

    it("survives a preview block that is the wrong shape", function()
        local post = { url = "https://i.redd.it/o.jpg", preview = { images = "nonsense" } }
        assert_equal("https://i.redd.it/o.jpg", Post.imageUrl(post, { width = 1072 }))
        assert_equal(0, #Post.imageVariants(post))
    end)
end)

--[[
The image cache had no bound at all -- 4.8 MB after casual use on the device,
and three comments in this codebase claiming it was an LRU. It is trimmed now.
--]]
describe("reddle_ui_post cache budget", function()
    local function entries(...)
        local out = {}
        for i, spec in ipairs({ ... }) do
            out[i] = { path = "/c/" .. spec[1], size = spec[2], mtime = spec[3] }
        end
        return out
    end

    it("deletes nothing while under budget", function()
        local remove, left = Post.trimPolicy(entries({ "a", 10, 1 }, { "b", 10, 2 }), 100)
        assert_equal(0, #remove)
        assert_equal(20, left)
    end)

    it("deletes oldest first until it fits", function()
        local remove, left = Post.trimPolicy(
            entries({ "new", 40, 300 }, { "old", 40, 100 }, { "mid", 40, 200 }), 100)
        assert_equal(1, #remove)
        assert_equal("/c/old", remove[1])
        assert_equal(80, left)
    end)

    it("keeps going when one file is not enough", function()
        local remove = Post.trimPolicy(
            entries({ "a", 50, 1 }, { "b", 50, 2 }, { "c", 50, 3 }), 60)
        assert_equal(2, #remove)
        assert_equal("/c/a", remove[1])
        assert_equal("/c/b", remove[2])
    end)

    it("is exact at the boundary rather than one file over", function()
        local remove = Post.trimPolicy(entries({ "a", 50, 1 }, { "b", 50, 2 }), 100)
        assert_equal(0, #remove, "exactly at budget is within budget")
    end)

    it("survives an empty cache", function()
        assert_equal(0, #Post.trimPolicy({}, 100))
    end)

    it("does not delete a file whose size it could not read", function()
        -- An unknown size counts as nothing against the budget, so it is never
        -- the reason something gets removed -- deleting on a failed stat would
        -- throw away the file the reader is looking at.
        local remove = Post.trimPolicy({ { path = "/c/x", mtime = 1 } }, 0)
        assert_equal(0, #remove)
    end)

    it("budgets in megabytes, not gigabytes", function()
        -- The partition is shared with the reader's books.
        assert_true(Post.CACHE_BUDGET <= 64 * 1024 * 1024, tostring(Post.CACHE_BUDGET))
    end)
end)
