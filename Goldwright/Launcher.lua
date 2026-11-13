--- Launcher (LCH): an entry in the game's add-on compartment (the .toc's AddonCompartmentFunc) and an
--- optional minimap button. Click: a small popup with the house, data pack age and quick links.
--- Right-click: settings. No always-visible frames besides the button.
local _, GW = ...
local L = GW.L

local UI = GW.UI
local fs, setColor = UI.FontString, UI.SetColor
local GREY = UI.GREY
local popup, minimapButton

---------------------------------------------------------------------------
-- popup
---------------------------------------------------------------------------
--- A label / value row in the popup: grey label on the left, value on the right.
---@param y number top offset
---@param label string
---@return table value font string for the value
local function pairRow(y, label)
  local l = fs(popup, "GameFontHighlightSmall", "LEFT")
  l:SetPoint("TOPLEFT", 14, y)
  l:SetText(label)
  setColor(l, GREY)
  local r = fs(popup, "GameFontHighlightSmall", "RIGHT")
  r:SetPoint("TOPRIGHT", -14, y)
  return r
end

--- Fills the popup: house, data pack age (orange when stale or missing), searches this minute, the
--- last full scan and its cooldown. "Open Goldwright" is enabled only at the auction house.
local function refreshPopup()
  local h = GW.House()
  local pack = GW.Pack()
  popup.house:SetText(string.format("%s · %s · %s", h.region, h.ruleset, GW.HOUSE_NAMES[h.side]))
  if pack then
    local days = GW.PackAgeDays()
    popup.pack:SetText(
      (days and days > GW.STALE_DAYS and "|cfff59e4b" or "")
        .. string.format(L["snapshot %s"], GW.Age(pack.snapshotAt))
        .. "|r"
    )
  else
    popup.pack:SetText("|cfff59e4b" .. L["not installed"] .. "|r")
  end
  popup.searches:SetText(string.format(L["%d / %d this minute"], GW.SearchesThisMinute(), GW.SEARCH_LIMIT))
  local left = GW.ScanCooldownLeft and GW.ScanCooldownLeft() or 0
  local last = GW.LastScanText and GW.LastScanText()
  last = last or L["none yet"]
  if left > 0 then
    popup.scan:SetText(string.format(L["%s · next in %s"], last, GW.ClockText(left)))
  else
    popup.scan:SetText(string.format(L["%s · available"], last))
  end
  popup.open:SetEnabled(GW.AuctionHouseOpen and GW.AuctionHouseOpen() and true or false)
end

--- Builds the launcher popup (hidden).
local function createPopup()
  popup = CreateFrame("Frame", "GoldwrightLauncher", UIParent, "BackdropTemplate")
  popup:SetSize(250, 200)
  popup:SetFrameStrata("DIALOG")
  popup:SetClampedToScreen(true)
  if popup.SetBackdrop then
    popup:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    popup:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
  end
  popup:EnableMouse(true)
  GW.CloseOnEscape(popup)

  local title = fs(popup, "GameFontNormal", "LEFT")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("Goldwright")
  setColor(title, GW.GOLD)
  local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
  close:SetSize(24, 24)
  close:SetPoint("TOPRIGHT", -2, -2)

  popup.house = pairRow(-36, L["House"])
  popup.pack = pairRow(-54, L["Data pack"])
  popup.searches = pairRow(-72, L["Searches"])
  local scan = pairRow(-90, L["Full scan"])
  popup.scan = scan

  --- A full-width button in the popup at top offset y.
  ---@param text string
  ---@param y number
  ---@param onClick function
  ---@return table button
  local function linkButton(text, y, onClick)
    local b = UI.Button(popup, text, 222, 22, onClick)
    b:SetPoint("TOPLEFT", 14, y)
    return b
  end
  popup.open = linkButton(L["Open Goldwright"], -112, function()
    popup:Hide()
    GW.OpenTab("sell")
  end)
  popup.open:SetMotionScriptsWhileDisabled(true)
  popup.open:SetScript("OnEnter", function(self)
    if self:IsEnabled() then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["Open the auction house first"])
    GameTooltip:Show()
  end)
  popup.open:SetScript("OnLeave", function() GameTooltip:Hide() end)
  linkButton(L["Settings"], -138, function()
    popup:Hide()
    GW.OpenSettings()
  end)

  -- The game can't open web links: a selectable box to copy the address from.
  local web = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
  web:SetSize(210, 20)
  web:SetPoint("TOPLEFT", 20, -168)
  web:SetAutoFocus(false)
  web:SetText(GW.WEBSITE)
  web:SetScript("OnTextChanged", function(self, user)
    if user then self:SetText(GW.WEBSITE) end
  end)
  web:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  web:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  local hint = fs(popup, "GameFontDisableSmall", "LEFT")
  hint:SetPoint("TOPLEFT", web, "BOTTOMLEFT", -6, -2)
  hint:SetText(L["Click, then Ctrl+C to copy"])
  popup:SetHeight(214)
  popup:Hide()
