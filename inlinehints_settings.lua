--[[--
This plugin's own settings, in its own file.

Kept out of G_reader_settings so everything here can be read, changed or thrown
away without touching the reader's global configuration -- deleting this one
file resets the plugin and nothing else.

What lives here:
  * min_level, max_terms, excluded_dicts -- what the reader chose.
  * dict_labels -- what we learned about each dictionary's own formatting. Not a
    preference, but it belongs with them: it has to outlive the gloss cache
    (which is emptied whenever the dictionary set changes, while a dictionary's
    labels do not), it is a few dozen short strings, and having it in plain Lua
    means a wrong label can be corrected by hand.

Per-book settings are not here. Whether hints are on is stored in the book's own
doc_settings, because it has to be applied before the document renders.

LuaSettings only writes when told, so call flush() after changing anything.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

return LuaSettings:open(DataStorage:getSettingsDir() .. "/inlinehints.lua")
