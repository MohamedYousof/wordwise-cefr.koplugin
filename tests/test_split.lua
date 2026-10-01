-- Checks that splitting the old probe module left the two halves wired up:
-- diagnostics reaches into the engine, so anything it needs must be exported.
-- Find the plugin next to this test, so this runs from anywhere.
local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]+$")
-- Also the koreader root: lua-ljsqlite3 reaches for ffi/posix_h from there.
package.path = here .. "/../?.lua;" .. here .. "/../../../common/?.lua;"
    .. here .. "/../../../common/?/init.lua;" .. here .. "/../../../?.lua;"
    .. package.path
local ffi = require("ffi")
ffi.loadlib = function() return ffi.load("winsqlite3") end

-- This test is about which module reaches which, so the settings behind them
-- are stubbed out entirely; test_settings covers the rules that govern those.
package.loaded["luasettings"] = {
    open = function()
        return {
            readSetting = function() return nil end,
            saveSetting = function() end,
            flush = function() end,
        }
    end,
}

-- The engine only wants joinPath from this, and the real one drags in posix
-- libraries that don't exist off-device.
package.loaded["ffi/util"] = { joinPath = function(a, b) return a .. "/" .. b end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end }
package.loaded["logger"] = { warn = function() end, dbg = function() end, info = function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return os.getenv("TEMP") or "/tmp" end }
package.loaded["ui/time"] = {
    monotonic = function() return 0 end,
    since = function() return 0 end,
    to_us = function() return 0 end,
}
package.loaded["util"] = {
    UTF8_CHAR_PATTERN = "[%z\1-\127\194-\253][\128-\191]*",
    trim = function(s) return s:match("^%s*(.-)%s*$") end,
    htmlToPlainTextIfHtml = function(t) return t end,
}

local fails = 0
local function check(cond, msg)
    if not cond then fails = fails + 1; print("  FAIL " .. msg) end
end

local ok, Engine = pcall(require, "inlinehints_engine")
check(ok, "engine loads: " .. tostring(Engine))
local ok2, Diagnostics = pcall(require, "inlinehints_diagnostics")
check(ok2, "diagnostics loads: " .. tostring(Diagnostics))
if not (ok and ok2) then print(fails .. " FAILED") os.exit(1) end

-- Everything main.lua or diagnostics calls on the engine.
for _, name in ipairs({
    "collectPageWords", "selectCandidates", "getDictLabels", "preparePage",
    "resolveBoxes", "hasWordPack", "resetCensus", "setCefrLevel",
    "shouldHint", "setPluginPath", "closeDatabases",
    "DEFAULT_CEFR", "CEFR_RANK",
}) do
    check(Engine[name] ~= nil, "engine exports " .. name)
end
for _, name in ipairs({ "run", "dumpGlosses" }) do
    check(Diagnostics[name] ~= nil, "diagnostics exports " .. name)
end

-- The engine must still find the language pack shipped beside it.
Engine.setPluginPath(here .. "/..")
check(Engine.hasWordPack(), "engine opens its language pack")
Engine.closeDatabases()

print(fails == 0 and "module split verified" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
