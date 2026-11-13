--- Settings page (SET) in the game's Options > AddOns > Goldwright, also opened by /gw config, the
--- launcher and the panel's Settings button. Built from plain UI templates (check buttons, buttons,
--- edit boxes), not the newer settings widgets. Every change applies at once (GW.SetOpt ->
--- GW.ApplyOptions), without /reload.
local _, GW = ...
local L = GW.L

local frame = CreateFrame("Frame", "GoldwrightSettingsFrame")
frame.name = "Goldwright"
local category -- the Settings category (newer clients only)
local controls = {} -- refresh functions, one per control: each sets the control from the saved options
local built = false

local UI = GW.UI
local fs, setColor = UI.FontString, UI.SetColor
local GREY = UI.GREY

---------------------------------------------------------------------------
-- widgets: each registers a refresh function in `controls`
---------------------------------------------------------------------------
local Y -- cursor while building
local content

--- A section heading at the cursor.
---@param text string
local function heading(text)
  Y = Y - 14
  local h = fs(content, "GameFontNormal", "LEFT")
  h:SetPoint("TOPLEFT", 16, Y)
  h:SetText(text)
  Y = Y - 22
end

--- A small grey note at the cursor (two lines of space when it wraps).
---@param text string
---@param x? number left offset (default 40)
---@return table fontString
local function note(text, x)
  local f = fs(content, "GameFontDisableSmall", "LEFT")
  f:SetPoint("TOPLEFT", x or 40, Y + 4)
  f:SetWidth(560)
  f:SetText(text)
  Y = Y - (f:GetStringHeight() > 14 and 30 or 18)
  return f
end

--- A check button bound to a boolean option.
---@param label string
---@param key string option key (GW.Opt / GW.SetOpt)
---@param tip? string tooltip text
---@return table checkButton
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

--- A row of buttons acting as radio buttons for one option; the button of the current value stays
--- highlighted.
---@param label string
---@param key string option key
---@param options table[] { value, buttonText } pairs
---@param onChange? fun(value: any) called after the option is set
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
      if GW.Opt(key) == x2.value then
        x2.b:LockHighlight()
      else
        x2.b:UnlockHighlight()
      end
    end
  end)
  Y = Y - 28
end

--- A whole-number box (up to 3 digits) with a unit after it. Enter or leaving the box saves the
--- value clamped to min..max; Escape restores the saved value.
---@param label string
---@param key string option key
---@param min number
---@param max number
---@param unit? string text after the box
---@param tip? string grey hint after the unit
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
  box:SetScript("OnEscapePressed", function(self)
    self:SetText(tostring(GW.Opt(key)))
    self:ClearFocus()
  end)
  if tip then
    local t = fs(content, "GameFontDisableSmall", "LEFT")
    t:SetPoint("LEFT", u, "RIGHT", 10, 0)
    t:SetText(tip)
  end
  table.insert(controls, function()
    if not box:HasFocus() then box:SetText(tostring(GW.Opt(key))) end
  end)
  Y = Y - 28
end

--- A button at the cursor (the caller moves the cursor).
---@param label string
---@param x? number left offset (default 20)
---@param width? number (default 140)
---@param onClick function
---@return table button
local function button(label, x, width, onClick)
  local b = UI.Button(content, label, width or 140, 22, onClick)
  b:SetPoint("TOPLEFT", x or 20, Y)
  return b
end

--- Sets every control from the saved options (once the page is built).
local function refresh()
  if not built then return end
  for _, fn in ipairs(controls) do
    fn()
  end
end

