-- Settings (requirements SET): a page in the game's Options > AddOns > Goldwright, also reached
-- with /gw config, the launcher and the panel's Settings button. Built from plain UI templates
-- (check buttons, buttons, edit boxes) so it doesn't depend on the newer settings widgets.
-- Every change applies at once (GW.SetOpt -> GW.ApplyOptions), no /reload.
local _, GW = ...

local frame = CreateFrame("Frame", "GoldwrightSettingsFrame")
frame.name = "Goldwright"
local category
local controls = {}
local built = false

local GREY = { 0.70, 0.70, 0.72 }

local function fs(parent, template, justify)
  local f = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
  if justify then f:SetJustifyH(justify) end
  return f
end

---------------------------------------------------------------------------
-- widgets: each registers a refresh function in `controls`
---------------------------------------------------------------------------
local Y -- cursor while building
local content

local function heading(text)
  Y = Y - 14
  local h = fs(content, "GameFontNormal", "LEFT")
  h:SetPoint("TOPLEFT", 16, Y)
  h:SetText(text)
  Y = Y - 22
end

local function note(text, x)
  local f = fs(content, "GameFontDisableSmall", "LEFT")
  f:SetPoint("TOPLEFT", x or 40, Y + 4)
  f:SetWidth(560)
  f:SetText(text)
  Y = Y - (f:GetStringHeight() > 14 and 30 or 18)
  return f
end

