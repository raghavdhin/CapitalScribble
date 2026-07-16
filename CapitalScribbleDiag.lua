--[[============================================================
  CapitalScribbleDiag — on-machine validator for CapitalScribble
  Run from Workspace → Scripts → CapitalScribbleDiag with any comp open.

  What it does (all inside one undo, nodes left in the comp as
  CScribbleText99/… for visual inspection — delete them when done):
    1. dumps every input ID of TextPlus / FastNoise / Displace /
       SoftGlow / StyledTextFollower to the diag log, so wrong input
       names in CapitalScribble.lua can be corrected without guessing
    2. builds a full stack via the engine (word-by-word ON,
       Scribble+Fade in, Draw-on out) and verifies:
       wiring, Seethe expression, refraction keys, Blend keys,
       follower + XYPath modifiers, WriteOn keys
  Log: ~/Library/Application Support/Blackmagic Design/
       DaVinci Resolve/Fusion/CapitalScribble/logs/diag.log
============================================================]]--

-- NOTE: plain globals do NOT cross dofile boundaries in the Fusion script
-- runtime (each file gets its own env — verified with fuscript 2026-07-16),
-- so the library-mode flag must be injected via loadfile + setfenv.
local SCRIPT_DIR = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Comp/"
local chunk, lerr = loadfile(SCRIPT_DIR .. "CapitalScribble.lua")
assert(chunk, "cannot load CapitalScribble.lua: " .. tostring(lerr))
setfenv(chunk, setmetatable({ CAPITALSCRIBBLE_LIBRARY_MODE = true }, { __index = getfenv(1) }))
local M = chunk()

local LOG = M.LOG_DIR .. "/diag.log"
local results = { pass = 0, fail = 0 }

local function log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[CSDiag] " .. msg)
    local f = io.open(LOG, "a")
    if f then f:write(os.date("[%H:%M:%S] ") .. msg .. "\n"); f:close() end
end

local function check(name, ok, detail)
    if ok then results.pass = results.pass + 1 else results.fail = results.fail + 1 end
    log("%s  %s%s", ok and "PASS" or "FAIL", name, detail and ("  — " .. tostring(detail)) or "")
    return ok
end

log("================ CapitalScribbleDiag (engine %s) ================", M.VERSION)
if not comp then
    log("ABORT: no comp. Open the Fusion page on a clip/Fusion comp first.")
    return
end

------------------------------------------------------------------
-- 0. environment probe — what does this build actually give us?
------------------------------------------------------------------
pcall(function()
    local v = "?"
    pcall(function() v = tostring(fu.Version) end)
    pcall(function() v = v .. " / " .. tostring(fusion:GetVersion and fusion:GetVersion() or "") end)
    log("ENV  fusion version: %s", v)
end)
pcall(function()
    local a = comp:GetAttrs() or {}
    log("ENV  comp: name=%s locked=%s", tostring(a.COMPS_Name), tostring(a.COMPB_Locked))
end)
log("ENV  comp.AddTool=%s comp.Paste=%s comp.AddToolAction=%s bmd.readfile=%s",
    type(comp.AddTool), type(comp.Paste), type(comp.AddToolAction),
    type(bmd and bmd.readfile))

