--[[
Minimal test harness. No busted/luarocks on this machine, and a plugin that has to
survive on a Kindle shouldn't grow a test-only dependency tree anyway.

    describe("thing", function()
        it("does x", function() assert_equal(1, 1) end)
    end)
--]]

local H = { passed = 0, failed = 0, failures = {}, _ctx = {} }

function H.describe(name, fn)
    table.insert(H._ctx, name)
    fn()
    table.remove(H._ctx)
end

function H.it(name, fn)
    local label = table.concat(H._ctx, " › ") .. " › " .. name
    local ok, err = xpcall(fn, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)
    if ok then
        H.passed = H.passed + 1
        io.write("  ok   ", label, "\n")
    else
        H.failed = H.failed + 1
        table.insert(H.failures, { label = label, err = err })
        io.write("  FAIL ", label, "\n")
    end
end

local function repr(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(v[k] ~= nil and v[k] or v[tonumber(k)])
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

function H.assert_equal(expected, actual, msg)
    if expected ~= actual then
        error(string.format("%sexpected %s, got %s",
            msg and (msg .. ": ") or "", repr(expected), repr(actual)), 2)
    end
end

function H.assert_nil(actual, msg)
    if actual ~= nil then
        error(string.format("%sexpected nil, got %s", msg and (msg .. ": ") or "", repr(actual)), 2)
    end
end

function H.assert_true(actual, msg)
    if actual ~= true then
        error(string.format("%sexpected true, got %s", msg and (msg .. ": ") or "", repr(actual)), 2)
    end
end

function H.assert_false(actual, msg)
    if actual ~= false and actual ~= nil then
        error(string.format("%sexpected false, got %s", msg and (msg .. ": ") or "", repr(actual)), 2)
    end
end

function H.assert_match(pattern, actual, msg)
    if type(actual) ~= "string" or not actual:match(pattern) then
        error(string.format("%sexpected match %s, got %s",
            msg and (msg .. ": ") or "", repr(pattern), repr(actual)), 2)
    end
end

function H.install(env)
    env.describe = H.describe
    env.it = H.it
    env.assert_equal = H.assert_equal
    env.assert_nil = H.assert_nil
    env.assert_true = H.assert_true
    env.assert_false = H.assert_false
    env.assert_match = H.assert_match
end

return H
