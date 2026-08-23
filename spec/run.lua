#!/usr/bin/env luajit
--[[
Test runner.   Usage:  luajit spec/run.lua [pattern]

Runs the pure-logic modules under plain LuaJIT -- the same runtime KOReader uses,
but with no device, no LuaSocket and no KOReader tree. What this can and cannot
prove is spelled out in spec/README.md.
--]]

local root = arg[0]:match("(.*)/spec/run%.lua") or "."
package.path = table.concat({
    root .. "/?.lua",
    package.path,
}, ";")

local H = require("spec.support.harness")
H.install(_G)

local specs = { "api", "auth", "markdown", "html", "comments", "listing", "post", "pair", "reader", "thread", "links", "emoji", "archive", "store", "read", "cache", "gettext", "ui" }
local filter = arg[1]

io.write("\n")
for _, name in ipairs(specs) do
    if not filter or name:match(filter) then
        io.write("spec/", name, "_spec.lua\n")
        require("spec." .. name .. "_spec")
        io.write("\n")
    end
end

if #H.failures > 0 then
    io.write("FAILURES\n\n")
    for _, f in ipairs(H.failures) do
        io.write("  ", f.label, "\n    ", (f.err:gsub("\n", "\n    ")), "\n\n")
    end
end

io.write(string.format("%d passed, %d failed\n\n", H.passed, H.failed))
os.exit(H.failed == 0 and 0 or 1)
