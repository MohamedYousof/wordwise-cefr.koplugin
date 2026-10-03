local Event = require("ui/event")
local Gloss = require("inlinehints_gloss")
local InfoMessage = require("ui/widget/infomessage")
local Overlay = require("inlinehints_overlay")
local Settings = require("inlinehints_settings")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Diagnostics = require("inlinehints_diagnostics")
local Engine = require("inlinehints_engine")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- Lines are set solid, so a gloss drawn between them would land on top of the
-- text above. Opening the leading is the only way to make room, and a plugin
-- can do it without touching the core: ReaderTypeset hands the document a
-- stylesheet plus the style tweaks, and we append to that.
--
-- The room scales with the gloss size, not the text size: a 12pt gloss needs
-- the line-height 2.0 upstream shipped (measured on a real page), and every
-- step above or below that asks for proportionally more or less leading.
local DEFAULT_HINT_FONT_SIZE = 12

local function gapCss(font_size)
    local line_height = 1 + font_size / DEFAULT_HINT_FONT_SIZE
    return ("p, li, dd, dt, blockquote { line-height: %.2f !important; }")
        :format(line_height)
end

-- How long to wait after a page settles before working out the next one. Long
-- enough that a reader flipping through pages never triggers it, short enough
-- to be done before anyone finishes reading a page.
local PREPARE_DELAY_S = 2

-- How many pages either side of the reader to keep prepared. Pages already
-- read are kept rather than thrown away: turning back to re-read a sentence is
-- common, and the work is already done. Each entry is a handful of words and
-- their xpointers, so a small window costs nothing.
local PREPARE_WINDOW = 2

local InlineHints = WidgetContainer:extend{
    name = "wordwise-cefr",
    is_doc_only = true,
}

function InlineHints:init()
    -- Pages worked out ahead of time, keyed by page number. Set up here because
    -- onReadSettings can switch the overlay on, and the first PosUpdate that
    -- follows reads this before anything else has had a chance to create it.
    self.prepared = {}

    -- PluginLoader sets .path on the plugin module; the language pack sits
    -- next to this file, and submodules have no other way to find it.
    Engine.setPluginPath(self.path)
    Engine.setCefrLevel(Settings:readSetting("cefr"))
    Engine.setMaxHints(Settings:readSetting("max_hints"))
    Engine.setKnownWords(Settings:readSetting("known_words") or {})
    Gloss.setMaxTerms(Settings:readSetting("max_terms"))
    self:installBundledDicts()
    self.ui.menu:registerToMainMenu(self)
end

--[[--
Copies the bundled fallback dictionaries into the reader's dict folder.

The two StarDict packs built by tools/build_stardict.py ride along in the
plugin folder so a fresh install works with no other setup. Folders we
installed ourselves carry a version marker and get replaced when the plugin
ships a newer pack -- that's how a rebuilt dictionary reaches the readers
who installed the older one. Folders without our marker belong to the
reader and are never touched. First open moves about 10 MB, hence the flag;
every later open costs one settings read and a marker peek.
]]
local DICT_PACK_VERSION = 2
local DICT_MARKER = ".wordwise-cefr-dicts"

