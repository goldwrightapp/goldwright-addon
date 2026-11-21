--- Goldwright's looks. Every frame Goldwright makes goes through UI.Skin (UI.Window and the UI.lua
--- factories call it); this file decides whether and how it is styled, and holds the colours of
--- Goldwright's own two looks (TOKENS, read through UI.Tokens) for what Goldwright draws itself:
--- cards, captions, chips, rows, bars and charts.
---
--- * Blizzard flat (the default, setting `look` = "blizzard"): the game's own window, buttons and
---   boxes, unchanged; Goldwright's cards and text in warm, dark colours that sit in it.
--- * Goldwright dark (`look` = "dark"): one more entry in LOOKS. Our own frames only: the window,
---   buttons and boxes Goldwright made are drawn flat (the template's textures faded out, flat
---   colours and 1-pixel borders in their place). Never a Blizzard frame.
---
--- ElvUI and EllesmereUI restyle Blizzard's own windows, never an add-on's: each add-on opts in by
--- handing its frames to the UI add-on's skin functions. With either of them, its look wins over
--- Goldwright's, and Goldwright's own drawing takes the dark colours.
---
--- One look at a time, the first that applies (LOOKS):
--- * EllesmereUI: through its public skinning API (EllesmereUI.RegisterSkin, SKINNING_API.md,
---   apiVersion 4). It calls us back at login with its primitives, only while the player has its
---   third-party skinning on for Goldwright (on by default, per add-on in its options), and keeps
---   the frames in sync with the player's theme from then on.
--- * ElvUI: through the functions ElvUI uses for Blizzard's frames
---   (ElvUI/Game/Shared/Modules/Skins/Skins.lua, 16.01), when its Blizzard skins are on and our
---   "Match ElvUI's look" setting is on.
--- * Goldwright dark: when the player chose it in Settings (and neither of the above applies).
--- Another look is one more entry in LOOKS: no panel needs to change.
---
--- In the Blizzard look nothing here styles a widget. Every call is wrapped in pcall: a change in
--- the other add-on can leave a frame with the Blizzard look, never break it. A frame made before
--- the look is known (the Welcome window at login) is styled once it is. Switching a look's setting
--- takes effect after /reload.
local _, GW = ...
local UI = GW.UI

