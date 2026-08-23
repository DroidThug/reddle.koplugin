--[[
The archive's filesystem layer, driven against an in-memory filesystem so the
specs never write anything to disk.
--]]

local Store = require("reddle_store")
local Archive = require("reddle_archive")
local json = require("spec.support.json")

--- Minimal fake: files as a path -> string map, directories as a set.
local function fakeFS()
    local files, dirs = {}, { ["/a"] = true }
    local fs = { files = files, dirs = dirs, writes = 0 }

    fs.lfs = {
        attributes = function(path, what)
            if dirs[path] then return what == "mode" and "directory" or {} end
            if files[path] then return what == "mode" and "file" or {} end
            return nil
        end,
        mkdir = function(path) dirs[path] = true; return true end,
    }
    fs.io_open = function(path, mode)
        if mode == "rb" then
            local body = files[path]
            if not body then return nil end
            return { read = function() return body end, close = function() end }
        end
        local buf = {}
        return {
            write = function(_, s) buf[#buf + 1] = s; return true end,
            close = function() files[path] = table.concat(buf); fs.writes = fs.writes + 1 end,
        }
    end
    fs.os_remove = function(path) files[path] = nil; return true end
    fs.os_rename = function(from, to)
        if not files[from] then return nil, "no such file" end
        files[to], files[from] = files[from], nil
        return true
    end
    return fs
end

local function newStore(fs, now)
    return Store.new{
        root = "/a", lfs = fs.lfs, json = json, io_open = fs.io_open,
        os_remove = fs.os_remove, os_rename = fs.os_rename,
        now = function() return now or 100 end,
    }
end

local function post(over)
    local p = { id = "abc", subreddit = "kindle", title = "T", author = "alice",
                score = 5, num_comments = 3, created_utc = 900 }
    for k, v in pairs(over or {}) do p[k] = v end
    return p
end

describe("reddle_store", function()

    describe("save", function()
        it("keeps relative archive roots relative", function()
            local fs = fakeFS()
            local store = Store.new{
                root = "./settings/reddle_saved", lfs = fs.lfs, json = json,
                io_open = fs.io_open, os_remove = fs.os_remove, os_rename = fs.os_rename,
            }
            assert_true(store:save(post(), nil, {}))
            assert_true(fs.files["./settings/reddle_saved/posts/kindle/abc.json"] ~= nil)
            assert_true(fs.dirs["./settings"])
        end)

        it("writes the record and indexes it", function()
            local fs = fakeFS()
            local store = newStore(fs)
            assert_true(store:save(post(), nil, {}))
            assert_true(fs.files["/a/posts/kindle/abc.json"] ~= nil)
            assert_true(fs.files["/a/index.json"] ~= nil)
            assert_true(store:isSaved("abc"))
        end)

        it("creates the directories it needs", function()
            -- lfs.mkdir makes one level; the archive is three deep.
            local fs = fakeFS()
            newStore(fs):save(post(), nil, {})
            assert_true(fs.dirs["/a/posts"])
            assert_true(fs.dirs["/a/posts/kindle"])
        end)

        it("stores comments when given them", function()
            local fs = fakeFS()
            local store = newStore(fs)
            store:save(post(), { { kind = "comment", id = "c1", created_utc = 800 } }, {})
            local record = store:load("kindle", "abc")
            assert_equal(1, #record.comments)
            assert_equal(800, record.comments[1].created_utc)
            assert_true(Archive.find(store:readIndex(), "abc").has_comments)
        end)

        it("marks a post saved without comments as incomplete", function()
            local fs = fakeFS()
            local store = newStore(fs)
            store:save(post(), nil, {})
            assert_false(Archive.find(store:readIndex(), "abc").has_comments)
            assert_equal("comments", Archive.describeMissing(Archive.find(store:readIndex(), "abc")))
        end)

        it("refuses a post with no id instead of writing rubbish", function()
            local fs = fakeFS()
            assert_false(newStore(fs):save({}, nil, {}))
            assert_nil(fs.files["/a/index.json"])
        end)

        it("re-saving updates in place rather than duplicating", function()
            local fs = fakeFS()
            local store = newStore(fs)
            store:save(post(), nil, {})
            store:save(post{ title = "Changed" }, nil, {})
            assert_equal(1, #store:readIndex())
            assert_equal("Changed", store:readIndex()[1].title)
        end)

        it("re-saving without comments keeps the ones already on disk", function()
            -- Long-pressing a post in a listing saves the summary only. Doing
            -- that to a post already saved from its thread used to overwrite
            -- the record and delete the comments.
            local fs = fakeFS()
            local store = newStore(fs)
            store:save(post(), { { id = "c1", body = "hi" } }, {})
            store:save(post(), nil, {})
            assert_equal(1, #store:load("kindle", "abc").comments)
            assert_true(Archive.find(store:readIndex(), "abc").has_comments)
            assert_nil(Archive.describeMissing(Archive.find(store:readIndex(), "abc")))
        end)

        it("re-saving keeps an image that is already on disk", function()
            -- has_image was recomputed from an option no caller passes, so every
            -- re-save reported the image missing while the file was still there.
            local fs = fakeFS()
            local store = newStore(fs)
            store:save(post(), nil, { image_url = "http://x/y.jpg" })
            store:saveImage("abc", "http://x/y.jpg", "bytes")
            store:save(post(), nil, {})
            local summary = Archive.find(store:readIndex(), "abc")
            assert_true(summary.has_image)
            assert_equal("http://x/y.jpg", summary.image_url)
            assert_true(store:imageFile("abc", summary.image_url) ~= nil)
        end)

        it("does not claim an image it never downloaded", function()
            local fs = fakeFS()
            local store = newStore(fs)
            store:save(post(), nil, { image_url = "http://x/y.jpg" })
            local summary = Archive.find(store:readIndex(), "abc")
            assert_false(summary.has_image)
            assert_equal("comments and image", Archive.describeMissing(summary))
        end)
    end)

    describe("durability", function()
        it("writes through a temp file and renames", function()
            -- A Kindle that sleeps mid-write must not be able to truncate the
            -- index: losing it loses every saved post at once.
            local fs = fakeFS()
            local seen = {}
            local real_rename = fs.os_rename
            fs.os_rename = function(from, to) seen[#seen + 1] = from; return real_rename(from, to) end
            newStore(fs):save(post(), nil, {})
            assert_true(#seen > 0, "nothing was renamed into place")
            for _, from in ipairs(seen) do assert_match("%.tmp$", from) end
        end)

        it("leaves no temp files behind", function()
            local fs = fakeFS()
            newStore(fs):save(post(), nil, {})
            for path in pairs(fs.files) do
                assert_true(path:find("%.tmp$") == nil, "leftover temp file: " .. path)
            end
        end)
    end)

    describe("load", function()
        it("returns nil for a post that was never saved", function()
            assert_nil(newStore(fakeFS()):load("kindle", "nope"))
        end)

        it("survives a corrupt record without throwing", function()
            local fs = fakeFS()
            fs.files["/a/posts/kindle/abc.json"] = "{not json"
            local record, err = newStore(fs):load("kindle", "abc")
            assert_nil(record)
            assert_match("unreadable", err)
        end)

        it("survives a corrupt index, since the records are still there", function()
            local fs = fakeFS()
            fs.files["/a/index.json"] = "]]garbage"
            local store = newStore(fs)
            assert_equal(0, #store:readIndex())
            assert_true(store:save(post(), nil, {}))
        end)
    end)

    describe("delete", function()
        it("removes the record, the index row and the image", function()
            local fs = fakeFS()
            local store = newStore(fs)
            store:save(post(), nil, { image_url = "https://i.redd.it/x.jpg" })
            store:saveImage("abc", "https://i.redd.it/x.jpg", "IMAGEBYTES")
            assert_true(fs.files["/a/images/abc.jpg"] ~= nil)

            store:delete("kindle", "abc")
            assert_nil(fs.files["/a/posts/kindle/abc.json"])
            assert_nil(fs.files["/a/images/abc.jpg"])
            assert_false(store:isSaved("abc"))
        end)
    end)

    describe("images", function()
        it("saves bytes into the archive and marks the post complete", function()
            local fs = fakeFS()
            local store = newStore(fs)
            store:save(post(), nil, { image_url = "https://i.redd.it/x.jpg" })
            local ok, path = store:saveImage("abc", "https://i.redd.it/x.jpg", "BYTES")
            assert_true(ok)
            assert_equal("BYTES", fs.files[path])
            assert_true(Archive.find(store:readIndex(), "abc").has_image)
        end)

        it("refuses to write an empty body as an image", function()
            assert_false(newStore(fakeFS()):saveImage("abc", "x.jpg", ""))
        end)

        it("reports a saved image only when it is really on disk", function()
            local fs = fakeFS()
            local store = newStore(fs)
            assert_nil(store:imageFile("abc", "https://i.redd.it/x.jpg"))
            store:saveImage("abc", "https://i.redd.it/x.jpg", "BYTES")
            fs.dirs["/a/images"] = true
            assert_equal("/a/images/abc.jpg", store:imageFile("abc", "https://i.redd.it/x.jpg"))
        end)
    end)

    describe("filling in later", function()
        it("attaches comments to an already-saved post", function()
            local fs = fakeFS()
            local store = newStore(fs)
            store:save(post(), nil, {})
            assert_false(Archive.find(store:readIndex(), "abc").has_comments)

            assert_true(store:addComments("kindle", "abc",
                { { kind = "comment", id = "c1" } }))
            assert_equal(1, #store:load("kindle", "abc").comments)
            assert_true(Archive.find(store:readIndex(), "abc").has_comments)
        end)

        it("will not attach comments to something that was never saved", function()
            assert_false(newStore(fakeFS()):addComments("kindle", "nope", {}))
        end)
    end)

    describe("browsing", function()
        it("groups by subreddit and orders newest save first", function()
            local fs = fakeFS()
            local store = newStore(fs)
            store:save(post{ id = "a", subreddit = "kindle" }, nil, { saved_at = 1 })
            store:save(post{ id = "b", subreddit = "books" }, nil, { saved_at = 3 })
            store:save(post{ id = "c", subreddit = "kindle" }, nil, { saved_at = 2 })

            assert_equal(3, #store:children())
            assert_equal("b", store:children()[1].data.id)
            assert_equal(2, #store:children("kindle"))
            assert_equal(2, #store:subreddits())
        end)
    end)
end)

describe("reddle_store partial threads", function()
    it("records the outstanding branches, so the archive knows it is a slice", function()
        local fs = fakeFS()
        local store = newStore(fs)
        store:save(post{ num_comments = 1200 }, {
            { kind = "comment", id = "c1" },
            { kind = "more", id = "m1", children = { "a", "b" } },
        }, {})
        local summary = Archive.find(store:readIndex(), "abc")
        assert_true(summary.has_comments)
        assert_equal(1, summary.pending)
        assert_equal("more comments", Archive.describeMissing(summary))
    end)

    it("clears the mark once the branches are filled in", function()
        local fs = fakeFS()
        local store = newStore(fs)
        store:save(post(), { { kind = "more", id = "m1", children = { "a" } } }, {})
        store:addComments("kindle", "abc", { { kind = "comment", id = "c1" } })
        local summary = Archive.find(store:readIndex(), "abc")
        assert_nil(summary.pending)
        assert_nil(Archive.describeMissing(summary))
    end)
end)
