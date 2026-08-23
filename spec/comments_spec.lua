--[[
Comment tree flattening. spec/fixtures/comments_kindle.json was captured live on
2026-08-15: 6 top-level comments, nesting to depth 4, and 5 `more` stubs.
--]]

local Comments = require("reddle_comments")
local json = require("spec.support.json")

local function fixture()
    local root = arg[0]:match("(.*)/spec/run%.lua") or "."
    local f = assert(io.open(root .. "/spec/fixtures/comments_kindle.json", "r"))
    local body = f:read("*a"); f:close()
    return json.decode(body)
end

local NOW = 1755400000
local LIVE = fixture()

local function kinds(rows)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.kind end
    return table.concat(out, ",")
end

describe("reddle_comments", function()

    describe("parse", function()
        it("flattens the live tree into depth-tagged rows", function()
            local rows = Comments.parse(LIVE, { now = NOW })
            assert_true(#rows > 6, "expected more rows than top-level comments, got " .. #rows)
            local depths = {}
            for _, r in ipairs(rows) do depths[r.depth] = true end
            assert_true(depths[0], "no top-level rows")
            assert_true(depths[1], "no nested rows")
        end)

        it("returns the post alongside the comments", function()
            local _, post = Comments.parse(LIVE, { now = NOW })
            assert_true(post ~= nil)
            assert_match("Open Serif", post.title)
        end)

        it("keeps replies directly after their parent", function()
            local rows = Comments.parse(LIVE, { now = NOW })
            -- the first row is top level; the row after it is its first reply
            assert_equal(0, rows[1].depth)
            assert_equal("comment", rows[1].kind)
            assert_equal(1, rows[2].depth)
        end)

        it("converts bodies through the markdown subset", function()
            local rows = Comments.parse(LIVE, { now = NOW })
            for _, r in ipairs(rows) do
                if r.kind == "comment" then
                    assert_false(r.body:find("&amp;") ~= nil, "undecoded entity in body")
                end
            end
        end)

        it("carries the fullname needed for voting later", function()
            local rows = Comments.parse(LIVE, { now = NOW })
            assert_match("^t1_", rows[1].fullname)
        end)

        it("keeps the more stubs Reddit sent", function()
            local rows = Comments.parse(LIVE, { now = NOW })
            local more = 0
            for _, r in ipairs(rows) do if r.kind == "more" then more = more + 1 end end
            assert_true(more > 0, "fixture has 5 more-stubs; none survived")
        end)

        it("survives junk instead of a response", function()
            assert_equal(0, #Comments.parse(nil))
            assert_equal(0, #Comments.parse({}))
            assert_equal(0, #Comments.parse("nope"))
            assert_equal(0, #Comments.parse({ {}, { data = {} } }))
        end)
    end)

    describe("depth cap", function()
        local function deepTree(levels)
            local function node(d)
                local child = d < levels and {
                    kind = "Listing", data = { children = { node(d + 1) } } } or ""
                return { kind = "t1", data = {
                    id = "c" .. d, author = "u" .. d, body = "level " .. d,
                    score = d, created_utc = NOW, replies = child } }
            end
            return { { data = { children = {} } },
                     { kind = "Listing", data = { children = { node(0) } } } }
        end

        it("indents down to the cap", function()
            local rows = Comments.parse(deepTree(3), { now = NOW, max_depth = 4 })
            assert_equal("comment,comment,comment,comment", kinds(rows))
            assert_equal(3, rows[4].depth)
        end)

        it("replaces everything past the cap with one continue row", function()
            local rows = Comments.parse(deepTree(8), { now = NOW, max_depth = 2 })
            assert_equal("comment,comment,comment,continue", kinds(rows))
            assert_equal(2, rows[4].depth, "the continue row sits at the cap, not beyond it")
        end)

        it("defaults to the depth in DESIGN §5.2", function()
            assert_equal(4, Comments.MAX_DEPTH)
            local rows = Comments.parse(deepTree(9), { now = NOW })
            for _, r in ipairs(rows) do
                assert_true(r.depth <= 4, "row deeper than the cap: " .. r.depth)
            end
        end)
    end)

    describe("rowText", function()
        it("puts the byline first, then the body, on one line", function()
            local text = Comments.rowText{
                kind = "comment", depth = 0, author = "someone", score = 42,
                age = "3h", body = "first line\nsecond line",
            }
            assert_match("^u/someone · 42 · 3h", text)
            assert_match("first line second line", text)
            assert_false(text:find("\n") ~= nil, "Menu strips newlines; do not emit them")
        end)

        it("indents nested comments", function()
            local text = Comments.rowText{
                kind = "comment", depth = 2, author = "x", score = 1, age = "1h", body = "hi",
            }
            assert_match("^    u/x", text)
        end)

        it("truncates long bodies to the preview length", function()
            local text = Comments.rowText({
                kind = "comment", depth = 0, author = "x", score = 1, age = "1h",
                body = "a\nb\nc\nd\ne\nf\ng",
            }, 3)
            assert_match("…", text)
            assert_false(text:find("\n") ~= nil)
        end)

        it("counts replies on a more row", function()
            assert_match("↳ 7 more replies",
                Comments.rowText{ kind = "more", depth = 1, count = 7 })
            assert_match("↳ 1 more reply",
                Comments.rowText{ kind = "more", depth = 1, count = 1 })
        end)

        it("labels a zero-count more as a thread continuation", function()
            assert_match("continue thread", Comments.rowText{ kind = "more", depth = 1, count = 0 })
            assert_match("continue thread", Comments.rowText{ kind = "continue", depth = 4 })
        end)

        it("shows ? rather than nil for a hidden score", function()
            assert_match("u/x · %? · 1h",
                Comments.rowText{ kind = "comment", depth = 0, author = "x", age = "1h", body = "" })
        end)
    end)

    describe("toItems", function()
        it("marks non-comment rows as actionable", function()
            local items = Comments.toItems{
                { kind = "comment", depth = 0, author = "a", score = 1, age = "1h", body = "x" },
                { kind = "more", depth = 1, count = 3 },
            }
            assert_nil(items[1].mandatory)
            assert_equal("›", items[2].mandatory)
            assert_equal("more", items[2].row.kind)
        end)
    end)

    describe("spliceMore", function()
        local function moreFixture()
            local root = arg[0]:match("(.*)/spec/run%.lua") or "."
            local f = assert(io.open(root .. "/spec/fixtures/morechildren.json", "r"))
            local b = f:read("*a"); f:close()
            return json.decode(b).json.data.things
        end

        it("replaces the more row rather than duplicating it", function()
            local rows = {
                { kind = "comment", depth = 0, author = "a", body = "x" },
                { kind = "more", depth = 1, count = 1, children = { "p3tdbbv" } },
            }
            local n = Comments.spliceMore(rows, 2, moreFixture())
            assert_true(n > 0)
            assert_equal(1 + n, #rows)
            for _, r in ipairs(rows) do
                assert_true(r.kind ~= "more", "the more row should be gone")
            end
        end)

        it("uses Reddit's absolute depth for the spliced comment", function()
            local rows = { { kind = "more", depth = 1, children = { "x" } } }
            Comments.spliceMore(rows, 1, moreFixture())
            -- the fixture's thing carries depth 1
            assert_equal(1, rows[1].depth)
        end)

        it("keeps nested replies indented instead of flattening the branch", function()
            -- one thing at absolute depth 1, carrying two levels of its own replies
            local function reply(id, child)
                return { kind = "t1", data = {
                    id = id, author = id, body = id, created_utc = NOW,
                    replies = child and { kind = "Listing", data = { children = { child } } } or "",
                } }
            end
            local grandchild = reply("c", nil)
            local child = reply("b", grandchild)
            local thing = reply("a", child)
            thing.data.depth = 1

            local rows = { { kind = "more", depth = 1, children = { "a" } } }
            Comments.spliceMore(rows, 1, { thing }, { now = NOW })
            assert_equal(3, #rows)
            assert_equal(1, rows[1].depth)
            assert_equal(2, rows[2].depth, "reply should sit one level deeper, not flat")
            assert_equal(3, rows[3].depth, "and its reply one deeper again")
        end)

        it("never indents past the cap", function()
            local things = { { kind = "t1", data = {
                id = "a", author = "a", body = "a", depth = 9, created_utc = NOW, replies = "" } } }
            local rows = { { kind = "more", depth = 4, children = { "a" } } }
            Comments.spliceMore(rows, 1, things, { now = NOW, max_depth = 4 })
            assert_equal(4, rows[1].depth)
        end)

        it("falls back to the stub's depth when Reddit omits one", function()
            local things = { { kind = "t1", data = {
                id = "a", author = "a", body = "a", created_utc = NOW, replies = "" } } }
            local rows = { { kind = "more", depth = 2, children = { "a" } } }
            Comments.spliceMore(rows, 1, things, { now = NOW })
            assert_equal(2, rows[1].depth)
        end)

        it("handles an empty things list without corrupting the list", function()
            local rows = { { kind = "comment", depth = 0, author = "a", body = "x" },
                           { kind = "more", depth = 1, children = { "a" } } }
            assert_equal(0, Comments.spliceMore(rows, 2, {}))
            assert_equal(1, #rows)
        end)
    end)

    describe("moreChildrenBody", function()
        it("builds the morechildren payload", function()
            local body, n = Comments.moreChildrenBody("t3_abc",
                { kind = "more", children = { "a", "b", "c" } })
            assert_equal("t3_abc", body.link_id)
            assert_equal("a,b,c", body.children)
            assert_equal("json", body.api_type)
            assert_equal(3, n)
        end)

        it("respects a limit, since Reddit caps ids per call", function()
            local body, n = Comments.moreChildrenBody("t3_abc",
                { children = { "a", "b", "c", "d" } }, 2)
            assert_equal("a,b", body.children)
            assert_equal(2, n)
        end)
    end)
end)

describe("reddle_comments document view", function()
    local rows = Comments.parse(LIVE, { now = NOW })

    describe("toHtml", function()
        it("indents each depth with its own class and margin", function()
            local doc = Comments.toHtml(rows)
            assert_match('class="c d0"', doc)
            assert_match('class="c d1"', doc)
            assert_match("%.d1 { margin%-left: 1%.1em;", doc)
            assert_match("%.d2 { margin%-left: 2%.2em;", doc)
        end)

        it("draws a rule down the left of replies but not top-level comments", function()
            local doc = Comments.toHtml(rows)
            assert_match("%.d1 [^\n]*border%-left", doc)
            -- d0 gets a hairline *above* it instead: a separator between
            -- conversations, without boxing every reply.
            assert_match("%.d0 {[^\n]*border%-top", doc)
            assert_false(doc:find(".d0 { margin-left: 0; border-left", 1, true) ~= nil)
        end)

        -- The device regression of 2026-08-16: the whole thread rendered flat,
        -- because our stylesheet was nested where MuPDF ignores it. Class-based
        -- rules alone are therefore not enough to claim threading works.
        it("indents inline as well as by class, so threading survives a dropped stylesheet", function()
            local doc = Comments.toHtml(rows)
            assert_match('style="margin%-left: 1%.1em; border%-left', doc)
            assert_match('style="margin%-left: 2%.2em; border%-left', doc)
        end)

        it("leaves top-level comments unindented inline", function()
            local doc = Comments.toHtml{ { kind = "comment", depth = 0, author = "a",
                score = 1, age = "1h", body = "top" } }
            assert_match('class="c d0" style=""', doc)
        end)

        it("indents more stubs inline too, so a branch does not appear to end", function()
            local doc = Comments.toHtml{ { kind = "more", depth = 2, count = 3, children = { "a" } } }
            assert_match('style="margin%-left: 2%.2em;', doc)
        end)

        it("sets score and age apart from the username so the byline recedes", function()
            local doc = Comments.toHtml{ { kind = "comment", depth = 0, author = "abc",
                score = 12, age = "3h", body = "hi" } }
            assert_match('<span class="meta"> · 12 · 3h</span>', doc)
        end)

        it("carries the styling for that span in the sheet handed to the widget", function()
            -- Not in the body: MuPDF ignores a stylesheet found there (§5.2.2).
            local css = Comments.css()
            assert_match("%.meta {", css)
            assert_match("%.d1 {", css)
        end)

        it("marks the byline with a tag, not only a class", function()
            local doc = Comments.toHtml{ { kind = "comment", depth = 0, author = "abc",
                score = 1, age = "1h", body = "hi" } }
            assert_match("<b>u/abc</b>", doc)
        end)

        it("keeps whole comment bodies, not previews", function()
            local long = { { kind = "comment", depth = 0, author = "a", score = 1, age = "1h",
                body = "one\ntwo\nthree\nfour\nfive\nsix\nseven" } }
            local doc = Comments.toHtml(long)
            assert_match("seven", doc)
            assert_false(doc:find("…", 1, true) ~= nil, "document view must not truncate")
        end)

        it("renders Reddit's HTML for bodies that have it", function()
            local doc = Comments.toHtml{ { kind = "comment", depth = 0, author = "a",
                score = 1, age = "1h", body = "bold",
                body_html = "<div class=\"md\"><p><strong>bold</strong></p></div>" } }
            assert_match("<strong>bold</strong>", doc)
            assert_false(doc:find('class="md"', 1, true) ~= nil, "body must still be sanitised")
        end)

        it("escapes author names and scores rather than trusting them", function()
            local doc = Comments.toHtml{ { kind = "comment", depth = 0,
                author = "a<script>x</script>", score = 1, age = "1h", body = "hi" } }
            assert_false(doc:find("<script>", 1, true) ~= nil)
            assert_match("&lt;script&gt;", doc)
        end)

        it("labels more stubs instead of dropping them", function()
            local doc = Comments.toHtml{ { kind = "more", depth = 1, count = 7, children = { "a" } } }
            assert_match("7 more replies", doc)
        end)
    end)

    describe("toPlainText", function()
        it("indents by depth for builds that cannot render HTML", function()
            local text = Comments.toPlainText{
                { kind = "comment", depth = 0, author = "a", score = 1, age = "1h", body = "top" },
                { kind = "comment", depth = 2, author = "b", score = 2, age = "2h", body = "nested" },
            }
            assert_match("\nu/a", "\n" .. text)
            assert_match("    u/b", text)
            assert_match("    nested", text)
        end)

        it("keeps whole bodies", function()
            local text = Comments.toPlainText{ { kind = "comment", depth = 0, author = "a",
                score = 1, age = "1h", body = "one\ntwo\nthree\nfour\nfive" } }
            assert_match("five", text)
        end)
    end)

    describe("pendingStubs", function()
        it("finds the stubs that can actually be expanded", function()
            local stubs = Comments.pendingStubs{
                { kind = "comment", depth = 0 },
                { kind = "more", depth = 1, count = 3, children = { "a", "b" } },
                { kind = "more", depth = 1, count = 0, children = {} },   -- nothing to fetch
            }
            assert_equal(1, #stubs)
            assert_equal(2, stubs[1].index)
        end)

        it("is empty once everything is expanded", function()
            assert_equal(0, #Comments.pendingStubs{ { kind = "comment", depth = 0 } })
        end)
    end)
end)

--[[
Taps (§5.9). Everything the reader can do inside a thread without a button is an
anchor in this markup, so the hrefs are as much a contract as the text is.
--]]
describe("reddle_comments tap targets", function()
    local TREE = {
        { kind = "comment", depth = 0, id = "a", author = "alice", score = 12, age = "3h", body = "top" },
        { kind = "comment", depth = 1, id = "b", author = "bob", score = 4, age = "2h", body = "reply" },
        { kind = "comment", depth = 2, id = "c", author = "carol", score = 1, age = "1h", body = "deep" },
        { kind = "comment", depth = 0, id = "d", author = "dan", score = 7, age = "5h", body = "second top" },
    }

    describe("bylines", function()
        it("makes the whole byline a fold control", function()
            local html = Comments.bodyHtml(TREE)
            assert_match('<a href="reddle:collapse:a">', html)
            assert_match("u/alice", html)
        end)

        -- Underlining every byline would say "link" on every line and so say
        -- nothing. A disclosure triangle says "this folds", and doubles as the
        -- open/closed state. Both glyphs are in the range the device draws (§5.10).
        it("shows a disclosure triangle so the control is discoverable at all", function()
            assert_match("▾", Comments.bodyHtml(TREE))
        end)

        it("turns the triangle when the comment is folded", function()
            local html = Comments.bodyHtml(TREE, { collapsed = { a = true } })
            assert_match("▸", html)
            assert_match("%+3", html, "and still says how much is hidden")
        end)

        it("leaves a byline with no id alone rather than minting a dead link", function()
            local html = Comments.bodyHtml{
                { kind = "comment", depth = 0, author = "ghost", body = "x" } }
            assert_true(html:find("reddle:collapse", 1, true) == nil)
        end)
    end)

    describe("collapsing", function()
        it("hides the whole subtree, not just the comment", function()
            local html = Comments.bodyHtml(TREE, { collapsed = { a = true } })
            assert_match("u/alice", html)
            assert_true(html:find("u/bob", 1, true) == nil, "reply should be folded away")
            assert_true(html:find("u/carol", 1, true) == nil, "grandchild should be folded away")
            -- ...and stops at the next sibling, rather than eating the rest.
            assert_match("u/dan", html)
        end)

        it("drops the body of the comment it folded", function()
            local html = Comments.bodyHtml(TREE, { collapsed = { a = true } })
            assert_true(html:find(">top<", 1, true) == nil)
        end)

        it("says how much is hidden, counting the comment itself", function()
            local html = Comments.bodyHtml(TREE, { collapsed = { a = true } })
            assert_match("%+3", html)
        end)

        it("counts a subtree", function()
            assert_equal(2, Comments.subtreeSize(TREE, 1))
            assert_equal(1, Comments.subtreeSize(TREE, 2))
            assert_equal(0, Comments.subtreeSize(TREE, 4))
        end)

        it("folds only what was asked for", function()
            local html = Comments.bodyHtml(TREE, { collapsed = { b = true } })
            assert_match("u/alice", html)
            assert_match("u/bob", html)
            assert_true(html:find("u/carol", 1, true) == nil)
            assert_match("u/dan", html)
        end)
    end)

    describe("stubs", function()
        it("makes a loadable stub tappable, by id", function()
            local html = Comments.bodyHtml{
                { kind = "comment", depth = 0, id = "a", author = "alice", body = "x" },
                { kind = "more", depth = 1, id = "m1", count = 12, children = { "x", "y" } },
            }
            assert_match('<a href="reddle:more:m1">', html)
            assert_match("12 more replies", html)
        end)

        -- It used to read "use 'Load all replies'", which pointed at a button from
        -- text that looks exactly like something you would press.
        it("no longer tells the reader to press a button instead", function()
            local html = Comments.bodyHtml{
                { kind = "more", depth = 0, id = "m1", count = 3, children = { "x" } } }
            assert_true(html:find("Load all replies", 1, true) == nil)
        end)

        it("points a continue-thread row at the comment it stands in for", function()
            local html = Comments.bodyHtml{
                { kind = "continue", depth = 4, id = "deep" } }
            assert_match('<a href="reddle:continue:deep">', html)
        end)

        it("resolves reddit's anonymous continue stub to its nearest ancestor", function()
            local html = Comments.bodyHtml{
                { kind = "comment", depth = 0, id = "parent", author = "a", body = "x" },
                { kind = "comment", depth = 1, id = "child", author = "b", body = "y" },
                { kind = "more", depth = 2, id = "_", count = 0, children = {} },
            }
            assert_match('<a href="reddle:continue:child">', html)
        end)

        it("renders a stub it cannot target as text rather than a dead link", function()
            local html = Comments.bodyHtml{
                { kind = "more", depth = 0, id = "_", count = 0, children = {} } }
            assert_match("<i>↳ continue thread</i>", html)
        end)
    end)
end)

--[[
expandBranches: the one morechildren loop, shared by "Load all replies", saving
a thread for offline, and repairing a partial record. The ceiling is the point --
one tap must not be able to spend a shared rate limit.
--]]
describe("reddle_comments.expandBranches", function()
    local function stub(id, n)
        local children = {}
        for i = 1, n do children[i] = id .. i end
        return { kind = "more", depth = 1, id = id, children = children }
    end

    local function thing(id)
        return { kind = "t1", data = { id = id, author = "a", body = "b", depth = 1 } }
    end

    --- Answers with one comment per call, and records what was asked for.
    local function api(answers)
        local calls = {}
        return {
            calls = calls,
            get = function(_self, path, params)
                calls[#calls + 1] = { path = path, params = params }
                local a = answers and answers[#calls]
                if a == false then return nil end
                return { json = { data = { things = { thing("c" .. #calls) } } } }
            end,
        }
    end

    it("expands every branch when the ceiling allows", function()
        local rows = { stub("m1", 2), stub("m2", 2) }
        local a = api()
        local expanded, remaining = Comments.expandBranches(a, "t3_p", rows, { max = 10 })
        assert_equal(2, expanded)
        assert_equal(0, remaining)
        assert_equal(0, #Comments.pendingStubs(rows))
        assert_equal("/api/morechildren", a.calls[1].path)
        assert_equal("t3_p", a.calls[1].params.link_id)
    end)

    it("stops at the ceiling and reports what is left", function()
        local rows = { stub("m1", 1), stub("m2", 1), stub("m3", 1) }
        local a = api()
        local expanded, remaining = Comments.expandBranches(a, "t3_p", rows, { max = 2 })
        assert_equal(2, expanded)
        assert_equal(1, remaining)
        assert_equal(2, #a.calls, "must not request past the ceiling")
    end)

    it("gives up on the first failure rather than hammering a limit that said no", function()
        local rows = { stub("m1", 1), stub("m2", 1), stub("m3", 1) }
        local a = api({ [1] = false })
        local expanded, remaining = Comments.expandBranches(a, "t3_p", rows, { max = 10 })
        assert_equal(0, expanded)
        assert_equal(3, remaining)
        assert_equal(1, #a.calls)
    end)

    it("batches a large branch rather than asking for all of it", function()
        local rows = { stub("m1", Comments.MORE_BATCH + 25) }
        local a = api()
        Comments.expandBranches(a, "t3_p", rows, { max = 1 })
        local ids = {}
        for _ in a.calls[1].params.children:gmatch("[^,]+") do ids[#ids + 1] = 1 end
        assert_equal(Comments.MORE_BATCH, #ids)
    end)

    it("does nothing, and costs nothing, when the thread is already whole", function()
        local a = api()
        local expanded, remaining = Comments.expandBranches(
            a, "t3_p", { { kind = "comment", id = "c1" } }, { max = 10 })
        assert_equal(0, expanded)
        assert_equal(0, remaining)
        assert_equal(0, #a.calls)
    end)

    it("allows more requests for a save than for a tap", function()
        -- A tap is a browsing convenience; a save is a promise that the thread
        -- will still be there offline.
        assert_true(Comments.MAX_EXPANDS_SAVE > Comments.MAX_EXPANDS)
    end)
end)

--[[
The truncation this pins: moreChildrenBody asks for at most MORE_BATCH of a
stub's ids, but spliceMore removed the stub outright -- so a branch of 300 lost
260 replies and then reported itself complete, because the stub that recorded
their existence was gone.
--]]
describe("reddle_comments large branches", function()
    local function stub(n)
        local children = {}
        for i = 1, n do children[i] = "id" .. i end
        return { kind = "more", depth = 1, id = "m1", count = n, children = children }
    end

    local function things(n)
        local out = {}
        for i = 1, n do
            out[i] = { kind = "t1", data = { id = "c" .. i, author = "a", body = "b", depth = 1 } }
        end
        return out
    end

    it("keeps the ids it did not ask for", function()
        local rows = { stub(100) }
        Comments.spliceMore(rows, 1, things(40), { consumed = 40 })
        local left = Comments.pendingStubs(rows)
        assert_equal(1, #left, "the unrequested ids must stay as a stub")
        assert_equal(60, #left[1].row.children)
        -- count is hidden comments, not hidden ids: the stub said 100 replies,
        -- 40 arrived, so 60 is what is left to promise.
        assert_equal(60, left[1].row.count)
    end)

    it("removes the stub once every id has been consumed", function()
        local rows = { stub(40) }
        Comments.spliceMore(rows, 1, things(40), { consumed = 40 })
        assert_equal(0, #Comments.pendingStubs(rows))
    end)

    it("prices a large branch as the several requests it is", function()
        -- One branch, but not one call. The number on the save button is a
        -- promise about what it is about to spend.
        assert_equal(1, Comments.pendingRequests({ stub(40) }))
        assert_equal(2, Comments.pendingRequests({ stub(41) }))
        assert_equal(8, Comments.pendingRequests({ stub(300) }))
        assert_equal(0, Comments.pendingRequests({ { kind = "comment" } }))
    end)

    it("walks a large branch across several requests instead of dropping it", function()
        local rows = { stub(100) }
        local calls = 0
        local api = { get = function()
            calls = calls + 1
            return { json = { data = { things = things(40) } } }
        end }
        local expanded, remaining = Comments.expandBranches(api, "t3_p", rows, { max = 10 })
        assert_equal(3, expanded, "100 ids at 40 per call is three calls")
        assert_equal(0, remaining)
        assert_equal(0, #Comments.pendingStubs(rows))
        assert_equal(3, calls)
    end)
end)

describe("reddle_comments leftover stub count", function()
    it("counts hidden comments, not the ids that stand for them", function()
        -- A branch of 40 ids can represent hundreds of replies, so the stub's
        -- own count is the better number to carry forward -- it is what the
        -- reader reads to decide whether tapping again is worth it.
        local rows = { { kind = "more", depth = 1, id = "m", count = 500,
                         children = { "a", "b", "c" } } }
        Comments.spliceMore(rows, 1, {
            { kind = "t1", data = { id = "c1", author = "a", body = "b", depth = 1 } },
        }, { consumed = 1 })
        local left = Comments.pendingStubs(rows)
        assert_equal(2, #left[1].row.children)
        assert_equal(499, left[1].row.count, "500 hidden, one arrived")
    end)

    it("never claims fewer comments than it has ids for", function()
        local rows = { { kind = "more", depth = 1, id = "m", count = 2,
                         children = { "a", "b", "c", "d" } } }
        Comments.spliceMore(rows, 1, {}, { consumed = 1 })
        assert_equal(3, Comments.pendingStubs(rows)[1].row.count)
    end)
end)
