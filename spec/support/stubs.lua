--[[
Fakes for the KOReader modules reddle_pair.lua requires, plus the small test
doubles the other specs need.

Only reddle_pair.lua needs the package.loaded trick -- it is deliberately tested
as the *real* file, because the interesting behaviour (headers-only read, body
still in the socket) lives in how it drives the socket, not in pure functions.
--]]

local M = {}

--- Install fakes into package.loaded so require("device") etc. resolve.
-- Returns a table of spies for assertions.
function M.installKOReaderFakes()
    local spies = {
        executed = {},      -- os.execute calls (iptables)
        shown = {},         -- widgets
        scheduled = {},     -- UIManager:scheduleIn
        next_ticks = {},    -- UIManager:nextTick callbacks
        zmq_inserted = 0,
        zmq_removed = 0,
        zmq_list = {},
        servers = {},
    }

    package.loaded["device"] = { isKindle = function() return false end }
    package.loaded["ui/event"] = { new = function(_, name) return { name = name } end }
    package.loaded["logger"] = {
        dbg = function() end, warn = function() end, err = function() end, info = function() end,
    }
    package.loaded["json"] = require("spec.support.json")

    package.loaded["ui/uimanager"] = {
        -- Real UIManager stores and returns the object itself; returning a wrapper
        -- here would let a removeZMQ mismatch pass unnoticed.
        insertZMQ = function(_, server)
            spies.zmq_inserted = spies.zmq_inserted + 1
            table.insert(spies.zmq_list, server)
            return server
        end,
        removeZMQ = function(_, mq)
            spies.zmq_removed = spies.zmq_removed + 1
            for i = #spies.zmq_list, 1, -1 do
                if spies.zmq_list[i] == mq then table.remove(spies.zmq_list, i) end
            end
            return mq
        end,
        scheduleIn = function(_, secs, task) table.insert(spies.scheduled, { secs = secs, task = task }) end,
        unschedule = function(_, task)
            for i, s in ipairs(spies.scheduled) do
                if s.task == task then table.remove(spies.scheduled, i); break end
            end
        end,
        nextTick = function(_, cb) table.insert(spies.next_ticks, cb) end,
        show = function(_, w) table.insert(spies.shown, w) end,
        close = function() end,
    }

    -- Stands in for ui/message/simpletcpserver: records config, never binds.
    package.loaded["ui/message/simpletcpserver"] = {
        new = function(self, o)
            o.start = function() return true end
            o.stop = function() end
            o.send = function(_, data, client) client.sent = data end
            table.insert(spies.servers, o)
            return o
        end,
    }

    package.loaded["ffi/netinfo"] = {
        new = function()
            return { retrieve = function()
                return {
                    { name = "lo", ipv4 = "127.0.0.1" },
                    { name = "wlan0", ipv4 = "192.168.1.42", wireless = true },
                }
            end }
        end,
    }

    return spies
end

function M.clearKOReaderFakes()
    for _, name in ipairs({
        "device", "ui/event", "logger", "json", "ui/uimanager",
        "ui/message/simpletcpserver", "ffi/netinfo",
        "reddle_pair", "reddle_api", "reddle_auth",
    }) do
        package.loaded[name] = nil
    end
end

--- LuaSettings-shaped in-memory store.
function M.store(initial)
    local data = {}
    for k, v in pairs(initial or {}) do data[k] = v end
    return {
        data = data,
        flushes = 0,
        readSetting = function(self, k) return self.data[k] end,
        saveSetting = function(self, k, v) self.data[k] = v end,
        delSetting = function(self, k) self.data[k] = nil end,
        flush = function(self) self.flushes = self.flushes + 1 end,
    }
end

--- Transport double. `responses` is a list of {body=, code=, headers=} consumed
-- in order; the requests it received are recorded for assertions.
--
-- Strict on purpose: running past the configured responses raises instead of
-- repeating the last one. An earlier version repeated, which turned a
-- retry-forever bug into a hung test run rather than a failing one.
function M.transport(responses)
    local t = { requests = {}, responses = responses or {}, index = 0 }
    t.fn = function(req)
        table.insert(t.requests, req)
        t.index = t.index + 1
        local r = t.responses[t.index]
        if not r then
            error(string.format(
                "transport double exhausted: request #%d but only %d response(s) configured",
                t.index, #t.responses), 2)
        end
        return r.body or "", r.code or 200, r.headers or {}
    end
    return t
end

--- Socket-client double for reddle_pair: hands out `buffer` in receive(n) calls.
function M.client(buffer)
    return {
        buffer = buffer or "",
        sent = nil,
        closed = false,
        reads = {}, -- every n passed to receive(), so specs can assert we never
                    -- ask the socket for an attacker-supplied length
        receive = function(self, n)
            table.insert(self.reads, n)
            if #self.buffer == 0 then return nil, "closed" end
            if #self.buffer < n then return nil, "timeout" end
            local chunk = self.buffer:sub(1, n)
            self.buffer = self.buffer:sub(n + 1)
            return chunk
        end,
        close = function(self) self.closed = true end,
    }
end

return M
