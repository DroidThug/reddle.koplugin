--[[
Emoji on a device with no emoji font (DESIGN.md §5.10).

KOReader's fonts are chosen for prose and none of them is an emoji font, so
coverage is incidental. Measured on a Paperwhite 5 (`Rendering test` rows 5-10):

  - U+2190-27BF renders completely: arrows, geometric shapes, dingbats, and the
    emoji-presentation characters down there (✅ ⚠ ❤ ⭐ ⬆). Anything Reddle draws
    itself should come from this range.
  - U+1F300+ is patchy per glyph, not per block: 🔥 and 💀 render, 📌 😀 👍 🚀 🏆
    do not.
  - A missing glyph draws as nothing at all -- blank space, not a tofu box.

So the map below is curated rather than blanket: faces become the emoticons they
descend from, objects a short bracketed word, and everything unmeasured is left
alone. Only add a substitution for a glyph somebody watched fail on hardware.
--]]

local M = {}

--- Confirmed missing, or common enough that the fallback is worth having.
--- Keys are UTF-8 byte strings; no pattern magic characters can occur in them,
--- so a plain gsub is safe.
M.MAP = {
    -- Measured missing on a Paperwhite 5, 2026-08-16.
    ["\240\159\147\140"] = "[pinned]",   -- U+1F4CC pushpin
    ["\240\159\152\128"] = ":)",         -- U+1F600 grinning face
    ["\240\159\145\141"] = "[+1]",       -- U+1F44D thumbs up
    ["\240\159\154\128"] = "[rocket]",   -- U+1F680
    ["\240\159\143\134"] = "[winner]",   -- U+1F3C6 trophy

    -- Faces: inferred from U+1F600 being absent, since these share its block and
    -- would come from the same font. The emoticons they were drawn from anyway.
    ["\240\159\152\131"] = ":D",         -- U+1F603 smiling face open mouth
    ["\240\159\152\132"] = ":D",         -- U+1F604
    ["\240\159\152\130"] = ":')",        -- U+1F602 tears of joy
    ["\240\159\164\163"] = ":')",        -- U+1F923 rolling on the floor
    ["\240\159\153\130"] = ":(",         -- U+1F642 slightly smiling (inverted use)
    ["\240\159\152\137"] = ";)",         -- U+1F609 winking
    ["\240\159\152\162"] = ":'(",        -- U+1F622 crying
    ["\240\159\152\173"] = ":'(",        -- U+1F62D loudly crying
    ["\240\159\152\145"] = ":|",         -- U+1F611 expressionless
    ["\240\159\152\144"] = ":|",         -- U+1F610 neutral
    ["\240\159\164\148"] = "[thinking]", -- U+1F914
    ["\240\159\152\142"] = "B)",         -- U+1F60E sunglasses
    ["\240\159\152\177"] = ":O",         -- U+1F631 screaming
    ["\240\159\152\174"] = ":O",         -- U+1F62E open mouth
    ["\240\159\164\183"] = "[shrug]",    -- U+1F937

    -- Objects that carry meaning in a title or a comment. Not U+1F525 fire or
    -- U+1F480 skull: both were mapped here until the device drew them fine.
    ["\240\159\145\142"] = "[-1]",       -- U+1F44E thumbs down (pairs with U+1F44D)
    ["\240\159\142\137"] = "[party]",    -- U+1F389
    ["\240\159\145\128"] = "[eyes]",     -- U+1F440
    ["\240\159\146\169"] = "[poop]",     -- U+1F4A9
    ["\240\159\154\168"] = "[alert]",    -- U+1F6A8
    ["\240\159\148\180"] = "[live]",     -- U+1F534 red circle
    ["\240\159\147\162"] = "[notice]",   -- U+1F4E2 loudspeaker
    ["\240\159\148\151"] = "[link]",     -- U+1F517
    ["\240\159\147\150"] = "[book]",     -- U+1F4D6
    ["\240\159\146\161"] = "[idea]",     -- U+1F4A1
    ["\240\159\143\134"] = "[winner]",   -- U+1F3C6 trophy
    ["\240\159\152\187"] = "[cat]",      -- U+1F63B
    ["\240\159\144\136"] = "[cat]",      -- U+1F408
    ["\240\159\144\182"] = "[dog]",      -- U+1F436
}

--- True when the string contains a byte only a multi-byte UTF-8 sequence can
--- start. Skipping ASCII-only strings is worth it: this runs over every title
--- and every comment body.
local function mayHaveEmoji(s)
    return s:find("[\194-\244]") ~= nil
end

