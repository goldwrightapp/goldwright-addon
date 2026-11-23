--- Diagnostics: answers "was it Goldwright?" when something goes wrong at the auction house.
---
--- * Remembers the last few auction house requests and who sent them (Goldwright, the game's own
---   auction house window, or another add-on), by watching the request functions with
---   hooksecurefunc. Watching never calls them and never changes what they do.
--- * Records every auction house error (AUCTION_HOUSE_SHOW_ERROR, dropped requests), whether or not
---   the Goldwright panel is open, with the error's name and the requests just before it.
--- * Records Lua errors in Goldwright's own files and actions the game blocked for Goldwright, then
---   passes them on unchanged to the game's (or another add-on's) error handler.
---
--- Kept in GoldwrightDB.errorLog (last ERROR_LOG_MAX, with dates) and shown in the bug report.
local _, GW = ...

--- Errors kept in SavedVariables.
GW.ERROR_LOG_MAX = 20
--- Requests remembered (in memory only) to explain an error.
local TRAIL_MAX = 8
--- How many of the remembered requests an error record names.
local TRAIL_IN_ERROR = 3

--- Auction house functions that send something to the server. Only watched, never called here.
local REQUESTS = {
  "SendBrowseQuery",
  "RequestMoreBrowseResults",
  "SendSearchQuery",
  "SendSellSearchQuery",
  "SearchForItemKeys",
  "SearchForFavorites",
  "RefreshCommoditySearchResults",
  "RefreshItemSearchResults",
  "RequestMoreCommoditySearchResults",
  "RequestMoreItemSearchResults",
  "QueryOwnedAuctions",
  "QueryBids",
  "ReplicateItems",
  "PostItem",
  "PostCommodity",
  "ConfirmPostItem",
  "ConfirmPostCommodity",
  "PlaceBid",
  "StartCommoditiesPurchase",
  "ConfirmCommoditiesPurchase",
  "CancelCommoditiesPurchase",
  "CancelAuction",
  "CancelSell",
}

--- Plain-English text for the auction house error names (Enum.AuctionHouseError); others show the name.
local ERROR_TEXT = {
  NotEnoughMoney = "Not enough money",
  HigherBid = "Higher bid",
  BidIncrement = "Bid increment",
  BidOwn = "Can't bid on your own auction",
  ItemNotFound = "Item not found",
  RestrictedAccountTrial = "Trial account",
  HasRestriction = "Restricted",
  IsBusy = "Auction house busy",
  Unavailable = "Auction house unavailable",
  ItemHasQuote = "Item has a quote",
  DatabaseError = "Internal auction error",
  MinBid = "Below the minimum bid",
  NotEnoughItems = "Not enough items",
  RepairItem = "Item needs repair",
  UsedCharges = "Item has used charges",
  QuestItem = "Quest item",
  BoundItem = "Soulbound item",
}

local trail = {} -- recent requests, newest last: { t, fn, by, what }

--- Today's date and time for log lines, e.g. "11-12 16:45:03".
---@return string
function GW.Stamp() return date("%m-%d %H:%M:%S") end

--- The name and text of an auction house error code.
---@param code any AUCTION_HOUSE_SHOW_ERROR's argument
---@return string name e.g. "DatabaseError", or "?" when the game doesn't say
---@return string text e.g. "Internal auction error"
function GW.AuctionErrorName(code)
  local name
  for k, v in pairs(Enum and Enum.AuctionHouseError or {}) do
    if v == code then name = k end
  end
  return name or "?", (name and ERROR_TEXT[name]) or name or ("error " .. tostring(code))
end

--- Who called an auction house function, from the call stack: "Goldwright", "game UI" (Blizzard's
--- own windows), or another add-on's folder name.
---@param stack string|nil debugstack() text, innermost call first
---@return string who
function GW.CallerOf(stack)
  if type(stack) ~= "string" then return "?" end
  for line in stack:gmatch("[^\n]+") do
    -- Skip this file: the watcher itself is the innermost Lua call.
    if not line:find("Diagnostics%.lua") then
      local folder = line:match("AddOns[/\\]([%w_%-]+)[/\\]")
      if folder then
        if folder == "Goldwright" then return "Goldwright" end
        if folder:find("^Blizzard_") then return "game UI" end
        return folder
      end
      if line:find("FrameXML", 1, true) or line:find("SharedXML", 1, true) then return "game UI" end
    end
  end
  return "game UI" -- no add-on file in the stack: the game's own code (key bindings, secure buttons)
end