---------------------------------------------------------------------------
-- Goldwright's colours, per look ({r, g, b} or {r, g, b, a})
---------------------------------------------------------------------------
--- The colours one look draws Goldwright's own parts with.
---@class GoldwrightTokens
---@field name string "blizzard" or "dark"
---@field window number[] window background (dark look only)
---@field card number[] card background
---@field cardBorder number[] card border
---@field line number[] dividers inside a card
---@field rowLine number[] the faint line between list rows
---@field caption number[] card captions
---@field label number[] field labels and the labels over big numbers
---@field gold number[] the brand colour: chart line, selected row bar, selected tab
---@field text number[] main text
---@field muted number[] secondary text
---@field faint number[] the quietest text (footers, the status bar)
---@field selected number[] background of the selected list row
---@field hover number[] background of a row under the mouse
---@field chips table<string, number[][]> chip kind -> { background, text }
---@field barTrack number[] quantity bar background
---@field barFill number[] quantity bar
---@field warnBg number[] warning box background
---@field warnText number[] warning box text
---@field warnBorder number[] warning box border
---@field chartBg number[] plot background
---@field chartRef number[] the dashed reference line in a chart
---@field captionMark boolean captions start with a small gold square
---@field button? table dark look: flat button colours
local TOKENS = {
  blizzard = {
    name = "blizzard",
    window = { 0.07, 0.07, 0.08, 0.97 },
    card = { 0.047, 0.047, 0.055, 0.50 }, -- half see-through: the window's rock texture shows, as on the game's own windows
    cardBorder = { 0.231, 0.220, 0.200, 1 },
    line = { 0.173, 0.165, 0.149, 1 },
    rowLine = { 0.102, 0.098, 0.090, 1 },
    caption = { 1, 0.82, 0 },
    label = { 1, 0.82, 0 },
    gold = { 1, 0.82, 0 },
    text = { 1, 1, 1 },
    muted = { 0.722, 0.706, 0.667 },
    faint = { 0.545, 0.529, 0.494 },
    selected = { 1, 0.82, 0, 0.10 },
    hover = { 1, 1, 1, 0.05 },
    chips = {
      blue = { { 0.082, 0.125, 0.227, 1 }, { 0.561, 0.690, 1 } },
      orange = { { 0.227, 0.141, 0.090, 1 }, { 0.941, 0.627, 0.376 } },
      grey = { { 0.133, 0.122, 0.106, 1 }, { 0.722, 0.706, 0.667 } },
    },
    barTrack = { 0.133, 0.125, 0.110, 1 },
    barFill = { 0.420, 0.353, 0.200, 1 },
    warnBg = { 0.227, 0.141, 0.090, 1 },
    warnText = { 0.965, 0.780, 0.624 },
    warnBorder = { 0.353, 0.227, 0.133, 1 },
    chartBg = { 1, 1, 1, 0.02 },
    chartRef = { 0.42, 0.44, 0.50, 1 },
    captionMark = false,
  },
  dark = {
    name = "dark",
    window = { 0.082, 0.086, 0.106, 0.98 },
    card = { 0.102, 0.110, 0.133, 1 },
    cardBorder = { 0.165, 0.176, 0.208, 1 },
    line = { 0.165, 0.176, 0.208, 1 },
    rowLine = { 0.122, 0.129, 0.157, 1 },
    caption = { 0.604, 0.612, 0.647 },
    label = { 0.604, 0.612, 0.647 },
    gold = { 0.878, 0.675, 0.227 },
    text = { 0.925, 0.910, 0.875 },
    muted = { 0.604, 0.612, 0.647 },
    faint = { 0.392, 0.408, 0.451 },
    selected = { 0.137, 0.145, 0.176, 1 },
    hover = { 1, 1, 1, 0.04 },
    chips = {
      blue = { { 0.110, 0.145, 0.251, 1 }, { 0.561, 0.690, 1 } },
      orange = { { 0.227, 0.149, 0.094, 1 }, { 0.922, 0.604, 0.361 } },
      grey = { { 0.149, 0.157, 0.188, 1 }, { 0.604, 0.612, 0.647 } },
    },
    barTrack = { 0.169, 0.180, 0.216, 1 },
    barFill = { 0.290, 0.314, 0.408, 1 },
    warnBg = { 0.227, 0.149, 0.094, 1 },
    warnText = { 0.949, 0.753, 0.604 },
    warnBorder = { 0.227, 0.149, 0.094, 1 },
    chartBg = { 1, 1, 1, 0.015 },
    chartRef = { 0.30, 0.32, 0.38, 1 },
    captionMark = true,
    button = {
      bg = { 0.141, 0.149, 0.180, 1 },
      border = { 0.290, 0.306, 0.361, 1 },
      hover = { 1, 1, 1, 0.06 },
      text = { 0.925, 0.910, 0.875 },
      disabled = { 0.392, 0.408, 0.451 },
      onBg = { 0.200, 0.212, 0.255, 1 },
      onBorder = { 0.541, 0.416, 0.149, 1 },
      input = { 0.067, 0.071, 0.090, 1 },
      primary = { 0.878, 0.675, 0.227, 1 },
      primaryText = { 0.102, 0.078, 0.024 },
    },
  },
}
UI.TOKENS = TOKENS

---@class GoldwrightLook
---@field name string "ellesmere", "elvui" or "dark" (UI.LookName)
---@field find fun(): table|false|nil the look's state when it should be used, false when it is
---  absent or switched off, nil when it isn't known yet
---@field style table<string, fun(state: table, frame: table)> how each kind of widget is styled
---@field selected fun(state: table, button: table, on: boolean) shows a tab or toggle as selected

---------------------------------------------------------------------------
-- EllesmereUI
---------------------------------------------------------------------------
local euiSkin -- the primitives EllesmereUI handed us at login
local loginDone = false -- a frame after PLAYER_LOGIN: EllesmereUI has called back by then, or won't

