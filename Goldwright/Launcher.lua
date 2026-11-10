-- Launcher (requirements LCH): an entry in the game's add-on compartment (the .toc's
-- AddonCompartmentFunc) and an optional minimap button. Click: a small popup with the house, data
-- pack age and quick links. Right-click: settings. No always-visible frames besides the button.
local _, GW = ...

local GREY = { 0.70, 0.70, 0.72 }
local popup, minimapButton

local function fs(parent, template, justify)
  local f = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
  if justify then f:SetJustifyH(justify) end
  return f
end

---------------------------------------------------------------------------
-- popup
---------------------------------------------------------------------------
local function pairRow(y, label)
  local l = fs(popup, "GameFontHighlightSmall", "LEFT"); l:SetPoint("TOPLEFT", 14, y); l:SetText(label)
  l:SetTextColor(GREY[1], GREY[2], GREY[3])
  local r = fs(popup, "GameFontHighlightSmall", "RIGHT"); r:SetPoint("TOPRIGHT", -14, y)
  return r
end

local function refreshPopup()
  local h = GW.house or GW.DetectHouse()
  local pack = GW.Pack()
  popup.house:SetText(string.format("%s · %s · %s", h.region, h.ruleset, GW.HOUSE_NAMES[h.side]))
  if pack then
    local days = GW.PackAgeDays()
    popup.pack:SetText((days and days > GW.STALE_DAYS and "|cfff59e4b" or "") .. "snapshot " .. GW.Age(pack.snapshotAt) .. "|r")
  else
    popup.pack:SetText("|cfff59e4bnot installed|r")
  end
  popup.searches:SetText(string.format("%d / %d this minute", GW.SearchesThisMinute(), GW.SEARCH_LIMIT))
  local left = GW.ScanCooldownLeft and GW.ScanCooldownLeft() or 0
  local last = GW.LastScanText and GW.LastScanText()
  popup.scan:SetText((last or "none yet") .. (left > 0 and (" · next in " .. GW.ClockText(left)) or " · available"))
  popup.open:SetEnabled(GW.AuctionHouseOpen and GW.AuctionHouseOpen() and true or false)
end

local function createPopup()
  popup = CreateFrame("Frame", "GoldwrightLauncher", UIParent, "BackdropTemplate")
  popup:SetSize(250, 200)
  popup:SetFrameStrata("DIALOG")
  popup:SetClampedToScreen(true)
  if popup.SetBackdrop then
    popup:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    popup:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
  end
  popup:EnableMouse(true)
  GW.CloseOnEscape(popup)

  local title = fs(popup, "GameFontNormal", "LEFT"); title:SetPoint("TOPLEFT", 14, -12); title:SetText("Goldwright")
  title:SetTextColor(GW.GOLD[1], GW.GOLD[2], GW.GOLD[3])
  local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
  close:SetSize(24, 24); close:SetPoint("TOPRIGHT", -2, -2)

  popup.house = pairRow(-36, "House")
  popup.pack = pairRow(-54, "Data pack")
  popup.searches = pairRow(-72, "Searches")
  local scan = pairRow(-90, "Full scan")
  popup.scan = scan

  local function linkButton(text, y, onClick)
    local b = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    b:SetSize(222, 22); b:SetPoint("TOPLEFT", 14, y); b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
  end
  popup.open = linkButton("Open Goldwright", -112, function()
    popup:Hide()
    GW.OpenTab("sell")
  end)
  popup.open:SetMotionScriptsWhileDisabled(true)
  popup.open:SetScript("OnEnter", function(self)
    if self:IsEnabled() then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Open the auction house first")
    GameTooltip:Show()
  end)
  popup.open:SetScript("OnLeave", function() GameTooltip:Hide() end)
  linkButton("Settings", -138, function()
    popup:Hide()
    GW.OpenSettings()
  end)

  -- The game can't open web links: a selectable box to copy the address from.
  local web = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
  web:SetSize(210, 20); web:SetPoint("TOPLEFT", 20, -168); web:SetAutoFocus(false)
  web:SetText(GW.WEBSITE)
  web:SetScript("OnTextChanged", function(self, user) if user then self:SetText(GW.WEBSITE) end end)
  web:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  web:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  local hint = fs(popup, "GameFontDisableSmall", "LEFT"); hint:SetPoint("TOPLEFT", web, "BOTTOMLEFT", -6, -2)
  hint:SetText("Click, then Ctrl+C to copy")
  popup:SetHeight(214)
  popup:Hide()
end

function GW.ToggleLauncher(anchor)
  if not popup then createPopup() end
  if popup:IsShown() then popup:Hide() return end
  popup:ClearAllPoints()
  if anchor and anchor.GetCenter and anchor:GetCenter() then
    local x, y = anchor:GetCenter()
    local right = x > UIParent:GetWidth() / 2
    local top = y > UIParent:GetHeight() / 2
    popup:SetPoint((top and "TOP" or "BOTTOM") .. (right and "RIGHT" or "LEFT"), anchor, (top and "BOTTOM" or "TOP") .. (right and "LEFT" or "RIGHT"))
  else
    popup:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -220, -60)
  end
  refreshPopup()
  popup:Show()
end

---------------------------------------------------------------------------
-- add-on compartment (.toc: AddonCompartmentFunc / OnEnter / OnLeave)
---------------------------------------------------------------------------
local function showButtonTooltip(owner)
  GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
  GameTooltip:SetText("Goldwright", GW.GOLD[1], GW.GOLD[2], GW.GOLD[3])
  GameTooltip:AddLine("Auction house prices for WoW Forever", 1, 1, 1)
  GameTooltip:AddLine("Click: status and links · Right-click: settings", GREY[1], GREY[2], GREY[3])
  GameTooltip:Show()
end

function Goldwright_OnAddonCompartmentClick(_, buttonName, menuButton)
  if buttonName == "RightButton" then GW.OpenSettings() else GW.ToggleLauncher(menuButton or AddonCompartmentFrame) end
end
function Goldwright_OnAddonCompartmentEnter(_, menuButton) showButtonTooltip(menuButton or AddonCompartmentFrame) end
function Goldwright_OnAddonCompartmentLeave() GameTooltip:Hide() end

---------------------------------------------------------------------------
-- minimap button (hidden by default when the compartment exists)
---------------------------------------------------------------------------
local function hasCompartment() return AddonCompartmentFrame ~= nil end

function GW.MinimapShown()
  local v = GW.Opt("minimap")
  if v == "auto" then return not hasCompartment() end
  return v and true or false
end

local function placeButton()
  local angle = math.rad(GoldwrightDB.minimapAngle or 200)
  local r = (Minimap:GetWidth() / 2) + 6
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

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
  bg:SetSize(20, 20); bg:SetPoint("TOPLEFT", 7, -5)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(18, 18); icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexture(GW.ICON)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53); border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  b:SetScript("OnClick", function(self, button)
    if button == "RightButton" then GW.OpenSettings() else GW.ToggleLauncher(self) end
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

function GW.SetMinimapShown(show)
  GW.SetOpt("minimap", show and true or false)
  if show and not minimapButton and Minimap then createMinimapButton() end
  if minimapButton then minimapButton:SetShown(show and true or false) end
  if not show and not hasCompartment() then
    GW.Print("Minimap button hidden. Bring it back with /gw minimap.")
  end
end

GW.OnLogin(function()
  if GW.MinimapShown() and Minimap then createMinimapButton() end
end)
