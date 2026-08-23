--[[
Stand-in for KOReader's `json` module, so specs can run under plain LuaJIT.

Decode only (that's all Reddle uses), plus a tiny encode for building fixtures.
This is a test double: it is not a hardened parser and must never ship to the
device -- on the Kindle, require("json") is the real thing.
--]]

local M = {}

local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local decode_value

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decode_string(s, i)
    assert(s:sub(i, i) == '"', "expected string at " .. i)
    i = i + 1
    local out = {}
    while true do
        local c = s:sub(i, i)
        if c == "" then error("unterminated string") end
        if c == '"' then return table.concat(out), i + 1 end
        if c == "\\" then
            local e = s:sub(i + 1, i + 1)
            if e == "u" then
                local hex = s:sub(i + 2, i + 5)
                local cp = tonumber(hex, 16) or 63
                out[#out + 1] = cp < 128 and string.char(cp) or "?"
                i = i + 6
            else
                out[#out + 1] = ESCAPES[e] or e
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

local function decode_number(s, i)
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    return tonumber(num), i + #num
end

local function decode_array(s, i)
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local v
        v, i = decode_value(s, i)
        arr[#arr + 1] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "]" then return arr, i + 1 end
        assert(c == ",", "expected , or ] at " .. i)
        i = skip_ws(s, i + 1)
    end
end

local function decode_object(s, i)
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        local k, v
        k, i = decode_string(s, i)
        i = skip_ws(s, i)
        assert(s:sub(i, i) == ":", "expected : at " .. i)
        i = skip_ws(s, i + 1)
        v, i = decode_value(s, i)
        obj[k] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "}" then return obj, i + 1 end
        assert(c == ",", "expected , or } at " .. i)
        i = skip_ws(s, i + 1)
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return decode_string(s, i) end
    if c == "{" then return decode_object(s, i) end
    if c == "[" then return decode_array(s, i) end
    if s:sub(i, i + 3) == "true" then return true, i + 4 end
    if s:sub(i, i + 4) == "false" then return false, i + 5 end
    if s:sub(i, i + 3) == "null" then return nil, i + 4 end
    if c:match("[%d%-]") then return decode_number(s, i) end
    error("unexpected character " .. string.format("%q", c) .. " at " .. i)
end

function M.decode(s)
    assert(type(s) == "string", "decode expects a string")
    local v = decode_value(s, 1)
    return v
end

local function encode_value(v)
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        if #v > 0 then
            local parts = {}
            for _, item in ipairs(v) do parts[#parts + 1] = encode_value(item) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = encode_value(tostring(k)) .. ":" .. encode_value(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("cannot encode " .. t)
end

M.encode = encode_value

return M
