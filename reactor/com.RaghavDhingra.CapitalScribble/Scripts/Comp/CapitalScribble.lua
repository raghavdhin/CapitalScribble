--[[============================================================
  CapitalScribble — hand-drawn text animator for DaVinci Resolve Fusion
  Capital Code · v0.9.0 (first on-machine build)

  A Resolve-native take on the "Hand Drawn Animator" idea:
  boiling hand-drawn text, scribble in/out transitions, word-by-word
  sequencing — driven from one UIManager panel.

  Install : this file lives in  Fusion/Scripts/Comp/
  Run     : Fusion page → Workspace → Scripts → CapitalScribble
  Data    : ~/Library/Application Support/Blackmagic Design/
            DaVinci Resolve/Fusion/CapitalScribble/
  Target  : Resolve 19.0.x free (UIManager is Studio-only from 19.1+)

  Node stack (created/updated by the panel, one per "stack index"):
      CScribbleText<i>   TextPlus   — text, font, style elements, color
        └ StyledTextFollower (word-by-word mode) + XYPath word rise
      CScribbleNoise<i>  FastNoise  — boil source; Seethe stepped by expression
      CScribbleDisp<i>   Displace   — XY refraction = boil / scribble smear
      CScribbleGlow<i>   SoftGlow   — terminal node; merge this over footage

  API ground rules inherited from CapitalEase (all verified on 19.0.3):
    * SetKeyFrames REPLACES the whole key set; LH/RH are OFFSETS.
    * ui:Timer never ticks; no widget mouse events; no Events tables.
    * Combo signals must not relayout (Stack page flips only).
    * Every write pcall-contained inside StartUndo/EndUndo.
    * os.clock is CPU time — never used for timing.
============================================================]]--

CapitalScribble = CapitalScribble or {}
local M = CapitalScribble
M.VERSION = "0.9.4"

------------------------------------------------------------------
-- 1. Paths + logging
------------------------------------------------------------------
local HOME = os.getenv("HOME") or ""
M.DATA_DIR = HOME .. "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/CapitalScribble"
M.LOG_DIR  = M.DATA_DIR .. "/logs"
M.LogFile  = M.LOG_DIR .. "/engine.log"

local function ensureDir(path)
    local ok = false
    if bmd and bmd.createdir then ok = pcall(bmd.createdir, path) end
    if not ok then os.execute(string.format('mkdir -p "%s"', path)) end
end
ensureDir(M.DATA_DIR)
ensureDir(M.LOG_DIR)

function M.Log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    local line = os.date("[%H:%M:%S] ") .. msg
    print("[CapitalScribble] " .. msg)
    local f = io.open(M.LogFile, "a")
    if f then f:write(line, "\n"); f:close() end
end

------------------------------------------------------------------
-- 2. Small utils
------------------------------------------------------------------
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end
M.clamp = clamp

