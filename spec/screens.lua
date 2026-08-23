#!/usr/bin/env luajit
--[[
Prints every screen Reddle can currently show, using the real strings the code
produces -- not a mockup someone typed by hand. Run it after changing any user
facing copy:

    luajit spec/screens.lua

Frames are ~32 columns to echo a Paperwhite's usable text width. This shows copy
and flow only: nothing here reflects real fonts, layout or e-ink refresh.
--]]

local root = arg[0]:match("(.*)/spec/screens%.lua") or "."
package.path = table.concat({
    root .. "/?.lua", package.path }, ";")

local ui_fakes = require("spec.support.ui_fakes")
local stubs = require("spec.support.stubs")

local W = 44

local function line(l, m, r) return l .. string.rep("─", W) .. r end
local function row(s)
    s = s or ""
    local out = {}
    for chunk in (s .. "\n"):gmatch("([^\n]*)\n") do
        -- carry the line's own indent onto its wrapped continuations, or nested
        -- comments would look flatter here than they do on the device
        local indent = chunk:match("^(%s*)") or ""
        while utf8len(chunk) > W - 2 do
            local cut = chunk:sub(1, W - 2):match(".*()%s") or (W - 2)
            out[#out + 1] = chunk:sub(1, cut - 1)
            chunk = indent .. chunk:sub(cut + 1)
        end
        out[#out + 1] = chunk
    end
    local rendered = {}
    for _, l in ipairs(out) do
        local pad = W - 2 - utf8len(l)
        rendered[#rendered + 1] = "│ " .. l .. string.rep(" ", pad > 0 and pad or 0) .. " │"
    end
    return table.concat(rendered, "\n")
end

function utf8len(s)
    local _, count = s:gsub("[^\128-\191]", "")
    return count
end

local function screen(title, body)
    print(line("┌", "", "┐"))
    print(row(title))
    print(line("├", "", "┤"))
    print(row(body))
    print(line("└", "", "┘"))
    print()
end

local function fresh()
    ui_fakes.clear()
    stubs.installKOReaderFakes()
    local rec = ui_fakes.install()
    return ui_fakes.newPlugin(rec), rec
end

print("\nReddle -- every screen that exists today\n")

-- 1. the menu
local plugin = fresh()
local menu = ui_fakes.menu(plugin)
local items = {}
for _, item in ipairs(menu.sub_item_table) do
    items[#items + 1] = "  " .. ui_fakes.itemText(item)
end
screen("Tools ▸ " .. menu.text, table.concat(items, "\n"))

-- 2. check login, unpaired
local p2, rec2 = fresh()
p2:onReddleWhoAmI()
screen("Check login (not paired)", ui_fakes.lastShown(rec2, "InfoMessage").text)

-- 3. check login, working
local p3, rec3 = fresh()
p3.api = { ratelimit = { remaining = 9997 }, get = function() return { name = "xhuh" }, 200 end }
p3:onReddleWhoAmI()
screen("Check login (paired)", ui_fakes.lastShown(rec3, "InfoMessage").text)

-- 4. check login, failure
local p4, rec4 = fresh()
p4.api = { get = function() return nil, 503, "service unavailable" end }
p4:onReddleWhoAmI()
screen("Check login (failure)", ui_fakes.lastShown(rec4, "InfoMessage").text)

-- 5. pairing
local p5, rec5 = fresh()
p5:startPairing()
screen("Pair with desktop", ui_fakes.lastShown(rec5, "InfoMessage").text)

-- 6. paired
local Pair = require("reddle_pair")
Pair.on_paired("cid", "rt")
screen("Paired", ui_fakes.lastShown(rec5, "InfoMessage").text)

-- 7. port dialog
local p7, rec7 = fresh()
p7:setPairingPort(nil)
local dlg = ui_fakes.lastShown(rec7, "InputDialog")
local buttons = {}
for _, b in ipairs(dlg.buttons[1]) do buttons[#buttons + 1] = "[ " .. b.text .. " ]" end
screen(dlg.title, "  " .. dlg.input .. "\n\n" .. table.concat(buttons, "  "))

-- 8. the listing view, rendered from the live fixture
local Listing = require("reddle_listing")
local json = require("spec.support.json")
local f = assert(io.open(root .. "/spec/fixtures/listing_kindle_hot.json"))
local body = f:read("*a"); f:close()

local api = { get = function() return json.decode(body), 200 end }
local l = Listing.new{ api = api, subreddit = "kindle" }  -- real clock: ages reflect when you run it
l:reload()

-- The listing is a document now: bold title on its own line, quiet byline under
-- it. This preview shows the plain-text shape; on the device the title is an
-- anchor and the byline renders smaller and grey.
local lines = {}
for i, child in ipairs(l.posts) do
    local r = Listing.rowFor(child, os.time())
    local title, byline = r.text:match("^(.-)  \226\128\148  (.*)$")
    lines[#lines + 1] = string.format("%s", title or r.text)
    lines[#lines + 1] = "   " .. r.mandatory .. " \194\183 " .. (byline or "")
    lines[#lines + 1] = ""
end
lines[#lines + 1] = "[ Sort ]  [ Search ]  [ Load more ]"
screen(l:title(), table.concat(lines, "\n"))

-- 9. post and comments, one document (\194\1675.6)
local Post = require("reddle_ui_post")
local Thread = nil  -- reddle_ui_thread pulls in KOReader widgets; compose by hand
local Comments = require("reddle_comments")
local post = json.decode(body).data.children[5].data
post.selftext = "Bought it last week after seeing it here.\n\n" ..
    "> is it worth it?\n\n" ..
    "Honestly **no** \226\128\148 it reads almost exactly like Bookerly to me.\n\n" ..
    "- same x-height\n- slightly tighter spacing\n\n" ..
    "See [the comparison](https://imgur.com/a/xyz) ^(shot on a PW5)"
post.is_self = true

local cf = assert(io.open(root .. "/spec/fixtures/comments_kindle.json"))
local cbody = cf:read("*a"); cf:close()
local rows = Comments.parse(json.decode(cbody))

local thread = { Post.fullText(post, "4h"), "", ("\226\148\128"):rep(40), "" }
local shown = {}
for i, r in ipairs(rows) do
    if i > 6 then break end
    shown[#shown + 1] = r
end
thread[#thread + 1] = Comments.toPlainText(shown)
screen("r/" .. post.subreddit, table.concat(thread, "\n") ..
    "\n[ Load all replies (3) ]")

print("Tap a post title to open it; the thread scrolls straight on from the post.")
print("Sort carries the time window (top/controversial: hour\226\128\166all). Search is per-sub or global.")
print("")
print("NB: on the device these render as HTML, so bold, italic, strikethrough,")
print("superscript, headings, quotes and code display as real formatting, titles")
print("are bold, bylines are smaller and grey, and replies carry a rule down the")
print("left. These ASCII frames use the plain-text path and cannot show that.")
print("Offline archive and write actions are next (DESIGN.md \194\1676, \194\1678).")
