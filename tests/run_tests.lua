--[[--
Runs every test in this folder.

    luajit tests/run_tests.lua        (from the plugin folder, or anywhere)

They need no KOReader: each stubs the handful of core modules it touches, so
they run on a desktop in about a second. That is the point. Nearly every bug in
this plugin was invisible in the code and obvious in real data -- a dictionary's
actual output, a real page's words -- so these keep those cases around, and a
later change has to keep passing them.

Each test runs in its own process. They install stubs into package.loaded, and
one test's idea of `util` must not become another's.
]]
local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]+$")
local windows = package.config:sub(1, 1) == "\\"
local devnull = windows and "NUL" or "/dev/null"
local interpreter = arg[-1] or "luajit"

local tests = { "test_gloss", "test_learn", "test_layout", "test_census", "test_settings", "test_split" }
local failed = 0

for _, name in ipairs(tests) do
    io.write(("%-14s "):format(name))
    io.flush()
    local script = here .. "/" .. name .. ".lua"
    local cmd
    if windows then
        -- cmd.exe won't run a quoted program path written with forward slashes,
        -- and when both the program and an argument are quoted it needs the
        -- whole command wrapped in one more pair.
        cmd = ('""%s" "%s" > %s 2>&1"'):format(interpreter, script:gsub("/", "\\"), devnull)
    else
        cmd = ('"%s" "%s" > %s 2>&1'):format(interpreter, script, devnull)
    end
    local ok, _, code = os.execute(cmd)
    -- LuaJIT follows Lua 5.1: os.execute returns the exit code as a number.
    -- 5.2+ returns true/false plus the code, so accept both.
    local passed = (ok == 0) or (ok == true and (code == nil or code == 0))
    print(passed and "ok" or "FAILED")
    if not passed then
        failed = failed + 1
        print("  rerun to see why:  " .. interpreter .. " " .. script)
    end
end

print(failed == 0 and "\nall tests passed" or ("\n" .. failed .. " test file(s) failed"))
os.exit(failed == 0 and 0 or 1)