if type(EllesmereUI) == "table" and type(EllesmereUI.RegisterSkin) == "function" then
  pcall(EllesmereUI.RegisterSkin, "Goldwright", function(S) euiSkin = S end)
end

---@type GoldwrightLook
local ellesmere = {
  name = "ellesmere",
  style = {
    window = function(S, f)
      S.Shell(f)
      if f.Inset then S.Inset(f.Inset) end
      if f.CloseButton then S.CloseButton(f.CloseButton) end
    end,
    frame = function(S, f) S.Panel(f) end,
    button = function(S, f)
      S.Button(f)
      -- Its buttons' labels are white, grey while disabled; S.Button leaves the label alone.
      if S.StateButtonLabel then S.StateButtonLabel(f) end
    end,
    tab = function(S, f) S.Tab(f) end,
    editbox = function(S, f) S.EditBox(f) end,
    close = function(S, f) S.CloseButton(f) end,
    check = function(S, f) S.Checkbox(f) end,
    scrollbar = function(S, f) S.ScrollBar(f) end,
  },
}

function ellesmere.find()
  if type(EllesmereUI) ~= "table" or type(EllesmereUI.RegisterSkin) ~= "function" then return false end
  if euiSkin then return (not euiSkin.IsEnabled or euiSkin.IsEnabled()) and euiSkin or false end
  if loginDone then return false end -- the player turned EllesmereUI's skinning off for Goldwright
  return nil
end

--- Tabs: EllesmereUI's own selected tab (an accent underline, apiVersion 2). Other buttons that
--- stay selected (the Sell strategies): the label in the player's accent colour.
function ellesmere.selected(S, b, on)
  if b.gwKind == "tab" and S.SetTabSelection then
    S.SetTabSelection(b, on)
    return
  end
  local label = b.GetFontString and b:GetFontString()
  if not label then return end
  if not b.gwLabelColor then b.gwLabelColor = { label:GetTextColor() } end
  if on and S.GetAccentColor then
    label:SetTextColor(S.GetAccentColor())
  else
    local c = b.gwLabelColor
    label:SetTextColor(c[1], c[2], c[3])
  end
end

---------------------------------------------------------------------------
-- ElvUI
---------------------------------------------------------------------------
--- One of ElvUI's skin functions (S:HandleButton and so on).
local function elv(name)
  return function(skins, f) skins[name](skins, f) end
end

---@type GoldwrightLook
local elvui = {
  name = "elvui",
  style = {
    window = elv("HandlePortraitFrame"), -- ButtonFrameTemplate windows (inset and close button too)
    frame = elv("HandleFrame"),
    button = elv("HandleButton"),
    tab = elv("HandleButton"), -- our tabs are buttons; ElvUI's HandleTab is for Blizzard's tab templates
    editbox = elv("HandleEditBox"),
    close = elv("HandleCloseButton"),
    check = elv("HandleCheckBox"),
    scrollbar = elv("HandleScrollBar"),
  },
}

function elvui.find()
  local E = type(ElvUI) == "table" and ElvUI[1]
  if not E then return false end
  if not E.Initialized then return nil end -- set at the end of E:Initialize (General/Core.lua)
  if GW.Opt("elvSkin") == false then return false end
  local s = E.private and E.private.skins and E.private.skins.blizzard
  if not (s and s.enable) then return false end
  local ok, skins = pcall(E.GetModule, E, "Skins", true)
  return ok and type(skins) == "table" and skins or false
end

--- ElvUI's button style has no highlight texture (its hover only changes the border), so the
--- selected button's background takes ElvUI's accent colour.
function elvui.selected(_, b, on)
  if not b.SetBackdropColor then return end
  local media = ElvUI[1].media
  local c = media and (on and media.rgbvaluecolor or media.backdropcolor)
  if type(c) == "table" then pcall(b.SetBackdropColor, b, c.r or c[1], c.g or c[2], c.b or c[3], on and 0.45 or 1) end
end

