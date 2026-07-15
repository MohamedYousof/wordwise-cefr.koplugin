--[[--
Tools for finding out why a page looks the way it does.

Nothing here is part of reading. It is here because almost every bug in this
plugin was invisible from the outside and obvious from a dump: hints reading
"noun" (Babylon labels its parts of speech on their own line), "şık, temiz
giyimli" over a character called Trig, "bey, İspanyol efendisi" over "don't".
A wrong hint looks just as confident as a right one, so when one turns up, this
is how its provenance gets traced.

Reached from the menu under Diagnostics.
]]

local Engine = require("inlinehints_engine")
local Gloss = require("inlinehints_gloss")
local time = require("ui/time")

local Diagnostics = {}

local function toMs(duration)
    return time.to_us(duration) / 1000
end


--[[--
Times one batched sdcv call over the given words, restricted to dict_names
(nil searches every installed dictionary).
]]
local function timeLookup(ui, words, dict_names)
    local start = time.monotonic()
    local cancelled, results = ui.dictionary:rawSdcv(words, dict_names, false, false)
    local duration = time.since(start)

    local found = 0
    for _, result in ipairs(results or {}) do
        if #result > 0 then
            found = found + 1
        end
    end

    return { ms = toMs(duration), found = found, cancelled = cancelled }
end

