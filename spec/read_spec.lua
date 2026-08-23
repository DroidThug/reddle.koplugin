--[[
Read/unread tracking. Pure; the store is a table.
--]]

local Read = require("reddle_read")

local function store()
    local data, flushes = {}, 0
    return {
        data = data,
        flushes = function() return flushes end,
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        flush = function() flushes = flushes + 1 end,
    }
end

describe("reddle_read", function()

    it("starts empty and remembers nothing", function()
        local r = Read.new{ store = store() }
        assert_false(r:isRead("a"))
        assert_equal(0, r:count())
    end)

    it("marks a post read", function()
        local r = Read.new{ store = store() }
        assert_true(r:mark("a"))
        assert_true(r:isRead("a"))
    end)

    it("reports a repeat mark as no change, so callers can skip the write", function()
        local s = store()
        local r = Read.new{ store = s }
        r:mark("a")
        local before = s.flushes()
        assert_false(r:mark("a"))
        assert_equal(before, s.flushes(), "re-marking must not write to disk")
    end)

    it("ignores nil and empty ids rather than storing junk", function()
        local r = Read.new{ store = store() }
        assert_false(r:mark(nil))
        assert_false(r:mark(""))
        assert_equal(0, r:count())
    end)

    it("survives a restart", function()
        local s = store()
        Read.new{ store = s }:mark("a")
        assert_true(Read.new{ store = s }:isRead("a"))
    end)

    it("survives a settings value of the wrong type", function()
        local s = store()
        s.data.read_ids = "not a table"
        local r = Read.new{ store = s }
        assert_equal(0, r:count())
        assert_true(r:mark("a"))
    end)

    describe("bounded", function()
        it("discards the oldest beyond the limit", function()
            -- Unbounded, this grows forever and is rewritten on every post
            -- opened, on a device someone may use for years.
            local r = Read.new{ store = store(), limit = 3 }
            r:mark("a"); r:mark("b"); r:mark("c"); r:mark("d")
            assert_equal(3, r:count())
            assert_false(r:isRead("a"), "oldest should have been dropped")
            assert_true(r:isRead("d"))
        end)

        it("evicts by insertion order, not by recency of reading", function()
            -- Re-opening an old post should not extend the life of some other
            -- unrelated id; "recently opened" is the window worth keeping.
            local r = Read.new{ store = store(), limit = 3 }
            r:mark("a"); r:mark("b"); r:mark("c")
            r:mark("a")           -- already known: no reordering
            r:mark("d")
            assert_false(r:isRead("a"))
            assert_true(r:isRead("b"))
        end)

        it("keeps the membership index in step with eviction", function()
            local r = Read.new{ store = store(), limit = 2 }
            r:mark("a"); r:mark("b"); r:mark("c")
            assert_false(r:isRead("a"))
            assert_equal(2, r:count())
        end)
    end)

    describe("unmark and clear", function()
        it("forgets one post", function()
            local r = Read.new{ store = store() }
            r:mark("a"); r:mark("b")
            assert_true(r:unmark("a"))
            assert_false(r:isRead("a"))
            assert_true(r:isRead("b"))
            assert_equal(1, r:count())
        end)

        it("reports unmarking something unknown as no change", function()
            assert_false(Read.new{ store = store() }:unmark("nope"))
        end)

        it("forgets everything", function()
            local r = Read.new{ store = store() }
            r:mark("a"); r:mark("b")
            r:clear()
            assert_equal(0, r:count())
            assert_false(r:isRead("a"))
        end)
    end)

    describe("apply", function()
        it("stamps listing children the renderer can read", function()
            local r = Read.new{ store = store() }
            r:mark("a")
            local children = {
                { kind = "t3", data = { id = "a" } },
                { kind = "t3", data = { id = "b" } },
            }
            r:apply(children)
            assert_true(children[1].data.reddle_read)
            assert_nil(children[2].data.reddle_read)
        end)

        it("is unbothered by junk", function()
            local r = Read.new{ store = store() }
            r:apply(nil)
            r:apply({ "not a child" })
        end)
    end)
end)