function InlineHints:installBundledDicts()
    if Settings:readSetting("bundled_dicts_installed") then
        return
    end
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")

    local function removeTree(path)
        if lfs.attributes(path, "mode") == "directory" then
            for name in lfs.dir(path) do
                if name:sub(1, 1) ~= "." then
                    removeTree(path .. "/" .. name)
                end
            end
            lfs.rmdir(path)
        else
            os.remove(path)
        end
    end

    local function copyTree(src, dest)
        lfs.mkdir(dest)
        for name in lfs.dir(src) do
            if name:sub(1, 1) ~= "." then
                local s, d = src .. "/" .. name, dest .. "/" .. name
                if lfs.attributes(s, "mode") == "directory" then
                    copyTree(s, d)
                else
                    local fin = io.open(s, "rb")
                    if fin then
                        local data = fin:read("*a")
                        fin:close()
                        local fout = io.open(d, "wb")
                        if fout then
                            fout:write(data)
                            fout:close()
                        end
                    end
                end
            end
        end
        local marker = io.open(dest .. "/" .. DICT_MARKER, "w")
        if marker then
            marker:write(DICT_PACK_VERSION)
            marker:close()
        end
    end

    local function installedVersion(dest)
        local marker = io.open(dest .. "/" .. DICT_MARKER, "r")
        if not marker then
            return nil -- no marker: the reader's own dictionary, hands off
        end
        local version = tonumber(marker:read("*l"))
        marker:close()
        return version or 0
    end

    local src_root = self.path .. "/dictionaries"
    if lfs.attributes(src_root, "mode") == "directory" then
        local dest_root = DataStorage:getDataDir() .. "/data/dict"
        if not lfs.attributes(dest_root, "mode") then
            lfs.mkdir(dest_root) -- data/ itself exists in every KOReader install
        end
        for name in lfs.dir(src_root) do
            local src = src_root .. "/" .. name
            local dest = dest_root .. "/" .. name
            if name:sub(1, 1) ~= "." and lfs.attributes(src, "mode") == "directory" then
                if not lfs.attributes(dest, "mode") then
                    copyTree(src, dest)
                else
                    local version = installedVersion(dest)
                    if version and version < DICT_PACK_VERSION then
                        removeTree(dest)
                        copyTree(src, dest)
                    end
                end
            end
        end
    end
    Settings:saveSetting("bundled_dicts_installed", true)
    Settings:flush()
end