--- Has someone installed an emoji font? Then get out of the way.
---
--- Substituting is damage control for a font gap, not something we want for its
--- own sake -- `[rocket]` is strictly worse than a rocket if the device can draw
--- one. Dropping a monochrome Noto Emoji into koreader/fonts/ fixes the gap
--- properly and wholesale (tools/install-emoji-font.sh), and when it is there
--- this whole module should do nothing.
---
--- Detected by name across KOReader's font list rather than by looking for one
--- path, so any emoji font counts and the user is free to install a different
--- one. Wrapped in pcall and cached: fontlist is not available off-device, and
--- "cannot tell" has to mean "substitute", which is the safe answer.
function M.hasFont()
    return M.fontPath() ~= nil
end

--- Where the emoji font is, or nil. Cached; M._font_path == false means "looked,
--- found nothing", which is distinct from "not looked yet".
function M.fontPath()
    if M._font_path ~= nil then
        return M._font_path or nil
    end
    M._font_path = false
    local ok, FontList = pcall(require, "fontlist")
    if ok and type(FontList) == "table" and FontList.getFontList then
        local listed, fonts = pcall(FontList.getFontList, FontList)
        if listed and type(fonts) == "table" then
            for _, path in ipairs(fonts) do
                if tostring(path):lower():find("emoji", 1, true) then
                    M._font_path = tostring(path)
                    break
                end
            end
        end
    end
    return M._font_path or nil
end

M.FAMILY = "ReddleEmoji"

--- Directory and filename, for an @font-face rule: MuPDF resolves `src: url(...)`
--- against the resource directory handed to setContent (§5.10.1).
function M.fontFace(family)
    local path = M.fontPath()
    if not path then return nil end
    local dir, file = path:match("^(.*)/([^/]+)$")
    if not dir then return nil end
    return {
        dir = dir,
        file = file,
        css = string.format(
            '@font-face { font-family: "%s"; src: url("%s"); }\n', family or M.FAMILY, file),
    }
end

--- The stylesheet and resource directory a view needs to render emoji, or nil.
---
--- The `.e` class is the important half. MuPDF picks a font per *run* from the
--- family list -- it does not fall back per glyph, which is the whole reason a
--- missing emoji vanishes rather than being borrowed from elsewhere. So
--- `font-family: serif, ReddleEmoji` would simply use serif and never reach the
--- emoji font. The font has to be applied to the emoji *characters*, which means
--- wrapping them, which means `.e`.
---
--- The device made that concrete: the probe set font-family on a whole paragraph
--- and the Latin text came out in Noto Emoji's own Latin glyphs -- correct
--- behaviour, wrong scope.
function M.style()
    local face = M.fontFace()
    if not face then return nil end
    return {
        dir = face.dir,
        css = face.css .. string.format(".e { font-family: %s; }\n", M.FAMILY),
    }
end

-- A 4-byte UTF-8 sequence in U+1F000-U+1FFFF: the emoji planes proper. The
-- U+2190-27BF glyphs are deliberately *not* matched -- the reading font already
-- draws those, and wrapping them would swap a familiar arrow for a different one.
local EMOJI = "\240\159[\128-\191][\128-\191]"
--- Emoji for a piece of *already-escaped* text bound for HTML.
---
--- With the font: wrap each emoji so the `.e` rule reaches it, and leave the
--- surrounding prose in the reader's own font. Without it: fall back to the
--- placeholder map.
---
--- ZWJ sequences (👨‍👩‍👧) come out as their component emoji side by side rather
--- than one combined glyph, since each is wrapped separately. Accepted: the
--- alternative is a joining implementation, and MuPDF would not honour it anyway.
function M.markup(escaped)
    if type(escaped) ~= "string" or escaped == "" or not mayHaveEmoji(escaped) then
        return escaped or ""
    end
    if not M.hasFont() then return M.substitute(escaped) end
    local out = escaped:gsub("\239\184[\142\143]", "")
    return (out:gsub(EMOJI, '<span class="e">%0</span>'))
end

--- Replace the glyphs we know this device cannot draw.
function M.substitute(s)
    if type(s) ~= "string" or s == "" or not mayHaveEmoji(s) then return s or "" end
    if M.hasFont() then return s end
    for glyph, text in pairs(M.MAP) do
        s = s:gsub(glyph, text)
    end
    return s
end

--- The same, over markup: only the text between tags is touched, so an href
--- never gets rewritten out from under a link.
function M.applyToHtml(html)
    if type(html) ~= "string" or html == "" or not mayHaveEmoji(html) then
        return html or ""
    end
    local out, pos = {}, 1
    while true do
        local s, e = html:find("<[^>]*>", pos)
        if not s then
            out[#out + 1] = M.markup(html:sub(pos))
            break
        end
        out[#out + 1] = M.markup(html:sub(pos, s - 1))
        out[#out + 1] = html:sub(s, e)
        pos = e + 1
    end
    return table.concat(out)
end

return M
