--- The Buy tab (goldwright-addon #37), its own view laid out like the Sell tab: on the left a lookup
--- (a box with suggestions while you type, and this character's recent lookups); top right the shared
--- market card (MarketCard.lua); below it "Compared with usual", the other houses and buying. Works away from the auction house from Goldwright's data. Facts only: Goldwright shows how
--- today's price compares with the item's usual and the player decides (no resell or profit lines).
--- Design: docs/design/buy-tab-2026-11-22.md, docs/design/BuyTab.html.
local _, GW = ...
local L = GW.L
local UI = GW.UI

GW.BuyView = {}

local ROWS, ROW_H = 10, 38 -- recent lookups, like the bag list's rows
local SUGGEST, SUGGEST_H = 5, 24 -- suggestions under the box
local NOTE_H = 30 -- the suggestions' note when Goldwright Data's names are missing (two lines)
local RECENT_MAX = ROWS -- lookups remembered: as many as the list shows (it doesn't scroll)
local MENU_ROWS, MENU_H, MENU_W = 12, 20, 220 -- the "+ Shopping List" menu: lists shown, row height, width
local USUAL_PCT = 10 -- within this % of the 7-day normal: "About usual"
local SIDES = { "A", "H", "N" }

local lookupCard, buyCard
local box, hint, drop, recentRows, clearLink
local cmp, houses, buyCol
local suggestions, hl = {}, 1
local myBuy, dropPending -- the Buy tab's purchase (defined with the buying code below)

local MC = GW.MarketCard
local view -- the tab's frame
local sel -- the item looked up (GoldwrightMarketItem with `count`)

--- What the Buy tab is showing: its item and, once the auction house answered, the market card's
--- live listings for it.
---@return { mode: string|nil, sel: table|nil, stats: table|nil, source: string|nil }
local function current()
  local mine = sel and MC.Item() == sel
  return {
    mode = view and view:IsShown() and "buy" or nil,
    sel = sel,
    stats = mine and MC.Stats() or nil,
    source = mine and MC.Source() or nil,
  }
end

--- How many of an item are in your bags.
---@param id number
---@return number
local function itemCount(id)
  if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id, false) or 0 end
  return GetItemCount and GetItemCount(id) or 0
end

--- Shows an item in the market card and below.
---@param g table
local function showItem(g)
  sel = g
  MC.Show(g, g.count > 0 and GW.PluralCount(g.count, "You have %s", "You have %s") or nil)
  GW.BuyView.Render()
end
local function T() return UI.Tokens() end

--- The cheapest real listing of an item at the house you'd buy at: live when it's the item on the
--- Buy tab and the auction house just answered, else from Goldwright's data.
---@param id number
---@return number|nil copper
local function lowestOf(id)
  -- the item on screen, searched just now at the auction house: the live cheapest listing
  local st = current()
  local s = st.mode == "buy" and st.sel and st.sel.itemID == id and st.stats
  local live = s and s.sorted[s.firstRealIndex]
  if live then return live.price end
  local d = GW.ItemData(id)
  local here = d and d[MC.Side()]
  return here and here.mv and here.min or nil
end

---------------------------------------------------------------------------
-- looking an item up
---------------------------------------------------------------------------
--- This character's recent lookups, newest first (item ids): each character shops for its own
--- things (GoldwrightDB.buyRecent["US/Bomo"]).
---@return number[]
local function recent()
  local key = GW.CharKey() or "?"
  GoldwrightDB.buyRecent = type(GoldwrightDB.buyRecent) == "table" and GoldwrightDB.buyRecent or {}
  local all = GoldwrightDB.buyRecent
  if all[1] then -- an early dev build kept one list for every character: start fresh
    all = {}
    GoldwrightDB.buyRecent = all
  end
  if type(all[key]) ~= "table" then all[key] = {} end
  return all[key]
end

local renderRecent, renderSuggest

--- Looks an item up: shows it in the market card and below, and puts it first in Recent.
---@param id number item id
---@param link string|nil item link (its name in the player's language)
function GW.BuyView.LookUp(id, link)
  if type(id) ~= "number" then return end
  local name = (type(link) == "string" and link:match("%[(.-)%]"))
    or GW.ItemNames.Of(id)
    or string.format(L["item %d"], id)
  GW.ItemNames.Note(id, name)
  local r = recent()
  for i = #r, 1, -1 do
    if r[i] == id then table.remove(r, i) end
  end
  table.insert(r, 1, id)
  while #r > RECENT_MAX do
    table.remove(r)
  end
  if box then
    box:SetText("")
    box:ClearFocus()
  end
  local p = myBuy()
  if buyCol then buyCol.menu:Hide() end
  if buyCol and not (p and p.confirming) then
    dropPending()
    buyCol.qty:SetText("")
    buyCol.status:SetText("")
  end
  local quality = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
  showItem({
    itemID = id,
    key = id,
    packKey = id,
    name = name,
    icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id),
    quality = quality,
    count = itemCount(id),
  })
  if renderRecent then renderRecent() end
end

---------------------------------------------------------------------------
-- the lookup card
---------------------------------------------------------------------------
--- A row: icon, name, and the lowest price at this house in one right-aligned column.
---@param parent table
---@param h number height
---@param iconSize number
---@return table row
local function itemRow(parent, w, h, iconSize)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(w, h)
  local lit = row:CreateTexture(nil, "HIGHLIGHT")
  lit:SetAllPoints()
  local hov = T().hover
  lit:SetColorTexture(hov[1], hov[2], hov[3], hov[4])
  row.sel = row:CreateTexture(nil, "BACKGROUND")
  row.sel:SetAllPoints()
  local s = T().selected
  row.sel:SetColorTexture(s[1], s[2], s[3], s[4])
  row.sel:Hide()
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(iconSize, iconSize)
  row.icon:SetPoint("LEFT", 8, 0)
  row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  row.name = UI.FontString(row, h > 30 and "GameFontHighlight" or "GameFontHighlightSmall", "LEFT")
  row.name:SetPoint("LEFT", iconSize + 14, 0)
  row.name:SetWidth(w - iconSize - 14 - 78)
  row.name:SetWordWrap(false)
  row.price = UI.Text(row, "GameFontHighlightSmall", "muted", "RIGHT")
  row.price:SetPoint("RIGHT", -10, 0)
  row.price:SetWidth(74)
  row:SetScript("OnEnter", function(self)
    if not self.id then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.id)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:SetScript("OnClick", function(self)
    if self.id then GW.BuyView.LookUp(self.id) end
  end)
  return row
end

--- Fills a row for an item.
---@param row table
---@param id number
---@param name string
local function fillRow(row, id, name)
  row.id = id
  row.icon:SetTexture(C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id) or 134400)
  row.name:SetText(name)
  local low = lowestOf(id)
  row.price:SetText(low and GW.Money(low, true) or "–")
  row:Show()
end

renderSuggest = function()
  local typed = box and box:GetText() or ""
  hint:SetShown(typed == "" and not box:HasFocus())
  suggestions = typed ~= "" and GW.ItemNames.Match(typed, SUGGEST) or {}
  hl = math.max(1, math.min(hl, #suggestions))
  for i, row in ipairs(drop.rows) do
    local m = suggestions[i]
    if m then
      fillRow(row, m.id, m.name)
      row.sel:SetShown(i == hl)
    else
      row.id = nil
      row:Hide()
    end
  end
  -- without Goldwright Data's names (an older data add-on) only names Goldwright has seen are found:
  -- say how to get them all, under the matches (also when there are none)
  local noNames = typed ~= "" and not GW.ItemNames.FromData()
  local n = #suggestions
  drop.note:ClearAllPoints()
  drop.note:SetPoint("TOPLEFT", 10, -(2 + n * SUGGEST_H + 4))
  drop.note:SetShown(noNames)
  drop:SetHeight(math.max(1, n) * SUGGEST_H + (noNames and NOTE_H or 0) + 4)
  drop:SetShown((n > 0 or noNames) and box:HasFocus())
end

renderRecent = function()
  local r = recent()
  lookupCard.recentCap:SetText(string.format("%s · %d", L["Recent"], #r))
  local sel = sel
  for i, row in ipairs(recentRows) do
    local id = r[i]
    if id then
      fillRow(row, id, GW.ItemNames.Of(id) or string.format(L["item %d"], id))
      row.sel:SetShown(sel and sel.itemID == id or false)
    else
      row.id = nil
      row:Hide()
    end
  end
  clearLink:SetShown(#r > 0)
end

--- Builds the lookup card: on the left, where the Sell tab has your bags.
local function buildLookup()
  local w = MC.LIST_W
  lookupCard = UI.Card(view)
  lookupCard:SetPoint("TOPLEFT", 6, -6)
  lookupCard:SetPoint("BOTTOMLEFT", 6, 6)
  lookupCard:SetWidth(w)
  UI.Caption(lookupCard, L["Look up"], 12, -10)

  box = UI.NewEditBox(lookupCard)
  box:SetSize(w - 28, 20)
  box:SetPoint("TOPLEFT", 18, -30)
  box:SetAutoFocus(false)
  hint = UI.Text(box, "GameFontDisableSmall", "faint", "LEFT")
  hint:SetPoint("LEFT", 2, 0)
  hint:SetText(L["Type an item name"])
  box:SetScript("OnTextChanged", function()
    hl = 1
    renderSuggest()
  end)
  box:SetScript("OnEditFocusGained", renderSuggest)
  box:SetScript("OnEditFocusLost", function()
    -- a click on a suggestion lands after the focus left: hide on the next frame
    C_Timer.After(0.2, function()
      if not box:HasFocus() then
        drop:Hide()
        hint:SetShown(box:GetText() == "")
      end
    end)
  end)
  box:SetScript("OnArrowPressed", function(_, key)
    if #suggestions == 0 then return end
    if key == "DOWN" then
      hl = hl % #suggestions + 1
    elseif key == "UP" then
      hl = (hl - 2) % #suggestions + 1
    end
    renderSuggest()
  end)
  box:SetScript("OnEnterPressed", function()
    local m = suggestions[hl] or suggestions[1]
    if m then GW.BuyView.LookUp(m.id) end
  end)
  box:SetScript("OnEscapePressed", function(self)
    if drop:IsShown() then
      drop:Hide()
    else
      self:ClearFocus()
    end
  end)

  lookupCard.recentCap = UI.Text(lookupCard, "GameFontNormalSmall", "muted", "LEFT")
  lookupCard.recentCap:SetPoint("TOPLEFT", 12, -60)
  recentRows = {}
  local list = CreateFrame("Frame", nil, lookupCard)
  list:SetPoint("TOPLEFT", 1, -76)
  list:SetSize(w - 2, ROWS * ROW_H)
  for i = 1, ROWS do
    local row = itemRow(list, w - 2, ROW_H, 28)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    local line = UI.Rule(row, "rowLine")
    line:SetPoint("TOPLEFT")
    line:SetPoint("TOPRIGHT")
    line:SetHeight(1)
    recentRows[i] = row
  end
  clearLink = CreateFrame("Button", nil, lookupCard)
  clearLink:SetSize(120, 16)
  clearLink:SetPoint("BOTTOMLEFT", 12, 12)
  clearLink:SetNormalFontObject("GameFontHighlightSmall")
  clearLink:SetText(L["Clear Recent"])
  clearLink:GetFontString():SetPoint("LEFT")
  UI.SetColor(clearLink:GetFontString(), GW.SIGNAL_BLUE)
  clearLink:SetScript("OnClick", function()
    local r = recent()
    for i = #r, 1, -1 do
      r[i] = nil
    end
    renderRecent()
  end)

  -- suggestions drop down over the Recent list
  -- the card's colour, but solid: the Blizzard look's cards are half see-through (the window's rock
  -- shows), and the Recent rows under the suggestions must not
  local c = T().card
  drop = UI.Flat(CreateFrame("Frame", nil, lookupCard), { c[1], c[2], c[3], 0.97 }, T().cardBorder)
  drop:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -2)
  drop:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -2)
  drop:SetFrameLevel((lookupCard:GetFrameLevel() or 1) + 20)
  drop.rows = {}
  for i = 1, SUGGEST do
    local row = itemRow(drop, w - 22, SUGGEST_H, 18)
    row:SetPoint("TOPLEFT", 2, -2 - (i - 1) * SUGGEST_H)
    drop.rows[i] = row
  end
  drop.note = UI.Text(drop, "GameFontDisableSmall", "faint", "LEFT")
  drop.note:SetWidth(w - 42)
  drop.note:SetText(L["Update Goldwright Data, then restart the game, to search every item."])
  drop:Hide()
end

---------------------------------------------------------------------------
-- the bottom card: compared with usual, other houses, buy
---------------------------------------------------------------------------
--- A label / value line: label on the left, value after it.
local function infoLine(parent, x, y, label)
  local l = UI.Text(parent, "GameFontHighlightSmall", "muted", "LEFT")
  l:SetPoint("TOPLEFT", x, y)
  l:SetText(label)
  local v = UI.Text(parent, "GameFontHighlightSmall", "text", "LEFT")
  v:SetPoint("TOPLEFT", x + 74, y)
  v:SetWidth(170)
  v:SetWordWrap(false)
  return v
end

local function buildBuyCard()
  buyCard = UI.Card(view)
  buyCard:SetPoint("TOPLEFT", MC.LIST_W + 14, -(6 + MC.HEIGHT + 8))
  buyCard:SetPoint("BOTTOMRIGHT", -6, 6)
  -- the Sell listing card's three columns, at the same widths, with the same lines between them
  local aW, bW = 262, 238
  for _, x in ipairs({ aW, aW + bW }) do
    local v = UI.Rule(buyCard)
    v:SetPoint("TOPLEFT", x, -1)
    v:SetPoint("BOTTOMLEFT", x, 1)
    v:SetWidth(1)
  end
  -- column 1: compared with usual
  cmp = {}
  UI.Caption(buyCard, L["Compared with usual"], 12, -10)
  cmp.chip = UI.Chip(buyCard)
  cmp.chip:SetPoint("TOPLEFT", 12, -32)
  cmp.beside = UI.Text(buyCard, "GameFontHighlightSmall", "muted", "LEFT")
  cmp.beside:SetPoint("LEFT", cmp.chip, "RIGHT", 8, 0)
  cmp.sells = infoLine(buyCard, 12, -58, L["Sells"])
  cmp.trend = infoLine(buyCard, 12, -76, L["Trend"])
  cmp.cheapest = infoLine(buyCard, 12, -94, L["Cheapest"])
  -- column 2: other houses, money in one column
  houses = {}
  local hx = aW + 12
  UI.Caption(buyCard, L["Other houses"], hx, -10)
  for i, side in ipairs(SIDES) do
    local name = UI.Text(buyCard, "GameFontHighlightSmall", "muted", "LEFT")
    name:SetPoint("TOPLEFT", hx, -32 - (i - 1) * 18)
    local price = UI.Text(buyCard, "GameFontHighlightSmall", "text", "RIGHT")
    price:SetPoint("TOPLEFT", aW + bW - 12 - 90, -32 - (i - 1) * 18)
    price:SetWidth(90)
    houses[side] = { name = name, price = price }
  end
  -- column 3: buying. Quantity and "Under normal", then Each and Total in one money column,
  -- "+ Shopping list", a status line and one button (Buy, then Confirm; Show for gear).
  buyCol = {}
  local cx = aW + bW + 12
  local cW = MC.WIDTH - cx - 12
  UI.Caption(buyCard, L["Buy"], cx, -10)
  local ql = UI.Text(buyCard, "GameFontNormalSmall", "label", "LEFT")
  ql:SetPoint("TOPLEFT", cx, -32)
  ql:SetText(L["Quantity"])
  buyCol.qty = UI.NewEditBox(buyCard)
  buyCol.qty:SetSize(56, 20)
  buyCol.qty:SetPoint("TOPLEFT", cx + 6, -48)
  buyCol.qty:SetAutoFocus(false)
  buyCol.qty:SetNumeric(true)
  buyCol.qty:SetMaxLetters(6)
  buyCol.qty:SetScript("OnTextChanged", function(_, user)
    if user then GW.BuyView.QuantityChanged() end
  end)
  buyCol.qty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  buyCol.under = UI.Button(buyCard, " ", 110, 20, function() GW.BuyView.FillUnderNormal() end)
  buyCol.under:SetPoint("LEFT", buyCol.qty, "RIGHT", 8, 0)
  local function moneyLine(y, label)
    local l = UI.Text(buyCard, "GameFontHighlightSmall", "muted", "LEFT")
    l:SetPoint("TOPLEFT", cx, y)
    l:SetText(label)
    local v = UI.Text(buyCard, "GameFontHighlightSmall", "text", "RIGHT")
    v:SetPoint("TOPLEFT", cx, y)
    v:SetWidth(cW)
    return v
  end
  buyCol.each = moneyLine(-76, L["Each"])
  buyCol.total = moneyLine(-94, L["Total"])
  buyCol.list = UI.Button(buyCard, L["+ Shopping List"], 120, 20, function() GW.BuyView.ToggleListMenu() end)
  buyCol.list:SetPoint("TOPLEFT", cx, -114)
  -- which list: every list (greyed when the item is on it already), then New List…
  local c = T().card
  local menu = UI.Flat(CreateFrame("Frame", nil, buyCard), { c[1], c[2], c[3], 0.97 }, T().cardBorder)
  menu:SetPoint("TOPLEFT", buyCol.list, "BOTTOMLEFT", 0, -2)
  menu:SetWidth(MENU_W)
  -- above the window's own border, which it may hang over (like Blizzard's dropdown menus)
  menu:SetFrameStrata("DIALOG")
  menu.rows = {}
  for i = 1, MENU_ROWS + 1 do
    local row = CreateFrame("Button", nil, menu)
    row:SetSize(MENU_W - 4, MENU_H)
    row:SetPoint("TOPLEFT", 2, -2 - (i - 1) * MENU_H)
    local lit = row:CreateTexture(nil, "HIGHLIGHT")
    lit:SetAllPoints()
    local hov = T().hover
    lit:SetColorTexture(hov[1], hov[2], hov[3], hov[4])
    row.name = UI.FontString(row, "GameFontHighlightSmall", "LEFT")
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(MENU_W - 20)
    row.name:SetWordWrap(false)
    row:SetScript("OnClick", function(self) GW.BuyView.AddToList(self.list) end)
    menu.rows[i] = row
  end
  menu:Hide()
  buyCol.menu = menu
  buyCol.status = UI.Text(buyCard, "GameFontHighlightSmall", "muted", "LEFT")
  buyCol.status:SetPoint("TOPLEFT", cx, -140)
  buyCol.status:SetWidth(cW)
  buyCol.button = UI.PrimaryButton(buyCard, L["Buy"], cW, 26, function() GW.BuyView.BuyClick() end)
  buyCol.button:SetPoint("BOTTOMLEFT", cx, 12)
end

--- Redraws the bottom card for the looked-up item: today's price against its 7-day normal (the
--- live cheapest listing at the auction house, else Goldwright's data), sales, trend, the cheapest
--- unusual listings, and the other houses.
function GW.BuyView.Render()
  if not buyCard then return end
  local st = current()
  local g = st.sel
  local side = MC.Side()
  local d = g and GW.ItemData(g.packKey)
  local here = d and d[side]
  local s = st.stats
  local price = (s and s.sorted[s.firstRealIndex] and s.sorted[s.firstRealIndex].price) or (here and here.min)
  -- with a quantity typed at the auction house: the average you'd pay for that many, cheapest first
  local plan = GW.BuyView.Plan()
  if plan and plan.units > 0 then price = plan.avg end
  local normal = here and (here.avg7 or here.avg30)
  -- the chip: how today's price compares with the item's own usual
  local kind, pct = GW.PriceCheck(price, normal)
  if not g then
    UI.SetChip(cmp.chip, nil)
    cmp.beside:SetText("")
  elseif not kind then
    UI.SetChip(cmp.chip, L["Not enough history"], "grey")
    cmp.beside:SetText("")
  else
    local under = price < normal
    local usual = pct <= USUAL_PCT
    UI.SetChip(
      cmp.chip,
      usual and L["About usual"] or (under and L["Cheaper than usual"] or L["Pricier than usual"]),
      usual and "grey" or (under and "blue" or "orange")
    )
    cmp.beside:SetText(
      pct == 0 and "" or string.format(under and L["%d%% below normal"] or L["%d%% above normal"], pct)
    )
  end
  cmp.sells:SetText(g and GW.SellRateText(here) or "–")
  local trend = "–"
  if here and here.avg7 and here.avg30 and here.avg30 > 0 then
    local t = math.floor((here.avg7 / here.avg30 - 1) * 100 + 0.5)
    if t ~= 0 then trend = string.format(L["Price %s%d%% this week"], t > 0 and "+" or "-", math.abs(t)) end
  end
  cmp.trend:SetText(g and trend or "–")
  local baitUnits = s and s.baitUnits or (here and here.baitUnits) or 0
  local baitPrice = s and s.baitPrice or (here and here.baitPrice)
  cmp.cheapest:SetText(
    g and baitUnits > 0 and baitPrice and string.format(L["%s at %s"], GW.Number(baitUnits), GW.Money(baitPrice))
      or "–"
  )
  -- other houses: each house's lowest price in one column; yours marked
  for _, h in ipairs(SIDES) do
    local x = d and d[h]
    local row = houses[h]
    row.name:SetText((h == side and "• " or "") .. GW.HOUSE_NAMES[h])
    UI.SetColor(row.name, h == side and T().gold or T().muted)
    -- your house at the auction house: the live cheapest listing, the same number as "Lowest now"
    local p = h == side and g and lowestOf(g.itemID) or (x and x.mv and (x.min or x.mv))
    row.price:SetText(p and GW.Money(p, true) or (g and L["none listed"] or "–"))
  end
  GW.BuyView.RenderBuy()
  if renderRecent then renderRecent() end
end

---------------------------------------------------------------------------
-- buying (#37 step 2): commodities with two clicks (Buy gets the exact price, Confirm buys), gear
-- shown in Blizzard's list, any item onto a shopping list. Never automatic.
---------------------------------------------------------------------------
--- The quantity typed (nil when empty or 0).
---@return number|nil
local function typedQty()
  local n = buyCol and tonumber(buyCol.qty:GetText() or "")
  return n and n > 0 and math.floor(n) or nil
end

--- What the typed quantity costs from the live listings, cheapest first (GW.BuyPlan); nil without a
--- quantity or a search.
---@return GoldwrightBuyPlan|nil
function GW.BuyView.Plan()
  local st = current()
  local q = typedQty()
  if not (q and st.mode == "buy" and st.stats) then return nil end
  return GW.BuyPlan(st.stats.sorted, nil, q)
end

--- How many are listed under the item's 7-day normal price, from the live listings.
---@return number|nil units nil without a search or a normal price
local function underNormal()
  local st = current()
  local g = st.sel
  local d = g and GW.ItemData(g.packKey)
  local here = d and d[MC.Side()]
  local normal = here and (here.avg7 or here.avg30)
  if not (st.stats and normal) then return nil end
  return GW.BuyPlan(st.stats.sorted, normal - 1).available
end

--- The Buy tab's purchase going on, if any (GW.Purchase handles one at a time for every tab).
---@return GoldwrightPurchase|nil
myBuy = function()
  local p = GW.Purchase.Current()
  return p and p.buyTab and p or nil
end

--- Lets the Buy tab's unconfirmed purchase go.
dropPending = function()
  local p = myBuy()
  if p then GW.Purchase.Cancel(p) end
end

--- Redraws the Buy column: away from the auction house everything waits for it; gear is bought
--- in Blizzard's list; commodities with Buy, then Confirm.
function GW.BuyView.RenderBuy()
  if not buyCol then return end
  local st = current()
  local g = st.sel
  local atAH = GW.AuctionHouseOpen and GW.AuctionHouseOpen()
  local gear = st.source == "item"
  local live = atAH and g and st.stats
  local plan = GW.BuyView.Plan()
  local pending = myBuy()
  local n = live and not gear and underNormal()
  buyCol.under:SetText(n and string.format(L["Under Normal: %s"], GW.Number(n)) or L["Under Normal"])
  buyCol.under:SetWidth(math.ceil(buyCol.under:GetFontString():GetStringWidth()) + 20)
  buyCol.under:SetEnabled(n and n > 0 or false)
  if live and not gear then
    buyCol.qty:Enable()
  else
    buyCol.qty:Disable()
  end
  buyCol.each:SetText(plan and plan.units > 0 and GW.Money(pending and pending.unit or plan.avg, true) or "–")
  buyCol.total:SetText(plan and plan.units > 0 and GW.Money(pending and pending.total or plan.total, true) or "–")
  buyCol.list:SetEnabled(g ~= nil)
  local b = buyCol.button
  if not atAH then
    b:SetText(L["Buy"])
    b:Disable()
    if not pending then buyCol.status:SetText(g and L["Buying needs the auction house."] or "") end
  elseif gear then
    b:SetText(L["Show"])
    b:SetEnabled(g ~= nil)
  elseif pending and pending.total and not pending.confirming then
    b:SetText(string.format(L["Confirm · %s"], GW.Money(pending.total)))
    b:SetEnabled(GW.Purchase.CanConfirm(pending))
  elseif pending then
    b:SetText(pending.confirming and L["Buying…"] or L["Getting Price…"])
    b:Disable()
  elseif plan and plan.units > 0 then
    b:SetText(string.format(L["Buy %d · %s"], plan.units, GW.Money(plan.total)))
    b:SetEnabled(GW.Purchase.Current() == nil)
  else
    b:SetText(L["Buy"])
    b:Disable()
  end
end

--- The quantity changed: a price quoted for another quantity is let go.
function GW.BuyView.QuantityChanged()
  local p = myBuy()
  if p and not p.confirming then
    dropPending()
    buyCol.status:SetText("")
  end
  GW.BuyView.Render()
end

--- Fills the quantity with how many are listed under the normal price.
function GW.BuyView.FillUnderNormal()
  local n = underNormal()
  if not (n and n > 0) then return end
  buyCol.qty:SetText(tostring(n))
  GW.BuyView.QuantityChanged()
end

--- Opens (or closes) the menu of shopping lists under "+ Shopping List". With no lists yet the item
--- goes straight onto a new "Shopping" list.
function GW.BuyView.ToggleListMenu()
  local menu, g = buyCol.menu, sel
  if menu:IsShown() or not g then return menu:Hide() end
  local lists = GW.Lists()
  if #lists == 0 then return GW.BuyView.AddToList() end
  local shown = math.min(#lists, MENU_ROWS)
  for i, row in ipairs(menu.rows) do
    local l = lists[i]
    if i <= shown then
      local has = GW.ListHas(l, g.itemID, g.name)
      row.list = l
      row.name:SetText(has and string.format(L["%s (has it)"], l.name) or l.name)
      UI.SetColor(row.name, has and T().faint or T().text)
      row:SetEnabled(not has)
      row:Show()
    elseif i == shown + 1 then
      row.list = "new"
      row.name:SetText(L["New List…"])
      UI.SetColor(row.name, GW.SIGNAL_BLUE)
      row:SetEnabled(true)
      row:Show()
    else
      row:Hide()
    end
  end
  menu:SetHeight((shown + 1) * MENU_H + 4)
  menu:Show()
end

--- Puts the item on a shopping list, its max price following the market price (100%).
---@param list? GoldwrightShoppingList|string the list picked, "new" to name a new one; none: the
--- selected list (or a new "Shopping" list when there is none)
function GW.BuyView.AddToList(list)
  local g = sel
  if not g then return end
  buyCol.menu:Hide()
  if list == "new" then
    return GW.AskNewList(function(l) GW.BuyView.AddToList(l) end)
  end
  local link = string.format("|cffffffff|Hitem:%d::::::::::::|h[%s]|h|r", g.itemID, g.name)
  local e, into = GW.AddToList(link, "100%", typedQty() and tostring(typedQty()) or "", list)
  buyCol.status:SetText(e and string.format(L["Added %s to %s."], g.name, into.name) or tostring(into))
end

--- Buy: asks the auction house for the exact price of the typed quantity; Confirm (the same
--- button, once the price is known) buys. Gear: Show puts it in Blizzard's list to buy there.
function GW.BuyView.BuyClick()
  local st = current()
  local g = st.sel
  if not (g and GW.AuctionHouseOpen and GW.AuctionHouseOpen()) then return end
  if InCombatLockdown and InCombatLockdown() then return buyCol.status:SetText(L["Not in combat."]) end
  if st.source == "item" then -- gear: Blizzard's list, as Shopping does
    if not GW.CanSearch() then return buyCol.status:SetText(L["Waiting for a search slot: try again in a moment."]) end
    GW.NoteSearch()
    C_AuctionHouse.SendBrowseQuery({
      searchString = g.name,
      sorts = GW.PriceSorts(),
      filters = {},
      itemClassFilters = {},
    })
    return buyCol.status:SetText(L["Shown in Blizzard's list on the left: buy it there."])
  end
  local b = myBuy()
  if b and b.confirming then return end -- never confirm twice
  if b and b.itemID == g.itemID and b.total then
    if GW.Purchase.Confirm(b) then buyCol.status:SetText(L["Buying…"]) end
    return GW.BuyView.RenderBuy()
  end
  local plan = GW.BuyView.Plan()
  if not (plan and plan.units > 0) then return end
  local p = GW.Purchase.Start({
    itemID = g.itemID,
    name = g.name,
    qty = plan.units,
    estimate = plan.total,
    buyTab = true,
    onChange = function(...) GW.BuyView.OnPurchase(...) end,
  })
  if not p then return end
  buyCol.status:SetText(L["Asking the auction house for the exact price…"])
  GW.BuyView.RenderBuy()
end

--- What the Buy tab says about its purchase (GW.Purchase's onChange): the exact price, with
--- warnings when it is more than shown or more gold than you have; the result; and what to do when
--- the answer didn't come. Messages that matter with the window closed also go to chat.
---@param b GoldwrightPurchase
---@param what string
---@param reason? string
function GW.BuyView.OnPurchase(b, what, reason)
  local say = function(text) buyCol.status:SetText(text) end
  local function sayAlways(text)
    say(text)
    if not (buyCard and buyCard:IsVisible()) or reason == "closed" then GW.Print("%s", text) end
  end
  if what == "quote" then
    if b.total and GetMoney and b.total > GetMoney() then
      say(string.format(L["Not enough gold for %s."], GW.Money(b.total)))
    elseif b.total and b.total > b.estimate then
      say(
        string.format(
          L["Exact price: %s, %s more than shown. Confirm only if you still want it."],
          GW.Money(b.total),
          GW.Money(b.total - b.estimate)
        )
      )
    else
      say(string.format(L["Exact price: %s for %s. Click Confirm to buy."], GW.Money(b.total), GW.Number(b.qty)))
    end
  elseif what == "noPrice" then
    say(L["No answer from the auction house. Nothing was bought."])
  elseif what == "expired" then
    say(L["The price wasn't confirmed in time. Nothing was bought: click Buy again."])
  elseif what == "unavailable" then
    say(L["Those listings are gone. Look the item up again."])
  elseif what == "bought" then
    sayAlways(string.format(L["Bought %d × %s for %s."], b.qty, b.name, GW.Money(b.total or b.estimate)))
    buyCol.qty:SetText("")
    -- see what's left
    C_Timer.After(0.5, function()
      local st = current()
      if st.mode == "buy" and st.sel and st.sel.itemID == b.itemID and buyCard:IsVisible() then
        GW.BuyView.LookUp(b.itemID)
      end
    end)
  elseif what == "failed" then
    sayAlways(L["The purchase failed. Nothing was bought."])
  elseif what == "unanswered" then
    sayAlways(
      string.format(
        reason == "closed"
            and L["The auction house closed before it answered about %d × %s. It may have been bought: check your mailbox before buying again."]
          or L["No answer from the auction house about %d × %s. It may have been bought: check your mailbox before buying again."],
        b.qty,
        b.name
      )
    )
  elseif what == "lateBought" then
    sayAlways(string.format(L["It went through after all: bought %d × %s."], b.qty, b.name))
  elseif what == "lateFailed" then
    sayAlways(string.format(L["The purchase of %d × %s failed. Nothing was bought."], b.qty, b.name))
  end
  GW.BuyView.RenderBuy()
end

---------------------------------------------------------------------------
-- the tab (SellPanel.lua's tab bar shows and hides it)
---------------------------------------------------------------------------
--- Shows the Buy tab inside `parent`, building it the first time, with the market card attached.
---@param parent table the window's content frame
function GW.BuyView.Show(parent)
  if not view then
    view = CreateFrame("Frame", nil, parent)
    view:SetAllPoints()
    buildLookup()
    buildBuyCard()
  end
  view:Show()
  MC.Attach(view, function() GW.BuyView.Render() end, MC.LIST_W + 14, MC.HEIGHT)
  if sel then
    MC.Show(sel, sel.count > 0 and GW.PluralCount(sel.count, "You have %s", "You have %s") or nil)
  else
    MC.Clear(L["Look up an item on the left to see its market."])
  end
  GW.ItemNames.Learn()
  renderSuggest()
  GW.BuyView.Render()
end

--- Hides the Buy tab; a price waiting for Confirm is let go (a confirmed purchase goes on).
function GW.BuyView.Hide()
  if not view then return end
  view:Hide()
  drop:Hide()
  buyCol.menu:Hide()
  dropPending()
end

--- Redraws the tab after a setting changed.
function GW.BuyView.Refresh()
  if not (view and view:IsShown()) then return end
  MC.Refresh()
  GW.BuyView.Render()
end

--- The auction house opened with the Buy tab showing: the item is searched again for its live
--- listings (and your bag count read again), and buying turns on.
function GW.BuyView.AuctionHouseOpened()
  if not (view and view:IsShown()) then return end
  if buyCol and not myBuy() then buyCol.status:SetText("") end -- "Buying needs the auction house." no more
  if sel then
    sel.count = itemCount(sel.itemID)
    showItem(sel)
  else
    GW.BuyView.Render()
  end
end

--- For tests: the lookup box, its suggestions and the cards.
function GW.BuyView.Debug()
  return {
    box = box,
    drop = drop,
    recent = recentRows,
    cmp = cmp,
    houses = houses,
    buy = buyCol,
    lookup = lookupCard,
    view = view,
  }
end
