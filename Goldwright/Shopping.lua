--- Shopping lists and the Shopping tab (SHOP-1..8): page 1 lists your lists, page 2 is one list.
--- Lists live in GoldwrightDB.lists (account-wide); running one sends a throttle-aware search per entry.
--- Watched lists are checked against your newest data at login and after a full scan (price watch). Commodities: Buy asks for the exact price
--- (StartCommoditiesPurchase), a second click confirms (ConfirmCommoditiesPurchase), never automatic.
--- Gear: Show sends a browse search so Blizzard's own Buy list shows the item; the player buys there.
local _, GW = ...
local L = GW.L

local ROWS, ROW_H = 10, 30 -- entry table: visible rows, row height
local LIST_ROWS = 11 -- visible rows in the lists column
local SEARCH_TIMEOUT = 6 -- seconds to wait for search results before giving up on an entry
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
---@field watch? boolean price watch on (SHOP-8): Goldwright tells you in chat when an item drops below its max
---@field liveAt? number server time the whole list was last searched at the auction house

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
  -- The English coin letters always work; the game's own (German g s k) work too.
  local value = { g = 10000, s = 100, c = 1 }
  for sym, v in pairs({
    [GOLD_AMOUNT_SYMBOL or "g"] = 10000,
    [SILVER_AMOUNT_SYMBOL or "s"] = 100,
    [COPPER_AMOUNT_SYMBOL or "c"] = 1,
  }) do
    sym = sym:lower()
    if sym ~= "" and not value[sym] then value[sym] = v end
  end
  local total, found, rest = 0, false, text
  for num, unit in text:gmatch("(%d+)%s*([^%d%s]+)") do
    local v = value[unit]
    if not v then return nil, nil end
    found = true
    total = total + tonumber(num) * v
    rest = rest:gsub(num .. "%s*" .. unit:gsub("%p", "%%%0"), "", 1)
  end
  if not found or rest:gsub("%s+", "") ~= "" then return nil, nil end
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
  if itemText == "" then return nil, L["Type an item name or Shift-click an item."] end
  local id, name = GW.LinkItem(itemText)
  if not id then
    name = itemText:gsub('^"(.*)"$', "%1")
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local _, link = getInfo and getInfo(name)
    id = link and GW.LinkItem(link)
  end
  local e = { name = name or string.format(L["item %d"], id), itemID = id }
  if strtrim(maxText or "") ~= "" then
    e.max, e.maxPct = GW.ParseMoney(maxText)
    if not e.max and not e.maxPct then return nil, L["Max price: e.g. 75c, 1s 50c, 2g or 80% (of market)."] end
  end
  if strtrim(wantText or "") ~= "" then
    e.want = tonumber(wantText)
    if not e.want or e.want < 1 then return nil, L["Want: a number of items."] end
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
  local lim = GW.IMPORT_LIMITS
  text = text or ""
  if #text > lim.chars then return {}, L["That text is too long to be a shopping list."] end
  local out, cut = {}, false
  for line in text:gmatch("[^\r\n]+") do
    local pieces = {}
    for p in (line .. "^"):gmatch("([^%^]*)%^") do
      pieces[#pieces + 1] = p
    end
    local name = safeText(pieces[1] or "")
    if name ~= "" and #pieces > 1 then
      if #out >= lim.lists then
        cut = true
        break
      end
      local list = { name = name, entries = {} }
      for i = 2, #pieces do
        if #list.entries >= lim.entries then
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
            local f = fields[j]:sub(1, lim.field)
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
    cut and string.format(L["Only the first %d lists and %d items per list were kept."], lim.lists, lim.entries) or nil
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
  if math.abs(pct) < 3 then return L["at market"], GREY end
  if pct < 0 then
    return string.format(L["%d%% under market"], -pct), pct <= -GW.Opt("signalPct") and GW.SIGNAL_BLUE or GREY
  end
  return string.format(L["%d%% over market"], pct), pct >= GW.Opt("signalPct") and GW.SIGNAL_ORANGE or GREY
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
---@field runLists? GoldwrightShoppingList[] lists the run checks in full (their liveAt is set when it ends)
---@field onDone? function called when the run ends
---@field watchRun? boolean the run is "Check watched lists"
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
    if sv.running and sv.runLists then
      for _, l in ipairs(sv.runLists) do
        l.liveAt = GetServerTime() -- "Checked: live" on page 1
      end
    end
    local done = sv.running and sv.onDone
    sv.running, sv.runLists, sv.onDone, sv.watchRun = false, nil, nil, nil
    if done then done() end
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

--- Starts a run over `entries` (results so far for them are dropped).
---@param entries GoldwrightShoppingEntry[]
---@param lists? GoldwrightShoppingList[] lists the run checks in full: their liveAt is set when it ends
---@param onDone? function called when the run ends (not when it is stopped)
local function startRun(entries, lists, onDone)
  sv.queue, sv.checked, sv.current, sv.token = {}, 0, nil, nil
  for _, e in ipairs(entries) do
    sv.queue[#sv.queue + 1] = e
    sv.results[e] = nil
  end
  sv.total, sv.running, sv.runLists, sv.onDone, sv.watchRun = #sv.queue, true, lists, onDone, nil
  if render then render() end
  runNext()
end

--- SHOP-3: runs the open list (or one entry of it). Needs the auction house open.
---@param only? GoldwrightShoppingEntry check just this entry
function GW.RunList(only)
  if not (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) then return GW.Print(L["Open the auction house first."]) end
  local list = selectedList()
  if not list then return end
  local entries = {}
  for _, e in ipairs(list.entries) do
    if not only or only == e then entries[#entries + 1] = e end
  end
  startRun(entries, not only and { list } or nil)
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
  sv.runLists, sv.onDone, sv.watchRun = nil, nil, nil
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

--- Shopping's purchase going on, if any (GW.Purchase handles one at a time for every tab).
---@return GoldwrightPurchase|nil p with `entry`, the list entry being bought
local function myBuy()
  local p = GW.Purchase.Current()
  return p and p.entry and p or nil
end

--- Lets Shopping's unconfirmed purchase go (a confirmed one is on its way and is left alone).
local function cancelBuy()
  local b = myBuy()
  if b then GW.Purchase.Cancel(b) end
end

--- Saves a Want typed into a list row (blank or 0 clears it). The buy plan depends on Want, so a
--- quote waiting for Confirm is dropped and the item is checked again (when the auction house is open).
---@param e GoldwrightShoppingEntry|nil
---@param text string|nil
local function setWant(e, text)
  if not e then return end
  local n = tonumber(text or "")
  n = n and n >= 1 and math.floor(n) or nil
  if n == e.want then return end
  e.want = n
  local b = myBuy()
  if b and b.entry == e then
    if b.confirming then return end
    cancelBuy()
  end
  if sv.results[e] then GW.CheckEntry(e) end
end

--- Tells the player in the tab and in chat (the tab may be closed by now).
---@param text string
---@param color? number[]
local function tellBuy(text, color)
  toast(text, color)
  if not (view and view:IsShown()) then GW.Print("%s", text) end
end

--- What Shopping says about its purchase (GW.Purchase's onChange): the exact price, with warnings
--- when it is over the max, more gold than the player has or more than the list showed; the result;
--- and what to do when the answer didn't come.
---@param b GoldwrightPurchase
---@param what string
---@param reason? string
local function onBuyChange(b, what, reason)
  local e = b.entry
  if what == "quote" then
    entryName(e)
    local max = GW.EntryMax(e)
    if max and b.unit and b.unit > max then
      toast(
        string.format(
          L["The price went up: %s each is over your max (%s). Confirm only if you still want it."],
          GW.Money(b.unit),
          GW.Money(max)
        ),
        GW.SIGNAL_ORANGE
      )
    elseif b.total and GetMoney and b.total > GetMoney() then
      toast(string.format(L["Not enough gold for %s."], GW.Money(b.total)), GW.SIGNAL_ORANGE)
    elseif b.total and b.total > b.estimate then
      toast(
        string.format(
          L["%d × %s for %s (%s each): %s more than the list showed. Confirm only if you still want it."],
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
          L["%d × %s for %s (%s each). Click Confirm to buy."],
          b.qty,
          e.name,
          GW.Money(b.total),
          GW.Money(b.unit)
        ),
        WHITE
      )
    end
  elseif what == "noPrice" then
    toast(L["No answer from the auction house. Nothing was bought."], GW.SIGNAL_ORANGE)
  elseif what == "expired" then
    toast(L["The price wasn't confirmed in time. Nothing was bought: click Buy again."], GREY)
  elseif what == "unavailable" then
    toast(L["Those listings are gone. Run the list again."], GW.SIGNAL_ORANGE)
  elseif what == "bought" then
    sv.bought[e] = (sv.bought[e] or 0) + b.qty
    tellBuy(string.format(L["Bought %d × %s for %s."], b.qty, e.name, GW.Money(b.total or b.estimate)), GW.SIGNAL_BLUE)
    sv.results[e] = nil
    -- see what's left (only while the tab is open; otherwise the next run checks it)
    C_Timer.After(0.5, function()
      if view and view:IsShown() then GW.CheckEntry(e) end
    end)
  elseif what == "failed" then
    tellBuy(L["The purchase failed. Nothing was bought."], GW.SIGNAL_ORANGE)
  elseif what == "unanswered" then
    -- it may have gone through: the row stops offering it until the list is checked again
    sv.results[e] = nil
    -- the auction house closed: the window goes with it, so this one is always said in chat
    if reason == "closed" then
      GW.Print(
        L["The auction house closed before it answered about %d × %s. It may have been bought: check your mailbox before buying again."],
        b.qty,
        e.name
      )
      if render then render() end
      return
    end
    tellBuy(
      string.format(
        L["No answer from the auction house about %d × %s. It may have been bought: check your mailbox before buying again."],
        b.qty,
        e.name
      ),
      GW.SIGNAL_ORANGE
    )
  elseif what == "lateBought" then
    sv.bought[e] = (sv.bought[e] or 0) + b.qty
    tellBuy(string.format(L["It went through after all: bought %d × %s."], b.qty, e.name), GW.SIGNAL_BLUE)
  elseif what == "lateFailed" then
    tellBuy(string.format(L["The purchase of %d × %s failed. Nothing was bought."], b.qty, e.name), GW.SIGNAL_ORANGE)
  end
  if render then render() end
end

--- The Buy / Confirm button of a commodity row. First click asks the auction house for the exact
--- price of the planned units; a second click, once the price is known, confirms the purchase
--- (GW.Purchase). Refused in combat.
---@param e GoldwrightShoppingEntry
local function buyClick(e)
  local res = sv.results[e]
  local b = myBuy()
  if InCombatLockdown and InCombatLockdown() then return toast(L["Not in combat."], GW.SIGNAL_ORANGE) end
  if b and b.confirming then return end -- already buying: never confirm twice
  if b and b.entry == e and b.total then
    -- second click: confirm at the quoted price (not within the pause after the quote)
    if not GW.Purchase.Confirm(b) then return end
    toast(L["Buying…"], GREY)
    if render then render() end
    return
  end
  if not (res and res.kind == "commodity" and res.plan.units > 0) then return end
  entryName(e)
  local p = GW.Purchase.Start({
    itemID = e.itemID,
    name = e.name,
    qty = res.plan.units,
    estimate = res.plan.total,
    entry = e,
    onChange = onBuyChange,
  })
  if not p then return end
  toast(L["Asking the auction house for the exact price…"], GREY)
  if render then render() end
end

--- The Show button of a gear row: sends a browse search so Blizzard's Buy list shows the item.
---@param e GoldwrightShoppingEntry
local function showInBuyTab(e)
  if not GW.CanSearch() then return toast(L["Waiting for a search slot: try again in a moment."], GW.SIGNAL_ORANGE) end
  GW.NoteSearch()
  C_AuctionHouse.SendBrowseQuery({ searchString = e.name, sorts = sorts(), filters = {}, itemClassFilters = {} })
  toast(L["Shown in Blizzard's list on the left: buy it there."], GREY)
end

---------------------------------------------------------------------------
-- price watch (SHOP-8): watched lists checked against your newest data (data pack or full scan)
---------------------------------------------------------------------------
local WATCH_LOGIN_DELAY = 8 -- seconds after login before the watch line, so it isn't lost in the login messages

--- Your newest numbers for an entry at the auction house you shop at (Blackwater in neutral towns):
--- the data pack, or your own full scan when it is newer (GW.ItemData).
---@param e GoldwrightShoppingEntry
---@return GoldwrightItemSide|nil
function GW.EntryData(e)
  local d = e.itemID and GW.ItemData(e.itemID)
  local side = GW.AuctionSide and GW.AuctionSide() or GW.House().side
  return d and d[side] or nil
end

--- The entries of a list whose cheapest real listing in your newest data is at or under their max.
---@param list GoldwrightShoppingList
---@return { entry: GoldwrightShoppingEntry, price: number, max: number }[]
function GW.WatchHits(list)
  local out = {}
  for _, e in ipairs(list.entries) do
    local s, max = GW.EntryData(e), GW.EntryMax(e)
    if s and s.min and max and s.min <= max then out[#out + 1] = { entry = e, price = s.min, max = max } end
  end
  return out
end

--- Where the watch remembers what it already told you: per house, the items that were below max on
--- a watched list at the last check.
---@return table watch GoldwrightDB.watch
---@return string key region, ruleset and house, e.g. "US_Normal:A"
local function watchState()
  GoldwrightDB.watch = GoldwrightDB.watch or {}
  local w = GoldwrightDB.watch
  w.seen = w.seen or {}
  w.dataAt = nil -- 0.7.0-dev kept the data time; the check now runs at every login
  local side = GW.AuctionSide and GW.AuctionSide() or GW.House().side
  return w, GW.House().packKey .. ":" .. side
end

--- Server time of your newest data for the house you shop at: the pack's snapshot or your full scan.
---@return number serverTime 0 without data
function GW.WatchDataAt()
  local side = GW.AuctionSide and GW.AuctionSide() or GW.House().side
  local at = GW.pack and GW.pack.snapshotAt or 0
  local sc = GW.HouseScans and GW.HouseScans()[side]
  if sc and sc.at and sc.at > at then at = sc.at end
  return at
end

--- How many lists are watched.
---@return number
function GW.WatchedCount()
  local c = 0
  for _, l in ipairs(GW.Lists()) do
    if l.watch then c = c + 1 end
  end
  return c
end

--- Checks every watched list against your newest data and shows the items that dropped to or under
--- your max since the last check in the price watch window (WatchView.lua), with one short line in
--- chat. An item on several lists counts once, under its first list. Nothing is searched or bought.
---@param all? boolean show every item below max, not only new ones, and say so when there are none (a check you asked for)
---@return number hits items below max on watched lists
---@return number told items shown
function GW.WatchCheck(all)
  local w, key = watchState()
  local seen = w.seen[key] or {}
  local now, hits = {}, {}
  for index, l in ipairs(GW.Lists()) do
    if l.watch then
      for _, h in ipairs(GW.WatchHits(l)) do
        local id = h.entry.itemID
        if not now[id] then
          now[id] = true
          h.list, h.index = l, index
          hits[#hits + 1] = h
        end
      end
    end
  end
  local tell = {}
  for _, h in ipairs(hits) do
    if all or not seen[h.entry.itemID] then tell[#tell + 1] = h end
  end
  w.seen[key] = now
  if #tell > 0 then
    GW.Print(
      "%s",
      GW.Plural(
        #tell,
        "%d item on your watched lists is below your max price. /gw watch shows it again.",
        "%d items on your watched lists are below your max price. /gw watch shows them again."
      )
    )
    if GW.ShowWatch then GW.ShowWatch(tell, GW.WatchDataAt()) end
  elseif all then
    GW.Print("%s", L["Nothing on your watched lists is below your max price."])
  end
  GW.Log("watch check: %d below max, %d told", #hits, #tell)
  return #hits, #tell
end

--- The automatic check, at every login and after a full scan: tells you about items you haven't
--- been told about yet (a new day's prices, or a list you started watching since). Items already
--- told stay quiet until they go back above your max and dip again.
---@return boolean ran false without a watched list or any data
function GW.WatchIfNew()
  if GW.WatchedCount() == 0 or GW.WatchDataAt() == 0 then return false end
  GW.WatchCheck()
  return true
end

GW.OnLogin(function()
  C_Timer.After(WATCH_LOGIN_DELAY, function() GW.WatchIfNew() end)
end)

---------------------------------------------------------------------------
-- the Shopping tab: page 1 lists your lists, page 2 is one list (breadcrumb back to page 1)
---------------------------------------------------------------------------
local n = GW.Number

--- What your newest data says about an entry that hasn't been searched: today's cheapest real
--- listing against your max, with how old the data is.
---@param e GoldwrightShoppingEntry
---@return string|nil text nil without data
---@return number[]? color
local function dataText(e)
  local s = GW.EntryData(e)
  if not (s and s.min) then return nil end
  local label = string.format(s.source == "scan" and L["Your scan %s"] or L["Data %s"], GW.Age(s.at))
  local max = GW.EntryMax(e)
  if max and s.min <= max then
    return string.format(L["%s: %s, under your max · %s listed"], label, GW.Money(s.min), n(s.units)), GW.SIGNAL_BLUE
  elseif max then
    return string.format(L["%s: cheapest %s, over your max"], label, GW.Money(s.min)), GREY
  end
  return string.format(L["%s: %s listed from %s"], label, n(s.units), GW.Money(s.min)), GREY
end

--- The "Found" column text for an entry: search state, what its last search found, or else what
--- your newest data says.
---@param e GoldwrightShoppingEntry
---@return string text
---@return number[] color {r, g, b}
local function foundText(e)
  local r = sv.results[e]
  if sv.current == e then return L["Searching…"], GREY end
  if not r then
    for _, q in ipairs(sv.queue) do
      if q == e then return L["Waiting…"], GREY end
    end
    local text, color = dataText(e)
    if text then return text, color end
    return (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) and L["Not checked yet: Run List"] or L["Not checked yet"],
      GREY
  end
  if r.kind == "unknown" then return L["No answer from the auction house"], GREY end
  if r.kind == "none" then return L["None listed"], GREY end
  if r.kind == "notfound" then return L["No item by that name is listed"], GW.SIGNAL_ORANGE end
  local p, max = r.plan, GW.EntryMax(e)
  if not p.cheapest then return L["None listed"], GREY end
  if max and p.available == 0 then
    return string.format(L["Nothing under %s (cheapest %s)"], GW.Money(max), GW.Money(p.cheapest)), GREY
  end
  local text
  if r.kind == "commodity" then
    text = (
      max and string.format(L["%s at ≤ %s"], n(p.available), GW.Money(max))
      or string.format(L["%s listed from %s"], n(p.listed), GW.Money(p.cheapest))
    ) .. (sv.bought[e] and (" · " .. string.format(L["bought %d"], sv.bought[e])) or "")
  else
    text = string.format(L["%s listed from %s"], n(p.listed), GW.Money(p.cheapest))
      .. (r.variants and r.variants > 1 and (" " .. GW.Plural(r.variants, "(%d version)", "(%d versions)")) or "")
  end
  local mt, color = GW.MarketText(p.avg or p.cheapest, e.itemID)
  return text .. (mt and ("  ·  " .. mt) or ""), color or WHITE
end

--- The items of a list at or under their max: from this session's searches, else (watched lists
--- only) from your newest data.
---@param l GoldwrightShoppingList
---@return number|nil count nil when nothing is known (an unwatched list not searched this session)
---@return string[] names
local function belowOf(l)
  local count, names, known = 0, {}, l.watch == true
  for _, e in ipairs(l.entries) do
    local r, max, hit = sv.results[e], GW.EntryMax(e), false
    if r then
      known = true
      hit = max ~= nil and r.plan ~= nil and r.plan.available > 0
    elseif l.watch then
      local s = GW.EntryData(e)
      hit = s ~= nil and s.min ~= nil and max ~= nil and s.min <= max
    end
    if hit then
      count = count + 1
      names[#names + 1] = entryName(e)
    end
  end
  return known and count or nil, names
end

--- When a list was last checked: live at the auction house, or your newest data (watched lists).
---@param l GoldwrightShoppingList
---@return string
local function checkedText(l)
  local at = GW.WatchDataAt()
  if l.liveAt and (not l.watch or l.liveAt >= at) then return string.format(L["live, %s"], GW.Age(l.liveAt)) end
  if l.watch and at > 0 then return string.format(L["data, %s"], GW.Age(at)) end
  return "–"
end

--- The search progress text while a run is going ("" when idle).
---@return string
local function progressText()
  if sv.waiting then return GW.WaitText() end
  if sv.running and sv.total > 0 then
    return string.format(
      L["Searched %d of %d · %d searches this minute"],
      sv.checked,
      sv.total,
      GW.SearchesThisMinute()
    )
  end
  return ""
end

--- The move / rename / duplicate / delete buttons of a page 1 row: up and down only where the list
--- can move; dimmed unless the row is under the mouse or a controller is in use; the row lit on hover.
---@param row table
local function showTools(row)
  local i, count = row.index, #GW.Lists()
  row.icons.up:SetEnabled(i > 1)
  row.icons.down:SetEnabled(i < count)
  -- quiet until the mouse is on the row; always full with a controller (no mouse to hover)
  local on = row.hover or (GW.Gamepad and GW.Gamepad.on)
  for _, b in pairs(row.icons) do
    b:SetAlpha(on and 1 or 0.45)
  end
  row.lit:SetShown(row.hover == true)
end

--- Page 1: your lists, with what is below your max on each.
local function renderLists()
  local lists = GW.Lists()
  local p = view.listsPage
  p.offset = math.max(0, math.min(p.offset or 0, math.max(0, #lists - LIST_ROWS)))
  local below = 0
  for i, row in ipairs(view.listRows) do
    local l = lists[i + p.offset]
    row.index = i + p.offset
    if l then
      row:Show()
      row.name:SetText(l.name)
      row.count:SetText(tostring(#l.entries))
      local c, names = belowOf(l)
      if c and c > 0 then
        row.below:SetText(c .. " · " .. table.concat(names, ", "))
        setColor(row.below, GW.SIGNAL_BLUE)
      else
        row.below:SetText(c and L["none"] or "–")
        setColor(row.below, GREY)
      end
      row.checked:SetText(checkedText(l))
      row.eye.icon:SetDesaturated(not l.watch)
      row.eye.icon:SetAlpha(l.watch and 1 or 0.35)
      showTools(row)
    else
      row:Hide()
    end
  end
  for _, l in ipairs(lists) do
    if l.watch then below = below + #GW.WatchHits(l) end
  end
  local progress = progressText()
  if progress ~= "" then
    p.meta:SetText(progress)
  else
    local parts = { GW.Plural(#lists, "%d list", "%d lists") }
    local watched = GW.WatchedCount()
    if watched > 0 then
      parts[#parts + 1] = string.format(L["%d watched"], watched)
      parts[#parts + 1] = GW.Plural(below, "%d item below your max", "%d items below your max")
      parts[#parts + 1] = string.format(L["data, %s"], GW.Age(GW.WatchDataAt()))
    end
    p.meta:SetText(#lists > 0 and table.concat(parts, " · ") or "")
  end
  p.check:SetText(sv.running and sv.watchRun and L["Stop"] or L["Check Watched Lists"])
  p.empty:SetShown(#lists == 0)
  p.hint:SetText(
    (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) and L["Click a list to open it. The spyglass watches its prices."]
      or L["Away from the auction house: change your lists and their watch here. Searching needs the auction house."]
  )
  for _, b in ipairs(view.listButtons) do
    b:SetEnabled(#lists > 0 or b.always)
  end
end

--- Page 2: one list, its add-item boxes and entry table.
---@param list GoldwrightShoppingList
local function renderList(list)
  view.title:SetText(list.name)
  view.watch:SetChecked(list.watch == true)
  local progress = progressText()
  if progress == "" then
    local parts = { GW.Plural(#list.entries, "%d item", "%d items") }
    local c = belowOf(list)
    if c then parts[#parts + 1] = GW.Plural(c, "%d below your max", "%d below your max") end
    progress = table.concat(parts, " · ")
  end
  view.progress:SetText(progress)
  local atAH = GW.AuctionHouseOpen and GW.AuctionHouseOpen()
  view.run:SetText(sv.running and L["Stop"] or L["Run List"])
  view.run:SetEnabled(#list.entries > 0 and atAH or false)
  view.note:SetText(
    atAH
        and L["Buying takes two clicks: Buy asks the auction house for the exact price, then Confirm buys. Gear: Show puts it in Blizzard's list to buy there."]
      or L["Away from the auction house you can change your lists and their watch. Searching and buying need the auction house."]
  )

  local entries = list.entries
  view.offset = math.max(0, math.min(view.offset or 0, math.max(0, #entries - ROWS)))
  for i, row in ipairs(view.rows) do
    local e = entries[i + view.offset]
    row.e = e
    if e then
      row:Show()
      row.name:SetText(e.itemID and entryName(e) or string.format(L["%s  |cff9a9aa2(not found yet)|r"], entryName(e)))
      local max = GW.EntryMax(e)
      row.max:SetText(
        e.maxPct and (e.maxPct .. "%" .. (max and (" · " .. GW.Money(max)) or ""))
          or (e.max and GW.Money(e.max))
          or "–"
      )
      if not row.want:HasFocus() then row.want:SetText(e.want and tostring(e.want) or "") end
      local text, color = foundText(e)
      row.found:SetText(text)
      setColor(row.found, color)
      local r = sv.results[e]
      local b = myBuy()
      if b and b.entry == e then
        row.action:Show()
        row.action:SetText(
          b.confirming and L["Buying…"]
            or b.total and string.format(L["Confirm · %s"], GW.Money(b.total))
            or L["Getting Price…"]
        )
        row.action:SetEnabled(
          atAH and b.total ~= nil and not b.confirming and GetTime() - (b.quotedAt or 0) >= GW.CONFIRM_DELAY or false
        )
      elseif r and r.kind == "commodity" and r.plan.units > 0 and e.want then
        row.action:Show()
        row.action:SetText(string.format(L["Buy %d · %s"], r.plan.units, GW.Money(r.plan.total)))
        row.action:SetEnabled(atAH and GW.Purchase.Current() == nil or false)
      elseif r and r.kind == "commodity" and r.plan.available > 0 then
        row.action:Show()
        row.action:SetText(L["Set Want to Buy"])
        row.action:Disable()
      elseif r and r.kind == "item" and r.plan.available > 0 then
        row.action:Show()
        row.action:SetText(L["Show"])
        row.action:SetEnabled(atAH or false)
      else
        row.action:Hide()
      end
    else
      row:Hide()
    end
  end
  view.empty:SetShown(#entries == 0)
end

--- Redraws the Shopping tab: page 2 when a list is open (GoldwrightDB.shopPage), else page 1.
--- Does nothing while the tab is hidden.
render = function()
  if not (view and view:IsShown()) then return end
  local list = selectedList()
  local onList = GoldwrightDB.shopPage == "list" and list ~= nil
  view.listsPage:SetShown(not onList)
  view.listPage:SetShown(onList)
  if onList then
    renderList(list)
  else
    renderLists()
  end
end

--- Opens a list (page 2).
---@param i number index in GW.Lists()
local function openList(i)
  GoldwrightDB.listSel, GoldwrightDB.shopPage = i, "list"
  cancelBuy()
  view.offset = 0
  render()
end

--- Back to your lists (page 1).
local function showLists()
  GoldwrightDB.shopPage = nil
  cancelBuy()
  render()
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
  text = L['Delete the shopping list "%s"?'],
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
  local c = { name = string.format(L["%s (copy)"], l.name), entries = {} }
  for _, e in ipairs(l.entries) do
    c.entries[#c.entries + 1] = { name = e.name, itemID = e.itemID, max = e.max, maxPct = e.maxPct, want = e.want }
  end
  return c
end

--- Whether a list has an item already (same id or same name): an item is on a list once, on as
--- many lists as you like.
---@param list GoldwrightShoppingList
---@param itemID number|nil
---@param name string
---@return boolean
function GW.ListHas(list, itemID, name)
  for _, x in ipairs(list.entries) do
    if (itemID and x.itemID == itemID) or x.name:lower() == name:lower() then return true end
  end
  return false
end

--- Asks for a new list's name and makes the list (empty).
---@param apply fun(list: GoldwrightShoppingList) called with the new list
function GW.AskNewList(apply)
  askName(L["Name the new shopping list:"], "", function(name)
    local lists = GW.Lists()
    local list = { name = name, entries = {} }
    lists[#lists + 1] = list
    apply(list)
  end)
end

--- SHOP-7: adds an item to a list: the one given, else the selected list (or a new "Shopping" list
--- when there is none). Refuses an item already in that list (same id or same name).
---@param itemText? string see GW.MakeEntry
---@param maxText? string
---@param wantText? string
---@param list? GoldwrightShoppingList
---@return GoldwrightShoppingEntry|nil entry
---@return GoldwrightShoppingList|string list the list it went into, or an error message
function GW.AddToList(itemText, maxText, wantText, list)
  local lists = GW.Lists()
  list = list or selectedList()
  if not list then
    list = { name = L["Shopping"], entries = {} }
    lists[#lists + 1] = list
    GoldwrightDB.listSel = #lists
  end
  local e, err = GW.MakeEntry(itemText, maxText, wantText)
  if not e then return nil, err end
  if GW.ListHas(list, e.itemID, e.name) then return nil, string.format(L["%s is already in %s."], e.name, list.name) end
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
    io.ok = UI.NewButton(io)
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
            and GW.Plural(
              #got,
              "Imported %d list with %s.",
              "Imported %d lists with %s.",
              GW.Plural(items, "%d item", "%d items")
            )
          or L["Nothing to import: one list per line, Name^Item^Item."]
        if problem then msg = (#got > 0 and msg .. " " or "") .. problem end
        toast(msg, (#got > 0 and not problem) and GW.SIGNAL_BLUE or GW.SIGNAL_ORANGE)
      end
      io:Hide()
      if render then render() end
    end)
  end
  io.mode = mode
  if io.SetTitle then io:SetTitle(mode == "import" and L["Import Shopping Lists"] or L["Export Shopping Lists"]) end
  if mode == "import" then
    io.hint:SetText(
      L["Paste lists here, one per line: List name^Item^Item;max=75c;qty=20. Auctionator lists work too (names only)."]
    )
    io.box:SetText("")
    if io.box.SetMaxLetters then io.box:SetMaxLetters(GW.IMPORT_LIMITS.chars + 1) end -- +1: "too long" is reported
    io.ok:SetText(L["Import"])
  else
    io.hint:SetText(L["Copy this text (Ctrl+A, then Ctrl+C). It holds all your lists."])
    if io.box.SetMaxLetters then io.box:SetMaxLetters(0) end -- no limit on your own lists
    io.box:SetText(GW.ExportLists(GW.Lists()))
    io.ok:SetText(L["Close"])
    io.box:HighlightText()
  end
  io:Show()
  io.box:SetFocus()
end

--- "Check watched lists": at the auction house, searches every entry of every watched list live (one
--- run, Stop stops it) and says how many are under your max; away from it, checks your newest data
--- and names every item below max in chat (GW.WatchCheck).
function GW.CheckWatched()
  if sv.running and sv.watchRun then return GW.StopList() end
  local lists = {}
  for _, l in ipairs(GW.Lists()) do
    if l.watch then lists[#lists + 1] = l end
  end
  if #lists == 0 then
    return toast(L["No list is watched yet: click the spyglass next to a list."], GW.SIGNAL_ORANGE)
  end
  if not (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) then
    local hits = GW.WatchCheck(true)
    return toast(
      GW.Plural(hits, "%d item below your max in your newest data.", "%d items below your max in your newest data."),
      hits > 0 and GW.SIGNAL_BLUE or GREY
    )
  end
  local entries = {}
  for _, l in ipairs(lists) do
    for _, e in ipairs(l.entries) do
      entries[#entries + 1] = e
    end
  end
  startRun(entries, lists, function()
    local hits = 0
    for _, e in ipairs(entries) do
      local r, max = sv.results[e], GW.EntryMax(e)
      if r and r.plan and max and r.plan.available > 0 then hits = hits + 1 end
    end
    toast(
      GW.Plural(
        #lists,
        "Checked %d watched list live: %s.",
        "Checked %d watched lists live: %s.",
        GW.Plural(hits, "%d item below your max", "%d items below your max")
      ),
      hits > 0 and GW.SIGNAL_BLUE or GREY
    )
  end)
  sv.watchRun = true
  render()
end

--- Turns the price watch of a list on or off, and says what that means.
---@param l GoldwrightShoppingList
---@param on boolean
local function setWatch(l, on)
  l.watch = on or nil
  if on then
    local hits = #GW.WatchHits(l)
    toast(
      string.format(L["Watching %s: Goldwright tells you in chat when an item drops below your max."], l.name)
        .. (hits > 0 and (" " .. GW.Plural(hits, "%d is below it now.", "%d are below it now.")) or ""),
      GW.SIGNAL_BLUE
    )
  else
    toast(string.format(L["Stopped watching %s."], l.name), GREY)
  end
  render()
end

--- Builds page 1: your lists, one row each (watch spyglass, name, items, below your max, last
--- checked, then move / rename / duplicate / delete), New List, Check watched lists, Import, Export
--- and Blackwater gaps.
---@param p table page frame
local function buildListsPage(p)
  p.title = fs(p, "GameFontNormalLarge", "LEFT")
  p.title:SetPoint("TOPLEFT", 14, -8)
  p.title:SetText(L["Shopping"])
  p.meta = fs(p, "GameFontDisableSmall", "LEFT")
  p.meta:SetPoint("LEFT", p.title, "RIGHT", 12, 0)
  p.meta:SetWidth(520)
  p.meta:SetWordWrap(false)

  view.listButtons = {}
  --- A list-page button.
  ---@param label string
  ---@param w number width
  ---@param always boolean enabled even when there is no list
  ---@param fn function click handler
  ---@return table button
  local function lbtn(label, w, always, fn)
    local b = UI.Button(p, label, w, 22, fn)
    b.always = always
    view.listButtons[#view.listButtons + 1] = b
    return b
  end
  local newList = lbtn(L["New List"], 100, true, function()
    askName(L["Name the new shopping list:"], "", function(name)
      local lists = GW.Lists()
      lists[#lists + 1] = { name = name, entries = {} }
      openList(#lists)
    end)
  end)
  newList:SetPoint("TOPRIGHT", -12, -5)
  p.check = lbtn(L["Check Watched Lists"], 150, false, function() GW.CheckWatched() end)
  p.check:SetPoint("RIGHT", newList, "LEFT", -6, 0)
  UI.HoverTip(
    p.check,
    L["At the auction house: searches every watched list now. Elsewhere: checks your newest data and lists what is below your max in chat."]
  )
  lbtn(L["Import"], 100, true, function() showIO("import") end):SetPoint("BOTTOMLEFT", 14, 10)
  lbtn(L["Export"], 100, false, function() showIO("export") end):SetPoint("BOTTOMLEFT", 120, 10)
  -- Items worth carrying to or from Blackwater, to add to a list (GapsView.lua).
  lbtn(L["Blackwater Gaps"], 140, true, function()
    if GW.OpenGaps then GW.OpenGaps() end
  end):SetPoint("BOTTOMLEFT", 226, 10)
  p.hint = fs(p, "GameFontDisableSmall", "LEFT")
  p.hint:SetPoint("BOTTOMLEFT", 380, 15)
  p.hint:SetWidth(590)

  for _, c in ipairs({
    { L["Watch"], 12 },
    { L["List"], 54 },
    { L["Items"], 360 },
    { L["Below your max"], 420 },
    { L["Checked"], 650 },
  }) do
    local f = fs(p, "GameFontDisableSmall", "LEFT")
    f:SetPoint("TOPLEFT", c[2], -40)
    f:SetText(c[1])
  end

  --- Moves list i up (-1) or down (1).
  ---@param i number
  ---@param d number
  local function move(i, d)
    local lists = GW.Lists()
    if lists[i] and lists[i + d] then
      lists[i], lists[i + d] = lists[i + d], lists[i]
      if GoldwrightDB.listSel == i then
        GoldwrightDB.listSel = i + d
      elseif GoldwrightDB.listSel == i + d then
        GoldwrightDB.listSel = i
      end
      render()
    end
  end
  local function rename(i)
    local l = GW.Lists()[i]
    if l then
      askName(L["Rename the shopping list:"], l.name, function(name)
        l.name = name
        render()
      end)
    end
  end
  local function copy(i)
    local l = GW.Lists()[i]
    if l then
      table.insert(GW.Lists(), i + 1, copyList(l))
      render()
    end
  end
  local function delete(i)
    local l = GW.Lists()[i]
    if not l then return end
    StaticPopup_Show("GOLDWRIGHT_LIST_DELETE", l.name, nil, {
      apply = function()
        table.remove(GW.Lists(), i)
        if (GoldwrightDB.listSel or 1) >= i then GoldwrightDB.listSel = math.max(1, (GoldwrightDB.listSel or 1) - 1) end
        GW.StopList()
        render()
      end,
    })
  end
  -- The tools column: always there (so the controller's cursor reaches them: it skips hidden
  -- buttons), dimmed until the mouse is on the row. Left to right: move up, move down, rename,
  -- duplicate, delete.
  local TOOLS = {
    {
      key = "up",
      tex = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton",
      tip = L["Move up"],
      fn = function(i) move(i, -1) end,
    },
    {
      key = "down",
      tex = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton",
      tip = L["Move down"],
      fn = function(i) move(i, 1) end,
    },
    { key = "rename", tex = "Interface\\Buttons\\UI-GuildButton-PublicNote", tip = L["Rename"], fn = rename },
    { key = "copy", tex = "Interface\\Buttons\\UI-PlusButton", tip = L["Duplicate this list"], fn = copy },
    { key = "delete", close = true, tip = L["Delete this list"], fn = delete },
  }

  --- The row stays lit while the mouse is over any part of it (its buttons included).
  ---@param row table
  local function leave(row)
    row.hover = (row.IsMouseOver and row:IsMouseOver()) and true or false
    showTools(row)
  end
  --- Hover handlers for a part of a row: lights the row; `tip` adds a tooltip.
  ---@param row table
  ---@param b table the part (a button)
  ---@param tip? fun(): string, string? tooltip title and optional text
  local function hoverPart(row, b, tip)
    b:SetScript("OnEnter", function(self)
      row.hover = true
      showTools(row)
      if tip then
        local title, text = tip()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title)
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
      end
    end)
    b:SetScript("OnLeave", function()
      GameTooltip:Hide()
      leave(row)
    end)
  end

  local tbl = CreateFrame("Frame", nil, p)
  tbl:SetPoint("TOPLEFT", 8, -56)
  tbl:SetSize(968, LIST_ROWS * ROW_H)
  tbl:EnableMouseWheel(true)
  tbl:SetScript("OnMouseWheel", function(_, delta)
    p.offset = (p.offset or 0) - delta
    render()
  end)
  view.listRows = {}
  for i = 1, LIST_ROWS do
    -- A row is a frame of separate buttons side by side (spyglass, the list itself, the tools), not
    -- buttons inside a button, so the controller's cursor can tell them apart.
    local row = CreateFrame("Frame", nil, tbl)
    row:SetSize(968, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    UI.Stripe(row, i)
    row.lit = row:CreateTexture(nil, "BACKGROUND")
    row.lit:SetAllPoints()
    row.lit:SetColorTexture(1, 0.82, 0, 0.12)
    row.lit:Hide()
    -- the watch switch: a spyglass, lit when watched
    row.eye = CreateFrame("Button", nil, row)
    row.eye:SetSize(24, 24)
    row.eye:SetPoint("LEFT", 8, 0)
    row.eye.icon = row.eye:CreateTexture(nil, "ARTWORK")
    row.eye.icon:SetAllPoints()
    row.eye.icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_03")
    row.eye:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    row.eye:SetScript("OnClick", function()
      local l = GW.Lists()[row.index]
      if l then setWatch(l, not l.watch) end
    end)
    hoverPart(row, row.eye, function()
      local l = GW.Lists()[row.index]
      return l and l.watch and L["Watching prices: click to stop."] or L["Watch prices"],
        L["Once a day and after a full scan, Goldwright tells you in chat when an item on this list drops below your max price. Nothing is searched or bought."]
    end)
    -- the list itself: name, items, below your max, checked; a click opens it
    row.open = CreateFrame("Button", nil, row)
    row.open:SetPoint("TOPLEFT", 40, 0)
    row.open:SetSize(730, ROW_H)
    row.open:SetScript("OnClick", function() openList(row.index) end)
    hoverPart(row, row.open)
    row.name = fs(row.open, "GameFontHighlight", "LEFT")
    row.name:SetPoint("LEFT", 6, 0)
    row.name:SetWidth(300)
    row.name:SetWordWrap(false)
    row.count = fs(row.open, "GameFontHighlightSmall", "LEFT")
    row.count:SetPoint("LEFT", 312, 0)
    row.below = fs(row.open, "GameFontHighlightSmall", "LEFT")
    row.below:SetPoint("LEFT", 372, 0)
    row.below:SetWidth(220)
    row.below:SetWordWrap(false)
    row.checked = fs(row.open, "GameFontHighlightSmall", "LEFT")
    row.checked:SetPoint("LEFT", 602, 0)
    row.checked:SetWidth(124)
    row.checked:SetWordWrap(false)
    setColor(row.checked, GREY)
    row.icons = {}
    for k, t in ipairs(TOOLS) do
      local b
      if t.close then
        b = UI.NewCloseButton(row) -- the same red X that removes an item on the list page
      else
        b = CreateFrame("Button", nil, row)
        b:SetNormalTexture(t.tex .. "-Up")
        b:SetPushedTexture(t.tex .. "-Down")
        b:SetDisabledTexture(t.tex .. "-Disabled")
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
      end
      b:SetSize(24, 24)
      b:SetPoint("LEFT", 782 + (k - 1) * 30, 0)
      b:SetScript("OnClick", function() t.fn(row.index) end)
      hoverPart(row, b, function() return t.tip end)
      row.icons[t.key] = b
    end
    local arrow = fs(row, "GameFontDisableLarge", "RIGHT")
    arrow:SetPoint("RIGHT", -10, 0)
    arrow:SetText("›")
    view.listRows[i] = row
  end
  p.empty = fs(p, "GameFontDisable", "CENTER")
  p.empty:SetPoint("TOP", 0, -150)
  p.empty:SetWidth(700)
  p.empty:SetText(L["No lists yet: click New List"])
end

--- A button that is greyed out away from the auction house says why in its tooltip.
---@param b table
local function needsAH(b)
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  b:SetScript("OnEnter", function(self)
    if self:IsEnabled() or (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(L["Searching and buying need the auction house."])
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- Builds page 2: the breadcrumb (Shopping › list name, with rename), Watch prices and Run List, the
--- add-item boxes and the entry table.
---@param p table page frame
local function buildListPage(p)
  -- breadcrumb: "Shopping" goes back to your lists
  view.back = CreateFrame("Button", nil, p)
  view.back:SetPoint("TOPLEFT", 12, -5)
  view.back:SetNormalFontObject("GameFontNormalLarge")
  view.back:SetHighlightFontObject("GameFontHighlightLarge")
  view.back:SetText(L["Shopping"])
  local bfs = view.back:GetFontString()
  view.back:SetSize(math.max(60, (bfs and bfs:GetStringWidth() or 0) + 4), 24)
  view.back:SetScript("OnClick", showLists)
  UI.HoverTip(view.back, L["Back to your lists"])
  local sep = fs(p, "GameFontDisableLarge", "LEFT")
  sep:SetPoint("LEFT", view.back, "RIGHT", 6, 0)
  sep:SetText("›")
  view.title = fs(p, "GameFontHighlightLarge", "LEFT")
  view.title:SetPoint("LEFT", sep, "RIGHT", 8, 0)
  view.title:SetWordWrap(false)
  view.rename = CreateFrame("Button", nil, p)
  view.rename:SetSize(16, 16)
  view.rename:SetPoint("LEFT", view.title, "RIGHT", 8, 0)
  view.rename:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
  view.rename:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  view.rename:SetScript("OnClick", function()
    local list = selectedList()
    if list then
      askName(L["Rename the shopping list:"], list.name, function(name)
        list.name = name
        render()
      end)
    end
  end)
  UI.HoverTip(view.rename, L["Rename"])
  view.progress = fs(p, "GameFontDisableSmall", "LEFT")
  view.progress:SetPoint("LEFT", view.rename, "RIGHT", 12, 0)

  view.run = UI.NewButton(p)
  view.run:SetSize(120, 24)
  view.run:SetPoint("TOPRIGHT", -12, -4)
  view.run:SetScript("OnClick", function()
    if sv.running then
      GW.StopList()
    else
      GW.RunList()
    end
  end)
  needsAH(view.run)
  view.watch = UI.NewCheckButton(p)
  view.watch:SetSize(24, 24)
  view.watch:SetPoint("TOPRIGHT", view.run, "TOPLEFT", -110, 0)
  local wt = view.watch.Text or view.watch.text
  if not wt then
    wt = fs(view.watch, "GameFontNormalSmall", "LEFT")
    wt:SetPoint("LEFT", view.watch, "RIGHT", 2, 0)
  end
  wt:SetText(L["Watch prices"])
  view.watch:SetScript("OnClick", function(self)
    local list = selectedList()
    if list then setWatch(list, self:GetChecked() and true or false) end
  end)
  view.watch:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(L["Watch prices"])
    GameTooltip:AddLine(
      L["Once a day and after a full scan, Goldwright tells you in chat when an item on this list drops below your max price. Nothing is searched or bought."],
      1,
      1,
      1,
      true
    )
    GameTooltip:Show()
  end)
  view.watch:SetScript("OnLeave", function() GameTooltip:Hide() end)

  --- An input with a short label above and grey example text inside while it is empty.
  ---@param w number width
  ---@param x number left offset in the tab
  ---@param label string
  ---@param placeholder string
  ---@return table editBox
  local function box(w, x, label, placeholder)
    local b = UI.NewEditBox(p)
    b:SetSize(w, 22)
    b:SetPoint("TOPLEFT", x, -52)
    b:SetAutoFocus(false)
    b.label = fs(p, "GameFontNormalSmall", "LEFT")
    b.label:SetPoint("BOTTOMLEFT", b, "TOPLEFT", -4, 5)
    b.label:SetText(label)
    b.placeholder = fs(b, "GameFontDisable", "LEFT")
    b.placeholder:SetPoint("LEFT", 2, 0)
    b.placeholder:SetText(placeholder)
    b:SetScript("OnTextChanged", function(self) self.placeholder:SetShown((self:GetText() or "") == "") end)
    b:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return b
  end
  view.addBox = box(360, 20, L["Item"], L["Type a name or Shift-click an item"])
  view.addMax = box(120, 398, L["Max price"], L["75c, 2g or 80%"])
  view.addWant = box(60, 536, L["Want"], "20")
  view.addWant:SetNumeric(true)
  view.add = UI.Button(p, L["Add Item"], 100, 22)
  view.add:SetPoint("TOPLEFT", 608, -52)
  --- Adds the typed item to the open list, clears the boxes and checks the new entry.
  local function doAdd()
    local e, err = GW.AddToList(view.addBox:GetText(), view.addMax:GetText(), view.addWant:GetText())
    if not e then return toast(err, GW.SIGNAL_ORANGE) end
    view.addBox:SetText("")
    view.addMax:SetText("")
    view.addWant:SetText("")
    view.addBox:ClearFocus()
    toast(string.format(L["Added %s."], e.name), GW.SIGNAL_BLUE)
    GW.CheckEntry(e)
    render()
  end
  view.add:SetScript("OnClick", doAdd)
  for _, b in ipairs({ view.addBox, view.addMax, view.addWant }) do
    b:SetScript("OnEnterPressed", doAdd)
  end

  for _, c in ipairs({
    { L["Item"], 16 },
    { L["Max price"], 304 },
    { L["Want"], 424 },
    { L["Found"], 480 },
    { L["Action"], 780 },
  }) do
    local f = fs(p, "GameFontDisableSmall", "LEFT")
    f:SetPoint("TOPLEFT", c[2], -88)
    f:SetText(c[1])
  end
  local tbl = CreateFrame("Frame", nil, p)
  tbl:SetPoint("TOPLEFT", 8, -104)
  tbl:SetSize(968, ROWS * ROW_H)
  tbl:EnableMouseWheel(true)
  tbl:SetScript("OnMouseWheel", function(_, delta)
    view.offset = (view.offset or 0) - delta
    render()
  end)
  view.rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("Frame", nil, tbl)
    row:SetSize(968, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    UI.Stripe(row, i)
    row.name = fs(row, "GameFontHighlight", "LEFT")
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(280)
    row.name:SetWordWrap(false)
    row.max = fs(row, "GameFontHighlightSmall", "LEFT")
    row.max:SetPoint("LEFT", 296, 0)
    -- Want is editable in place: Enter or clicking away saves it and checks the item again.
    row.want = UI.NewEditBox(row)
    row.want:SetSize(40, 20)
    row.want:SetPoint("LEFT", 420, 0)
    row.want:SetAutoFocus(false)
    row.want:SetNumeric(true)
    row.want:SetMaxLetters(5)
    row.want:SetFontObject("GameFontHighlightSmall")
    row.want:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    row.want:SetScript("OnEscapePressed", function(self)
      self:SetText(row.e and row.e.want and tostring(row.e.want) or "") -- put the saved Want back
      self:ClearFocus()
    end)
    row.want:SetScript("OnEditFocusLost", function(self)
      setWant(row.e, self:GetText())
      render()
    end)
    row.found = fs(row, "GameFontHighlightSmall", "LEFT")
    row.found:SetPoint("LEFT", 472, 0)
    row.found:SetWidth(290)
    row.found:SetWordWrap(true)
    row.action = UI.NewButton(row)
    row.action:SetSize(160, 22)
    row.action:SetPoint("LEFT", 772, 0)
    needsAH(row.action)
    row.action:SetScript("OnClick", function()
      local e, r = row.e, row.e and sv.results[row.e]
      if not e then return end
      local b = myBuy()
      if (b and b.entry == e) or (r and r.kind == "commodity") then
        buyClick(e)
      else
        showInBuyTab(e)
      end
    end)
    row.remove = UI.NewCloseButton(row)
    row.remove:SetSize(22, 22)
    row.remove:SetPoint("LEFT", 940, 0)
    row.remove:SetScript("OnClick", function()
      local list = selectedList()
      for k, x in ipairs(list and list.entries or {}) do
        if x == row.e then
          table.remove(list.entries, k)
          break
        end
      end
      local b = myBuy()
      if b and b.entry == row.e then cancelBuy() end
      render()
    end)
    view.rows[i] = row
  end
  view.empty = fs(p, "GameFontDisable", "CENTER")
  view.empty:SetPoint("TOP", 0, -150)
  view.empty:SetWidth(700)
  view.empty:SetText(L["Add the items you buy often, with the most you'd pay. Run List checks them all in one go."])
  view.note = fs(p, "GameFontDisableSmall", "LEFT") -- what buying takes, or (away) that it needs the auction house
  view.note:SetPoint("BOTTOMLEFT", 14, 12)
  view.note:SetWidth(940)
end

--- Builds the Shopping tab inside `parent`: page 1 (your lists) and page 2 (one list). Esc and the
--- controller's B on page 2 go back to page 1 first (the window's goBack; Esc through
--- GW.EscapeGoesBack in Core.lua, B through Gamepad.lua).
---@param parent table tab content frame
local function build(parent)
  view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints()
  view.listsPage = CreateFrame("Frame", nil, view)
  view.listsPage:SetAllPoints()
  view.listPage = CreateFrame("Frame", nil, view)
  view.listPage:SetAllPoints()
  buildListsPage(view.listsPage)
  buildListPage(view.listPage)
  view.toast = fs(view, "GameFontHighlightSmall", "LEFT")
  view.toast:SetPoint("BOTTOMLEFT", 14, 36)
  view.toast:SetWidth(940)

  local win = GW.panel
  if win then
    local before = win.goBack
    win.goBack = function()
      if view:IsVisible() and view.listPage:IsShown() then
        showLists()
        return true
      end
      return before and before() or false
    end
    -- While page 2 is on screen, Escape goes back a page instead of closing the window. Hooked on
    -- the window and the tab too: each change of what's on screen re-checks.
    local function sync() GW.EscapeGoesBack(win, view:IsVisible() and view.listPage:IsShown()) end
    for _, f in ipairs({ win, view, view.listPage }) do
      f:HookScript("OnShow", sync)
      f:HookScript("OnHide", sync)
    end
    sync()
  end
end

-- SHOP-7: Shift-click an item (bags, links) while the Shopping tab is open to fill the Item box. On
-- page 1 it opens the last list you had open first.
if hooksecurefunc and HandleModifiedItemClick then
  hooksecurefunc("HandleModifiedItemClick", function(link)
    if view and view:IsVisible() and IsShiftKeyDown() and type(link) == "string" and link:find("item:") then
      if not view.listPage:IsShown() then
        local _, i = selectedList()
        if not i then return end
        openList(i)
      end
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

--- Redraws the Shopping tab when it's open (after a list changed from another window).
function GW.ShopView.Refresh()
  if view and view:IsShown() then render() end
end

--- Opens list `i` on the Shopping tab (page 2), now if the tab is open, else the next time it is.
---@param i number index in GW.Lists()
function GW.ShopView.OpenList(i)
  GoldwrightDB.listSel, GoldwrightDB.shopPage = i, "list"
  if view then view.offset = 0 end
  GW.ShopView.Refresh()
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
  "AUCTION_HOUSE_CLOSED",
}) do
  pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, a1)
  if event == "AUCTION_HOUSE_CLOSED" then
    GW.StopList() -- a purchase on its way is Purchase.lua's to report
    return
  end
  if not (view and view:IsShown()) then return end
  if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    onBrowseResults()
  else
    onSearchResults(event, a1)
  end
end)
