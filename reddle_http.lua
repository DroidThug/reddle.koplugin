--[[
Device-side HTTP transport (DESIGN.md §4.1).

The only file that touches LuaSocket, and so the only one that cannot run
off-device. Everything above it takes a `transport` function with this contract:

    transport{ url=, method=, headers=, body= } -> body_string, code, resp_headers
--]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local M = {}

function M.transport(req)
    local sink = {}
    local block, total = socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT
    if req.timeouts == "file" then
        block, total = socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT
    end
    socketutil:set_timeout(block, total)
    local code, headers = socket.skip(1, http.request{
        url = req.url,
        method = req.method or "GET",
        headers = req.headers,
        source = req.body and ltn12.source.string(req.body) or nil,
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    return table.concat(sink), code, headers
end

return M
