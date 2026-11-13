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
  elseif type(a1) == "string" and a1:find("^Goldwright") then -- ADDON_ACTION_BLOCKED / _FORBIDDEN
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
