--[[
Fakes for the KOReader UI modules main.lua needs, so the menu tree and dialog
flow can be driven off-device.

This verifies *behaviour and copy*: what the menu contains, what each callback
does, and the exact text a user would read. It cannot verify pixels, layout,
fonts or e-ink refresh -- that needs KOReader on a device or a desktop build.
--]]

local M = {}

function M.install()
    local rec = {
        shown = {},          -- every widget passed to UIManager:show
        closed = {},
        next_ticks = {},
        scheduled = {},
        dispatcher = {},
        keyboard_shown = 0,
        transport_calls = {},
    }

    package.loaded["json"] = require("spec.support.json")
    package.loaded["logger"] = { dbg = function() end, info = function() end,
        warn = function() end, err = function() end }
    package.loaded["device"] = {
        isKindle = function() return false end,
        -- reddle_ui_links sizes the QR code off the screen: QRWidget draws one
        -- pixel per module when given neither width nor height.
        screen = {
            getWidth = function() return 1072 end,
            getHeight = function() return 1448 end,
            scaleBySize = function(_, n) return n end,
        },
    }
    package.loaded["ui/event"] = { new = function(_, name) return { name = name } end }
    package.loaded["datastorage"] = {
        getSettingsDir = function() return "/tmp/reddle-spec" end,
        getDataDir = function() return "/tmp/reddle-spec" end,
    }
    package.loaded["ffi/util"] = {
        template = function(fmt, ...)
            local args = { ... }
            return (fmt:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
        end,
    }
    package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })

    -- main.lua requires reddle_http, which pulls in LuaSocket: fake the module
    -- rather than the socket, so main.lua's own wiring is what gets exercised.
    package.loaded["reddle_http"] = {
        transport = function(req)
            table.insert(rec.transport_calls, req)
            return "", 599, {}
        end,
    }

    package.loaded["ui/uimanager"] = {
        show = function(_, w) table.insert(rec.shown, w); return w end,
        close = function(_, w) table.insert(rec.closed, w) end,
        nextTick = function(_, cb) table.insert(rec.next_ticks, cb) end,
        scheduleIn = function(_, s, t) table.insert(rec.scheduled, { secs = s, task = t }) end,
        unschedule = function() end,
        -- Real: flushes the screen before a blocking fetch, so "Loading…" is
        -- actually visible on e-ink rather than arriving with the result.
        forceRePaint = function() end,
        setDirty = function() end,
        insertZMQ = function(_, s) return { server = s } end,
        removeZMQ = function() end,
    }

    package.loaded["ui/network/manager"] = {
        isOnline = function() return true end,
        -- run immediately: the specs care about what happens once online
        runWhenOnline = function(_, cb) cb() end,
    }

    local function widget(kind)
        return { new = function(_, o) o = o or {}; o.widget_kind = kind; return o end }
    end
    package.loaded["ui/widget/infomessage"] = widget("InfoMessage")
    package.loaded["ui/widget/confirmbox"] = widget("ConfirmBox")

    -- TextViewer gets a fuller fake than the rest: reddle_ui_reader subclasses it
    -- and reaches into the widget tree it builds, so `extend` and `init` have to
    -- behave the way KOReader's do or the subclass is not really under test.
    --
    -- The shape mirrors textviewer.lua: init decides is_txt from text_format, and
    -- only the HTML path builds a ScrollHtmlWidget wrapping an HtmlBoxWidget.
    -- setContent calls are recorded because that is where our stylesheet has to
    -- arrive -- embedding it in the body is exactly the bug this guards (§5.2.2).
    local TextViewer = {
        html_text_formats = { html = true, htm = true, md = true },
        justified = true,
        monospace_font = false,
        show_menu = true,   -- textviewer.lua: the title bar's left icon
    }
    -- KOReader's display settings. Reddle overrides onShowMenu and falls back to
    -- this, so the fake has to be callable and countable.
    TextViewer.onShowMenu = function(self)
        self.show_menu_calls = (self.show_menu_calls or 0) + 1
    end
    TextViewer.extend = function(self, subclass)
        subclass = subclass or {}
        subclass.extend, subclass.new = self.extend, self.new
        return setmetatable(subclass, { __index = self })
    end
    TextViewer.new = function(self, o)
        o = setmetatable(o or {}, { __index = self })
        o.widget_kind = "TextViewer"
        if o.init then o:init() end
        return o
    end
    TextViewer.init = function(self, reinit)
        self.init_calls = (self.init_calls or 0) + 1
        self.reinit_last = reinit
        self.is_txt = not self.html_text_formats[self.text_format or ""]
        if self.is_txt then self.scroll_widget = nil; return end
        local htmlbox = { set_content = {} }
        htmlbox.setContent = function(hb, body, css, font_size)
            hb.set_content[#hb.set_content + 1] =
                { body = body, css = css, font_size = font_size }
            -- Relayout is what changes the page count, so a spec that wants the
            -- new document to be a different length sets next_page_count and it
            -- takes effect here rather than before the swap.
            if hb.next_page_count then hb.page_count = hb.next_page_count end
        end
        -- Pagination, enough of it for the position-restoring code in
        -- reddle_ui_reader:setDocument. `page_links` is per page number, and is
        -- what pageOfLink walks looking for its anchor.
        htmlbox.page_number = 1
        htmlbox.page_count = 1
        htmlbox.page_links = {}
        -- The rendered bitmap. Modelled because setContent deliberately does
        -- NOT clear it and _render() returns early while one exists, so a swap
        -- that forgets to free it redraws the previous document.
        htmlbox.bb = "rendered"
        htmlbox.freeBb = function(hb) hb.bb = nil end
        htmlbox.document = {
            openPage = function(_doc, p)
                return {
                    getPageLinks = function() return htmlbox.page_links[p] or {} end,
                    close = function() end,
                }
            end,
        }
        self.scroll_widget = {
            html_body = self.text,
            default_font_size = 20,
            htmlbox_widget = htmlbox,
            reset_calls = 0,
            resetScroll = function(sw) sw.reset_calls = sw.reset_calls + 1 end,
            scrollToRatio = function(sw, ratio) sw.ratio = ratio end,
        }
        -- ScrollHtmlWidget:init lays the document out immediately
        -- (scrollhtmlwidget.lua:48). Recording it here is what makes a wasted
        -- second layout visible to the specs.
        htmlbox:setContent(self.text, "<koreader css>", 20)
    end
    package.loaded["ui/widget/textviewer"] = TextViewer
    package.loaded["ui/time"] = {
        now = function() return 0 end,
        since = function() return 0 end,
        to_ms = function() return 0 end,
    }
    package.loaded["ui/widget/imageviewer"] = widget("ImageViewer")
    package.loaded["ui/widget/buttondialog"] = widget("ButtonDialog")
    package.loaded["ui/widget/qrmessage"] = widget("QRMessage")
    package.loaded["ui/widget/spinwidget"] = widget("SpinWidget")
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function() return nil end,
        mkdir = function() return true end,
    }

    local InputDialog = widget("InputDialog")
    local real_new = InputDialog.new
    InputDialog.new = function(self, o)
        o = real_new(self, o)
        o.input_text = o.input
        o.getInputText = function(s) return s.input_text end
        o.getInputValue = function(s) return tonumber(s.input_text) end
        o.onShowKeyboard = function() rec.keyboard_shown = rec.keyboard_shown + 1 end
        return o
    end
    package.loaded["ui/widget/inputdialog"] = InputDialog

    package.loaded["dispatcher"] = {
        registerAction = function(_, name, def) rec.dispatcher[name] = def end,
    }

    package.loaded["luasettings"] = {
        open = function(_, path)
            local stubs = require("spec.support.stubs")
            local s = stubs.store{}
            s.path = path
            return s
        end,
    }

    package.loaded["ui/widget/container/widgetcontainer"] = {
        extend = function(self, tbl)
            tbl = tbl or {}
            tbl.extend = self.extend
            tbl.new = function(cls, o)
                o = o or {}
                setmetatable(o, { __index = cls })
                if o.init then o:init() end
                return o
            end
            return tbl
        end,
    }

    return rec
