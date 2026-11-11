--- The Goldwright Crafting panel beside Blizzard's profession window (ProfessionsFrame): the open
--- profession's recipes with a profit badge each (CRAFT-1), sortable by profit or name, and the
--- selected recipe's materials, cost, output value, profit after the cut and sell rate (CRAFT-2),
--- with currencies such as Merchant's Favor listed apart from gold (CRAFT-3). Rules without UI live
--- in Crafting.lua.
---
--- Read-only and taint-safe: the panel is our own window anchored beside ProfessionsFrame. It never
--- hooks or changes Blizzard's frames or recipe rows, assigns no Blizzard globals and calls no
--- crafting or protected functions. It opens on TRADE_SKILL_SHOW and closes on TRADE_SKILL_CLOSE.
local _, GW = ...

local W, H = 680, 540
local ROWS, ROW_H = 15, 28
local LIST_W = 300
local MAX_MATS = 8 -- material rows shown (Forever recipes seen in game use at most 4)
local REFRESH_DELAY = 0.2 -- seconds: TRADE_SKILL_LIST_UPDATE fires in bursts
local NAMES_DELAY = 0.5 -- seconds: item names arrive one GET_ITEM_INFO_RECEIVED at a time
local GAP, MIN_GAP = 60, 6 -- pixels right of the profession window: clear of its side tabs, less if the screen is narrow
local ANCHOR_TRIES, ANCHOR_DELAY = 10, 0.1 -- wait up to a second for the profession window to show

local UI = GW.UI
local fs, setColor, header = UI.FontString, UI.SetColor, UI.Header
local GREY, WHITE = UI.GREY, UI.WHITE

local panel -- the frame, created on first use
local onDragStop -- defined with the anchoring below; the window built before it calls it on drag

--- State of the Crafting panel.
---@class CraftState
---@field open boolean the profession window is open (between TRADE_SKILL_SHOW and TRADE_SKILL_CLOSE)
---@field rows GoldwrightRecipeRow[] the recipe list, in display order
---@field hidden number unlearned recipes left out of the list
---@field offset number scroll offset into rows
---@field sel number|nil recipe id of the selected recipe
---@field token number bumped to cancel pending refresh timers
---@field namesToken number bumped to cancel pending redraws for item names
local state = { open = false, rows = {}, hidden = 0, offset = 0, token = 0, namesToken = 0 }

--- The list order setting: "profit" (default) or "name".
---@return string by
local function sortBy() return GoldwrightDB and GoldwrightDB.craftSort == "name" and "name" or "profit" end

--- Whether the list shows recipes the character hasn't learned.
---@return boolean
local function showUnlearned() return GoldwrightDB and GoldwrightDB.craftUnlearned == true or false end

--- An item's name from the client, or "Item 1234" while it isn't cached.
---@param itemID number|nil
---@return string name
local function itemName(itemID)
  if not itemID then return "Unknown material" end
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
  if not name then
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    name = getInfo and getInfo(itemID)
  end
  return name or ("Item " .. itemID)
end

--- The badge for a recipe row: "+9c profit" (blue), "−4c loss" (orange), or a grey note.
---@param p GoldwrightCraftPrice
---@return string text
---@return number[] color {r, g, b}
function GW.ProfitBadge(p)
  if p.profit then
    if p.profit >= 0.5 then return GW.SignedMoney(p.profit) .. " profit", GW.SIGNAL_BLUE end
    if p.profit <= -0.5 then return GW.SignedMoney(p.profit) .. " loss", GW.SIGNAL_ORANGE end
    return "Break even", GREY
  end
  if p.noOutput then return "No item made", GREY end
  return "No price data", GREY
end

--- The house name for a side ("Alliance", "Blackwater").
---@param side string|nil
---@return string name "" without a side
local function houseName(side)
  if side == "vendor" then return "Vendor" end
  return side and GW.HOUSE_NAMES[side] or ""
end

--- A count or percentage without a needless ".0": 2 -> "2", 1.5 -> "1.5".
---@param n number
---@return string text
local function qtyText(n)
  local r = math.floor(n * 10 + 0.5) / 10
  if r == math.floor(r) then return string.format("%d", r) end
  return string.format("%.1f", r)
end

