--[[
The short-lived thread cache. Backing out of a post and opening it again is a
misclick; it should not cost a request against a shared rate limit.
--]]

local Cache = require("reddle_cache")

local function clocked(start)
    local t = { at = start or 0 }
    t.cache = Cache.new{ now = function() return t.at end, ttl = 100, max = 3 }
    return t
end

describe("reddle_cache", function()

    it("returns what was put in", function()
        local t = clocked()
        t.cache:put("a", { rows = { 1, 2 } })
        assert_equal(2, #t.cache:get("a").rows)
    end)

    it("misses for anything it never saw", function()
        assert_nil(clocked().cache:get("nope"))
        assert_nil(clocked().cache:get(nil))
    end)

    it("keeps an entry right up to the deadline and not past it", function()
        local t = clocked(1000)
        t.cache:put("a", "v")
        t.at = 1099
        assert_equal("v", t.cache:get("a"))
        t.at = 1100
        assert_nil(t.cache:get("a"), "ttl is the age at which it stops counting")
    end)

    it("forgets a stale entry rather than leaving it to be tripped over", function()
        local t = clocked(0)
        t.cache:put("a", "v")
        t.at = 500
        t.cache:get("a")
        assert_equal(0, t.cache:count())
    end)

    it("drops the oldest when full, not the least recently read", function()
        -- Re-reading one thread should not evict the one read just before it:
        -- that is the same misclick this exists for.
        local t = clocked()
        t.cache:put("a", 1); t.cache:put("b", 2); t.cache:put("c", 3)
        t.cache:get("a")            -- would promote `a` under an LRU
        t.cache:put("d", 4)
        assert_nil(t.cache:get("a"), "insertion order is the eviction order")
        assert_equal(2, t.cache:get("b"))
        assert_equal(4, t.cache:get("d"))
    end)

    it("re-putting a key refreshes it rather than duplicating it", function()
        local t = clocked(0)
        t.cache:put("a", 1)
        t.at = 50
        t.cache:put("a", 2)
        t.at = 120           -- past the original deadline, inside the new one
        assert_equal(2, t.cache:get("a"))
        assert_equal(1, t.cache:count())
    end)

    it("can be emptied and individually invalidated", function()
        local t = clocked()
        t.cache:put("a", 1); t.cache:put("b", 2)
        t.cache:invalidate("a")
        assert_nil(t.cache:get("a"))
        assert_equal(2, t.cache:get("b"))
        t.cache:clear()
        assert_equal(0, t.cache:count())
    end)

    it("ignores a nil value rather than caching a hole", function()
        local t = clocked()
        t.cache:put("a", nil)
        assert_equal(0, t.cache:count())
    end)

    it("defaults to a window measured in minutes, not hours", function()
        -- Long enough to cover a misclick, short enough that a thread reopened
        -- much later is the thread as it is now.
        assert_true(Cache.TTL >= 300 and Cache.TTL <= 1800, tostring(Cache.TTL))
        assert_true(Cache.MAX <= 10, "a Kindle has little RAM")
    end)
end)
