--[[
A short-lived cache for fetched threads.

Backing out of a post and opening it again is a normal misclick, and it used to
cost a full /comments request every time -- against a rate limit that, on a
borrowed client ID, is shared with everyone else using it.

In memory, not on disk, on purpose. This is about the minute you are in, not the
week; a thread worth keeping past that is what saving is for, and writing it to
storage would mean another directory to grow without bound (which is exactly the
mistake the image cache made).

Bounded twice over, because a Kindle has little RAM and a thread with eighty
comment bodies is not small: entries expire, and the oldest is dropped once
there are too many.
--]]

local M = {}

--- Long enough to cover backing out and changing your mind, short enough that
--- an hour later you are looking at the thread as it is now.
M.TTL = 600
--- Threads, not bytes. Six is a couple of misclicks and a comparison between
--- two posts, which is the behaviour this is for.
M.MAX = 6

local Cache = {}
Cache.__index = Cache

--- deps: now (optional clock), ttl, max
function M.new(deps)
    deps = deps or {}
    return setmetatable({
        now = deps.now or os.time,
        ttl = deps.ttl or M.TTL,
        max = deps.max or M.MAX,
        entries = {},   -- key -> { value, at }
        order = {},     -- keys, oldest first
    }, Cache)
end

local function drop(self, key)
    if self.entries[key] == nil then return end
    self.entries[key] = nil
    for i, k in ipairs(self.order) do
        if k == key then table.remove(self.order, i); break end
    end
end

--- Returns the value, or nil when absent or stale. A stale entry is removed
--- rather than left to be tripped over again.
function Cache:get(key)
    if key == nil then return nil end
    local entry = self.entries[key]
    if not entry then return nil end
    if self.now() - entry.at >= self.ttl then
        drop(self, key)
        return nil
    end
    return entry.value
end

--- Insertion order is the eviction order, not use: re-reading the same thread
--- should not push out the one you looked at just before it, which is the other
--- half of the same misclick.
function Cache:put(key, value)
    if key == nil or value == nil then return value end
    drop(self, key)
    self.entries[key] = { value = value, at = self.now() }
    self.order[#self.order + 1] = key
    while #self.order > self.max do
        drop(self, self.order[1])
    end
    return value
end

function Cache:invalidate(key) drop(self, key) end

function Cache:clear()
    self.entries, self.order = {}, {}
end

function Cache:count()
    -- Counted through order, so an expired-but-not-yet-collected entry is not
    -- reported as if it were still usable.
    local n = 0
    for _i, key in ipairs(self.order) do
        if self:get(key) ~= nil then n = n + 1 end
    end
    return n
end

M.Cache = Cache
return M
