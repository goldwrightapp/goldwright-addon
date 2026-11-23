--- The market card (SELL-3, 15, 16; goldwright-addon #37): one item's market, shown the same way on
--- the Sell and Buy tabs. One job: show an item's market and keep its live listings up to date.
--- Header (icon, name, a line from the tab), three numbers (Lowest now, Normal last 7 days, Sold per
--- day), the price history / best time chart (SellCharts.lua) and the cheapest listings. At the
--- auction house it searches the item's live listings once (throttle-aware, with timeouts); away from
--- it the card shows Goldwright's data.
---
--- There is one card: the tab on screen attaches it (Attach) with a listener, and hears when a search
--- starts ("started"), when listings arrive ("results") and when none came ("none"). The card knows
--- nothing about selling or buying.
local _, GW = ...
local L = GW.L
local UI = GW.UI

GW.MarketCard = {}
local MC = GW.MarketCard

local LADDER_ROWS, LADDER_H = 10, 18 -- cheapest listings
MC.LADDER_ROWS = LADDER_ROWS
-- The layout the Sell and Buy tabs share: their list (bags, lookup) on the left, this card top right.
MC.LIST_W = 252 -- the list's width
MC.HEIGHT = 300 -- this card's height; the tab's own card takes the rest below
MC.WIDTH = 1000 - 16 - MC.LIST_W - 20 -- this card's width in the 1000 px window

---@class GoldwrightMarketItem
---@field itemID number
---@field packKey number|string Goldwright Data key (a random suffix: "id:bonus")
---@field name string
---@field icon number|string|nil
---@field quality number|nil
---@field variant string|nil GW.LinkVariant: search results of other suffixes are left out (#25)
---@field itemKey table|nil the exact auction house item key (from a bag slot), else made from the id
---@field bag number|nil a bag slot holding it (the icon's tooltip), else the item's own tooltip
---@field slot number|nil

local card, f, T -- the card frame, its parts (also on `holder` for older code and tests), the look's colours
local m = { token = 0 } -- item, stats, key, source, searching, answered, token, listener

local setColor = UI.SetColor

--- The house the card is about: where you stand at the auction house, else your faction's.
---@return string side "A", "H" or "N"
function MC.Side() return GW.AuctionSide and GW.AuctionSide() or GW.House().side end

--- "~140" items sold per day (one decimal under 10), "–" when unknown.
---@param here table|nil
---@return string
function MC.PerDayText(here)
  local n = GW.SellRate(here)
  if not n then return "–" end
  return "~" .. (n >= 10 and GW.Number(math.floor(n + 0.5)) or GW.Decimal(n))
end

--- Goldwright Data's numbers for the item at the card's house, only when it is listed there now.
---@param item GoldwrightMarketItem|nil
---@return table|nil here
---@return table|nil data all houses (GW.ItemData)
local function packFor(item)
  local d = item and GW.ItemData(item.packKey or item.itemID)
  local here = d and d[MC.Side()]
  return here and here.mv and here or nil, d
end

--- Tells the tab on screen.
---@param what string "started", "results" or "none"
local function tell(what)
  if m.listener then m.listener(what) end
end

---------------------------------------------------------------------------
-- drawing
---------------------------------------------------------------------------
--- The note a cheapest-listings row carries (its tooltip and its colour).
---@param s table market stats
---@param i number row index
---@return string|nil note
---@return number[] color price colour
local function ladderNote(s, i)
  local x = s.sorted[i]
  if i < s.firstRealIndex then return L["likely bait, skipped"], T.faint end
  if x.own then return L["yours"], T.gold end
  if i == s.firstRealIndex then return L["cheapest real seller"], T.text end
  return nil, T.text
end

--- Redraws the numbers and the cheapest listings: Lowest now, Normal (last 7 days), Sold per day,
--- and the listings with their quantities and the total listed (#11).
function MC.Render()
  local item, s = m.item, m.stats
  if not (f and item) then return end
  local here = packFor(item)
  local lowest = (s and s.sorted[s.firstRealIndex].price) or (here and here.min)
  f.lowest:SetText(lowest and GW.Money(lowest) or "–")
  f.normal:SetText(here and here.avg7 and GW.Money(here.avg7) or "–")
  f.perDay:SetText(MC.PerDayText(here))
  -- what the number counts, and whether it is an estimate (gear: listings gone early)
  local n, proven = GW.SellRate(here)
  f.perDayHit.tip = not n and { L["No sales data for this item yet."] }
    or {
      string.format(L["Items bought per day at %s, average of the last 10 days."], GW.HOUSE_NAMES[MC.Side()]),
      not proven and L["Estimate: counts listings that went early, so some may have been cancelled."] or nil,
    }
  local maxQty, total = 1, 0
  if s then
    for i, x in ipairs(s.sorted) do
      total = total + x.qty
      if i <= LADDER_ROWS and x.qty > maxQty then maxQty = x.qty end
    end
  end
  for i, r in ipairs(f.ladder) do
    local x = s and s.sorted[i]
    if x then
      local note, color = ladderNote(s, i)
      r.note = note
      r.price:SetText(GW.Money(x.price, true))
      setColor(r.price, color)
      r.qty:SetText(GW.Number(x.qty))
      UI.SetBar(r.bar, x.qty / maxQty)
      r:Show()
    else
      r.note = nil
      r:Hide()
    end
  end
  f.listTotal:SetText(s and GW.PluralCount(total, "%s listed", "%s listed") or "")
end

--- Redraws the numbers and the charts (after a setting changed).
function MC.Refresh()
  if not m.item then return end
  MC.Render()
  GW.SellCharts.Render(m.item.packKey, m.item.name)
end

---------------------------------------------------------------------------
-- live listings
---------------------------------------------------------------------------
--- Listings for an item from the last search, commodity results first, else item results.
--- Shared with the My Auctions tab.
---@param itemID number
---@param itemKey table? item key for item (non-commodity) results
---@param variant string? GW.LinkVariant of the item being priced: item rows of another random suffix
--- are left out. A search (Blizzard's Sell window's above all) can return every suffix of the item,
--- and they share one item id (goldwright-addon #25). "" or nil keeps every row.
---@return { price: number, qty: number, own: boolean?, ownQty: number? }[] list price is per unit
---@return string|nil source "commodity", "item" or nil when empty
---@return number commodityCount number of commodity results the client reported
---@return number itemCount number of item results the client reported
function GW.CollectSearchResults(itemID, itemKey, variant)
  local list = {}
  local nc = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  for i = 1, nc do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if r then
      local ownQty = r.numOwnerItems or 0
      list[#list + 1] = {
        price = r.unitPrice,
        qty = r.quantity,
        own = r.containsOwnerItem or ownQty > 0,
        ownQty = ownQty > 0 and ownQty or nil,
      }
    end
  end
  if #list > 0 then return list, "commodity", nc, 0 end
  -- Item (non-commodity) results group identical auctions into one row: `quantity` is how many
  -- there are and `buyoutAmount` the price of each, not of the row (goldwright-addon #5: dividing
  -- by the count turned 31 Expert Cookbooks at 94s 99c into "3s 6c each"). Only an item that
  -- stacks would carry a whole-stack buyout; on this auction house those are commodities.
  local ni = itemKey and (C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0) or 0
  local stacks = itemKey and GW.MaxStack and (GW.MaxStack(itemKey.itemID) or 1) > 1
  local other = 0
  for i = 1, ni do
    local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if r and r.buyoutAmount and (r.quantity or 0) > 0 then
      local rv = variant and variant ~= "" and r.itemLink and GW.LinkVariant(r.itemLink)
      if rv and rv ~= variant then
        other = other + r.quantity -- another suffix of the item
      else
        local each = stacks and math.floor(r.buyoutAmount / r.quantity + 0.5) or r.buyoutAmount
        list[#list + 1] = { price = each, qty = r.quantity, own = r.containsOwnerItem }
      end
    end
  end
  if other > 0 then GW.Log("left out %d listings of other suffixes (item %s, %s)", other, tostring(itemID), variant) end
  return list, #list > 0 and "item" or nil, nc, ni
end

--- Reads the item's search results into the card's stats and tells the tab. An empty result while
--- the search is still running is ignored (no answer yet).
---@param itemKeyFromEvent table? the item key an item-results event carried
---@param eventName string? for the log
local function readResults(itemKeyFromEvent, eventName)
  local item = m.item
  if not item then return end
  local list, source, nc, ni = GW.CollectSearchResults(item.itemID, itemKeyFromEvent or m.key, item.variant)
  m.source = source
  GW.Log(
    "%s for %s: %d listings (%s; commodity n=%s, item n=%s)",
    eventName or "read",
    item.name,
    #list,
    tostring(source),
    tostring(nc),
    tostring(ni)
  )
  if eventName and not eventName:find("^timeout") then m.answered = true end
  if #list == 0 and m.searching then return end
  m.searching = false
  local recent = GW.RecentPrice(item.packKey, MC.Side())
  m.stats = GW.MarketStats(list, recent)
  GW.SellCharts.Listings(item.packKey, m.stats) -- the Market window's Supply tab
  GW.NoteBaitSearch(item.itemID, item.name, MC.Side(), m.stats, recent)
  f.listStatus:SetText(m.stats and L["searched just now"] or L["no other listings"])
  MC.Render()
  tell("results")
end

--- Sends a search for the card's item key, sorted by price; counts it against the search limit.
---@param kind string "sell" for SendSellSearchQuery, anything else for SendSearchQuery
local function sendQuery(kind)
  local sorts = GW.PriceSorts()
  GW.NoteSearch()
  if kind == "sell" then
    C_AuctionHouse.SendSellSearchQuery(m.key, sorts, true)
  else
    C_AuctionHouse.SendSearchQuery(m.key, sorts, true)
  end
  GW.Log("sent %s search for %s (itemID %d)", kind, m.item.name, m.item.itemID)
end

--- Searches the live listings for the card's item, waiting for the search throttle if needed. Shows
--- Goldwright's data until the answer arrives; gives up after 8 seconds.
local search
search = function()
  local item = m.item
  m.key = item.itemKey or C_AuctionHouse.MakeItemKey(item.itemID)
  GW.Log(
    "item key for %s: id %s, level %s, suffix %s",
    item.name,
    tostring(m.key.itemID),
    tostring(m.key.itemLevel),
    tostring(m.key.itemSuffix)
  )
  m.stats, m.searching, m.answered = nil, true, false
  m.token = m.token + 1
  local token = m.token
  MC.Render()
  tell("started")
  if not GW.CanSearch() then
    -- throttled: wait for a slot instead of firing anyway (§3.5)
    f.listStatus:SetText(GW.WaitText())
    GW.Log("search waiting: %s", tostring(GW.SearchBlocked()))
    C_Timer.After(GW.SEARCH_RETRY, function()
      if m.token == token and m.item == item and card:IsVisible() then search() end
    end)
    return
  end
  f.listStatus:SetText(L["searching…"])
  -- The normal search answers within a second on Forever; the sell search never answered in game
  -- (log 2026-11-10: every sell search timed out, the general one then answered at once), so the
  -- sell search is only the fallback after 4 seconds.
  sendQuery("general")
  C_Timer.After(4, function()
    if m.token ~= token or not m.searching then return end
    readResults(nil, "timeout-4s")
    if m.searching and GW.CanSearch() then sendQuery("sell") end
  end)
  C_Timer.After(8, function()
    if m.token ~= token or not m.searching then return end
    m.searching = false
    readResults(nil, "timeout-8s")
    if not m.stats then
      -- The auction house did answer, with nothing: none listed here (e.g. at Blackwater).
      f.listStatus:SetText(
        m.answered and string.format(L["none listed at %s right now"], GW.HOUSE_NAMES[MC.Side()])
          or L["no answer from the auction house"]
      )
      tell("none")
    end
  end)
end

---------------------------------------------------------------------------
-- what a tab uses
---------------------------------------------------------------------------
--- Shows an item: header, numbers, charts; at the auction house its live listings.
---@param item GoldwrightMarketItem
---@param info string|nil the line under the name (the tab's: "You have 2 · …")
function MC.Show(item, info)
  m.item, m.stats, m.source, m.searching = item, nil, nil, false
  m.token = m.token + 1 -- a search still on its way for another item is dropped
  f.iconButton.tex:SetTexture(item.icon or 134400)
  f.itemName:SetText(item.name)
  setColor(f.itemName, UI.QualityColor(item.quality))
  f.itemInfo:SetText(info or "")
  f.col2:Show()
  f.empty:Hide()
  GW.SellCharts.Render(item.packKey, item.name)
  if GW.AuctionHouseOpen and GW.AuctionHouseOpen() then
    search()
  else
    MC.Render()
    f.listStatus:SetText(L["Listings show at the auction house."])
  end
end

--- Shows nothing: the card's message in its place.
---@param message string
function MC.Clear(message)
  m.item, m.stats, m.source, m.searching = nil, nil, nil, false
  m.token = m.token + 1
  f.col2:Hide()
  f.empty:SetText(message or "")
  f.empty:Show()
end

--- Stops waiting for a search (its timers do nothing more): posting started.
function MC.StopSearch()
  m.token = m.token + 1
  m.searching = false
end

---@return GoldwrightMarketItem|nil
function MC.Item() return m.item end
---@return GoldwrightMarketStats|nil stats the live listings from the last search
function MC.Stats() return m.stats end
---@return boolean searching a search is on its way
function MC.Searching() return m.searching end
---@return string|nil source "commodity" or "item" once listings arrived
function MC.Source() return m.source end
---@return boolean answered the auction house answered the last search
function MC.Answered() return m.answered end
---@return table|nil key the item key of the last search
function MC.Key() return m.key end

--- Puts the card on a tab's view, in the place right of the 252 px list, and listens for it.
---@param view table the tab's content frame
---@param listener fun(what: string)|nil
---@param left number x of the card (right of the tab's list)
---@param height number card height
function MC.Attach(view, listener, left, height)
  card:SetParent(view)
  card:ClearAllPoints()
  card:SetPoint("TOPLEFT", left, -6)
  card:SetPoint("TOPRIGHT", -6, -6)
  card:SetHeight(height)
  card:Show()
  m.listener = listener
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------
--- Builds the card once. Its parts are also put on `holder` (the Goldwright window) under the names
--- older code and the tests use (panel.lowest, panel.listStatus, …).
---@param parent table
---@param holder table
---@param width number the card's width
---@param height number the card's height
---@return table card
function MC.Build(parent, holder, width, height)
  T = UI.Tokens()
  card = UI.Card(parent)
  f = holder
  local col2 = CreateFrame("Frame", nil, card)
  col2:SetAllPoints()
  f.col2 = col2
  local split = width - 238 -- chart | cheapest listings

  f.iconButton = CreateFrame("Button", nil, col2)
  f.iconButton:SetSize(36, 36)
  f.iconButton:SetPoint("TOPLEFT", 12, -11)
  f.iconButton.tex = f.iconButton:CreateTexture(nil, "ARTWORK")
  f.iconButton.tex:SetAllPoints()
  f.iconButton.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  f.iconButton:SetScript("OnEnter", function(self)
    local item = m.item
    if not item then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if item.bag then
      GameTooltip:SetBagItem(item.bag, item.slot)
    else
      GameTooltip:SetItemByID(item.itemID)
    end
    GameTooltip:Show()
  end)
  f.iconButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.itemName = UI.FontString(col2, "GameFontNormalLarge", "LEFT")
  f.itemName:SetPoint("TOPLEFT", 58, -12)
  f.itemName:SetWidth(300)
  f.itemName:SetWordWrap(false)
  f.itemInfo = UI.Text(col2, "GameFontHighlightSmall", "muted", "LEFT")
  f.itemInfo:SetPoint("TOPLEFT", 58, -32)

  -- three numbers, each a label over one big value
  local stats = {
    { L["Lowest now"], "lowest", 100 },
    { L["Normal, last 7 days"], "normal", 124 },
    { L["Sold per day"], "perDay", 84 },
  }
  local x = width - 12
  for i = #stats, 1, -1 do
    local s = stats[i]
    x = x - s[3]
    local lab = UI.Text(col2, "GameFontNormalSmall", "label", "LEFT")
    lab:SetPoint("TOPLEFT", x, -12)
    lab:SetText(s[1])
    local val = UI.Text(col2, "GameFontHighlightLarge", "text", "LEFT")
    val:SetPoint("TOPLEFT", x, -28)
    f[s[2]] = val
    x = x - 8
  end
  -- hovering Sold per day says what it counts (MC.Render fills .tip)
  local hit = CreateFrame("Frame", nil, col2)
  hit:SetPoint("TOPLEFT", f.perDay, "TOPLEFT", 0, 18)
  hit:SetSize(84, 44)
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", function(self)
    if not self.tip then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(L["Sold per day"], 1, 1, 1)
    for _, line in ipairs(self.tip) do
      GameTooltip:AddLine(line, nil, nil, nil, true)
    end
    GameTooltip:Show()
  end)
  hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.perDayHit = hit
  local rule = UI.Rule(col2)
  rule:SetPoint("TOPLEFT", 1, -58)
  rule:SetPoint("TOPRIGHT", -1, -58)
  rule:SetHeight(1)
  local v = UI.Rule(col2)
  v:SetPoint("TOPLEFT", split, -58)
  v:SetPoint("BOTTOMLEFT", split, 1)
  v:SetWidth(1)

  -- the chart: price history or best time to post (SellCharts.lua)
  GW.SellCharts.Create(col2, { x = 12, y = -68, w = split - 24, h = height - 68 - 6 })
  f.charts = GW.SellCharts

  -- cheapest listings: price each | quantity bar | quantity
  local lx = split + 12
  local lw = width - lx - 12
  UI.Caption(col2, L["Cheapest listings"], lx, -71)
  f.ladder = {}
  for i = 1, LADDER_ROWS do
    local r = CreateFrame("Frame", nil, col2)
    r:SetSize(lw, LADDER_H)
    r:SetPoint("TOPLEFT", lx, -92 - (i - 1) * LADDER_H)
    r:EnableMouse(true)
    local line = UI.Rule(r, "rowLine")
    line:SetPoint("TOPLEFT")
    line:SetPoint("TOPRIGHT")
    line:SetHeight(1)
    r.price = UI.FontString(r, "GameFontHighlightSmall", "RIGHT")
    r.price:SetPoint("LEFT", 0, 0)
    r.price:SetWidth(78)
    r.bar = UI.Bar(r, lw - 78 - 8 - 40, 6)
    r.bar:SetPoint("LEFT", 86, 0)
    r.qty = UI.Text(r, "GameFontHighlightSmall", "muted", "RIGHT")
    r.qty:SetPoint("RIGHT", 0, 0)
    r.qty:SetWidth(38)
    r:SetScript("OnEnter", function(self)
      if not self.note then return end
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetText(self.note)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:Hide()
    f.ladder[i] = r
  end
  local y = -92 - LADDER_ROWS * LADDER_H - 6
  f.listTotal = UI.Text(col2, "GameFontHighlightSmall", "muted", "LEFT")
  f.listTotal:SetPoint("TOPLEFT", lx, y)
  f.listStatus = UI.Text(col2, "GameFontDisableSmall", "faint", "RIGHT")
  f.listStatus:SetPoint("TOPRIGHT", col2, "TOPLEFT", lx + lw, y)
  -- the message when nothing is shown
  f.empty = UI.Text(card, "GameFontHighlight", "muted", "CENTER")
  f.empty:SetPoint("CENTER")
  f.empty:SetWidth(500)
  col2:Hide()
  return card
end

-- Search results for the card's item. Another tab's search (My Auctions) isn't ours: only while the
-- card is on screen with an item.
local ev = CreateFrame("Frame")
for _, e in ipairs({
  "COMMODITY_SEARCH_RESULTS_UPDATED",
  "COMMODITY_SEARCH_RESULTS_ADDED",
  "COMMODITY_SEARCH_RESULTS_RECEIVED",
  "ITEM_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_ADDED",
}) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, arg1)
  if not (card and card:IsVisible() and m.item) then return end
  local argItem = type(arg1) == "table" and arg1.itemID or arg1
  GW.Log("event %s (item %s)", event, tostring(argItem))
  -- An item search for another suffix of the same item (Blizzard's Browse tab) isn't ours (#25).
  -- Only when both name a suffix: a search for every suffix is sorted out row by row (GW.CollectSearchResults).
  local theirs, ours = type(arg1) == "table" and arg1.itemSuffix or 0, m.key and m.key.itemSuffix or 0
  if theirs ~= 0 and ours ~= 0 and theirs ~= ours then
    GW.Log("ignored %s: suffix %s, ours %s", event, tostring(arg1.itemSuffix), tostring(m.key.itemSuffix))
  elseif argItem == nil or argItem == m.item.itemID then
    readResults(type(arg1) == "table" and arg1 or nil, event)
  end
end)
