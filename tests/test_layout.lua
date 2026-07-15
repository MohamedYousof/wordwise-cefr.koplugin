-- Exercises the collision resolver with a fake font: width = 6px per character.
-- Find the plugin next to this test, so this runs from anywhere.
local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]+$")
package.path = here .. "/../?.lua;" .. here .. "/../../../common/?.lua;"
    .. here .. "/../../../common/?/init.lua;" .. package.path
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_GRAY_4 = 4 }
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/rendertext"] = {
    sizeUtf8Text = function(_, _, _, _, text) return { x = #text * 6, y_top = 9 } end,
}
package.loaded["ui/size"] = { span = { horizontal_small = 5 }, line = { thin = 1 } }
package.loaded["ui/widget/widget"] = { extend = function(_, t) 
    t.new = function(cls, o) o = o or {}; setmetatable(o, {__index = cls}); if o.init then o:init() end; return o end
    return t
end }

local Overlay = require("inlinehints_overlay")
local fails = 0
local function check(c, m) if not c then fails = fails + 1; print("  FAIL " .. m) end end

local function place(glosses, max_x)
    local o = Overlay:new{ glosses = glosses }
    o.glosses = glosses
    return o:layout({}, max_x)
end

-- Two glossed words side by side on one line, glosses wider than the words.
local placed = place({
    { text = "azaltmak", box = { x = 100, y = 50, w = 30, h = 40 }, level = 3 },
    { text = "dinlemek", box = { x = 140, y = 50, w = 30, h = 40 }, level = 4 },
}, 1000)
check(#placed == 2, "both fit when there is room, got " .. #placed)
table.sort(placed, function(a, b) return a.x < b.x end)
check(placed[1].x + placed[1].w <= placed[2].x, "shifted apart, no overlap")

-- No room: the line is narrow, so one must go -- the commoner word.
placed = place({
    { text = "azaltmak", box = { x = 0,  y = 50, w = 30, h = 40 }, level = 5 },
    { text = "dinlemek", box = { x = 40, y = 50, w = 30, h = 40 }, level = 2 },
}, 60)
check(#placed == 1, "one dropped when the line is full, got " .. #placed)
check(placed[1] and placed[1].text == "azaltmak",
      "the rarer word keeps its gloss, got " .. tostring(placed[1] and placed[1].text))

-- Different lines never collide with each other.
placed = place({
    { text = "azaltmak", box = { x = 100, y = 50,  w = 30, h = 40 }, level = 3 },
    { text = "dinlemek", box = { x = 100, y = 150, w = 30, h = 40 }, level = 3 },
}, 1000)
check(#placed == 2, "same x on different lines both survive, got " .. #placed)

-- A gloss over the first word of a line must not hang off the left edge.
placed = place({ { text = "azaltmak", box = { x = 2, y = 50, w = 20, h = 40 }, level = 3 } }, 1000)
check(placed[1].x >= 0, "clamped to the left edge, got " .. tostring(placed[1].x))

print(fails == 0 and "all layout checks passed" or (fails .. " FAILED"))