--[[--
The dictionaries to take meanings from, in the order they'll be tried.

Order is KOReader's own: the reader already has a screen for arranging
dictionaries, and enabled_dict_names reflects it, so this only filters. That
filtering matters -- one reader's order ran Babylon English-Turkish first but
WordNet second, so an English definition could win over the Turkish
dictionaries further down. Which dictionaries make sense as a source is not
something we can infer: .ifo files only carry a language tag when KOReader
downloaded them itself, and hand-installed ones have none.

Deliberately one list for all books, not one per book. The case for per-book --
a reader with English and German books wanting different dictionaries -- can't
arise while the language pack is English-only, and within one language the
ordered fallback already covers it: a specialist dictionary can sit in the list
and only wins when the ones before it have nothing short to say. When other
source languages do arrive, the setting to have is per *language*, which the
book itself tells us and which needs no interface at all.
]]
function InlineHints:getGlossDicts()
    local enabled = self.ui.dictionary and self.ui.dictionary.enabled_dict_names or {}
    local excluded = Settings:readSetting("excluded_dicts") or {}
    local dicts = {}
    for i = 1, #enabled do
        if not excluded[enabled[i]] then
            dicts[#dicts + 1] = enabled[i]
        end
    end
    return dicts
end

function InlineHints:onReaderReady()
    self.overlay = Overlay:new{}
    self.ui.view:registerViewModule("inlinehints", self.overlay)
    -- The record of which words appear in lower case is about this book's prose,
    -- so it must not carry over: one book's character names would license
    -- hinting the same words in the next. Keyed by file, so reopening this book
    -- -- or toggling hints, which reloads it -- keeps what we already know.
    Engine.resetCensus(self.ui.document.file)
end

--[[--
Makes the document add our line-height to every stylesheet it is ever given.

Appending once isn't enough. Anything that re-applies the stylesheet drops our
gap and leaves the hints drawing into the line above -- and the obvious hook is
closed to us, because ReaderTypeset:onApplyStyleSheet returns true, which stops
the event before any plugin sees it (widgetcontainer.lua:83). Changing a style
tweak with hints on did exactly that.

So intercept the document's own method instead of chasing the callers. This is
one well-defined point that every path goes through -- ReaderTypeset's initial
setup, style tweaks, a stylesheet change -- and it is set on the document
instance, so it goes away with the document rather than patching anything.
]]
function InlineHints:hookStyleSheet()
    local doc = self.ui.document
    if doc.inlinehints_hooked then
        return
    end
    doc.inlinehints_hooked = true

    local setStyleSheet = doc.setStyleSheet
    doc.setStyleSheet = function(document, css, tweaks_css)
        if self.overlay_enabled then
            tweaks_css = (tweaks_css or "") .. "\n"
                .. gapCss(self:getHintFontSize())
        end
        return setStyleSheet(document, css, tweaks_css)
    end
end

--[[--
Re-applies the stylesheet so the gap appears or disappears.

Re-read rather than remembered: the base sheet and the style tweaks can both
have changed under us, and writing back a stale copy would quietly revert the
reader's own choices. The gap itself is added by the hook above.

`initial` means we are still setting the document up and nothing has rendered
yet, so there is no re-render to ask for.
]]
function InlineHints:applyGapCss(initial)
    local tweaks = self.ui.styletweak and self.ui.styletweak:getCssText() or ""
    self.ui.document:setStyleSheet(self.ui.typeset.css, tweaks)
    if not initial then
        -- Re-render: the page's line positions have just changed.
        self.ui:handleEvent(Event:new("UpdatePos"))
    end
end

--[[--
Applies the gap before the document is rendered, when the setting is on.

This timing is the whole point. ReaderUI fires ReadSettings (readerui.lua:461)
and only then runs postInitCallback (:463), where ReaderRolling records the
document's rendering hash. Injecting here means the hash is taken *with* our
line-height in it, so the engine never sees the stylesheet change.

Changing it later is what caused the "book closes and reopens" reports: a
rendering change starts crengine's rerender-and-reload automation
(readerrolling.lua:1815), which fully re-renders in a subprocess and then
reloads the document once the reader has been idle for 5s. Nothing was
crashing -- that is KOReader working as designed, and the same thing it does
for any style change. The reload just took the overlay with it, because the
setting didn't survive.
]]
function InlineHints:onReadSettings(config)
    -- The key was renamed with the plugin; read the old one so a book enabled
    -- under the upstream name comes back enabled.
    self.overlay_enabled = config:isTrue("wordwise_cefr_enabled")
        or config:isTrue("inlinehints_enabled")
    -- Hooked whether or not hints are on: the hook checks overlay_enabled each
    -- time, and installing it later would miss the stylesheet ReaderTypeset has
    -- already applied by now.
    self:hookStyleSheet()
    if self.overlay_enabled then
        self:applyGapCss(true)
    end
end

function InlineHints:onSaveSettings()
    self.ui.doc_settings:saveSetting("wordwise_cefr_enabled", self.overlay_enabled or nil)
end

function InlineHints:onCloseWidget()
    Engine.closeDatabases()
end

function InlineHints:setOverlayEnabled(enabled)
    self.overlay_enabled = enabled
    self.glossed_page = nil
    self.prepared = {}
    self.overlay:setGlosses({})
    -- Persist before the reload below: reloadDocument saves settings, but the
    -- flag has to be in doc_settings for the reopened document to come back
    -- with the gap already applied.
    self.ui.doc_settings:saveSetting("wordwise_cefr_enabled", enabled or nil)

    -- Reload rather than just re-render. The line-height has changed either
    -- way, so crengine will re-render and reload on its own several seconds
    -- from now; doing it ourselves makes it immediate and predictable, and the
    -- reopened document applies the gap in onReadSettings, before the hash is
    -- taken -- so it settles instead of reloading again.
    self.ui:reloadDocument(nil, true)
end

--[[--
Recomputes the glosses for the page now on screen.

Guarded twice, and both guards are load-bearing. PosUpdate fires far more often
than the page actually changes -- during re-rendering, and repeatedly while
paging -- and each refresh forks an sdcv process. Left unguarded they pile up:
the reader crashed with no Lua traceback, which is what running out of memory
looks like from here.

Deferred to the next tick because this runs from a render-time event, while the
lookup shells out through Trapper, which must not happen mid-paint.
]]
function InlineHints:refreshGlosses()
    if not self.overlay_enabled or self.refreshing then
        return
    end
    local page = self.ui.document:getCurrentPage()
    if page == self.glossed_page then
        return -- nothing moved; the glosses on screen are already right
    end

    -- Already worked out, either read ahead while the reader was on the previous
    -- page, or still remembered from when they were last on this one. Then the
    -- page turn only has to ask where the words are, which takes milliseconds,
    -- and the hints land in the same screen refresh as the page instead of
    -- flashing in a third of a second later.
    local ready = self.prepared[page]
    if ready then
        self:drawPrepared(ready)
        self:prepareNextPage()
        return
    end

    self.refreshing = true
    UIManager:nextTick(function()
        Trapper:wrap(function()
            local ok, prepared = pcall(Engine.preparePage, self.ui, page, self:getGlossDicts())
            self.refreshing = false
            if not ok then
                logger.warn("InlineHints: page prepare failed:", prepared)
                return
            end
            -- The reader may have turned the page while sdcv was running.
            if self.ui.document:getCurrentPage() ~= page then
                self:refreshGlosses()
                return
            end
            self:rememberPrepared(prepared)
            self:drawPrepared(prepared)
            self:prepareNextPage()
        end)
    end)
end

--[[--
Keeps a prepared page, and forgets any that the reader has left well behind.

Bounded by distance from the reader rather than by count, so it holds on to the
page just turned away from -- going back one page to re-read a sentence is
common, and that page's work is already done.
]]
function InlineHints:rememberPrepared(prepared)
    if not prepared then
        return
    end
    self.prepared[prepared.page] = prepared
    local current = self.ui.document:getCurrentPage()
    for page in pairs(self.prepared) do
        if math.abs(page - current) > PREPARE_WINDOW then
            self.prepared[page] = nil
        end
    end
end

--[[--
Positions a prepared page's hints and puts them on screen.

The boxes are resolved here and nowhere earlier: they are screen coordinates,
and the engine only knows them for the page it has rendered.
]]
function InlineHints:drawPrepared(prepared)
    -- Re-read each time: the reader can change the font size while the book is
    -- open, and it decides where inside its line box a word's letters sit.
    self.overlay.text_height = self.ui.document:getFontSize()
    self.overlay.font_size = self:getHintFontSize()
    self.overlay.hint_font = self:getHintFont()

    local glosses = Engine.resolveBoxes(self.ui.document, prepared)
    logger.dbg("InlineHints: drawing", #glosses, "hints on page", prepared and prepared.page)
    self.glossed_page = self.ui.document:getCurrentPage()
    self.overlay:setGlosses(glosses)
    UIManager:setDirty(self.view.dialog, "partial")
end

--[[--
Works out the next page's hints while the reader is still on this one.

The walk costs ~140ms and a cold cache adds an sdcv call on top; none of it
needs the screen, so it can all happen during the half-minute the reader spends
on a page. Scheduled rather than immediate so the current page finishes drawing
first -- and skipped entirely if the reader has already moved on, which is also
what stops a fast page-flipper from queueing up work.
]]
function InlineHints:prepareNextPage()
    if not self.overlay_enabled then
        return
    end
    local doc = self.ui.document
    if not doc then
        return
    end
    local next_page = doc:getCurrentPage() + 1
    if self.prepared[next_page] then
        return
    end

    UIManager:scheduleIn(PREPARE_DELAY_S, function()
        if not self.overlay_enabled or self.refreshing then
            return
        end
        -- Two seconds later the book may be closed already: this task then
        -- outlives its document and must not touch it (that race is what the
        -- crash log caught on 10/03 -- "attempt to index field 'document'").
        doc = self.ui.document
        if not doc then
            return
        end
        if doc:getCurrentPage() + 1 ~= next_page then
            return -- reader moved; whatever we'd prepare is for the wrong page
        end
        self.refreshing = true
        Trapper:wrap(function()
            local ok, prepared = pcall(Engine.preparePage, self.ui, next_page, self:getGlossDicts())
            self.refreshing = false
            if ok then
                self:rememberPrepared(prepared)
            end
        end)
    end)
end

--[[--
Forgets everything prepared, because page numbers no longer mean what they did.

A re-render -- a font size change, say -- reflows the book, so page 50 now holds
different text. The stored xpointers survive (they are DOM positions), but they
are filed under the wrong page numbers, and hints would go missing on whichever
page happened to match.
]]
function InlineHints:onDocumentRerendered()
    self.prepared = {}
    self.glossed_page = nil
    self:refreshGlosses()
end

--[[--
Throws away the glosses on screen and works them out again.

For settings changes: unlike a page turn, the page is the same, so the
"already glossed this page" guard would otherwise refuse to redo it.
]]
function InlineHints:invalidateGlosses()
    self.glossed_page = nil
    -- The prepared page was worked out under the old settings, so it would
    -- happily draw the answer the reader just changed away from.
    self.prepared = {}
    self:refreshGlosses()
end

--[[--
Drops the glosses the moment the page moves.

Their boxes are screen coordinates for the page that just left, so painting
them over the new one would put words in the wrong places.
]]
function InlineHints:onPageChanged()
    if self.glossed_page ~= nil then
        self.glossed_page = nil
        self.overlay:setGlosses({})
    end
    self:refreshGlosses()
end

InlineHints.onPosUpdate = InlineHints.onPageChanged
InlineHints.onPageUpdate = InlineHints.onPageChanged

function InlineHints:getHintFontSize()
    return Settings:readSetting("hint_font_size") or DEFAULT_HINT_FONT_SIZE
end

function InlineHints:getHintFont()
    return Settings:readSetting("hint_font") -- nil = KOReader's UI font
end

function InlineHints:getKnownWords()
    local words = Settings:readSetting("known_words")
    if not words then
        words = {}
        Settings:saveSetting("known_words", words)
        Settings:flush()
    end
    return words
end

--[[--
Builds the known-words manager.

A known word is never hinted again, in any form: the reader taps through the
list to forget one, or types a word in directly. Ten seconds of typing saves
a book's worth of nuisance.
]]
function InlineHints:genKnownWordsMenu()
    local UIManager = require("uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local words = self:getKnownWords()

    local items = {
        {
            text = _("Add a known word…"),
            callback = function()
                local dialog
                dialog = InputDialog:new{
                    title = _("Add a known word"),
                    input_type = "text",
                    buttons = {{
                        {
                            text = _("Cancel"),
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text = _("Add"),
                            is_enter_default = true,
                            callback = function()
                                local word = dialog:getInputText():lower()
                                if word ~= "" then
                                    words[word] = true
                                    Settings:saveSetting("known_words", words)
                                    Settings:flush()
                                    Engine.setKnownWords(words)
                                    self:invalidateGlosses()
                                end
                                UIManager:close(dialog)
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
            end,
            separator = true,
        },
    }

    local list = {}
    for word in pairs(words) do
        list[#list + 1] = word
    end
    table.sort(list)
    for _, word in ipairs(list) do
        items[#items + 1] = {
            text = word,
            callback = function()
                words[word] = nil
                Settings:saveSetting("known_words", words)
                Settings:flush()
                Engine.setKnownWords(words)
                self:invalidateGlosses()
            end,
        }
    end
    return items
end

--[[--
Builds the per-page hint limit chooser.

Dense pages can offer more worthy words than anyone wants floating over the
text; past a handful the hints stop being aids and become weather. When the
page offers more than the limit, the rarest words win the spots.
]]
function InlineHints:genMaxHintsMenu()
    local choices = { 5, 10, 15, 20, 30 }
    local items = {}
    for _, n in ipairs(choices) do
        items[#items + 1] = {
            text = string.format(_("%d hints per page"), n),
            radio = true,
            checked_func = function()
                return (Settings:readSetting("max_hints")
                        or Engine.DEFAULT_MAX_HINTS) == n
            end,
            callback = function()
                Settings:saveSetting("max_hints", n)
                Settings:flush()
                Engine.setMaxHints(n)
                self:invalidateGlosses()
            end,
        }
    end
    return items
end

--[[--
Builds the hint text size chooser.

The gloss is drawn small on purpose -- it has to fit in the leading above its
word -- but on a big e-ink screen or tired eyes, small is a choice, not a law.
Changing it changes the line-height with it (see gapCss), so the book reloads
the same way it does when hints are turned on.
]]
function InlineHints:genFontSizeMenu()
    local sizes = { 10, 12, 14, 16, 18 }
    local labels = {
        [10] = _("Small (10)"),
        [12] = _("Normal (12)"),
        [14] = _("Large (14)"),
        [16] = _("Extra large (16)"),
        [18] = _("Huge (18)"),
    }
    local items = {}
    for _, size in ipairs(sizes) do
        items[#items + 1] = {
            text = labels[size],
            radio = true,
            checked_func = function()
                return self:getHintFontSize() == size
            end,
            callback = function()
                if self:getHintFontSize() == size then return end
                Settings:saveSetting("hint_font_size", size)
                Settings:flush()
                if self.overlay_enabled then
                    -- The gap changes with the size, so re-render now and
                    -- predictably rather than on crengine's idle timer.
                    self:setOverlayEnabled(true)
                end
            end,
        }
    end
    return items
end

--[[--
Builds the hint font chooser.

Lists every font KOReader can see (its own bundled ones plus anything dropped
into the fonts folder), with the reader's UI font as the default. Hints are
drawn by us, not the book, so the choice costs nothing but this list; if the
picked font has no glyphs for a hint's language (Arabic, say), the shaping
engine falls back to KOReader's bundled fallback fonts for the missing
script, same as everywhere else in the reader.
]]
function InlineHints:genHintFontMenu()
    local FontList = require("fontlist")
    local items = {
        {
            text = _("Default (KOReader font)"),
            radio = true,
            checked_func = function()
                return self:getHintFont() == nil
            end,
            callback = function()
                if self:getHintFont() == nil then return end
                Settings:saveSetting("hint_font", nil)
                Settings:flush()
                self:invalidateGlosses()
            end,
            separator = true,
        },
    }
    local fonts = FontList:getFontList()
    table.sort(fonts, function(a, b) return a:lower() < b:lower() end)
    for _, path in ipairs(fonts) do
        local label = path:match("([^/]+)$") or path
        items[#items + 1] = {
            text = label,
            radio = true,
            checked_func = function()
                return self:getHintFont() == path
            end,
            callback = function()
                if self:getHintFont() == path then return end
                Settings:saveSetting("hint_font", path)
                Settings:flush()
                -- The gloss width changes with the face, so the page's layout
                -- is stale; recomputing glosses redraws them.
                self:invalidateGlosses()
            end,
        }
    end
    return items
end

--[[--
Builds the "my English level" chooser (CEFR A1-C2).

The reader picks the level they actually have, and the engine glosses every
word above it: pick B1 and the B2/C1/C2 words -- and anything no learner list
has -- get explanations, while words a B1 reader already knows stay clean.
]]
function InlineHints:genCefrMenu()
    local names = { "A1", "A2", "B1", "B2", "C1", "C2" }
    local labels = {
        [1] = _("A1 — Beginner: hint most words"),
        [2] = _("A2 — Elementary: everyday words and harder"),
        [3] = _("B1 — Intermediate"),
        [4] = _("B2 — Upper-intermediate"),
        [5] = _("C1 — Advanced: only hard words"),
        [6] = _("C2 — Proficient: only words no learner list has"),
    }
    local items = {}
    for rank = 1, #names do
        local name = names[rank]
        items[#items + 1] = {
            text = labels[rank],
            radio = true,
            checked_func = function()
                return (Settings:readSetting("cefr")
                        or Engine.DEFAULT_CEFR) == name
            end,
            callback = function()
                Settings:saveSetting("cefr", name)
                Settings:flush()
                Engine.setCefrLevel(name)
                self:invalidateGlosses()
            end,
        }
    end
    return items
end

function InlineHints:genLengthMenu()
    local labels = {
        [1] = _("One meaning"),
        [2] = _("Up to two meanings"),
        [3] = _("Up to three meanings"),
    }
    local items = {}
    for terms = 1, 3 do
        items[terms] = {
            text = labels[terms],
            radio = true,
            checked_func = function()
                return (Settings:readSetting("max_terms")
                        or Gloss.DEFAULT_MAX_TERMS) == terms
            end,
            callback = function()
                Settings:saveSetting("max_terms", terms)
                Settings:flush()
                Gloss.setMaxTerms(terms)
                self:invalidateGlosses()
            end,
        }
    end
    return items
end

function InlineHints:genDictionaryMenu()
    local enabled = self.ui.dictionary and self.ui.dictionary.enabled_dict_names or {}
    if #enabled == 0 then
        return { { text = _("No dictionary enabled"), enabled = false } }
    end
    local items = {
        {
            text = _("Tried in this order, first usable meaning wins"),
            enabled = false,
            separator = true,
        },
    }
    for i = 1, #enabled do
        local dict_name = enabled[i]
        items[#items + 1] = {
            text = dict_name,
            checked_func = function()
                local excluded = Settings:readSetting("excluded_dicts") or {}
                return not excluded[dict_name]
            end,
            callback = function()
                local excluded = Settings:readSetting("excluded_dicts") or {}
                excluded[dict_name] = not excluded[dict_name] or nil
                Settings:saveSetting("excluded_dicts", excluded)
                Settings:flush()
                self:invalidateGlosses()
            end,
        }
    end
    return items
end

--[[--
Tools for working out why a page looks the way it does.

Kept apart from the settings because nothing here is part of reading: they
report timings and dump raw dictionary entries to the log. A reader never needs
them; when a meaning comes out wrong, they are the only way to find out where.
]]
function InlineHints:genDiagnosticsMenu()
    local enabled = self.ui.dictionary and self.ui.dictionary.enabled_dict_names or {}
    local per_dict = {}
    for i = 1, #enabled do
        local dict_name = enabled[i]
        per_dict[i] = {
            text = dict_name,
            keep_menu_open = true,
            callback = function()
                Trapper:wrap(function()
                    self:dumpGlosses({ dict_name })
                end)
            end,
        }
    end

    return {
        {
            -- The same set the overlay uses, so this explains what is actually
            -- on the page rather than something adjacent to it.
            text = _("Show meanings for this page"),
            keep_menu_open = true,
            callback = function()
                Trapper:wrap(function()
                    self:dumpGlosses(self:getGlossDicts())
                end)
            end,
        },
        {
            text = _("Try one dictionary on its own"),
            enabled_func = function() return #per_dict > 0 end,
            sub_item_table = per_dict,
            separator = true,
        },
        {
            text = _("Benchmark this page"),
            keep_menu_open = true,
            callback = function()
                -- rawSdcv() runs sdcv through Trapper:dismissablePopen(), which
                -- only works inside a Trapper coroutine.
                Trapper:wrap(function()
                    self:runBenchmark()
                end)
            end,
        },
    }
end

function InlineHints:addToMainMenu(menu_items)
    menu_items.inlinehints = {
        text = _("WordWise CEFR"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Show hints while reading"),
                checked_func = function()
                    return self.overlay_enabled == true
                end,
                callback = function()
                    self:setOverlayEnabled(not self.overlay_enabled)
                end,
                separator = true,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Which words get a hint"),
                        sub_item_table_func = function() return self:genCefrMenu() end,
                    },
                    {
                        text = _("How long a hint may be"),
                        sub_item_table_func = function() return self:genLengthMenu() end,
                    },
                    {
                        text = _("Max hints per page"),
                        sub_item_table_func = function() return self:genMaxHintsMenu() end,
                    },
                    {
                        text = _("Known words"),
                        sub_item_table_func = function() return self:genKnownWordsMenu() end,
                    },
                    {
                        text = _("Hint text size"),
                        sub_item_table_func = function() return self:genFontSizeMenu() end,
                    },
                    {
                        text = _("Hint font"),
                        sub_item_table_func = function() return self:genHintFontMenu() end,
                    },
                    {
                        text = _("Dictionaries to take meanings from"),
                        sub_item_table_func = function() return self:genDictionaryMenu() end,
                    },
                },
            },
            {
                text = _("Diagnostics"),
                sub_item_table_func = function() return self:genDiagnosticsMenu() end,
            },
        },
    }
end

local function forLog(text, max_len)
    if not text then return "(none)" end
    text = text:gsub("\n", "\\n")
    if #text > max_len then
        return text:sub(1, max_len) .. "..."
    end
    return text
end

function InlineHints:dumpGlosses(dict_names)
    local dump, err = Diagnostics.dumpGlosses(self.ui, 12, dict_names)
    if not dump then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end

    -- The popup shows whether the glosses are usable; the log shows why, so a
    -- bad one can be traced back through the extraction stages.
    logger.info("InlineHints gloss dump, dictionaries:", table.concat(dump.dicts, " > "))
    for i = 1, #dump.entries do
        local e = dump.entries[i]
        logger.info(string.format(
            "InlineHints [%s] lemma=%s level=%s\n  gloss: %s (from %s%s)\n  raw:   %s\n  plain: %s\n  sense: %s",
            e.word, tostring(e.lemma), tostring(e.level),
            forLog(e.gloss, 100), tostring(e.from), e.fell_back and ", FALLBACK" or "",
            forLog(e.raw, 400),
            forLog(e.plain, 300),
            forLog(e.sense, 200)))
    end

    local lines = { T(_("Glosses from: %1"), table.concat(dump.dicts, " > ")), "" }
    local with_gloss, fallbacks = 0, 0
    for i = 1, #dump.entries do
        local e = dump.entries[i]
        -- Show the base form when it differs: that's what was looked up, and
        -- seeing it is how we tell a lemma bug from a dictionary gap.
        local label = e.word
        if e.lemma and e.lemma ~= e.word then
            label = T(_("%1 (%2)"), e.word, e.lemma)
        end
        if e.gloss then
            with_gloss = with_gloss + 1
            if e.fell_back then
                fallbacks = fallbacks + 1
                lines[#lines + 1] = T(_("%1 → %2 *"), label, e.gloss)
            else
                lines[#lines + 1] = T(_("%1 → %2"), label, e.gloss)
            end
        elseif not e.found then
            lines[#lines + 1] = T(_("%1 → (not in dictionary)"), label)
        else
            lines[#lines + 1] = T(_("%1 → (no short gloss)"), label)
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = T(_("%1 of %2 usable"), with_gloss, #dump.entries)
    if fallbacks > 0 then
        lines[#lines + 1] = T(_("* %1 rescued by a fallback dictionary"), fallbacks)
    end
    -- Without this a page with no glosses is unreadable as a result: an easy
    -- page and an over-eager name filter look identical.
    if #dump.dropped_names > 0 then
        lines[#lines + 1] = T(_("Dropped as names: %1"), table.concat(dump.dropped_names, ", "))
    end

    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function InlineHints:runBenchmark()
    local report, err = Diagnostics.run(self.ui)
    if not report then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end

    logger.info("InlineHints probe:", report)

    local text = T(_([[WordWise CEFR page benchmark

Words on page: %1
Difficult candidates: %2 (boxes: %3)%4

Word walk: %5 ms
Level filter: %6 ms
Word boxes: %7 ms
Page work total: %8 ms]]),
        report.word_count,
        report.candidate_count,
        report.boxes_found,
        report.have_pack and "" or _("\nWARNING: language pack missing, using a length guess"),
        string.format("%.1f", report.walk_ms),
        string.format("%.1f", report.filter_ms),
        string.format("%.1f", report.boxes_ms),
        string.format("%.1f", report.page_ms))

    if report.cold then
        text = text .. T(_("\n\nsdcv, 1 dict (%1)\n  cold, %2 words: %3 ms"),
            report.first_dict,
            report.candidate_count,
            string.format("%.1f", report.cold.ms))

        -- Not "for _, result": that would shadow gettext's _ inside the loop.
        for i = 1, #(report.sweep or {}) do
            local result = report.sweep[i]
            text = text .. T(_("\n  warm, %1 words: %2 ms (%3 found)"),
                result.n,
                string.format("%.1f", result.ms),
                result.found)
        end
    end

    if report.all_dicts then
        text = text .. T(_("\n\nsdcv, all %1 dicts\n  warm, %2 words: %3 ms"),
            report.dict_count,
            report.candidate_count,
            string.format("%.1f", report.all_dicts.ms))
    end

    if report.candidate_count > 0 and not report.cold then
        text = text .. "\n\n" .. _("No dictionary lookups ran. Is a StarDict dictionary installed and enabled?")
    end

    UIManager:show(InfoMessage:new{ text = text })
end

return InlineHints
