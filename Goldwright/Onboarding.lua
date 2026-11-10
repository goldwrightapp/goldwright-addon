-- First run and data status (requirements ONB-1..3). The welcome panel appears once per account,
-- a few seconds after the first login with Goldwright, never in combat. /gw welcome shows it again.
-- ONB-2 / ONB-3 (missing, wrong-region or stale pack) are one chat line at login (Core.lua) and the
-- Sell panel's status banner.
local _, GW = ...

local WELCOME_VERSION = 1
local GREY = { 0.70, 0.70, 0.72 }
local welcome

local function fs(parent, template, justify)
  local f = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
  if justify then f:SetJustifyH(justify) end
  return f
end

-- One line on the data pack for the welcome panel, from what LoadPack found.
function GW.PackStatusText()
  local h = GW.house or GW.DetectHouse()
  local pack = GW.Pack()
  if pack then
    local days = GW.PackAgeDays()
    if days and days > GW.STALE_DAYS then
      return string.format("Goldwright Data: %s · installed, but %d days old: update it in your add-on manager", h.region, math.floor(days)), false
    end
    return string.format("Goldwright Data: %s · installed, snapshot %s", h.region, GW.Age(pack.snapshotAt)), true
  end
  if GW.packStatus == "disabled" then
    return string.format("Installed but disabled: enable GoldwrightData_%s in the AddOns list", h.packKey), false
  end
  if GW.packStatus == "schema" then
    return "Your data pack doesn't match this version: update both in your add-on manager", false
  end
  if GW.otherPacks and #GW.otherPacks > 0 then
    return string.format("You have %s, but you're playing on %s %s: install Goldwright Data: %s", table.concat(GW.otherPacks, ", "), h.region, h.ruleset, h.region), false
  end
  return string.format("Not installed: search \"Goldwright Data\" in your add-on manager and install %s", h.region), false
end

local function row(y, label)
  local l = fs(welcome, "GameFontHighlight", "LEFT"); l:SetPoint("TOPLEFT", 24, y); l:SetText(label)
  l:SetTextColor(GREY[1], GREY[2], GREY[3])
  local r = fs(welcome, "GameFontHighlight", "LEFT"); r:SetPoint("TOPLEFT", 120, y); r:SetWidth(360)
  return r
end

local function create()
  welcome = CreateFrame("Frame", "GoldwrightWelcome", UIParent, "ButtonFrameTemplate")
  welcome:SetSize(500, 400)
  welcome:SetPoint("CENTER", 0, 60)
  welcome:SetFrameStrata("DIALOG")
  if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(welcome) end
  if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(welcome) end
  if welcome.Inset then welcome.Inset:Hide() end
  if welcome.SetTitle then welcome:SetTitle("Goldwright") elseif welcome.TitleText then welcome.TitleText:SetText("Goldwright") end
  welcome:SetMovable(true)
  welcome:EnableMouse(true)
  welcome:RegisterForDrag("LeftButton")
  welcome:SetScript("OnDragStart", welcome.StartMoving)
  welcome:SetScript("OnDragStop", welcome.StopMovingOrSizing)
  GW.CloseOnEscape(welcome)

  local t = fs(welcome, "GameFontNormalLarge", "LEFT"); t:SetPoint("TOPLEFT", 24, -36); t:SetText("Welcome to Goldwright")
  t:SetTextColor(GW.GOLD[1], GW.GOLD[2], GW.GOLD[3])
  local tag = fs(welcome, "GameFontHighlight", "LEFT"); tag:SetPoint("TOPLEFT", 24, -58); tag:SetText("Auction house prices for WoW Forever.")

  welcome.region = row(-90, "Region")
  welcome.ruleset = row(-110, "Ruleset")
  welcome.faction = row(-130, "Faction")
  welcome.pack = row(-150, "Data pack")

  local tips = {
    "Hover any item: market value, the real cheapest price and other houses are in the tooltip.",
    "At the auction house, Goldwright opens beside it: sell through your bags one click at a time, and cancel undercut auctions.",
    "Run a full scan (Scan tab) now and then: your prices become current to the minute. Right-click the Goldwright button for settings.",
  }
  local y = -196
  for i, text in ipairs(tips) do
    local n = fs(welcome, "GameFontNormalLarge", "CENTER"); n:SetPoint("TOPLEFT", 24, y); n:SetText(tostring(i))
    n:SetTextColor(GW.GOLD[1], GW.GOLD[2], GW.GOLD[3])
    local f = fs(welcome, "GameFontHighlight", "LEFT"); f:SetPoint("TOPLEFT", 52, y); f:SetWidth(420); f:SetText(text)
    y = y - math.max(36, f:GetStringHeight() + 14)
  end

  local ok = CreateFrame("Button", nil, welcome, "UIPanelButtonTemplate")
  ok:SetSize(120, 26); ok:SetPoint("BOTTOMRIGHT", -20, 18); ok:SetText("Got It")
  ok:SetScript("OnClick", function() welcome:Hide() end)
  local settings = CreateFrame("Button", nil, welcome, "UIPanelButtonTemplate")
  settings:SetSize(120, 26); settings:SetPoint("RIGHT", ok, "LEFT", -8, 0); settings:SetText("Settings")
  settings:SetScript("OnClick", function()
    welcome:Hide()
    GW.OpenSettings()
  end)
  welcome:Hide() -- new frames start shown; hide before the OnHide below can mark it as seen
  welcome:SetScript("OnHide", function()
    GoldwrightDB.welcomed = WELCOME_VERSION
  end)
end

function GW.ShowWelcome()
  if InCombatLockdown and InCombatLockdown() then
    GW.Print("The welcome opens after combat.")
    return
  end
  if not welcome then create() end
  local h = GW.house or GW.DetectHouse()
  welcome.region:SetText(h.region)
  welcome.ruleset:SetText(string.format("%s  |cff9a9aa2(from realm “%s”%s)|r", h.ruleset, h.realm,
    GoldwrightDB.rulesetOverride and ", set by you" or ""))
  welcome.faction:SetText(GW.HOUSE_NAMES[h.side])
  local text, good = GW.PackStatusText()
  welcome.pack:SetText(text)
  local c = good and { 1, 1, 1 } or GW.SIGNAL_ORANGE
  welcome.pack:SetTextColor(c[1], c[2], c[3])
  welcome:Show()
end

-- First login: wait a few seconds for the world to settle, and for combat to end.
local waiter = CreateFrame("Frame")
waiter:SetScript("OnEvent", function(self)
  self:UnregisterAllEvents()
  C_Timer.After(2, GW.ShowWelcome)
end)

GW.OnLogin(function()
  if (GoldwrightDB.welcomed or 0) >= WELCOME_VERSION then return end
  C_Timer.After(4, function()
    if InCombatLockdown and InCombatLockdown() then
      waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
    else
      GW.ShowWelcome()
    end
  end)
end)
