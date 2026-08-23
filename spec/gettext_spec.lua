--[[
Plugin-local translations.

KOReader's gettext is one global catalogue with no per-plugin text domain, so
Reddle's strings can never be in KOReader's .mo files. This layer holds its own
and falls through to KOReader's for the words it already knows.
--]]

-- Restored at the end of the file: every UI module captures gettext when it is
-- first required, so leaving this in place translates the next spec file's menu.
local real_gettext = package.loaded["gettext"]
package.loaded["gettext"] = setmetatable({ current_lang = nil }, {
    __call = function(_self, s) return "[koreader]" .. s end,
})
package.loaded["reddle_gettext"] = nil
local GT = require("reddle_gettext")

--- A stand-in for `require`, so no catalogue has to exist on disk.
local function catalogues(available)
    return function(name)
        local tbl = available[name]
        if not tbl then error("module '" .. name .. "' not found") end
        return tbl
    end
end

describe("reddle_gettext", function()

    describe("choosing a catalogue", function()
        it("takes an exact regional match when there is one", function()
            GT.load("pt_BR", catalogues{ ["l10n.pt_BR"] = { a = "exact" },
                                          ["l10n.pt"] = { a = "generic" } })
            assert_equal("pt_BR", GT.lang)
            assert_equal("exact", GT.translations.a)
        end)

        it("falls back to the language when the region has none", function()
            -- pt_PT and pt_BR differ, but either beats English.
            GT.load("pt_PT", catalogues{ ["l10n.pt"] = { a = "generic" } })
            assert_equal("pt", GT.lang)
            assert_equal("generic", GT.translations.a)
        end)

        it("loads nothing for English, since the source is the English", function()
            GT.load("en_GB", catalogues{ ["l10n.en_GB"] = { a = "x" } })
            assert_nil(GT.lang)
            assert_nil(GT.translations.a)
        end)

        it("survives having no catalogue, an empty code, or the C locale", function()
            for _i, code in ipairs({ "de", "", "C" }) do
                GT.load(code, catalogues{})
                assert_nil(GT.lang, "code " .. code)
            end
            GT.load(nil, catalogues{})
            assert_nil(GT.lang)
        end)

        it("ignores a catalogue that is not a table", function()
            GT.load("de", catalogues{ ["l10n.de"] = "not a table" })
            assert_nil(GT.lang)
        end)
    end)

    describe("translating", function()
        it("prefers Reddle's own string", function()
            GT.load("de", catalogues{ ["l10n.de"] = { ["Front page"] = "Startseite" } })
            assert_equal("Startseite", GT("Front page"))
        end)

        it("falls through to KOReader for words it already translates", function()
            -- "Cancel" and "Save" are in KOReader's catalogue; duplicating them
            -- here would be work for every translator and would drift.
            GT.load("de", catalogues{ ["l10n.de"] = {} })
            assert_equal("[koreader]Cancel", GT("Cancel"))
        end)

        it("treats an empty translation as untranslated, not as an empty string", function()
            -- The template ships every string with "" so a partial translation
            -- is usable; an empty value must not blank the UI.
            GT.load("de", catalogues{ ["l10n.de"] = { ["Front page"] = "" } })
            assert_equal("[koreader]Front page", GT("Front page"))
        end)

        it("is callable exactly like gettext, so call sites do not change", function()
            GT.load("de", catalogues{ ["l10n.de"] = {} })
            assert_true(type(getmetatable(GT).__call) == "function")
        end)
    end)
end)

describe("the string template", function()
    it("covers every string in the plugin", function()
        -- Guards the case where a new string is added and never offered to
        -- translators, which is invisible until somebody reports English text
        -- in a translated build.
        local root = arg and arg[0] and arg[0]:match("(.*)/spec/run%.lua") or "."
        local pipe = io.popen("cd " .. root ..
            " && luajit tools/extract-strings.lua --check 2>&1")
        local out = pipe:read("*a")
        local ok = pipe:close()
        assert_true(ok == true or ok == 0, "template is stale:\n" .. tostring(out))
        assert_match("strings, template up to date", out)
    end)

    it("keys the template by what the code looks up, not by its source text", function()
        -- The source says \n and the runtime msgid holds a newline. Copying the
        -- literal put a backslash in the key, so every multi-line string -- which
        -- is every dialog -- could never match a translation.
        local t = dofile("l10n/TEMPLATE.lua")
        assert_true(t["Failed (HTTP %1)\n%2"] ~= nil,
            "escapes must be interpreted when extracting")
        for key in pairs(t) do
            assert_true(key:find("\\n", 1, true) == nil,
                "key still carries a literal backslash: " .. key)
        end
    end)
end)


--[[
The shipped catalogues. A translation cannot be checked for meaning here, but it
can be checked for the things that break silently: a key nothing looks up, a
lost %1, or a stray newline that reflows a dialog.
--]]
describe("the shipped translations", function()
    local template = dofile("l10n/TEMPLATE.lua")

    local function placeholders(s)
        local found = {}
        for d in s:gmatch("%%(%d)") do found[d] = (found[d] or 0) + 1 end
        return found
    end

    local function newlines(s)
        local n = 0
        for _ in s:gmatch("\n") do n = n + 1 end
        return n
    end

    for _i, code in ipairs({ "fr", "es", "pt", "de" }) do
        describe(code, function()
            local cat = dofile("l10n/" .. code .. ".lua")

            it("translates only strings the plugin actually uses", function()
                -- A key with a typo in it is invisible: it simply never matches.
                for key in pairs(cat) do
                    assert_true(template[key] ~= nil,
                        code .. ": no such string in the plugin: " .. key)
                end
            end)

            it("keeps every placeholder", function()
                -- Losing %1 does not fail, it prints a sentence with a hole.
                for key, value in pairs(cat) do
                    local want, got = placeholders(key), placeholders(value)
                    for d, n in pairs(want) do
                        assert_equal(n, got[d] or 0,
                            code .. ": %" .. d .. " count changed in: " .. key)
                    end
                    for d in pairs(got) do
                        assert_true(want[d] ~= nil,
                            code .. ": invented %" .. d .. " in: " .. key)
                    end
                end
            end)

            it("keeps the line structure of multi-line strings", function()
                for key, value in pairs(cat) do
                    assert_equal(newlines(key), newlines(value),
                        code .. ": line count changed in: " .. key)
                end
            end)

            it("leaves nothing empty, since empty means untranslated", function()
                for key, value in pairs(cat) do
                    assert_true(type(value) == "string" and value ~= "",
                        code .. ": empty value for: " .. key)
                end
            end)

            it("is reachable through the loader", function()
                local GT = require("reddle_gettext")
                GT.load(code)
                assert_equal(code, GT.lang)
                assert_true(next(GT.translations) ~= nil)
            end)
        end)
    end

    it("leaves the words KOReader already translates to KOReader", function()
        -- Translating "Cancel" here would let Reddle's button disagree with
        -- every other Cancel in the reader.
        local cat = dofile("l10n/fr.lua")
        for _i, word in ipairs({ "Cancel", "Save", "Search", "Sort", "Open" }) do
            assert_nil(cat[word], word .. " should fall through to KOReader")
        end
    end)
end)

package.loaded["gettext"] = real_gettext
package.loaded["reddle_gettext"] = nil
