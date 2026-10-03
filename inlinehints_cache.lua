--[[--
Remembers the gloss found for a word, so sdcv is asked once per word ever
rather than once per page.

Measured on the user's device, one sdcv call costs ~150ms almost regardless of
how many words it is given: the cost is starting the process, not the searching.
So the page path should not contain one at all, and it doesn't have to -- a
word's gloss never changes.

Words with NO gloss are cached too, and that is the important half. "podcast"
isn't in any of the reader's dictionaries and never will be; without a negative
entry it would be looked up again on every page it appears, which is exactly the
lookup we can't afford. A row with a NULL gloss means "asked, found nothing".

Lives under DataStorage rather than in the plugin folder: this is generated
data, and a plugin update replaces its folder wholesale.
]]

local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local Cache = {}
Cache.__index = Cache

Cache.DB_PATH = DataStorage:getSettingsDir() .. "/wordwise-cefr_cache.sqlite3"

-- Bump when the extraction rules change enough that stored glosses are wrong.
-- 2: labels are now learned from each dictionary rather than taken from a
--    hardcoded English/Turkish list, so entries stored before this may hold a
--    part-of-speech label where the meaning should be.
-- 3: rarity comes from wordfreq rather than ECDICT's own ranks, so words the
--    old data had us hinting (alabama, amazon, android) are no longer hinted
--    at all -- their cached meanings would otherwise linger.
-- 4: the bundled dictionaries were rebuilt (FreeDict re-paired and cleaned,
--    WordNet first sense instead of shortest), so stored meanings would be
--    the old answers.
local SCHEMA_VERSION = 4

local SCHEMA = [[
    CREATE TABLE IF NOT EXISTS profile (
        id          INTEGER PRIMARY KEY,
        fingerprint TEXT UNIQUE
    );
    CREATE TABLE IF NOT EXISTS gloss (
        profile INTEGER NOT NULL,
        lemma   TEXT NOT NULL,
        gloss   TEXT,  -- NULL means: looked up, nothing usable found
        PRIMARY KEY (profile, lemma)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT
    ) WITHOUT ROWID;
]]

--[[--
Opens the cache for one set of dictionaries.

`fingerprint` identifies the dictionaries, their order, and anything else that
decides what a word's meaning comes out as. Entries are filed under it rather
than being thrown away when it changes, because a reader can now pick different
dictionaries per book: alternating between an English novel and a German one
would otherwise empty the cache on every switch. The fingerprint is stored once,
in `profile`, and the rows carry its small integer id.

The whole cache is still emptied when SCHEMA_VERSION moves, since that means our
own rules changed and every stored answer is suspect.
]]
function Cache.open(fingerprint)
    local ok, conn = pcall(SQ3.open, Cache.DB_PATH)
    if not ok then
        logger.warn("InlineHints: cannot open gloss cache:", conn)
        return nil
    end

    local self = setmetatable({ conn = conn }, Cache)
    ok = pcall(function()
        conn:exec("PRAGMA journal_mode=WAL;")
        -- Everything here is recoverable by asking sdcv again, so it does not
        -- deserve an fsync per commit -- and this runs on a device whose flash
        -- we should not wear out for a cache. NORMAL in WAL mode cannot corrupt
        -- the database; at worst a power cut loses the last few entries, which
        -- costs one lookup to replace.
        conn:exec("PRAGMA synchronous=NORMAL;")
        conn:exec(SCHEMA)

        local stamp = tostring(SCHEMA_VERSION)
        local row = conn:prepare("SELECT value FROM meta WHERE key = 'version'"):step()
        if not row or row[1] ~= stamp then
            logger.dbg("InlineHints: gloss cache built by older rules, clearing")
            conn:exec("DELETE FROM gloss;")
            conn:exec("DELETE FROM profile;")
            local stmt = conn:prepare("INSERT OR REPLACE INTO meta VALUES ('version', ?)")
            stmt:bind(stamp)
            stmt:step()
            stmt:close()
        end

        self.profile = self:profileId(fingerprint or "")
        self.get_stmt = conn:prepare("SELECT gloss FROM gloss WHERE profile = ? AND lemma = ?")
        self.put_stmt = conn:prepare("INSERT OR REPLACE INTO gloss VALUES (?, ?, ?)")
    end)
    if not ok then
        logger.warn("InlineHints: gloss cache unusable")
        self:close()
        return nil
    end

    self.row = {}
    return self
end

--[[--
Finds the id for a set of dictionaries, creating one if this is the first time.
]]
function Cache:profileId(fingerprint)
    local select_stmt = self.conn:prepare("SELECT id FROM profile WHERE fingerprint = ?")
    select_stmt:bind(fingerprint)
    local row = select_stmt:step()
    select_stmt:close()
    if row then
        return tonumber(row[1])
    end

    local insert_stmt = self.conn:prepare("INSERT INTO profile (fingerprint) VALUES (?)")
    insert_stmt:bind(fingerprint)
    insert_stmt:step()
    insert_stmt:close()
    return tonumber(self.conn:rowexec("SELECT last_insert_rowid()"))
end

--[[--
Looks a word up.

Returns the gloss, or false if we already know there is none, or nil if the
word has never been looked up. The three cases are different: only nil is worth
spending an sdcv call on.
]]
function Cache:get(lemma)
    self.get_stmt:clearbind():reset()
    self.get_stmt:bind(self.profile, lemma)
    local row = self.get_stmt:step(self.row)
    if not row then
        return nil
    end
    return row[1] or false
end

--[[--
Stores a result. `gloss` may be nil, meaning nothing usable was found.
]]
function Cache:put(lemma, gloss)
    self.put_stmt:clearbind():reset()
    self.put_stmt:bind(self.profile, lemma, gloss)
    self.put_stmt:step()
end

--[[--
Runs `fn` with all its writes in one transaction.

A page's worth of misses is a dozen or so inserts; committing each separately
means a dozen fsyncs on a device where that is slow.
]]
function Cache:transaction(fn)
    self.conn:exec("BEGIN;")
    local ok, err = pcall(fn)
    self.conn:exec(ok and "COMMIT;" or "ROLLBACK;")
    if not ok then
        logger.warn("InlineHints: cache transaction failed:", err)
    end
end

function Cache:close()
    if self.conn then
        self.conn:close() -- closes the statements prepared on it too
        self.conn = nil
    end
end

return Cache
