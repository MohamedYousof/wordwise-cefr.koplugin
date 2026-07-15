--[[--
Guards two rules about settings that are easy to break and silent when broken.

Not a round-trip test: inlinehints_settings.lua only opens a LuaSettings at a
path, so exercising it would be testing KOReader's LuaSettings rather than ours,
and would need half the reader stubbed to do it.

These read the source instead, which is what actually catches the mistakes.
Both are things someone adds in passing, and neither shows up until a setting
quietly fails to stick.
]]
-- Find the plugin next to this test, so this runs from anywhere.
local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]+$")

local fails = 0
local function check(cond, msg)
    if not cond then fails = fails + 1; print("  FAIL " .. msg) end
end

local function read(name)
    local f = assert(io.open(here .. "/../" .. name), "cannot read " .. name)
    local s = f:read("*a")
    f:close()
    return s
end

-- 1. Nothing of ours belongs in the reader's global configuration. The plugin
--    keeps its own file so that deleting it resets the plugin and nothing else.
for _, name in ipairs({ "main.lua", "inlinehints_engine.lua", "inlinehints_gloss.lua",
                        "inlinehints_overlay.lua", "inlinehints_words.lua",
                        "inlinehints_cache.lua", "inlinehints_diagnostics.lua" }) do
    check(not read(name):find("G_reader_settings", 1, true),
          name .. " uses G_reader_settings; it should use inlinehints_settings")
end

-- 2. LuaSettings only writes when told. A saveSetting without a flush() looks
--    like it worked until the reader restarts.
for _, name in ipairs({ "main.lua", "inlinehints_engine.lua" }) do
    local source = read(name)
    local saves, flushes = 0, 0
    for _ in source:gmatch("Settings:saveSetting") do saves = saves + 1 end
    for _ in source:gmatch("Settings:flush") do flushes = flushes + 1 end
    check(flushes >= saves,
          ("%s has %d Settings:saveSetting but only %d Settings:flush"):format(name, saves, flushes))
end

-- Per-book settings are a different thing and must stay in doc_settings: the
-- enabled flag has to be readable before the document renders.
check(read("main.lua"):find('doc_settings:saveSetting("inlinehints_enabled"', 1, true),
      "the per-book enabled flag must live in doc_settings")

print(fails == 0 and "settings rules verified" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
