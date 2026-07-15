-- Can we work out a dictionary's labels without being told the language?
-- Find the plugin next to this test, so this runs from anywhere.
local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]+$")
package.path = here .. "/../?.lua;" .. here .. "/../../../common/?.lua;"
    .. here .. "/../../../common/?/init.lua;" .. package.path
local util = {}
util.UTF8_CHAR_PATTERN = '[%z\1-\127\194-\253][\128-\191]*'
function util.trim(s) return s:match("^%s*(.-)%s*$") end
local ents = { ["&amp;"]="&", ["&lt;"]="<", ["&gt;"]=">", ["&quot;"]='"', ["&nbsp;"]=" " }
function util.htmlToPlainTextIfHtml(text)
    local _, n = text:gsub("<%w+.->", "")
    if n == 0 then return text end
    text = text:gsub("%s*<%s*br%s*/?>%s*", "\n"):gsub("<[^>]*>", "")
    text = text:gsub("&%a+;", function(e) return ents[e] or e end)
    return (text:gsub("^[\n%s]*", ""):gsub("[\n%s]*$", ""))
end
package.loaded["util"] = util
local Gloss = require("inlinehints_gloss")

local fails = 0
local function check(c, m) if not c then fails = fails + 1; print("  FAIL " .. m) end end

-- Real Babylon English-Turkish entries, verbatim from the on-device dump.
local babylon = {
    '\n<font color="#007000">noun</font><br>\n[pe·ri·od·i·cal]<br>\ndergi',
    '\n<font color="#007000">noun</font><br>\nbaşlık, manşet, afişteki isim',
    '\n<font color="#007000">noun</font><br>\natkestanesi türü bir ağaç',
    '\n<font color="#007000">verb</font><br>\n[lis·ten]<br>\ndinlemek, kulak asmak',
    '\n<font color="#007000">verb</font><br>\növdürmek, cinayet işlemek',
    '\n<font color="#007000">verb</font><br>\ngözlerini dikmek, dik dik bakmak',
    '\n<font color="#007000">adjective</font><br>\nmasum, suçsuz, günahsız',
    '\n<font color="#007000">adjective</font><br>\nsoğuk, serin',
    '\n<font color="#007000">adjective</font><br>\nağır, sıkıntılı',
}
local labels = Gloss.learnLabels(babylon)
check(labels["noun"], "learned 'noun' as a label")
check(labels["verb"], "learned 'verb' as a label")
check(labels["adjective"], "learned 'adjective' as a label")
check(not labels["dergi"], "'dergi' is a meaning, not a label")
check(not labels["soğuk, serin"], "a two-sense line is not a label")

-- A German dictionary: nothing in the code knows these words.
local german = {
    "\nSubst.\ndas Haus",
    "\nSubst.\ndas Wasser",
    "\nSubst.\ndas Buch",
    "\nVerb\nlaufen",
    "\nVerb\nessen",
    "\nVerb\nschlafen",
    "\nAdj.\nrot",
    "\nAdj.\nkalt",
    "\nAdj.\nschwer",
}
labels = Gloss.learnLabels(german)
check(labels["subst."], "learned German 'Subst.' with no German in the code")
check(labels["verb"], "learned German 'Verb'")
check(labels["adj."], "learned German 'Adj.'")
check(not labels["das haus"], "'das Haus' is a meaning")

-- And it must not invent labels where there are none.
labels = Gloss.learnLabels({ "\ndergi", "\nbaşlık", "\nat kestanesi" })
check(next(labels) == nil, "no repeats -> no labels")

-- End to end: the label is skipped and the meaning comes through.
local stages = Gloss.extract("\nSubst.\ndas Haus", "house", Gloss.learnLabels(german))
check(stages.gloss == "das Haus", "German meaning extracted, got " .. tostring(stages.gloss))
-- Without the learned labels the old code would have returned the label itself.
stages = Gloss.extract("\nSubst.\ndas Haus", "house")
-- The trailing period is stripped as sense punctuation, so this reads "Subst".
check(stages.gloss == "Subst", "without learning the label leaks as the hint -- got " .. tostring(stages.gloss))

print(fails == 0 and "all learning checks passed" or (fails .. " FAILED"))

-- Learned labels must be used ALONE, not merged with the hardcoded list.
-- "isim" is Turkish for "name": a dictionary answering "name" with "isim" has
-- given a real meaning, and the fallback list would throw it away as a label.
local babylon_labels = Gloss.learnLabels(babylon)
local s = Gloss.extract('\n<font color="#007000">noun</font><br>\nisim', "name", babylon_labels)
check(s.gloss == "isim", "'isim' kept as the meaning when labels are known, got " .. tostring(s.gloss))

-- With no labels learned we fall back, and there the old mistake stands --
-- accepted, because the alternative is every hint reading "noun".
s = Gloss.extract("\nisim", "name")
check(s.gloss == nil, "fallback still drops 'isim' (known cost of guessing)")

-- The fallback must still do its job on a dictionary we couldn't profile.
s = Gloss.extract("\nnoun\ndergi", "periodical")
check(s.gloss == "dergi", "fallback skips 'noun', got " .. tostring(s.gloss))

print(fails == 0 and "label precedence verified" or (fails .. " FAILED"))