end

--- Build the plugin with a fake `ui` host, as KOReader would.
function M.newPlugin(rec)
    local Reddle = require("main")
    local registered = {}
    local plugin = Reddle:new{
        ui = {
            menu = {
                registerToMainMenu = function(_, p) registered[#registered + 1] = p end,
            },
        },
    }
    plugin._registered = registered
    -- The real store writes to disk. Specs must not, so the archive is swapped
    -- for an identical one over an in-memory filesystem.
    plugin.store = M.memoryStore()
    return plugin
end

--- A reddle_store backed by tables rather than files.
function M.memoryStore()
    local Store = require("reddle_store")
    local files, dirs = {}, { ["/mem"] = true }
    return Store.new{
        root = "/mem",
        json = require("spec.support.json"),
        lfs = {
            attributes = function(path, what)
                if dirs[path] then return what == "mode" and "directory" or {} end
                if files[path] then return what == "mode" and "file" or {} end
                return nil
            end,
            mkdir = function(path) dirs[path] = true; return true end,
        },
        io_open = function(path, mode)
            if mode == "rb" then
                local body = files[path]
                if not body then return nil end
                return { read = function() return body end, close = function() end }
            end
            local buf = {}
            return {
                write = function(_, s) buf[#buf + 1] = s; return true end,
                close = function() files[path] = table.concat(buf) end,
            }
        end,
        os_remove = function(path) files[path] = nil; return true end,
        os_rename = function(from, to)
            if not files[from] then return nil, "no such file" end
            files[to], files[from] = files[from], nil
            return true
        end,
        now = function() return 1000 end,
    }
end

--- The menu tree the user actually sees.
function M.menu(plugin)
    local items = {}
    plugin:addToMainMenu(items)
    return items.reddle
end

function M.itemText(item)
    if item.text_func then return item.text_func() end
    return item.text
end

function M.lastShown(rec, kind)
    for i = #rec.shown, 1, -1 do
        if not kind or rec.shown[i].widget_kind == kind then return rec.shown[i] end
    end
end

function M.clear()
    for _, n in ipairs({
        "main", "reddle_api", "reddle_auth", "reddle_pair", "reddle_http", "reddle_identity",
        "json", "logger", "device", "ui/event", "datastorage", "ffi/util", "gettext",
        -- captures whatever gettext was loaded when it was required, so it has
        -- to be dropped with it or a spec that fakes gettext leaks into the next
        "reddle_gettext",
        "ui/uimanager", "ui/network/manager", "ui/widget/infomessage", "ui/widget/inputdialog",
        "ui/widget/confirmbox",
        "dispatcher", "luasettings", "ui/widget/container/widgetcontainer",
        "ui/widget/textviewer", "ui/widget/imageviewer", "ui/widget/buttondialog",
        "libs/libkoreader-lfs", "reddle_ui_post", "reddle_markdown", "reddle_listing",
        "ui/message/simpletcpserver", "ffi/netinfo", "ui/widget/spinwidget",
    }) do package.loaded[n] = nil end
end

return M
