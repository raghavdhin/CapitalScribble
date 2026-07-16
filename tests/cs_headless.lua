-- Headless tests for CapitalScribble's pure-Lua core.
-- Run:  "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript" \
--         -l lua tests/cs_headless.lua
-- No Resolve needed; engine loads in library mode (no fu/comp touched).

local here = arg and arg[0] and arg[0]:match("^(.*)/tests/") or "."
local chunk, lerr = loadfile(here .. "/CapitalScribble.lua")
assert(chunk, "cannot load CapitalScribble.lua: " .. tostring(lerr))
setfenv(chunk, setmetatable({ CAPITALSCRIBBLE_LIBRARY_MODE = true }, { __index = getfenv(1) }))
local M = chunk()

local n, failed = 0, 0
local function eq(a, b, label)
    n = n + 1
    local ok
    if type(a) == "number" and type(b) == "number" then ok = math.abs(a - b) < 1e-9
    else ok = a == b end
    if not ok then
        failed = failed + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(a), tostring(b)))
    end
end

-- HexToRGB / RGBToHex
local r, g, b = M.HexToRGB("#ffffff"); eq(r, 1, "hex white r"); eq(b, 1, "hex white b")
r, g, b = M.HexToRGB("000000"); eq(r, 0, "hex black no-#")
r, g, b = M.HexToRGB("#dcf000")
eq(math.floor(r * 255 + 0.5), 220, "accent r"); eq(math.floor(g * 255 + 0.5), 240, "accent g")
r = M.HexToRGB("#xyz")
eq(r, nil, "bad hex rejected")
r, g, b = M.HexToRGB("#fff"); eq(r, 1, "short hex expands")
eq(M.RGBToHex(1, 1, 1), "#ffffff", "rgb->hex white")
eq(M.RGBToHex(220/255, 240/255, 0), "#dcf000", "rgb->hex accent roundtrip")

-- BoilExpression
eq(M.BoilExpression(3), "floor(time/3)*0.6180339887", "boil expr 3f")
eq(M.BoilExpression(0), "floor(time/1)*0.6180339887", "boil expr clamps to 1")
eq(M.BoilExpression(2.6), "floor(time/3)*0.6180339887", "boil expr rounds")

-- TransitionWindows
local w = M.TransitionWindows(10, 100, 12, 8)
eq(w.inA, 10, "inA"); eq(w.inB, 22, "inB"); eq(w.outA, 92, "outA"); eq(w.outB, 100, "outB")
w = M.TransitionWindows(0, 10, 20, 20)               -- overlong transitions shrink to fit
eq(w.inB <= w.outA, true, "shrunk windows do not cross")
eq(w.outB, 10, "outB pinned to EF")
w = M.TransitionWindows(5, 5, 4, 4)                   -- degenerate EF<=SF
eq(w.outB > w.inA, true, "degenerate range repaired")

-- style table sanity
eq(#M.STYLES, 3, "3 styles")
for _, st in ipairs(M.STYLES) do
    eq(type(st.font), "string", st.id .. " font")
    eq(st.boilAmount > 0 and st.boilAmount < 0.05, true, st.id .. " boil sane")
    eq(#st.set >= 3, true, st.id .. " element toggles present")
    -- ordered pairs, Enabled toggles only (config lives in the paste template)
    for _, kv in ipairs(st.set) do
        eq(kv[1]:match("^Enabled%d$") ~= nil, true, st.id .. " set entry " .. kv[1])
    end
    eq(#st.colorElems >= 1, true, st.id .. " color elements")
    eq(M.FONT_STYLES[st.font] ~= nil, true, st.id .. " font has style mapping")
end
eq(#M.TRANSITIONS, 6, "6 transitions")
for _, f in ipairs(M.FONTS) do
    eq(M.FONT_STYLES[f] ~= nil, true, "font style mapped: " .. f)
end

-- constants carried over from the user's macro
eq(M.RISE_AMOUNT, 0.044, "macro rise")
eq(M.WORD_DELAY, 1.03, "macro delay")
eq(M.EASE_FRAMES, 25, "macro ease span")

print(string.format("%d checks, %d failed", n, failed))
if failed > 0 then os.exit(1) end