local function check(label, key, tip)
  local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("TOPLEFT", 16, Y)
  local text = cb.Text or cb.text
  if not text then
    text = fs(cb, "GameFontHighlight", "LEFT")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  end
  text:SetText(label)
  cb:SetScript("OnClick", function(self) GW.SetOpt(key, self:GetChecked() and true or false) end)
  if tip then
    cb:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(tip, 1, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  table.insert(controls, function() cb:SetChecked(GW.Opt(key) and true or false) end)
  Y = Y - 26
  return cb
end

-- A row of buttons acting as radio buttons.
local function choice(label, key, options, onChange)
  local l = fs(content, "GameFontHighlight", "LEFT")
  l:SetPoint("TOPLEFT", 20, Y - 4)
  l:SetText(label)
  local buttons = {}
  local x = 220
  for _, o in ipairs(options) do
    local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    b:SetText(o[2])
    b:SetSize(math.max(64, (b:GetFontString() and b:GetFontString():GetStringWidth() or 40) + 24), 22)
    b:SetPoint("TOPLEFT", x, Y)
    x = x + b:GetWidth() + 4
    b:SetScript("OnClick", function()
      GW.SetOpt(key, o[1])
      if onChange then onChange(o[1]) end
    end)
    buttons[#buttons + 1] = { b = b, value = o[1] }
  end
  table.insert(controls, function()
    for _, x2 in ipairs(buttons) do
      if GW.Opt(key) == x2.value then x2.b:LockHighlight() else x2.b:UnlockHighlight() end
    end
  end)
  Y = Y - 28
end

-- A whole-number box with a unit after it.
local function number(label, key, min, max, unit, tip)
  local l = fs(content, "GameFontHighlight", "LEFT")
  l:SetPoint("TOPLEFT", 20, Y - 4)
  l:SetText(label)
  local box = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
  box:SetSize(44, 22)
  box:SetPoint("TOPLEFT", 226, Y)
  box:SetAutoFocus(false)
  box:SetNumeric(true)
  box:SetMaxLetters(3)
  local u = fs(content, "GameFontHighlight", "LEFT")
  u:SetPoint("LEFT", box, "RIGHT", 6, 0)
  u:SetText(unit or "")
  local function commit(self)
    local v = tonumber(self:GetText())
    if v then GW.SetOpt(key, math.max(min, math.min(max, math.floor(v)))) end
    self:SetText(tostring(GW.Opt(key)))
    self:ClearFocus()
  end
  box:SetScript("OnEnterPressed", commit)
  box:SetScript("OnEditFocusLost", commit)
  box:SetScript("OnEscapePressed", function(self) self:SetText(tostring(GW.Opt(key))); self:ClearFocus() end)
  if tip then
    local t = fs(content, "GameFontDisableSmall", "LEFT")
    t:SetPoint("LEFT", u, "RIGHT", 10, 0)
    t:SetText(tip)
  end
  table.insert(controls, function() if not box:HasFocus() then box:SetText(tostring(GW.Opt(key))) end end)
  Y = Y - 28
end

local function button(label, x, width, onClick)
  local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  b:SetSize(width or 140, 22)
  b:SetPoint("TOPLEFT", x or 20, Y)
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

local function refresh()
  if not built then return end
  for _, fn in ipairs(controls) do fn() end
end

---------------------------------------------------------------------------
-- the page
---------------------------------------------------------------------------
StaticPopupDialogs.GOLDWRIGHT_RESET = {
  text = "Reset all Goldwright settings to their defaults?\nYour hidden items and remembered durations stay.",
  button1 = YES or "Yes",
  button2 = NO or "No",
  OnAccept = function()
    GW.ResetOptions()
    GW.Print("Settings reset to defaults.")
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

local function build()
  built = true
  -- Blizzard's Options window is see-through (~70% in Forever); a dark layer behind our page keeps
  -- a little of that but makes the text readable over a busy world (Mischa, 2026-11-10).
  local shade = frame:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints()
  shade:SetColorTexture(0.03, 0.03, 0.04, 0.6)
  local scroll
  local ok = pcall(function() scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate") end)
  if not ok or not scroll then
    scroll = CreateFrame("ScrollFrame", nil, frame, "ScrollFrameTemplate")
  end
  scroll:SetPoint("TOPLEFT", 0, -8)
  scroll:SetPoint("BOTTOMRIGHT", -28, 8)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(620, 1200)
  scroll:SetScrollChild(content)
  Y = -4

  local title = fs(content, "GameFontNormalLarge", "LEFT")
  title:SetPoint("TOPLEFT", 16, Y)
  title:SetText("Goldwright")
  local tag = fs(content, "GameFontHighlightSmall", "LEFT")
  tag:SetPoint("LEFT", title, "RIGHT", 10, 0)
  tag:SetText("Auction house prices for WoW Forever")
  Y = Y - 24

  heading("Tooltip")
  check("Market value", "ttMarket", "Depth-based market value at your auction house.")
  check("Now (cheapest real listing)", "ttNow", "The cheapest listing after skipping likely bait.")
  check("Normal price and buy / sell signal", "ttNormal", "The 7-day normal price, and a line when the cheapest listing is well above or below it.")
  check("Trend and sell rate", "ttTrend", "7-day trend against 30 days, and estimated units sold per day.")
  check("Other houses", "ttOthers")
  check("Blackwater pays more", "ttBetter", "Only shown with real depth and proven buyers at the other house.")
  check("Vendor comparison", "ttVendor")
  check("\"No auction data yet\" for unknown items", "ttNoData")
  choice("Expanded view key", "expandKey", { { "SHIFT", "Shift" }, { "CTRL", "Ctrl" }, { "ALT", "Alt" }, { "NONE", "None" } })
  choice("Money", "money", { { "coins", "Coin Icons" }, { "letters", "1g 23s 47c" } })

  heading("Signals")
  number("Tooltip signal outside", "signalPct", 1, 90, "% of normal", "default 15")
  number("Better-house hint from", "betterPct", 1, 500, "% more, after cuts", "default 20")

  heading("Selling")
  choice("Undercut by", "undercut", { { "1c", "1 Copper" }, { "match", "Match" }, { "pct", "Percent" } })
  number("Percent under", "undercutPct", 1, 50, "%", "used with Percent")
  number("Warn when below", "belowPct", 1, 99, "% of normal", "default 70")
  number("Note when above", "abovePct", 101, 999, "% of normal", "default 150")
  choice("Default duration", "duration", { { 3, "24 Hours" }, { 2, "8 Hours" }, { 1, "2 Hours" } })
  check("Open Goldwright with the auction house", "autoShow")
  note("Key bindings for Post, Cancel next undercut and opening Goldwright: Options › Keybindings › AddOns › Goldwright.", 20)

  heading("Bait detection")
  check("Skip thin cheap listings when pricing", "bait", "Sellers price against the first real listing; buyers see bait as a deal.")
  number("Thin = at most", "baitShare", 1, 20, "% of units listed", "default 1")
  number("...and more than", "baitGap", 5, 90, "% below the 5% depth price", "default 30")
  note("Applies to live listings in game. Data pack prices use the server's fixed rule (1%, 30%).", 20)

  heading("Launcher")
  local mm = check("Minimap button", "minimap", "Also in the add-on menu next to the minimap, when the game has one.")
  mm:SetScript("OnClick", function(self) if GW.SetMinimapShown then GW.SetMinimapShown(self:GetChecked() and true or false) end end)
  table.insert(controls, function() mm:SetChecked(GW.MinimapShown and GW.MinimapShown() or false) end)

  heading("Data")
  local house = fs(content, "GameFontHighlight", "LEFT"); house:SetPoint("TOPLEFT", 20, Y); house:SetWidth(580)
  Y = Y - 20
  local packLine = fs(content, "GameFontHighlightSmall", "LEFT"); packLine:SetPoint("TOPLEFT", 20, Y); packLine:SetWidth(580)
  Y = Y - 26
  table.insert(controls, function()
    local h = GW.house or GW.DetectHouse()
    local override = GoldwrightDB and GoldwrightDB.rulesetOverride
    house:SetText(string.format("%s · %s · %s  |cff9a9aa2(realm “%s”%s)|r", h.region, h.ruleset, GW.HOUSE_NAMES[h.side], h.realm,
      override and ", ruleset set by you" or ""))
    local pack = GW.Pack()
    if pack then
      packLine:SetText(string.format("Goldwright Data: %s %s · snapshot %s", h.packKey, pack.version or "", GW.Age(pack.snapshotAt)))
      packLine:SetTextColor(GREY[1], GREY[2], GREY[3])
    else
      packLine:SetText("No data pack loaded for " .. h.region .. " " .. h.ruleset .. ". Install Goldwright Data: " .. h.region .. " in your add-on manager.")
      packLine:SetTextColor(GW.SIGNAL_ORANGE[1], GW.SIGNAL_ORANGE[2], GW.SIGNAL_ORANGE[3])
    end
  end)

  -- Ruleset override (if detection from the realm name is wrong): stored outside opt so it survives Reset.
  local l = fs(content, "GameFontHighlight", "LEFT"); l:SetPoint("TOPLEFT", 20, Y - 4); l:SetText("Ruleset")
  local rules = { { nil, "Detect" }, { "Normal", "Normal" }, { "PvP", "PvP" }, { "Roleplay", "RP" }, { "Roleplay PvP", "RP-PvP" } }
  local rb = {}
  local x = 220
  for _, o in ipairs(rules) do
    local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    b:SetText(o[2]); b:SetSize(64, 22); b:SetPoint("TOPLEFT", x, Y)
    x = x + 68
    b:SetScript("OnClick", function()
      GoldwrightDB.rulesetOverride = o[1]
      local pack = GW.ReloadPack()
      local h = GW.house
      if pack then GW.Print("Using the %s %s data pack.", h.region, h.ruleset) else GW.PrintPackProblem() end
      GW.ApplyOptions()
    end)
    rb[#rb + 1] = { b = b, value = o[1] }
  end
  table.insert(controls, function()
    local cur = GoldwrightDB and GoldwrightDB.rulesetOverride
    for _, x2 in ipairs(rb) do
      if x2.value == cur then x2.b:LockHighlight() else x2.b:UnlockHighlight() end
    end
  end)
  Y = Y - 32

  button("Forget My Scans", 20, 160, function()
    if GoldwrightDB then GoldwrightDB.searchLog = nil end
    GoldwrightScans = { lastDataAt = GoldwrightScans and GoldwrightScans.lastDataAt } -- the server's 15 minutes still apply
    GW.ResetCache()
    GW.ApplyOptions()
    GW.Print("Your local search history is cleared.")
  end)
  button("Show Welcome Again", 186, 180, function() if GW.ShowWelcome then GW.ShowWelcome() end end)
  Y = Y - 36

  heading("Reset")
  button("Reset All Settings", 20, 160, function() StaticPopup_Show("GOLDWRIGHT_RESET") end)
  Y = Y - 40

  content:SetHeight(-Y + 20)
end

frame:SetScript("OnShow", function()
  if not built then build() end
  refresh()
end)
GW.OnOptionsChanged(function() if frame:IsShown() then refresh() end end)

GW.OnLogin(function()
  if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(frame, "Goldwright")
    Settings.RegisterAddOnCategory(category)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(frame)
  end
end)

function GW.OpenSettings()
  if InCombatLockdown and InCombatLockdown() then
    GW.Print("Settings open after combat.")
    return
  end
  if category and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(category:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(frame)
    InterfaceOptionsFrame_OpenToCategory(frame) -- the old panel needs two calls the first time
  else
    GW.Print("Couldn't open the settings page; use /gw commands instead.")
  end
end
