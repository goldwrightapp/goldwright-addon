-- Shopping lists (requirements SHOP-1..7). Lists live in GoldwrightDB.lists (account-wide, so every
-- character sees them). Running a list sends one search per entry (throttle-aware, with progress).
-- Commodities: the result says how many are under your max and what buying your wanted quantity
-- costs; Buy asks the auction house for the exact price (StartCommoditiesPurchase) and a second click
-- confirms (ConfirmCommoditiesPurchase): one purchase per click pair, never automatic.
-- Gear: Show sends a browse search so Blizzard's own Buy list shows the item; you buy it there.
local _, GW = ...

local ROWS, ROW_H = 10, 30
local LIST_ROWS = 11
local SEARCH_TIMEOUT = 6
local BUY_TIMEOUT = 12
local GREY = { 0.70, 0.70, 0.72 }
local WHITE = { 1, 1, 1 }

---------------------------------------------------------------------------
-- rules without UI (tested in server/test/addon.test.mjs)
---------------------------------------------------------------------------
-- "1g 2s 3c", "75c", "1s50c", "150" (copper) or "80%" (of market). Returns copper, pct.
function GW.ParseMoney(text)
  text = strtrim(text or ""):lower()
  if text == "" then return nil, nil end
  local pct = text:match("^(%d+)%s*%%$")
  if pct then return nil, tonumber(pct) end
  if text:match("^%d+$") then return tonumber(text), nil end
  local total, found = 0, false
  for num, unit in text:gmatch("(%d+)%s*([gsc])") do
    found = true
    total = total + tonumber(num) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
  end
  local rest = text:gsub("%d+%s*[gsc]", ""):gsub("%s+", "")
  if not found or rest ~= "" then return nil, nil end
  return total, nil
end

-- Item id and name from an item link, or nil.
function GW.LinkItem(text)
  local id = text and tonumber(text:match("item:(%d+)"))
  if not id then return nil end
  return id, text:match("%[(.-)%]")
end

function GW.Lists()
  GoldwrightDB.lists = GoldwrightDB.lists or {}
  return GoldwrightDB.lists
end

-- A new entry from what the player typed or shift-clicked. Returns entry or nil, error.
function GW.MakeEntry(itemText, maxText, wantText)
  itemText = strtrim(itemText or "")
  if itemText == "" then return nil, "Type an item name or Shift-click an item." end
  local id, name = GW.LinkItem(itemText)
  if not id then
    name = itemText:gsub('^"(.*)"$', "%1")
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local _, link = getInfo and getInfo(name)
    id = link and GW.LinkItem(link)
  end
  local e = { name = name or ("item " .. id), itemID = id }
  if strtrim(maxText or "") ~= "" then
    e.max, e.maxPct = GW.ParseMoney(maxText)
    if not e.max and not e.maxPct then return nil, "Max price: e.g. 75c, 1s 50c, 2g or 80% (of market)." end
  end
  if strtrim(wantText or "") ~= "" then
    e.want = tonumber(wantText)
    if not e.want or e.want < 1 then return nil, "Want: a number of items." end
  end
  return e
end