---------------------------------------------------------------------------
-- Goldwright dark
---------------------------------------------------------------------------
--- Fades one texture out (template art we draw over); anything else is left alone.
local function fade(t)
  if type(t) == "table" and t.SetAlpha then t:SetAlpha(0) end
end

--- Fades a widget template's own art: its Left / Middle / Right pieces (by key or by global name)
--- and its normal, pushed, disabled and highlight textures. Text and other parts stay.
---@param f table button or edit box
local function fadeParts(f)
  local name = f.GetName and f:GetName()
  for _, k in ipairs({ "Left", "Middle", "Right", "Mid" }) do
    fade(f[k])
    if name then fade(_G[name .. k]) end
  end
  for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }) do
    if type(f[get]) == "function" then fade(f[get](f)) end
  end
end

--- Fades every texture of a template frame and of its children, except the frames in `keep`. Run
--- right after the frame is made, so everything it holds then is template art.
---@param f table
---@param keep table<table, boolean>
local function fadeTree(f, keep)
  if f.GetRegions then
    for _, r in ipairs({ f:GetRegions() }) do
      if type(r) == "table" and r.GetObjectType and r:GetObjectType() == "Texture" then fade(r) end
    end
  end
  if f.GetChildren then
    for _, c in ipairs({ f:GetChildren() }) do
      if type(c) == "table" and not keep[c] then fadeTree(c, keep) end
    end
  end
end

--- A font object for flat buttons in one colour (button states would reset a plain text colour).
local fonts = {}
local function flatFont(key, color, base)
  if fonts[key] then return fonts[key] end
  base = base or GameFontHighlight
  if not (CreateFont and base) then return base end
  local f = CreateFont("GoldwrightFlat" .. key)
  f:SetFontObject(base)
  f:SetTextColor(color[1], color[2], color[3])
  -- dark text on the gold primary button: the game font's black drop shadow smudges it
  if key == "dark" and f.SetShadowOffset then f:SetShadowOffset(0, 0) end
  fonts[key] = f
  return f
end

--- Sets a flat button's label colour for all its states. Tabs ("tab*" keys) and the primary button
--- ("dark") use the normal size; other buttons the small one, so two-line labels fit.
---@param b table button
---@param key string font key ("tabText", "tabMuted", "text", "gold", "dark", "off")
---@param color number[]
local function labelFont(b, key, color)
  local base = GameFontHighlightSmall
  if key == "dark" then
    base = GameFontNormal
  elseif key:find("^tab") then
    base = GameFontHighlight
  end
  local f = flatFont(key, color, base)
  if not f or not b.SetNormalFontObject then return end
  b:SetNormalFontObject(f)
  if b.SetHighlightFontObject then b:SetHighlightFontObject(f) end
  if b.SetDisabledFontObject then
    b:SetDisabledFontObject(flatFont("off", TOKENS.dark.button.disabled, GameFontHighlightSmall))
  end
end

--- A hover background on the button's highlight layer.
local function hover(b, color)
  if b.gwHover or not b.CreateTexture then return end
  local t = b:CreateTexture(nil, "HIGHLIGHT")
  t:SetAllPoints()
  t:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
  b.gwHover = t
end

--- The gold line under a selected tab or toggle.
local function underline(b, gold)
  if b.gwUnder or not b.CreateTexture then return b.gwUnder end
  local t = b:CreateTexture(nil, "OVERLAY")
  t:SetPoint("BOTTOMLEFT", 1, 0)
  t:SetPoint("BOTTOMRIGHT", -1, 0)
  t:SetHeight(2)
  t:SetColorTexture(gold[1], gold[2], gold[3], 1)
  t:Hide()
  b.gwUnder = t
  return t
end

local NONE = { 0, 0, 0, 0 }

