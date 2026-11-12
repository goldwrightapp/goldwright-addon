--- Shopping lists and the Shopping tab (SHOP-1..7). Lists live in GoldwrightDB.lists (account-wide);
--- running one sends a throttle-aware search per entry. Commodities: Buy asks for the exact price
--- (StartCommoditiesPurchase), a second click confirms (ConfirmCommoditiesPurchase), never automatic.
--- Gear: Show sends a browse search so Blizzard's own Buy list shows the item; the player buys there.
local _, GW = ...

local ROWS, ROW_H = 10, 30 -- entry table: visible rows, row height
local LIST_ROWS = 11 -- visible rows in the lists column
local SEARCH_TIMEOUT = 6 -- seconds to wait for search results before giving up on an entry
local BUY_TIMEOUT = 12 -- seconds to wait for the exact commodity price before cancelling
local QUOTE_TIMEOUT = 60 -- seconds a quoted price waits for Confirm before it is let go
local CONFIRM_TIMEOUT = 30 -- seconds after Confirm before saying the outcome is unknown
local LATE_RESULT_WINDOW = 300 -- seconds a late purchase result still counts for that buy
local UI = GW.UI
local fs, setColor = UI.FontString, UI.SetColor
local GREY, WHITE = UI.GREY, UI.WHITE

---------------------------------------------------------------------------
-- rules without UI (tested in server/test/addon.test.mjs)
---------------------------------------------------------------------------

--- One entry of a shopping list, as saved in GoldwrightDB.lists.
---@class GoldwrightShoppingEntry
---@field name string item name as typed, or from the link
---@field itemID? number item id (nil until a name-only entry is found by a browse search)
---@field max? number most to pay per item, in copper
---@field maxPct? number most to pay per item, as a % of market value (instead of `max`)
---@field want? number how many to buy

--- A saved shopping list.
---@class GoldwrightShoppingList
---@field name string
---@field entries GoldwrightShoppingEntry[]

--- What buying looks like for one item, from GW.BuyPlan (or built from browse results).
---@class GoldwrightBuyPlan
---@field cheapest? number lowest unit price listed, in copper (nil when none are listed)
---@field listed number units listed by other players
---@field available number units at or under the max price
---@field units number units the plan buys (at most `want`)
---@field total number cost of those units, in copper
---@field avg? number average unit price of those units, rounded (nil when units is 0)

--- The result of checking one entry.
---@class GoldwrightShoppingResult
---@field kind string "commodity", "item", "none" (none listed), "notfound" (no such name) or "unknown" (timeout)
---@field plan? GoldwrightBuyPlan set for "commodity" and "item"
---@field variants? number how many browse results matched (gear with several versions)
---@field at? number GetTime() when the result arrived

--- Parses a price the player typed: "1g 2s 3c", "75c", "1s50c", "150" (copper) or "80%" (of market).
---@param text? string
---@return number|nil copper price in copper, or nil
---@return number|nil pct percentage of market, or nil
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

--- Item id and name from an item link, or nil.
---@param text? string item link (or any text containing "item:<id>")
---@return number|nil itemID
---@return string|nil name the text between [ and ], if any
function GW.LinkItem(text)
  local id = text and tonumber(text:match("item:(%d+)"))
  if not id then return nil end
  return id, text:match("%[(.-)%]")
end

--- The saved shopping lists (GoldwrightDB.lists), created empty on first use.
---@return GoldwrightShoppingList[]
function GW.Lists()
  GoldwrightDB.lists = GoldwrightDB.lists or {}
  return GoldwrightDB.lists
end

--- A new list entry from what the player typed or shift-clicked. A plain name is looked up with
--- GetItemInfo, which only knows items the client has cached; otherwise the id stays nil.
---@param itemText? string item name (optionally in quotes) or item link
---@param maxText? string max price, see GW.ParseMoney ("" for none)
---@param wantText? string quantity wanted ("" for none)
---@return GoldwrightShoppingEntry|nil entry
---@return string? err message for the player when the input is invalid
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

--- Replaces the export format's separators (^ ; newline) in a name with spaces.
---@param s string
---@return string
local function clean(s) return (s:gsub("[%^;\n]", " ")) end

--- Exports lists as text: one list per line, "Name^Item;id=2840;max=75;qty=20^Other Item".
--- A percentage max is written as "max=80%".
---@param lists GoldwrightShoppingList[]
---@return string
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

--- Limits on imported text, so a huge or crafted paste can't freeze the game or bloat saved data.
GW.IMPORT_LIMITS = { chars = 100000, lists = 50, entries = 500, field = 100 }

--- A whole number from `v` within [1, max], else nil.
---@param v string
---@param max number
---@return number|nil
local function wholeNumber(v, max)
  if not v:match("^%d+$") or #v > 12 then return nil end
  local n = tonumber(v)
  return n and n >= 1 and n <= max and n or nil
end

--- An imported name made safe to show: no WoW formatting codes (links, textures, colours start
--- with "|"), no backticks (they break code blocks where reports are pasted), no control
--- characters, at most IMPORT_LIMITS.field characters.
---@param s string
---@return string
local function safeText(s)
  s = s:sub(1, GW.IMPORT_LIMITS.field):gsub("[|`%c]", "")
  return strtrim(s)
end

