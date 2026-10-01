--[[--
This plugin's own settings, in its own file.

Kept out of G_reader_settings so everything here can be read, changed or thrown
away without touching the reader's global configuration -- deleting this one
file resets the plugin and nothing else.

What lives here:
  * cefr, max_terms, excluded_dicts -- what the reader chose.
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
local lfs = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")

-- One-time migration from the upstream-named settings file: this fork used to
-- share "inlinehints.lua" with the original plugin, and anyone upgrading (or
-- with both installed) would otherwise start from zero. The copy is verbatim
-- -- a settings file is just a Lua table in, Lua table out.
local settings_dir = DataStorage:getSettingsDir()
local old_path = settings_dir .. "/inlinehints.lua"
local new_path = settings_dir .. "/wordwise-cefr.lua"
if not lfs.attributes(new_path) and lfs.attributes(old_path) then
    local fin = io.open(old_path, "r")
    if fin then
        local contents = fin:read("*a")
        fin:close()
        local fout = io.open(new_path, "w")
        if fout then
            fout:write(contents)
            fout:close()
        end
    end
end

return LuaSettings:open(new_path)