--[[--
Builds the list of batch sizes to sweep, always ending at the full candidate
count and never repeating a size.
]]
local function sweepSizes(candidate_count)
    local sizes = {}
    for _, n in ipairs({ 5, 10, 20 }) do
        if n < candidate_count then
            sizes[#sizes + 1] = n
        end
    end
    sizes[#sizes + 1] = candidate_count
    return sizes
end

--[[--
Looks up the first `limit` candidates on the page and reports what
Gloss.extract() made of each entry, stage by stage.

The benchmark answers whether we CAN draw glosses; this answers whether they'd
be worth drawing.

dict_names is an ordered list: sdcv returns each word's matches in the order the
dictionaries are given, so a later one acts as a fallback for free. That matters
because falling back is not just for words the first dictionary lacks -- Babylon
has "buckeye", but only as "atkestanesi türü bir ağaç; ohio'da oturan kimse",
too long to draw, while saja has the usable "at kestanesi". So the fallback
triggers on failing to produce a gloss, not on failing to find the word.

Doing it in one call is also the cheap way round: an extra dictionary costs
~35 ms, whereas a second sdcv call costs a fresh ~145 ms process spawn.

Must be called from inside a Trapper:wrap(). Returns { dicts, entries }, or nil
plus a message.
]]
function Diagnostics.dumpGlosses(ui, limit, dict_names)
    local doc = ui.document
    if not doc or not doc.getPageXPointer then
        return nil, "Inline Hints only works on reflowable documents (EPUB, FB2, ...)."
    end

    local enabled = ui.dictionary and ui.dictionary.enabled_dict_names or {}
    dict_names = dict_names or (enabled[1] and { enabled[1] })
    if not dict_names or #dict_names == 0 then
        return nil, "No StarDict dictionary is enabled."
    end

    local words, err = Engine.collectPageWords(doc)
    if not words then
        return nil, err
    end

    local dropped_names = {}
    local candidates = Engine.selectCandidates(doc, words, dropped_names)
    -- Ask for the base form: that is what most dictionaries actually carry.
    local lookup_words = {}
    for i = 1, math.min(limit, #candidates) do
        lookup_words[i] = candidates[i].lemma
    end
    if #lookup_words == 0 and #dropped_names == 0 then
        return nil, "No candidate words on this page (none rare enough)."
    end

    local cancelled, results = ui.dictionary:rawSdcv(lookup_words, dict_names, false, false)
    if cancelled then
        return nil, "Dictionary lookup was cancelled."
    end

    local entries = {}
    -- The same labels the real thing uses, so this explains what the reader is
    -- actually looking at.
    local labels = Engine.getDictLabels(ui, dict_names)

    for i = 1, #lookup_words do
        -- Results are index-aligned with the words we passed in; each is the
        -- list of dictionaries that had the word, in the order we asked.
        local matches = (results and results[i]) or {}
        local entry = {
            word = candidates[i].text,
            lemma = lookup_words[i],
            level = candidates[i].level,
            found = #matches > 0,
        }
        for m = 1, #matches do
            local match = matches[m]
            local stages = Gloss.extract(match.definition, match.word, labels[match.dict])
            if stages.gloss then
                entry.gloss = stages.gloss
                entry.from = match.dict
                entry.fell_back = m > 1
                break
            end
            if m == 1 then -- keep the first for the log, to see what went wrong
                entry.raw, entry.plain, entry.sense = match.definition, stages.plain, stages.sense
            end
        end
        entries[i] = entry
    end

    return { dicts = dict_names, entries = entries, dropped_names = dropped_names }
end

--[[--
Times the work a page costs, broken down.

Reports each stage separately because the total on its own has never been the
useful number: it was the breakdown that showed sdcv to be a flat ~150ms
whatever it is asked, which is what led to caching words rather than pages, and
to reading ahead rather than optimising the walk.

Must be called from inside a Trapper:wrap(), because rawSdcv() shells out to
sdcv through Trapper:dismissablePopen().

Returns a report table, or nil plus a message.
]]
function Diagnostics.run(ui)
    local doc = ui.document
    if not doc or not doc.getPageXPointer then
        return nil, "Inline Hints only works on reflowable documents (EPUB, FB2, ...)."
    end

    local walk_start = time.monotonic()
    local words, err = Engine.collectPageWords(doc)
    local walk_duration = time.since(walk_start)
    if not words then
        return nil, err
    end

    -- Two SQLite lookups per word on the page, so this is ~500 queries and
    -- needs its own number rather than hiding inside the walk.
    local filter_start = time.monotonic()
    local candidates = Engine.selectCandidates(doc, words)
    local filter_duration = time.since(filter_start)

    -- Boxes are only needed for words we actually gloss, so this is measured
    -- over the candidates rather than every word on the page.
    local boxes_start = time.monotonic()
    local boxes_found = 0
    for _, c in ipairs(candidates) do
        local boxes = doc:getScreenBoxesFromPositions(c.ws, c.we, false)
        if boxes and #boxes > 0 then
            boxes_found = boxes_found + 1
        end
    end
    local boxes_duration = time.since(boxes_start)

    -- One sdcv process for the whole page. rawSdcv() returns results aligned
    -- with the words we passed in, which is what makes batching usable at all.
    --
    -- Two things the first probe couldn't tell apart, and both decide the
    -- design:
    --   * how much of the cost was sdcv searching EVERY installed dictionary
    --     (that probe passed no dict_names), versus just one;
    --   * how much is fixed per-process cost versus per-word search cost. If
    --     it's mostly fixed, capping glosses per line saves nothing and only
    --     buys readability; if it scales per word, the cap is also the page's
    --     performance budget.
    -- Sweeping the batch size against a single dictionary answers both.
    local enabled = ui.dictionary and ui.dictionary.enabled_dict_names or {}
    local cold, sweep, all_dicts
    if #candidates > 0 and #enabled > 0 then
        local lookup_words = {}
        for i, c in ipairs(candidates) do
            lookup_words[i] = c.lemma
        end
        local one_dict = { enabled[1] }

        -- First call also pays to read the dictionary off storage, so it
        -- doubles as the cold measurement and leaves the sweep below warm.
        cold = timeLookup(ui, lookup_words, one_dict)

        sweep = {}
        for _, n in ipairs(sweepSizes(#candidates)) do
            local batch = {}
            for i = 1, n do
                batch[i] = lookup_words[i]
            end
            local result = timeLookup(ui, batch, one_dict)
            result.n = n
            sweep[#sweep + 1] = result
        end

        if #enabled > 1 then
            all_dicts = timeLookup(ui, lookup_words, nil)
        end
    end

    return {
        word_count = #words,
        candidate_count = #candidates,
        boxes_found = boxes_found,
        dict_count = #enabled,
        first_dict = enabled[1],
        walk_ms = toMs(walk_duration),
        filter_ms = toMs(filter_duration),
        boxes_ms = toMs(boxes_duration),
        page_ms = toMs(walk_duration + filter_duration + boxes_duration),
        have_pack = Engine.hasWordPack(),
        cold = cold,
        sweep = sweep,
        all_dicts = all_dicts,
    }
end

return Diagnostics
