--- The Blackwater gaps window (/gw gaps, or the Shopping tab's button): items worth carrying between
--- the player's faction house and Blackwater (Gaps.lua), with how many to carry and an Add button
--- that puts each on the "Blackwater run" shopping list. Its own window, like the Sales window, so it
--- works away from the auction house. Read-only: our own frames, the data pack.
local _, GW = ...
local L = GW.L

local UI = GW.UI
local fs, setColor = UI.FontString, UI.SetColor
local GREY = UI.GREY

local W, H = 880, 500
local ROWS, ROW_H = 13, 26
-- column right edges (x from the left of the list)
local COL = { name = 8, buy = 380, sell = 470, gain = 530, carry = 630, slots = 690, profit = 776 }

local window -- built on first open
---@type {dir: string, rows: GoldwrightGap[], offset: number}
local state = { dir = "toN", rows = {}, offset = 0 }

--- An item's name and icon from the client.
local function itemInfo(id)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not name and getInfo then name = getInfo(id) end
  local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
  return name or string.format(L["Item %s"], id), icon
end

--- Reads the gaps for the chosen direction (back to the top unless `keepOffset`).
---@param keepOffset boolean|nil
local function load(keepOffset)
  local home = GW.House().side
  if home == "N" then home = UnitFactionGroup and UnitFactionGroup("player") == "Horde" and "H" or "A" end
  local all = GW.BlackwaterGaps(home)
  local rows = {}
  for _, g in ipairs(all) do
    if (state.dir == "toN") == (g.to == "N") then rows[#rows + 1] = g end
  end
  state.rows = rows
  state.offset = keepOffset and math.max(0, math.min(state.offset, math.max(0, #rows - ROWS))) or 0
end

local function render()
  if not window then return end
  local home = GW.House().side
  local homeName = GW.HOUSE_NAMES[home] or ""
  window.toN:SetText(string.format(L["Buy at %s, sell at Blackwater"], homeName))
  window.fromN:SetText(string.format(L["Buy at Blackwater, sell at %s"], homeName))
  UI.SetSelected(window.toN, state.dir == "toN")
  UI.SetSelected(window.fromN, state.dir ~= "toN")
  for i, row in ipairs(window.rows) do
    local g = state.rows[i + state.offset]
    row.g = g
    if not g then
      row:Hide()
    else
      row:Show()
      local name, icon = itemInfo(g.item)
      row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.name:SetText(name)
      row.buy:SetText(GW.Money(math.floor(g.buy + 0.5)))
      row.sell:SetText(GW.Money(math.floor(g.net + 0.5)))
      row.gain:SetText(string.format("+%d%%", math.floor(g.gain * 100 + 0.5)))
      row.carry:SetText(string.format(L["%d (up to %d)"], g.sure, g.upTo))
      row.slots:SetText(g.slots and tostring(g.slots) or "–")
      row.profit:SetText(GW.Money(math.floor(g.profit + 0.5)))
    end
  end
  local pack = GW.Pack and GW.Pack()
  if #state.rows == 0 then
    window.empty:SetText(
      pack and L["No gaps with proven buyers right now."] or L["No data pack: install Goldwright Data for prices."]
    )
  else
    window.empty:SetText("")
  end
  window.status:SetText(
    pack
        and string.format(
          L["%d items · prices from Goldwright Data, snapshot %s · check the listings in game before you carry a bag across the world."],
          #state.rows,
          GW.Age(pack.snapshotAt)
        )
      or ""
  )
end

local function create()
  window = UI.Window("GoldwrightGapsFrame", W, H, { title = "Goldwright · " .. L["Blackwater gaps"], movable = true })
  window:SetPoint("CENTER")

  window.toN = UI.TabButton(window, "", 260, 22, function()
    state.dir = "toN"
    load()
    render()
  end)
  window.toN:SetPoint("TOPLEFT", 14, -30)
  window.fromN = UI.TabButton(window, "", 260, 22, function()
    state.dir = "fromN"
    load()
    render()
  end)
  window.fromN:SetPoint("LEFT", window.toN, "RIGHT", 4, 0)

  local inset = window.Inset or window
  if window.Inset then
    window.Inset:ClearAllPoints()
    window.Inset:SetPoint("TOPLEFT", 8, -58)
    window.Inset:SetPoint("BOTTOMRIGHT", -8, 30)
  end
  local view = CreateFrame("Frame", nil, inset)
  view:SetAllPoints()

  local note = fs(view, "GameFontHighlightSmall", "LEFT")
  note:SetPoint("TOPLEFT", 10, -8)
  note:SetWidth(W - 40)
  note:SetText(
    L['Carry: how many should sell within one 24-hour auction where you sell (up to a day\'s worth if it goes well), in whole stacks. Only items with proven buyers there. Add puts it on your "Blackwater run" shopping list.']
  )
  setColor(note, GREY)

  local y0 = -44
  local function head(text, x, justify)
    local h = fs(view, "GameFontNormalSmall", justify)
    if justify == "RIGHT" then
      h:SetPoint("TOPRIGHT", view, "TOPLEFT", x, y0)
    else
      h:SetPoint("TOPLEFT", x, y0)
    end
    h:SetText(text)
  end
  head(L["Item"], COL.name + 26, "LEFT")
  head(L["Buy"], COL.buy, "RIGHT")
  head(L["Sells for"], COL.sell, "RIGHT")
  head(L["Gain"], COL.gain, "RIGHT")
  head(L["Carry"], COL.carry, "RIGHT")
  head(L["Slots"], COL.slots, "RIGHT")
  head(L["Profit"], COL.profit, "RIGHT")

  local list = CreateFrame("Frame", nil, view)
  list:SetPoint("TOPLEFT", 0, y0 - 16)
  list:SetSize(W - 32, ROWS * ROW_H)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    state.offset = math.max(0, math.min(state.offset - delta, math.max(0, #state.rows - ROWS)))
    render()
  end)
  window.rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("Frame", nil, list)
    row:SetSize(W - 32, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    UI.Stripe(row, i)
    row:EnableMouse(true)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", COL.name, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = fs(row, "GameFontHighlight", "LEFT")
    row.name:SetPoint("LEFT", COL.name + 26, 0)
    row.name:SetWidth(COL.buy - 110 - COL.name - 26)
    row.name:SetWordWrap(false)
    local function cell(x, w)
      local c = fs(row, "GameFontHighlightSmall", "RIGHT")
      c:SetPoint("RIGHT", row, "LEFT", x, 0)
      c:SetWidth(w)
      c:SetWordWrap(false)
      return c
    end
    row.buy = cell(COL.buy, 104)
    row.sell = cell(COL.sell, 88)
    row.gain = cell(COL.gain, 56)
    row.carry = cell(COL.carry, 106)
    row.slots = cell(COL.slots, 50)
    row.profit = cell(COL.profit, 86)
    row.add = UI.Button(row, L["Add"], 60, 20, function(self)
      local g = self:GetParent().g
      if not g then return end
      local l = GW.AddGapToList(g)
      GW.Print("%s", string.format(L['%s: %d on "%s".'], (itemInfo(g.item)), g.sure, l.name))
    end)
    row.add:SetPoint("RIGHT", -6, 0)
    row:SetScript("OnEnter", function(self)
      local g = self.g
      if not g then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(g.item) -- our tooltip lines show every house's numbers
      else
        GameTooltip:SetText((itemInfo(g.item)))
      end
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(
        string.format(
          L["%s where you sell: carry %d to sell within one auction, up to %d."],
          GW.SoldText(g.bought),
          g.sure,
          g.upTo
        ),
        1,
        1,
        1,
        true
      )
      if g.stack then
        GameTooltip:AddLine(
          string.format(L["Stacks of %d: %d bag slots, up to %d."], g.stack, g.slots, g.upToSlots),
          1,
          1,
          1,
          true
        )
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    window.rows[i] = row
  end
  window.empty = fs(view, "GameFontDisable", "CENTER")
  window.empty:SetPoint("TOP", 0, -140)
  window.status = fs(window, "GameFontDisableSmall", "LEFT")
  window.status:SetPoint("BOTTOMLEFT", 14, 10)
  window.status:SetWidth(W - 28)
  window.status:SetWordWrap(false)
  window:Hide()
end

--- Opens the window (or brings it to the front) with today's gaps.
function GW.OpenGaps()
  if not window then create() end
  load()
  window:Show()
  window:Raise()
  render()
end

-- Names and stack sizes of items the client hasn't seen yet arrive a moment later, one
-- GET_ITEM_INFO_RECEIVED each: read the gaps again (a stack size changes the amounts) and redraw,
-- once things go quiet.
local NAMES_DELAY = 0.5
local namesToken = 0
local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "GET_ITEM_INFO_RECEIVED")
ev:SetScript("OnEvent", function()
  if not (window and window:IsShown()) then return end
  namesToken = namesToken + 1
  local token = namesToken
  C_Timer.After(NAMES_DELAY, function()
    if token == namesToken and window:IsShown() then
      load(true)
      render()
    end
  end)
end)

--- Reads the gaps again when the window is open: after a full scan the prices changed, so gaps
--- can open or close (goldwright-addon #35). Back to the top of the list.
function GW.RefreshGaps()
  if not (window and window:IsShown()) then return end
  load()
  render()
end

--- For tests: the window and its state.
function GW.GapsDebug() return window, state end
