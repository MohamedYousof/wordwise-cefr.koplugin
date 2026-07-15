--[[--
Draws glosses over the rendered page.

This is the assumption everything else rests on and the last one still
untested: that a plugin can put its own text between the lines of a crengine
page. ReaderView paints every registered view module after the page itself
(readerview.lua), so we get a blitbuffer and the page's own screen coordinates
-- the same mechanism highlights use.

Two things have to be true and this module is how we find out:
  * text can be drawn at a word's box, which the engine gives us;
  * there is somewhere to draw it. There isn't, normally -- lines are set
    solid. Room has to be made by injecting a line-height into the document's
    stylesheet, which a plugin can do through document:setStyleSheet().

If this doesn't work the data layers survive (they don't care how a gloss is
presented), but the presentation would have to change.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local RenderText = require("ui/rendertext")
local Size = require("ui/size")
local Widget = require("ui/widget/widget")

local Overlay = Widget:extend{
    -- Array of { text = <gloss>, box = <Geom, screen coords> }.
    glosses = nil,
    font_size = 12,
    underline = true,
    -- Height of the document's own text, in pixels. Needed because the engine's
    -- word boxes are LINE boxes: they span the full line-height, and the glyphs
    -- sit centred inside with the extra leading split above and below. (The
    -- core makes the same assumption -- readerview.lua shrinks highlight boxes
    -- by a percentage and re-centres them for exactly this reason.) Treating
    -- box.y as the top of the letters put every gloss a half-leading too high,
    -- so it read as belonging to the line above.
    text_height = nil,
}

--[[--
Finds the band the actual glyphs occupy inside a word's line box.

Returns the y of the top of the text and of the bottom.
]]
function Overlay:textBand(box)
    local text_height = math.min(self.text_height or box.h, box.h)
    local half_leading = (box.h - text_height) / 2
    return box.y + half_leading, box.y + box.h - half_leading
end

function Overlay:init()
    self.glosses = self.glosses or {}
    self.placed = {}
end

function Overlay:setGlosses(glosses)
    self.glosses = glosses or {}
    self.placed = nil -- recomputed on the next paint, where we know the width
end

--[[--
Places the glosses of one line, left to right, so none overlap.

A gloss is centred over its word, but is usually wider than it, so two glossed
words standing near each other collide. Shifting is preferred to dropping: the
underline already says which word a gloss belongs to, so a nudged gloss is still
readable, whereas a dropped one is information lost.

When shifting isn't enough -- the line runs out of room -- something has to go,
and it is the most common word that goes. That is the whole ranking the rarity
level exists for: if only one of "abate" and "feature" can be explained, it is
not "feature".

Returns the placements that fit.
]]
function Overlay:layoutLine(line, max_x)
    local margin = Size.span.horizontal_small
    while #line > 0 do
        local placed, cursor, fits = {}, 0, true
        for i = 1, #line do
            local item = line[i]
            local box = item.box
            local text_x = box.x + (box.w - item.w) / 2
            if text_x < cursor then
                text_x = cursor -- pushed right by the gloss before it
            end
            if text_x < 0 then
                text_x = 0
            end
            if text_x + item.w > max_x then
                fits = false
                break
            end
            placed[i] = text_x
            cursor = text_x + item.w + margin
        end

        if fits then
            for i = 1, #line do
                line[i].x = placed[i]
            end
            return line
        end

        -- Drop the commonest word on the line and try again. Levels may be nil
        -- when the language pack is missing; then this just drops the last.
        local worst_i, worst_level = 1, math.huge
        for i = 1, #line do
            local level = line[i].level or 0
            if level <= worst_level then
                worst_i, worst_level = i, level
            end
        end
        table.remove(line, worst_i)
    end
    return line
end

--[[--
Measures every gloss and works out where it goes.

Done once per page rather than per paint, but not before: it needs the screen
width, which arrives with the blitbuffer.
]]
function Overlay:layout(face, max_x)
    -- Group by line. Words on one line share the top of their line box exactly,
    -- so it identifies the line without any tolerance games.
    local lines, order = {}, {}
    for _, g in ipairs(self.glosses) do
        local size = RenderText:sizeUtf8Text(0, max_x, face, g.text, true, false)
        local key = g.box.y
        if not lines[key] then
            lines[key] = {}
            order[#order + 1] = key
        end
        table.insert(lines[key], {
            text = g.text, box = g.box, level = g.level,
            w = size.x, y_top = size.y_top,
        })
    end

    local placed = {}
    for _, key in ipairs(order) do
        local line = lines[key]
        table.sort(line, function(a, b) return a.box.x < b.box.x end)
        for _, item in ipairs(self:layoutLine(line, max_x)) do
            placed[#placed + 1] = item
        end
    end
    return placed
end

function Overlay:paintTo(bb, x, y)
    if #self.glosses == 0 then
        return
    end
    local face = Font:getFace("cfont", self.font_size)
    local max_x = bb:getWidth()
    if not self.placed then
        self.placed = self:layout(face, max_x)
    end

    for _, item in ipairs(self.placed) do
        local box = item.box
        local text_x = item.x

        -- Sit the gloss in the leading directly above its own word, inside that
        -- word's line box. renderUtf8Text takes a baseline, not a top edge, so
        -- drop by the gloss's own ascent. Clamped to the top of the line box:
        -- past that it would be in the previous line's half of the gap, which
        -- is the bug this replaces.
        local text_top, text_bottom = self:textBand(box)
        local baseline = math.max(text_top - 1, box.y + item.y_top)

        -- Integers only. These end up as coordinates in the C blitter, and the
        -- centring above produces fractions.
        RenderText:renderUtf8Text(bb, x + math.floor(text_x), y + math.floor(baseline),
                                  face, item.text, true, false, Blitbuffer.COLOR_BLACK)

        -- Mark which word the gloss belongs to. A gloss is nearly always wider
        -- than its word and overhangs the neighbours on both sides, so without
        -- this the pairing is guesswork. Kept thin and grey on purpose: it says
        -- "this word", it is not a highlight. Sits under the letters, not under
        -- the line box, which would leave it floating a half-leading too low.
        if self.underline then
            bb:paintRect(x + box.x, y + math.floor(text_bottom), box.w,
                         Size.line.thin, Blitbuffer.COLOR_GRAY_4)
        end
    end
end

return Overlay
