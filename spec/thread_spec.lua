--[[
reddle_ui_thread.lua -- post and comments composed into one document (§5.6).

The interesting cases are the joins: that the post survives a failed comment
fetch, that the comment stylesheet still governs the post half, and that nothing
from Reddit crosses into the document unsanitised just because it is now being
concatenated with markup we wrote.
--]]

local ui_fakes = require("spec.support.ui_fakes")
local rec = ui_fakes.install()

local Thread = require("reddle_ui_thread")
local Comments = require("reddle_comments")
local json = require("spec.support.json")

local POST = {
    id = "abc", title = "The Title", author = "op", subreddit = "kindle",
    score = 101, num_comments = 80, is_self = true,
    selftext = "post body", selftext_html = "<div class=\"md\"><p>post body</p></div>",
}

local ROWS = {
    { kind = "comment", depth = 0, author = "alice", score = 12, age = "3h", body = "first" },
    { kind = "comment", depth = 1, author = "bob", score = 4, age = "2h", body = "reply" },
}

local function fakeApi(res, code, err)
    return { get = function() return res, code, err end }
end

describe("reddle_ui_thread", function()

    describe("documentHtml", function()
        it("puts the post above the comments in one document", function()
            local doc = Thread.documentHtml(POST, ROWS, "3h")
            assert_match("<b>The Title</b>", doc)
            assert_match("<p>post body</p>", doc)
            assert_match("u/alice", doc)
            assert_true(doc:find("The Title", 1, true) < doc:find("u/alice", 1, true),
                "the post must come first")
        end)

        it("keeps inline thread indentation in the document", function()
            local doc = Thread.documentHtml(POST, ROWS, "3h")
            assert_match('style="margin%-left: 1%.1em', doc)
            assert_false(doc:find("<style", 1, true) ~= nil,
                "the stylesheet belongs in HtmlBoxWidget, not inside its body")
        end)

        it("says so plainly when a post has no comments", function()
            local doc = Thread.documentHtml(POST, {}, "3h")
            assert_match("No comments yet", doc)
            assert_match("<b>The Title</b>", doc)
        end)

        it("sanitises Reddit's markup even though we compose around it", function()
            local nasty = {}
            for k, v in pairs(POST) do nasty[k] = v end
            nasty.selftext_html = '<div class="md"><script>evil()</script><p>ok</p></div>'
            local doc = Thread.documentHtml(nasty, {
                { kind = "comment", depth = 0, author = "x", score = 1, age = "1h",
                  body = "c", body_html = "<p onclick=\"evil()\">c</p>" },
            }, "3h")
            assert_false(doc:find("<script", 1, true) ~= nil)
            assert_false(doc:find("onclick", 1, true) ~= nil)
            assert_false(doc:find('class="md"', 1, true) ~= nil)
        end)

        it("escapes a title that carries markup", function()
            local nasty = {}
            for k, v in pairs(POST) do nasty[k] = v end
            nasty.title = "<script>x</script>"
            assert_match("&lt;script&gt;", Thread.documentHtml(nasty, ROWS, "3h"))
        end)
    end)

    describe("documentText", function()
        it("carries both halves for builds that cannot render HTML", function()
            local text = Thread.documentText(POST, ROWS, "3h")
            assert_match("The Title", text)
            assert_match("u/alice", text)
            assert_match("  u/bob", text)  -- indent survives
        end)
    end)

    describe("loading", function()
        it("shows the post even when the comment fetch fails", function()
            -- Losing the thread should not cost the reader the post they tapped.
            local view = Thread.open{ api = fakeApi(nil, 503, "service unavailable"),
                post = POST, subreddit = "kindle", age = "3h" }
            assert_equal(0, #view.rows)
            assert_true(view.viewer ~= nil, "a viewer must still be shown")
            assert_match("The Title", view.viewer.text)
            assert_match("service unavailable",
                ui_fakes.lastShown(rec, "InfoMessage").text or "")
        end)

        it("renders the thread when the fetch works", function()
            local body = json.decode([[
              [{"kind":"Listing","data":{"children":[]}},
               {"kind":"Listing","data":{"children":[
                 {"kind":"t1","data":{"id":"c1","author":"alice","body":"first",
                  "score":12,"created_utc":0,"depth":0,"replies":""}}]}}]
            ]])
            local view = Thread.open{ api = fakeApi(body, 200), post = POST,
                subreddit = "kindle", age = "3h" }
            assert_equal(1, #view.rows)
            assert_match("u/alice", view.viewer.text)
        end)

        it("hands the widget the stylesheet rather than burying it in the body", function()
            local view = Thread.open{ api = fakeApi(nil, 503, "nope"), post = POST,
                subreddit = "kindle", age = "3h" }
            local css = view.viewer.reddle_css
            assert_match("%.d1 {", css, "comment indent rules missing")
            assert_match("%.card {", css, "the card box is in Html.CSS")
        end)

        it("boxes the post so the thread visibly begins after it", function()
            local doc = Thread.documentHtml(POST, ROWS, "3h")
            assert_match('<div class="card postcard">', doc)
            -- the old <hr/> between post and comments read as a comment separator
            assert_false(doc:find("<hr/>", 1, true) ~= nil)
        end)
    end)

    describe("buttons", function()
        it("offers no button row for a plain text post with no more stubs", function()
            local view = Thread.open{ api = fakeApi(nil, 503, "nope"), post = POST,
                subreddit = "kindle", age = "3h" }
            assert_nil(view.viewer.buttons_table)
        end)

        it("offers the image button only when there is an image", function()
            local img = {}
            for k, v in pairs(POST) do img[k] = v end
            img.is_self, img.url = false, "https://i.redd.it/x.jpg"
            local view = Thread.open{ api = fakeApi(nil, 503, "nope"), post = img,
                subreddit = "kindle", age = "3h" }
            assert_match("Image", view.viewer.buttons_table[1][1].text)
        end)
    end)
end)

--[[
Taps inside a thread (§5.9). The bug this guards: reddle_ui_thread rendered a
document full of anchors and never passed on_link, so every link in every post
and comment -- Reddit's and ours -- was inert.
--]]
describe("reddle_ui_thread taps", function()
    local function openView()
        return Thread.open{ api = fakeApi(nil, 503, "nope"), post = POST,
            subreddit = "kindle", age = "3h" }
    end

    it("gives the viewer a link handler at all", function()
        assert_true(type(openView().viewer.on_link) == "function")
    end)

    it("folds a comment and holds the reader's place", function()
        local view = openView()
        view.rows = {
            { kind = "comment", depth = 0, id = "a", author = "alice", body = "x" },
            { kind = "comment", depth = 1, id = "b", author = "bob", body = "y" },
        }
        view.viewer.setDocument = function(self, html, opts)
            self.last_html, self.last_opts = html, opts
        end
        Thread.onLink(view, "reddle:collapse:a")
        assert_true(view.collapsed.a)
        assert_true(view.viewer.last_opts.keep_position)
        assert_true(view.viewer.last_html:find("u/bob", 1, true) == nil)
    end)

    it("unfolds on a second tap, rather than folding harder", function()
        local view = openView()
        view.rows = { { kind = "comment", depth = 0, id = "a", author = "alice", body = "x" } }
        view.viewer.setDocument = function() end
        Thread.onLink(view, "reddle:collapse:a")
        Thread.onLink(view, "reddle:collapse:a")
        assert_nil(view.collapsed.a)
    end)

    it("expands one stub rather than all of them", function()
        local calls = {}
        local view = Thread.open{
            api = { get = function(_, path, params)
                calls[#calls + 1] = { path = path, params = params }
                return { json = { data = { things = {} } } }
            end },
            post = POST, subreddit = "kindle", age = "3h",
        }
        view.rows = {
            { kind = "comment", depth = 0, id = "a", author = "alice", body = "x" },
            { kind = "more", depth = 1, id = "m1", count = 2, children = { "p", "q" } },
        }
        view.viewer.setDocument = function() end
        local before = #calls
        Thread.onLink(view, "reddle:more:m1")
        assert_equal(before + 1, #calls)
        assert_equal("/api/morechildren", calls[#calls].path)
        assert_equal("p,q", calls[#calls].params.children)
    end)

    it("says so when a stub has nothing left to fetch", function()
        local view = openView()
        view.rows = { { kind = "more", depth = 0, id = "m1", count = 0, children = {} } }
        Thread.onLink(view, "reddle:more:m1")
        assert_match("Nothing more to load", rec.shown[#rec.shown].text)
    end)

    it("re-roots the thread at a comment for continue-thread", function()
        local asked
        local view = Thread.open{
            api = { get = function(_, path, params) asked = params; return nil, 503, "x" end },
            post = POST, subreddit = "kindle", age = "3h",
        }
        Thread.onLink(view, "reddle:continue:deep")
        assert_equal("deep", asked.comment)
        assert_equal(0, asked.context)
    end)

    it("hands a link from inside a comment body to the router", function()
        local view = openView()
        Thread.onLink(view, "https://example.com/x")
        assert_equal("ButtonDialog", rec.shown[#rec.shown].widget_kind)
    end)
end)

describe("reddle_ui_thread.openById", function()
    it("asks for a post without needing to know its subreddit", function()
        local asked
        Thread.openById{
            api = { get = function(_, path) asked = path; return nil, 503, "x" end },
            id = "abc123",
        }
        assert_equal("/comments/abc123", asked)
    end)

    it("takes the post out of the response, since there is no other copy", function()
        local res = {
            { data = { children = { { kind = "t3", data = {
                id = "abc123", title = "Linked", subreddit = "koreader",
                author = "op", score = 5, num_comments = 0, is_self = true,
                selftext = "body", created_utc = os.time(),
            } } } } },
            { data = { children = {} } },
        }
        local view = Thread.openById{ api = fakeApi(res), id = "abc123" }
        assert_equal("Linked", view.post.title)
        assert_equal("koreader", view.subreddit)
        assert_match("Linked", view.viewer.text)
    end)
end)

--[[
The failure the id-keyed hrefs exist to prevent: expanding one stub splices its
replies into `rows` in place of it, which moves every stub below. A position
minted into an earlier document would then name a different branch.
--]]
describe("reddle_ui_thread stale stubs", function()
    local function thingsFor(n)
        local things = {}
        for i = 1, n do
            things[i] = { kind = "t1", data = { id = "new" .. i, depth = 1,
                author = "new", body = "reply " .. i, score = 1, created_utc = os.time() } }
        end
        return { json = { data = { things = things } } }
    end

    it("expands the branch the reader tapped, not the one that moved into its place", function()
        local view = Thread.open{
            api = { get = function() return thingsFor(3) end },
            post = POST, subreddit = "kindle", age = "3h",
        }
        view.rows = {
            { kind = "comment", depth = 0, id = "a", author = "alice", body = "x" },
            { kind = "more", depth = 1, id = "first", count = 3, children = { "p" } },
            { kind = "comment", depth = 0, id = "b", author = "bob", body = "y" },
            { kind = "more", depth = 1, id = "second", count = 2, children = { "q" } },
        }
        view.viewer.setDocument = function() end

        Thread.onLink(view, "reddle:more:first")
        -- "second" now sits at index 6, not 4. Tapping it must still find it.
        Thread.onLink(view, "reddle:more:second")
        assert_nil(Comments.stubIndexById(view.rows, "second"),
            "the stub the reader tapped should be the one that got expanded")
        assert_nil(Comments.stubIndexById(view.rows, "first"))
    end)

    it("does nothing when a stub has already been expanded away", function()
        local view = Thread.open{ api = fakeApi(nil, 503, "x"), post = POST,
            subreddit = "kindle", age = "3h" }
        view.rows = { { kind = "comment", depth = 0, id = "a", author = "alice", body = "x" } }
        Thread.onLink(view, "reddle:more:gone")
        assert_match("Nothing more to load", rec.shown[#rec.shown].text)
    end)
end)

--[[
The save dialog. What it writes is whatever is in memory, and a thread arrives
capped -- so the question these pin is whether it says so.
--]]
describe("reddle_ui_saved.saveDialog", function()
    package.loaded["reddle_ui_saved"] = nil
    local Saved = require("reddle_ui_saved")

    local function store()
        return { isSaved = function() return false end,
                 save = function() return true end }
    end

    local function openWith(rows)
        Saved.saveDialog{ store = store(), post = POST, rows = rows }
        return ui_fakes.lastShown(rec, "ButtonDialog")
    end

    local function buttonTexts(dialog)
        local out = {}
        for _i, row in ipairs(dialog.buttons) do out[#out + 1] = row[1].text end
        return table.concat(out, "|")
    end

    it("gives a bare count when the whole thread is in memory", function()
        local dialog = openWith(ROWS)
        assert_match("Post and comments %(2%)", buttonTexts(dialog))
        assert_equal("Save for offline", dialog.title)
    end)

    it("says the count is only what loaded when branches are outstanding", function()
        -- A `more` stub is an unfetched branch. Saving here writes the slice,
        -- and the byline above says the post has 80 comments -- so "(2)" alone
        -- reads as the whole thread.
        local rows = { ROWS[1], ROWS[2],
            { kind = "more", depth = 1, id = "m1", children = { "x", "y", "z" } } }
        local dialog = openWith(rows)
        assert_match("Post and comments %(3 loaded%)", buttonTexts(dialog))
        assert_match("Only part of the thread is loaded", dialog.title)
    end)

    it("leads with completing the thread when there is an api to do it with", function()
        -- Saving for offline is a promise, and this is the only moment the
        -- reader is online. The price is on the button rather than hidden.
        local rows = { ROWS[1],
            { kind = "more", depth = 1, id = "m1", children = { "x" } },
            { kind = "more", depth = 1, id = "m2", children = { "y" } } }
        Saved.saveDialog{ store = store(), post = POST, rows = rows,
            api = fakeApi({ json = { data = { things = {} } } }) }
        local dialog = ui_fakes.lastShown(rec, "ButtonDialog")
        assert_equal("Post and all comments (~2 requests)", dialog.buttons[1][1].text)
        assert_equal("Post only", dialog.buttons[2][1].text)
    end)

    it("does not offer to complete a thread with no api, which is the saved case", function()
        local rows = { ROWS[1], { kind = "more", depth = 1, id = "m1", children = { "x" } } }
        local texts = buttonTexts(openWith(rows))
        assert_true(texts:find("all comments") == nil, texts)
    end)

    it("ignores a stub that has nothing left behind it", function()
        local rows = { ROWS[1], { kind = "more", depth = 1, id = "m1", children = {} } }
        local dialog = openWith(rows)
        assert_match("Post and comments %(2%)", buttonTexts(dialog))
        assert_equal("Save for offline", dialog.title)
    end)

    it("offers post-only and nothing else when no comments loaded", function()
        local texts = buttonTexts(openWith({}))
        assert_match("Post only", texts)
        assert_true(texts:find("Post and comments") == nil, texts)
    end)
end)

--[[
Saving an image the reader has already looked at must not download it twice:
viewing writes it to cache/reddle, and the radio is the slow part.
--]]
describe("reddle_ui_saved.fetchImage", function()
    package.loaded["reddle_ui_saved"] = nil
    local Saved = require("reddle_ui_saved")
    local Post = require("reddle_ui_post")

    it("reuses the viewed copy instead of fetching again", function()
        local cached, read = Post.cachedFile, Saved.readFile
        Post.cachedFile = function() return "/cache/x.jpg" end
        Saved.readFile = function() return "IMAGEBYTES" end
        local calls, stored = 0, nil
        local store = { saveImage = function(_s, _id, _url, body) stored = body; return true end }
        local done = 0
        Saved.fetchImage(store, "p1", "http://x/y.jpg",
            function() calls = calls + 1 end, function() done = done + 1 end)
        Post.cachedFile, Saved.readFile = cached, read
        assert_equal(0, calls, "must not hit the network")
        assert_equal("IMAGEBYTES", stored)
        assert_equal(1, done)
    end)

    it("downloads when nothing is cached", function()
        local cached = Post.cachedFile
        Post.cachedFile = function() return nil end
        local calls = 0
        local store = { saveImage = function() return true end }
        Saved.fetchImage(store, "p1", "http://x/y.jpg", function()
            calls = calls + 1
            return "FRESH", 200
        end)
        Post.cachedFile = cached
        assert_equal(1, calls)
    end)
end)

--[[
The offline save limit (Settings and about). The dialog must not quote a price
it will not pay, and zero has to mean "never fetch" rather than "unset".
--]]
describe("reddle_ui_saved budget", function()
    package.loaded["reddle_ui_saved"] = nil
    local Saved = require("reddle_ui_saved")
    local Comments2 = require("reddle_comments")

    local function store()
        return { isSaved = function() return false end, save = function() return true end }
    end

    local function stub(id, n)
        local children = {}
        for i = 1, n do children[i] = id .. i end
        return { kind = "more", depth = 1, id = id, children = children }
    end

    local function open(o)
        o.store, o.post = store(), POST
        Saved.saveDialog(o)
        return ui_fakes.lastShown(rec, "ButtonDialog")
    end

    local function texts(dialog)
        local out = {}
        for _i, row in ipairs(dialog.buttons) do out[#out + 1] = row[1].text end
        return table.concat(out, "|")
    end

    it("falls back to the ceiling when no caller threaded the setting through", function()
        assert_equal(Comments2.MAX_EXPANDS_SAVE, Saved.budget(nil))
        assert_equal(Comments2.MAX_EXPANDS_SAVE, Saved.budget({}))
        assert_equal(Comments2.MAX_EXPANDS_SAVE, Saved.budget({ save_expand_max = -1 }))
        assert_equal(0, Saved.budget({ save_expand_max = 0 }))
        assert_equal(4, Saved.budget({ save_expand_max = 4 }))
    end)

    it("does not offer to fetch anything when the limit is zero", function()
        local dialog = open{ rows = { ROWS[1], stub("m", 40) },
            api = fakeApi({}), save_expand_max = 0 }
        assert_true(texts(dialog):find("all comments") == nil, texts(dialog))
        assert_match("Post and comments %(2 loaded%)", texts(dialog))
    end)

    it("quotes the whole job when the limit covers it", function()
        local dialog = open{ rows = { stub("m", 80) }, api = fakeApi({}), save_expand_max = 25 }
        assert_match("Post and all comments %(~2 requests%)", texts(dialog))
    end)

    it("says how far it will get when the limit does not cover it", function()
        -- Quoting "~20 requests" and then stopping at 3 would be a lie about
        -- what the reader is going to end up with offline.
        local dialog = open{ rows = { stub("m", 800) }, api = fakeApi({}), save_expand_max = 3 }
        assert_match("Post and more comments %(3 of ~20 requests%)", texts(dialog))
    end)
end)

--[[
The leak this pins: transport was called with no headers at all for image
downloads, and "no headers" does not mean "no User-Agent" -- KOReader's
socketutil monkey-patches a global http.USERAGENT, so LuaSocket filled in
"KOReader/..." while every API call from the same device claimed to be another
app. Asserting the helper alone would not have caught it; these assert the call
sites.
--]]
describe("every request presents the same identity", function()
    package.loaded["reddle_ui_saved"] = nil
    package.loaded["reddle_ui_post"] = nil
    local Saved = require("reddle_ui_saved")
    local Post = require("reddle_ui_post")
    local Api = require("reddle_api")
    local Identity = require("reddle_identity")

    local function recorder()
        local seen = {}
        return seen, function(req) seen[#seen + 1] = req; return "BYTES", 200 end
    end

    it("sends it when an image is viewed", function()
        local seen, transport = recorder()
        Post.showImage("https://i.redd.it/x.jpg", transport)
        assert_equal(1, #seen)
        assert_equal(Identity.userAgent(), seen[1].headers["User-Agent"])
        assert_nil(seen[1].headers["Authorization"])
    end)

    it("sends it when an image is saved", function()
        local cached = Post.cachedFile
        Post.cachedFile = function() return nil end
        local seen, transport = recorder()
        Saved.fetchImage({ saveImage = function() return true end },
            "p1", "https://i.redd.it/y.jpg", transport)
        Post.cachedFile = cached
        assert_equal(1, #seen)
        assert_equal(Identity.userAgent(), seen[1].headers["User-Agent"])
    end)

    it("sends it when Fetch missing tops a record up", function()
        local seen, transport = recorder()
        Saved.fillOne({
            store = { saveImage = function() return true end },
            api = fakeApi(nil),
            transport = transport,
        }, { id = "p1", subreddit = "kindle", has_comments = true,
             num_comments = 0, image_url = "https://i.redd.it/z.jpg" })
        assert_equal(1, #seen)
        assert_equal(Identity.userAgent(), seen[1].headers["User-Agent"])
    end)

    it("uses the file timeouts, since an image is not a JSON response", function()
        local seen, transport = recorder()
        Post.showImage("https://i.redd.it/t.jpg", transport)
        assert_equal("file", seen[1].timeouts)
    end)
end)

--[[
Reopening a thread. Backing out by accident and going straight back in used to
cost a full /comments request every time.
--]]
describe("reddle_ui_thread caching", function()
    local Cache = require("reddle_cache")

    local BODY = json.decode([[
      [{"kind":"Listing","data":{"children":[
         {"kind":"t3","data":{"id":"abc","title":"T","author":"op",
          "subreddit":"kindle","created_utc":0}}]}},
       {"kind":"Listing","data":{"children":[
         {"kind":"t1","data":{"id":"c1","author":"alice","body":"first",
          "score":12,"created_utc":0,"depth":0,"replies":""}}]}}]
    ]])

    local function counting()
        local n = 0
        return { get = function() n = n + 1; return BODY, 200 end },
               function() return n end
    end

    local function open(api, cache)
        return Thread.open{ api = api, post = POST, subreddit = "kindle",
                            age = "3h", cache = cache }
    end

    it("does not ask twice for the same thread", function()
        local api, calls = counting()
        local cache = Cache.new{}
        open(api, cache)
        assert_equal(1, calls())
        local again = open(api, cache)
        assert_equal(1, calls(), "the second open must not hit the network")
        assert_equal(1, #again.rows)
    end)

    it("asks again once the entry has expired", function()
        local api, calls = counting()
        local at = 0
        local cache = Cache.new{ now = function() return at end, ttl = 100 }
        open(api, cache)
        at = 200
        open(api, cache)
        assert_equal(2, calls())
    end)

    it("keeps replies expanded after the fetch, so going back keeps them", function()
        -- Stored by reference: the rows the reader expanded are the rows in the
        -- cache, and coming back must not silently lose them.
        local api = counting()
        local cache = Cache.new{}
        local view = open(api, cache)
        view.rows[#view.rows + 1] = { kind = "comment", depth = 1, id = "later", body = "x" }
        assert_equal(2, #open(api, cache).rows)
    end)

    it("caches a re-rooted branch separately from the whole thread", function()
        -- Same post id, different document: /comments?comment=x is one branch.
        local whole = { post = { id = "abc" } }
        local branch = { post = { id = "abc" }, comment = "t1_x" }
        assert_true(Thread.cacheKey(whole) ~= Thread.cacheKey(branch))
    end)

    it("still works with no cache at all", function()
        local api, calls = counting()
        open(api, nil)
        open(api, nil)
        assert_equal(2, calls())
    end)

    it("does not cache a failed fetch", function()
        -- Otherwise a moment of bad Wi-Fi sticks an empty thread on screen for
        -- the next ten minutes.
        local cache = Cache.new{}
        Thread.open{ api = fakeApi(nil, 503, "nope"), post = POST,
                     subreddit = "kindle", age = "3h", cache = cache }
        assert_equal(0, cache:count())
    end)
end)
