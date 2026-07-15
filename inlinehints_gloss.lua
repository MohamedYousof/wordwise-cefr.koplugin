--[[--
Turns a StarDict entry into a gloss short enough to sit above a word.

This is what decides whether Inline Hints is useful at all. Kindle's glosses are
hand-authored 1-3 word paraphrases; ours have to be salvaged from whatever a
user-installed dictionary returns, which is normally a full entry with several
senses and parts of speech. "abate -> azalmak" is worth drawing above the line;
"abate -> i. azalma, eksilme; f. azaltmak, indirmek" is noise that makes the
page harder to read than no gloss at all.

The rules below were corrected against real output from five of the reader's
dictionaries, which write entries five different ways -- guessing at the format
got it wrong (Babylon spells the part of speech out on its own line rather than
abbreviating it inline, so every gloss came out as "noun"). Gloss.extract()
returns its intermediate stages and Probe.dumpGlosses() prints them, which is
how a new dictionary gets assessed.
]]

local util = require("util")

local Gloss = {}

-- A gloss is drawn in the gap above a line of text, so it competes for
-- horizontal space with its neighbours. These are deliberately tight.
Gloss.DEFAULT_MAX_TERMS = 2
Gloss.MAX_TERMS = Gloss.DEFAULT_MAX_TERMS

-- Length allowance grows with the number of senses asked for, so raising the
-- limit isn't cancelled out by the one below it.
local LEN_PER_TERM = 12

--[[--
Sets how many near-synonyms a gloss may carry ("azaltmak, indirmek" is two).

Changing this changes what every word's gloss is, so the cache is keyed on it
too -- otherwise the old, shorter glosses would simply be served back.
]]
function Gloss.setMaxTerms(terms)
    Gloss.MAX_TERMS = terms or Gloss.DEFAULT_MAX_TERMS
    Gloss.MAX_LEN = Gloss.MAX_TERMS * LEN_PER_TERM
end

Gloss.MAX_LEN = Gloss.DEFAULT_MAX_TERMS * LEN_PER_TERM

-- Counted in characters, not bytes: Turkish glosses are full of multi-byte
-- characters, and "hafifletmek" must not be rejected for being 14 bytes long.
local function utf8Len(text)
    return select(2, text:gsub(util.UTF8_CHAR_PATTERN, ""))
end

-- Part-of-speech markers to drop from the front of a sense, for dictionaries
-- that abbreviate them inline. Turkish-authored ones abbreviate in Turkish
-- (isim, fiil, sıfat, zarf, edat, ünlem, bağlaç), English ones in English.
local POS_PATTERNS = {
    "^n%.", "^v%.", "^vt%.", "^vi%.", "^adj%.", "^adv%.",
    "^prep%.", "^conj%.", "^pron%.", "^int%.", "^interj%.", "^abbr%.",
    "^i%.", "^f%.", "^s%.", "^zf%.", "^e%.", "^ünl%.", "^bağ%.",
}