function M.HexToRGB(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("^#", ""):gsub("%s", "")
    if #hex == 3 then
        hex = hex:sub(1,1):rep(2) .. hex:sub(2,2):rep(2) .. hex:sub(3,3):rep(2)
    end
    if #hex ~= 6 or hex:find("[^0-9a-fA-F]") then return nil end
    return tonumber(hex:sub(1, 2), 16) / 255,
           tonumber(hex:sub(3, 4), 16) / 255,
           tonumber(hex:sub(5, 6), 16) / 255
end

function M.RGBToHex(r, g, b)
    local function c(x) return string.format("%02x", math.floor(clamp(x, 0, 1) * 255 + 0.5)) end
    return "#" .. c(r) .. c(g) .. c(b)
end

-- Boil: FastNoise Seethe jumps once every `step` frames -> text "redraws"
function M.BoilExpression(step)
    step = math.max(1, math.floor(step + 0.5))
    return string.format("floor(time/%d)*0.6180339887", step)
end

-- Transition key layout (pure math, headless-testable).
-- Returns key times for the in/out windows given SF/EF and durations.
function M.TransitionWindows(sf, ef, dIn, dOut)
    sf, ef = math.floor(sf), math.floor(ef)
    if ef <= sf then ef = sf + 1 end
    dIn  = math.max(0, math.floor(dIn))
    dOut = math.max(0, math.floor(dOut))
    local span = ef - sf
    if dIn + dOut > span then          -- shrink both proportionally to fit
        local scale = span / (dIn + dOut)
        dIn  = math.floor(dIn * scale)
        dOut = math.max(0, span - dIn)
    end
    return { inA = sf, inB = sf + dIn, outA = ef - dOut, outB = ef }
end

------------------------------------------------------------------
-- 3. Styles + look constants
------------------------------------------------------------------
-- Element sub-inputs (ElementShape2, Softness5, …) only EXIST while their
-- element is enabled (verified via diag input dumps 2026-07-16), so element
-- configuration lives in the paste template; styles just flip Enabled flags.
-- `set` is an ORDERED list — Enabled toggles first, then anything else.
M.STYLES = {
    {
        id = "marker", label = "MARKER",
        font = "Marker Felt",
        boilAmount = 0.0045, glowBlend = 0.0,
        colorElems = { 1 },
        set = { { "Enabled1", 1 }, { "Enabled2", 0 }, { "Enabled5", 0 } },
    },
    {
        id = "sketch", label = "SKETCH",
        -- outline element is configured at Apply time via runtime enum
        -- decode (EnumIndexByLabel); falls back to plain fill if that fails
        font = "Noteworthy",
        boilAmount = 0.007, glowBlend = 0.35,
        colorElems = { 1, 2 },
        set = { { "Enabled1", 0 }, { "Enabled2", 1 }, { "Enabled5", 0 } },
    },
    {
        id = "smooth", label = "SMOOTH",   -- clean serif + glow (halo element shelved)
        font = "Ethic New",
        boilAmount = 0.0015, glowBlend = 0.5,
        colorElems = { 1 },
        set = { { "Enabled1", 1 }, { "Enabled2", 0 }, { "Enabled5", 0 } },
    },
}

-- grouped: hand-drawn · serif · script · sans · character
M.FONTS = {
    "Marker Felt", "Noteworthy", "Chalkboard SE", "Bradley Hand",
    "Comic Sans MS", "Permanent Marker", "Caveat",
    "Ethic New", "EB Garamond", "Instrument Serif", "Playfair Display",
    "Fraunces", "Young Serif", "Didot", "Baskerville", "Georgia",
    "Snell Roundhand", "Pinyon Script", "Great Vibes", "Zapfino", "Apple Chancery",
    "Inter", "Space Grotesk", "Manrope", "Outfit", "Avenir Next", "Optima",
    "Archivo Black",
    "American Typewriter", "Special Elite", "Space Mono",
}

-- Text+ renders NOTHING when the Style name doesn't exist for the font.
-- Every entry below was verified against the installed font's name table
-- (variable fonts: against their fvar named instances) on 2026-07-16.
M.FONT_STYLES = {
    ["Marker Felt"] = "Wide", ["Noteworthy"] = "Bold",
    ["Chalkboard SE"] = "Regular", ["Bradley Hand"] = "Bold",
    ["Comic Sans MS"] = "Regular", ["Permanent Marker"] = "Regular",
    ["Caveat"] = "Regular",
    ["Ethic New"] = "Semibold", ["Ethic Serif"] = "Semibold",
    ["EB Garamond"] = "Regular", ["Instrument Serif"] = "Regular",
    ["Playfair Display"] = "Regular", ["Fraunces"] = "SemiBold",
    ["Young Serif"] = "Regular", ["Didot"] = "Regular",
    ["Baskerville"] = "SemiBold", ["Georgia"] = "Regular",
    ["Snell Roundhand"] = "Bold", ["Pinyon Script"] = "Regular",
    ["Great Vibes"] = "Regular", ["Zapfino"] = "Regular",
    ["Apple Chancery"] = "Chancery",
    ["Inter"] = "Regular", ["Space Grotesk"] = "Medium",
    ["Manrope"] = "Medium", ["Outfit"] = "Medium",
    ["Avenir Next"] = "Medium", ["Optima"] = "Regular",
    ["Archivo Black"] = "Regular",
    ["American Typewriter"] = "Regular", ["Special Elite"] = "Regular",
    ["Space Mono"] = "Regular",
}

M.TRANSITIONS = { "None", "Scribble", "Fade", "Scribble + Fade", "Rise + Fade", "Draw-on" }

M.SCRIBBLE_MULT  = 22      -- transition peak = boil amount × this (capped)
M.SCRIBBLE_CAP   = 0.12
M.RISE_AMOUNT    = 0.044   -- from the user's word-by-word macro (Y rise)
M.WORD_DELAY     = 1.03    -- ditto (frames of stagger per word)
M.FOLLOWER_ORDER = 7       -- ditto (traversal order enum value)
M.EASE_FRAMES    = 25      -- ditto (per-word ease length)

------------------------------------------------------------------
-- 4. Tool write helpers (every miss is logged, nothing throws)
------------------------------------------------------------------
local function inputOf(tool, name)
    local ok, inp = pcall(function() return tool[name] end)
    if ok and inp then return inp end
    return nil
end

-- static write; returns true on success, logs misses so the diag loop can fix names
function M.TrySet(tool, name, value)
    local inp = inputOf(tool, name)
    if not inp then
        M.Log("MISS  %s has no input '%s'", tostring(tool and tool.Name or "?"), name)
        return false
    end
    local ok = pcall(function() inp[fu.TIME_UNDEFINED] = value end)
    if not ok then
        ok = pcall(function() inp[comp and comp.CurrentTime or 0] = value end)
    end
    if not ok then M.Log("FAIL  set %s.%s", tostring(tool.Name), name) end
    return ok
end

function M.TrySetExpr(tool, name, expr)
    local inp = inputOf(tool, name)
    if not inp then
        M.Log("MISS  %s has no input '%s' (expression)", tostring(tool and tool.Name or "?"), name)
        return false
    end
    local ok = pcall(function() inp:SetExpression(expr) end)
    if not ok then M.Log("FAIL  expression on %s.%s", tostring(tool.Name), name) end
    return ok
end

-- fetch (or create) the BezierSpline modifier driving tool[name]
function M.SplineOf(tool, name)
    local inp = inputOf(tool, name)
    if not inp then
        M.Log("MISS  %s has no input '%s' (spline)", tostring(tool and tool.Name or "?"), name)
        return nil
    end
    local function driver()
        local ok, out = pcall(function() return inp:GetConnectedOutput() end)
        if ok and out then
            local ok2, t = pcall(function() return out:GetTool() end)
            if ok2 and t then
                local a = t:GetAttrs()
                if a and a.TOOLS_RegID == "BezierSpline" then return t end
            end
        end
        return nil
    end
    local sp = driver()
    if sp then return sp end
    pcall(function() tool:AddModifier(name, "BezierSpline") end)
    sp = driver()
    if not sp then M.Log("FAIL  no BezierSpline on %s.%s after AddModifier", tostring(tool.Name), name) end
    return sp
end

-- write an eased pair of keys (smooth 1/3 handles, offsets per CapitalEase rules)
function M.WriteEase(spline, tA, vA, tB, vB)
    if not spline then return false end
    local dt = (tB - tA) / 3
    local keys = {
        [tA] = { vA, RH = { dt, 0 } },
        [tB] = { vB, LH = { -dt, 0 } },
    }
    local ok = pcall(function() spline:SetKeyFrames(keys, true) end)
    if not ok then M.Log("FAIL  SetKeyFrames on %s", tostring(spline.Name)) end
    return ok
end

-- write an arbitrary key list {{t=,v=},...} with smooth flat handles
function M.WriteKeys(spline, list)
    if not spline then return false end
    table.sort(list, function(a, b) return a.t < b.t end)
    local keys = {}
    for i, k in ipairs(list) do
        local e = { k.v }
        if i > 1     then e.LH = { -(k.t - list[i-1].t) / 3, 0 } end
        if i < #list then e.RH = {  (list[i+1].t - k.t) / 3, 0 } end
        keys[k.t] = e
    end
    local ok = pcall(function() spline:SetKeyFrames(keys, true) end)
    if not ok then M.Log("FAIL  SetKeyFrames on %s", tostring(spline.Name)) end
    return ok
end

-- Decode a multibutton/combo input's numeric value from its option LABEL.
-- (Guessing enum constants burned us twice: ElementShape values differ from
-- every archive example. The input's own attrs carry the label list.)
-- Returns value, matchedLabel — or nil if no option matches.
function M.EnumIndexByLabel(tool, name, wanted)
    local inp = inputOf(tool, name)
    if not inp then return nil end
    local ok, attrs = pcall(function() return inp:GetAttrs() end)
    if not ok or type(attrs) ~= "table" then return nil end
    wanted = wanted:lower()
    for _, v in pairs(attrs) do
        if type(v) == "table" then
            local zeroBased = v[0] ~= nil
            for idx, lbl in pairs(v) do
                if type(lbl) == "string" and type(idx) == "number"
                   and lbl:lower() == wanted then
                    return zeroBased and idx or (idx - 1), lbl
                end
            end
        end
    end
    return nil
end

function M.ClearAnim(tool, name)
    local inp = inputOf(tool, name)
    if not inp then return end
    pcall(function() inp:ConnectTo(nil) end)
end

------------------------------------------------------------------
-- 5. Stack discovery / creation
------------------------------------------------------------------
local PARTS = { Text = "TextPlus", Noise = "FastNoise", Disp = "Displace", Glow = "SoftGlow" }

local function stackIndexOf(toolName)
    return tostring(toolName or ""):match("^CScribble%a+(%d+)$")
end

function M.FindStack(idx)
    if not comp then return nil end
    local s = { idx = idx }
    local all = comp:GetToolList(false) or {}
    for _, t in ipairs(all) do
        local a = t:GetAttrs()
        local nm = a and a.TOOLS_Name or ""
        for part in pairs(PARTS) do
            if nm == "CScribble" .. part .. idx then s[part] = t end
        end
    end
    if s.Text then return s end
    return nil
end

-- stack of the currently selected/active CScribble node, else nil
function M.CurrentStack()
    if not comp then return nil end
    local cand = comp.ActiveTool
    local sel = comp:GetToolList(true) or {}
    local tools = {}
    if cand then table.insert(tools, cand) end
    for _, t in ipairs(sel) do table.insert(tools, t) end
    for _, t in ipairs(tools) do
        local idx = stackIndexOf(t:GetAttrs().TOOLS_Name)
        if idx then return M.FindStack(idx) end
    end
    return nil
end

local function nextFreeIndex()
    local i = 1
    while M.FindStack(tostring(i)) do i = i + 1 end
    return tostring(i)
end

function M.AddToolSafe(regid, name, x, y)
    local t
    local ok, err = pcall(function() t = comp:AddTool(regid, x, y) end)
    if not t then
        M.Log("AddTool(%s,x,y): ok=%s err=%s result=nil", regid, tostring(ok), tostring(err))
        ok, err = pcall(function() t = comp:AddTool(regid) end)
        if not t then
            M.Log("AddTool(%s): ok=%s err=%s result=nil", regid, tostring(ok), tostring(err))
        end
    end
    if t then pcall(function() t:SetAttrs({ TOOLS_Name = name }) end) end
    return t
end

-- Plan B: paste the whole pre-wired stack as a .setting table (the same
-- mechanism as dragging a macro in) — works even where AddTool is unhappy.
local STACK_TEMPLATE = [[{
	Tools = ordered() {
		CScribbleText = TextPlus {
			Inputs = {
				UseFrameFormatSettings = Input { Value = 1, },
				Size = Input { Value = 0.12, },
				VerticalJustificationNew = Input { Value = 3, },
				HorizontalJustificationNew = Input { Value = 3, },
				-- all three style elements ship configured (sub-inputs only
				-- exist while enabled, so this is the one reliable place);
				-- Apply() then flips the Enabled flags per chosen style
				Enabled1 = Input { Value = 1, },
				Enabled2 = Input { Value = 1, },
				ElementShape2 = Input { Value = 2, },
				Level2 = Input { Value = 1, },
				Thickness2 = Input { Value = 0.0045, },
				Red2 = Input { Value = 1, },
				Green2 = Input { Value = 1, },
				Blue2 = Input { Value = 1, },
				Enabled5 = Input { Value = 1, },
				ElementShape5 = Input { Value = 2, },
				Level5 = Input { Value = 2, },
				ExtendHorizontal5 = Input { Value = -0.217, },
				ExtendVertical5 = Input { Value = -0.053, },
				Softness5 = Input { Value = 1, },
			},
			ViewInfo = OperatorInfo { Pos = { 0, 0 } },
		},
		CScribbleNoise = FastNoise {
			Inputs = {
				UseFrameFormatSettings = Input { Value = 1, },
				XScale = Input { Value = 14, },
				Detail = Input { Value = 6, },
				Contrast = Input { Value = 1.6, },
				Brightness = Input { Value = -0.12, },
				SeetheRate = Input { Value = 0, },
			},
			ViewInfo = OperatorInfo { Pos = { -110, 33 } },
		},
		CScribbleDisp = Displace {
			Inputs = {
				Type = Input { Value = 1, },
				XChannel = Input { Value = 4, },
				YChannel = Input { Value = 4, },
				Input = Input { SourceOp = "CScribbleText", Source = "Output", },
				Foreground = Input { SourceOp = "CScribbleNoise", Source = "Output", },
			},
			ViewInfo = OperatorInfo { Pos = { 0, 33 } },
		},
		CScribbleGlow = SoftGlow {
			Inputs = {
				Input = Input { SourceOp = "CScribbleDisp", Source = "Output", },
			},
			ViewInfo = OperatorInfo { Pos = { 0, 66 } },
		}
	}
}]]

local REGID_TO_PART = { TextPlus = "Text", FastNoise = "Noise",
                        Displace = "Disp", SoftGlow = "Glow" }

function M.PasteStack(idx)
    local path = M.DATA_DIR .. "/CScribbleStack.setting"
    local f = io.open(path, "w")
    if not f then M.Log("PasteStack: cannot write template"); return nil end
    f:write(STACK_TEMPLATE); f:close()

    local tbl
    local ok, err = pcall(function() tbl = bmd.readfile(path) end)
    if not tbl then
        M.Log("PasteStack: bmd.readfile failed ok=%s err=%s", tostring(ok), tostring(err))
        return nil
    end
    ok, err = pcall(function() comp:Paste(tbl) end)
    if not ok then M.Log("PasteStack: Paste failed err=%s", tostring(err)); return nil end

    -- pasted tools come in selected; map them by RegID and stamp our names
    local s = { idx = idx }
    local sel = comp:GetToolList(true) or {}
    for _, t in ipairs(sel) do
        local part = REGID_TO_PART[t:GetAttrs().TOOLS_RegID]
        if part and not s[part] then
            s[part] = t
            pcall(function() t:SetAttrs({ TOOLS_Name = "CScribble" .. part .. idx }) end)
        end
    end
    if s.Text and s.Noise and s.Disp and s.Glow then
        M.Log("PasteStack: created stack %s via Paste", idx)
        return s
    end
    M.Log("PasteStack: paste succeeded but tools not found in selection (%d selected)", #sel)
    return nil
end

function M.CreateStack()
    local idx = nextFreeIndex()
    local x, y = 0, 0
    pcall(function()
        local flow = comp.CurrentFrame.FlowView
        x, y = flow:GetPosTable(comp.ActiveTool)   -- may be nil; pcall guards
    end)
    x, y = x or 0, y or 0

    -- Paste is the PRIMARY route: it is the only way to ship pre-configured
    -- shading elements (their sub-inputs don't exist until enabled).
    local ps = M.PasteStack(idx)
    if ps then return ps end

    M.Log("Paste route failed — falling back to AddTool (element config best-effort)")
    local s = { idx = idx }
    s.Text  = M.AddToolSafe("TextPlus",  "CScribbleText"  .. idx, x, y)
    s.Noise = M.AddToolSafe("FastNoise", "CScribbleNoise" .. idx, x - 1, y + 1)
    s.Disp  = M.AddToolSafe("Displace",  "CScribbleDisp"  .. idx, x, y + 1)
    s.Glow  = M.AddToolSafe("SoftGlow",  "CScribbleGlow"  .. idx, x, y + 2)

    if not (s.Text and s.Noise and s.Disp and s.Glow) then
        for _, part in ipairs({ "Text", "Noise", "Disp", "Glow" }) do
            if s[part] then pcall(function() s[part]:Delete() end) end
        end
        M.Log("AddTool route failed too — no stack")
        return nil
    end

    -- best-effort element config on this route: enable first so the
    -- sub-inputs materialize, then configure them
    M.TrySet(s.Text, "Enabled2", 1)
    M.TrySet(s.Text, "ElementShape2", 2)
    M.TrySet(s.Text, "Level2", 1)
    M.TrySet(s.Text, "Thickness2", 0.0045)
    M.TrySet(s.Text, "Enabled5", 1)
    M.TrySet(s.Text, "ElementShape5", 2)
    M.TrySet(s.Text, "Level5", 2)
    M.TrySet(s.Text, "ExtendHorizontal5", -0.217)
    M.TrySet(s.Text, "ExtendVertical5", -0.053)
    M.TrySet(s.Text, "Softness5", 1)

    -- wiring: Text -> Displace(Input), Noise -> Displace(Foreground), Displace -> Glow
    pcall(function() s.Disp.Input = s.Text.Output end)
    pcall(function() s.Disp.Foreground = s.Noise.Output end)
    pcall(function() s.Glow.Input = s.Disp.Output end)

    -- noise: fine detail, mid contrast; Seethe gets the boil expression later
    M.TrySet(s.Noise, "UseFrameFormatSettings", 1)
    M.TrySet(s.Noise, "XScale", 14)
    M.TrySet(s.Noise, "Detail", 6)
    M.TrySet(s.Noise, "Contrast", 1.6)
    M.TrySet(s.Noise, "Brightness", -0.12)
    M.TrySet(s.Noise, "SeetheRate", 0)

    -- displace: XY mode, both channels off luminance
    M.TrySet(s.Disp, "Type", 1)
    M.TrySet(s.Disp, "XChannel", 4)
    M.TrySet(s.Disp, "YChannel", 4)

    M.TrySet(s.Text, "UseFrameFormatSettings", 1)

    M.Log("Created stack %s", idx)
    return s
end

------------------------------------------------------------------
-- 6. Applying settings to a stack
------------------------------------------------------------------
local function styleById(id)
    for _, st in ipairs(M.STYLES) do if st.id == id then return st end end
    return M.STYLES[1]
end

-- word-by-word: follower modifier on StyledText + XYPath rise on WordOffset
local function followerOf(textTool, create)
    local inp = inputOf(textTool, "StyledText")
    if not inp then return nil end
    local function driver()
        local ok, out = pcall(function() return inp:GetConnectedOutput() end)
        if ok and out then
            local ok2, t = pcall(function() return out:GetTool() end)
            if ok2 and t and t:GetAttrs().TOOLS_RegID == "StyledTextFollower" then return t end
        end
        return nil
    end
    local f = driver()
    if f or not create then return f end
    pcall(function() textTool:AddModifier("StyledText", "StyledTextFollower") end)
    f = driver()
    if not f then M.Log("FAIL  StyledTextFollower on %s", tostring(textTool.Name)) end
    return f
end

-- opts: { text, styleId, font, size, colorHex, boilAmount(0..1), boilStep,
--         trIn, trOut, dIn, dOut, sf, ef, wordByWord, wordDelay }
function M.Apply(s, opts)
    if not (s and s.Text) then return false, "no stack" end
    local st = styleById(opts.styleId)
    local r, g, b = M.HexToRGB(opts.colorHex or "#ffffff")
    if not r then r, g, b = 1, 1, 1 end
    local amount = st.boilAmount * (0.25 + 1.5 * clamp(opts.boilAmount or 0.5, 0, 1))
    local W = M.TransitionWindows(opts.sf or 0, opts.ef or 90, opts.dIn or 12, opts.dOut or 12)
    local report = {}

    pcall(function() comp:StartUndo("CapitalScribble: apply") end)
    local okAll = pcall(function()

        ----------------------------------------------------------
        -- text, font, style elements, color
        ----------------------------------------------------------
        local fol = followerOf(s.Text, opts.wordByWord)
        if opts.wordByWord and fol then
            M.TrySet(fol, "Text", opts.text or "SCRIBBLE")
            M.TrySet(fol, "Order", M.FOLLOWER_ORDER)
            M.TrySet(fol, "Delay", opts.wordDelay or M.WORD_DELAY)
            M.TrySet(fol, "SelectTransform", 1)
            -- per-word ease: opacity 0->1 (the follower staggers it per word)
            M.WriteEase(M.SplineOf(fol, "Opacity1"), W.inA, 0, W.inA + M.EASE_FRAMES, 1)
            -- per-word rise via XYPath on WordOffset (scalar X/Y splines)
            pcall(function() fol:AddModifier("WordOffset", "XYPath") end)
            local wo = inputOf(fol, "WordOffset")
            if wo then
                local ok, out = pcall(function() return wo:GetConnectedOutput() end)
                if ok and out then
                    local xy = out:GetTool()
                    if xy then
                        M.WriteEase(M.SplineOf(xy, "Y"), W.inA, -M.RISE_AMOUNT, W.inA + M.EASE_FRAMES, 0)
                        M.TrySet(xy, "X", 0)
                    end
                end
            end
            table.insert(report, "word-by-word")
        else
            if fol and not opts.wordByWord then
                M.ClearAnim(s.Text, "StyledText")   -- drop follower, back to static text
            end
            M.TrySet(s.Text, "StyledText", opts.text or "SCRIBBLE")
        end

        local font = opts.font or st.font
        M.TrySet(s.Text, "Font", font)
        M.TrySet(s.Text, "Style", opts.fontStyle or M.FONT_STYLES[font] or "Regular")
        M.TrySet(s.Text, "Size", opts.size or 0.12)
        -- ordered: Enabled flags flip first (sub-inputs exist only while enabled)
        for _, kv in ipairs(st.set) do M.TrySet(s.Text, kv[1], kv[2]) end
        if st.id == "sketch" then
            -- configure the outline by decoding the actual enum labels
            local shapeV, shapeL = M.EnumIndexByLabel(s.Text, "ElementShape2", "text outline")
            local levelV, levelL = M.EnumIndexByLabel(s.Text, "Level2", "character")
            M.Log("sketch decode: ElementShape2=%s(%s) Level2=%s(%s)",
                  tostring(shapeV), tostring(shapeL), tostring(levelV), tostring(levelL))
            if shapeV then
                M.TrySet(s.Text, "ElementShape2", shapeV)
                if levelV then M.TrySet(s.Text, "Level2", levelV) end
                M.TrySet(s.Text, "Thickness2", 0.006)
            else
                -- can't identify Text Outline on this build: readable fallback
                M.Log("sketch decode failed — falling back to fill")
                M.TrySet(s.Text, "Enabled2", 0)
                M.TrySet(s.Text, "Enabled1", 1)
            end
        end
        for _, el in ipairs(st.colorElems) do
            M.TrySet(s.Text, "Red" .. el, r)
            M.TrySet(s.Text, "Green" .. el, g)
            M.TrySet(s.Text, "Blue" .. el, b)
        end

        ----------------------------------------------------------
        -- boil
        ----------------------------------------------------------
        if s.Noise then
            M.TrySetExpr(s.Noise, "Seethe", M.BoilExpression(opts.boilStep or 3))
        end

        ----------------------------------------------------------
        -- glow
        ----------------------------------------------------------
        if s.Glow then
            M.TrySet(s.Glow, "Blend", st.glowBlend)
            M.TrySet(s.Glow, "Gain", 0.6)
            if not M.TrySet(s.Glow, "XGlowSize", 6) then
                M.TrySet(s.Glow, "GlowSize", 6)
            end
        end

        ----------------------------------------------------------
        -- transitions (keys on Displace refraction + Text Blend + WriteOn)
        ----------------------------------------------------------
        local peak = math.min(amount * M.SCRIBBLE_MULT, M.SCRIBBLE_CAP)
        local trIn, trOut = opts.trIn or "None", opts.trOut or "None"

        local function wants(tr, what)
            if what == "scribble" then return tr == "Scribble" or tr == "Scribble + Fade" end
            if what == "fade" then
                return tr == "Fade" or tr == "Scribble + Fade" or tr == "Rise + Fade"
            end
            if what == "rise" then return tr == "Rise + Fade" end
            if what == "draw" then return tr == "Draw-on" end
        end

        -- displace refraction: base boil always on; scribble peaks at the edges
        if s.Disp then
            local xs = { { t = W.inB, v = amount }, { t = W.outA, v = amount } }
            if wants(trIn,  "scribble") then table.insert(xs, { t = W.inA,  v = peak }) end
            if wants(trOut, "scribble") then table.insert(xs, { t = W.outB, v = peak }) end
            if #xs > 2 then
                M.WriteKeys(M.SplineOf(s.Disp, "XRefraction"), xs)
                M.WriteKeys(M.SplineOf(s.Disp, "YRefraction"), xs)
                table.insert(report, "scribble keys")
            else
                M.ClearAnim(s.Disp, "XRefraction"); M.ClearAnim(s.Disp, "YRefraction")
                M.TrySet(s.Disp, "XRefraction", amount)
                M.TrySet(s.Disp, "YRefraction", amount)
            end
        end

        -- fades on Text+ master Alpha (Text+ has NO Blend input — verified)
        local fadeIn, fadeOut = wants(trIn, "fade"), wants(trOut, "fade")
        if fadeIn or fadeOut then
            local ks = {}
            table.insert(ks, { t = W.inA,  v = fadeIn and 0 or 1 })
            if fadeIn then table.insert(ks, { t = W.inB, v = 1 }) end
            if fadeOut then table.insert(ks, { t = W.outA, v = 1 }) end
            table.insert(ks, { t = W.outB, v = fadeOut and 0 or 1 })
            M.WriteKeys(M.SplineOf(s.Text, "Alpha"), ks)
            table.insert(report, "fade keys")
        else
            M.ClearAnim(s.Text, "Alpha")
            M.TrySet(s.Text, "Alpha", 1)
        end

        -- draw-on: Text+ write-on range is the Start/End input pair (verified)
        if wants(trIn, "draw") then
            M.WriteEase(M.SplineOf(s.Text, "End"), W.inA, 0, W.inB, 1)
            table.insert(report, "draw-on in")
        else
            M.ClearAnim(s.Text, "End"); M.TrySet(s.Text, "End", 1)
        end
        if wants(trOut, "draw") then
            M.WriteEase(M.SplineOf(s.Text, "Start"), W.outA, 0, W.outB, 1)
            table.insert(report, "draw-on out")
        else
            M.ClearAnim(s.Text, "Start"); M.TrySet(s.Text, "Start", 0)
        end

        -- block rise (only when not word-by-word; word mode rises per word)
        if (wants(trIn, "rise") or wants(trOut, "rise")) and not opts.wordByWord then
            pcall(function() s.Text:AddModifier("Center", "XYPath") end)
            local ci = inputOf(s.Text, "Center")
            if ci then
                local ok, out = pcall(function() return ci:GetConnectedOutput() end)
                if ok and out then
                    local xy = out:GetTool()
                    if xy then
                        local ks = {}
                        if wants(trIn, "rise") then
                            table.insert(ks, { t = W.inA, v = 0.5 - M.RISE_AMOUNT })
                            table.insert(ks, { t = W.inB, v = 0.5 })
                        end
                        if wants(trOut, "rise") then
                            if #ks == 0 then table.insert(ks, { t = W.outA, v = 0.5 }) end
                            table.insert(ks, { t = W.outB, v = 0.5 + M.RISE_AMOUNT })
                        end
                        M.WriteKeys(M.SplineOf(xy, "Y"), ks)
                        M.TrySet(xy, "X", 0.5)
                        table.insert(report, "rise keys")
                    end
                end
            end
        end
    end)
    pcall(function() comp:EndUndo(true) end)

    if not okAll then
        M.Log("Apply FAILED (error contained; comp undo closed)")
        return false, "error during apply — see engine.log"
    end
    M.Log("Applied to stack %s: %s", s.idx or "?", table.concat(report, ", "))
    return true, table.concat(report, ", ")
end

------------------------------------------------------------------
-- 7. UI
------------------------------------------------------------------
local ACCENT = "#dcf000"
local CSS = [[
QWidget { background-color: #17171a; color: #c9c9ce; font-size: 12px; }
QPushButton { background-color: #232328; border: 1px solid #2e2e35; border-radius: 6px;
              padding: 3px 7px; color: #d8d8dc; }
QPushButton:hover { border-color: #dcf000; }
QPushButton:pressed { background-color: #dcf000; color: #121212; }
QPushButton:disabled { color: #4a4a50; border-color: #232328; background-color: #1c1c20; }
QComboBox { background-color: #232328; border: 1px solid #2e2e35; border-radius: 6px;
            padding: 2px 8px; color: #d8d8dc; }
QComboBox QAbstractItemView { background-color: #232328; color: #d8d8dc;
            selection-background-color: #dcf000; selection-color: #121212; }
QLineEdit, QTextEdit { background-color: #1f1f24; border: 1px solid #2e2e35; border-radius: 6px;
            padding: 2px 6px; color: #ececf0; }
QDoubleSpinBox, QSpinBox { background-color: #1f1f24; border: 1px solid #2e2e35;
            border-radius: 5px; padding: 1px 3px; color: #ececf0; }
QCheckBox { color: #c9c9ce; spacing: 5px; }
QLabel { background: transparent; }
]]

local STYLE_HEX = { marker = "#ffaa50", sketch = "#5ac8fa", smooth = "#be82ff" }

local function chipCSS(hex, active)
    if active then
        return string.format(
            "QPushButton{background-color:%s;color:#141414;border:1px solid %s;border-radius:6px;padding:4px 2px;font-weight:bold;}",
            hex, hex)
    end
    return string.format(
        "QPushButton{background-color:#1e1e23;color:%s;border:1px solid #2c2c33;border-radius:6px;padding:4px 2px;}" ..
        "QPushButton:hover{border-color:%s;}", hex, hex)
end

local SWATCHES = { "#ffffff", "#111111", "#dcf000", "#ff5a5a", "#5ac8fa", "#ffaa50" }

function M.RunUI()
    if not (fu and fu.UIManager) then
        M.Log("UIManager unavailable (Studio-locked from 19.1+). Aborting UI.")
        return
    end
    if not comp then
        M.Log("No composition — open the Fusion page on a clip first.")
        return
    end
    local ui = fu.UIManager
    local disp = bmd.UIDispatcher(ui)

    local S = {
        styleId = "marker",
        colorHex = "#ffffff",
    }

    local swatchRow = { Spacing = 3, Weight = 0 }
    for i, hex in ipairs(SWATCHES) do
        swatchRow[#swatchRow + 1] = ui:Button{
            ID = "sw" .. i, Text = "", MinimumSize = { 24, 18 }, Flat = true,
            StyleSheet = string.format(
                "QPushButton{background-color:%s;border:1px solid #2c2c33;border-radius:4px;}", hex),
        }
    end

    local win = disp:AddWindow({
        ID = "CapitalScribbleWin",
        WindowTitle = "CapitalScribble " .. M.VERSION .. "  —  Capital Code",
        Geometry = { 720, 60, 560, 640 },
        Spacing = 4,
        ui:VGroup{
            StyleSheet = CSS,
            ui:HGroup{
                Weight = 0,
                ui:Label{ Text = "CAPITAL<b>SCRIBBLE</b>", Weight = 0,
                          StyleSheet = "QLabel{color:" .. ACCENT .. ";font-size:13px;letter-spacing:2px;}" },
                ui:Label{ ID = "targetLbl", Text = "new stack", Weight = 1, Alignment = { AlignRight = true },
                          StyleSheet = "QLabel{color:#9a9aa2;}" },
                ui:Button{ ID = "refreshBtn", Text = "↻", MinimumSize = { 26, 20 }, Weight = 0 },
            },
            ui:TextEdit{ ID = "textEdit", PlaceholderText = "Type your text…", MinimumSize = { 100, 64 }, Weight = 0 },
            ui:HGroup{
                Weight = 0,
                ui:Button{ ID = "styMarker", Text = "MARKER", Flat = true, Weight = 1, MinimumSize = { 60, 24 } },
                ui:Button{ ID = "stySketch", Text = "SKETCH", Flat = true, Weight = 1, MinimumSize = { 60, 24 } },
                ui:Button{ ID = "stySmooth", Text = "SMOOTH", Flat = true, Weight = 1, MinimumSize = { 60, 24 } },
            },
            ui:HGroup{
                Weight = 0,
                ui:Label{ Text = "Font", Weight = 0 },
                ui:ComboBox{ ID = "fontCmb", Weight = 1 },
                ui:LineEdit{ ID = "fontCustom", PlaceholderText = "custom font…", Weight = 1 },
            },
            ui:HGroup{
                Weight = 0,
                ui:Label{ Text = "Size", Weight = 0 },
                ui:Slider{ ID = "sizeSld", Minimum = 3, Maximum = 40, Value = 12, Weight = 1 },
                ui:Label{ Text = "Color", Weight = 0 },
                ui:LineEdit{ ID = "colorEdit", Text = S.colorHex, MinimumSize = { 76, 22 }, Weight = 0 },
            },
            ui:HGroup(swatchRow),
            ui:HGroup{
                Weight = 0,
                ui:Label{ Text = "Boil", Weight = 0 },
                ui:Slider{ ID = "boilSld", Minimum = 0, Maximum = 100, Value = 50, Weight = 1 },
                ui:Label{ Text = "redraw every", Weight = 0 },
                ui:SpinBox{ ID = "boilStep", Minimum = 1, Maximum = 8, Value = 3,
                            MinimumSize = { 52, 22 }, Weight = 0 },
                ui:Label{ Text = "f", Weight = 0 },
            },
            ui:HGroup{
                Weight = 0,
                ui:Label{ Text = "In", Weight = 0, MinimumSize = { 24, 14 } },
                ui:ComboBox{ ID = "trInCmb", Weight = 1 },
                ui:SpinBox{ ID = "dInSpin", Minimum = 1, Maximum = 120, Value = 12,
                            MinimumSize = { 52, 22 }, Weight = 0 },
                ui:Label{ Text = "f", Weight = 0 },
            },
            ui:HGroup{
                Weight = 0,
                ui:Label{ Text = "Out", Weight = 0, MinimumSize = { 24, 14 } },
                ui:ComboBox{ ID = "trOutCmb", Weight = 1 },
                ui:SpinBox{ ID = "dOutSpin", Minimum = 1, Maximum = 120, Value = 12,
                            MinimumSize = { 52, 22 }, Weight = 0 },
                ui:Label{ Text = "f", Weight = 0 },
            },
            ui:HGroup{
                Weight = 0,
                ui:CheckBox{ ID = "wordChk", Text = "Word-by-word", Checked = false, Weight = 0 },
                ui:Label{ Text = "delay", Weight = 0 },
                ui:DoubleSpinBox{ ID = "wordDelay", Minimum = 0.2, Maximum = 12, Decimals = 2,
                                  SingleStep = 0.1, Value = M.WORD_DELAY,
                                  MinimumSize = { 64, 22 }, Weight = 0 },
                ui:Label{ Text = "", Weight = 1 },
            },
            ui:HGroup{
                Weight = 0,
                ui:Label{ Text = "SF", Weight = 0 },
                ui:LineEdit{ ID = "sfEdit", Text = "", PlaceholderText = "playhead", Weight = 1 },
                ui:Button{ ID = "sfStamp", Text = "◉", MinimumSize = { 24, 18 }, Weight = 0 },
                ui:Label{ Text = "EF", Weight = 0 },
                ui:LineEdit{ ID = "efEdit", Text = "", PlaceholderText = "SF + 90", Weight = 1 },
                ui:Button{ ID = "efStamp", Text = "◉", MinimumSize = { 24, 18 }, Weight = 0 },
            },
            ui:HGroup{
                Weight = 0,
                ui:Button{ ID = "scribbleBtn", Text = "SCRIBBLE ⚡", MinimumSize = { 140, 32 }, Weight = 1,
                           StyleSheet = "QPushButton{background-color:" .. ACCENT ..
                               ";color:#131313;border-radius:7px;font-weight:bold;font-size:13px;}" ..
                               "QPushButton:hover{background-color:#eaff2e;}" ..
                               "QPushButton:pressed{background-color:#b8c900;}" },
                ui:Button{ ID = "newBtn", Text = "＋ New stack", Weight = 0, MinimumSize = { 90, 32 } },
            },
            ui:Label{ ID = "statusLbl", Text = "", Weight = 0,
                      StyleSheet = "QLabel{color:#8a8a92;font-size:11px;}" },
        },
    })
    local itm = win:GetItems()

    for _, f in ipairs(M.FONTS) do itm.fontCmb:AddItem(f) end
    for _, t in ipairs(M.TRANSITIONS) do itm.trInCmb:AddItem(t); itm.trOutCmb:AddItem(t) end
    itm.trInCmb.CurrentIndex = 1    -- Scribble
    itm.trOutCmb.CurrentIndex = 1

    local function tip(id, text) pcall(function() itm[id].ToolTip = text end) end
    tip("targetLbl", "Which CScribble stack the button will write to.\nSelect any CScribble node to update its stack; otherwise a new one is created.")
    tip("refreshBtn", "Re-detect the target stack from the current selection")
    tip("boilSld", "How hard the strokes wobble")
    tip("boilStep", "The drawing 'redraws' once every N frames (2–4 feels hand-animated)")
    tip("wordChk", "Words appear one after another (your word-by-word macro's follower setup)")
    tip("wordDelay", "Frames of stagger between words")
    tip("sfEdit", "Frame where the text (and transition in) starts — empty = playhead")
    tip("efEdit", "Frame where the transition out ends — empty = SF + 90")
    tip("newBtn", "Always build a fresh node stack, even if one is selected")
    tip("fontCustom", "Overrides the dropdown — type any installed font name")

    local function setStatus(fmt, ...)
        local ok, msg = pcall(string.format, fmt, ...)
        itm.statusLbl.Text = ok and msg or tostring(fmt)
    end

    local function refreshChips()
        itm.styMarker.StyleSheet = chipCSS(STYLE_HEX.marker, S.styleId == "marker")
        itm.stySketch.StyleSheet = chipCSS(STYLE_HEX.sketch, S.styleId == "sketch")
        itm.stySmooth.StyleSheet = chipCSS(STYLE_HEX.smooth, S.styleId == "smooth")
    end

    local function refreshTarget()
        local s = M.CurrentStack()
        itm.targetLbl.Text = s and ("stack " .. s.idx) or "new stack"
        return s
    end

    local function styleDefaults(id)
        local st = styleById and styleById(id) or nil
        for _, x in ipairs(M.STYLES) do if x.id == id then st = x end end
        if not st then return end
        -- put the style's font into the combo if present
        for i, f in ipairs(M.FONTS) do
            if f == st.font then itm.fontCmb.CurrentIndex = i - 1 end
        end
    end

    win.On.styMarker.Clicked = function() S.styleId = "marker"; refreshChips(); styleDefaults("marker") end
    win.On.stySketch.Clicked = function() S.styleId = "sketch"; refreshChips(); styleDefaults("sketch") end
    win.On.stySmooth.Clicked = function() S.styleId = "smooth"; refreshChips(); styleDefaults("smooth") end

    for i, hex in ipairs(SWATCHES) do
        win.On["sw" .. i].Clicked = function()
            S.colorHex = hex
            itm.colorEdit.Text = hex
        end
    end

    win.On.refreshBtn.Clicked = function() refreshTarget(); setStatus("Target re-detected.") end
    win.On.sfStamp.Clicked = function()
        pcall(function() itm.sfEdit.Text = tostring(math.floor(comp.CurrentTime)) end)
    end
    win.On.efStamp.Clicked = function()
        pcall(function() itm.efEdit.Text = tostring(math.floor(comp.CurrentTime)) end)
    end

    local function gatherOpts()
        local sf = tonumber(itm.sfEdit.Text)
        if not sf then pcall(function() sf = math.floor(comp.CurrentTime) end) end
        sf = sf or 0
        local ef = tonumber(itm.efEdit.Text) or (sf + 90)
        local font = itm.fontCustom.Text
        if font == "" then font = itm.fontCmb.CurrentText end
        local hex = itm.colorEdit.Text
        if M.HexToRGB(hex) then S.colorHex = hex end
        local txt = itm.textEdit.PlainText
        if not txt or txt == "" then txt = "SCRIBBLE" end
        return {
            text = txt, styleId = S.styleId, font = font,
            size = itm.sizeSld.Value / 100,
            colorHex = S.colorHex,
            boilAmount = itm.boilSld.Value / 100,
            boilStep = itm.boilStep.Value,
            trIn = itm.trInCmb.CurrentText, trOut = itm.trOutCmb.CurrentText,
            dIn = itm.dInSpin.Value, dOut = itm.dOutSpin.Value,
            sf = sf, ef = ef,
            wordByWord = itm.wordChk.Checked,
            wordDelay = itm.wordDelay.Value,
        }
    end

    local function doApply(forceNew)
        local s = (not forceNew) and M.CurrentStack() or nil
        local created = false
        if not s then
            s = M.CreateStack()
            created = true
        end
        if not s then setStatus("Could not create the node stack — see engine.log."); return end
        local ok, msg = M.Apply(s, gatherOpts())
        itm.targetLbl.Text = "stack " .. (s.idx or "?")
        if ok then
            setStatus("%s stack %s ✓  (%s)", created and "Created" or "Updated", s.idx or "?",
                      msg ~= "" and msg or "static look")
        else
            setStatus("Apply failed: %s", tostring(msg))
        end
    end

    win.On.scribbleBtn.Clicked = function() doApply(false) end
    win.On.newBtn.Clicked = function() doApply(true) end
    win.On.CapitalScribbleWin.Close = function() disp:ExitLoop() end

    refreshChips()
    refreshTarget()
    setStatus("Select footage-free spot in the Fusion flow and hit SCRIBBLE ⚡ — merge CScribbleGlow over your shot.")

    win:Show()
    disp:RunLoop()
    win:Hide()
end

------------------------------------------------------------------
-- 8. Entry point (library mode = loaded by the Diag)
------------------------------------------------------------------
if not CAPITALSCRIBBLE_LIBRARY_MODE then
    M.Log("CapitalScribble %s starting.", M.VERSION)
    M.RunUI()
end

return M