------------------------------------------------------------------
-- 1. input dumps
------------------------------------------------------------------
local function dumpInputs(tool, label)
    if not tool then log("DUMP %s: tool missing", label); return end
    local ids = {}
    local ok = pcall(function()
        for _, inp in ipairs(tool:GetInputList()) do
            local a = inp:GetAttrs()
            if a and a.INPS_ID then table.insert(ids, a.INPS_ID) end
        end
    end)
    if not ok or #ids == 0 then
        -- fallback: attr table walk
        pcall(function()
            for k, inp in pairs(tool:GetInputList() or {}) do
                local a = inp:GetAttrs()
                if a and a.INPS_ID then table.insert(ids, a.INPS_ID) end
            end
        end)
    end
    table.sort(ids)
    log("DUMP %s inputs (%d): %s", label, #ids, table.concat(ids, ", "))
end

comp:StartUndo("CSDiag")
local okRun, err = pcall(function()

    local probe = {}
    for _, regid in ipairs({ "TextPlus", "FastNoise", "Displace", "SoftGlow" }) do
        local t = M.AddToolSafe(regid, "CSDiagProbe_" .. regid, -32768, -32768)
        probe[regid] = t
        dumpInputs(t, regid)
    end
    if not probe.TextPlus then
        -- AddTool dead on this build: get the dumps via the Paste route instead
        log("AddTool probes failed — dumping inputs from a pasted stack")
        local ps = M.PasteStack("98")
        if ps then
            dumpInputs(ps.Text, "TextPlus"); dumpInputs(ps.Noise, "FastNoise")
            dumpInputs(ps.Disp, "Displace"); dumpInputs(ps.Glow, "SoftGlow")
            probe.TextPlus = ps.Text
            probe.__pasted = ps
        end
    end
    -- follower needs a host
    if probe.TextPlus then
        pcall(function() probe.TextPlus:AddModifier("StyledText", "StyledTextFollower") end)
        local out
        pcall(function() out = probe.TextPlus.StyledText:GetConnectedOutput() end)
        local fol = out and out:GetTool() or nil
        check("StyledTextFollower via AddModifier", fol ~= nil)
        dumpInputs(fol, "StyledTextFollower")
    end
    local pasted = probe.__pasted
    probe.__pasted = nil
    if pasted then
        for _, part in ipairs({ "Text", "Noise", "Disp", "Glow" }) do
            pcall(function() pasted[part]:Delete() end)
        end
        probe.TextPlus = nil
    end
    for _, t in pairs(probe) do pcall(function() t:Delete() end) end

    ------------------------------------------------------------------
    -- 2. full engine build + verification
    ------------------------------------------------------------------
    -- force a predictable index so re-runs reuse/replace the same nodes
    local old = M.FindStack("99")
    if old then for _, k in ipairs({ "Text", "Noise", "Disp", "Glow" }) do
        pcall(function() old[k]:Delete() end)
    end end

    local s = M.CreateStack()
    check("CreateStack returns all four tools",
          s and s.Text and s.Noise and s.Disp and s.Glow)
    if not s then error("no stack — aborting rest") end
    -- rename to the diag index
    for part, t in pairs({ Text = s.Text, Noise = s.Noise, Disp = s.Disp, Glow = s.Glow }) do
        pcall(function() t:SetAttrs({ TOOLS_Name = "CScribble" .. part .. "99" }) end)
    end
    s.idx = "99"

    local ok, msg = M.Apply(s, {
        text = "SCRIBBLE DIAG TEST", styleId = "sketch",
        font = "Noteworthy", size = 0.1, colorHex = "#dcf000",
        boilAmount = 0.6, boilStep = 3,
        trIn = "Scribble + Fade", trOut = "Draw-on",
        dIn = 12, dOut = 10, sf = 0, ef = 60,
        wordByWord = true, wordDelay = 1.03,
    })
    check("Apply returns ok", ok, msg)

    -- wiring
    local function srcOf(tool, inputName)
        local o
        pcall(function() o = tool[inputName]:GetConnectedOutput() end)
        return o and o:GetTool() or nil
    end
    check("Displace.Input ← Text",       srcOf(s.Disp, "Input") == s.Text)
    check("Displace.Foreground ← Noise", srcOf(s.Disp, "Foreground") == s.Noise)
    check("Glow.Input ← Displace",       srcOf(s.Glow, "Input") == s.Disp)

    -- Seethe expression
    local expr
    pcall(function() expr = s.Noise.Seethe:GetExpression() end)
    check("Seethe boil expression set", expr ~= nil and expr:find("floor") ~= nil, expr)

    -- refraction keys (scribble in => 3 keys expected on XRefraction)
    local function keyCount(tool, inputName)
        local n
        pcall(function()
            local sp = tool[inputName]:GetConnectedOutput():GetTool()
            local kf = sp:GetKeyFrames()
            n = 0
            for _ in pairs(kf or {}) do n = n + 1 end
        end)
        return n
    end
    check("XRefraction has scribble keys", (keyCount(s.Disp, "XRefraction") or 0) >= 3,
          tostring(keyCount(s.Disp, "XRefraction")) .. " keys")
    check("Blend has fade keys", (keyCount(s.Text, "Blend") or 0) >= 2,
          tostring(keyCount(s.Text, "Blend")) .. " keys")
    check("WriteOnStart has draw-out keys", (keyCount(s.Text, "WriteOnStart") or 0) >= 2,
          tostring(keyCount(s.Text, "WriteOnStart")) .. " keys")

    -- follower present with opacity keys
    local fout
    pcall(function() fout = s.Text.StyledText:GetConnectedOutput() end)
    local fol = fout and fout:GetTool() or nil
    check("Follower attached in word-by-word mode", fol ~= nil)
    if fol then
        check("Follower Opacity1 eased", (keyCount(fol, "Opacity1") or 0) >= 2,
              tostring(keyCount(fol, "Opacity1")) .. " keys")
        local wo
        pcall(function() wo = fol.WordOffset:GetConnectedOutput() end)
        check("WordOffset has XYPath rise", wo ~= nil)
    end
end)
comp:EndUndo(true)
if not okRun then log("DIAG ERROR (contained): %s", tostring(err)) end

log("================ DONE: %d pass / %d fail ================", results.pass, results.fail)
log("Test nodes left as CScribble*99 — look at CScribbleGlow99, then delete them.")