--- The short row hint for a recipe whose output pays more at the other house: "+40% at Blackwater".
---@param hint GoldwrightCraftHint|nil
---@return string|nil text
local function hintShort(hint)
  if not hint then return nil end
  if hint.pct then return string.format("+%d%% at %s", hint.pct, houseName(hint.side)) end
  return "Sells at " .. houseName(hint.side)
end

--- The detail note: where the prices come from, or why the other house is worth a look.
---@param p GoldwrightCraftPrice
---@return string text
local function hintNote(p)
  local h = p.hint
  if not h then return string.format("Prices from the %s auction house.", houseName(p.side)) end
  local sold = h.boughtPerDay and string.format(" (%s there)", GW.SoldText(h.boughtPerDay)) or ""
  if h.pct then
    return string.format(
      "Nets ~%d%% more at %s after its cut%s. Switch with the Prices button above.",
      h.pct,
      houseName(h.side),
      sold
    )
  end
  return string.format(
    "No price at %s, but %s has proven buyers%s. Switch with the Prices button above.",
    houseName(p.side),
    houseName(h.side),
    sold
  )
end

--- The selected row, if it is still in the list.
---@return GoldwrightRecipeRow|nil row
local function selectedRow()
  for _, row in ipairs(state.rows) do
    if row.recipe.id == state.sel then return row end
  end
  return nil
end

---------------------------------------------------------------------------
-- rendering
---------------------------------------------------------------------------
--- Redraws the recipe list (CRAFT-1).
local function renderList()
  local n = #state.rows
  state.offset = math.max(0, math.min(state.offset, n - ROWS))
  for i, row in ipairs(panel.rows) do
    local r = state.rows[state.offset + i]
    row.r = r
    if r then
      local rec = r.recipe
      row.icon:SetTexture(rec.icon)
      row.name:SetText(rec.name)
      setColor(row.name, rec.learned and WHITE or GREY)
      local cur = GW.CurrencyText(rec.currencies)
      local hint = hintShort(r.price.hint)
      setColor(row.sub, GREY)
      if not rec.learned then
        row.sub:SetText("Not learned")
      elseif hint then
        row.sub:SetText(hint)
        setColor(row.sub, GW.SIGNAL_BLUE)
      elseif cur then
        row.sub:SetText("Also needs " .. cur)
      else
        row.sub:SetText("")
      end
      local text, color = GW.ProfitBadge(r.price)
      row.badge:SetText(text)
      setColor(row.badge, color)
      row.sel:SetShown(rec.id == state.sel)
      row:Show()
    else
      row:Hide()
    end
  end
  if n > 0 then
    panel.empty:SetText("")
  elseif state.hidden > 0 then
    panel.empty:SetText("No learned recipes yet. Click Show Unlearned to see the rest.")
  else
    panel.empty:SetText("No recipes yet: they load when the profession window opens.")
  end
  panel.sortProfit:SetEnabled(sortBy() ~= "profit")
  panel.sortName:SetEnabled(sortBy() ~= "name")
  panel.unlearned:SetText(showUnlearned() and "Hide Unlearned" or "Show Unlearned")
  panel.house:SetText("Prices: " .. houseName(GW.CraftSide()))
  panel.house:SetShown(GW.House().side ~= "N")
  local shownText = GW.Number(n) .. (n == 1 and " recipe" or " recipes")
  if state.hidden > 0 then shownText = shownText .. " · " .. GW.Number(state.hidden) .. " not learned hidden" end
  panel.count:SetText(shownText)
end

--- Sets a summary line's value text and colour.
---@param line table summary line (label + value font strings)
---@param text string
---@param color number[]|nil {r, g, b} (default white)
local function setLine(line, text, color)
  line.value:SetText(text)
  setColor(line.value, color or WHITE)
end

