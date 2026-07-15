-- The name filter, exercised the way selectCandidates() runs it: one rarity
-- lookup per word, lower-case record built in pass 1, name test in pass 2.
-- Find the plugin next to this test, so this runs from anywhere.
local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]+$")
package.path = here .. "/../?.lua;" .. here .. "/../../../common/?.lua;"
    .. here .. "/../../../common/?/init.lua;" .. package.path
local seen = {}   -- stands in for the module-level record, accumulating per book

local function isCapitalised(t) local f=t:sub(1,1) return f ~= f:lower() end

-- Pretend language pack: these are the only words rare enough to hint.
local HINTABLE = { trig=true, buckeye=true, brandon=true, periodical=true,
                   abate=true, saturday=true, simplicity=true, airwave=true }

local function selectPage(page)
    local words = {}
    for tok in page:gmatch("[%a']+") do words[#words+1] = tok end

    local rare = {}
    for _, w in ipairs(words) do
        local text = w:lower()
        if HINTABLE[text] then
            local cap = isCapitalised(w)
            if not cap then seen[text] = true end
            rare[#rare+1] = { text = text, capitalised = cap }
        end
    end
    local kept, dropped = {}, {}
    for _, r in ipairs(rare) do
        if not r.capitalised or seen[r.text] then kept[#kept+1] = r.text
        else dropped[#dropped+1] = r.text end
    end
    return kept, dropped
end

local fails = 0
local function check(c, m) if not c then fails=fails+1; print("  FAIL "..m) end end
local function has(t, v) for _,x in ipairs(t) do if x==v then return true end end return false end

-- Page 1, from the book: every name opens a sentence.
local kept, dropped = selectPage([[
Trig has read the feature and listened to Buckeye Brandon podcast three times
Trig starts away but not toward The Flame
]])
check(has(dropped,"trig"), "Trig dropped: only ever capitalised")
check(has(dropped,"buckeye"), "Buckeye dropped: a name here, not the tree")
check(has(dropped,"brandon"), "Brandon dropped")
check(#kept == 0, "nothing hinted on a page of names")

-- Page 2 uses 'abate' in lower case mid-sentence.
kept, dropped = selectPage("the winds abate towards evening")
check(has(kept,"abate"), "abate hinted, lower case")

-- Page 3 opens a sentence with it. Per page this was lost; accumulated it isn't.
kept, dropped = selectPage("Abate is what the storm finally did")
check(has(kept,"abate"), "Abate hinted at a sentence start, because page 2 recorded it")

-- Trig still dropped, however far we read.
kept, dropped = selectPage("Trig closed the door")
check(has(dropped,"trig"), "Trig still dropped after many pages")

-- Ordering: capitalised occurrence comes BEFORE the lower-case one on the page.
seen = {}
kept, dropped = selectPage("Simplicity itself he thought and simplicity was the word")
check(has(kept,"simplicity"), "capitalised first, lower case later on the same page -> still hinted")

-- The record must hold only hintable words, not the book's whole vocabulary.
seen = {}
selectPage("the quick brown fox jumps over the lazy dog and abate")
local n = 0
for _ in pairs(seen) do n = n + 1 end
check(n == 1, "only hintable words recorded, got " .. n)

print(fails == 0 and "all name-filter checks passed" or (fails .. " FAILED"))
