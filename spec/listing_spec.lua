--[[
Listing view-model. The fixture in spec/fixtures/listing_kindle_hot.json was
captured from the live API on 2026-08-15, so the shapes here are Reddit's, not
ones I invented.
--]]

local Listing = require("reddle_listing")
local stubs = require("spec.support.stubs")
local json = require("spec.support.json")

local function fixture(name)
    local root = arg[0]:match("(.*)/spec/run%.lua") or "."
    local f = assert(io.open(root .. "/spec/fixtures/" .. name, "r"))
    local body = f:read("*a"); f:close()
    return body
end

-- An api double: hands back canned bodies and records the calls.
local function fakeApi(bodies)
    local a = { calls = {}, index = 0, bodies = bodies }
    a.get = function(self, path, query)
        table.insert(a.calls, { path = path, query = query })
        a.index = a.index + 1
        local b = a.bodies[a.index]
        if not b then error("api double exhausted: call #" .. a.index) end
        if type(b) == "table" then return nil, b.code, b.err end
        return json.decode(b), 200
    end
    return a
end

local LIVE = fixture("listing_kindle_hot.json")

describe("reddle_listing", function()

    describe("formatScore", function()
        it("leaves small numbers alone", function()
            assert_equal("0", Listing.formatScore(0))
            assert_equal("1", Listing.formatScore(1))
            assert_equal("999", Listing.formatScore(999))
        end)

        it("abbreviates thousands to fit a narrow column", function()
            assert_equal("1k", Listing.formatScore(1000))
            assert_equal("2.2k", Listing.formatScore(2203))
            assert_equal("9.9k", Listing.formatScore(9949))
            assert_equal("12k", Listing.formatScore(12000))
            assert_equal("999k", Listing.formatScore(999000))
        end)

        it("abbreviates millions", function()
            assert_equal("1m", Listing.formatScore(1000000))
            assert_equal("1.5m", Listing.formatScore(1500000))
        end)

        it("never exceeds four characters", function()
            for _, n in ipairs({ 0, 999, 1000, 2203, 9999, 12000, 999000, 1500000, 99000000 }) do
                assert_true(#Listing.formatScore(n) <= 4, n .. " -> " .. Listing.formatScore(n))
            end
        end)

        it("survives nil and junk", function()
            assert_equal("0", Listing.formatScore(nil))
            assert_equal("0", Listing.formatScore("banana"))
        end)
    end)

    describe("formatAge", function()
        local NOW = 1000000
        it("reads the way Reddit does", function()
            assert_equal("now", Listing.formatAge(NOW - 5, NOW))
            assert_equal("5m", Listing.formatAge(NOW - 300, NOW))
            assert_equal("3h", Listing.formatAge(NOW - 3 * 3600, NOW))
            assert_equal("2d", Listing.formatAge(NOW - 2 * 86400, NOW))
            assert_equal("3mo", Listing.formatAge(NOW - 95 * 86400, NOW))
            assert_equal("2y", Listing.formatAge(NOW - 800 * 86400, NOW))
        end)

        it("does not show a negative age when the clock is skewed", function()
            -- Kindles wake with a stale clock often enough to matter
            assert_equal("now", Listing.formatAge(NOW + 3600, NOW))
        end)
    end)

    describe("rowFor", function()
        local NOW = 1755300000

        it("puts the title first, then the byline after a dash", function()
            -- One line only: MenuItem strips newlines (menu.lua)
            local child = json.decode(LIVE).data.children[4]
            local row = Listing.rowFor(child, NOW)
            local title, byline = row.text:match("^(.-)  —  (.*)$")
            assert_equal("Finished my first book in 25+ years!", title)
            assert_match("^u/", byline)
            assert_match("130c", byline)
        end)

        it("never emits a newline, which Menu would silently swallow", function()
            for _, child in ipairs(json.decode(LIVE).data.children) do
                local row = Listing.rowFor(child, NOW)
                assert_false(row.text:find("\n") ~= nil, "row text contains a newline")
            end
        end)

        it("puts the score in the right-aligned column", function()
            local child = json.decode(LIVE).data.children[4]
            assert_equal("2.2k", Listing.rowFor(child, NOW).mandatory)
        end)

        it("flattens titles that contain newlines", function()
            local row = Listing.rowFor({ data = { title = "two\nlines  here", author = "a" } }, NOW)
            assert_match("^two lines here  —  ", row.text)
        end)

        it("shows the domain for link posts but not self posts", function()
            local link = Listing.rowFor({ data = {
                title = "t", author = "a", is_self = false, domain = "imgur.com" } }, NOW)
            assert_match("imgur%.com", link.text)

            local self_post = Listing.rowFor({ data = {
                title = "t", author = "a", is_self = true, domain = "self.kindle" } }, NOW)
            assert_false(self_post.text:find("self%.kindle") ~= nil)
        end)

        it("marks pinned and NSFW posts", function()
            local row = Listing.rowFor({ data = {
                title = "t", author = "a", stickied = true, over_18 = true } }, NOW)
            assert_match("pinned", row.text)
            assert_match("NSFW", row.text)
        end)

        it("handles deleted authors", function()
            assert_match("u/%[deleted%]", Listing.rowFor({ data = { title = "t" } }, NOW).text)
        end)

        it("carries the fullname needed for votes and comments", function()
            local child = json.decode(LIVE).data.children[1]
            local row = Listing.rowFor(child, NOW)
            assert_equal("t3_" .. child.data.id, row.fullname)
        end)
    end)

    describe("html rows", function()
        local NOW = 1755300000

        it("puts the title in an anchor and the byline in a quiet line below", function()
            local child = json.decode(LIVE).data.children[4]
            local html = Listing.htmlFor(child, NOW, 4)
            assert_match('<a href="reddle:post:4">Finished my first book in 25%+ years!</a>', html)
            assert_match('<span class="score">2%.2k</span> · u/', html)
            assert_match('class="post card"', html)
            assert_match("130c", html)
        end)

        it("marks a read post two ways, since either alone is missable", function()
            local child = { data = { id = "x", title = "T", author = "a", reddle_read = true } }
            local html = Listing.htmlFor(child, NOW, 1)
            -- Grey title (the visited-link idiom) and a trailing square.
            assert_match('class="post card read"', html)
            assert_match('<span class="readmark">', html)
        end)

        it("leaves an unread post unmarked", function()
            local html = Listing.htmlFor({ data = { id = "x", title = "T", author = "a" } }, NOW, 1)
            assert_equal('class="post card"', html:match('class="post card[^"]*"'))
            assert_true(html:find("readmark") == nil)
        end)

        it("uses a glyph the device can actually draw", function()
            -- U+25AA, the same U+25xx block as the comment fold triangles. A
            -- missing glyph draws as nothing at all here, so a marker from an
            -- unsupported block would be an invisible feature (§5.10).
            local html = Listing.htmlFor(
                { data = { id = "x", title = "T", author = "a", reddle_read = true } }, NOW, 1)
            assert_match("\226\150\170", html)
        end)

        it("says 'read' in the plain-text path, which has no colour to dim", function()
            local row = Listing.rowFor({ data = { id = "x", title = "T", author = "a",
                reddle_read = true } }, NOW)
            assert_match("read", row.text)
        end)

        it("round-trips the tap target", function()
            assert_equal(7, Listing.postIndexFromHref(Listing.postHref(7)))
        end)

        it("ignores hrefs that are not ours, so a post link cannot be spoofed", function()
            assert_nil(Listing.postIndexFromHref("https://example.com"))
            assert_nil(Listing.postIndexFromHref("reddle:post:"))
            assert_nil(Listing.postIndexFromHref("reddle:post:1x"))
            assert_nil(Listing.postIndexFromHref(nil))
        end)

        it("escapes a title carrying markup", function()
            local html = Listing.htmlFor({ data = { title = "<script>x</script>", author = "a" } }, NOW, 1)
            assert_false(html:find("<script>", 1, true) ~= nil)
            assert_match("&lt;script&gt;", html)
        end)

        it("resolves a tapped index back to the post", function()
            local l = Listing.new{ api = fakeApi{ LIVE }, subreddit = "kindle" }
            l:reload()
            assert_equal(json.decode(LIVE).data.children[2].data.id, l:postAt(2).id)
            assert_nil(l:postAt(99))
        end)

        it("says so when there is nothing to show", function()
            local l = Listing.new{ api = fakeApi{ '{"kind":"Listing","data":{"children":[]}}' },
                subreddit = "kindle" }
            l:reload()
            assert_match("Nothing here", l:bodyHtml())
        end)
    end)

    describe("sort and time window", function()
        it("sends a time window only for the sorts that take one", function()
            local api = fakeApi{ LIVE, LIVE }
            local l = Listing.new{ api = api, subreddit = "kindle", sort = "top", time = "week" }
            l:reload()
            assert_equal("week", api.calls[1].query.t)

            local plain = fakeApi{ LIVE }
            Listing.new{ api = plain, subreddit = "kindle", sort = "hot" }:reload()
            assert_nil(plain.calls[1].query.t, "hot has no time window")
        end)

        it("covers the windows Reddit accepts", function()
            assert_equal("hour", Listing.TIMES[1])
            assert_equal("all", Listing.TIMES[#Listing.TIMES])
            assert_equal(6, #Listing.TIMES)
        end)

        it("offers best on the front page only, since /r/x/best is not a listing", function()
            local front = table.concat(Listing.sortsFor(nil), ",")
            local sub = table.concat(Listing.sortsFor("kindle"), ",")
            assert_match("best", front)
            assert_false(sub:find("best", 1, true) ~= nil)
        end)

        it("shows the window in the title so the screen says what it is showing", function()
            local l = Listing.new{ api = fakeApi{}, subreddit = "kindle", sort = "top", time = "year" }
            assert_equal("r/kindle  ·  top · year", l:title())
        end)

        it("switching window refetches from the top", function()
            local api = fakeApi{ LIVE, LIVE }
            local l = Listing.new{ api = api, subreddit = "kindle", sort = "top" }
            l:reload()
            l:setTime("all")
            assert_equal("all", api.calls[2].query.t)
            assert_nil(api.calls[2].query.after)
            assert_equal(5, #l.posts)
        end)
    end)

    describe("search", function()
        it("targets the subreddit and restricts to it", function()
            local api = fakeApi{ LIVE }
            local l = Listing.new{ api = api, subreddit = "kindle", query = "oasis" }
            l:reload()
            assert_equal("/r/kindle/search", api.calls[1].path)
            assert_equal("oasis", api.calls[1].query.q)
            assert_equal(1, api.calls[1].query.restrict_sr)
            assert_equal("link", api.calls[1].query.type)
        end)

        it("searches everywhere with no subreddit", function()
            local api = fakeApi{ LIVE }
            Listing.new{ api = api, query = "oasis" }:reload()
            assert_equal("/search", api.calls[1].path)
            assert_nil(api.calls[1].query.restrict_sr)
        end)

        it("defaults to relevance, not the browse sort", function()
            local l = Listing.new{ api = fakeApi{}, query = "x" }
            assert_equal("relevance", l.sort)
            assert_true(l:isSearch())
        end)

        it("treats an empty query as no search at all", function()
            local l = Listing.new{ api = fakeApi{}, subreddit = "kindle", query = "" }
            assert_false(l:isSearch())
            assert_equal("/r/kindle/hot", l:path())
        end)

        it("names the query in the title", function()
            assert_equal("r/kindle  ·  “oasis”",
                Listing.new{ api = fakeApi{}, subreddit = "kindle", query = "oasis" }:title())
            assert_equal("all  ·  “oasis”", Listing.new{ api = fakeApi{}, query = "oasis" }:title())
        end)

        it("pages with the same cursor machinery", function()
            local api = fakeApi{ LIVE, LIVE }
            local l = Listing.new{ api = api, subreddit = "kindle", query = "oasis" }
            l:reload()
            l:loadMore()
            assert_equal(l.posts[1] and api.calls[2].query.after, api.calls[2].query.after)
            assert_equal("oasis", api.calls[2].query.q, "the query must ride along on page two")
            assert_equal(10, #l.posts)
        end)
    end)

    describe("paths", function()
        it("targets a subreddit and sort", function()
            local l = Listing.new{ api = fakeApi{}, subreddit = "kindle", sort = "top" }
            assert_equal("/r/kindle/top", l:path())
        end)

        it("falls back to the front page with no subreddit", function()
            assert_equal("/hot", Listing.new{ api = fakeApi{} }:path())
        end)

        it("titles itself for the screen header", function()
            assert_equal("r/kindle  ·  hot", Listing.new{ api = fakeApi{}, subreddit = "kindle" }:title())
            assert_equal("Front page  ·  hot", Listing.new{ api = fakeApi{} }:title())
        end)
    end)

    describe("loading", function()
        it("loads the live fixture into rows", function()
            local l = Listing.new{ api = fakeApi{ LIVE }, subreddit = "kindle" }
            assert_true(l:reload())
            assert_equal(5, #l.posts)
            assert_equal(5, #l:rows())
            assert_false(l:isEmpty())
        end)

        it("asks for the page size and no cursor on the first page", function()
            local api = fakeApi{ LIVE }
            Listing.new{ api = api, subreddit = "kindle", limit = 25 }:reload()
            assert_equal(25, api.calls[1].query.limit)
            assert_nil(api.calls[1].query.after)
        end)

        it("passes the cursor on the next page and appends", function()
            local api = fakeApi{ LIVE, LIVE }
            local l = Listing.new{ api = api, subreddit = "kindle" }
            l:reload()
            local cursor = l.cursor
            assert_true(cursor ~= nil)
            l:loadMore()
            assert_equal(cursor, api.calls[2].query.after)
            assert_equal(10, #l.posts)
        end)

        it("stops when Reddit stops sending a cursor", function()
            local last = LIVE:gsub('"after": *"[^"]*"', '"after": null')
            local api = fakeApi{ last }
            local l = Listing.new{ api = api, subreddit = "kindle" }
            l:reload()
            assert_true(l.exhausted)
            l:loadMore() -- must not call the API again
            assert_equal(1, #api.calls)
        end)

        it("records the error and keeps what it already had", function()
            local api = fakeApi{ LIVE, { code = 503, err = "service unavailable" } }
            local l = Listing.new{ api = api, subreddit = "kindle" }
            l:reload()
            local ok, err = l:loadMore()
            assert_false(ok)
            assert_match("service unavailable", err)
            assert_equal(5, #l.posts) -- page one survives
        end)

        it("does not crash on a response that is not a listing", function()
            local l = Listing.new{ api = fakeApi{ '{"kind":"t2","data":{}}' }, subreddit = "kindle" }
            local ok, err = l:reload()
            assert_false(ok)
            assert_match("unexpected response shape", err)
            assert_true(l:isEmpty())
        end)

        it("ignores non-post children so ads or stubs cannot break a page", function()
            local mixed = '{"kind":"Listing","data":{"after":null,"children":[' ..
                '{"kind":"t3","data":{"id":"a","title":"real","author":"x"}},' ..
                '{"kind":"more","data":{"id":"b"}}]}}'
            local l = Listing.new{ api = fakeApi{ mixed }, subreddit = "kindle" }
            l:reload()
            assert_equal(1, #l.posts)
        end)

        it("reload discards the old page and starts from the top", function()
            local api = fakeApi{ LIVE, LIVE, LIVE }
            local l = Listing.new{ api = api, subreddit = "kindle" }
            l:reload(); l:loadMore()
            assert_equal(10, #l.posts)
            l:reload()
            assert_equal(5, #l.posts)
            assert_nil(api.calls[3].query.after)
        end)

        it("switching sort refetches from scratch", function()
            local api = fakeApi{ LIVE, LIVE }
            local l = Listing.new{ api = api, subreddit = "kindle" }
            l:reload()
            l:setSort("top")
            assert_equal("top", l.sort)
            assert_equal("/r/kindle/top", api.calls[2].path)
            assert_equal(5, #l.posts)
        end)
    end)
end)