end

--- Shows or hides the launcher popup. When shown, it opens next to `anchor`, on the side facing the
--- middle of the screen.
---@param anchor? table frame the popup attaches to (default: near the top right of the screen)
function GW.ToggleLauncher(anchor)
  if not popup then createPopup() end
  if popup:IsShown() then
    popup:Hide()
    return
  end
  popup:ClearAllPoints()
  if anchor and anchor.GetCenter and anchor:GetCenter() then
    local x, y = anchor:GetCenter()
    local right = x > UIParent:GetWidth() / 2
    local top = y > UIParent:GetHeight() / 2
    popup:SetPoint(
      (top and "TOP" or "BOTTOM") .. (right and "RIGHT" or "LEFT"),
      anchor,
      (top and "BOTTOM" or "TOP") .. (right and "LEFT" or "RIGHT")
    )
  else
    popup:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -220, -60)
  end
  refreshPopup()
  popup:Show()
end

---------------------------------------------------------------------------
-- add-on compartment (.toc: AddonCompartmentFunc / OnEnter / OnLeave)
---------------------------------------------------------------------------
--- The launcher tooltip (name, tagline, click hints).
---@param owner table frame to anchor the tooltip to
local function showButtonTooltip(owner)
  GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
  GameTooltip:SetText("Goldwright", GW.GOLD[1], GW.GOLD[2], GW.GOLD[3])
  GameTooltip:AddLine(L["Auction house prices for WoW Forever"], 1, 1, 1)
  GameTooltip:AddLine(L["Click: status and links · Right-click: settings"], GREY[1], GREY[2], GREY[3])
  GameTooltip:Show()
end

--- Add-on compartment click (global, named in the .toc): right-click opens settings, any other
--- click toggles the popup.
---@param buttonName string mouse button
---@param menuButton? table the compartment entry clicked
function Goldwright_OnAddonCompartmentClick(_, buttonName, menuButton)
  if buttonName == "RightButton" then
    GW.OpenSettings()
  else
    GW.ToggleLauncher(menuButton or AddonCompartmentFrame)
  end
end
--- Add-on compartment hover (global, named in the .toc): shows the launcher tooltip.
---@param menuButton? table the compartment entry
function Goldwright_OnAddonCompartmentEnter(_, menuButton) showButtonTooltip(menuButton or AddonCompartmentFrame) end
--- Add-on compartment hover end (global, named in the .toc).
function Goldwright_OnAddonCompartmentLeave() GameTooltip:Hide() end

---------------------------------------------------------------------------
-- minimap button (hidden by default when the compartment exists)
---------------------------------------------------------------------------
--- True when the game has the add-on compartment.
local function hasCompartment() return AddonCompartmentFrame ~= nil end

--- Whether the minimap button should show. The "auto" setting shows it only without a compartment.
---@return boolean
function GW.MinimapShown()
  local v = GW.Opt("minimap")
  if v == "auto" then return not hasCompartment() end
  return v and true or false
end

--- Places the minimap button on the minimap's edge at the saved angle (default 200 degrees).
local function placeButton()
  local angle = math.rad(GoldwrightDB.minimapAngle or 200)
  local r = (Minimap:GetWidth() / 2) + 6
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

--- Builds the minimap button: click toggles the popup, right-click opens settings, dragging moves
--- it around the minimap and saves the angle in GoldwrightDB.minimapAngle.
local function createMinimapButton()
  local b = CreateFrame("Button", "GoldwrightMinimapButton", Minimap)
  minimapButton = b
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", 7, -5)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(18, 18)
  icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexture(GW.ICON)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  b:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      GW.OpenSettings()
    else
      GW.ToggleLauncher(self)
    end
  end)
  b:SetScript("OnEnter", function(self) showButtonTooltip(self) end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local px, py = GetCursorPosition()
      local s = Minimap:GetEffectiveScale()
      GoldwrightDB.minimapAngle = math.deg((math.atan2 or math.atan)(py / s - my, px / s - mx))
      placeButton()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  placeButton()
end

--- Shows or hides the minimap button and saves the choice (building the button when needed).
---@param show boolean
function GW.SetMinimapShown(show)
  GW.SetOpt("minimap", show and true or false)
  if show and not minimapButton and Minimap then createMinimapButton() end
  if minimapButton then minimapButton:SetShown(show and true or false) end
  if not show and not hasCompartment() then GW.Print(L["Minimap button hidden. Bring it back with /gw minimap."]) end
end

GW.OnLogin(function()
  if GW.MinimapShown() and Minimap then createMinimapButton() end
end)
