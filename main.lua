--[[
Reddle -- UI glue.

The testable logic is in the reddle_* modules, which have no KOReader requires.
This file is the part that only runs on a device: menus, widgets, and wiring the
real transport in.
--]]

local Api = require("reddle_api")
local Auth = require("reddle_auth")
local Cache = require("reddle_cache")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Http = require("reddle_http")
local Identity = require("reddle_identity")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Read = require("reddle_read")
local Store = require("reddle_store")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local Pair = require("reddle_pair")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local JSON = require("json")
local logger = require("logger")
local _ = require("reddle_gettext")
local T = require("ffi/util").template

local Reddle = WidgetContainer:extend{
    name = "reddle",
    is_doc_only = false,
}

function Reddle:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/reddle.lua")
    self.auth = Auth.new{
        store = self.settings,
        transport = Http.transport,
        json = JSON,
    }
    self.api = Api.new{
        transport = Http.transport,
        json = JSON,
        auth = self.auth,
    }
    -- Saved posts live beside the settings, not in cache/: the image cache is
    -- trimmed to a byte budget, and an archive whose contents evict is not an
    -- archive (reddle_archive).
    self.store = Store.new{
        root = DataStorage:getSettingsDir() .. "/reddle_saved",
        lfs = lfs,
        json = JSON,
    }
    -- In memory only, so it costs no storage and starts empty each run.
    self.threads = Cache.new{}
    self.read = Read.new{ store = self.settings }
    self:applyIdentity()
    self:warnPlaceholderIdentity()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

--- Restore the identity chosen during pairing. A bad stored value falls back to
--- the default rather than failing the load, which would lock the user out of
--- the screen that fixes it.
function Reddle:applyIdentity()
    local name = self.settings:readSetting("identity")
    if not name then return end
    local ok, err = Identity.apply{
        identity = name,
        redirect_uri = self.settings:readSetting("identity_redirect_uri"),
        user_agent = self.settings:readSetting("identity_user_agent"),
    }
    if not ok then
        logger.warn("Reddle: stored identity unusable, using the default:", err)
    end
end

--- Said once at start-up, because the placeholder is silent otherwise: every
--- request goes out naming an app that does not exist.
function Reddle:warnPlaceholderIdentity()
    if Identity.isPlaceholder() then
        logger.warn("Reddle: sending the example user agent (" ..
            tostring(Identity.userAgent()) ..
            "). Pair again and pick an identity, or edit reddle_identity.lua.")
    end
end

function Reddle:saveIdentity(identity)
    self.settings:saveSetting("identity", identity.identity)
    if identity.identity == Identity.CUSTOM then
        self.settings:saveSetting("identity_redirect_uri", identity.redirect_uri)
        self.settings:saveSetting("identity_user_agent", Identity.userAgent())
    else
        self.settings:delSetting("identity_redirect_uri")
        self.settings:delSetting("identity_user_agent")
    end
    self.settings:flush()
end

