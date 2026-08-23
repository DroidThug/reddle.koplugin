--[[
Drives main.lua's menu and dialogs off-device.

Scope: behaviour and copy -- what the menu contains, what callbacks do, and the
exact strings a user reads. NOT pixels, layout, fonts or e-ink refresh.
--]]

local ui_fakes = require("spec.support.ui_fakes")
local stubs = require("spec.support.stubs")

local function fresh()
    ui_fakes.clear()
    local spies = stubs.installKOReaderFakes()  -- netinfo + simpletcpserver for pairing
    local rec = ui_fakes.install()
    local plugin = ui_fakes.newPlugin(rec)
    return plugin, rec, spies
end

describe("main (UI)", function()

    describe("registration", function()
        it("registers itself with the main menu on init", function()
            local plugin = fresh()
            assert_equal(1, #plugin._registered)
        end)

        it("registers a dispatcher action so it can be bound to a gesture", function()
            local _, rec = fresh()
            assert_true(rec.dispatcher["reddle_whoami"] ~= nil)
            assert_equal("ReddleWhoAmI", rec.dispatcher["reddle_whoami"].event)
        end)

        it("opens its settings file next to KOReader's", function()
            local plugin = fresh()
            assert_equal("/tmp/reddle-spec/reddle.lua", plugin.settings.path)
        end)
    end)

    describe("menu", function()
        it("lives under Tools and is called Reddle", function()
            local plugin = fresh()
            local menu = ui_fakes.menu(plugin)
            assert_equal("Reddle", menu.text)
            assert_equal("tools", menu.sorting_hint)
        end)

        it("leads with the ways to start reading, then Saved", function()
            local plugin = fresh()
            local items = ui_fakes.menu(plugin).sub_item_table
            assert_equal(5, #items)
            -- "Popular" until an account is paired: anonymously this is
            -- Reddit's default set, not the reader's own subscriptions.
            assert_equal("Popular", ui_fakes.itemText(items[1]))
            plugin.auth:save("cid", "rt")
            assert_equal("Front page", ui_fakes.itemText(items[1]))
            assert_equal("Go to subreddit…", ui_fakes.itemText(items[2]))
            assert_equal("Saved", ui_fakes.itemText(items[3]))
            -- Account gathers the things you touch once and then forget;
            -- everything else you configure (and both diagnostics) sits below it.
            assert_equal("Account", ui_fakes.itemText(items[4]))
            assert_equal("Settings and about", ui_fakes.itemText(items[5]))
        end)

        it("keeps the diagnostics out of the top level", function()
            -- A rendering probe next to "Front page" is a development artefact,
            -- not a feature.
            local plugin = fresh()
            local about = ui_fakes.menu(plugin).sub_item_table[5].sub_item_table
            assert_equal("Images: fit the screen", ui_fakes.itemText(about[1]))
            assert_equal("Offline save limit: 25 requests", ui_fakes.itemText(about[2]))
            assert_equal("Clear read markers (0)", ui_fakes.itemText(about[3]))
            assert_equal("Rendering test", ui_fakes.itemText(about[4]))
            assert_equal("About Reddle", ui_fakes.itemText(about[5]))
        end)

        it("greys out Clear read markers when nothing has been read", function()
            local plugin = fresh()
            local clear = ui_fakes.menu(plugin).sub_item_table[5].sub_item_table[3]
            assert_false(clear.enabled_func())
            plugin.read:mark("abc")
            assert_true(clear.enabled_func())
            assert_equal("Clear read markers (1)", ui_fakes.itemText(clear))
        end)

        it("keeps account actions together in one submenu", function()
            local plugin = fresh()
            local items = ui_fakes.menu(plugin).sub_item_table
            local account = items[4].sub_item_table
            assert_equal("Check login", ui_fakes.itemText(account[1]))
            assert_equal("Pair…", ui_fakes.itemText(account[2]))
            assert_equal("Pairing port: 8888", ui_fakes.itemText(account[3]))
            assert_equal("Log out", ui_fakes.itemText(account[4]))
        end)

        it("builds Saved at open time, not at registration", function()
            -- A static sub_item_table is evaluated once when the menu is
            -- registered, so a post saved afterwards would never appear.
            local plugin = fresh()
            local saved = ui_fakes.menu(plugin).sub_item_table[3]
            assert_true(saved.sub_item_table_func ~= nil,
                "Saved must build lazily")
            assert_nil(saved.sub_item_table)
        end)

        it("remembers the last subreddit in the menu label", function()
            local plugin = fresh()
            plugin.settings:saveSetting("last_subreddit", "eink")
            assert_equal("Go to subreddit… (r/eink)",
                ui_fakes.itemText(ui_fakes.menu(plugin).sub_item_table[2]))
        end)

        it("keeps the menu open for the entries that do not navigate away", function()
            local plugin = fresh()
            local items = ui_fakes.menu(plugin).sub_item_table
            for _, item in ipairs(items[4].sub_item_table) do
                assert_true(item.keep_menu_open, ui_fakes.itemText(item))
            end
            for _, item in ipairs(items[5].sub_item_table) do
                -- a submenu opens rather than acting, so it needs no flag
                assert_true(item.keep_menu_open or item.sub_item_table_func ~= nil,
                    ui_fakes.itemText(item))
            end
            -- the browse entries open a screen, so the menu must close
            assert_false(items[1].keep_menu_open)
            assert_false(items[2].keep_menu_open)
        end)

        it("shows the configured port in the menu label, not the default", function()
            local plugin = fresh()
            plugin.settings:saveSetting("pair_port", 9001)
            local account = ui_fakes.menu(plugin).sub_item_table[4].sub_item_table
            assert_equal("Pairing port: 9001", ui_fakes.itemText(account[3]))
        end)
    end)

    describe("Browsing", function()
        local function withListingStub()
            local plugin, rec = fresh()
            local opened = {}
            package.loaded["reddle_ui_listing"] = {
                -- dot call, not colon: the listing view is a plain module now
                open = function(o) opened[#opened + 1] = o end,
            }
            return plugin, rec, opened
        end

        it("refuses to browse before pairing, and says why", function()
            local plugin, rec, opened = withListingStub()
            plugin:openListing("kindle")
            assert_equal(0, #opened)
            assert_match("Not set up yet", ui_fakes.lastShown(rec, "InfoMessage").text)
        end)

        it("opens the front page with no subreddit once paired", function()
            local plugin, _, opened = withListingStub()
            plugin.auth:save("cid", "rt")
            plugin:openListing(nil)
            assert_equal(1, #opened)
            assert_nil(opened[1].subreddit)
            assert_equal("hot", opened[1].sort)
        end)

        it("remembers a sort the reader picks, so it is not chosen twice", function()
            -- The setting was read but never written until 2026-08-16.
            local plugin, _, opened = withListingStub()
            plugin.auth:save("cid", "rt")
            plugin:openListing("kindle")
            opened[1].on_sort("top", "week")
            assert_equal("top", plugin.settings:readSetting("sort"))
            assert_equal("week", plugin.settings:readSetting("sort_time"))

            local again = {}
            package.loaded["reddle_ui_listing"] = { open = function(o) again[1] = o end }
            plugin:openListing("kindle")
            assert_equal("top", again[1].sort)
            assert_equal("week", again[1].time)
        end)

        it("offers to save a post held down in the listing", function()
            -- Saving used to need the post open. The listing already holds the
            -- summary, so a long press can save it without a request.
            local plugin, _, opened = withListingStub()
            local asked = {}
            package.loaded["reddle_ui_saved"] = {
                saveDialog = function(o) asked[#asked + 1] = o end,
            }
            plugin.auth:save("cid", "rt")
            plugin:openListing("eink")
            opened[1].on_hold{ id = "p1", subreddit = "eink", title = "t" }
            package.loaded["reddle_ui_saved"] = nil
            assert_equal(1, #asked)
            assert_equal("p1", asked[1].post.id)
            assert_equal(plugin.store, asked[1].store)
            -- No rows: the listing has none, and fetching them behind a long
            -- press would spend a call the reader did not ask for.
            assert_nil(asked[1].rows)
        end)

        it("remembers the subreddit it was sent to", function()
            local plugin, _, opened = withListingStub()
            plugin.auth:save("cid", "rt")
            plugin:openListing("eink")
            assert_equal("eink", opened[1].subreddit)
            assert_equal("eink", plugin.settings:readSetting("last_subreddit"))
        end)

        it("accepts a subreddit typed with the r/ prefix", function()
            local plugin, rec, opened = withListingStub()
            plugin.auth:save("cid", "rt")
            plugin:askSubreddit()
            local dlg = ui_fakes.lastShown(rec, "InputDialog")
            dlg.input_text = "r/koreader"
            dlg.buttons[1][2].callback()
            assert_equal("koreader", opened[1].subreddit)
        end)

        it("rejects names Reddit could not have", function()
            for _, bad in ipairs({ "a", "has space", "way_too_long_subreddit_name_here", "bad-dash", "" }) do
                local plugin, rec, opened = withListingStub()
                plugin.auth:save("cid", "rt")
                plugin:askSubreddit()
                local dlg = ui_fakes.lastShown(rec, "InputDialog")
                dlg.input_text = bad
                dlg.buttons[1][2].callback()
                assert_equal(0, #opened, "should not open for " .. string.format("%q", bad))
                assert_match("Not a subreddit name", ui_fakes.lastShown(rec, "InfoMessage").text)
            end
        end)

        it("trims surrounding whitespace rather than rejecting it", function()
            local plugin, rec, opened = withListingStub()
            plugin.auth:save("cid", "rt")
            plugin:askSubreddit()
            local dlg = ui_fakes.lastShown(rec, "InputDialog")
            dlg.input_text = "  kindle  "
            dlg.buttons[1][2].callback()
            assert_equal("kindle", opened[1].subreddit)
        end)
    end)

    describe("Check login", function()
        it("tells an unpaired user what to do instead of showing a raw error", function()
            local plugin, rec = fresh()
            plugin:onReddleWhoAmI()
            local msg = ui_fakes.lastShown(rec, "InfoMessage")
            assert_true(msg ~= nil, "an InfoMessage should be shown")
            assert_match("pair", msg.text:lower())
        end)

        it("does not say 'HTTP nil' when there was never a request", function()
            local plugin, rec = fresh()
            plugin:onReddleWhoAmI()
            local text = ui_fakes.lastShown(rec, "InfoMessage").text
            assert_false(text:lower():find("nil") ~= nil, "user-facing text contains 'nil': " .. text)
            assert_false(text:find("HTTP") ~= nil, "no HTTP code exists to report: " .. text)
        end)

        it("never reaches the network without credentials", function()
            local plugin, rec = fresh()
            plugin:onReddleWhoAmI()
            assert_equal(0, #rec.transport_calls)
        end)

        it("shows the username and the remaining API budget when it works", function()
            local plugin, rec = fresh()
            plugin.api = {
                ratelimit = { remaining = 9997 },
                get = function() return { name = "xhuh" }, 200 end,
            }
            plugin:onReddleWhoAmI()
            local msg = ui_fakes.lastShown(rec, "InfoMessage")
            assert_match("u/xhuh", msg.text)
            assert_match("9997", msg.text)
        end)

        it("omits the budget line when Reddit sent no rate-limit headers", function()
            local plugin, rec = fresh()
            plugin.api = { ratelimit = nil, get = function() return { name = "xhuh" }, 200 end }
            plugin:onReddleWhoAmI()
            assert_equal("u/xhuh", ui_fakes.lastShown(rec, "InfoMessage").text)
        end)

        it("surfaces the HTTP code on failure", function()
            local plugin, rec = fresh()
            plugin.api = { get = function() return nil, 503, "upstream is sad" end }
            plugin:onReddleWhoAmI()
            local msg = ui_fakes.lastShown(rec, "InfoMessage")
            assert_match("503", msg.text)
            assert_match("upstream is sad", msg.text)
        end)
    end)

    describe("Pair with desktop", function()
        it("shows the IP, port and one-time code the desktop needs", function()
            local plugin, rec = fresh()
            plugin:startPairing()
            local msg = ui_fakes.lastShown(rec, "InfoMessage")
            assert_match("192%.168%.1%.42", msg.text)
            assert_match("8888", msg.text)
            assert_match("%d%d%d%d%d%d", msg.text)
        end)

        it("shows an address to open, not a command to run", function()
            local plugin, rec = fresh()
            plugin:startPairing()
            local text = ui_fakes.lastShown(rec, "InfoMessage").text
            -- The desktop needs no software now, so the screen must not send
            -- the reader off to run a shell script (DESIGN.md ss3.3d).
            assert_match("http://192%.168%.1%.42:8888", text)
            assert_match("Code:", text)
            assert_true(text:find("reddle%-bridge") == nil,
                "the page flow should not tell the user to run the bridge")
            -- no line should be long enough to wrap on a narrow screen
            for l in (text .. "\n"):gmatch("([^\n]*)\n") do
                assert_true(#l <= 40, "line too long for e-ink: " .. l)
            end
        end)

        it("warns that the listener is not permanent", function()
            local plugin, rec = fresh()
            plugin:startPairing()
            assert_match("5 minutes", ui_fakes.lastShown(rec, "InfoMessage").text)
        end)

        it("stops the listener when the dialog is dismissed", function()
            local plugin, rec = fresh()
            local Pair = require("reddle_pair")
            plugin:startPairing()
            assert_true(Pair:isRunning())
            ui_fakes.lastShown(rec, "InfoMessage").dismiss_callback()
            assert_false(Pair:isRunning())
        end)

        it("stores the credentials and confirms when the desktop pairs", function()
            local plugin, rec = fresh()
            local Pair = require("reddle_pair")
            plugin:startPairing()
            Pair.on_paired("cid-live", "rt-live")
            assert_equal("cid-live", plugin.settings:readSetting("client_id"))
            assert_equal("rt-live", plugin.settings:readSetting("refresh_token"))
            assert_match("Paired", ui_fakes.lastShown(rec, "InfoMessage").text)
        end)

        it("says where to look when it cannot detect the IP", function()
            local plugin, rec = fresh()
            local Pair = require("reddle_pair")
            -- Every strategy has to be silenced, not just ffi/netinfo: the
            -- socket route lookup would otherwise return the IP of whatever
            -- machine is running the specs.
            local real = Pair.IP_STRATEGIES
            Pair.IP_STRATEGIES = { function() return nil end }
            plugin:startPairing()
            Pair.IP_STRATEGIES = real

            local text = ui_fakes.lastShown(rec, "InfoMessage").text
            -- Not "check Wi-Fi": the listener is up and the flow still works,
            -- the reader just has to find the address themselves.
            assert_match("Network info", text)
            assert_match("Code:", text)
            assert_true(text:find("<") == nil)
        end)
    end)

    describe("Log out", function()
        it("is offered only when there is something to log out of", function()
            local plugin = fresh()
            local account = ui_fakes.menu(plugin).sub_item_table[4].sub_item_table
            assert_false(account[4].enabled_func())
            plugin.auth:save("cid", "rt")
            assert_true(account[4].enabled_func())
        end)

        it("asks before doing it", function()
            local plugin, rec = fresh()
            plugin.auth:save("cid", "rt")
            plugin:confirmLogout()
            local box = ui_fakes.lastShown(rec, "ConfirmBox")
            assert_true(box ~= nil, "no confirmation shown")
            -- Still logged in until the reader agrees.
            assert_true(plugin.auth:hasCredentials())
        end)

        it("says what it does not do, which is revoke", function()
            local plugin, rec = fresh()
            plugin.auth:save("cid", "rt")
            plugin:confirmLogout()
            local text = ui_fakes.lastShown(rec, "ConfirmBox").text
            assert_match("does not revoke", text)
            assert_match("prefs/apps", text)
            -- Nobody with an archive presses this unless it says so.
            assert_match("Saved posts are kept", text)
            -- Logging out no longer means the plugin stops working.
            assert_match("anonymously", text)
        end)

        it("drops the credentials but keeps the client ID", function()
            -- Re-pasting a client ID to switch accounts is pure friction: it
            -- identifies the app, not the user.
            local plugin, rec = fresh()
            plugin.auth:save("cid", "rt")
            plugin:confirmLogout()
            ui_fakes.lastShown(rec, "ConfirmBox").ok_callback()
            assert_equal("cid", plugin.settings:readSetting("client_id"))
            assert_nil(plugin.settings:readSetting("refresh_token"))
            -- Logging out of an account leaves anonymous access working: the
            -- client ID is still there, and that is a whole credential now.
            assert_true(plugin.auth:hasCredentials())
            assert_false(plugin.auth:hasAccount())
        end)

        it("leaves saved posts alone", function()
            local plugin, rec = fresh()
            plugin.auth:save("cid", "rt")
            plugin.store:save({ id = "p1", subreddit = "kindle", title = "T" }, nil, {})
            plugin:confirmLogout()
            ui_fakes.lastShown(rec, "ConfirmBox").ok_callback()
            assert_true(plugin.store:isSaved("p1"))
        end)
    end)

    describe("Saved menu", function()
        it("offers All, and nothing else when the archive is empty", function()
            local plugin = fresh()
            local items = plugin:savedMenu()
            assert_equal("All (0)", ui_fakes.itemText(items[1]))
            assert_equal("Nothing saved yet", ui_fakes.itemText(items[2]))
            assert_false(items[2].enabled_func())
        end)

        it("grows an entry per subreddit as posts are saved", function()
            local plugin = fresh()
            plugin.store:save({ id = "a", subreddit = "kindle", title = "T" }, nil, {})
            plugin.store:save({ id = "b", subreddit = "books", title = "T" }, nil, {})
            plugin.store:save({ id = "c", subreddit = "kindle", title = "T" }, nil, {})

            local items = plugin:savedMenu()
            assert_equal("All (3)", ui_fakes.itemText(items[1]))
            assert_equal("r/books (1)", ui_fakes.itemText(items[2]))
            assert_equal("r/kindle (2)", ui_fakes.itemText(items[3]))
        end)

        it("counts the archive in the top-level label", function()
            local plugin = fresh()
            plugin.store:save({ id = "a", subreddit = "kindle", title = "T" }, nil, {})
            assert_equal("Saved (1)",
                ui_fakes.itemText(ui_fakes.menu(plugin).sub_item_table[3]))
        end)
    end)

    describe("Search", function()
        it("refuses before pairing rather than opening an empty search", function()
            local plugin, rec = fresh()
            plugin:askSearch()
            assert_match("Not set up yet", ui_fakes.lastShown(rec, "InfoMessage").text)
        end)

        it("opens a listing for the query, across all of Reddit", function()
            local plugin, rec = fresh()
            plugin.auth:save("cid", "rt")
            local opened = {}
            package.loaded["reddle_ui_listing"] = { open = function(o) opened[1] = o end }
            plugin:askSearch()
            local dialog = ui_fakes.lastShown(rec, "InputDialog")
            dialog.input_text = "  e ink  "
            dialog.buttons[1][2].callback()
            package.loaded["reddle_ui_listing"] = nil
            assert_equal("e ink", opened[1].query, "trimmed at the ends only")
            assert_nil(opened[1].subreddit)
            -- Relevance, not the browsing sort the reader last picked.
            assert_nil(opened[1].sort)
        end)

        it("does nothing on an empty query instead of searching for nothing", function()
            local plugin, rec = fresh()
            plugin.auth:save("cid", "rt")
            local opened = {}
            package.loaded["reddle_ui_listing"] = { open = function(o) opened[1] = o end }
            plugin:askSearch()
            local dialog = ui_fakes.lastShown(rec, "InputDialog")
            dialog.input_text = "   "
            dialog.buttons[1][2].callback()
            package.loaded["reddle_ui_listing"] = nil
            assert_nil(opened[1])
        end)

        it("is reachable from any screen through the router", function()
            local plugin = fresh()
            assert_true(type(plugin:linkContext().search) == "function")
        end)
    end)

    describe("About", function()
        -- fresh() reloads reddle_identity, so the module has to be taken after
        -- it: a reference held from before points at a discarded copy.
        it("marks the shipped example user agent as a placeholder", function()
            -- An unset identity and a chosen one both read as plain "own", which
            -- is how an install sends the example user agent unnoticed.
            local plugin, rec = fresh()
            require("reddle_identity").active = "own"
            plugin:showAbout()
            local text = ui_fakes.lastShown(rec, "InfoMessage").text
            assert_match("API identity: own %(placeholder user agent%)", text)
        end)

        it("says nothing about placeholders for a real identity", function()
            local plugin, rec = fresh()
            local Id = require("reddle_identity")
            local before = Id.active
            Id.active = "redreader"
            plugin.settings:saveSetting("identity", "redreader")
            plugin:showAbout()
            local text = ui_fakes.lastShown(rec, "InfoMessage").text
            assert_true(text:find("placeholder") == nil, text)
            Id.active = before
        end)

        it("reports anonymous access as a state, not as a failed sign-in", function()
            local plugin, rec = fresh()
            plugin.settings:saveSetting("client_id", "cid")
            plugin:showAbout()
            assert_match("Access: anonymous", ui_fakes.lastShown(rec, "InfoMessage").text)
        end)
    end)

    describe("Image quality", function()
        local function item(plugin)
            return ui_fakes.menu(plugin).sub_item_table[5].sub_item_table[1]
        end

        it("fits the screen by default, since a bigger file shows no more", function()
            local plugin = fresh()
            local opts = plugin:imageOpts()
            assert_equal("fit", opts.quality)
            assert_equal(1072, opts.width, "the screen is what it fits to")
        end)

        it("offers exactly two choices, with the current one ticked", function()
            local plugin = fresh()
            local choices = item(plugin).sub_item_table_func()
            assert_equal(2, #choices)
            assert_equal("Fit the screen (smaller download)", choices[1].text)
            assert_equal("Original size", choices[2].text)
            assert_true(choices[1].checked_func())
            assert_false(choices[2].checked_func())
        end)

        it("says that greyscale is not Reddle's doing", function()
            -- The obvious reading of "original size" is "in colour". Colour is
            -- KOReader's setting, and nothing here converts anything.
            local plugin = fresh()
            local choices = item(plugin).sub_item_table_func()
            assert_match("never converts", choices[2].help_text)
            assert_match("Color rendering", choices[2].help_text)
        end)

        it("remembers the choice and shows it in the label", function()
            local plugin = fresh()
            item(plugin).sub_item_table_func()[2].callback()
            assert_equal("original", plugin:imageOpts().quality)
            assert_equal("Images: original size", ui_fakes.itemText(item(plugin)))
            item(plugin).sub_item_table_func()[1].callback()
            assert_equal("fit", plugin:imageOpts().quality)
        end)

        it("hands the choice to the screens that download images", function()
            local plugin = fresh()
            plugin.settings:saveSetting("image_quality", "original")
            local threads = {}
            package.loaded["reddle_ui_thread"] = { open = function(o) threads[1] = o end }
            plugin:openPost{ id = "p1", subreddit = "kindle" }
            package.loaded["reddle_ui_thread"] = nil
            assert_equal("original", threads[1].image_opts.quality)
        end)
    end)

    describe("Offline save limit", function()
        local function item(plugin)
            return ui_fakes.menu(plugin).sub_item_table[5].sub_item_table[2]
        end

        it("defaults to the compiled-in ceiling", function()
            local plugin = fresh()
            assert_equal(require("reddle_comments").MAX_EXPANDS_SAVE, plugin:saveExpandMax())
        end)

        it("opens a spinner bounded at something a shared quota survives", function()
            local plugin, rec = fresh()
            item(plugin).callback()
            local spin = ui_fakes.lastShown(rec, "SpinWidget")
            assert_equal(25, spin.value)
            assert_equal(0, spin.value_min)
            assert_equal(100, spin.value_max)
            -- The number is meaningless without knowing what a request buys.
            assert_match("40 replies", spin.info_text)
        end)

        it("remembers what the reader picked", function()
            local plugin, rec = fresh()
            item(plugin).callback()
            ui_fakes.lastShown(rec, "SpinWidget").callback({ value = 8 })
            assert_equal(8, plugin:saveExpandMax())
            assert_equal("Offline save limit: 8 requests", ui_fakes.itemText(item(plugin)))
        end)

        it("says plainly what zero means, rather than showing '0 requests'", function()
            local plugin, rec = fresh()
            item(plugin).callback()
            ui_fakes.lastShown(rec, "SpinWidget").callback({ value = 0 })
            assert_equal(0, plugin:saveExpandMax())
            assert_equal("Offline save limit: never fetch", ui_fakes.itemText(item(plugin)))
        end)

        it("hands the limit to the screens that spend it", function()
            local plugin, _, _ = fresh()
            plugin.settings:saveSetting("save_expand_max", 3)
            local opened = {}
            package.loaded["reddle_ui_saved"] = { openList = function(o) opened[1] = o end }
            plugin:openSaved(nil)
            package.loaded["reddle_ui_saved"] = nil
            assert_equal(3, opened[1].save_expand_max)

            local threads = {}
            package.loaded["reddle_ui_thread"] = { open = function(o) threads[1] = o end }
            plugin:openPost{ id = "p1", subreddit = "kindle" }
            package.loaded["reddle_ui_thread"] = nil
            assert_equal(3, threads[1].save_expand_max)
        end)

        it("ignores a stored value that is not a usable count", function()
            local plugin = fresh()
            plugin.settings:saveSetting("save_expand_max", -4)
            assert_equal(require("reddle_comments").MAX_EXPANDS_SAVE, plugin:saveExpandMax())
        end)
    end)

    describe("Pairing port", function()
        local function openPortDialog()
            local plugin, rec = fresh()
            plugin:setPairingPort(nil)
            return plugin, rec, ui_fakes.lastShown(rec, "InputDialog")
        end

        it("opens a numeric dialog prefilled with the current port", function()
            local _, _, dlg = openPortDialog()
            assert_equal("number", dlg.input_type)
            assert_equal("8888", dlg.input)
            assert_equal("Pairing port", dlg.title)
        end)

        it("raises the keyboard, since typing is the only thing to do", function()
            local _, rec = openPortDialog()
            assert_equal(1, rec.keyboard_shown)
        end)

        it("saves a valid port and closes", function()
            local plugin, rec, dlg = openPortDialog()
            dlg.input_text = "9001"
            dlg.buttons[1][2].callback()
            assert_equal(9001, plugin.settings:readSetting("pair_port"))
            assert_equal(1, #rec.closed)
        end)

        it("refuses a privileged port and keeps the dialog open", function()
            local plugin, rec, dlg = openPortDialog()
            dlg.input_text = "80"
            dlg.buttons[1][2].callback()
            assert_nil(plugin.settings:readSetting("pair_port"))
            assert_equal(0, #rec.closed)
        end)

        it("refuses nonsense input", function()
            local plugin, _, dlg = openPortDialog()
            dlg.input_text = "not a port"
            dlg.buttons[1][2].callback()
            assert_nil(plugin.settings:readSetting("pair_port"))
        end)

        it("cancel closes without saving", function()
            local plugin, rec, dlg = openPortDialog()
            dlg.input_text = "9001"
            dlg.buttons[1][1].callback()
            assert_nil(plugin.settings:readSetting("pair_port"))
            assert_equal(1, #rec.closed)
        end)
    end)
end)

--[[
The title-bar menu. Search belongs here as well as on the button row: from
inside a thread there is no button row, and backing all the way out to run a
search is the navigation this menu exists to remove.
--]]
describe("reddle_ui_listing.navButtons", function()
    ui_fakes.clear()
    ui_fakes.install()
    package.loaded["reddle_ui_listing"] = nil
    local UiListing = require("reddle_ui_listing")

    local function texts(rows)
        local out = {}
        for _i, row in ipairs(rows) do out[#out + 1] = row[1].text end
        return table.concat(out, "|")
    end

    local LINKS = {
        open_front = function() end,
        ask_subreddit = function() end,
        open_saved = function() end,
        search = function() end,
    }

    it("offers the four ways to get somewhere else", function()
        assert_equal("Front page|Go to subreddit…|Search…|Saved posts",
            texts(UiListing.navButtons(LINKS)))
    end)

    it("prefers a screen's own search over the global one", function()
        -- On a listing, Search means "within this subreddit"; the router's is
        -- the fallback for screens with no listing behind them.
        local mine, global = 0, 0
        local links = {}
        for k, v in pairs(LINKS) do links[k] = v end
        links.search = function() global = global + 1 end
        local rows = UiListing.navButtons(links, function() mine = mine + 1 end)
        for _i, row in ipairs(rows) do
            if row[1].text == "Search…" then row[1].callback() end
        end
        assert_equal(1, mine)
        assert_equal(0, global)
    end)

    it("leaves out what the router cannot do", function()
        -- A screen opened without a router gets no menu rather than dead rows.
        assert_equal("", texts(UiListing.navButtons({})))
        assert_equal("", texts(UiListing.navButtons(nil)))
        assert_equal("Search…", texts(UiListing.navButtons({}, function() end)))
    end)
end)