---@type GoldwrightLook
local dark = {
  name = "dark",
  style = {
    window = function(T, f)
      local keep = {}
      if f.CloseButton then keep[f.CloseButton] = true end
      fadeTree(f, keep)
      if type(f.NineSlice) == "table" and f.NineSlice.Hide then f.NineSlice:Hide() end
      UI.Flat(f, T.window, T.cardBorder)
      if f.CloseButton then UI.Skin("close", f.CloseButton) end
      local title = f.TitleText or (type(f.TitleContainer) == "table" and f.TitleContainer.TitleText)
      if type(title) == "table" and title.SetTextColor then title:SetTextColor(T.gold[1], T.gold[2], T.gold[3]) end
    end,
    frame = function(T, f) UI.Flat(f, T.card, T.cardBorder) end,
    button = function(T, b)
      local c = T.button
      fadeParts(b)
      if b.gwPrimary then
        UI.Flat(b, c.primary, c.primary)
        hover(b, { 1, 1, 1, 0.12 })
        labelFont(b, "dark", c.primaryText)
      else
        UI.Flat(b, c.bg, c.border)
        hover(b, c.hover)
        labelFont(b, "text", c.text)
      end
    end,
    -- a toggle (2h / 8h / 24h, 7d / 30d) is boxed like a button, so it reads as one
    toggle = function(T, b)
      local c = T.button
      fadeParts(b)
      UI.Flat(b, c.bg, c.border)
      hover(b, c.hover)
      labelFont(b, "text", c.text)
    end,
    tab = function(T, b)
      fadeParts(b)
      UI.Flat(b, NONE, nil)
      hover(b, T.button.hover)
      underline(b, T.gold)
      labelFont(b, "tabMuted", T.muted)
    end,
    editbox = function(T, b)
      fadeParts(b)
      UI.Flat(b, T.button.input, T.button.border, -5, 0)
    end,
    close = function(T, b)
      fadeParts(b)
      b:SetSize(22, 22)
      UI.Flat(b, NONE, T.button.border)
      hover(b, T.button.hover)
      if not b.gwX and b.CreateFontString then
        b.gwX = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        b.gwX:SetPoint("CENTER", 0, 0)
        b.gwX:SetText("×")
        b.gwX:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
      end
    end,
  },
}

function dark.find()
  if GW.Opt("look") ~= "dark" then return false end
  return TOKENS.dark
end

--- Tabs and toggles: a quiet background, the gold line under them and the label in the main text
--- colour. Other buttons that stay selected (the Sell strategies): a gold border and gold label.
function dark.selected(T, b, on)
  local c = T.button
  if b.gwKind == "tab" then
    UI.Flat(b, on and c.onBg or NONE, nil)
    if b.gwUnder then b.gwUnder:SetShown(on) end
    labelFont(b, on and "tabText" or "tabMuted", on and c.text or T.muted)
  elseif not b.gwPrimary then
    UI.Flat(b, on and c.onBg or c.bg, on and c.onBorder or c.border)
    underline(b, T.gold):SetShown(on)
    labelFont(b, on and "gold" or "text", on and T.gold or c.text)
  end
end

---------------------------------------------------------------------------
-- The look in use
---------------------------------------------------------------------------
--- The looks Goldwright knows, first match wins.
local LOOKS = { ellesmere, elvui, dark }

local decided, active, state = false, nil, nil
local pending = {} -- { kind, frame } made before the look was known

--- Decides the look once every look has answered. A look that doesn't know yet keeps it open.
---@return boolean decided
local function decide()
  if decided then return true end
  for _, look in ipairs(LOOKS) do
    local s = look.find()
    if s == nil then return false end
    if s then
      active, state = look, s
      break
    end
  end
  decided = true
  return true
end

--- Styles one frame in the active look; returns whether it did.
local function apply(kind, frame)
  -- A primary button (Post) is a button in every look but Goldwright dark; a toggle (2h / 8h / 24h)
  -- is a tab in every look but Goldwright dark, which boxes it like a button.
  local fn = active
    and (active.style[kind] or (kind == "primary" and active.style.button) or (kind == "toggle" and active.style.tab))
  if fn and pcall(fn, state, frame) then
    frame.gwSkinned, frame.gwKind = true, kind
    return true
  end
  return false
end

--- Styles the frames made before the look was known.
local function flush()
  local queued = pending
  pending = {}
  for _, p in ipairs(queued) do
    if not p[2].gwSkinned then apply(p[1], p[2]) end
  end
end