--- All saved posts, then one entry per subreddit that has any. Rebuilt on every
--- open (sub_item_table_func), so saving a post from a new subreddit shows up
--- without restarting.
function Reddle:savedMenu()
    local items = { {
        text_func = function()
            return T(_("All (%1)"), tostring(#self.store:readIndex()))
        end,
        callback = function() self:openSaved(nil) end,
    } }
    local subs = self.store:subreddits()
    if #subs > 0 then items[1].separator = true end
    -- NB: not `for _, row` -- `_` is gettext here, and shadowing it inside the
    -- loop turns every translated string in it into an attempt to call a number.
    for _idx, row in ipairs(subs) do
        items[#items + 1] = {
            text = T(_("r/%1 (%2)"), row.subreddit, tostring(row.count)),
            callback = function() self:openSaved(row.subreddit) end,
        }
    end
    if #subs == 0 then
        items[#items + 1] = {
            text = _("Nothing saved yet"),
            enabled_func = function() return false end,
        }
    end
    return items
end

function Reddle:openSaved(subreddit)
    require("reddle_ui_saved").openList{
        store = self.store,
        subreddit = subreddit,
        api = self.api,
        transport = Http.transport,
        links = self:linkContext(),
        save_expand_max = self:saveExpandMax(),
        image_opts = self:imageOpts(),
    }
end

--- Logging out is not revoking: the token leaves the device but stays valid
--- until revoked at Reddit. The prompt says so, and says saved posts survive.
function Reddle:confirmLogout()
    UIManager:show(ConfirmBox:new{
        text = _([[Log out of Reddit?

The account credentials are removed from this device. Saved posts are kept, and
Reddle keeps working anonymously — without your front page or subscriptions.

This does not revoke access at Reddit — do that at reddit.com/prefs/apps.]]),
        ok_text = _("Log out"),
        ok_callback = function()
            self.auth:clear()
            UIManager:show(InfoMessage:new{ text = _("Logged out.") })
        end,
    })
end

--- Gesture and profile targets, so the entry points can be bound to a swipe or
--- a hotkey instead of four taps through Tools.
function Reddle:onDispatcherRegisterActions()
    Dispatcher:registerAction("reddle_front_page", {
        category = "none", event = "ReddleFrontPage", title = _("Reddle: front page"), general = true,
    })
    Dispatcher:registerAction("reddle_subreddit", {
        category = "none", event = "ReddleSubreddit", title = _("Reddle: go to subreddit"), general = true,
    })
    Dispatcher:registerAction("reddle_saved", {
        category = "none", event = "ReddleSaved", title = _("Reddle: saved posts"), general = true,
    })
    Dispatcher:registerAction("reddle_whoami", {
        category = "none", event = "ReddleWhoAmI", title = _("Reddle: check login"), general = true,
    })
end

function Reddle:onReddleFrontPage()
    self:openListing(nil)
    return true
end

function Reddle:onReddleSubreddit()
    self:askSubreddit()
    return true
end

--- Straight to the whole archive: a gesture that needs a second choice is not a
--- shortcut.
function Reddle:onReddleSaved()
    self:openSaved(nil)
    return true
end

function Reddle:addToMainMenu(menu_items)
    menu_items.reddle = {
        text = _("Reddle"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                -- Anonymously this is Reddit's default set, not the reader's
                -- own subscriptions, and calling it "Front page" would be a
                -- quiet lie about what they are looking at.
                text_func = function()
                    return self.auth:hasAccount() and _("Front page") or _("Popular")
                end,
                callback = function() self:openListing(nil) end,
            },
            {
                text_func = function()
                    local last = self.settings:readSetting("last_subreddit")
                    return last and T(_("Go to subreddit… (r/%1)"), last) or _("Go to subreddit…")
                end,
                callback = function() self:askSubreddit() end,
            },
            {
                -- Built at open time, not at registration: the list of saved
                -- subreddits changes as posts are saved, and a static
                -- sub_item_table is evaluated once and never again.
                text_func = function()
                    local n = #self.store:readIndex()
                    return n > 0 and T(_("Saved (%1)"), tostring(n)) or _("Saved")
                end,
                sub_item_table_func = function() return self:savedMenu() end,
                separator = true,
            },
            {
                text = _("Account"),
                sub_item_table = {
                    {
                        text = _("Check login"),
                        keep_menu_open = true,
                        callback = function() self:onReddleWhoAmI() end,
                    },
                    {
                        text = _("Pair…"),
                        keep_menu_open = true,
                        callback = function() self:startPairing() end,
                    },
                    {
                        text_func = function()
                            return T(_("Pairing port: %1"),
                                self.settings:readSetting("pair_port") or Pair.DEFAULT_PORT)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:setPairingPort(touchmenu_instance)
                        end,
                        separator = true,
                    },
                    {
                        text = _("Log out"),
                        enabled_func = function() return self.auth:hasAccount() end,
                        keep_menu_open = true,
                        callback = function() self:confirmLogout() end,
                    },
                },
            },
            {
                -- Configured once, plus the two diagnostics: one tap further
                -- away than browsing, which is what this menu is opened for.
                text = _("Settings and about"),
                sub_item_table = {
                    {
                        text_func = function()
                            return (self.settings:readSetting("image_quality") == "original")
                                and _("Images: original size")
                                or _("Images: fit the screen")
                        end,
                        sub_item_table_func = function() return self:imageQualityMenu() end,
                    },
                    {
                        text_func = function()
                            local n = self:saveExpandMax()
                            return n > 0
                                and T(_("Offline save limit: %1 requests"), tostring(n))
                                or _("Offline save limit: never fetch")
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:setSaveExpandMax(touchmenu_instance)
                        end,
                        separator = true,
                    },
                    {
                        text_func = function()
                            return T(_("Clear read markers (%1)"), tostring(self.read:count()))
                        end,
                        enabled_func = function() return self.read:count() > 0 end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:confirmClearRead(touchmenu_instance)
                        end,
                        separator = true,
                    },
                    {
                        text = _("Rendering test"),
                        keep_menu_open = true,
                        callback = function() self:renderingTest() end,
                    },
                    {
                        text = _("About Reddle"),
                        keep_menu_open = true,
                        callback = function() self:showAbout() end,
                    },
                },
            },
        },
    }
end

--- What to fetch when the reader opens an image.
---
--- Reddit offers previews up to about 1080 wide beside the source. The default
--- takes the smallest one that still fills the screen: on a 1072px panel a
--- 4000px photo costs several megabytes over a slow radio and shows nothing
--- more. "Original" is there for colour e-ink, where the extra detail is
--- actually visible, and for anyone who would rather have the real file offline.
---
--- Colour is not this setting, and Reddle has no say in it: nothing here
--- converts anything to greyscale, and the previews carry the same colour the
--- source does. What the panel draws is KOReader's own "Color rendering", under
--- Screen settings.
function Reddle:imageOpts()
    return {
        quality = self.settings:readSetting("image_quality") or "fit",
        width = Device.screen and Device.screen:getWidth() or nil,
    }
end

function Reddle:imageQualityMenu()
    local function pick(value)
        return {
            checked_func = function()
                return (self.settings:readSetting("image_quality") or "fit") == value
            end,
            callback = function()
                self.settings:saveSetting("image_quality", value)
                self.settings:flush()
            end,
        }
    end
    local fit, original = pick("fit"), pick("original")
    fit.text = _("Fit the screen (smaller download)")
    original.text = _("Original size")
    original.help_text = _("Reddle never converts an image to greyscale. Whether colour is drawn is KOReader's own “Color rendering” setting, under Screen.")
    return { fit, original }
end

--- How many requests saving one thread for offline may spend completing it.
---
--- Worth exposing rather than compiling in: the quota is shared, and how much
--- of it one saved thread is worth depends on whose client ID is signing the
--- requests. Zero means never fetch -- the save dialog then only offers what is
--- already loaded.
function Reddle:saveExpandMax()
    local n = tonumber(self.settings:readSetting("save_expand_max"))
    if n and n >= 0 then return math.floor(n) end
    return require("reddle_comments").MAX_EXPANDS_SAVE
end

function Reddle:setSaveExpandMax(touchmenu_instance)
    local Comments = require("reddle_comments")
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Offline save limit"),
        info_text = _([[Completing a thread costs one request per 40 replies, so a 1,000-comment thread is about 20.

Reddle stops at this many and saves what it has; the rest can be fetched later from the Saved screen.

Zero means never fetch — saving keeps only what is already on screen.]]),
        value = self:saveExpandMax(),
        value_min = 0,
        value_max = 100,
        default_value = Comments.MAX_EXPANDS_SAVE,
        unit = _("requests"),
        callback = function(spin)
            self.settings:saveSetting("save_expand_max", spin.value)
            self.settings:flush()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

--- Not reversible, so it asks, and names the count -- "all of them" is an
--- unhelpful quantity when the list is not on screen.
function Reddle:confirmClearRead(touchmenu_instance)
    UIManager:show(ConfirmBox:new{
        text = T(_("Forget which %1 posts have been read?\n\nSaved posts are not affected."),
            tostring(self.read:count())),
        ok_text = _("Forget"),
        ok_callback = function()
            self.read:clear()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

--- A stored identity and an unset one both used to read as plain "own", which is
--- how an install can spend months sending the shipped example user agent
--- without anyone noticing. Say which it is.
function Reddle:identityLabel(name)
    if Identity.isPlaceholder() then
        return T(_("%1 (placeholder user agent)"), tostring(name))
    end
    return tostring(name)
end

--- "Anonymous" is a real state, not a failure to sign in, so it is named rather
--- than reported as "signed in: no".
function Reddle:accessLabel()
    local Auth = require("reddle_auth")
    local mode = self.auth:mode()
    if mode == Auth.ACCOUNT then return _("signed in") end
    if mode == Auth.ANONYMOUS then return _("anonymous") end
    return _("not set up")
end

--- Roughly, in whole units, because the point is "is this a problem" rather
--- than an exact byte count.
function Reddle:cacheSize()
    local Post = require("reddle_ui_post")
    local dir = Post.cachePath("x")
    dir = dir and dir:match("^(.*)/[^/]*$")
    local total = 0
    if dir and lfs.dir then
        pcall(function()
            for name in lfs.dir(dir) do
                local a = lfs.attributes(dir .. "/" .. name)
                if a and a.mode == "file" then total = total + (a.size or 0) end
            end
        end)
    end
    if total >= 1024 * 1024 then
        return string.format("%.1f MB", total / (1024 * 1024))
    end
    return string.format("%d KB", math.floor(total / 1024))
end

--- What a bug report needs, on one screen. `self.version` comes from _meta.lua,
--- which PluginLoader merges onto the plugin module; it is absent outside
--- KOReader.
function Reddle:showAbout()
    local Emoji = require("reddle_emoji")
    local identity = self.settings:readSetting("identity") or Identity.active
    UIManager:show(InfoMessage:new{
        text = table.concat({
            T(_("Reddle %1"), tostring(self.version or "dev")),
            "",
            T(_("Access: %1"), self:accessLabel()),
            T(_("API identity: %1"), self:identityLabel(identity)),
            T(_("Saved posts: %1"), tostring(#self.store:readIndex())),
            T(_("Read markers: %1"), tostring(self.read:count())),
            -- Where the storage actually goes. The image cache had no bound at
            -- all until it was measured, so it is worth being able to see it.
            T(_("Images cached: %1"), self:cacheSize()),
            T(_("Threads held: %1"), tostring(self.threads:count())),
            T(_("Emoji font: %1"), Emoji.style() and _("installed") or _("not installed")),
            "",
            _("AGPL-3.0 · github.com/DroidThug/reddle.koplugin"),
        }, "\n"),
    })
end

--- Which styling mechanisms this device's MuPDF actually honours. None of it is
--- answerable off-device.
---
--- Row 1 is the regression test for the finding that started this screen: a
--- <style> element inside the body is discarded, so the sheet has to reach the
--- widget instead. It is styled by a class, and indents only if that is working.
---
--- The rest asks about glyph coverage. A missing glyph draws as nothing, so
--- anything blank below gets a substitution in reddle_emoji.
function Reddle:renderingTest()
    local InfoMessage = require("ui/widget/infomessage")
    local RichText = require("reddle_ui_richtext")
    local RULE = "margin-left: 2em; border-left: 1px solid #999; padding-left: 0.4em;"

    -- KOReader's MuPDF is built with NOBUILTINFONT and resolves fonts through a
    -- hardcoded name-to-path table; it never scans the fonts directory, which is
    -- why installing an emoji font on its own changes nothing. @font-face plus
    -- setContent's resource directory is the only route in.
    --
    -- Row 12 is the shipping form: the font scoped to a span around each emoji,
    -- prose untouched. A regression shows up as prose in the wrong face.
    local Emoji = require("reddle_emoji")
    local face = Emoji.style()
    local face_row = face
        and ("<p>12. scoped @font-face: " .. Emoji.markup("📌 😀 👍 🚀 🏆") ..
             " (emoji drawn, this text unchanged)</p>")
        or "<p>12. no emoji font installed — run tools/install-emoji-font.sh</p>"

    RichText.show{
        title = _("Rendering test"),
        pre_rendered = true,
        -- The real sheet, or the probe lies: with only the two classes below,
        -- h1 and blockquote render unstyled and look like failures.
        -- Rows 13-14 ask whether the read marker can sit in a true corner
        -- instead of trailing the title in normal flow.
        css = require("reddle_html").CSS .. "\n.probe { " .. RULE .. " }"
            .. "\n.cornerbox { border: 1px solid #000000; padding: 0.3em; }"
            .. "\n.floatmark { float: right; color: #666666; }"
            .. "\n.absbox { position: relative; }"
            .. "\n.absmark { position: absolute; top: 0; right: 0; color: #666666; }",
        on_link = function(link)
            UIManager:show(InfoMessage:new{
                text = T(_("Link tapped: %1"), tostring(link and link.uri or "?")), timeout = 4 })
        end,
        html = table.concat({
            '<p class="probe">1. stylesheet (indented = the sheet reaches MuPDF)</p>',
            '<p style="', RULE, '">2. inline attr (indented = inline styles work)</p>',
            '<blockquote>3. blockquote (rule + italic)</blockquote>',
            '<p><a href="reddle:comment:t1_probe">4. tap the anchor text</a></p>',

            -- Read these rows for gaps, not for tofu. Rows 9 and 10 carry raw
            -- emoji: with a font installed they stay blank while row 12 draws,
            -- which is the control proving the <span class="e"> is what works.
            -- Do not run them through Emoji.markup.
            '<p><b>Which of these are missing?</b></p>',

            -- Already in use: stub arrows, the collapse marker, byline separators.
            '<p>5. in use now: ↳ hook · → arrow · ▸ marker · · dot · — dash · ▏ bar</p>',

            -- U+2190-21FF arrows, U+25A0-25FF shapes: the safest candidates for
            -- anything we need to draw ourselves.
            '<p>6. arrows: ← ↑ ↓ ↔ ⇒ ⤷ ↰ ↳</p>',
            '<p>7. shapes: ■ □ ▪ ▫ ● ○ ◆ ◇ ▲ ▼ ★ ☆</p>',

            -- U+2700-27BF dingbats: ticks and crosses for a vote indicator.
            '<p>8. marks: ✓ ✔ ✗ ✘ ✚ ✱ ❯ ❮</p>',

            -- The real emoji planes (U+1F300+). Pin and grinning face are known
            -- tofu; the rest decides how big reddle_emoji.MAP has to be.
            '<p>9. emoji: 📌 pin · 😀 face · 🔥 fire · 👍 up · 💀 skull · 🚀 rocket</p>',
            '<p>10. emoji: ✅ tick · ⚠ warn · ❤ heart · ⭐ star · ⬆ up · 🏆 cup</p>',

            -- How a long unbreakable URL is laid out: it is what the "unsupported
            -- link" dialog has to show before offering a QR code.
            '<p>11. <a href="https://example.com/a/very/long/path?utm_source=reddit' ..
            '&amp;utm_medium=share&amp;s=abcdef0123456789">' ..
            'https://example.com/a/very/long/path?utm_source=reddit&amp;s=abcdef0123456789</a></p>',
            face_row,
            -- Read-marker placement. The shipping form is the square trailing
            -- the title, below; these two ask whether it can go in the corner.
            '<div class="cornerbox"><span class="floatmark">▪</span>'
                .. "13. float: right — is the square at the top-right?</div>",
            '<div class="cornerbox absbox"><span class="absmark">▪</span>'
                .. "14. position: absolute — is the square at the top-right?</div>",
            '<p>15. shipping read marker: <span style="color: #666666;">A read title</span>'
                .. ' <span style="color: #999999;">▪</span> (grey title + square)</p>',
        }),
        text = "HTML rendering is not available on this KOReader build.",
    }
end

-- Required lazily: the widget module pulls in a pile of KOReader widgets that a
-- plugin which is merely loaded should not pay for.
function Reddle:openListing(subreddit, query)
    if not self.auth:hasCredentials() then
        UIManager:show(InfoMessage:new{
            text = _("Not set up yet. Use Account → Pair… first."), timeout = 8 })
        return
    end
    if subreddit and subreddit ~= "" then
        self.settings:saveSetting("last_subreddit", subreddit)
        self.settings:flush()
    end
    -- A search has its own sort set (relevance, top, new...), so it is left for
    -- the listing to default. NB: `query and nil or x` cannot express this --
    -- `nil or x` is x, so the browsing sort would come through anyway.
    local sort
    if not query then sort = self.settings:readSetting("sort") or "hot" end

    local ListingView = require("reddle_ui_listing")
    ListingView.open{
        api = self.api,
        links = self:linkContext(),
        subreddit = subreddit,
        query = query,
        sort = sort,
        time = self.settings:readSetting("sort_time") or "day",
        read = self.read,
        anonymous = not self.auth:hasAccount(),
        on_select = function(post) self:openPost(post) end,
        -- Long-press saves without opening the post. Only the summary is in
        -- memory here, so this is the post-only branch of the dialog; comments
        -- and image can be filled in later from the Saved screen.
        on_hold = function(post)
            require("reddle_ui_saved").saveDialog{
                store = self.store,
                post = post,
                -- No rows here, so there is nothing to complete: the dialog
                -- offers post-only, and the thread can be filled in later.
                image_url = require("reddle_ui_post").imageUrl(post, self:imageOpts()),
                transport = Http.transport,
            }
        end,
        on_sort = function(sort, time)
            self.settings:saveSetting("sort", sort)
            self.settings:saveSetting("sort_time", time)
            self.settings:flush()
        end,
    }
end

function Reddle:askSubreddit()
    local dialog
    dialog = InputDialog:new{
        title = _("Go to subreddit"),
        input = self.settings:readSetting("last_subreddit") or "",
        input_hint = _("kindle"),
        description = _("Without the r/ prefix."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Go"),
                is_enter_default = true,
                callback = function()
                    -- Ends only: stripping interior whitespace would turn "has
                    -- space" into a subreddit nobody asked for. Reddit allows
                    -- [A-Za-z0-9_], 3-21 characters.
                    local sub = (dialog:getInputText() or "")
                        :gsub("^%s+", ""):gsub("%s+$", ""):gsub("^/?r/", "")
                    if sub:match("^[%w_]+$") and #sub >= 3 and #sub <= 21 then
                        UIManager:close(dialog)
                        self:openListing(sub)
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Not a subreddit name.\nLetters, digits and _ only, 3-21 characters."),
                            timeout = 5,
                        })
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Post and comments are one screen: the reader scrolls from the post straight
--- into the thread.
--- Search from anywhere, including a screen with no listing behind it.
function Reddle:askSearch()
    if not self.auth:hasCredentials() then
        UIManager:show(InfoMessage:new{
            text = _("Not set up yet. Use Account → Pair… first."), timeout = 8 })
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search Reddit"),
        input_hint = _("words to look for"),
        description = _("Searches all of Reddit. Inside a subreddit, the Search button below searches only that one."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if q == "" then return end
                    UIManager:close(dialog)
                    self:openListing(nil, q)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Reddle:openPost(post)
    local ThreadView = require("reddle_ui_thread")
    local Listing = require("reddle_listing")
    -- On open rather than on close: a reader who backs out immediately still
    -- saw the thread.
    self.read:mark(post.id)
    ThreadView.open{
        api = self.api,
        post = post,
        subreddit = post.subreddit,
        age = Listing.formatAge(post.created_utc),
        transport = Http.transport,
        links = self:linkContext(),
        -- Lets the thread screen offer Save, which costs no API calls: the post
        -- and its rows are already in memory.
        store = self.store,
        save_expand_max = self:saveExpandMax(),
        image_opts = self:imageOpts(),
        cache = self.threads,
    }
end

--- Everything a tapped link might need. Built here because this is the only
--- place owning both the API and the screens; the router must not require the
--- plugin back.
function Reddle:linkContext()
    if self.link_context then return self.link_context end
    self.link_context = {
        api = self.api,
        transport = Http.transport,
        open_subreddit = function(sub) self:openListing(sub) end,
        -- Also what the title-bar menu on every screen is built from
        -- (reddle_ui_listing.navButtons), so a thread can reach another
        -- subreddit without closing back out to Tools.
        open_front = function() self:openListing(nil) end,
        ask_subreddit = function() self:askSubreddit() end,
        open_saved = function() self:openSaved(nil) end,
        -- The title-bar menu's Search when the screen has no listing of its own
        -- to search within -- from inside a thread, say.
        search = function() self:askSearch() end,
    }
    return self.link_context
end

-- Pairing (DESIGN.md §3.3c): show IP, port and a one-time code, then wait for the
-- desktop bridge to POST the credentials. Nothing about the desktop is configured here.
function Reddle:startPairing()
    NetworkMgr:runWhenOnline(function()
        local port = self.settings:readSetting("pair_port") or Pair.DEFAULT_PORT
        local ok, ip_or_err, actual_port, code = Pair:start(port, function(client_id, refresh_token)
            self.auth:save(client_id, refresh_token)
            UIManager:show(InfoMessage:new{ text = _("Paired. Try 'Check login'.") })
        end, function(client_id, auth_code, identity)
            -- The page's route: the code is single-use, so the exchange happens
            -- here, after the listener has stopped (reddle_pair.onPaste).
            UIManager:show(InfoMessage:new{ text = _("Signing in…"), timeout = 2 })
            -- The chosen identity has to outlive pairing: a refresh would
            -- otherwise go out under a different app's name than the one that
            -- issued the token.
            if identity then self:saveIdentity(identity) end
            local refresh_token, err = self.auth:exchangeCode(client_id, auth_code,
                identity and identity.redirect_uri or nil)
            if not refresh_token then
                UIManager:show(InfoMessage:new{
                    text = T(_("Sign-in failed:\n%1\n\nAuthorization codes expire quickly — try pairing again."),
                        tostring(err)),
                    timeout = 10,
                })
                return
            end
            self.auth:save(client_id, refresh_token)
            UIManager:show(InfoMessage:new{ text = _("Paired. Try 'Check login'.") })
        end, function(client_id, identity)
            -- Anonymous: no exchange, nothing to sign in to. The client ID is
            -- the whole credential, and the first request mints a token.
            if identity then self:saveIdentity(identity) end
            self.auth:saveAnonymous(client_id)
            UIManager:show(InfoMessage:new{
                text = _("Ready. Reading anonymously — no account, no personalised front page.") })
        end)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not start pairing listener:\n%1"), tostring(ip_or_err)),
                timeout = 8,
            })
            return
        end
        -- Shown as a URL, because that is what gets typed into the browser.
        -- When every lookup strategy fails the listener is still up, so say
        -- where to find the address rather than implying Wi-Fi is down.
        local where = ip_or_err
            and T(_("  http://%1:%2"), ip_or_err, actual_port)
            or T(_([[  Could not detect this device's IP.
  Find it under Network info, then open
  http://THAT-IP:%1]]), actual_port)
        UIManager:show(InfoMessage:new{
            text = T(_([[Waiting for a browser…

Open this on your computer:

%1

  Code:  %2

Paste your client ID there, authorize,
then paste the result back.
Listener stops in 5 minutes.]]), where, code),
            dismiss_callback = function() Pair:stop() end,
        })
    end)
end

function Reddle:setPairingPort(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Pairing port"),
        input = tostring(self.settings:readSetting("pair_port") or Pair.DEFAULT_PORT),
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local port = tonumber(dialog:getInputText())
                    if port and port >= 1024 and port <= 65535 then
                        self.settings:saveSetting("pair_port", port)
                        self.settings:flush()
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Reddle:onReddleWhoAmI()
    NetworkMgr:runWhenOnline(function()
        local res, code, err = self.api:get("/api/v1/me")
        -- Anonymously, /api/v1/me answers 200 with a feature blob and no name.
        -- That is a working connection, not a failure, and saying "HTTP 200"
        -- at somebody would be the least helpful possible reading of it.
        local anonymous = self.auth:mode() == require("reddle_auth").ANONYMOUS
        if res and (res.name or anonymous) then
            local rl = self.api.ratelimit
            local text = res.name and ("u/" .. res.name)
                or _("Anonymous — no account, no personalised front page.")
            if rl and rl.remaining then
                text = text .. T(_("\n%1 API calls left this window"), math.floor(rl.remaining))
            end
            UIManager:show(InfoMessage:new{ text = text })
        elseif code then
            UIManager:show(InfoMessage:new{
                text = T(_("Failed (HTTP %1)\n%2"), tostring(code), tostring(err):sub(1, 200)),
                timeout = 10,
            })
        else
            -- No code means no request was made (no credentials, no network),
            -- and "HTTP nil" would be noise.
            UIManager:show(InfoMessage:new{ text = tostring(err):sub(1, 200), timeout = 10 })
        end
    end)
    return true
end

return Reddle