-- Export: one list per line, "Name^Item;id=2840;max=75;qty=20^Other Item". Import also takes
-- Auctionator-style terms ("Name"; extra fields after ';' are ignored unless they are ours).
local function clean(s) return (s:gsub("[%^;\n]", " ")) end
function GW.ExportLists(lists)
  local lines = {}
  for _, l in ipairs(lists) do
    local parts = { clean(l.name) }
    for _, e in ipairs(l.entries) do
      local t = { clean(e.name) }
      if e.itemID then t[#t + 1] = "id=" .. e.itemID end
      if e.max then t[#t + 1] = "max=" .. e.max end
      if e.maxPct then t[#t + 1] = "max=" .. e.maxPct .. "%" end
      if e.want then t[#t + 1] = "qty=" .. e.want end
      parts[#parts + 1] = table.concat(t, ";")
    end
    lines[#lines + 1] = table.concat(parts, "^")
  end
  return table.concat(lines, "\n")
end

function GW.ImportLists(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local pieces = {}
    for p in (line .. "^"):gmatch("(.-)%^") do pieces[#pieces + 1] = p end
    local name = strtrim(pieces[1] or "")
    if name ~= "" and #pieces > 1 then
      local list = { name = name, entries = {} }
      for i = 2, #pieces do
        local fields = {}
        for f in (pieces[i] .. ";"):gmatch("(.-);") do fields[#fields + 1] = f end
        local item = strtrim(fields[1] or ""):gsub('^"(.*)"$', "%1")
        if item ~= "" then
          local e = { name = item }
          for j = 2, #fields do
            local k, v = fields[j]:match("^%s*(%a+)=(.-)%s*$")
            if k == "id" then e.itemID = tonumber(v)
            elseif k == "qty" then e.want = tonumber(v)
            elseif k == "max" then e.max, e.maxPct = GW.ParseMoney(v) end
          end
          list.entries[#list.entries + 1] = e
        end
      end
      out[#out + 1] = list
    end
  end
  return out
end

-- What buying looks like from a commodity's listings (yours excluded): the cheapest price, how many
-- are at or under `max` (all when nil), and the cost of the cheapest `want` of those.
function GW.BuyPlan(listings, max, want)
  local l = {}
  for _, x in ipairs(listings or {}) do
    local q = (x.qty or 0) - (x.own and (x.ownQty or x.qty) or 0)
    if q > 0 and x.price and x.price > 0 then l[#l + 1] = { price = x.price, qty = q } end
  end
  table.sort(l, function(a, b) return a.price < b.price end)
  local plan = { cheapest = l[1] and l[1].price, listed = 0, available = 0, units = 0, total = 0 }
  for _, x in ipairs(l) do
    plan.listed = plan.listed + x.qty
    if not max or x.price <= max then
      plan.available = plan.available + x.qty
      local take = want and math.min(x.qty, want - plan.units) or x.qty
      if take > 0 then
        plan.units = plan.units + take
        plan.total = plan.total + take * x.price
      end
    end
  end
  plan.avg = plan.units > 0 and math.floor(plan.total / plan.units + 0.5) or nil
  return plan
end

-- Market value of an item at your house (scan or data pack; 7-day normal as fallback).
local function market(id)
  local d = id and GW.ItemData(id)
  local h = GW.house or GW.DetectHouse()
  local s = d and d[h.side]
  return s and (s.mv or s.avg7 or s.avg30) or nil
end
function GW.EntryMax(e)
  if e.max then return e.max end
  if e.maxPct then
    local m = market(e.itemID)
    return m and math.floor(m * e.maxPct / 100) or nil
  end
  return nil
end

-- "20% under market" / "at market" / "35% over market" (or nil without a market value).
function GW.MarketText(price, id)
  local m = market(id)
  if not (m and m > 0 and price) then return nil end
  local pct = math.floor((price / m - 1) * 100 + 0.5)
  if math.abs(pct) < 3 then return "at market", GREY end
  if pct < 0 then return -pct .. "% under market", pct <= -GW.Opt("signalPct") and GW.SIGNAL_BLUE or GREY end
  return pct .. "% over market", pct >= GW.Opt("signalPct") and GW.SIGNAL_ORANGE or GREY
end

---------------------------------------------------------------------------
-- running a list
---------------------------------------------------------------------------
local view
local sv = { results = {}, queue = {}, checked = 0, total = 0, bought = {} }
local render

local function current() return sv.current end

local function selectedList()
  local lists = GW.Lists()
  local i = GoldwrightDB.listSel or 1
  if not lists[i] then i = #lists > 0 and 1 or nil end
  GoldwrightDB.listSel = i
  return i and lists[i], i
end

local function sorts() return { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } } end

local runNext

local function finishEntry(e, result)
  if sv.current ~= e then return end
  result.at = GetTime()
  sv.results[e] = result
  sv.current, sv.token = nil, nil
  sv.checked = sv.checked + 1
  if render then render() end
  C_Timer.After(0.1, runNext)
end

local function send(e, purpose)
  local token = {}
  sv.token, sv.purpose = token, purpose
  GW.NoteSearch()
  if purpose == "search" then
    C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(e.itemID), sorts(), true)
  else
    C_AuctionHouse.SendBrowseQuery({ searchString = e.name, sorts = sorts(), filters = {}, itemClassFilters = {} })
  end
  GW.Log("shopping %s for %s (id %s)", purpose, e.name, tostring(e.itemID))
  C_Timer.After(SEARCH_TIMEOUT, function()
    if sv.token == token and sv.current == e then
      if purpose == "search" and #GW.CollectSearchResults(e.itemID, C_AuctionHouse.MakeItemKey(e.itemID)) == 0 then
        -- an item search with no answer: try the browse search (random-suffix gear answers there)
        if GW.CanSearch() then return send(e, "browse") end
      end
      finishEntry(e, { kind = "unknown" })
    end
  end)
end

runNext = function()
  if sv.current then return end
  local e = sv.queue[1]
  if not e then
    sv.running = false
    if render then render() end
    return
  end
  if not GW.CanSearch() then
    sv.waiting = true
    if render then render() end
    C_Timer.After(2, runNext)
    return
  end
  sv.waiting = false
  table.remove(sv.queue, 1)
  sv.current = e
  send(e, e.itemID and "search" or "browse")
  if render then render() end
end

-- SHOP-3: run the selected list (or one entry).
function GW.RunList(only)
  if not (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) then return GW.Print("Open the auction house first.") end
  local list = selectedList()
  if not list then return end
  sv.queue, sv.checked, sv.current, sv.token = {}, 0, nil, nil
  for _, e in ipairs(list.entries) do
    if not only or only == e then
      sv.queue[#sv.queue + 1] = e
      sv.results[e] = nil
    end
  end
  sv.total, sv.running = #sv.queue, true
  if render then render() end
  runNext()
end

-- Check one entry now (just added, or just bought): joins a running list, or runs alone.
function GW.CheckEntry(e)
  if not (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) then return end
  sv.results[e] = nil
  if sv.running then
    for _, q in ipairs(sv.queue) do if q == e then return end end
    if sv.current == e then return end
    sv.queue[#sv.queue + 1] = e
    sv.total = sv.total + 1
  else
    sv.queue, sv.checked, sv.total, sv.running = { e }, 0, 1, true
  end
  if render then render() end
  runNext()
end

function GW.StopList()
  sv.queue, sv.running, sv.current, sv.token, sv.waiting = {}, false, nil, nil, false
  if render then render() end
end

-- Browse results: pick the ones for this entry (by item id, or by exact name when we have no id).
local function browseMatches(e)
  local out = {}
  local results = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults() or {}
  local want = e.name:lower()
  for _, r in ipairs(results) do
    local id = r.itemKey and r.itemKey.itemID
    local name
    if not e.itemID and id then
      local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(r.itemKey)
      name = (info and info.itemName) or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
    end
    if (e.itemID and id == e.itemID) or (name and name:lower() == want) then out[#out + 1] = r end
  end
  return out
end

local function onSearchResults(event, arg1)
  local e = current()
  if not (e and e.itemID) then return end
  if event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "COMMODITY_SEARCH_RESULTS_ADDED" then
    if arg1 ~= e.itemID then return end
    local list = GW.CollectSearchResults(e.itemID)
    if #list == 0 then return end
    local plan = GW.BuyPlan(list, GW.EntryMax(e), e.want and math.max(0, e.want - (sv.bought[e] or 0)) or nil)
    finishEntry(e, { kind = "commodity", plan = plan })
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED" then
    if not (type(arg1) == "table" and arg1.itemID == e.itemID) then return end
    local list = GW.CollectSearchResults(e.itemID, arg1)
    if #list == 0 then
      if sv.purpose == "search" and GW.CanSearch() then send(e, "browse") end -- suffix gear: browse instead
      return
    end
    finishEntry(e, { kind = "item", plan = GW.BuyPlan(list, GW.EntryMax(e)) })
  end
end

local function onBrowseResults()
  local e = current()
  if not (e and sv.purpose == "browse") then return end
  local m = browseMatches(e)
  if #m == 0 then
    finishEntry(e, { kind = e.itemID and "none" or "notfound" })
    return
  end
  if not e.itemID then
    -- found it by name: remember the id, then search it properly
    e.itemID = m[1].itemKey.itemID
    sv.current = nil
    table.insert(sv.queue, 1, e)
    C_Timer.After(0.1, runNext)
    return
  end
  local cheapest, listed = nil, 0
  for _, r in ipairs(m) do
    listed = listed + (r.totalQuantity or 0)
    if r.minPrice and r.minPrice > 0 and (not cheapest or r.minPrice < cheapest) then cheapest = r.minPrice end
  end
  local max = GW.EntryMax(e)
  finishEntry(e, { kind = "item", plan = { cheapest = cheapest, listed = listed, available = (not max or (cheapest and cheapest <= max)) and listed or 0, units = 0, total = 0 }, variants = #m })
end

---------------------------------------------------------------------------
-- buying commodities (SHOP-5): Buy gets the exact price, Confirm buys
---------------------------------------------------------------------------
local function toast(text, color)
  if not view then return end
  view.toast:SetText(text or "")
  local c = color or WHITE
  view.toast:SetTextColor(c[1], c[2], c[3])
end

local function cancelBuy()
  if sv.buy and C_AuctionHouse.CancelCommoditiesPurchase then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
  sv.buy = nil
end

local function buyClick(e)
  local res = sv.results[e]
  local b = sv.buy
  if InCombatLockdown and InCombatLockdown() then return toast("Not in combat.", GW.SIGNAL_ORANGE) end
  if b and b.entry == e and b.total then
    -- second click: confirm at the quoted price
    b.confirming = true
    C_AuctionHouse.ConfirmCommoditiesPurchase(e.itemID, b.qty)
    GW.Log("shopping confirm: %d x %s for %d", b.qty, e.name, b.total)
    toast("Buying…", GREY)
    if render then render() end
    return
  end
  if not (res and res.kind == "commodity" and res.plan.units > 0) then return end
  cancelBuy()
  local qty = res.plan.units
  sv.buy = { entry = e, qty = qty, estimate = res.plan.total, at = GetTime() }
  local token = sv.buy
  C_AuctionHouse.StartCommoditiesPurchase(e.itemID, qty)
  GW.Log("shopping buy start: %d x %s (estimate %d)", qty, e.name, res.plan.total)
  toast("Asking the auction house for the exact price…", GREY)
  if render then render() end
  C_Timer.After(BUY_TIMEOUT, function()
    if sv.buy == token and not token.done then
      cancelBuy()
      toast("No answer from the auction house. Nothing was bought.", GW.SIGNAL_ORANGE)
      if render then render() end
    end
  end)
end

local function showInBuyTab(e)
  if not GW.CanSearch() then return toast("Waiting for a search slot: try again in a moment.", GW.SIGNAL_ORANGE) end
  GW.NoteSearch()
  C_AuctionHouse.SendBrowseQuery({ searchString = e.name, sorts = sorts(), filters = {}, itemClassFilters = {} })
  toast("Shown in Blizzard's list on the left: buy it there.", GREY)
end

local function onBuyEvent(event, a1, a2)
  local b = sv.buy
  if not b then return end
  local e = b.entry
  if event == "COMMODITY_PRICE_UPDATED" then
    b.unit, b.total = a1, a2
    local max = GW.EntryMax(e)
    if max and b.unit and b.unit > max then
      toast(string.format("The price went up: %s each is over your max (%s). Confirm only if you still want it.", GW.Money(b.unit), GW.Money(max)), GW.SIGNAL_ORANGE)
    elseif b.total and GetMoney and b.total > GetMoney() then
      toast("Not enough gold for " .. GW.Money(b.total) .. ".", GW.SIGNAL_ORANGE)
    else
      toast(string.format("%d × %s for %s (%s each). Click Confirm to buy.", b.qty, e.name, GW.Money(b.total), GW.Money(b.unit)), WHITE)
    end
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
    sv.buy = nil
    toast("Those listings are gone. Run the list again.", GW.SIGNAL_ORANGE)
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
    b.done = true
    sv.bought[e] = (sv.bought[e] or 0) + b.qty
    toast(string.format("Bought %d × %s for %s.", b.qty, e.name, GW.Money(b.total or b.estimate)), GW.SIGNAL_BLUE)
    sv.buy = nil
    sv.results[e] = nil
    C_Timer.After(0.5, function() GW.CheckEntry(e) end) -- see what's left
  elseif event == "COMMODITY_PURCHASE_FAILED" then
    sv.buy = nil
    toast("The purchase failed. Nothing was bought.", GW.SIGNAL_ORANGE)
  end
  if render then render() end
end

---------------------------------------------------------------------------
-- the Shopping tab
---------------------------------------------------------------------------
local function fs(parent, template, justify)
  local f = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
  if justify then f:SetJustifyH(justify) end
  return f
end
local function setColor(f, c) f:SetTextColor(c[1], c[2], c[3]) end
local function n(x) return BreakUpLargeNumbers and BreakUpLargeNumbers(x) or tostring(x) end

local function foundText(e)
  local r = sv.results[e]
  if sv.current == e then return "Searching…", GREY end
  if not r then
    for _, q in ipairs(sv.queue) do if q == e then return "Waiting…", GREY end end
    return (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) and "Not checked yet: Run List" or "Not checked yet", GREY
  end
  if r.kind == "unknown" then return "No answer from the auction house", GREY end
  if r.kind == "none" then return "None listed", GREY end
  if r.kind == "notfound" then return "No item by that name is listed", GW.SIGNAL_ORANGE end
  local p, max = r.plan, GW.EntryMax(e)
  if not p.cheapest then return "None listed", GREY end
  if max and p.available == 0 then
    return string.format("Nothing under %s (cheapest %s)", GW.Money(max), GW.Money(p.cheapest)), GREY
  end
  local text
  if r.kind == "commodity" then
    text = (max and string.format("%s at ≤ %s", n(p.available), GW.Money(max)) or string.format("%s listed from %s", n(p.listed), GW.Money(p.cheapest)))
      .. (sv.bought[e] and (" · bought " .. sv.bought[e]) or "")
  else
    text = string.format("%s listed from %s%s", n(p.listed), GW.Money(p.cheapest), r.variants and r.variants > 1 and (" (" .. r.variants .. " versions)") or "")
  end
  local mt, color = GW.MarketText(p.avg or p.cheapest, e.itemID)
  return text .. (mt and ("  ·  " .. mt) or ""), color or WHITE
end

render = function()
  if not (view and view:IsShown()) then return end
  local lists = GW.Lists()
  local list, sel = selectedList()
  for i, row in ipairs(view.listRows) do
    local l = lists[i]
    row.index = i
    if l then
      row:Show()
      row.text:SetText(string.format("%s  |cff9a9aa2· %d|r", l.name, #l.entries))
      row.sel:SetShown(i == sel)
      local selected = i == sel
      row.text:SetWidth(selected and 116 or 208) -- room for the icons
      row.icons.up:SetShown(selected and i > 1)
      row.icons.down:SetShown(selected and i < #lists)
      row.icons.rename:SetShown(selected)
      row.icons.copy:SetShown(selected)
      row.icons.delete:SetShown(selected)
    else
      row:Hide()
    end
  end
  for _, b in ipairs(view.listButtons) do b:SetEnabled(list ~= nil or b.always) end

  view.title:SetText(list and list.name or "No lists yet: click New List")
  view.addBox:SetShown(list ~= nil); view.addMax:SetShown(list ~= nil); view.addWant:SetShown(list ~= nil); view.add:SetShown(list ~= nil)
  local progress = ""
  if sv.waiting then progress = GW.WaitText()
  elseif sv.total > 0 then progress = string.format("Searched %d of %d · %d searches this minute", sv.checked, sv.total, GW.SearchesThisMinute()) end
  view.progress:SetText(progress)
  view.run:SetText(sv.running and "Stop" or "Run List")
  view.run:SetEnabled(list ~= nil and #list.entries > 0)

  local entries = list and list.entries or {}
  view.offset = math.max(0, math.min(view.offset or 0, math.max(0, #entries - ROWS)))
  for i, row in ipairs(view.rows) do
    local e = entries[i + view.offset]
    row.e = e
    if e then
      row:Show()
      row.name:SetText(e.name .. (e.itemID and "" or "  |cff9a9aa2(not found yet)|r"))
      local max = GW.EntryMax(e)
      row.max:SetText(e.maxPct and (e.maxPct .. "%" .. (max and (" · " .. GW.Money(max)) or "")) or (e.max and GW.Money(e.max)) or "–")
      row.want:SetText(e.want and tostring(e.want) or "–")
      local text, color = foundText(e)
      row.found:SetText(text)
      setColor(row.found, color)
      local r = sv.results[e]
      local b = sv.buy
      if b and b.entry == e then
        row.action:Show()
        row.action:SetText(b.confirming and "Buying…" or b.total and ("Confirm · " .. GW.Money(b.total)) or "Getting price…")
        row.action:SetEnabled(b.total ~= nil and not b.confirming)
      elseif r and r.kind == "commodity" and r.plan.units > 0 and e.want then
        row.action:Show()
        row.action:SetText(string.format("Buy %d · %s", r.plan.units, GW.Money(r.plan.total)))
        row.action:SetEnabled(sv.buy == nil)
      elseif r and r.kind == "commodity" and r.plan.available > 0 then
        row.action:Show(); row.action:SetText("Set Want to Buy"); row.action:Disable()
      elseif r and r.kind == "item" and r.plan.available > 0 then
        row.action:Show(); row.action:SetText("Show"); row.action:Enable()
      else
        row.action:Hide()
      end
    else
      row:Hide()
    end
  end
  view.empty:SetShown(list ~= nil and #entries == 0)
end

-- small dialogs: name a list, confirm delete
StaticPopupDialogs.GOLDWRIGHT_LIST_NAME = {
  text = "%s",
  button1 = OKAY or "OK",
  button2 = CANCEL or "Cancel",
  hasEditBox = 1,
  OnShow = function(self, data)
    data = data or self.data
    local box = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
    if box then box:SetText(data and data.name or ""); box:HighlightText() end
  end,
  OnAccept = function(self, data)
    data = data or self.data
    local box = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
    local name = box and strtrim(box:GetText() or "") or ""
    if name ~= "" and data and data.apply then data.apply(name) end
  end,
  EditBoxOnEnterPressed = function(self)
    local p = self:GetParent()
    StaticPopupDialogs.GOLDWRIGHT_LIST_NAME.OnAccept(p, p.data)
    p:Hide()
  end,
  timeout = 0, whileDead = true, hideOnEscape = true,
}
StaticPopupDialogs.GOLDWRIGHT_LIST_DELETE = {
  text = "Delete the shopping list \"%s\"?",
  button1 = YES or "Yes",
  button2 = NO or "No",
  OnAccept = function(self, data) data = data or self.data; if data and data.apply then data.apply() end end,
  timeout = 0, whileDead = true, hideOnEscape = true,
}

local function askName(prompt, name, apply)
  StaticPopup_Show("GOLDWRIGHT_LIST_NAME", prompt, nil, { name = name, apply = apply })
end

local function copyList(l)
  local c = { name = l.name .. " (copy)", entries = {} }
  for _, e in ipairs(l.entries) do
    c.entries[#c.entries + 1] = { name = e.name, itemID = e.itemID, max = e.max, maxPct = e.maxPct, want = e.want }
  end
  return c
end

-- SHOP-7: add an item to the selected list (or a new "Shopping" list).
function GW.AddToList(itemText, maxText, wantText)
  local lists = GW.Lists()
  local list = selectedList()
  if not list then
    list = { name = "Shopping", entries = {} }
    lists[#lists + 1] = list
    GoldwrightDB.listSel = #lists
  end
  local e, err = GW.MakeEntry(itemText, maxText, wantText)
  if not e then return nil, err end
  for _, x in ipairs(list.entries) do
    if (e.itemID and x.itemID == e.itemID) or x.name:lower() == e.name:lower() then
      return nil, e.name .. " is already in " .. list.name .. "."
    end
  end
  list.entries[#list.entries + 1] = e
  if render then render() end
  return e, list
end

-- Import / export window (SHOP-6)
local io
local function showIO(mode)
  if not io then
    io = CreateFrame("Frame", "GoldwrightListIO", UIParent, "ButtonFrameTemplate")
    io:SetSize(520, 360); io:SetPoint("CENTER"); io:SetFrameStrata("DIALOG")
    if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(io) end
    if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(io) end
    io:EnableMouse(true)
    GW.CloseOnEscape(io)
    io.hint = fs(io, "GameFontHighlightSmall", "LEFT"); io.hint:SetPoint("TOPLEFT", 18, -32); io.hint:SetWidth(480)
    -- a framed text area: dark background, tooltip-style border, padding; click anywhere to type
    local area = CreateFrame("Frame", nil, io, "BackdropTemplate")
    area:SetPoint("TOPLEFT", 14, -54); area:SetPoint("BOTTOMRIGHT", -14, 48)
    if area.SetBackdrop then
      area:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
      area:SetBackdropColor(0, 0, 0, 0.6)
      area:SetBackdropBorderColor(0.6, 0.6, 0.65, 1)
    end
    local scroll = CreateFrame("ScrollFrame", nil, area, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -8); scroll:SetPoint("BOTTOMRIGHT", -28, 8)
    io.box = CreateFrame("EditBox", nil, scroll)
    io.box:SetMultiLine(true); io.box:SetFontObject("ChatFontNormal"); io.box:SetWidth(440); io.box:SetAutoFocus(false)
    io.box:SetTextInsets(2, 2, 2, 2)
    io.box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    io.box:SetScript("OnEditFocusGained", function(self) if io.mode == "export" then self:HighlightText() end end)
    scroll:SetScrollChild(io.box)
    area:EnableMouse(true)
    area:SetScript("OnMouseDown", function() io.box:SetFocus() end)
    io.ok = CreateFrame("Button", nil, io, "UIPanelButtonTemplate"); io.ok:SetSize(120, 24); io.ok:SetPoint("BOTTOMRIGHT", -16, 16)
    io.ok:SetScript("OnClick", function()
      if io.mode == "import" then
        local got = GW.ImportLists(io.box:GetText())
        local lists = GW.Lists()
        local items = 0
        for _, l in ipairs(got) do lists[#lists + 1] = l; items = items + #l.entries end
        if #got > 0 then GoldwrightDB.listSel = #lists end
        toast(#got > 0 and string.format("Imported %d list%s with %d items.", #got, #got == 1 and "" or "s", items) or "Nothing to import: one list per line, Name^Item^Item.", #got > 0 and GW.SIGNAL_BLUE or GW.SIGNAL_ORANGE)
      end
      io:Hide()
      if render then render() end
    end)
  end
  io.mode = mode
  if io.SetTitle then io:SetTitle(mode == "import" and "Import Shopping Lists" or "Export Shopping Lists") end
  if mode == "import" then
    io.hint:SetText("Paste lists here, one per line: List name^Item^Item;max=75c;qty=20. Auctionator lists work too (names only).")
    io.box:SetText("")
    io.ok:SetText("Import")
  else
    io.hint:SetText("Copy this text (Ctrl+A, then Ctrl+C). It holds all your lists.")
    io.box:SetText(GW.ExportLists(GW.Lists()))
    io.ok:SetText("Close")
    io.box:HighlightText()
  end
  io:Show()
  io.box:SetFocus()
end

local function build(parent)
  view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints()

  -- left: the lists (SHOP-1). The selected row carries small icon buttons (move up / down, rename,
  -- duplicate, delete) with tooltips; double-click a name to rename. Below: New List, Import, Export.
  local function renameList()
    local list = selectedList()
    if list then askName("Rename the shopping list:", list.name, function(name) list.name = name; render() end) end
  end
  local function copySelected()
    local list, i = selectedList()
    if list then table.insert(GW.Lists(), i + 1, copyList(list)); GoldwrightDB.listSel = i + 1; render() end
  end
  local function deleteSelected()
    local list, i = selectedList()
    if not list then return end
    StaticPopup_Show("GOLDWRIGHT_LIST_DELETE", list.name, nil, { apply = function()
      table.remove(GW.Lists(), i)
      GoldwrightDB.listSel = math.max(1, i - 1)
      GW.StopList()
      render()
    end })
  end
  local function move(d)
    local lists = GW.Lists()
    local _, i = selectedList()
    if i and lists[i + d] then
      lists[i], lists[i + d] = lists[i + d], lists[i]
      GoldwrightDB.listSel = i + d
      render()
    end
  end
  local ICONS = {
    { key = "up", tex = "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up", tip = "Move up", fn = function() move(-1) end },
    { key = "down", tex = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up", tip = "Move down", fn = function() move(1) end },
    { key = "rename", tex = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up", tip = "Rename (or double-click the name)", fn = renameList },
    { key = "copy", tex = "Interface\\Buttons\\UI-PlusButton-Up", tip = "Duplicate this list", fn = copySelected },
    { key = "delete", tex = "Interface\\Buttons\\UI-GroupLoot-Pass-Up", tip = "Delete this list", fn = deleteSelected },
  }

  local lh = fs(view, "GameFontNormal", "LEFT"); lh:SetPoint("TOPLEFT", 12, -8); lh:SetText("Lists")
  view.listRows = {}
  for i = 1, LIST_ROWS do
    local row = CreateFrame("Button", nil, view)
    row:SetSize(220, 24)
    row:SetPoint("TOPLEFT", 8, -28 - (i - 1) * 24)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.sel = row:CreateTexture(nil, "BACKGROUND"); row.sel:SetAllPoints(); row.sel:SetColorTexture(0.24, 0.37, 0.66, 0.35)
    row.text = fs(row, "GameFontHighlight", "LEFT"); row.text:SetPoint("LEFT", 6, 0); row.text:SetWidth(208); row.text:SetWordWrap(false)
    row:SetScript("OnClick", function(self)
      GoldwrightDB.listSel = self.index
      GW.StopList()
      cancelBuy()
      view.offset = 0
      render()
    end)
    row:SetScript("OnDoubleClick", function(self)
      GoldwrightDB.listSel = self.index
      render()
      renameList()
    end)
    row.icons = {}
    for k = #ICONS, 1, -1 do -- right to left: delete at the far right
      local ic = ICONS[k]
      local b = CreateFrame("Button", nil, row)
      b:SetSize(16, 16)
      b:SetPoint("RIGHT", -4 - (#ICONS - k) * 18, 0)
      b:SetNormalTexture(ic.tex)
      b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
      b.key = ic.key
      b:SetScript("OnClick", ic.fn)
      b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(ic.tip)
        GameTooltip:Show()
      end)
      b:SetScript("OnLeave", function() GameTooltip:Hide() end)
      row.icons[ic.key] = b
    end
    view.listRows[i] = row
  end
  view.listButtons = {}
  local function lbtn(label, x, y, w, always, fn)
    local b = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
    b:SetSize(w, 22); b:SetPoint("BOTTOMLEFT", x, y); b:SetText(label); b.always = always
    b:SetScript("OnClick", fn)
    view.listButtons[#view.listButtons + 1] = b
    return b
  end
  lbtn("New List", 8, 36, 220, true, function()
    askName("Name the new shopping list:", "", function(name)
      local lists = GW.Lists()
      lists[#lists + 1] = { name = name, entries = {} }
      GoldwrightDB.listSel = #lists
      render()
    end)
  end)
  lbtn("Import", 8, 10, 108, true, function() showIO("import") end)
  lbtn("Export", 120, 10, 108, false, function() showIO("export") end)

  local div = view:CreateTexture(nil, "ARTWORK"); div:SetColorTexture(1, 1, 1, 0.08)
  div:SetPoint("TOPLEFT", 238, -6); div:SetPoint("BOTTOMLEFT", 238, 6); div:SetWidth(1)

  -- right: the selected list (SHOP-2..5)
  local X = 252
  view.title = fs(view, "GameFontNormalLarge", "LEFT"); view.title:SetPoint("TOPLEFT", X, -8)
  view.progress = fs(view, "GameFontDisableSmall", "LEFT"); view.progress:SetPoint("LEFT", view.title, "RIGHT", 12, 0)
  view.run = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
  view.run:SetSize(120, 24); view.run:SetPoint("TOPRIGHT", -12, -4)
  view.run:SetScript("OnClick", function() if sv.running then GW.StopList() else GW.RunList() end end)

  -- input with a short label above and grey example text inside while it's empty
  local function box(w, x, label, placeholder)
    local b = CreateFrame("EditBox", nil, view, "InputBoxTemplate")
    b:SetSize(w, 22); b:SetPoint("TOPLEFT", x, -52); b:SetAutoFocus(false)
    b.label = fs(view, "GameFontNormalSmall", "LEFT"); b.label:SetPoint("BOTTOMLEFT", b, "TOPLEFT", -4, 5); b.label:SetText(label)
    b.placeholder = fs(b, "GameFontDisable", "LEFT"); b.placeholder:SetPoint("LEFT", 2, 0); b.placeholder:SetText(placeholder)
    b:SetScript("OnTextChanged", function(self) self.placeholder:SetShown((self:GetText() or "") == "") end)
    b:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return b
  end
  view.addBox = box(300, X + 6, "Item", "Type a name or Shift-click an item")
  view.addMax = box(110, X + 324, "Max price", "75c, 2g or 80%")
  view.addWant = box(60, X + 452, "Want", "20")
  view.addWant:SetNumeric(true)
  view.add = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
  view.add:SetSize(100, 22); view.add:SetPoint("TOPLEFT", X + 524, -52); view.add:SetText("Add Item")
  local function doAdd()
    local e, err = GW.AddToList(view.addBox:GetText(), view.addMax:GetText(), view.addWant:GetText())
    if not e then return toast(err, GW.SIGNAL_ORANGE) end
    view.addBox:SetText(""); view.addMax:SetText(""); view.addWant:SetText("")
    view.addBox:ClearFocus()
    toast("Added " .. e.name .. ".", GW.SIGNAL_BLUE)
    GW.CheckEntry(e)
    render()
  end
  view.add:SetScript("OnClick", doAdd)
  for _, b in ipairs({ view.addBox, view.addMax, view.addWant }) do b:SetScript("OnEnterPressed", doAdd) end

  local cols = { { "Item", X }, { "Max price", X + 210 }, { "Want", X + 310 }, { "Found", X + 360 }, { "Action", X + 566 } }
  for _, c in ipairs(cols) do
    local f = fs(view, "GameFontDisableSmall", "LEFT"); f:SetPoint("TOPLEFT", c[2], -86); f:SetText(c[1])
  end
  local tbl = CreateFrame("Frame", nil, view)
  tbl:SetPoint("TOPLEFT", X - 4, -100); tbl:SetSize(730, ROWS * ROW_H)
  tbl:EnableMouseWheel(true)
  tbl:SetScript("OnMouseWheel", function(_, delta) view.offset = (view.offset or 0) - delta; render() end)
  view.rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("Frame", nil, tbl)
    row:SetSize(730, ROW_H); row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    if i % 2 == 0 then local bg = row:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(1, 1, 1, 0.03) end
    row.name = fs(row, "GameFontHighlight", "LEFT"); row.name:SetPoint("LEFT", 4, 0); row.name:SetWidth(200); row.name:SetWordWrap(false)
    row.max = fs(row, "GameFontHighlightSmall", "LEFT"); row.max:SetPoint("LEFT", 214, 0)
    row.want = fs(row, "GameFontHighlightSmall", "LEFT"); row.want:SetPoint("LEFT", 314, 0)
    row.found = fs(row, "GameFontHighlightSmall", "LEFT"); row.found:SetPoint("LEFT", 364, 0); row.found:SetWidth(196); row.found:SetWordWrap(true)
    row.action = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.action:SetSize(136, 22); row.action:SetPoint("LEFT", 566, 0)
    row.action:SetScript("OnClick", function()
      local e, r = row.e, row.e and sv.results[row.e]
      if not e then return end
      if (sv.buy and sv.buy.entry == e) or (r and r.kind == "commodity") then buyClick(e) else showInBuyTab(e) end
    end)
    row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    row.remove:SetSize(22, 22); row.remove:SetPoint("LEFT", 704, 0)
    row.remove:SetScript("OnClick", function()
      local list = selectedList()
      for k, x in ipairs(list and list.entries or {}) do
        if x == row.e then table.remove(list.entries, k) break end
      end
      if sv.buy and sv.buy.entry == row.e then cancelBuy() end
      render()
    end)
    view.rows[i] = row
  end
  view.empty = fs(view, "GameFontDisable", "CENTER"); view.empty:SetPoint("TOPLEFT", X, -150); view.empty:SetWidth(700)
  view.empty:SetText("Add the items you buy often, with the most you'd pay. Run List checks them all in one go.")
  view.toast = fs(view, "GameFontHighlightSmall", "LEFT"); view.toast:SetPoint("BOTTOMLEFT", X, 34); view.toast:SetWidth(720)
  local note = fs(view, "GameFontDisableSmall", "LEFT"); note:SetPoint("BOTTOMLEFT", X, 12); note:SetWidth(720)
  note:SetText("Buying takes two clicks: Buy asks the auction house for the exact price, then Confirm buys. Gear: Show puts it in Blizzard's list to buy there.")
end

-- SHOP-7: Shift-click an item (bags, links) while the Shopping tab is open to fill the Item box.
if hooksecurefunc and HandleModifiedItemClick then
  hooksecurefunc("HandleModifiedItemClick", function(link)
    if view and view:IsVisible() and view.addBox and IsShiftKeyDown() and type(link) == "string" and link:find("item:") then
      view.addBox:SetText(link)
      view.addMax:SetFocus()
    end
  end)
end

GW.ShopView = {}
function GW.ShopView.Show(parent)
  if not view then build(parent) end
  view:Show()
  render()
end
function GW.ShopView.Hide()
  if view then view:Hide() end
  GW.StopList()
  cancelBuy()
end
function GW.ShopView.Debug() return sv, view end

local events = CreateFrame("Frame")
for _, e in ipairs({ "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED", "ITEM_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_CLOSED" }) do
  pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "AUCTION_HOUSE_CLOSED" then
    sv.buy = nil
    GW.StopList()
    return
  end
  if not (view and view:IsShown()) then return end
  if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    onBrowseResults()
  elseif event:find("^COMMODITY_P") then
    onBuyEvent(event, a1, a2)
  else
    onSearchResults(event, a1)
  end
end)
