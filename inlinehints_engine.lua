--[[--
Works out which words on a page get a hint, and what it says.

The engine, split in two by what the screen forces. Everything here is either
pure or DOM-based -- xpointers, not pixels -- which is what lets preparePage()
run for a page the reader hasn't turned to yet. Only resolveBoxes() needs the
rendered page, and it is the cheap half; see its comment.

The costs, measured on the user's device rather than guessed:
  * the word walk is ~140ms a page and irreducible -- crengine has no bulk
    "give me this page's word boxes" call, since getWordBoxesFromPositions()
    merges word rects into line rects before it returns them;
  * an sdcv call is ~150ms almost regardless of how many words it is given,
    because the cost is starting the process. Hence inlinehints_cache: a word is
    looked up once ever, not once a page.
]]

local Cache = require("inlinehints_cache")
local Gloss = require("inlinehints_gloss")
local Settings = require("inlinehints_settings")
local Words = require("inlinehints_words")
local ffiUtil = require("ffi/util")
local logger = require("logger")

local Engine = {}

-- Guards against a malformed DOM turning the walk below into an infinite loop.
local MAX_WORDS = 3000

-- The reader picks their own English level on the CEFR scale (A1-C2). A word
-- is glossed when its CEFR level is above that: a B1 reader is shown B2, C1
-- and C2 words, and spared the A1-B1 words a learner at their level already
-- knows. The pack stores real learner-vocabulary data (CEFR-J A1-B2, Octanove
-- C1-C2), which is why this works better than a frequency guess.
Engine.DEFAULT_CEFR = "B1"
Engine.CEFR_RANK = { A1 = 1, A2 = 2, B1 = 3, B2 = 4, C1 = 5, C2 = 6 }
local cefr_rank = Engine.CEFR_RANK[Engine.DEFAULT_CEFR]

function Engine.setCefrLevel(cefr)
    cefr_rank = Engine.CEFR_RANK[cefr] or Engine.CEFR_RANK[Engine.DEFAULT_CEFR]
end

--[[--
The whole "does this word get a hint" rule, in one pure function.

lemma comes from the pack; a nil lemma means the word was dropped at build
time -- too common, not English, or not vocabulary -- and never gets a hint.
A word with a CEFR tag is glossed only when its level is above the reader's.

A pack word with no tag has no learner evidence either way, so it rides on
rarity -- but with a floor that moves with the reader. Half the pack is
untagged, and "no tag = always hinted" sent a B2 reader hints for his
mid-frequency vocabulary (measured on his own cache: 55% of untagged hints
sat in the two commonest rarity bands). The assumption: an untagged word this
common is known at any level; only one rarer than two bands below the reader
is worth explaining.
]]
function Engine.shouldHint(lemma, level, cefr)
    if not lemma then return false end
    local rank = cefr and Engine.CEFR_RANK[cefr]
    if rank then return rank > cefr_rank end
    return level ~= nil and level >= cefr_rank - 2
end

-- Max hints on one page. A dense legal page can carry dozens of candidates;
-- past a handful they fight for space and the page turns into confetti.
Engine.DEFAULT_MAX_HINTS = 15
Engine.MAX_HINTS = Engine.DEFAULT_MAX_HINTS

function Engine.setMaxHints(n)
    Engine.MAX_HINTS = n or Engine.DEFAULT_MAX_HINTS
end

--[[--
Keeps the `limit` rarest candidates, in page order.

When a page offers more worthy words than the reader wants hints, the rarest
win the spots -- "propensity" is the plain one, the harder word is the one
that needed explaining. Words with a CEFR tag but no corpus rank sort as the
rarest: the learner lists are the better evidence.
]]
function Engine.prioritize(candidates, limit)
    limit = limit or Engine.MAX_HINTS
    local sorted = {}
    for i, candidate in ipairs(candidates) do
        sorted[i] = candidate
    end
    table.sort(sorted, function(a, b)
        local la, lb = a.level or 6, b.level or 6
        if la ~= lb then
            return la > lb
        end
        return (a.ws or 0) < (b.ws or 0)
    end)
    for i = #sorted, limit + 1, -1 do
        sorted[i] = nil
    end
    return sorted
end

-- Words the reader marked as known: never hinted again, in any form.
Engine.known_words = nil

function Engine.setKnownWords(words)
    Engine.known_words = words
end