--- Short description of a request's arguments: the search text, item, or browse filters.
---@param fn string function name
---@param a1 any first argument
---@param a2 any second argument
---@return string
local function describe(fn, a1, a2)
  if type(a1) == "table" then
    if a1.itemID then return "item " .. tostring(a1.itemID) end
    if fn == "SendBrowseQuery" then
      local parts = {}
      if a1.searchString and a1.searchString ~= "" then parts[#parts + 1] = '"' .. tostring(a1.searchString) .. '"' end
      for _, c in ipairs(a1.itemClassFilters or {}) do
        parts[#parts + 1] = "class " .. tostring(c.classID) .. "/" .. tostring(c.subClassID or "-")
      end
      if a1.minLevel or a1.maxLevel then
        parts[#parts + 1] = "level " .. tostring(a1.minLevel or "") .. "-" .. tostring(a1.maxLevel or "")
      end
      return #parts > 0 and table.concat(parts, ", ") or "everything"
    end
  end
  if type(a1) == "number" then
    if fn:find("Purchase") then return "item " .. a1 .. (type(a2) == "number" and (" ×" .. a2) or "") end
    return tostring(a1)
  end
  return ""
end

--- Remembers one request (called by the watchers, after the real function ran).
---@param fn string function name
---@param who string caller
---@param what string description
function GW.NoteRequest(fn, who, what)
  trail[#trail + 1] = { t = GetTime(), fn = fn, by = who, what = what }
  while #trail > TRAIL_MAX do
    table.remove(trail, 1)
  end
end

--- The remembered requests, newest last (for tests and /gw debug).
---@return table[]
function GW.RequestTrail() return trail end

--- The last few requests as text, newest first: "SendBrowseQuery by game UI (class 4/1) 0.3s before".
---@return string
local function trailText()
  local now, parts = GetTime(), {}
  for i = #trail, math.max(1, #trail - TRAIL_IN_ERROR + 1), -1 do
    local r = trail[i]
    parts[#parts + 1] =
      string.format("%s by %s%s %.1fs before", r.fn, r.by, r.what ~= "" and (" (" .. r.what .. ")") or "", now - r.t)
  end
  return #parts > 0 and table.concat(parts, "; ") or "no request seen"
end

--- Adds an error to GoldwrightDB.errorLog (and the search log). A repeat of the newest error only
--- counts up, so one error in a loop can't push the others out.
---@param text string
function GW.RecordError(text)
  if not GoldwrightDB then return end
  GoldwrightDB.errorLog = GoldwrightDB.errorLog or {}
  local log = GoldwrightDB.errorLog
  local last = log[#log]
  if last and last.text == text then
    last.n = (last.n or 1) + 1
    last.at = GW.Stamp()
  else
    log[#log + 1] = { at = GW.Stamp(), text = text }
  end
  while #log > GW.ERROR_LOG_MAX do
    table.remove(log, 1)
  end
  if GW.Log then GW.Log("ERROR %s", text) end
end

--- Recent errors as lines, newest last: "11-12 16:45:03 auction house: ... (×3)".
---@return string[]
function GW.ErrorLines()
  local out = {}
  for _, e in ipairs(GoldwrightDB and GoldwrightDB.errorLog or {}) do
    out[#out + 1] =
      string.format("%s %s%s", tostring(e.at), tostring(e.text), (e.n or 1) > 1 and (" (×" .. e.n .. ")") or "")
  end
  return out
end

-- Watch the request functions. hooksecurefunc runs our function after the real one, with the same
-- arguments; the real call is untouched.
if hooksecurefunc and C_AuctionHouse then
  for _, fn in ipairs(REQUESTS) do
    if type(C_AuctionHouse[fn]) == "function" then
      hooksecurefunc(C_AuctionHouse, fn, function(a1, a2)
        pcall(function() GW.NoteRequest(fn, GW.CallerOf(debugstack and debugstack(2)), describe(fn, a1, a2)) end)
      end)
    end
  end
end

-- Errors, whether or not the Goldwright panel is open.
local events = CreateFrame("Frame")
for _, e in ipairs({
  "AUCTION_HOUSE_SHOW_ERROR",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "UI_ERROR_MESSAGE",
  "ADDON_ACTION_BLOCKED",
  "ADDON_ACTION_FORBIDDEN",
}) do
  pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "AUCTION_HOUSE_SHOW_ERROR" then
    local name, text = GW.AuctionErrorName(a1)
    GW.RecordError(string.format("auction house error %s %s (%s) after %s", tostring(a1), name, text, trailText()))
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    GW.RecordError("auction house dropped a request after " .. trailText())
  elseif event == "UI_ERROR_MESSAGE" then
    -- Only auction house and money messages, and only while the auction house is open.
    if GW.AuctionHouseOpen and GW.AuctionHouseOpen() and GW.IsAuctionError and GW.IsAuctionError(a1, a2) then
      GW.RecordError(string.format('game message "%s" after %s', tostring(a2), trailText()))
    end
  elseif GW.ReadableText(a1) and a1:find("^Goldwright") then -- ADDON_ACTION_BLOCKED / _FORBIDDEN
    GW.RecordError(string.format("%s: %s called %s", event, a1, tostring(a2)))
  end
end)

--- Records a Lua error when it comes from Goldwright's own files, then passes it on.
---@param msg any the error
local function onLuaError(msg)
  local text = tostring(msg)
  if not text:find("AddOns[/\\]Goldwright[/\\]") then return end
  GW.RecordError("Lua error: " .. text:gsub("^.-AddOns[/\\]Goldwright[/\\]", ""):sub(1, 220))
end

if seterrorhandler and geterrorhandler then
  local previous = geterrorhandler()
  seterrorhandler(function(msg, ...)
    pcall(onLuaError, msg)
    if previous then return previous(msg, ...) end
  end)
end

---------------------------------------------------------------------------
-- Bait notes (2026-11-20): evidence for tuning the bait rule (Pricing.lua). A note is written on a
-- Sell tab search when (A) the rule skipped listings or (B) the cheapest listing is under half the
-- recent price and the rule kept it. Later the note gets two facts: whether listings at that cheap
-- price were still there at the next search of the item, and what the player posted at. Kept in
-- GoldwrightDB.baitNotes (last BAIT_NOTES_MAX) and shown in the bug report; never sent anywhere.
---------------------------------------------------------------------------
GW.BAIT_NOTES_MAX = 20
local NOTE_SAME_MIN = 600 -- the same item and cheapest price within 10 min is one case, not a new note
local FOLLOW_UP_MAX = 86400 -- a note older than a day gets no follow-up

--- Copper as plain letters for the notes ("1g 2s 3c"), whatever the money setting.
---@param c number|nil copper
---@return string
local function plainMoney(c)
  if not c then return "?" end
  c = math.floor(c + 0.5)
  local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if k > 0 or #parts == 0 then parts[#parts + 1] = k .. "c" end
  return table.concat(parts, " ")
end

local function notes()
  GoldwrightDB = GoldwrightDB or {}
  GoldwrightDB.baitNotes = GoldwrightDB.baitNotes or {}
  return GoldwrightDB.baitNotes
end

--- The newest note for an item at a house, or nil.
local function latest(id, side)
  local list = notes()
  for i = #list, 1, -1 do
    local n = list[i]
    if n.id == id and n.side == side then return n end
  end
  return nil
end

--- Records a Sell tab search for the bait notes: fills in the "still there?" fact of the item's last
--- note, then writes a new note when the rule skipped listings or kept a very cheap one.
---@param id number item id
---@param name string|nil item name
---@param side string house ("A", "H", "N")
---@param stats GoldwrightMarketStats|nil GW.MarketStats of the search
---@param recent number|nil the recent price the rule used (GW.RecentPrice)
function GW.NoteBaitSearch(id, name, side, stats, recent)
  if not (id and side and stats and stats.sorted and stats.sorted[1]) then return end
  local now = GetServerTime()
  local first = stats.sorted[1].price
  local prev = latest(id, side)
  -- Every later search within a day updates it, so the note keeps the latest look ("4 left after
  -- 2 min" becomes "0 left after 60 min").
  if prev and now - prev.t >= 60 and now - prev.t <= FOLLOW_UP_MAX then
    local units = 0
    for _, x in ipairs(stats.sorted) do
      if x.price <= prev.first then units = units + x.qty end
    end
    prev.still = units -- units at or under the noted cheapest price at this later search (0 = gone)
    prev.stillAfter = math.floor((now - prev.t) / 60)
  end
  if not (recent and recent > 0) then return end
  local skipped = stats.baitUnits > 0
  if not skipped and first >= recent * 0.5 then return end
  if prev and prev.first == first and now - prev.t < NOTE_SAME_MIN then return end
  local ladder = {}
  for i = 1, math.min(10, #stats.sorted) do
    local x = stats.sorted[i]
    ladder[#ladder + 1] = plainMoney(x.price) .. (x.qty > 1 and ("x" .. x.qty) or "")
  end
  local list = notes()
  list[#list + 1] = {
    t = now,
    id = id,
    name = name,
    side = side,
    kind = skipped and "skipped" or "kept",
    recent = recent,
    first = first,
    minReal = stats.minReal,
    baitUnits = stats.baitUnits,
    cliffUnits = stats.cliffUnits,
    ladder = table.concat(ladder, " "),
  }
  while #list > GW.BAIT_NOTES_MAX do
    table.remove(list, 1)
  end
end

--- Records what the player posted an item at, on the item's last note (within a day).
---@param id number item id
---@param side string house
---@param unit number posted price per unit, copper
function GW.NoteBaitPost(id, side, unit)
  local n = id and latest(id, side)
  if n and n.posted == nil and GetServerTime() - n.t <= FOLLOW_UP_MAX then n.posted = unit end
end

--- The newest bait notes as bug report lines, newest last.
---@param max number how many
---@return string[]
function GW.BaitNoteLines(max)
  local list, out = notes(), {}
  for i = math.max(1, #list - max + 1), #list do
    local n = list[i]
    local line = string.format(
      "%s %s (%s) %s %s, recent %s: %s -> min %s%s%s",
      date("%m-%d %H:%M", n.t),
      n.name or ("item " .. tostring(n.id)),
      tostring(n.id),
      n.side,
      n.kind,
      plainMoney(n.recent),
      n.ladder,
      plainMoney(n.minReal),
      n.still and string.format(" · %d left after %d min", n.still, n.stillAfter or 0) or "",
      n.posted and (" · posted " .. plainMoney(n.posted)) or ""
    )
    out[#out + 1] = line:sub(1, 240)
  end
  return out
end