--- Redraws the selected recipe's detail (CRAFT-2, CRAFT-3).
local function renderDetail()
  local d = panel.detail
  local r = selectedRow()
  if not r then
    d.title:SetText("Select a recipe")
    d.makes:SetText("Its materials, cost and profit show here.")
    for _, m in ipairs(d.mats) do
      m:Hide()
    end
    d.more:SetText("")
    d.currency:SetText("")
    for _, line in pairs(d.lines) do
      line.label:Hide()
      line.value:Hide()
    end
    d.note:SetText("")
    return
  end
  for _, line in pairs(d.lines) do
    line.label:Show()
    line.value:Show()
  end
  local rec, p = r.recipe, r.price
  d.title:SetText(rec.name)
  local makes
  if rec.outputItemID then
    local qty = rec.qtyMin == rec.qtyMax and tostring(rec.qtyMin) or (rec.qtyMin .. "–" .. rec.qtyMax)
    makes = string.format("Makes %s × %s", qty, itemName(rec.outputItemID))
    if rec.qtyAssumed then makes = makes .. " (count unknown, 1 assumed)" end
  elseif rec.noSchematic then
    makes = "The game didn't say what this recipe makes."
  else
    makes = "Makes no item to sell."
  end
  if not rec.learned then makes = makes .. " · Not learned" end
  d.makes:SetText(makes)

  -- materials table: name ×qty | cost | house
  for i, m in ipairs(d.mats) do
    local mat = p.materials[i]
    if mat then
      m.name:SetText(string.format("%s ×%s", itemName(mat.itemID), mat.qty and tostring(mat.qty) or "?"))
      if mat.total then
        m.cost:SetText(GW.Money(mat.total))
        setColor(m.cost, WHITE)
        m.house:SetText(houseName(mat.side))
      else
        m.cost:SetText("No price data")
        setColor(m.cost, GREY)
        m.house:SetText("")
      end
      m:Show()
    else
      m:Hide()
    end
  end
  local extra = #p.materials - MAX_MATS
  if extra > 0 then
    d.more:SetText(string.format("+ %d more", extra))
  elseif #p.materials == 0 then
    d.more:SetText(rec.noSchematic and "Materials unknown." or "No materials.")
  else
    d.more:SetText("")
  end
  local cur = GW.CurrencyText(p.currencies)
  d.currency:SetText(cur and ("Also needs " .. cur .. " (not counted in gold)") or "")

  -- summary
  if p.cost then
    setLine(d.lines.cost, GW.Money(p.cost))
  elseif p.missing > 0 and #p.materials > 1 then
    setLine(d.lines.cost, string.format("No price data for %d of %d", p.missing, #p.materials), GREY)
  else
    setLine(d.lines.cost, "No price data", GREY)
  end
  if p.value then
    local each = p.avgQty == 1 and "" or string.format(" (%s × %s)", qtyText(p.avgQty), GW.Money(p.outputUnit))
    setLine(d.lines.value, GW.Money(p.value) .. each)
    setLine(
      d.lines.cut,
      string.format(
        "−%s (%s%% at %s)",
        GW.Money(p.cut),
        qtyText((GW.CUT[p.outputSide] or 0.05) * 100),
        houseName(p.outputSide)
      )
    )
  else
    setLine(d.lines.value, p.noOutput and "No item made" or "No price data", GREY)
    setLine(d.lines.cut, "", GREY)
  end
  local text, color = GW.ProfitBadge(p)
  if p.profit then text = text .. " per craft" end
  if cur then text = text .. ", plus " .. cur end
  setLine(d.lines.profit, text, color)
  if p.soldPerDay then
    setLine(d.lines.rate, GW.SoldText(p.soldPerDay) .. " (est.)")
  else
    setLine(d.lines.rate, "Unknown", GREY)
  end
  d.note:SetText(hintNote(p))
end

--- The data status line under the panel.
local function renderStatus()
  local pack = GW.Pack and GW.Pack()
  if pack then
    panel.status:SetText(
      "Market values from Goldwright Data, snapshot " .. GW.Age(pack.snapshotAt) .. ". Deposits not included."
    )
  else
    panel.status:SetText("No data pack: install Goldwright Data for prices.")
  end
end

--- Redraws everything.
local function render()
  if not panel then return end
  UI.SetTitle(panel, "Goldwright · " .. (GW.ProfessionName() or "Crafting"))
  renderList()
  renderDetail()
  renderStatus()
end

--- Reads the recipes again, keeps the selection when it is still listed (else selects the first) and
--- redraws.
local function refresh()
  if not panel then return end
  state.rows, state.hidden = GW.CraftRows(sortBy(), showUnlearned())
  if not selectedRow() then state.sel = state.rows[1] and state.rows[1].recipe.id or nil end
  render()
end
GW.RefreshCraftPanel = refresh

--- Refreshes after `delay` seconds; a newer call replaces an older one (debounce).
---@param delay number seconds
local function scheduleRefresh(delay)
  state.token = state.token + 1
  local token = state.token
  C_Timer.After(delay, function()
    if token == state.token and panel and panel:IsShown() then refresh() end
  end)
end

--- Selects a recipe and shows its detail.
---@param id number recipe id
function GW.SelectRecipe(id)
  state.sel = id
  if panel then
    renderList()
    renderDetail()
  end
end

---------------------------------------------------------------------------
-- the window
---------------------------------------------------------------------------
--- Builds the panel window: sort buttons, the house switch, the recipe list, the detail column and the
--- status line.
--- The panel starts hidden.
local function createPanel()
  panel = UI.Window("GoldwrightCraftFrame", W, H, { title = "Goldwright", movable = true })
  GW.craftPanel = panel

  panel.sortProfit = UI.Button(panel, "Sort by Profit", 110, 22, function()
    GoldwrightDB.craftSort = nil
    refresh()
  end)
  panel.sortProfit:SetPoint("TOPLEFT", 14, -30)
  panel.sortName = UI.Button(panel, "Sort by Name", 110, 22, function()
    GoldwrightDB.craftSort = "name"
    refresh()
  end)
  panel.sortName:SetPoint("LEFT", panel.sortProfit, "RIGHT", 4, 0)
  panel.unlearned = UI.Button(panel, "Show Unlearned", 120, 22, function()
    GoldwrightDB.craftUnlearned = not showUnlearned() or nil
    state.offset = 0
    refresh()
  end)
  panel.unlearned:SetPoint("LEFT", panel.sortName, "RIGHT", 4, 0)
  panel.house = UI.Button(panel, "Prices: Alliance", 150, 22, function()
    GW.SetCraftSide(GW.CraftSide() == "N" and GW.House().side or "N")
    refresh()
  end)
  panel.house:SetPoint("LEFT", panel.unlearned, "RIGHT", 8, 0)
  panel.house:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Auction house for prices")
    GameTooltip:AddLine("Materials, output value and the cut all come from this house.", 1, 1, 1, true)
    GameTooltip:AddLine("Click to switch between your faction's house and Blackwater.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  panel.house:SetScript("OnLeave", function() GameTooltip:Hide() end)
  local gear = UI.Button(panel, "Settings", 90, 22, function()
    if GW.OpenSettings then GW.OpenSettings() end
  end)
  gear:SetPoint("TOPRIGHT", -14, -30)

  local inset = panel.Inset or panel
  if panel.Inset then
    panel.Inset:ClearAllPoints()
    panel.Inset:SetPoint("TOPLEFT", 8, -58)
    panel.Inset:SetPoint("BOTTOMRIGHT", -8, 30)
  end
  local view = CreateFrame("Frame", nil, inset)
  view:SetAllPoints()

  -- recipe list (CRAFT-1) -----------------------------------------------------
  panel.rows = {}
  local list = CreateFrame("Frame", nil, view)
  list:SetPoint("TOPLEFT", 6, -6)
  list:SetSize(LIST_W, ROWS * ROW_H)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    state.offset = math.max(0, math.min(state.offset - delta, math.max(0, #state.rows - ROWS)))
    renderList()
  end)
  for i = 1, ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetSize(LIST_W, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    UI.Stripe(row, i)
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(0.24, 0.37, 0.66, 0.35)
    row.sel:Hide()
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = fs(row, "GameFontHighlight", "LEFT")
    row.name:SetPoint("TOPLEFT", 32, -2)
    row.name:SetWidth(LIST_W - 36)
    row.name:SetWordWrap(false)
    row.sub = fs(row, "GameFontDisableSmall", "LEFT")
    row.sub:SetPoint("BOTTOMLEFT", 32, 2)
    row.sub:SetWidth(130)
    row.sub:SetWordWrap(false)
    row.badge = fs(row, "GameFontHighlightSmall", "RIGHT")
    row.badge:SetPoint("BOTTOMRIGHT", -4, 2)
    row:SetScript("OnClick", function(self)
      if self.r then GW.SelectRecipe(self.r.recipe.id) end
    end)
    row:SetScript("OnEnter", function(self)
      local r = self.r
      if not r then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if r.recipe.outputItemID and GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(r.recipe.outputItemID) -- our tooltip lines add the prices
      else
        GameTooltip:SetText(r.recipe.name)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    panel.rows[i] = row
  end
  panel.empty = fs(view, "GameFontDisable", "CENTER")
  panel.empty:SetPoint("TOPLEFT", 16, -60)
  panel.empty:SetWidth(LIST_W - 20)
  panel.count = fs(view, "GameFontDisableSmall", "LEFT")
  panel.count:SetPoint("BOTTOMLEFT", 10, 8)

  UI.Divider(view, LIST_W + 12)

  -- detail (CRAFT-2, CRAFT-3) -------------------------------------------------
  local x = LIST_W + 24
  local colW = W - 16 - x - 12
  local d = {}
  panel.detail = d
  d.title = fs(view, "GameFontNormalLarge", "LEFT")
  d.title:SetPoint("TOPLEFT", x, -10)
  d.title:SetWidth(colW)
  d.title:SetWordWrap(false)
  d.makes = fs(view, "GameFontHighlightSmall", "LEFT")
  d.makes:SetPoint("TOPLEFT", x, -32)
  d.makes:SetWidth(colW)
  header(view, "Materials", x, -56)
  d.mats = {}
  for i = 1, MAX_MATS do
    local m = CreateFrame("Frame", nil, view)
    m:SetSize(colW, 18)
    m:SetPoint("TOPLEFT", x, -74 - (i - 1) * 18)
    m.name = fs(m, "GameFontHighlightSmall", "LEFT")
    m.name:SetPoint("LEFT", 0, 0)
    m.name:SetWidth(colW - 180)
    m.name:SetWordWrap(false)
    m.cost = fs(m, "GameFontHighlightSmall", "RIGHT")
    m.cost:SetPoint("RIGHT", -80, 0)
    m.cost:SetWidth(100)
    m.house = fs(m, "GameFontDisableSmall", "RIGHT")
    m.house:SetPoint("RIGHT", 0, 0)
    m.house:SetWidth(76)
    m:Hide()
    d.mats[i] = m
  end
  local y = -74 - MAX_MATS * 18
  d.more = fs(view, "GameFontDisableSmall", "LEFT")
  d.more:SetPoint("TOPLEFT", x, y - 2)
  d.currency = fs(view, "GameFontNormalSmall", "LEFT")
  d.currency:SetPoint("TOPLEFT", x, y - 18)
  d.currency:SetWidth(colW)

  header(view, "Per Craft", x, y - 44)
  d.lines = {}
  local labels = {
    { key = "cost", label = "Total cost" },
    { key = "value", label = "Output value" },
    { key = "cut", label = "Auction house cut" },
    { key = "profit", label = "Profit" },
    { key = "rate", label = "Sell rate" },
  }
  for i, l in ipairs(labels) do
    local ly = y - 64 - (i - 1) * 20
    local label = fs(view, "GameFontHighlight", "LEFT")
    label:SetPoint("TOPLEFT", x, ly)
    label:SetText(l.label)
    setColor(label, GREY)
    local value = fs(view, "GameFontHighlight", "RIGHT")
    value:SetPoint("TOPRIGHT", view, "TOPLEFT", x + colW, ly)
    value:SetWidth(colW - 130)
    d.lines[l.key] = { label = label, value = value }
  end
  d.note = fs(view, "GameFontDisableSmall", "LEFT")
  d.note:SetPoint("TOPLEFT", x, y - 64 - #labels * 20 - 6)
  d.note:SetWidth(colW)

  panel.status = fs(panel, "GameFontDisableSmall", "LEFT")
  panel.status:SetPoint("BOTTOMLEFT", 14, 10)

  panel:SetScript("OnShow", refresh)
  panel:SetScript("OnDragStop", function(self) onDragStop(self) end)
  GW.OnOptionsChanged(function()
    if panel:IsShown() then refresh() end
  end)
  -- New frames start shown, so the first Show() wouldn't fire OnShow; start hidden instead.
  panel:Hide()
end

--- How far right of the profession window the panel starts: GAP, clear of the profession tabs on the
--- window's right edge, or as much as the screen leaves room for (at least MIN_GAP).
---@param pf table the profession window
---@return number gap pixels, in the panel's scale
local function defaultGap(pf)
  local right, screen = pf:GetRight(), UIParent:GetRight()
  if not (right and screen) then return GAP end
  local s = panel:GetEffectiveScale()
  local room = screen * UIParent:GetEffectiveScale() / s - right * pf:GetEffectiveScale() / s - panel:GetWidth()
  return math.max(MIN_GAP, math.min(GAP, math.floor(room)))
end

--- Places the panel beside the profession window: where the player last dragged it (an offset from
--- the window's top-right corner, GoldwrightDB.craftPos), else defaultGap() right of it. Anchored to the
--- window, so it follows when the window moves. While the window isn't shown yet (it can show a
--- moment after TRADE_SKILL_SHOW), the panel waits centred and tries again, up to ANCHOR_TRIES times.
---@param tries number|nil attempts so far
local function anchorToProfessions(tries)
  tries = tries or 0
  panel:ClearAllPoints()
  local pf = ProfessionsFrame
  if pf and pf:IsShown() then
    local pos = GoldwrightDB and GoldwrightDB.craftPos
    panel:SetPoint("TOPLEFT", pf, "TOPRIGHT", pos and pos.x or defaultGap(pf), pos and pos.y or 0)
    return
  end
  panel:SetPoint("CENTER")
  if tries < ANCHOR_TRIES then
    C_Timer.After(ANCHOR_DELAY, function()
      if panel:IsShown() then anchorToProfessions(tries + 1) end
    end)
  end
end

--- After the player drags the panel: remembers where it sits relative to the profession window's
--- top-right corner and anchors it there again (dragging anchors it to the screen instead).
---@param self table the panel
onDragStop = function(self)
  self:StopMovingOrSizing()
  local pf = ProfessionsFrame
  local left, top = self:GetLeft(), self:GetTop()
  local right, pfTop = pf and pf:IsShown() and pf:GetRight(), pf and pf:GetTop()
  if not (left and top and right and pfTop) then return end
  local k = pf:GetEffectiveScale() / self:GetEffectiveScale()
  GoldwrightDB.craftPos = { x = math.floor(left - right * k + 0.5), y = math.floor(top - pfTop * k + 0.5) }
  anchorToProfessions()
end

--- Puts the panel back just right of the profession window (/gw craft reset).
function GW.ResetCraftPosition()
  if GoldwrightDB then GoldwrightDB.craftPos = nil end
  if panel and panel:IsShown() then anchorToProfessions() end
end

--- Shows the panel beside the profession window.
local function showPanel()
  if not panel then createPanel() end
  anchorToProfessions()
  if panel:IsShown() then
    refresh()
  else
    panel:Show() -- OnShow refreshes
  end
end

--- Shows or hides the panel (/gw craft); only while a profession window is open.
function GW.ToggleCraftPanel()
  if not state.open then
    GW.Print("Open a profession first.")
    return
  end
  if panel and panel:IsShown() then
    panel:Hide()
  else
    showPanel()
  end
end

---------------------------------------------------------------------------
-- events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({
  "TRADE_SKILL_SHOW",
  "TRADE_SKILL_CLOSE",
  "TRADE_SKILL_LIST_UPDATE",
  "TRADE_SKILL_DATA_SOURCE_CHANGED",
  "GET_ITEM_INFO_RECEIVED",
}) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event)
  if event == "TRADE_SKILL_SHOW" then
    state.open = true
    -- A moment later, so Blizzard's window is shown and placed first (like the Sell panel).
    C_Timer.After(0.1, function()
      if state.open then showPanel() end
    end)
  elseif event == "TRADE_SKILL_CLOSE" then
    state.open = false
    state.token = state.token + 1
    if panel then panel:Hide() end
  elseif event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
    if event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then state.offset = 0 end
    scheduleRefresh(REFRESH_DELAY)
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if not (panel and panel:IsShown()) then return end
    state.namesToken = state.namesToken + 1
    local token = state.namesToken
    C_Timer.After(NAMES_DELAY, function()
      if token == state.namesToken and panel:IsShown() then renderDetail() end
    end)
  end
end)
