-- Exercises inlinehints_gloss.lua outside KOReader by stubbing `util`.
-- The stubs mirror frontend/util.lua closely enough for these rules.
-- Find the plugin next to this test, so this runs from anywhere.
local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]+$")
package.path = here .. "/../?.lua;" .. here .. "/../../../common/?.lua;"
    .. here .. "/../../../common/?/init.lua;" .. package.path

local util = {}
util.UTF8_CHAR_PATTERN = '[%z\1-\127\194-\253][\128-\191]*'

function util.trim(s)
    return s:match("^%s*(.-)%s*$")
end

local entities = { ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"', ["&nbsp;"] = " " }
local function htmlEntitiesToUtf8(text)
    return (text:gsub("&%a+;", function(e) return entities[e] or e end))
end

local function htmlToPlainText(text)
    text = text:gsub("%s*<%s*br%s*/?>%s*", "\n")
    text = text:gsub("%s*</%s*p%s*>%s*", "\n")
    text = text:gsub("%s*<%s*p%s*>%s*", "\n")
    text = text:gsub("<[^>]*>", "")
    text = htmlEntitiesToUtf8(text)
    text = text:gsub("^[\n%s]*", ""):gsub("[\n%s]*$", "")
    return text
end

function util.htmlToPlainTextIfHtml(text)
    local _, nb_tags = text:gsub("<%w+.->", "")
    if nb_tags > 0 then
        return htmlToPlainText(text)
    end
    return text
end

package.loaded["util"] = util

local Gloss = require("inlinehints_gloss")

-- Raw entries captured from the user's Babylon English-Turkish dictionary via
-- the on-device dump, verbatim. Earlier guesses at this format were wrong
-- (Babylon spells the part of speech out on its own line rather than
-- abbreviating it inline), so these are the real thing.
local cases = {
    {
        name = "babylon: pos line, phonetics line, then senses",
        word = "periodicals",
        def = '\n<font color="#007000">noun</font><br>\n[pe·ri·od·i·cal || ‚pɪrɪ\'ɑdɪkl /‚pɪərɪ\'ɒ-]<br>\ndergi',
        want = "dergi",
    },
    {
        name = "babylon: many senses, first two fit",
        word = "listened",
        def = '\n<font color="#007000">verb</font><br>\n[lis·ten || \'lɪsn]<br>\ndinlemek, kulak asmak',
        want = "dinlemek, kulak asmak",
    },
    {
        name = "babylon: no phonetics line",
        word = "headline",
        def = '\n<font color="#007000">noun</font><br>\nbaşlık, manşet, afişteki isim',
        want = "başlık, manşet",
    },
    {
        name = "babylon: second sense overflows, keep the first",
        word = "murdered",
        def = '\n<font color="#007000">verb</font><br>\n[mur·der || \'mɜrdər /\'mɜːdə]<br>\nöldürmek, cinayet işlemek, kasten öldürmek',
        want = "öldürmek",
    },
    {
        name = "babylon: adjective label skipped",
        word = "innocent",
        def = '\n<font color="#007000">adjective</font><br>\n[\'in·no·cent || ɪnəsnt]<br>\nmasum, suçsuz, günahsız, saf, zararsız',
        want = "masum, suçsuz",
    },
    {
        name = "inline abbreviated pos, as other dictionaries write it",
        word = "abate",
        def = "abate\n[\xc9\x99'beit]\nf. azaltmak",
        want = "azaltmak",
    },

    -- Four more of the user's dictionaries, captured the same way. Each writes
    -- entries differently, and the rules have to survive all of them.
    {
        name = "mustafa yildiz: bare senses, no pos or phonetics",
        word = "staring",
        def = "\nhareketsiz, sabit",
        want = "hareketsiz, sabit",
    },
    {
        name = "mustafa yildiz: semicolon separated senses",
        word = "innocent",
        def = "\nmasum, suçsuz; zararsiz; saf, temiz kalpli",
        want = "masum, suçsuz",
    },
    {
        name = "saja: senses numbered inline, cut at the next number",
        word = "innocent",
        def = "\ns. 1. masum, suçsuz. 2. zararsız. 3. saf, safdil. i. 1. masum kimse/çocuk.",
        want = "masum, suçsuz",
    },
    {
        name = "saja: trailing period dropped from the gloss",
        word = "headline",
        def = "\ni. başlık, manşet.",
        want = "başlık, manşet",
    },
    {
        name = "saja: stray opening quote before the pos marker",
        word = "feature",
        def = '\n"i. 1. yüzdeki organlardan biri. 2. çoğ. yüz, sima, çehre; yüz hatları. 3. özellik.',
        want = "yüzdeki organlardan biri",
    },
    {
        name = "english-turkish: numbered senses one per line",
        word = "headline",
        def = "\n\n1. başlık, serlevha\n2. başlık koymak\n3. (tiyatro) afişte ismi başta olmak.",
        want = "başlık, serlevha",
    },
    {
        name = "wordnet: pos written as 'adj :' with no period",
        word = "murdered",
        def = '\n\nmurdered\n     adj : killed unlawfully; "the murdered woman"',
        want = "killed unlawfully",
    },
    {
        name = "wordnet: pos written as 'n 1:' with a sense number",
        word = "headline",
        def = '\n\nheadline\n     n 1: the heading or caption of a newspaper article',
        want = nil, -- an explanatory sentence, too long to draw
    },
    {
        name = "numbered senses stacked with part of speech",
        word = "abate",
        def = "1. f. dindirmek, yatistirmak",
        want = "dindirmek, yatistirmak",
    },
    {
        name = "single term",
        word = "cogent",
        def = "s. inandirici",
        want = "inandirici",
    },
    {
        name = "second term would overflow, keep the first",
        word = "obfuscate",
        def = "f. karartmak, anlasilmaz hale getirmek",
        want = "karartmak",
    },
    {
        name = "no usable short gloss",
        word = "notwithstanding",
        def = "e. ragmen olmasina karsin buna ragmen yine de",
        want = nil,
    },
    {
        -- 24 characters but 26 bytes: measuring length in bytes would wrongly
        -- reject this, which is why utf8Len() exists.
        name = "turkish characters counted as characters, not bytes",
        word = "assuage",
        def = "f. hafifletmek, yatıştırmak",
        want = "hafifletmek, yatıştırmak",
    },
    {
        name = "empty definition",
        word = "x",
        def = "",
        want = nil,
    },
}

local failures = 0
for _, case in ipairs(cases) do
    local stages = Gloss.extract(case.def, case.word)
    local got = stages.gloss
    local ok = got == case.want
    if not ok then failures = failures + 1 end
    print(string.format("%s  %s\n     want: %s\n      got: %s",
        ok and "PASS" or "FAIL", case.name, tostring(case.want), tostring(got)))
end

print(string.format("\n%d/%d passed", #cases - failures, #cases))
os.exit(failures == 0 and 0 or 1)
