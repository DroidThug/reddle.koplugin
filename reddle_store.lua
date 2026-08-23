--[[
Filesystem for the saved-post archive (DESIGN.md §6).

Everything that touches disk lives here; the shape of what gets written is
reddle_archive.lua's business. Split that way because the model is worth testing
exhaustively and the I/O is worth testing through a fake — spec/store_spec.lua
drives this with an in-memory filesystem, so the specs never write anything.

The index is the hot path: it is read whenever the Saved menu opens and rewritten
on every save or delete. It is small by design (one short row per post) and
cached in memory after the first read.
--]]

local Archive = require("reddle_archive")

local M = {}

--- deps: root (archive directory), lfs, json, now (optional clock)
--- `io_open` is injectable so the specs can run against a fake filesystem.
function M.new(deps)
    return setmetatable({
        root = assert(deps.root, "root required"),
        lfs = assert(deps.lfs, "lfs required"),
        json = assert(deps.json, "json required"),
        io_open = deps.io_open or io.open,
        os_remove = deps.os_remove or os.remove,
        os_rename = deps.os_rename or os.rename,
        now = deps.now or os.time,
        index_cache = nil,
    }, { __index = M })
end

function M:exists(path)
    return self.lfs.attributes(path, "mode") ~= nil
end

function M:removeFile(path)
    return self.os_remove(path)
end

--- mkdir -p. lfs.mkdir only creates one level, and the archive is three deep.
function M:mkdirp(path)
    -- DataStorage may return either an absolute directory (usual desktop
    -- builds) or a relative one (the Kindle build: ./settings). Starting every
    -- path with "/" changed the latter into /settings and made archive saves
    -- fail with a permissions error.
    local absolute = tostring(path):sub(1, 1) == "/"
    local built = absolute and "/" or ""
    for part in tostring(path):gmatch("[^/]+") do
        if built == "" or built == "/" then
            built = built .. part
        else
            built = built .. "/" .. part
        end
        if self.lfs.attributes(built, "mode") ~= "directory" then
            self.lfs.mkdir(built)
        end
    end
    return self.lfs.attributes(path, "mode") == "directory"
end

function M:readFile(path)
    local f = self.io_open(path, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return body
end

--- Written via a temporary file and renamed, so a Kindle that sleeps or runs out
--- of battery mid-write leaves the previous index intact rather than a truncated
--- one. Losing the index loses every saved post at once.
function M:writeFile(path, body)
    self:mkdirp(path:match("^(.*)/[^/]*$") or self.root)
    local tmp = path .. ".tmp"
    local f = self.io_open(tmp, "wb")
    if not f then return false, "could not open " .. tmp end
    local ok = f:write(body)
    f:close()
    if not ok then return false, "write failed" end
    self:removeFile(path)
    local renamed, err = self.os_rename(tmp, path)
    if not renamed then return false, tostring(err) end
    return true
end

function M:readIndex()
    if self.index_cache then return self.index_cache end
    local body = self:readFile(Archive.indexPath(self.root))
    local index = {}
    if body and body ~= "" then
        local ok, decoded = pcall(self.json.decode, body)
        -- A corrupt index must not take the plugin down: the records are still
        -- on disk, and an empty list is recoverable by saving again.
        if ok and type(decoded) == "table" then index = decoded end
    end
    self.index_cache = index
    return index
end

function M:writeIndex(index)
    self.index_cache = index
    return self:writeFile(Archive.indexPath(self.root), self.json.encode(index))
end

--- Save a post. `rows` may be nil (post only). Returns ok, err.
---
--- Costs zero API calls when called from an open thread: the post and its rows
--- are already in memory. Only the image is ever fetched, and only if asked.
--- Saving again merges rather than replaces. "Post only" on a post already saved
--- with its comments used to overwrite the record and drop them, and the index
--- row it wrote then claimed the comments and image were missing while both were
--- still on disk.
function M:save(post, rows, opts)
    opts = opts or {}
    if type(post) ~= "table" or not post.id then return false, "no post" end
    local saved_at = opts.saved_at or self.now()
    local previous = self:load(post.subreddit, post.id)
    local prior = Archive.find(self:readIndex(), post.id)

    if rows == nil and previous then rows = previous.comments end
    local prev_image = previous and previous.image or nil
    local image_url = opts.image_url or (prior and prior.image_url) or (prev_image and prev_image.url)
    local image_file = opts.image_file or (prev_image and prev_image.file)

    local record = Archive.record(post, rows, {
        saved_at = saved_at,
        image_url = image_url,
        image_file = image_file,
    })
    local ok, err = self:writeFile(
        Archive.postPath(self.root, post.subreddit, post.id),
        self.json.encode(record))
    if not ok then return false, err end

    local summary = Archive.summaryOf(post, {
        saved_at = saved_at,
        has_comments = rows ~= nil and #rows > 0,
        pending = Archive.pendingBranches(rows),
        -- The file on disk is the only reliable answer. No caller passes
        -- image_file, so deriving this from opts made every save report that
        -- there was no image.
        has_image = self:imageFile(post.id, image_url) ~= nil,
        image_url = image_url,
    })
    return self:writeIndex(Archive.upsert(self:readIndex(), summary))
end

function M:load(subreddit, id)
    local body = self:readFile(Archive.postPath(self.root, subreddit, id))
    if not body then return nil, "not saved" end
    local ok, record = pcall(self.json.decode, body)
    if not ok or type(record) ~= "table" then return nil, "unreadable record" end
    return record
end

function M:delete(subreddit, id)
    self:removeFile(Archive.postPath(self.root, subreddit, id))
    local summary = Archive.find(self:readIndex(), id)
    if summary and summary.has_image and summary.image_url then
        self:removeFile(Archive.imagePath(self.root, id, summary.image_url))
    end
    return self:writeIndex(Archive.remove(self:readIndex(), id))
end

function M:isSaved(id)
    return Archive.isSaved(self:readIndex(), id)
end

function M:children(subreddit)
    return Archive.children(self:readIndex(), subreddit)
end

function M:subreddits()
    return Archive.subreddits(self:readIndex())
end

--- Write image bytes into the archive (not the evictable cache) and record it.
function M:saveImage(id, url, body)
    if not body or #body == 0 then return false, "empty image" end
    local path = Archive.imagePath(self.root, id, url)
    local ok, err = self:writeFile(path, body)
    if not ok then return false, err end
    local index = self:readIndex()
    local summary = Archive.find(index, id)
    if summary then
        summary.has_image, summary.image_url = true, url
        self:writeIndex(index)
    end
    return true, path
end

--- The saved image for a post, if it is actually on disk.
function M:imageFile(id, url)
    if not url then return nil end
    local path = Archive.imagePath(self.root, id, url)
    return self:exists(path) and path or nil
end

--- Attach comments fetched after the fact to an already-saved post.
function M:addComments(subreddit, id, rows)
    local record = self:load(subreddit, id)
    if not record then return false, "not saved" end
    record.comments = rows
    local ok, err = self:writeFile(
        Archive.postPath(self.root, subreddit, id), self.json.encode(record))
    if not ok then return false, err end
    local index = self:readIndex()
    local summary = Archive.find(index, id)
    if summary then
        summary.has_comments = rows ~= nil and #rows > 0
        local pending = Archive.pendingBranches(rows)
        summary.pending = pending > 0 and pending or nil
        self:writeIndex(index)
    end
    return true
end

return M
