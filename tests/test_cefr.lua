-- Pins down the CEFR selection rule: a word is glossed when its learner level
-- sits above the reader's own, and words no learner list knows are above every
-- reader. Everything else about the engine is covered elsewhere; this is the
-- one rule this fork changed, so it gets its own test.
local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]+$")
-- Same stub set as test_split: only what the engine's require chain touches,
-- none of it on-device.
package.path = here .. "/../?.lua;" .. here .. "/../../../common/?.lua;"
    .. here .. "/../../../common/?/init.lua;" .. here .. "/../../../?.lua;"
    .. package.path
package.loaded["luasettings"] = {
    open = function()
        return {
            readSetting = function() return nil end,
            saveSetting = function() end,
            flush = function() end,
        }
    end,
}
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

local Engine = require("inlinehints_engine")

-- The word under test, once per row: (lemma, rarity level, CEFR tag).
-- level/cefr nil = the pack knows the word but ranked/tagged nothing.
local function hinted(lemma, level, cefr)
    return Engine.shouldHint(lemma, level, cefr)
end

-- Default reader is B1.
check(Engine.DEFAULT_CEFR == "B1", "default reader level is B1")

-- A dropped word (too common, not English) never gets a hint.
check(not hinted(nil, 0, "A1"), "nil lemma: no hint")
check(not hinted(nil, nil, nil), "nil lemma, no data: no hint")

-- CEFR-tagged words: shown when above the reader, hidden at or below.
check(not hinted("house", 0, "A1"), "A1 word hidden from B1 reader")
check(not hinted("feature", 0, "B1"), "B1 word hidden from B1 reader")
check(hinted("contemplate", nil, "B2"), "B2 word shown to B1 reader")
check(hinted("mitigate", nil, "C1"), "C1 word shown to B1 reader")
check(hinted("crepuscular", nil, "C2"), "C2 word shown to B1 reader")
Engine.setCefrLevel("C1")
check(not hinted("mitigate", nil, "C1"), "C1 word hidden from C1 reader")

-- Moving the reader's level moves the line.
Engine.setCefrLevel("A2")
check(not hinted("house", 0, "A2"), "A2 word hidden from A2 reader")
check(hinted("feature", 0, "B1"), "B1 word shown to A2 reader")
Engine.setCefrLevel("C2")
check(not hinted("contemplate", nil, "B2"), "B2 word hidden from C2 reader")
check(not hinted("crepuscular", nil, "C2"), "C2 word hidden from C2 reader too")
Engine.setCefrLevel("B1")
check(Engine.CEFR_RANK["B1"] == 3, "back to B1: rank 3")

-- Untagged pack words sit above every learner list: always hinted, at any
-- level. The rarity check only keeps out words the pack kept but ranked
-- nothing -- so common that glossing them would be noise.
check(hinted("abate", 4, nil), "untagged rare word shown to B1 reader")
Engine.setCefrLevel("C2")
check(hinted("abate", 4, nil), "untagged rare word shown to C2 reader")
Engine.setCefrLevel("B1")
check(not hinted("was", nil, nil), "untagged unranked word hidden")
-- An unknown tag can never crash the comparison; the word is then treated as
-- untagged pack vocabulary, which the rarity data still vouches for.
check(hinted("house", 0, "zz"), "unknown cefr tag falls back to rarity rule")
check(not hinted("house", nil, "zz"), "unknown tag and no rarity: no hint")

print(fails == 0 and "cefr selection verified" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
