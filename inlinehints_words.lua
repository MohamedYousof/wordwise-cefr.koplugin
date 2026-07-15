--[[--
The "which words are hard?" half of Inline Hints.

Reads the English language pack built by tools/build_en_db.py from ECDICT and
the CEFR-J profiles. It answers two questions per word, and both matter:

  * What is the base form? "murdered" has to become "murder", because most
    dictionaries only carry lemmas. Measurements on the user's dictionaries
    showed this -- not entry formatting -- to be the biggest cause of missed
    glosses; Babylon only looked better than the others because it happens to
    include inflected forms.
  * How rare is it? Without this we gloss everything, which both buries the
    page and produces bad glosses: "feature" is common enough that a reader
    knows it, and taking its first dictionary sense gives the wrong meaning
    anyway ("yüz hattı" where the text means "özellik"). Filtering by rarity
    removes those words, and the wrong-sense problem largely goes with them.

This layer is deliberately English-only. Rarity data and morphology are
per-language, and the word walk it feeds assumes spaces between words, so
languages like Chinese and Japanese would need their own approach entirely.
Other languages plug in by shipping another pack, not by changing callers.
]]

local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local Words = {}
Words.__index = Words

-- Ships inside the plugin folder so it is simply there on first run, with
-- nothing for the reader to download or install. It is only 1.8 MB, which is
-- what makes that affordable -- dropping ECDICT's Chinese translations, which
-- we have no use for, is most of the reason.
Words.EN_DB_NAME = "inlinehints_en.sqlite3"

--[[--
Opens a language pack read-only.

Read-only is not just caution: the pack ships inside the plugin folder, which
is replaced wholesale when the plugin updates. Anything we generate and want to
keep -- the gloss cache above all -- has to live under DataStorage instead.
]]
function Words.open(db_path)
    local ok, conn = pcall(SQ3.open, db_path, "ro")
    if not ok then
        logger.warn("InlineHints: cannot open language pack", db_path, conn)
        return nil
    end

    local self = setmetatable({ conn = conn }, Words)
    ok = pcall(function()
        self.form_stmt = conn:prepare("SELECT lemma FROM form WHERE form = ?")
        self.lemma_stmt = conn:prepare("SELECT level, cefr, tags FROM lemma WHERE word = ?")
    end)
    if not ok then
        logger.warn("InlineHints: language pack has no usable schema", db_path)
        self:close()
        return nil
    end

    -- step() fills a table we hand it rather than allocating one. A page is
    -- ~250 lookups, so the rows are reused; separate tables per statement so a
    -- narrow result can't leave stale columns behind from a wider one.
    self.form_row = {}
    self.lemma_row = {}
    return self
end

local function queryOne(stmt, row, key)
    -- Reset first: a statement that already reached DONE returns nil forever
    -- otherwise, and resetting up front also recovers from a previous error.
    stmt:clearbind():reset()
    stmt:bind(key)
    return stmt:step(row)
end

--[[--
Resolves a word to its base form and rarity.

Returns lemma, level, cefr, tags. level is 1 (least rare) to 5, and may be nil
for a word the CEFR profiles know but no corpus ranked. Returns nil when the
word isn't worth glossing at all: too common, not English, or absent from the
pack -- which is the answer for the great majority of words on a page.
]]
function Words:lookup(word)
    local lemma = word
    local row = queryOne(self.form_stmt, self.form_row, word)
    if row and row[1] then
        lemma = row[1]
    end

    row = queryOne(self.lemma_stmt, self.lemma_row, lemma)
    if not row then
        return nil
    end
    -- SQLite INTEGERs arrive as int64 cdata, not Lua numbers. They compare
    -- fine, which is what makes this easy to miss, but a cdata used as a table
    -- key hashes by identity, so grouping words by level would silently break.
    local level = row[1] and tonumber(row[1]) or nil
    return lemma, level, row[2], row[3]
end

function Words:close()
    if self.conn then
        self.conn:close() -- also closes the statements prepared on it
        self.conn = nil
    end
end

return Words
