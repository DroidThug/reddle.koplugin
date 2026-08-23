--[[
Markdown subset → plain text (DESIGN.md §5.4).

The plain-text fallback path, for builds whose TextViewer cannot render HTML.
Emphasis markers are removed rather than shown; structure survives -- quotes,
lists, code, headings, and where links point.

Pure Lua, no requires.
--]]

local M = {}

M.QUOTE_PREFIX = "▏ "
M.BULLET = "• "
M.RULE = "────────"

local ENTITIES = {
    ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"',
    ["&#39;"] = "'", ["&apos;"] = "'", ["&nbsp;"] = " ", ["&#x200B;"] = "",
}

function M.unescape(s)
    return (tostring(s):gsub("&#?%w+;", function(e) return ENTITIES[e] or e end))
end

--- "https://www.reddit.com/r/x" -> "reddit.com"
function M.host(url)
    local h = tostring(url):match("^%a+://([^/]+)") or tostring(url):match("^([%w%.%-]+%.%a%a+)")
    if not h then return nil end
    return (h:gsub("^www%.", ""))
end

-- Emphasis and other inline noise, applied to a single line of prose.
local function inline(line)
    -- [text](url) -> text (host), so the destination survives without the URL
    line = line:gsub("%[([^%]]*)%]%(([^%)%s]+)[^%)]*%)", function(text, url)
        local h = M.host(url)
        if text == "" then return url end
        if h and not text:lower():find(h, 1, true) then
            return text .. " (" .. h .. ")"
        end
        return text
    end)
    line = line:gsub(">!(.-)!<", "[spoiler]")
    line = line:gsub("%*%*%*(.-)%*%*%*", "%1")
    line = line:gsub("%*%*(.-)%*%*", "%1")
    line = line:gsub("%_%_(.-)%_%_", "%1")
    line = line:gsub("%*(.-)%*", "%1")
    line = line:gsub("~~(.-)~~", "%1")
    line = line:gsub("`(.-)`", "%1")
    -- superscript: ^(text) and ^word
    line = line:gsub("%^%((.-)%)", "%1")
    line = line:gsub("%^(%S+)", "%1")
    line = line:gsub("^%s*#+%s*", "")          -- headings keep their text
    if line:find("|", 1, true) then            -- tables degrade to spaced text
        line = line:gsub("|", " "):gsub("%s+", "  "):gsub("^%s+", ""):gsub("%s+$", "")
    end
    return line
end

--- Convert Reddit markdown to plain text.
function M.toText(md)
    if md == nil or md == "" then return "" end
    -- Track which lines are code, so the tidy-up below cannot eat their indent.
    local out, is_code = {}, {}
    local in_fence = false
    local function emit(text, code)
        out[#out + 1] = text
        is_code[#out] = code or false
    end

    for raw in (M.unescape(md):gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw

        if line:match("^%s*```") then
            in_fence = not in_fence
        elseif in_fence or line:match("^    %S") then
            emit("  " .. line:gsub("^    ", ""), true)
        elseif line:match("^%s*[%-%*_]%s*[%-%*_]%s*[%-%*_][%s%-%*_]*$") then
            emit(M.RULE)
        elseif line:match("^%s*>") then
            local depth = 0
            local body = line
            while body:match("^%s*>") do
                body = body:gsub("^%s*>%s?", "")
                depth = depth + 1
            end
            emit(M.QUOTE_PREFIX:rep(depth) .. inline(body))
        elseif line:match("^%s*[%*%-%+]%s+") then
            local indent = #(line:match("^(%s*)") or "")
            emit(string.rep(" ", indent) .. M.BULLET .. inline(line:gsub("^%s*[%*%-%+]%s+", "")))
        elseif line:match("^%s*%d+%.%s+") then
            local n, rest = line:match("^%s*(%d+)%.%s+(.*)$")
            emit(n .. ". " .. inline(rest))
        else
            emit(inline(line))
        end
    end

    -- Trim prose lines; leave code lines exactly as they are.
    for i, line in ipairs(out) do
        if not is_code[i] then
            out[i] = line:gsub("%s+$", "")
        end
    end
    -- Drop blank lines at both ends, then trim the leading indent of the first
    -- line only when that line is prose.
    while #out > 0 and out[1]:match("^%s*$") do table.remove(out, 1); table.remove(is_code, 1) end
    while #out > 0 and out[#out]:match("^%s*$") do table.remove(out); table.remove(is_code) end
    if out[1] and not is_code[1] then out[1] = out[1]:gsub("^%s+", "") end

    local text = table.concat(out, "\n")
    text = text:gsub("\n\n\n+", "\n\n")     -- Reddit loves blank lines
    return text
end

--- First `n` lines, with an ellipsis if anything was cut. Used for the collapsed
--- comment rows, where the full text is one tap away.
function M.preview(text, n)
    n = n or 3
    local lines, count = {}, 0
    for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" or count > 0 then
            count = count + 1
            if count > n then
                lines[#lines] = (lines[#lines] or "") .. " …"
                break
            end
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, "\n")
end

return M