--- Parses exported lists (see GW.ExportLists). Also takes Auctionator-style terms ("Name" in quotes;
--- fields after ';' are ignored unless they are id=, max= or qty=). Lines without a name or without
--- any item are skipped, as are numbers that aren't sensible (id and qty: whole and positive).
--- Text over IMPORT_LIMITS.chars is refused; lists and entries past the limits are left out.
---@param text? string
---@return GoldwrightShoppingList[] lists
---@return string|nil problem why something was refused or left out
function GW.ImportLists(text)
  local L = GW.IMPORT_LIMITS
  text = text or ""
  if #text > L.chars then return {}, "That text is too long to be a shopping list." end
  local out, cut = {}, false
  for line in text:gmatch("[^\r\n]+") do
    local pieces = {}
    for p in (line .. "^"):gmatch("([^%^]*)%^") do
      pieces[#pieces + 1] = p
    end
    local name = safeText(pieces[1] or "")
    if name ~= "" and #pieces > 1 then
      if #out >= L.lists then
        cut = true
        break
      end
      local list = { name = name, entries = {} }
      for i = 2, #pieces do
        if #list.entries >= L.entries then
          cut = true
          break
        end
        local fields = {}
        for f in (pieces[i] .. ";"):gmatch("([^;]*);") do
          fields[#fields + 1] = f
        end
        local item = safeText((strtrim(fields[1] or ""):gsub('^"(.*)"$', "%1")))
        if item ~= "" then
          local e = { name = item }
          for j = 2, #fields do
            local f = fields[j]:sub(1, L.field)
            local eq = f:find("=", 1, true)
            local k = eq and strtrim(f:sub(1, eq - 1)):lower()
            local v = eq and strtrim(f:sub(eq + 1)) or ""
            if k == "id" then
              e.itemID = wholeNumber(v, 9999999)
            elseif k == "qty" then
              e.want = wholeNumber(v, 99999)
            elseif k == "max" then
              e.max, e.maxPct = GW.ParseMoney(v)
              if (e.max and e.max > 99999999999) or (e.maxPct and (e.maxPct < 1 or e.maxPct > 1000)) then
                e.max, e.maxPct = nil, nil
              end
            end
          end
          -- The client's own name for the id wins, so a shared list can't show one item and buy another.
          e.name = GW.ShopItemName(e.itemID) or e.name
          list.entries[#list.entries + 1] = e
        end
      end
      if #list.entries > 0 then out[#out + 1] = list end
    end
  end
  return out,
    cut and string.format("Only the first %d lists and %d items per list were kept.", L.lists, L.entries) or nil
end

--- The game's name for an item id, when the client knows it (nil otherwise, e.g. not cached yet).
---@param id? number
---@return string|nil
function GW.ShopItemName(id)
  if not id then return nil end
  local n = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
  if not n then
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    n = getInfo and getInfo(id)
  end
  return n
end

--- An entry's name, corrected to the game's name for its id once the client knows it (a shared list
--- may carry a misleading name). Saves the correction.
---@param e GoldwrightShoppingEntry
---@return string
local function entryName(e)
  local real = GW.ShopItemName(e.itemID)
  if real and real ~= e.name then e.name = real end
  return e.name
end

--- What buying looks like from an item's listings (the player's own excluded): the cheapest price,
--- how many are at or under `max` (all when nil), and the cost of the cheapest `want` of those.
---@param listings? table[] rows from GW.CollectSearchResults ({ price, qty, own?, ownQty? })
---@param max? number most to pay per unit, in copper
---@param want? number units to buy (nil: all available)
---@return GoldwrightBuyPlan
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

--- Market value of an item at the auction house you are shopping at (Blackwater in neutral towns,
--- else your faction's; scan or data pack), falling back to the 7-day and then the 30-day normal price.
---@param id? number item id
---@return number|nil copper
local function market(id)
  local d = id and GW.ItemData(id)
  local side = GW.AuctionSide and GW.AuctionSide() or GW.House().side
  local s = d and d[side]
  return s and (s.mv or s.avg7 or s.avg30) or nil
end

--- An entry's max price in copper: the fixed max, or maxPct of the current market value.
---@param e GoldwrightShoppingEntry
---@return number|nil copper nil when there is no max, or no market value for a % max
function GW.EntryMax(e)
  if e.max then return e.max end
  if e.maxPct then
    local m = market(e.itemID)
    return m and math.floor(m * e.maxPct / 100) or nil
  end
  return nil
end

--- "20% under market" / "at market" (within 3%) / "35% over market", with a colour: blue or orange
--- once the difference reaches the signalPct setting, grey otherwise.
---@param price? number unit price in copper
---@param id? number item id
---@return string|nil text nil without a market value or price
---@return number[]? color {r, g, b}
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

--- A commodity purchase in progress (between Buy and the purchase result).
---@class GoldwrightShoppingBuy
---@field entry GoldwrightShoppingEntry
---@field qty number units asked for
---@field estimate number cost from the buy plan, in copper
---@field at number GetTime() when Buy was clicked
---@field unit? number exact unit price from COMMODITY_PRICE_UPDATED
---@field total? number exact total from COMMODITY_PRICE_UPDATED (set: Confirm is possible)
---@field confirming? boolean Confirm was clicked
---@field done? boolean the purchase succeeded
---@field quote? table identifies the latest price, so an older quote's timeout does nothing
---@field quotedAt? number GetTime() of the latest price; Confirm works GW.CONFIRM_DELAY after it
---@field unansweredAt? number GetTime() when we stopped waiting for the result after Confirm

--- Shopping tab state (session only, not saved).
---@class GoldwrightShoppingState
---@field results table<GoldwrightShoppingEntry, GoldwrightShoppingResult> last result per entry
---@field queue GoldwrightShoppingEntry[] entries still to search
---@field checked number entries finished in this run
---@field total number entries in this run
---@field bought table<GoldwrightShoppingEntry, number> units bought per entry this session
---@field current? GoldwrightShoppingEntry entry being searched now
---@field token? table identifies the current search, so a stale timeout does nothing
---@field purpose? string "search" (item key search) or "browse" (name search)
---@field running? boolean a list run is in progress
---@field waiting? boolean waiting for a free search slot (throttle)
---@field buy? GoldwrightShoppingBuy
---@field unanswered? GoldwrightShoppingBuy a confirmed buy whose result never came; a late result still counts
local sv = { results = {}, queue = {}, checked = 0, total = 0, bought = {} }
local render

--- The entry being searched now, or nil.
local function current() return sv.current end

--- The selected list (GoldwrightDB.listSel), falling back to the first list. Saves the fixed index.
---@return GoldwrightShoppingList|nil list
---@return number|nil index
local function selectedList()
  local lists = GW.Lists()
  local i = GoldwrightDB.listSel or 1
  if not lists[i] then i = #lists > 0 and 1 or nil end
  GoldwrightDB.listSel = i
  return i and lists[i], i
end

local sorts = GW.PriceSorts

local runNext

--- Stores the result for the entry being searched and moves on to the next one. Ignored when `e`
--- is no longer the current entry (a late answer).
---@param e GoldwrightShoppingEntry
---@param result GoldwrightShoppingResult
local function finishEntry(e, result)
  if sv.current ~= e then return end
  result.at = GetTime()
  sv.results[e] = result
  sv.current, sv.token = nil, nil
  sv.checked = sv.checked + 1
  if render then render() end
  C_Timer.After(0.1, runNext)
end

--- Sends the search for an entry and arms the timeout. An item search that times out without results
--- falls back to a browse search; otherwise the entry finishes as "unknown".
---@param e GoldwrightShoppingEntry
---@param purpose string "search" (by item key, needs itemID) or "browse" (by name)
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

--- Starts the next queued search, or retries after GW.SEARCH_RETRY while the throttle has no free
--- slot. Ends the run when the queue is empty.
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
    C_Timer.After(GW.SEARCH_RETRY, runNext)
    return
  end
  sv.waiting = false
  table.remove(sv.queue, 1)
  sv.current = e
  send(e, e.itemID and "search" or "browse")
  if render then render() end
end

--- SHOP-3: runs the selected list (or one entry of it). Needs the auction house open.
---@param only? GoldwrightShoppingEntry check just this entry
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

--- Checks one entry now (just added, or just bought): joins a running list, or runs alone. Does
--- nothing while the auction house is closed.
---@param e GoldwrightShoppingEntry
function GW.CheckEntry(e)
  if not (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) then return end
  sv.results[e] = nil
  if sv.running then
    for _, q in ipairs(sv.queue) do
      if q == e then return end
    end
    if sv.current == e then return end
    sv.queue[#sv.queue + 1] = e
    sv.total = sv.total + 1
  else
    sv.queue, sv.checked, sv.total, sv.running = { e }, 0, 1, true
  end
  if render then render() end
  runNext()
end

--- Stops a list run: clears the queue and forgets the current search (results so far stay).
function GW.StopList()
  sv.queue, sv.running, sv.current, sv.token, sv.waiting = {}, false, nil, nil, false
  if render then render() end
end

--- The browse results for this entry: by item id, or by exact name (case-insensitive) when the
--- entry has no id yet.
---@param e GoldwrightShoppingEntry
---@return table[] results browse result rows
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

--- Handles commodity and item search results for the current entry. Commodities get a buy plan for
--- the quantity still wanted (want minus what was bought this session).
---@param event string COMMODITY_SEARCH_RESULTS_* or ITEM_SEARCH_RESULTS_*
---@param arg1 any item id (commodity events) or item key (item events)
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

--- Handles browse results for the current entry. A name-only entry that is found learns its item id
--- and is searched again at the front of the queue; gear gets a plan from the browse rows (cheapest
--- price and listed count only).
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
  finishEntry(e, {
    kind = "item",
    plan = {
      cheapest = cheapest,
      listed = listed,
      available = (not max or (cheapest and cheapest <= max)) and listed or 0,
      units = 0,
      total = 0,
    },
    variants = #m,
  })
end

---------------------------------------------------------------------------
-- buying commodities (SHOP-5): Buy gets the exact price, Confirm buys
---------------------------------------------------------------------------
--- Shows a status line under the Shopping tab.
---@param text string
---@param color? number[] {r, g, b}
local function toast(text, color) UI.Toast(view, text, color) end

--- Cancels a pending commodity purchase (if any) and forgets it. A purchase whose Confirm was
--- already clicked is on its way and is left alone: its result still arrives (onBuyEvent).
local function cancelBuy()
  if sv.buy and sv.buy.confirming then return end
  if sv.buy and C_AuctionHouse.CancelCommoditiesPurchase then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
  sv.buy = nil
end

--- Tells the player in the tab and in chat (the tab may be closed by now).
---@param text string
---@param color? number[]
local function tellBuy(text, color)
  toast(text, color)
  if not (view and view:IsShown()) then GW.Print("%s", text) end
end

--- Gives up waiting for the result of a confirmed buy: the purchase may or may not have gone
--- through, so the row stops offering it until the list is checked again, and a late result still
--- counts (sv.unanswered).
---@param b GoldwrightShoppingBuy
---@param why string start of the message
local function buyUnanswered(b, why)
  if sv.buy == b then sv.buy = nil end
  b.unansweredAt = GetTime()
  sv.unanswered = b
  sv.results[b.entry] = nil
  GW.Log("shopping confirm unanswered: %d x %s (%s)", b.qty, b.entry.name, why)
  tellBuy(
    string.format(
      "%s about %d × %s. It may have been bought: check your mailbox before buying again.",
      why,
      b.qty,
      b.entry.name
    ),
    GW.SIGNAL_ORANGE
  )
  if render then render() end
end

--- The Buy / Confirm button of a commodity row. First click asks the auction house for the exact
--- price of the planned units (cancelled after BUY_TIMEOUT without an answer); a second click, once
--- the price is known, confirms the purchase. Refused in combat.
---@param e GoldwrightShoppingEntry
local function buyClick(e)
  local res = sv.results[e]
  local b = sv.buy
  if InCombatLockdown and InCombatLockdown() then return toast("Not in combat.", GW.SIGNAL_ORANGE) end
  if b and b.confirming then return end -- already buying: never confirm twice
  if b and b.entry == e and b.total then
    if GetTime() - (b.quotedAt or 0) < GW.CONFIRM_DELAY then return end -- a double click on Buy
    -- second click: confirm at the quoted price
    b.confirming = true
    C_AuctionHouse.ConfirmCommoditiesPurchase(e.itemID, b.qty)
    GW.Log("shopping confirm: %d x %s for %d", b.qty, e.name, b.total)
    toast("Buying…", GREY)
    if render then render() end
    C_Timer.After(CONFIRM_TIMEOUT, function()
      if sv.buy == b and not b.done then buyUnanswered(b, "No answer from the auction house") end
    end)
    return
  end
  if not (res and res.kind == "commodity" and res.plan.units > 0) then return end
  entryName(e)
  cancelBuy()
  local qty = res.plan.units
  sv.buy = { entry = e, qty = qty, estimate = res.plan.total, at = GetTime() }
  sv.unanswered = nil
  local token = sv.buy
  C_AuctionHouse.StartCommoditiesPurchase(e.itemID, qty)
  GW.Log("shopping buy start: %d x %s (estimate %d)", qty, e.name, res.plan.total)
  toast("Asking the auction house for the exact price…", GREY)
  if render then render() end
  -- Only a buy that never got a price is cancelled here; a quoted one has its own wait
  -- (onBuyEvent) and a confirmed one is never cancelled.
  C_Timer.After(BUY_TIMEOUT, function()
    if sv.buy == token and not token.done and not token.total and not token.confirming then
      cancelBuy()
      toast("No answer from the auction house. Nothing was bought.", GW.SIGNAL_ORANGE)
      if render then render() end
    end
  end)
end

--- The Show button of a gear row: sends a browse search so Blizzard's Buy list shows the item.
---@param e GoldwrightShoppingEntry
local function showInBuyTab(e)
  if not GW.CanSearch() then return toast("Waiting for a search slot: try again in a moment.", GW.SIGNAL_ORANGE) end
  GW.NoteSearch()
  C_AuctionHouse.SendBrowseQuery({ searchString = e.name, sorts = sorts(), filters = {}, itemClassFilters = {} })
  toast("Shown in Blizzard's list on the left: buy it there.", GREY)
end

--- Handles the commodity purchase events for the pending buy: the exact price (with warnings when it
--- is over the max or more gold than the player has), price gone, success (re-checks the entry) or
--- failure.
---@param event string COMMODITY_PRICE_* or COMMODITY_PURCHASE_*
---@param a1 any unit price (COMMODITY_PRICE_UPDATED)
---@param a2 any total price (COMMODITY_PRICE_UPDATED)
local function onBuyEvent(event, a1, a2)
  local b = sv.buy
  local late = false
  -- Blizzard's own Buy tab fires the same events, so only a result soon after counts as ours.
  if sv.unanswered and GetTime() - (sv.unanswered.unansweredAt or 0) > LATE_RESULT_WINDOW then sv.unanswered = nil end
  if not b and event:find("^COMMODITY_PURCHASE") and sv.unanswered then
    b, late = sv.unanswered, true -- the result of a buy we stopped waiting for
  end
  if not b then return end
  local e = b.entry
  if late then
    sv.unanswered = nil
    if event == "COMMODITY_PURCHASE_SUCCEEDED" then
      sv.bought[e] = (sv.bought[e] or 0) + b.qty
      tellBuy(string.format("It went through after all: bought %d × %s.", b.qty, e.name), GW.SIGNAL_BLUE)
    else
      tellBuy(string.format("The purchase of %d × %s failed. Nothing was bought.", b.qty, e.name), GW.SIGNAL_ORANGE)
    end
    if render then render() end
    return
  end
  if event == "COMMODITY_PRICE_UPDATED" then
    b.unit, b.total = a1, a2
    b.quotedAt = GetTime()
    entryName(e)
    C_Timer.After(GW.CONFIRM_DELAY + 0.05, function()
      if render then render() end
    end)
    local quote = {}
    b.quote = quote
    C_Timer.After(QUOTE_TIMEOUT, function()
      if sv.buy == b and b.quote == quote and not b.confirming and not b.done then
        cancelBuy()
        toast("The price wasn't confirmed in time. Nothing was bought: click Buy again.", GREY)
        if render then render() end
      end
    end)
    local max = GW.EntryMax(e)
    if max and b.unit and b.unit > max then
      toast(
        string.format(
          "The price went up: %s each is over your max (%s). Confirm only if you still want it.",
          GW.Money(b.unit),
          GW.Money(max)
        ),
        GW.SIGNAL_ORANGE
      )
    elseif b.total and GetMoney and b.total > GetMoney() then
      toast("Not enough gold for " .. GW.Money(b.total) .. ".", GW.SIGNAL_ORANGE)
    elseif b.total and b.total > b.estimate then
      toast(
        string.format(
          "%d × %s for %s (%s each): %s more than the list showed. Confirm only if you still want it.",
          b.qty,
          e.name,
          GW.Money(b.total),
          GW.Money(b.unit),
          GW.Money(b.total - b.estimate)
        ),
        GW.SIGNAL_ORANGE
      )
    else
      toast(
        string.format(
          "%d × %s for %s (%s each). Click Confirm to buy.",
          b.qty,
          e.name,
          GW.Money(b.total),
          GW.Money(b.unit)
        ),
        WHITE
      )
    end
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
    sv.buy = nil
    toast("Those listings are gone. Run the list again.", GW.SIGNAL_ORANGE)
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
    b.done = true
    sv.bought[e] = (sv.bought[e] or 0) + b.qty
    tellBuy(string.format("Bought %d × %s for %s.", b.qty, e.name, GW.Money(b.total or b.estimate)), GW.SIGNAL_BLUE)
    sv.buy = nil
    sv.results[e] = nil
    -- see what's left (only while the tab is open; otherwise the next run checks it)
    C_Timer.After(0.5, function()
      if view and view:IsShown() then GW.CheckEntry(e) end
    end)
  elseif event == "COMMODITY_PURCHASE_FAILED" then
    sv.buy = nil
    tellBuy("The purchase failed. Nothing was bought.", GW.SIGNAL_ORANGE)
  end
  if render then render() end
end

---------------------------------------------------------------------------
-- the Shopping tab
---------------------------------------------------------------------------
local n = GW.Number

--- The "Found" column text for an entry: search state, or what its last result found.
---@param e GoldwrightShoppingEntry
---@return string text
---@return number[] color {r, g, b}
local function foundText(e)
  local r = sv.results[e]
  if sv.current == e then return "Searching…", GREY end
  if not r then
    for _, q in ipairs(sv.queue) do
      if q == e then return "Waiting…", GREY end
    end
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
    text = (
      max and string.format("%s at ≤ %s", n(p.available), GW.Money(max))
      or string.format("%s listed from %s", n(p.listed), GW.Money(p.cheapest))
    ) .. (sv.bought[e] and (" · bought " .. sv.bought[e]) or "")
  else
    text = string.format(
      "%s listed from %s%s",
      n(p.listed),
      GW.Money(p.cheapest),
      r.variants and r.variants > 1 and (" (" .. r.variants .. " versions)") or ""
    )
  end
  local mt, color = GW.MarketText(p.avg or p.cheapest, e.itemID)
  return text .. (mt and ("  ·  " .. mt) or ""), color or WHITE
end

--- Redraws the Shopping tab (lists column, progress, entry rows and their action buttons). Does
--- nothing while the tab is hidden.
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
  for _, b in ipairs(view.listButtons) do
    b:SetEnabled(list ~= nil or b.always)
  end

  view.title:SetText(list and list.name or "No lists yet: click New List")
  view.addBox:SetShown(list ~= nil)
  view.addMax:SetShown(list ~= nil)
  view.addWant:SetShown(list ~= nil)
  view.add:SetShown(list ~= nil)
  local progress = ""
  if sv.waiting then
    progress = GW.WaitText()
  elseif sv.total > 0 then
    progress =
      string.format("Searched %d of %d · %d searches this minute", sv.checked, sv.total, GW.SearchesThisMinute())
  end
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
      row.name:SetText(entryName(e) .. (e.itemID and "" or "  |cff9a9aa2(not found yet)|r"))
      local max = GW.EntryMax(e)
      row.max:SetText(
        e.maxPct and (e.maxPct .. "%" .. (max and (" · " .. GW.Money(max)) or ""))
          or (e.max and GW.Money(e.max))
          or "–"
      )
      row.want:SetText(e.want and tostring(e.want) or "–")
      local text, color = foundText(e)
      row.found:SetText(text)
      setColor(row.found, color)
      local r = sv.results[e]
      local b = sv.buy
      if b and b.entry == e then
        row.action:Show()
        row.action:SetText(
          b.confirming and "Buying…" or b.total and ("Confirm · " .. GW.Money(b.total)) or "Getting price…"
        )
        row.action:SetEnabled(b.total ~= nil and not b.confirming and GetTime() - (b.quotedAt or 0) >= GW.CONFIRM_DELAY)
      elseif r and r.kind == "commodity" and r.plan.units > 0 and e.want then
        row.action:Show()
        row.action:SetText(string.format("Buy %d · %s", r.plan.units, GW.Money(r.plan.total)))
        row.action:SetEnabled(sv.buy == nil)
      elseif r and r.kind == "commodity" and r.plan.available > 0 then
        row.action:Show()
        row.action:SetText("Set Want to Buy")
        row.action:Disable()
      elseif r and r.kind == "item" and r.plan.available > 0 then
        row.action:Show()
        row.action:SetText("Show")
        row.action:Enable()
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
    if box then
      box:SetText(data and data.name or "")
      box:HighlightText()
    end
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
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}
StaticPopupDialogs.GOLDWRIGHT_LIST_DELETE = {
  text = 'Delete the shopping list "%s"?',
  button1 = YES or "Yes",
  button2 = NO or "No",
  OnAccept = function(self, data)
    data = data or self.data
    if data and data.apply then data.apply() end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

--- Asks for a list name in a popup.
---@param prompt string popup text
---@param name string prefilled name
---@param apply fun(name: string) called with the trimmed, non-empty name on OK
local function askName(prompt, name, apply)
  StaticPopup_Show("GOLDWRIGHT_LIST_NAME", prompt, nil, { name = name, apply = apply })
end

--- A copy of a list named "<name> (copy)", with copied entries.
---@param l GoldwrightShoppingList
---@return GoldwrightShoppingList
local function copyList(l)
  local c = { name = l.name .. " (copy)", entries = {} }
  for _, e in ipairs(l.entries) do
    c.entries[#c.entries + 1] = { name = e.name, itemID = e.itemID, max = e.max, maxPct = e.maxPct, want = e.want }
  end
  return c
end

--- SHOP-7: adds an item to the selected list (or to a new "Shopping" list when there is none).
--- Refuses an item already in the list (same id or same name).
---@param itemText? string see GW.MakeEntry
---@param maxText? string
---@param wantText? string
---@return GoldwrightShoppingEntry|nil entry
---@return GoldwrightShoppingList|string list the list it went into, or an error message
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

--- Opens the import / export window (built on first use). Import appends the parsed lists and
--- selects the last one; export shows all lists as text, highlighted for copying.
---@param mode string "import" or "export"
local function showIO(mode)
  if not io then
    io = UI.Window("GoldwrightListIO", 520, 360, { strata = "DIALOG" })
    io:SetPoint("CENTER")
    io.hint = fs(io, "GameFontHighlightSmall", "LEFT")
    io.hint:SetPoint("TOPLEFT", 18, -32)
    io.hint:SetWidth(480)
    local area
    area, io.box = UI.TextArea(io, 440)
    area:SetPoint("TOPLEFT", 14, -54)
    area:SetPoint("BOTTOMRIGHT", -14, 48)
    io.box:SetScript("OnEditFocusGained", function(self)
      if io.mode == "export" then self:HighlightText() end
    end)
    io.ok = CreateFrame("Button", nil, io, "UIPanelButtonTemplate")
    io.ok:SetSize(120, 24)
    io.ok:SetPoint("BOTTOMRIGHT", -16, 16)
    io.ok:SetScript("OnClick", function()
      if io.mode == "import" then
        local got, problem = GW.ImportLists(io.box:GetText())
        local lists = GW.Lists()
        local items = 0
        for _, l in ipairs(got) do
          lists[#lists + 1] = l
          items = items + #l.entries
        end
        if #got > 0 then GoldwrightDB.listSel = #lists end
        local msg = #got > 0
            and string.format(
              "Imported %d list%s with %d item%s.",
              #got,
              #got == 1 and "" or "s",
              items,
              items == 1 and "" or "s"
            )
          or "Nothing to import: one list per line, Name^Item^Item."
        if problem then msg = (#got > 0 and msg .. " " or "") .. problem end
        toast(msg, (#got > 0 and not problem) and GW.SIGNAL_BLUE or GW.SIGNAL_ORANGE)
      end
      io:Hide()
      if render then render() end
    end)
  end
  io.mode = mode
  if io.SetTitle then io:SetTitle(mode == "import" and "Import Shopping Lists" or "Export Shopping Lists") end
  if mode == "import" then
    io.hint:SetText(
      "Paste lists here, one per line: List name^Item^Item;max=75c;qty=20. Auctionator lists work too (names only)."
    )
    io.box:SetText("")
    if io.box.SetMaxLetters then io.box:SetMaxLetters(GW.IMPORT_LIMITS.chars + 1) end -- +1: "too long" is reported
    io.ok:SetText("Import")
  else
    io.hint:SetText("Copy this text (Ctrl+A, then Ctrl+C). It holds all your lists.")
    if io.box.SetMaxLetters then io.box:SetMaxLetters(0) end -- no limit on your own lists
    io.box:SetText(GW.ExportLists(GW.Lists()))
    io.ok:SetText("Close")
    io.box:HighlightText()
  end
  io:Show()
  io.box:SetFocus()
end

--- Builds the Shopping tab inside `parent`: the lists column on the left, the selected list's
--- add-item boxes and entry table on the right.
---@param parent table tab content frame
local function build(parent)
  view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints()

  -- left: the lists (SHOP-1). The selected row carries small icon buttons (move up / down, rename,
  -- duplicate, delete) with tooltips; double-click a name to rename. Below: New List, Import, Export.
  local function renameList()
    local list = selectedList()
    if list then
      askName("Rename the shopping list:", list.name, function(name)
        list.name = name
        render()
      end)
    end
  end
  local function copySelected()
    local list, i = selectedList()
    if list then
      table.insert(GW.Lists(), i + 1, copyList(list))
      GoldwrightDB.listSel = i + 1
      render()
    end
  end
  local function deleteSelected()
    local list, i = selectedList()
    if not list then return end
    StaticPopup_Show("GOLDWRIGHT_LIST_DELETE", list.name, nil, {
      apply = function()
        table.remove(GW.Lists(), i)
        GoldwrightDB.listSel = math.max(1, i - 1)
        GW.StopList()
        render()
      end,
    })
  end
  --- Moves the selected list up (-1) or down (1).
  ---@param d number
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
    {
      key = "up",
      tex = "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up",
      tip = "Move up",
      fn = function() move(-1) end,
    },
    {
      key = "down",
      tex = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up",
      tip = "Move down",
      fn = function() move(1) end,
    },
    {
      key = "rename",
      tex = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up",
      tip = "Rename (or double-click the name)",
      fn = renameList,
    },
    { key = "copy", tex = "Interface\\Buttons\\UI-PlusButton-Up", tip = "Duplicate this list", fn = copySelected },
    { key = "delete", tex = "Interface\\Buttons\\UI-GroupLoot-Pass-Up", tip = "Delete this list", fn = deleteSelected },
  }

  UI.Header(view, "Lists", 12, -8)
  view.listRows = {}
  for i = 1, LIST_ROWS do
    local row = CreateFrame("Button", nil, view)
    row:SetSize(220, 24)
    row:SetPoint("TOPLEFT", 8, -28 - (i - 1) * 24)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(0.24, 0.37, 0.66, 0.35)
    row.text = fs(row, "GameFontHighlight", "LEFT")
    row.text:SetPoint("LEFT", 6, 0)
    row.text:SetWidth(208)
    row.text:SetWordWrap(false)
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
      UI.HoverTip(b, ic.tip)
      row.icons[ic.key] = b
    end
    view.listRows[i] = row
  end
  view.listButtons = {}
  --- A button under the lists column, anchored BOTTOMLEFT at x, y.
  ---@param label string
  ---@param x number
  ---@param y number
  ---@param w number width
  ---@param always boolean enabled even when there is no list
  ---@param fn function click handler
  ---@return table button
  local function lbtn(label, x, y, w, always, fn)
    local b = UI.Button(view, label, w, 22)
    b:SetPoint("BOTTOMLEFT", x, y)
    b.always = always
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

  UI.Divider(view, 238)

  -- right: the selected list (SHOP-2..5)
  local X = 252
  view.title = fs(view, "GameFontNormalLarge", "LEFT")
  view.title:SetPoint("TOPLEFT", X, -8)
  view.progress = fs(view, "GameFontDisableSmall", "LEFT")
  view.progress:SetPoint("LEFT", view.title, "RIGHT", 12, 0)
  view.run = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
  view.run:SetSize(120, 24)
  view.run:SetPoint("TOPRIGHT", -12, -4)
  view.run:SetScript("OnClick", function()
    if sv.running then
      GW.StopList()
    else
      GW.RunList()
    end
  end)

  --- An input with a short label above and grey example text inside while it is empty.
  ---@param w number width
  ---@param x number left offset in the tab
  ---@param label string
  ---@param placeholder string
  ---@return table editBox
  local function box(w, x, label, placeholder)
    local b = CreateFrame("EditBox", nil, view, "InputBoxTemplate")
    b:SetSize(w, 22)
    b:SetPoint("TOPLEFT", x, -52)
    b:SetAutoFocus(false)
    b.label = fs(view, "GameFontNormalSmall", "LEFT")
    b.label:SetPoint("BOTTOMLEFT", b, "TOPLEFT", -4, 5)
    b.label:SetText(label)
    b.placeholder = fs(b, "GameFontDisable", "LEFT")
    b.placeholder:SetPoint("LEFT", 2, 0)
    b.placeholder:SetText(placeholder)
    b:SetScript("OnTextChanged", function(self) self.placeholder:SetShown((self:GetText() or "") == "") end)
    b:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return b
  end
  view.addBox = box(300, X + 6, "Item", "Type a name or Shift-click an item")
  view.addMax = box(110, X + 324, "Max price", "75c, 2g or 80%")
  view.addWant = box(60, X + 452, "Want", "20")
  view.addWant:SetNumeric(true)
  view.add = UI.Button(view, "Add Item", 100, 22)
  view.add:SetPoint("TOPLEFT", X + 524, -52)
  --- Adds the typed item to the selected list, clears the boxes and checks the new entry.
  local function doAdd()
    local e, err = GW.AddToList(view.addBox:GetText(), view.addMax:GetText(), view.addWant:GetText())
    if not e then return toast(err, GW.SIGNAL_ORANGE) end
    view.addBox:SetText("")
    view.addMax:SetText("")
    view.addWant:SetText("")
    view.addBox:ClearFocus()
    toast("Added " .. e.name .. ".", GW.SIGNAL_BLUE)
    GW.CheckEntry(e)
    render()
  end
  view.add:SetScript("OnClick", doAdd)
  for _, b in ipairs({ view.addBox, view.addMax, view.addWant }) do
    b:SetScript("OnEnterPressed", doAdd)
  end

  local cols =
    { { "Item", X }, { "Max price", X + 210 }, { "Want", X + 310 }, { "Found", X + 360 }, { "Action", X + 566 } }
  for _, c in ipairs(cols) do
    local f = fs(view, "GameFontDisableSmall", "LEFT")
    f:SetPoint("TOPLEFT", c[2], -86)
    f:SetText(c[1])
  end
  local tbl = CreateFrame("Frame", nil, view)
  tbl:SetPoint("TOPLEFT", X - 4, -100)
  tbl:SetSize(730, ROWS * ROW_H)
  tbl:EnableMouseWheel(true)
  tbl:SetScript("OnMouseWheel", function(_, delta)
    view.offset = (view.offset or 0) - delta
    render()
  end)
  view.rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("Frame", nil, tbl)
    row:SetSize(730, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    UI.Stripe(row, i)
    row.name = fs(row, "GameFontHighlight", "LEFT")
    row.name:SetPoint("LEFT", 4, 0)
    row.name:SetWidth(200)
    row.name:SetWordWrap(false)
    row.max = fs(row, "GameFontHighlightSmall", "LEFT")
    row.max:SetPoint("LEFT", 214, 0)
    row.want = fs(row, "GameFontHighlightSmall", "LEFT")
    row.want:SetPoint("LEFT", 314, 0)
    row.found = fs(row, "GameFontHighlightSmall", "LEFT")
    row.found:SetPoint("LEFT", 364, 0)
    row.found:SetWidth(196)
    row.found:SetWordWrap(true)
    row.action = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.action:SetSize(136, 22)
    row.action:SetPoint("LEFT", 566, 0)
    row.action:SetScript("OnClick", function()
      local e, r = row.e, row.e and sv.results[row.e]
      if not e then return end
      if (sv.buy and sv.buy.entry == e) or (r and r.kind == "commodity") then
        buyClick(e)
      else
        showInBuyTab(e)
      end
    end)
    row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    row.remove:SetSize(22, 22)
    row.remove:SetPoint("LEFT", 704, 0)
    row.remove:SetScript("OnClick", function()
      local list = selectedList()
      for k, x in ipairs(list and list.entries or {}) do
        if x == row.e then
          table.remove(list.entries, k)
          break
        end
      end
      if sv.buy and sv.buy.entry == row.e then cancelBuy() end
      render()
    end)
    view.rows[i] = row
  end
  view.empty = fs(view, "GameFontDisable", "CENTER")
  view.empty:SetPoint("TOPLEFT", X, -150)
  view.empty:SetWidth(700)
  view.empty:SetText("Add the items you buy often, with the most you'd pay. Run List checks them all in one go.")
  view.toast = fs(view, "GameFontHighlightSmall", "LEFT")
  view.toast:SetPoint("BOTTOMLEFT", X, 34)
  view.toast:SetWidth(720)
  local note = fs(view, "GameFontDisableSmall", "LEFT")
  note:SetPoint("BOTTOMLEFT", X, 12)
  note:SetWidth(720)
  note:SetText(
    "Buying takes two clicks: Buy asks the auction house for the exact price, then Confirm buys. Gear: Show puts it in Blizzard's list to buy there."
  )
end

-- SHOP-7: Shift-click an item (bags, links) while the Shopping tab is open to fill the Item box.
if hooksecurefunc and HandleModifiedItemClick then
  hooksecurefunc("HandleModifiedItemClick", function(link)
    if
      view
      and view:IsVisible()
      and view.addBox
      and IsShiftKeyDown()
      and type(link) == "string"
      and link:find("item:")
    then
      view.addBox:SetText(link)
      view.addMax:SetFocus()
    end
  end)
end

GW.ShopView = {}

--- Shows the Shopping tab, building it inside `parent` the first time.
---@param parent table tab content frame
function GW.ShopView.Show(parent)
  if not view then build(parent) end
  view:Show()
  render()
end

--- Hides the Shopping tab, stops a running list and cancels a pending purchase.
function GW.ShopView.Hide()
  if view then view:Hide() end
  GW.StopList()
  cancelBuy()
end

--- The tab state and frame, for debugging.
---@return GoldwrightShoppingState sv
---@return table|nil view
function GW.ShopView.Debug() return sv, view end

local events = CreateFrame("Frame")
for _, e in ipairs({
  "COMMODITY_SEARCH_RESULTS_UPDATED",
  "COMMODITY_SEARCH_RESULTS_ADDED",
  "ITEM_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_ADDED",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
  "COMMODITY_PRICE_UPDATED",
  "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED",
  "COMMODITY_PURCHASE_FAILED",
  "AUCTION_HOUSE_CLOSED",
}) do
  pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "AUCTION_HOUSE_CLOSED" then
    local b = sv.buy
    if b and b.confirming and not b.done then buyUnanswered(b, "The auction house closed before it answered") end
    sv.buy = nil
    GW.StopList()
    return
  end
  -- A confirmed buy's result counts even with the tab closed (it was the player's click).
  local buyResult = event:find("^COMMODITY_PURCHASE")
    and ((sv.buy and sv.buy.confirming) or (not sv.buy and sv.unanswered))
  if not buyResult and not (view and view:IsShown()) then return end
  if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    onBrowseResults()
  elseif event:find("^COMMODITY_P") then
    onBuyEvent(event, a1, a2)
  else
    onSearchResults(event, a1)
  end
end)