--- Whether Goldwright's frames are styled by a look in this session (another add-on's, or
--- Goldwright dark); false in the Blizzard look.
---@return boolean
function UI.Skinned() return decide() and active ~= nil end

--- The look in use: "ellesmere", "elvui", "dark" or "blizzard". Before the look is decided (the
--- first moments after login), the player's choice.
---@return string
function UI.LookName()
  if decide() then return active and active.name or "blizzard" end
  return GW.Opt("look") == "dark" and "dark" or "blizzard"
end

--- An {r, g, b, a} colour from one of ElvUI's media colours ({r=, g=, b=} or {r, g, b}); nil if it
--- isn't one.
---@param c any
---@param a number|nil alpha (default the colour's own, else 1)
---@return number[]|nil
local function elvColor(c, a)
  if type(c) ~= "table" then return nil end
  local r, g, b = c.r or c[1], c.g or c[2], c.b or c[3]
  if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return nil end
  return { r, g, b, a or c.a or c[4] or 1 }
end

local elvTokens -- built once, the first time ElvUI's look asks for colours
--- The dark colours with ElvUI's own where it has them: the card background and border, the
--- window and the caption / label accent. Chart colours keep their meaning (gold = price, blue =
--- bought, green = profit zone) and stay as they are.
---@return GoldwrightTokens
local function elvuiTokens()
  if elvTokens then return elvTokens end
  local E = type(ElvUI) == "table" and ElvUI[1]
  local m = type(E) == "table" and E.media
  if type(m) ~= "table" then return TOKENS.dark end
  local t = {}
  for k, v in pairs(TOKENS.dark) do
    t[k] = v
  end
  t.name = "elvui"
  t.card = elvColor(m.backdropcolor, 1) or t.card
  t.window = elvColor(m.backdropfadecolor) or t.window
  t.cardBorder = elvColor(m.bordercolor, 1) or t.cardBorder
  local accent = elvColor(m.rgbvaluecolor, 1)
  if accent then
    t.caption, t.label = accent, accent
  end
  elvTokens = t
  return t
end

--- The colours Goldwright draws its own parts with: the Blizzard look's; with ElvUI the dark ones
--- in ElvUI's own card, border and accent colours; else the dark ones (also with EllesmereUI).
---@return GoldwrightTokens
function UI.Tokens()
  local look = UI.LookName()
  if look == "blizzard" then return TOKENS.blizzard end
  if look == "elvui" then return elvuiTokens() end
  return TOKENS.dark
end

--- Styles one frame in the active look; without one, does nothing.
---@param kind string "window", "frame", "button", "primary", "tab", "toggle", "editbox", "close", "check" or "scrollbar"
---@param frame any the frame (anything else is returned as it is)
---@return any frame the same frame
function UI.Skin(kind, frame)
  if type(frame) ~= "table" or frame.gwSkinned then return frame end
  frame.gwKind = kind
  if not decide() then
    table.insert(pending, { kind, frame })
    return frame
  end
  if #pending > 0 then flush() end
  apply(kind, frame)
  return frame
end

--- Styles the three boxes of a MoneyInputFrameTemplate (global name + Gold / Silver / Copper).
---@param name string the money frame's global name
function UI.SkinMoney(name)
  for _, part in ipairs({ "Gold", "Silver", "Copper" }) do
    UI.Skin("editbox", _G[name .. part])
  end
end

--- Shows a tab or toggle button as the selected one (or not): its highlight stays lit, and a
--- styled button also gets the look's own selected state.
---@param b table button
---@param on boolean selected
function UI.SetSelected(b, on)
  if on then
    b:LockHighlight()
  else
    b:UnlockHighlight()
  end
  if b.gwSetSelected then b.gwSetSelected(on) end -- a Blizzard-look window tab (UI.WindowTab)
  if active and b.gwSkinned then pcall(active.selected, state, b, on) end
end

-- A frame after login: EllesmereUI has called back by then (or won't), ElvUI has initialised.
-- Style what was made before.
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function(self)
  self:UnregisterAllEvents()
  C_Timer.After(0, function()
    loginDone = true
    if decide() then flush() end
  end)
end)
