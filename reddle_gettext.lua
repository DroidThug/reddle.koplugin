--[[
Translations for the plugin's own strings.

KOReader's gettext is one global catalogue: GetText.dirname is "l10n" relative
to KOReader itself, and there is no per-plugin text domain. So a plugin's
strings can never appear in KOReader's .mo files, and `require("gettext")`
returns them untouched no matter what language the reader has chosen.

This wraps it. Reddle's own table is consulted first, KOReader's catalogue after
-- which matters more than it sounds, because plenty of the strings here are
words KOReader has already translated ("Cancel", "Save", "Log out").

Catalogues are plain Lua tables in l10n/<code>.lua, mapping English source to
translation, which is the same approach appstore.koplugin takes. No msgfmt step
and no binary files in the repository, and they can be checked by the specs.
--]]

local M = {}

--- Exposed for the specs and for tools/extract-strings.lua.
M.translations = {}
M.lang = nil

local function base(code)
    return tostring(code or ""):match("^([%a]+)")
end

--- Load the catalogue for `code`, returning the table actually used.
---
--- An exact match wins (pt_BR), then the bare language (pt), so a regional
--- variant with no catalogue of its own still gets one. English is skipped
--- outright: the source strings are the English.
function M.load(code, requirer)
    requirer = requirer or require
    M.translations, M.lang = {}, nil
    local lang = base(code)
    if not lang or lang == "" or lang == "C" or lang == "en" then return M.translations end

    for _i, name in ipairs({ code, lang }) do
        local ok, tbl = pcall(requirer, "l10n." .. name)
        if ok and type(tbl) == "table" then
            M.translations, M.lang = tbl, name
            return M.translations
        end
    end
    return M.translations
end

--- KOReader's own gettext, or the identity when running outside it.
function M.fallback()
    local ok, gettext = pcall(require, "gettext")
    if ok and gettext then return gettext end
    return function(s) return s end
end

local koreader = M.fallback()

do
    local ok, gettext = pcall(require, "gettext")
    -- current_lang is what KOReader resolved from the reader's choice; the
    -- environment is the desktop fallback, and is what the specs drive.
    M.load(ok and gettext and gettext.current_lang
        or os.getenv("LANGUAGE") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES"))
end

return setmetatable(M, {
    __call = function(_self, msgid)
        local hit = M.translations[msgid]
        if type(hit) == "string" and hit ~= "" then return hit end
        return koreader(msgid)
    end,
})