-- The engine splits "I'm" into "I" and "m", and ECDICT has an entry for "m",
-- so a stray letter picked up a gloss of its own ("'m (am)") on the page.
-- Nothing under three letters is worth glossing anyway: two-letter words are
-- almost all function words.
local MIN_WORD_LEN = 3

local word_pack
local plugin_path

--[[--
Tells the engine where the plugin lives, so it can find the language pack that
ships alongside it. main.lua gets this for free: PluginLoader sets .path on
every plugin module.
]]
function Engine.setPluginPath(path)
    plugin_path = path
end

local function getWordPack()
    if word_pack == nil and plugin_path then
        word_pack = Words.open(ffiUtil.joinPath(plugin_path, Words.EN_DB_NAME)) or false
    end
    return word_pack or nil
end

local gloss_cache
local cache_fingerprint

--[[--
Opens the gloss cache, reopening it if anything that decides a gloss changed.

That means the dictionaries and their order, and how many senses a gloss may
carry -- all of them change the answer, so all of them are part of the cache's
identity. Miss one and the cache would keep serving glosses made under the old
setting, which looks like the setting being ignored.
]]
local function getCache(dict_names)
    local fingerprint = table.concat(dict_names, "\1") .. "\2" .. tostring(Gloss.MAX_TERMS)
    if gloss_cache ~= nil and cache_fingerprint ~= fingerprint then
        if gloss_cache then
            gloss_cache:close()
        end
        gloss_cache = nil
    end
    if gloss_cache == nil then
        cache_fingerprint = fingerprint
        gloss_cache = Cache.open(fingerprint) or false
    end
    return gloss_cache or nil
end

