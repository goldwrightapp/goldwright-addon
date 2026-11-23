--- The price watch window (SHOP-8): the items on your watched shopping lists that dropped below
--- your max, grouped by list, instead of a long chat line. Opened by GW.WatchCheck (Shopping.lua) at
--- login, after a full scan and from "Check watched lists" / `/gw watch`; never in combat (it waits
--- for the fight to end). Each list has "Open list": the Shopping tab on that list (it opens away
--- from the auction house too; searching and buying there need the auction house).
local _, GW = ...
local L = GW.L
local UI = GW.UI
local fs, setColor = UI.FontString, UI.SetColor

local W = 440
local LINE_H = 24
local MAX_LINES = 12 -- lines shown before the window scrolls
local TOP, BOTTOM = 86, 44 -- room above the lines (title, summary) and below them (footer)

local window -- built on first use
---@type { lines: table[], offset: number, at: number, pending?: table }
local state = { lines = {}, offset = 0, at = 0 }

--- An item's link (quality colour, for the tooltip and Shift-click) and icon from the client.
---@param id number
---@return string|nil link
---@return number|string|nil icon
local function itemInfo(id)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local _, link = getInfo and getInfo(id)
  local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
  return link, icon
end

--- Hits grouped by list, as the window's lines: a list header, then its items.
---@param hits table[] { entry, price, max, list, index } from GW.WatchCheck
---@return table[] lines { kind = "list", list, index } or { kind = "item", hit }
local function linesOf(hits)
  local out, last = {}, nil
  for _, h in ipairs(hits) do
    if h.list ~= last then
      out[#out + 1] = { kind = "list", list = h.list, index = h.index }
      last = h.list
    end
    out[#out + 1] = { kind = "item", hit = h }
  end
  return out
end

--- Redraws the lines, the summary and the "Open list" buttons (shown only at the auction house).
local function render()
  if not window then return end
  local items = 0
  for _, l in ipairs(state.lines) do
    if l.kind == "item" then items = items + 1 end
  end
  window.lead:SetText(GW.Plural(items, "%d item is below your max price", "%d items are below your max price"))
  window.meta:SetText(
    string.format(L["On your watched lists · data %s · they may sell before you get there"], GW.Age(state.at))
  )
  local n = #state.lines
  state.offset = math.max(0, math.min(state.offset, math.max(0, n - MAX_LINES)))
  for i, row in ipairs(window.rows) do
    local line = state.lines[i + state.offset]
    row.line = line
    if not line then
      row:Hide()
    else
      row:Show()
      local isList = line.kind == "list"
      row.icon:SetShown(not isList)
      row.price:SetShown(not isList)
      row.max:SetShown(not isList)
      row.open:SetShown(isList)
      if isList then
        row.name:SetText(line.list.name)
        setColor(row.name, UI.GOLD or { 1, 0.82, 0 })
        row.name:SetPoint("LEFT", 4, 0)
      else
        local h = line.hit
        local link, icon = itemInfo(h.entry.itemID)
        row.link = link
        row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.name:SetText(link or h.entry.name)
        setColor(row.name, UI.WHITE)
        row.name:SetPoint("LEFT", 32, 0)
        row.price:SetText(GW.Money(h.price))
        row.max:SetText(string.format(L["max %s"], GW.Money(h.max)))
      end
    end
  end
end

--- Builds the window: summary, up to MAX_LINES lines (mouse wheel scrolls), footer with Close.
local function create()
  window = UI.Window("GoldwrightWatchFrame", W, TOP + BOTTOM + LINE_H, {
    title = "Goldwright · " .. L["Price watch"],
    strata = "DIALOG",
    movable = true,
  })
  window:SetPoint("TOP", 0, -140)
  if window.Inset then
    window.Inset:ClearAllPoints()
    window.Inset:SetPoint("TOPLEFT", 8, -28)
    window.Inset:SetPoint("BOTTOMRIGHT", -8, 8)
  end
  window.lead = fs(window, "GameFontHighlightLarge", "LEFT")
  window.lead:SetPoint("TOPLEFT", 20, -38)
  window.meta = fs(window, "GameFontDisableSmall", "LEFT")
  window.meta:SetPoint("TOPLEFT", 20, -60)
  window.meta:SetWidth(W - 40)

  local list = CreateFrame("Frame", nil, window)
  list:SetPoint("TOPLEFT", 14, -TOP + 6)
  list:SetSize(W - 28, MAX_LINES * LINE_H)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    state.offset = state.offset - delta
    render()
  end)
  window.rows = {}
  for i = 1, MAX_LINES do
    -- a Button, so the tooltip, Shift-click and the controller's cursor work on an item line
    local row = CreateFrame("Button", nil, list)
    row:SetSize(W - 28, LINE_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * LINE_H)
    UI.Stripe(row, i)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", 6, 0)
    row.name = fs(row, "GameFontHighlight", "LEFT")
    row.name:SetPoint("LEFT", 32, 0)
    row.name:SetWidth(220)
    row.name:SetWordWrap(false)
    row.price = fs(row, "GameFontHighlight", "RIGHT")
    row.price:SetPoint("RIGHT", -100, 0)
    row.max = fs(row, "GameFontDisableSmall", "RIGHT")
    row.max:SetPoint("RIGHT", -6, 0)
    row.open = UI.Button(row, L["Open List"], 100, 20, function()
      local line = row.line
      if not (line and line.kind == "list") then return end
      if GW.OpenTab then GW.OpenTab("shopping") end
      GW.ShopView.OpenList(line.index)
      window:Hide()
    end)
    row.open:SetPoint("RIGHT", -4, 0)
    row:SetScript("OnEnter", function(self)
      if not self.link then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(self.link)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
      -- Shift-click links the item in chat, like a bag item
      if self.line and self.line.kind == "item" and self.link and HandleModifiedItemClick then
        HandleModifiedItemClick(self.link)
      end
    end)
    window.rows[i] = row
  end

  window.note = fs(window, "GameFontDisableSmall", "LEFT")
  window.note:SetPoint("BOTTOMLEFT", 20, 20)
  window.note:SetWidth(W - 150)
  window.note:SetText(L["Hover an item for its tooltip; Shift-click links it in chat."])
  window.close = UI.Button(window, L["Close"], 80, 22, function() window:Hide() end)
  window.close:SetPoint("BOTTOMRIGHT", -18, 16)
end

--- Shows the window with these hits (replacing what it showed). In combat it waits for the fight
--- to end; the latest hits win.
---@param hits table[] { entry, price, max, list, index }, grouped by list in list order
---@param at number server time of the data the hits come from
function GW.ShowWatch(hits, at)
  if InCombatLockdown and InCombatLockdown() then
    state.pending = { hits = hits, at = at }
    return
  end
  state.pending = nil
  if not window then create() end
  state.lines, state.offset, state.at = linesOf(hits), 0, at or 0
  window:SetHeight(TOP + BOTTOM + math.min(#state.lines, MAX_LINES) * LINE_H)
  render()
  window:Show()
end

--- The window and its state, for tests.
function GW.WatchDebug() return window, state end

local events = CreateFrame("Frame")
pcall(events.RegisterEvent, events, "PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function()
  local p = state.pending
  if p then GW.ShowWatch(p.hits, p.at) end
end)
