--[[
The saved-post model (DESIGN.md §6). Pure: paths, record shape, index.
--]]

local Archive = require("reddle_archive")

local function post(over)
    local p = {
        id = "abc123", subreddit = "kindle", title = "A title", author = "alice",
        score = 42, num_comments = 7, created_utc = 1000, domain = "self.kindle",
        is_self = true,
    }
    for k, v in pairs(over or {}) do p[k] = v end
    return p
end

describe("reddle_archive", function()

    describe("the missing-parts note", function()
        it("says what was not saved, not that the post has none", function()
            -- The byline on the same card says "47 comments"; a note reading
            -- "no comments" beside it contradicts it.
            local children = Archive.children({ {
                id = "abc", subreddit = "kindle", title = "T",
                num_comments = 47, has_comments = false, saved_at = 10,
            } })
            Archive.savedListing(children, "Saved")
            assert_equal("comments not saved", children[1].data.reddle_note)
        end)

        it("leaves a complete record unannotated", function()
            local children = Archive.children({ {
                id = "abc", subreddit = "kindle", title = "T",
                num_comments = 47, has_comments = true, saved_at = 10,
            } })
            Archive.savedListing(children, "Saved")
            assert_nil(children[1].data.reddle_note)
        end)
    end)


    describe("paths", function()
        it("puts a post under its subreddit", function()
            assert_equal("/a/posts/kindle/abc123.json", Archive.postPath("/a", "kindle", "abc123"))
        end)

        it("cannot be walked out of the archive root", function()
            -- Subreddit and id come from the API, so they are untrusted input to
            -- a path. Neutralised rather than rejected: a strange name must not
            -- make a post unsaveable.
            local p = Archive.postPath("/a", "../../etc", "../../passwd")
            assert_true(p:find("%.%.") == nil, "path escaped the root: " .. p)
            assert_match("^/a/posts/", p)
        end)

        it("never produces an empty path segment", function()
            assert_match("^/a/posts/_/_%.json$", Archive.postPath("/a", "", ""))
        end)

        it("keeps an image's extension so the viewer can identify it", function()
            assert_equal("/a/images/abc123.png",
                Archive.imagePath("/a", "abc123", "https://i.redd.it/x.png"))
            assert_equal("/a/images/abc123.jpeg",
                Archive.imagePath("/a", "abc123", "https://i.redd.it/x.jpeg"))
        end)

        it("falls back to .jpg rather than no extension at all", function()
            assert_equal("/a/images/abc123.jpg",
                Archive.imagePath("/a", "abc123", "https://i.redd.it/no-extension"))
        end)

        it("keeps saved images out of the evictable cache", function()
            -- cache/reddle is LRU (reddle_ui_post); an archive whose pictures
            -- evict is not an archive.
            local p = Archive.imagePath("/data/reddle", "abc123", "x.jpg")
            assert_true(p:find("cache") == nil, "saved image landed in the cache: " .. p)
        end)
    end)

    describe("record", function()
        it("wraps the post the way a listing child is shaped", function()
            -- So reddle_listing.htmlFor renders saved posts through exactly the
            -- same path as live ones.
            local r = Archive.record(post(), nil, { saved_at = 5 })
            assert_equal("t3", r.post.kind)
            assert_equal("abc123", r.post.data.id)
        end)

        it("stores the link fullname, which expanding a stub later needs", function()
            assert_equal("t3_abc123", Archive.record(post(), nil, {}).link_fullname)
        end)

        it("records comments when given them, and nothing when not", function()
            assert_nil(Archive.record(post(), nil, {}).comments)
            local rows = { { kind = "comment", id = "c1" } }
            assert_equal(rows, Archive.record(post(), rows, {}).comments)
        end)

        it("reads a post back out", function()
            assert_equal("abc123", Archive.postOf(Archive.record(post(), nil, {})).id)
        end)
    end)

    describe("summary", function()
        it("stores the timestamp, never a formatted age", function()
            -- A record saved three weeks ago whose comments still say "2h" is a
            -- visible lie; ages are derived at render time.
            local s = Archive.summaryOf(post(), { saved_at = 99 })
            assert_equal(1000, s.created_utc)
            assert_nil(s.age)
        end)

        it("notes what was and was not saved alongside the post", function()
            local s = Archive.summaryOf(post(), { has_comments = true, has_image = false })
            assert_true(s.has_comments)
            assert_false(s.has_image)
        end)
    end)

    describe("index", function()
        local function idx()
            local i = {}
            Archive.upsert(i, Archive.summaryOf(post{ id = "a", subreddit = "kindle" }, { saved_at = 1 }))
            Archive.upsert(i, Archive.summaryOf(post{ id = "b", subreddit = "books" }, { saved_at = 3 }))
            Archive.upsert(i, Archive.summaryOf(post{ id = "c", subreddit = "kindle" }, { saved_at = 2 }))
            return i
        end

        it("replaces rather than duplicates on re-save", function()
            local i = idx()
            Archive.upsert(i, Archive.summaryOf(post{ id = "a", title = "New" }, { saved_at = 9 }))
            assert_equal(3, #i)
            assert_equal("New", Archive.find(i, "a").title)
        end)

        it("removes a post", function()
            local i = Archive.remove(idx(), "b")
            assert_equal(2, #i)
            assert_nil(Archive.find(i, "b"))
        end)

        it("is unbothered by removing something that is not there", function()
            assert_equal(3, #Archive.remove(idx(), "nope"))
        end)

        it("lists subreddits with counts, in a stable order", function()
            local subs = Archive.subreddits(idx())
            assert_equal(2, #subs)
            assert_equal("books", subs[1].subreddit)
            assert_equal(1, subs[1].count)
            assert_equal("kindle", subs[2].subreddit)
            assert_equal(2, subs[2].count)
        end)

        it("returns listing-shaped children, newest save first", function()
            local kids = Archive.children(idx())
            assert_equal(3, #kids)
            assert_equal("t3", kids[1].kind)
            assert_equal("b", kids[1].data.id)  -- saved_at 3
            assert_equal("c", kids[2].data.id)
            assert_equal("a", kids[3].data.id)
        end)

        it("filters to one subreddit", function()
            local kids = Archive.children(idx(), "kindle")
            assert_equal(2, #kids)
            for _, k in ipairs(kids) do assert_equal("kindle", k.data.subreddit) end
        end)

        it("survives a nil or junk index", function()
            assert_equal(0, #Archive.children(nil))
            assert_equal(0, #Archive.subreddits("not a table"))
        end)
    end)

    describe("missing pieces", function()
        it("reports comments missing only when the post has any", function()
            assert_equal("comments", Archive.describeMissing(
                Archive.summaryOf(post{ num_comments = 7 }, { has_comments = false })))
            assert_nil(Archive.describeMissing(
                Archive.summaryOf(post{ num_comments = 0 }, { has_comments = false })))
        end)

        it("reports an image only when there was one to save", function()
            assert_nil(Archive.describeMissing(
                Archive.summaryOf(post{ num_comments = 0 }, { has_image = false })))
            assert_equal("image", Archive.describeMissing(Archive.summaryOf(
                post{ num_comments = 0 }, { has_image = false, image_url = "u" })))
        end)

        it("names both when both are missing", function()
            assert_equal("comments and image", Archive.describeMissing(
                Archive.summaryOf(post(), { has_image = false, image_url = "u" })))
        end)

        it("says nothing when the post is complete", function()
            assert_nil(Archive.describeMissing(Archive.summaryOf(post(),
                { has_comments = true, has_image = true, image_url = "u" })))
        end)
    end)
end)

describe("reddle_archive partial threads", function()
    it("counts branches Reddit has not sent", function()
        assert_equal(0, Archive.pendingBranches(nil))
        assert_equal(0, Archive.pendingBranches({ { kind = "comment" } }))
        assert_equal(0, Archive.pendingBranches({ { kind = "more", children = {} } }),
            "an expanded-away stub is not a gap")
        assert_equal(2, Archive.pendingBranches({
            { kind = "comment" },
            { kind = "more", children = { "a" } },
            { kind = "more", children = { "b", "c" } },
        }))
    end)

    it("reports a half-saved thread as repairable", function()
        -- The hole this closes: has_comments was true, so nothing said the
        -- record was a slice and "Fetch missing" would not touch it. The reader
        -- found out offline, at a stub, with no way to fix it.
        local s = Archive.summaryOf(post{ num_comments = 1200 },
            { has_comments = true, pending = 7 })
        assert_equal(7, s.pending)
        assert_equal("more comments", Archive.describeMissing(s))
    end)

    it("leaves a fully saved thread unmarked", function()
        local s = Archive.summaryOf(post(), { has_comments = true, pending = 0 })
        assert_nil(s.pending)
        assert_nil(Archive.describeMissing(s))
    end)

    it("still says plain 'comments' when none were saved at all", function()
        local s = Archive.summaryOf(post{ num_comments = 7 }, { has_comments = false })
        assert_equal("comments", Archive.describeMissing(s))
    end)
end)