--[[--
Learns how each dictionary labels its parts of speech, once, and remembers it.

A dictionary that writes "Subst." above every German meaning would otherwise
have "Subst." drawn as the hint for every word -- the same bug Babylon's "noun"
caused, in a language nobody thought to hardcode. Rather than keep adding
languages to a list, ask the dictionary: one sdcv call over a couple of dozen
probe words, and the labels are whatever short lines keep recurring.

Kept in the plugin's settings rather than the gloss cache: a dictionary's labels
don't change when the reader picks a different set of dictionaries, and that is
exactly when the cache is emptied.
]]
function Engine.getDictLabels(ui, dict_names)
    local known = Settings:readSetting("dict_labels") or {}
    local unprofiled = {}
    for i = 1, #dict_names do
        if not known[dict_names[i]] then
            unprofiled[#unprofiled + 1] = dict_names[i]
        end
    end

    for i = 1, #unprofiled do
        local dict_name = unprofiled[i]
        local cancelled, results = ui.dictionary:rawSdcv(Gloss.PROBE_WORDS, { dict_name }, false, false)
        local definitions = {}
        if not cancelled then
            for _, matches in ipairs(results or {}) do
                for _, match in ipairs(matches) do
                    definitions[#definitions + 1] = match.definition
                end
            end
        end
        -- Store even an empty result: a dictionary with no labels to find --
        -- or one that has none of the probe words, which tells us it isn't an
        -- English dictionary -- must not be probed again on every page.
        known[dict_name] = Gloss.learnLabels(definitions)
        local count = 0
        for _ in pairs(known[dict_name]) do count = count + 1 end
        logger.dbg("InlineHints: learned", count, "labels from", dict_name)
    end

    if #unprofiled > 0 then
        Settings:saveSetting("dict_labels", known)
        Settings:flush()
    end
    return known
end

--[[--
Is the language pack there? Only the benchmark asks, so it can say when it is
reporting numbers for the crude length fallback rather than the real filter.
]]
function Engine.hasWordPack()
    return getWordPack() ~= nil
end

--[[--
The lemma a surface form resolves to in the language pack, or nil.

Used when marking a word known: silencing the base form silences every
packed form of it, since the pack's own form table maps them back here.
]]
function Engine.resolveLemma(surface)
    if not word_pack then
        return nil
    end
    local lemma = word_pack:lookup(surface)
    return lemma
end

--[[--
Releases the databases.

Both are deliberately kept open across documents -- neither the language pack
nor a word's gloss depends on which book is being read -- so this is for
shutdown, not for closing a book.
]]
function Engine.closeDatabases()
    if gloss_cache then
        gloss_cache:close()
    end
    gloss_cache, cache_fingerprint = nil, nil
    if word_pack then
        word_pack:close()
    end
    word_pack = nil
end

--[[--
Walks the words of a page, `page` defaulting to the one on screen.

The walk is pure DOM -- xpointers, no screen coordinates -- which is what lets
it run for a page the reader hasn't reached yet. That matters: it is the
expensive half (~140ms) and the only half that can be done ahead of time.

Returns an array of { text, ws, we } (word text and its start/end xpointers),
or nil plus a message if the page range can't be determined.
]]
function Engine.collectPageWords(doc, page)
    local current_page = doc:getCurrentPage()
    page = page or current_page
    local start_xp = doc:getPageXPointer(page)
    if not start_xp then
        return nil, "no xpointer for page " .. tostring(page)
    end

    -- In two-page mode the visible range spans more than one crengine page.
    local nb_visible = 1
    if doc.getVisiblePageCount then
        nb_visible = doc:getVisiblePageCount() or 1
    end
    -- nil past the end of the book.
    local end_xp = doc:getPageXPointer(page + nb_visible)
    if not end_xp and page ~= current_page then
        -- The fallback below asks whether a word is on the page *on screen*,
        -- which answers the wrong question for a page we're reading ahead to.
        -- Rather than walk to the end of the book, give up: it is the last page,
        -- and it will be prepared for real when the reader gets there.
        return nil, "cannot bound page " .. tostring(page)
    end

    local words = {}
    local xp = start_xp
    for _ = 1, MAX_WORDS do
        local ws = doc:getNextVisibleWordStart(xp)
        if not ws then break end
        local we = doc:getNextVisibleWordEnd(ws)
        if not we then break end

        if end_xp then
            -- compareXPointers(a, b) returns 1 only when b is strictly after a,
            -- so anything but 1 means we've reached or passed the page end.
            if doc:compareXPointers(ws, end_xp) ~= 1 then break end
        elseif not doc:isXPointerInCurrentPage(ws) then
            break
        end

        local text = doc:getTextFromXPointers(ws, we)
        if text and text ~= "" then
            -- Original case is kept, not lower-cased: it's what tells a name
            -- from a word (see censusLowercase).
            words[#words + 1] = { text = text, ws = ws, we = we }
        end

        -- Bail out rather than spin if the walk stops making forward progress.
        if doc:compareXPointers(xp, we) ~= 1 then break end
        xp = we
    end

    return words
end

local function isCapitalised(text)
    local first = text:sub(1, 1)
    return first ~= first:lower()
end

-- EPUBs mostly use the typographic apostrophe, not the typewriter one.
local APOSTROPHES = { ["'"] = true, ["\226\128\153"] = true } -- ' and U+2019

--[[--
Detects the wreckage of an "n't" contraction.

The engine splits on the apostrophe, so "don't" arrives as "don" + "t". The "t"
is too short to survive the length filter, but "don" is a perfectly good
three-letter word -- ECDICT has it as the Spanish title -- and it was glossed as
"bey, İspanyol efendisi". Same for "ain't" and "shan't", which score level 4 and
5 and so leak at any setting.

Only "'t" needs this. It is the one contraction that mangles the word before it
(don<-do, won<-will, ain<-am); "chair's" leaves "chair" intact and glossable, so
possessives must not be caught here.
]]
local function isContractionStem(doc, words, i)
    local next_word = words[i + 1]
    if not next_word or next_word.text:lower() ~= "t" then
        return false
    end
    -- Make sure they are joined by an apostrophe rather than merely adjacent.
    local between = doc:getTextFromXPointers(words[i].we, next_word.ws)
    return between ~= nil and APOSTROPHES[between] == true
end

--[[--
Every hintable word this book has used in lower case, so far.

Names are the problem: fiction is full of them, and one that collides with a
real entry produces a hint that looks plausible and is entirely wrong -- this
book's character Trig came out as "şık, temiz giyimli", from the rare adjective
"trig". Capitalisation gives it away, but a word opening a sentence is
capitalised too, and exempting those defeats the check entirely: both of Trig's
appearances open sentences, which is what names do all book long.

So instead of asking "is this capital explained by a sentence start?", ask "does
this word ever appear in lower case?" -- a real word does, a name doesn't.

Asked of the whole book rather than one page, which is what accumulating buys:
per page, a rare word appearing once at the start of a sentence went unhinted;
now it only has to have been used in lower case on some page already read.
Nothing extra is computed -- the walk was doing this count anyway and throwing
it away.

The residual error runs the other way: a name colliding with a word the book
also uses in lower case would be hinted. That needs both to be true of the same
book, whereas the missing hints were happening every few pages.

Held in memory only, and only for words rare enough to hint -- see
selectCandidates() -- which is a couple of thousand per book rather than its
whole vocabulary. Persisting it would mean writing that to a device's flash to
save work that costs nothing to redo.
]]
local seen_lowercase = {}

--[[--
Starts the record again, for a different book.
]]
local census_book

--[[--
Points the record at `book`, forgetting the previous one's words.

Keyed by book rather than cleared on every open, because the two are not the
same event and the difference is felt. Reopening the same book -- or toggling
hints, which reloads the document -- would otherwise throw away a record that is
still exactly right, and the first pages afterwards would go back to judging
names a page at a time.

A KOReader restart does still lose it. That is accepted: it rebuilds as the
reader reads, the only symptom is a handful of missing hints on the way (never
wrong ones), and the alternative is writing a couple of thousand words per book
to a device's flash to save work that costs nothing to redo.
]]
function Engine.resetCensus(book)
    if book ~= nil and book == census_book then
        return
    end
    census_book = book
    seen_lowercase = {}
end

--[[--
Keeps the words on the page that are rare enough to be worth hinting, and
resolves each to the base form the dictionary will actually be asked for.

Falls back to a crude length test when the language pack is missing, so we
report something rather than nothing.

Words dropped by the name filter are collected into `dropped_names` when given.
A filter that silently removes things is one we can't judge: a page yielding no
hints looks the same whether the page is genuinely easy or the filter ate it.
]]
function Engine.selectCandidates(doc, words, dropped_names)
    local pack = getWordPack()

    -- First pass: everything rare enough to hint, and note which of those the
    -- page used in lower case. Two passes because a word can appear capitalised
    -- earlier on the page than it appears in lower case, and the name test below
    -- has to see the whole page before it can judge.
    local rare = {}
    for i = 1, #words do
        local w = words[i]
        local text = w.text:lower()
        if #text >= MIN_WORD_LEN and text:match("^%a+$") then
            local keep, lemma, level, cefr
            if pack then
                lemma, level, cefr = pack:lookup(text)
                keep = Engine.shouldHint(lemma, level, cefr)
                -- A word the reader marked known is known in all its forms.
                if keep and Engine.known_words and
                    (Engine.known_words[lemma] or Engine.known_words[text]) then
                    keep = false
                end
            else
                lemma, keep = text, #text >= 7
            end
            -- Costs an engine call, so it goes after the rarity test, which
            -- rejects nearly everything.
            if keep and isContractionStem(doc, words, i) then
                keep = false
            end
            if keep then
                local capitalised = isCapitalised(w.text)
                if not capitalised then
                    -- Only words that could be hinted are worth remembering: the
                    -- record is consulted for those and no others, so noting
                    -- that "the" appeared in lower case would be storage nothing
                    -- ever reads. This is what keeps a whole book's record to a
                    -- couple of thousand words rather than its entire vocabulary.
                    seen_lowercase[text] = true
                end
                rare[#rare + 1] = {
                    text = text, lemma = lemma, level = level,
                    ws = w.ws, we = w.we, capitalised = capitalised,
                }
            end
        end
    end

    -- Second pass: drop the ones that only ever appear capitalised. They are
    -- names, and a name that collides with a real entry gets a hint that looks
    -- plausible and is entirely wrong.
    local candidates = {}
    for _, r in ipairs(rare) do
        if not r.capitalised or seen_lowercase[r.text] then
            candidates[#candidates + 1] = {
                text = r.text, lemma = r.lemma, level = r.level, ws = r.ws, we = r.we,
            }
        elseif dropped_names then
            dropped_names[#dropped_names + 1] = r.text
        end
    end
    return candidates
end

--[[--
Works out which words on `page` get a hint and what it says.

Everything expensive lives here -- the word walk and, on a cold cache, the sdcv
call -- and none of it touches the screen, so it can run for a page the reader
hasn't turned to yet. That is the whole point of the split: prepared ahead of
time, a page turn only has to resolve boxes, which costs milliseconds.

Must be called from inside a Trapper:wrap(). Returns { page, items }, where each
item is a word and its gloss but no position yet. Returns nil if the page can't
be prepared (past the end of the book, no dictionaries, nothing worth hinting).
]]
function Engine.preparePage(ui, page, dict_names)
    local doc = ui.document
    if not doc or not doc.getPageXPointer then
        return nil
    end
    dict_names = dict_names or (ui.dictionary and ui.dictionary.enabled_dict_names)
    if not dict_names or #dict_names == 0 then
        return nil
    end

    local words = Engine.collectPageWords(doc, page)
    if not words then
        return nil
    end
    local candidates = Engine.prioritize(Engine.selectCandidates(doc, words))
    if #candidates == 0 then
        return { page = page, items = {} }
    end

    -- One lookup per distinct base form. A word repeated on the page was being
    -- looked up once per occurrence; sdcv is flat in batch size so it cost
    -- little, but it also gained nothing.
    local seen, lemmas = {}, {}
    for _, c in ipairs(candidates) do
        if not seen[c.lemma] then
            seen[c.lemma] = true
            lemmas[#lemmas + 1] = c.lemma
        end
    end

    -- Answer from the cache where we can, and collect only the genuinely
    -- unknown words for sdcv. Once a chapter's vocabulary is known this leaves
    -- nothing to ask, and the page costs no dictionary call at all.
    local cache = getCache(dict_names)
    local gloss_of, unknown = {}, {}
    for i = 1, #lemmas do
        local cached = cache and cache:get(lemmas[i])
        if cached == nil then
            unknown[#unknown + 1] = lemmas[i]
        elseif cached then
            gloss_of[lemmas[i]] = cached
        end
        -- cached == false: asked before, nothing usable. Nothing to do.
    end

    if #unknown > 0 then
        -- Before reading any entry, make sure we know how each dictionary marks
        -- up its own. One call per dictionary, once ever.
        local labels = Engine.getDictLabels(ui, dict_names)

        local cancelled, results = ui.dictionary:rawSdcv(unknown, dict_names, false, false)
        if cancelled then
            return nil
        end
        for i = 1, #unknown do
            local matches = (results and results[i]) or {}
            for m = 1, #matches do
                -- match.dict names the dictionary this entry came from, which
                -- is what makes per-dictionary labels usable at all.
                local stages = Gloss.extract(matches[m].definition, matches[m].word,
                                             labels[matches[m].dict])
                if stages.gloss then
                    gloss_of[unknown[i]] = stages.gloss
                    break -- first dictionary that yields a usable gloss wins
                end
            end
        end
        if cache then
            cache:transaction(function()
                for i = 1, #unknown do
                    -- nil gloss is stored too: "podcast" is in none of the
                    -- dictionaries, and without a negative entry we would pay
                    -- an sdcv call for it on every page it appears.
                    cache:put(unknown[i], gloss_of[unknown[i]])
                end
            end)
        end
    end
    -- The number that says whether the cache is doing its job: once a book's
    -- vocabulary is known this should read "0 looked up", and the page then
    -- costs no sdcv call at all.
    logger.dbg("InlineHints:", #lemmas - #unknown, "cached,", #unknown, "looked up")

    local items = {}
    for _, c in ipairs(candidates) do
        local text = gloss_of[c.lemma]
        if text then
            -- level travels with the gloss: when two collide and only one can
            -- be drawn, it decides which word keeps its explanation.
            items[#items + 1] = {
                text = text, word = c.text, level = c.level, ws = c.ws, we = c.we,
            }
        end
    end
    return { page = page, items = items }
end

--[[--
Turns a prepared page into something drawable, by asking where each word is.

Split from preparePage() because this is the one step that cannot be done
early: getWordBoxesFromPositions() resolves to screen coordinates and returns
nothing for a word that isn't on the page currently rendered. It is also the
cheap step -- a few milliseconds -- which is what makes preparing ahead
worthwhile: the page turn is left with only this.
]]
function Engine.resolveBoxes(doc, prepared)
    local glosses = {}
    if not prepared then
        return glosses
    end
    for _, item in ipairs(prepared.items) do
        local boxes = doc:getScreenBoxesFromPositions(item.ws, item.we, false)
        if boxes and boxes[1] then
            glosses[#glosses + 1] = {
                text = item.text, box = boxes[1], word = item.word, level = item.level,
            }
        end
    end
    return glosses
end
return Engine