-- WordNet drops the period and adds the sense number and a colon instead:
-- "adj 1: (used of eyes) open and fixed", "n : the heading of an article".
for _, abbrev in ipairs({ "adj", "adv", "n", "v", "vt", "vi" }) do
    POS_PATTERNS[#POS_PATTERNS + 1] = "^" .. abbrev .. "%s*%d*%s*:"
end

-- Babylon instead spells the part of speech out in full, on a line of its own
-- above the senses:
--     noun
--     [pe·ri·od·i·cal || ‚pɪrɪ'ɑdɪkl]
--     dergi
-- Such a line is a label, never a sense, and has to be skipped -- otherwise
-- every hint comes out as "noun".
--
-- A last resort, not the mechanism: learnLabels() works a dictionary's labels
-- out from the dictionary itself, and this only stands in when that finds
-- nothing (a specialist dictionary holding none of the probe words). It is used
-- no further than that, deliberately, because it is not merely incomplete -- it
-- is wrong in a way that costs real hints. "isim" is Turkish for "name" and
-- "fiil" for "verb", so a dictionary answering "name" with "isim" would have
-- that thrown away as a label. Learned labels never make that mistake: they are
-- only the lines a dictionary repeats, and a meaning doesn't repeat.
local FALLBACK_POS_LINES = {}
for _, word in ipairs({
    "noun", "verb", "auxiliary verb", "modal verb", "adjective", "adverb",
    "preposition", "conjunction", "pronoun", "interjection", "article",
    "abbreviation", "phrase", "idiom", "numeral", "prefix", "suffix",
    "proper name", "plural",
    "isim", "fiil", "sıfat", "zarf", "edat", "ünlem", "bağlaç",
}) do
    FALLBACK_POS_LINES[word] = true
end

--[[--
Strips sense numbering ("1.", "2)") and part-of-speech markers ("n.", "f.")
from the front of a line, repeatedly, since entries often stack them:
"1. f. azaltmak".
]]
local function stripLeadingMarkers(line)
    while true do
        local stripped = line:gsub("^%s+", "")
        -- Stray quote some entries open with: '"i. 1. yüzdeki organlardan biri'
        stripped = stripped:gsub('^"', "")
        stripped = stripped:gsub("^%d+%s*[%.%)]%s*", "")
        for i = 1, #POS_PATTERNS do
            stripped = stripped:gsub(POS_PATTERNS[i] .. "%s*", "")
        end
        if stripped == line then
            return line
        end
        line = stripped
    end
end

--[[--
Words to ask a dictionary about in order to learn how it labels things.

Common enough that any dictionary will have them, and deliberately spread
across parts of speech and meanings: no two should share a translation, or the
repeat count below would mistake a gloss for a label.
]]
Gloss.PROBE_WORDS = {
    "house", "water", "book", "dog", "city", "hand", "tree", "door",
    "run", "eat", "sleep", "sing", "buy", "throw", "wash", "climb",
    "red", "cold", "heavy", "clean", "young", "sharp",
    "quickly", "always", "under", "because",
}

-- A label repeats across entries; a meaning doesn't. Three is enough to be sure
-- while staying under the number of probe words sharing any one part of speech.
local MIN_LABEL_REPEATS = 3

-- Labels are short. This only keeps the counting cheap and stops a long sense
-- from being considered; the repetition test is what actually decides.
local MAX_LABEL_LEN = 20
local MAX_LABEL_WORDS = 2

local function isLabelShaped(line)
    if #line == 0 or #line > MAX_LABEL_LEN then
        return false
    end
    local words = 0
    for _ in line:gmatch("%S+") do
        words = words + 1
    end
    return words <= MAX_LABEL_WORDS
end

--[[--
Learns a dictionary's own label vocabulary from a sample of its entries.

The insight is that a label and a meaning behave differently across entries:
"noun" heads thousands of them, "dergi" heads one. So rather than teaching the
plugin every language's grammatical abbreviations -- which it would always be
one language behind on -- ask the dictionary for a couple of dozen words and
keep the short lines that keep coming back. "Subst.", "n.m." and "сущ." all
fall out of this without anyone naming them.

`definitions` is a flat list of raw entries. Returns a set of lower-cased labels.
]]
function Gloss.learnLabels(definitions)
    local counts = {}
    for _, definition in ipairs(definitions) do
        local seen = {} -- once per entry: a label repeated inside one entry
                        -- ("noun" for two senses) is still one piece of evidence
        local plain = util.htmlToPlainTextIfHtml(definition or "")
        for line in (plain .. "\n"):gmatch("(.-)\n") do
            local candidate = util.trim(stripLeadingMarkers(util.trim(line)):gsub("%b[]", ""))
            local key = candidate:lower()
            if not seen[key] and isLabelShaped(candidate) then
                seen[key] = true
                counts[key] = (counts[key] or 0) + 1
            end
        end
    end

    local labels = {}
    for text, n in pairs(counts) do
        if n >= MIN_LABEL_REPEATS then
            labels[text] = true
        end
    end
    return labels
end


--[[--
Picks the first line that carries an actual sense.

An entry opens with anything but the definition: the headword, a part-of-speech
label, pronunciation. Each of those has to be recognised and skipped.

`labels` is what this dictionary was seen to call its parts of speech. When we
have them they are used alone: they describe this dictionary, whereas the
fallback list is guesswork that can throw away a real meaning.
]]
local function firstSenseLine(plain, headword, labels)
    if not labels or next(labels) == nil then
        labels = FALLBACK_POS_LINES
    end
    local lower_headword = headword and headword:lower() or nil
    for line in (plain .. "\n"):gmatch("(.-)\n") do
        local candidate = stripLeadingMarkers(util.trim(line))
        -- Drop pronunciation, which Babylon writes as a bracketed run holding
        -- the syllabified headword and IPA: "[fea·ture || 'fɪːtʃə(r)]".
        candidate = util.trim(candidate:gsub("%b[]", ""))
        local lower = candidate:lower()
        if #candidate > 0 and not labels[lower] and lower ~= lower_headword then
            return candidate
        end
    end
    return nil
end

--[[--
Extracts a short gloss for headword from a raw StarDict definition.

`labels` is what this dictionary calls its parts of speech, as learned by
learnLabels(). Optional: without it we fall back to a hardcoded list that only
knows English and Turkish.

Returns a table of every stage -- plain, sense, gloss -- so callers can see
where a bad result went wrong. gloss is nil when nothing usable was found.
]]
function Gloss.extract(definition, headword, labels)
    local stages = {}
    if not definition or definition == "" then
        return stages
    end

    stages.plain = util.htmlToPlainTextIfHtml(definition)
    local sense = firstSenseLine(stages.plain, headword, labels)
    if not sense then
        return stages
    end

    -- Not every dictionary puts one sense per line; some run them all together
    -- and number them inline: "masum, suçsuz. 2. zararsız. 3. saf, safdil".
    -- The leading "1." is already gone, so cut at the next number to keep only
    -- the first sense.
    sense = sense:gsub("%s%d+%.%s.*$", "")
    stages.sense = sense

    -- A sense is usually a list of near-synonyms ("azaltmak, indirmek,
    -- hafifletmek"). The first one or two carry almost all the meaning, and
    -- are all we have room for.
    local terms = {}
    for term in (stages.sense .. ","):gmatch("(.-)[,;/]") do
        -- Trailing period from a dictionary that ends its senses with one
        -- ("başlık, manşet.") would otherwise show up in the gloss.
        term = (util.trim(term):gsub("%.$", ""))
        if #term > 0 then
            terms[#terms + 1] = term
            if #terms >= Gloss.MAX_TERMS then
                break
            end
        end
    end
    if #terms == 0 then
        terms[1] = stages.sense
    end

    local gloss = table.concat(terms, ", ")
    -- Prefer one term over a truncated second: a cut-off word reads as an
    -- error, while a single term just reads as a shorter gloss.
    if utf8Len(gloss) > Gloss.MAX_LEN and #terms > 1 then
        gloss = terms[1]
    end
    -- Still too long: drop it rather than draw something unreadable. The word
    -- is still tappable for the full entry.
    if utf8Len(gloss) <= Gloss.MAX_LEN then
        stages.gloss = gloss
    end
    return stages
end

return Gloss