---------------------------------------------------------------------------
-- the page
---------------------------------------------------------------------------
StaticPopupDialogs.GOLDWRIGHT_RESET = {
  text = L["Reset all Goldwright settings to their defaults?\nYour hidden items and remembered durations stay."],
  button1 = YES or "Yes",
  button2 = NO or "No",
  OnAccept = function()
    GW.ResetOptions()
    GW.Print(L["Settings reset to defaults."])
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

--- Builds the page on first show: a scroll frame with every section, top to bottom.
local function build()
  built = true
  -- Blizzard's Options window is see-through (about 70% in Forever). A dark layer behind the page
  -- keeps a little of that but makes the text readable over a busy world (decided 2026-11-10).
  local shade = frame:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints()
  shade:SetColorTexture(0.03, 0.03, 0.04, 0.6)
  local scroll
  local ok = pcall(function() scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate") end)
  if not ok or not scroll then scroll = CreateFrame("ScrollFrame", nil, frame, "ScrollFrameTemplate") end
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
  tag:SetText(L["Auction house prices for WoW Forever"])
  Y = Y - 24

  heading(L["Tooltip"])
  check(L["Market value"], "ttMarket", L["Depth-based market value at your auction house."])
  check(L["Now (cheapest real listing)"], "ttNow", L["The cheapest listing after skipping likely bait."])
  check(
    L["Normal price and buy / sell signal"],
    "ttNormal",
    L["The 7-day normal price, and a line when the cheapest listing is well above or below it."]
  )
  check(
    L["Trend and sell rate"],
    "ttTrend",
    L["7-day trend against 30 days, and units sold per day (proven sales, else an estimate)."]
  )
  check(L["Other houses"], "ttOthers")
  check(L["Blackwater pays more"], "ttBetter", L["Only shown with real depth and proven buyers at the other house."])
  check(L["Vendor comparison"], "ttVendor")
  check(string.format(L['"%s" for unknown items'], L["No auction data yet"]), "ttNoData")
  choice(
    L["Expanded view key"],
    "expandKey",
    { { "SHIFT", L["Shift"] }, { "CTRL", L["Ctrl"] }, { "ALT", L["Alt"] }, { "NONE", L["None"] } }
  )
  choice(L["Money"], "money", { { "coins", L["Coin Icons"] }, { "letters", L["1g 23s 47c"] } })

  heading(L["Signals"])
  number(L["Tooltip signal outside"], "signalPct", 1, 90, L["% of normal"], string.format(L["default %d"], 15))
  number(L["Better-house hint from"], "betterPct", 1, 500, L["% more, after cuts"], string.format(L["default %d"], 20))

  heading(L["Selling"])
  choice(L["Undercut by"], "undercut", { { "1c", L["1 Copper"] }, { "match", L["Match"] }, { "pct", L["Percent"] } })
  number(L["Percent under"], "undercutPct", 1, 50, L["%"], L["used with Percent"])
  number(L["Warn when below"], "belowPct", 1, 99, L["% of normal"], string.format(L["default %d"], 70))
  number(L["Note when above"], "abovePct", 101, 999, L["% of normal"], string.format(L["default %d"], 150))
  choice(L["Default duration"], "duration", { { 3, L["24 Hours"] }, { 2, L["8 Hours"] }, { 1, L["2 Hours"] } })
  check(L["Open Goldwright with the auction house"], "autoShow")
  note(
    L["Key bindings for Post, Cancel next undercut and opening Goldwright: Options › Keybindings › AddOns › Goldwright."],
    20
  )

  heading(L["Bait detection"])
  check(
    L["Skip thin cheap listings when pricing"],
    "bait",
    L["Sellers price against the first real listing; buyers see bait as a deal."]
  )
  number(L["Thin = at most"], "baitShare", 1, 20, L["% of units listed"], string.format(L["default %d"], 1))
  number(L["...and more than"], "baitGap", 5, 90, L["% below the 5% depth price"], string.format(L["default %d"], 30))
  note(L["Applies to live listings in game. Data pack prices use the server's fixed rule (1%, 30%)."], 20)

  heading(L["Launcher"])
  local mm =
    check(L["Minimap button"], "minimap", L["Also in the add-on menu next to the minimap, when the game has one."])
  mm:SetScript("OnClick", function(self)
    if GW.SetMinimapShown then GW.SetMinimapShown(self:GetChecked() and true or false) end
  end)
  table.insert(controls, function() mm:SetChecked(GW.MinimapShown and GW.MinimapShown() or false) end)

  heading(L["Data"])
  local house = fs(content, "GameFontHighlight", "LEFT")
  house:SetPoint("TOPLEFT", 20, Y)
  house:SetWidth(580)
  Y = Y - 20
  local packLine = fs(content, "GameFontHighlightSmall", "LEFT")
  packLine:SetPoint("TOPLEFT", 20, Y)
  packLine:SetWidth(580)
  Y = Y - 26
  table.insert(controls, function()
    local h = GW.House()
    local override = GoldwrightDB and GoldwrightDB.rulesetOverride
    local fmt = override and L["%s · %s · %s  |cff9a9aa2(realm “%s”, ruleset set by you)|r"]
      or L["%s · %s · %s  |cff9a9aa2(realm “%s”)|r"]
    house:SetText(string.format(fmt, h.region, h.ruleset, GW.HOUSE_NAMES[h.side], h.realm))
    local pack = GW.Pack()
    if pack then
      packLine:SetText(
        string.format(
          L["Goldwright Data: %s %s · snapshot %s"],
          h.packKey,
          pack.version or "",
          GW.Age(pack.snapshotAt)
        )
      )
      setColor(packLine, GREY)
    else
      packLine:SetText(
        string.format(
          L["No data pack loaded for %s %s. Install Goldwright Data: %s in your add-on manager."],
          h.region,
          h.ruleset,
          h.region
        )
      )
      setColor(packLine, GW.SIGNAL_ORANGE)
    end
  end)

  -- Ruleset override (if detection from the realm name is wrong): stored outside opt so it survives Reset.
  local l = fs(content, "GameFontHighlight", "LEFT")
  l:SetPoint("TOPLEFT", 20, Y - 4)
  l:SetText(L["Ruleset"])
  local rules = {
    { nil, L["Detect"] },
    { "Normal", L["Normal"] },
    { "PvP", L["PvP"] },
    { "Roleplay", L["RP"] },
    { "Roleplay PvP", L["RP-PvP"] },
  }
  local rb = {}
  local x = 220
  for _, o in ipairs(rules) do
    local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    b:SetText(o[2])
    b:SetSize(64, 22)
    b:SetPoint("TOPLEFT", x, Y)
    x = x + 68
    b:SetScript("OnClick", function()
      GoldwrightDB.rulesetOverride = o[1]
      local pack = GW.ReloadPack()
      local h = GW.house
      if pack then
        GW.Print(L["Using the %s %s data pack."], h.region, h.ruleset)
      else
        GW.PrintPackProblem()
      end
      GW.ApplyOptions()
    end)
    rb[#rb + 1] = { b = b, value = o[1] }
  end
  table.insert(controls, function()
    local cur = GoldwrightDB and GoldwrightDB.rulesetOverride
    for _, x2 in ipairs(rb) do
      if x2.value == cur then
        x2.b:LockHighlight()
      else
        x2.b:UnlockHighlight()
      end
    end
  end)
  Y = Y - 32

  button(L["Forget My Scans"], 20, 160, function()
    if GoldwrightDB then GoldwrightDB.searchLog = nil end
    GoldwrightScans = { lastDataAt = GoldwrightScans and GoldwrightScans.lastDataAt } -- the server's 15 minutes still apply
    GW.ResetCache()
    GW.ApplyOptions()
    GW.Print(L["Your local search history is cleared."])
  end)
  button(L["Show Welcome Again"], 186, 180, function()
    if GW.ShowWelcome then GW.ShowWelcome() end
  end)
  button(L["Report a Bug"], 372, 130, function()
    if GW.ShowBugReport then GW.ShowBugReport() end
  end)
  Y = Y - 36

  heading(L["Reset"])
  button(L["Reset All Settings"], 20, 160, function() StaticPopup_Show("GOLDWRIGHT_RESET") end)
  Y = Y - 40

  content:SetHeight(-Y + 20)
end

frame:SetScript("OnShow", function()
  if not built then build() end
  refresh()
end)
GW.OnOptionsChanged(function()
  if frame:IsShown() then refresh() end
end)

GW.OnLogin(function()
  if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(frame, "Goldwright")
    Settings.RegisterAddOnCategory(category)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(frame)
  end
end)

--- Opens the Goldwright settings page (not in combat).
function GW.OpenSettings()
  if InCombatLockdown and InCombatLockdown() then
    GW.Print(L["Settings open after combat."])
    return
  end
  if category and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(category:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(frame)
    InterfaceOptionsFrame_OpenToCategory(frame) -- the old panel needs two calls the first time
  else
    GW.Print(L["Couldn't open the settings page; use /gw commands instead."])
  end
end
