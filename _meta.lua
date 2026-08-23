--[[
Plugin metadata. KOReader's PluginLoader reads this file separately from
main.lua so the plugin can be listed (and toggled off) without being loaded.

Every key here is merged onto the plugin module, with one exception: `name` is
deprecated and ignored -- PluginLoader takes the name from the directory, so
this plugin is called "reddle" because it installs as reddle.koplugin.
--]]
local _ = require("gettext")

return {
    -- "Reddle for Reddit", not "Reddle": Data API Terms 4.2 licenses the Reddit
    -- wordmark outright so long as "for" precedes it. Reddle on its own would
    -- rest instead on an argument about 4.1(b)'s "confusingly similar", which is
    -- Reddit's to judge.
    fullname = _("Reddle for Reddit"),
    description = _([[Read Reddit on your e-reader: front page, subreddits, threaded comments and an offline archive of saved posts.]]),
    version = "0.0.1",
}
