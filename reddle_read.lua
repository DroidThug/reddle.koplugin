--[[
Which posts have been read (DESIGN.md §5.11).

Pure: takes a settings store, keeps a bounded set of post ids. No KOReader
requires, so spec/read_spec.lua exercises it directly.

**Bounded on purpose.** The obvious implementation is a table of every id ever
opened, which grows without limit and is written to disk on every post you read
— on a device someone might use for years. This keeps the most recent N and
discards the rest: forgetting that you read something eighteen months ago costs
nothing, and an unbounded settings file eventually costs a slow start-up.

Insertion order is the eviction order, which is deliberately *not* an LRU:
re-reading a post should not extend the life of some unrelated old id, and
"recently opened" is exactly the window worth remembering.
--]]

local M = {}

--- Roughly a year of heavy reading, and a few tens of KB on disk.
M.LIMIT = 500

local Read = {}
Read.__index = Read

--- deps: store (readSetting/saveSetting/flush), limit (optional)
function M.new(deps)
    local self = setmetatable({
        store = assert(deps.store, "store required"),
        limit = deps.limit or M.LIMIT,
    }, Read)
    self:reload()
    return self
end

function Read:reload()
    local ids = self.store:readSetting("read_ids")
    self.ids = type(ids) == "table" and ids or {}
    -- Membership index, rebuilt rather than persisted: a set and a list would be
    -- two things to keep in agreement across versions.
    self.seen = {}
    for _i, id in ipairs(self.ids) do self.seen[id] = true end
    return self
end

function Read:isRead(id)
    return id ~= nil and self.seen[id] == true
end

--- Returns true if this was a new read, false if it was already known -- the
--- caller can skip a settings write when nothing changed.
function Read:mark(id)
    if id == nil or id == "" or self.seen[id] then return false end
    self.ids[#self.ids + 1] = id
    self.seen[id] = true
    while #self.ids > self.limit do
        local oldest = table.remove(self.ids, 1)
        self.seen[oldest] = nil
    end
    self.store:saveSetting("read_ids", self.ids)
    self.store:flush()
    return true
end

function Read:unmark(id)
    if not self:isRead(id) then return false end
    for i, existing in ipairs(self.ids) do
        if existing == id then table.remove(self.ids, i); break end
    end
    self.seen[id] = nil
    self.store:saveSetting("read_ids", self.ids)
    self.store:flush()
    return true
end

function Read:clear()
    self.ids, self.seen = {}, {}
    self.store:saveSetting("read_ids", self.ids)
    self.store:flush()
end

function Read:count()
    return #self.ids
end

--- Stamp a set of listing children so the renderer can mark them. Mutates the
--- children's data, which is what reddle_listing.htmlFor reads.
function Read:apply(children)
    for _i, child in ipairs(type(children) == "table" and children or {}) do
        local d = child.data
        if type(d) == "table" then d.reddle_read = self:isRead(d.id) or nil end
    end
    return children
end

M.Read = Read
return M
