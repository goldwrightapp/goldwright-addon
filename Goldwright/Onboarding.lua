--- First run and data status (ONB-1..3). The welcome panel appears once per account, a few seconds
--- after the first login with Goldwright, never in combat; /gw welcome shows it again. ONB-2 / ONB-3
--- (missing, wrong-region or stale pack) are one chat line at login (Core.lua) and the Sell panel's
--- status banner.
local _, GW = ...
local L = GW.L

local WELCOME_VERSION = 1 -- raise to show the welcome again to everyone who saw an older one
local UI = GW.UI
local fs, setColor = UI.FontString, UI.SetColor
local GREY = UI.GREY
local welcome
local body -- the welcome's content, drawn over its dark inset

--- One line on the data pack for the welcome panel, from what LoadPack found: installed (and how
--- old), disabled, wrong schema, packs for another region only, or not installed.
---@return string text
---@return boolean good true when a current pack is loaded
function GW.PackStatusText()
  local h = GW.House()
  local pack = GW.Pack()
  if pack then
    local days = GW.PackAgeDays()
    if days and days > GW.STALE_DAYS then
      return string.format(
        L["Goldwright Data: %s · installed, but %s old: update it in your add-on manager"],
        h.region,
        GW.Plural(math.floor(days), "%d day", "%d days")
      ),
        false
    end
    return string.format(L["Goldwright Data: %s · installed, snapshot %s"], h.region, GW.Age(pack.snapshotAt)), true
  end
  if GW.packStatus == "disabled" then
    return string.format(L["Installed but disabled: enable GoldwrightData_%s in the AddOns list"], h.packKey), false
  end
  if GW.packStatus == "schema" then
    return L["Your data pack doesn't match this version: update both in your add-on manager"], false
  end
  if GW.otherPacks and #GW.otherPacks > 0 then
    return string.format(
      L["You have %s, but you're playing on %s %s: install Goldwright Data: %s"],
      table.concat(GW.otherPacks, ", "),
      h.region,
      h.ruleset,
      h.region
    ),
      false
  end
  return string.format(L['Not installed: search "Goldwright Data" in your add-on manager and install %s'], h.region),
    false
end

--- A label / value row in the welcome panel.
---@param y number top offset
---@param label string
---@return table value font string for the value
local function row(y, label)
  local l = fs(body, "GameFontHighlight", "LEFT")
  l:SetPoint("TOPLEFT", 24, y)
  l:SetText(label)
  setColor(l, GREY)
  local r = fs(body, "GameFontHighlight", "LEFT")
  r:SetPoint("TOPLEFT", 120, y)
  r:SetWidth(360)
  return r
end

--- Builds the welcome panel (hidden). Hiding it marks the welcome as seen.
local function create()
  welcome = UI.Window("GoldwrightWelcome", 500, 400, { title = "Goldwright", strata = "DIALOG", movable = true })
  welcome:SetPoint("CENTER", 0, 60)
  -- Keep the dark inset the other windows draw on, so the welcome is as opaque as they are. The
  -- content is a child of the inset (or it would draw under it), sized to the whole window so the
  -- offsets below are from the window's corner.
  if welcome.Inset then
    welcome.Inset:ClearAllPoints()
    welcome.Inset:SetPoint("TOPLEFT", 8, -26)
    welcome.Inset:SetPoint("BOTTOMRIGHT", -8, 8)
  end
  body = CreateFrame("Frame", nil, welcome.Inset or welcome)
  body:SetAllPoints(welcome)

  local t = fs(body, "GameFontNormalLarge", "LEFT")
  t:SetPoint("TOPLEFT", 24, -36)
  t:SetText(L["Welcome to Goldwright"])
  setColor(t, GW.GOLD)
  local tag = fs(body, "GameFontHighlight", "LEFT")
  tag:SetPoint("TOPLEFT", 24, -58)
  tag:SetText(L["Auction house prices for WoW Forever."])

  welcome.region = row(-90, L["Region"])
  welcome.ruleset = row(-110, L["Ruleset"])
  welcome.faction = row(-130, L["Faction"])
  welcome.pack = row(-150, L["Data pack"])

  local tips = {
    L["Hover any item: market value, the real cheapest price and other houses are in the tooltip."],
    L["At the auction house, Goldwright opens beside it: sell through your bags one click at a time, and cancel undercut auctions."],
    L["Run a full scan (Scan tab) now and then: your prices become current to the minute. Right-click the Goldwright button for settings."],
  }
  local y = -196
  for i, text in ipairs(tips) do
    local n = fs(body, "GameFontNormalLarge", "CENTER")
    n:SetPoint("TOPLEFT", 24, y)
    n:SetText(tostring(i))
    setColor(n, GW.GOLD)
    local f = fs(body, "GameFontHighlight", "LEFT")
    f:SetPoint("TOPLEFT", 52, y)
    f:SetWidth(420)
    f:SetText(text)
    y = y - math.max(36, f:GetStringHeight() + 14)
  end

  local ok = UI.Button(body, L["Got It"], 120, 26, function() welcome:Hide() end)
  ok:SetPoint("BOTTOMRIGHT", -20, 18)
  local settings = UI.Button(body, L["Settings"], 120, 26, function()
    welcome:Hide()
    GW.OpenSettings()
  end)
  settings:SetPoint("RIGHT", ok, "LEFT", -8, 0)
  welcome:Hide() -- new frames start shown; hide before the OnHide below can mark it as seen
  welcome:SetScript("OnHide", function() GoldwrightDB.welcomed = WELCOME_VERSION end)
end

--- Shows the welcome panel with the detected house and the data pack status (not in combat).
function GW.ShowWelcome()
  if InCombatLockdown and InCombatLockdown() then
    GW.Print(L["The welcome opens after combat."])
    return
  end
  if not welcome then create() end
  local h = GW.House()
  welcome.region:SetText(h.region)
  local fmt = GoldwrightDB.rulesetOverride and L["%s  |cff9a9aa2(from realm “%s”, set by you)|r"]
    or L["%s  |cff9a9aa2(from realm “%s”)|r"]
  welcome.ruleset:SetText(string.format(fmt, h.ruleset, h.realm))
  welcome.faction:SetText(GW.HOUSE_NAMES[h.side])
  local text, good = GW.PackStatusText()
  welcome.pack:SetText(text)
  setColor(welcome.pack, good and UI.WHITE or GW.SIGNAL_ORANGE)
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
