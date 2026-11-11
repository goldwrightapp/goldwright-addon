--- Goldwright core: house detection, data pack access, settings, formatting, the search throttle,
--- the /gw slash command and Escape handling for our windows. Loaded first; every other file adds
--- to the `GW` namespace defined here.

--- The add-on namespace, shared by every file (`local _, GW = ...`) and global as `Goldwright`.
---@class Goldwright
---@field SIGNAL_BLUE number[] colour {r, g, b} for a good buy / a house that pays more
---@field SIGNAL_ORANGE number[] colour {r, g, b} for caution
---@field GOLD number[] brand colour {r, g, b}
---@field CUT table<string, number> auction house cut per house ("A", "H", "N"), e.g. 0.05
---@field HOUSE_NAMES table<string, string> display name per house ("A" = "Alliance", ...)
---@field WEBSITE string website shown to players
---@field ICON string icon texture path
---@field DEFAULTS table<string, any> default value of every setting (see GW.Opt)
---@field optionListeners function[] called after any setting changes
---@field SEARCH_LIMIT number auction house searches allowed per minute
---@field searches number[] GetTime() of each search in the last minute
---@field SEARCH_RETRY number seconds before a blocked search tries again
---@field house GoldwrightHouse|nil the player's house, set by GW.DetectHouse
---@field PACK_SCHEMA number data pack format this version reads
---@field pack table|nil the loaded data pack for the player's region and ruleset
---@field packStatus string|nil "loaded", "missing", "disabled", "schema" or the client's reason string
---@field otherPacks string[] installed data pack add-ons for other regions / rulesets
---@field STALE_DAYS number pack age in days after which players are told to update
---@field MIN_UNITS_FOR_HINT number units another house needs listed before we point players at it
---@field MIN_PROVEN_PER_DAY number proven sales per day another house needs for that hint
---@field N36 fun(s: string|nil): number|nil parses a base-36 pack field
---@field loginHandlers function[] run once at PLAYER_LOGIN
---@field blockedShown boolean|nil the "game blocked an action" message was shown this session
---@field UI GoldwrightUI shared UI helpers (UI.lua)
---@field RULES table pricing rules (Pricing.lua)
---@field SellCharts table Sell panel charts (SellCharts.lua)
---@field HISTORY_MIN_DAYS number days with a price before the history chart shows (Selling.lua)
---@field POST_WINDOW number hours in the "best time to post" window (Selling.lua)
---@field FLAT_SUPPLY number supply ratio at or above which the day counts as flat (Selling.lua)
---@field MERCHANTS_FAVOR number currency id of Merchant's Favor (Crafting.lua)
---@field craftPanel table|nil the Crafting panel beside the profession window (CraftPanel.lua)
local ADDON_NAME, GW = ...
_G.Goldwright = GW

GW.SIGNAL_BLUE = { 0.56, 0.69, 1.0 } -- good buy / pays more
GW.SIGNAL_ORANGE = { 0.96, 0.62, 0.29 } -- caution
GW.GOLD = { 0.88, 0.67, 0.23 } -- brand mark
GW.CUT = { A = 0.05, H = 0.05, N = 0.15 } -- auction house cut, assumed; AuctionMail.lua replaces it with the rate measured from sale invoices
GW.HOUSE_NAMES = { A = "Alliance", H = "Horde", N = "Blackwater" }

-- Ruleset by the last word of the realm name.
local RULESET_BY_SUFFIX =
  { PvE = "Normal", PvP = "PvP", RP = "Roleplay", RPPvP = "Roleplay PvP", ["RP-PvP"] = "Roleplay PvP" }

GW.WEBSITE = "goldwright.app"
GW.ICON = "Interface\\Icons\\INV_Misc_Coin_02"

--- Prints a chat line prefixed with the gold "Goldwright:" tag.
---@param msg string format string (string.format)
---@param ... any format arguments
function GW.Print(msg, ...) print("|cffe0ac3aGoldwright|r: " .. string.format(msg, ...)) end

---------------------------------------------------------------------------
-- Settings (SET): GoldwrightDB.opt holds only what the player changed; everything else is a default.
---------------------------------------------------------------------------
GW.DEFAULTS = {
  -- tooltip (TT-2..TT-7)
  ttMarket = true,
  ttNow = true,
  ttNormal = true,
  ttTrend = true,
  ttOthers = true,
  ttBetter = true,
  ttVendor = true,
  ttNoData = false, -- "No auction data yet" line for items we know nothing about
  expandKey = "SHIFT", -- SHIFT / CTRL / ALT / NONE: hold for the per-house table
  money = "coins", -- "coins" (coin icons, like the backpack) or "letters" (1g 23s)
  -- signals
  signalPct = 15, -- tooltip buy / sell signal outside this band around normal (TT-4)
  belowPct = 70, -- Sell panel warns below this % of normal (SELL-7)
  abovePct = 150, -- ... and notes above this % (SELL-8)
  betterPct = 20, -- another house must net this % more (TT-6, SELL-9)
  -- selling
  undercut = "1c", -- "1c" (1 copper under), "match" or "pct"
  undercutPct = 5,
  duration = 3, -- 1 = 2 h, 2 = 8 h, 3 = 24 h
  autoShow = true, -- open Goldwright with the auction house
  -- bait detection (live listings in game; the data pack uses the server's fixed rule)
  bait = true,
  baitShare = 1,
  baitGap = 30,
  -- launcher
  minimap = "auto", -- "auto" = only when the game has no add-on compartment; true / false
}

--- Reads a setting: the player's value, else the default.
---@param key string setting name (a key of GW.DEFAULTS)
---@return any value
function GW.Opt(key)
  local o = GoldwrightDB and GoldwrightDB.opt
  local v = o and o[key]
  if v == nil then return GW.DEFAULTS[key] end
  return v
end

GW.optionListeners = {}

--- Registers a function to call after any setting changes.
---@param fn function called with no arguments (errors are caught)
function GW.OnOptionsChanged(fn) table.insert(GW.optionListeners, fn) end

--- Stores a setting (a value equal to the default is removed) and applies the settings.
---@param key string setting name
---@param value any new value
function GW.SetOpt(key, value)
  GoldwrightDB = GoldwrightDB or {}
  GoldwrightDB.opt = GoldwrightDB.opt or {}
  if value == GW.DEFAULTS[key] then value = nil end
  GoldwrightDB.opt[key] = value
  GW.ApplyOptions()
end

--- Resets every setting to its default and applies the settings.
function GW.ResetOptions()
  if GoldwrightDB then GoldwrightDB.opt = {} end
  GW.ApplyOptions()
end

--- Pushes the settings into the pricing rules and tells open panels to redraw.
function GW.ApplyOptions()
  if GW.RULES then
    GW.RULES.bait = GW.Opt("bait")
    GW.RULES.baitMaxShare = GW.Opt("baitShare") / 100
    GW.RULES.baitGap = GW.Opt("baitGap") / 100
  end
  for _, fn in ipairs(GW.optionListeners) do
    pcall(fn)
  end
end

--- Whether the hold-to-expand key for tooltips (setting `expandKey`) is held down.
---@return boolean down false when the setting is "NONE"
function GW.ExpandKeyDown()
  local k = GW.Opt("expandKey")
  if k == "SHIFT" then return IsShiftKeyDown() end
  if k == "CTRL" then return IsControlKeyDown() end
  if k == "ALT" then return IsAltKeyDown() end
  return false
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
local COINS = {
  g = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:1:0|t",
  s = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:1:0|t",
  c = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:1:0|t",
}

--- Formats copper as "1g 23s 47c" (or with coin icons, per the `money` setting), dropping zero units.
---@param copper number|nil amount in copper (rounded; nil = 0)
---@return string text
function GW.Money(copper)
  copper = math.floor((copper or 0) + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100
  local icons = GW.Opt("money") == "coins"
  local function unit(n, u) return n .. (icons and COINS[u] or u) end
  local parts = {}
  if g > 0 then parts[#parts + 1] = unit(g >= 1000 and BreakUpLargeNumbers and BreakUpLargeNumbers(g) or g, "g") end
  if s > 0 then parts[#parts + 1] = unit(s, "s") end
  if c > 0 or #parts == 0 then parts[#parts + 1] = unit(c, "c") end
  return table.concat(parts, " ")
end

--- Formats a count with the client's thousands separators ("172,000").
---@param n number
---@return string text
function GW.Number(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n) end

---------------------------------------------------------------------------
-- Search throttle (shared by Sell and Cancel): the server allows about 100 searches a minute.
---------------------------------------------------------------------------
GW.SEARCH_LIMIT = 100
GW.searches = {}

--- Records that a search went out now.
function GW.NoteSearch() table.insert(GW.searches, GetTime()) end

--- Counts the searches sent in the last 60 seconds, forgetting older ones.
---@return number count
function GW.SearchesThisMinute()
  local now, n = GetTime(), 0
  for i = #GW.searches, 1, -1 do
    if now - GW.searches[i] > 60 then
      table.remove(GW.searches, i)
    else
      n = n + 1
    end
  end
  return n
end

--- Why a search can't go out now: "limit" (our 100 a minute) or "busy" (the game says the auction
--- house isn't ready for another request, e.g. right after a post).
---@return string|nil reason nil when a search can go out
function GW.SearchBlocked()
  if GW.SearchesThisMinute() >= GW.SEARCH_LIMIT then return "limit" end
  if
    C_AuctionHouse
    and C_AuctionHouse.IsThrottledMessageSystemReady
    and not C_AuctionHouse.IsThrottledMessageSystemReady()
  then
    return "busy"
  end
  return nil
end

--- Whether a search can go out now.
---@return boolean
function GW.CanSearch() return GW.SearchBlocked() == nil end

-- Seconds before a blocked search tries again.
GW.SEARCH_RETRY = 2

--- Sort order for item searches: cheapest first.
---@return table sorts for C_AuctionHouse search queries
function GW.PriceSorts() return { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } } end

--- The waiting text shown while a search is blocked.
---@return string text
function GW.WaitText()
  return GW.SearchBlocked() == "limit" and "waiting for a search slot (100 a minute)…"
    or "waiting for the auction house…"
end

--- Appends a line to the debug log of auction house traffic in SavedVariables (read with
--- npm run gw:log). Keeps the last 80 lines.
---@param msg string format string (string.format)
---@param ... any format arguments
function GW.Log(msg, ...)
  if not GoldwrightDB then return end
  GoldwrightDB.searchLog = GoldwrightDB.searchLog or {}
  local log = GoldwrightDB.searchLog
  log[#log + 1] = string.format("%s %s", date("%H:%M:%S"), string.format(msg, ...))
  while #log > 80 do
    table.remove(log, 1)
  end
end

--- How long ago a server time was: "just now", "5 min ago", "3 h ago", "4 days ago" or "unknown".
---@param epoch number|nil server time in seconds (nil or 0 = unknown)
---@return string text
function GW.Age(epoch)
  if not epoch or epoch == 0 then return "unknown" end
  local d = GetServerTime() - epoch
  if d < 90 then return "just now" end
  if d < 3600 then return math.floor(d / 60) .. " min ago" end
  if d < 172800 then return math.floor(d / 3600) .. " h ago" end
  return math.floor(d / 86400) .. " days ago"
end

--- The player's auction house, as GW.DetectHouse returns it.
---@class GoldwrightHouse
---@field region string client region name, e.g. "US"
---@field ruleset string "Normal", "PvP", "Roleplay" or "Roleplay PvP"
---@field realm string realm name
---@field side string "A" (Alliance) or "H" (Horde)
---@field packKey string data pack key, e.g. "US_RoleplayPvP"

--- Detects the player's house: region, ruleset (from the realm name suffix, e.g.
--- "CAMWOW US1 Realm 5 PvE", unless overridden in settings) and faction. Stores it in GW.house.
---@return GoldwrightHouse house
function GW.DetectHouse()
  local region = (GetCurrentRegionName and GetCurrentRegionName()) or "US"
  local realm = GetRealmName() or ""
  local suffix = realm:match("(%S+)%s*$") or ""
  local ruleset = (GoldwrightDB and GoldwrightDB.rulesetOverride) or RULESET_BY_SUFFIX[suffix] or "Normal"
  local faction = UnitFactionGroup("player")
  GW.house = {
    region = region,
    ruleset = ruleset,
    realm = realm,
    side = faction == "Horde" and "H" or "A",
    packKey = region .. "_" .. ruleset:gsub("%s+", ""),
  }
  return GW.house
end

--- The player's house (detected on first use).
---@return GoldwrightHouse house
function GW.House() return GW.house or GW.DetectHouse() end

GW.PACK_SCHEMA = 1 -- data pack format this version reads (server/src/rollup/datapack.mjs)

local loadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
local numAddOns = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
local addOnInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo

--- Loads the player's data add-on (load-on-demand GoldwrightData_<REGION>_<Ruleset>) once.
--- Sets GW.packStatus ("loaded", "missing", "disabled", "schema" when the pack is too new or too
--- old, or the client's reason string) and GW.otherPacks (installed data packs for other regions /
--- rulesets).
---@return table|nil pack the data pack, or nil when it is missing or unusable
function GW.LoadPack()
  local h = GW.House()
  local folder = "GoldwrightData_" .. h.packKey
  if not (GoldwrightData and GoldwrightData[h.packKey]) then
    local ok, reason = loadAddOn(folder)
    if not ok then
      GW.packStatus = reason == "MISSING" and "missing"
        or reason == "DISABLED" and "disabled"
        or (reason or "missing"):lower()
    end
  end
  local pack = GoldwrightData and GoldwrightData[h.packKey]
  if pack and pack.schema ~= GW.PACK_SCHEMA then
    GW.packStatus, GW.pack = "schema", nil
  elseif pack then
    GW.packStatus, GW.pack = "loaded", pack
  end
  GW.otherPacks = {}
  for i = 1, numAddOns() do
    local name = addOnInfo(i)
    if name and name ~= folder and name:match("^GoldwrightData_") then table.insert(GW.otherPacks, name) end
  end
  return GW.pack
end

--- The loaded data pack.
---@return table|nil pack
function GW.Pack() return GW.pack end

--- Days since the pack's snapshot.
---@return number|nil days fractional days, nil without a pack
function GW.PackAgeDays()
  local p = GW.pack
  if not (p and p.snapshotAt and p.snapshotAt > 0) then return nil end
  return (GetServerTime() - p.snapshotAt) / 86400
end
GW.STALE_DAYS = 3

--- Switches rulesets at runtime (settings override): clears caches, detects the house again and
--- loads its pack. Load-on-demand packs need no /reload.
---@return table|nil pack the new data pack
function GW.ReloadPack()
  GW.pack, GW.packStatus = nil, nil
  GW.ResetCache()
  GW.DetectHouse()
  return GW.LoadPack()
end

--- Parses a base-36 pack field.
---@param s string|nil field text ("" or nil = unknown)
---@return number|nil value
local function n36(s)
  if s == nil or s == "" then return nil end
  return tonumber(s, 36)
end
GW.N36 = n36

--- One house's numbers for an item, as GW.ItemData returns them.
---@class GoldwrightItemSide
---@field mv number|nil market value per unit (copper); nil = none listed now
---@field min number|nil cheapest real listing per unit (copper)
---@field units number units listed
---@field baitPrice number price of the ignored bait listings (0 = none)
---@field baitUnits number units in the ignored bait listings
---@field avg7 number|nil 7-day typical price (pack only)
---@field avg30 number|nil 30-day typical price (pack only)
---@field soldPerDay number|nil estimated sales per day: bought or cancelled early (pack only)
---@field boughtPerDay number|nil proven sales per day: partial buys and sweeps (pack only)
---@field source string "server" (data pack) or "scan" (the player's own full scan)
---@field at number|nil server time of the snapshot or scan

-- Parsed results by item key; false = known to have no data. Cleared by GW.ResetCache.
local cache = {}

--- Clears the parsed item data cache (new pack, new scan, ruleset switch).
function GW.ResetCache() cache = {} end

--- Parsed per-house numbers for an item, cached.
---@param key number|string|nil item id, or "id:bonus" for suffix gear
---@return table<string, GoldwrightItemSide>|nil data by house ("A", "H", "N"), nil when nothing is known
function GW.ItemData(key)
  if not key then return nil end
  if cache[key] ~= nil then return cache[key] or nil end
  local pack = GW.pack
  local raw = pack and pack.items and pack.items[key]
  local out, any = {}, false
  for side, s in pairs(raw or {}) do
    local mv, min, units, baitPrice, baitUnits, avg7, avg30, sold10, bought10 = strsplit(",", s)
    sold10, bought10 = n36(sold10), n36(bought10)
    out[side] = {
      mv = n36(mv),
      min = n36(min),
      units = n36(units) or 0,
      baitPrice = n36(baitPrice) or 0,
      baitUnits = n36(baitUnits) or 0,
      avg7 = n36(avg7),
      avg30 = n36(avg30),
      soldPerDay = sold10 and sold10 / 10,
      boughtPerDay = bought10 and bought10 / 10,
      source = "server",
      at = pack.snapshotAt,
    }
    any = true
  end
  -- The player's own full scans (Scan.lua) replace the current-listing numbers of that house when
  -- they are newer than the pack: a full scan sees every listing, so an item missing from it is
  -- not listed now. History, trend and sales stay from the pack.
  for side, sc in pairs(GW.HouseScans and GW.HouseScans() or {}) do
    if not (pack and pack.snapshotAt and pack.snapshotAt >= sc.at) then
      local s = sc.items[key]
      local d = out[side]
      if s or d then
        d = d or {}
        local mv, min, units, baitPrice, baitUnits = strsplit(",", s or "")
        d.mv, d.min, d.units = n36(mv), n36(min), n36(units) or 0
        d.baitPrice, d.baitUnits = n36(baitPrice) or 0, n36(baitUnits) or 0
        d.source, d.at = "scan", sc.at
        out[side] = d
        any = true
      end
    end
  end
  cache[key] = any and out or false
  return any and out or nil
end

--- The 30 daily typical prices of an item in one house.
---@param key number|string item key
---@param side string house ("A", "H", "N")
---@return number[]|nil prices index 1 = the day starting at pack.histFrom; nil entries = no data
---@return number|nil histFrom server time of day 1
function GW.History(key, side)
  local s = GW.pack and GW.pack.hist and GW.pack.hist[key] and GW.pack.hist[key][side]
  if not s then return nil end
  local out, i = {}, 0
  for x in (s .. ","):gmatch("([^,]*),") do
    i = i + 1
    out[i] = n36(x)
  end
  return out, GW.pack.histFrom
end

--- The hour-of-day profile of an item in one house.
---@param key number|string item key
---@param side string house ("A", "H", "N")
---@return { prices: number[], units: number[] }|nil profile indexed 1..24 = UTC 00..23 (nil entries = no data)
function GW.Hours(key, side)
  local s = GW.pack and GW.pack.hours and GW.pack.hours[key] and GW.pack.hours[key][side]
  if not s then return nil end
  local p, u = strsplit("/", s)
  local function list(str)
    local out, i = {}, 0
    for x in (str .. ","):gmatch("([^,]*),") do
      i = i + 1
      out[i] = n36(x)
    end
    return out
  end
  return { prices = list(p), units = list(u or "") }
end

--- What a vendor pays for one, from the client's item data.
---@param itemID number
---@return number copper 0 when unsellable or not cached
function GW.VendorPrice(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local sell = select(11, getInfo(itemID))
  return sell or 0
end

GW.MIN_UNITS_FOR_HINT = 10 -- a house needs this many units listed before we point players at it
GW.MIN_PROVEN_PER_DAY = 5 -- ...and this many proven sales per day (partial buys + sweeps)

--- Whether another house really pays more: at least `betterPct` (20%) more net of both cuts, enough
--- units listed and proven buyers at that price (not just asking prices).
---@param d GoldwrightItemSide|nil the other house's numbers
---@param side string the other house ("A", "H", "N")
---@param mv number|nil market value in the house compared against
---@param fromSide string|nil the house compared against (default: the player's own)
---@return number|nil gain the % gain, rounded; nil when the other house isn't clearly better
function GW.BetterHouse(d, side, mv, fromSide)
  if not (d and mv and mv > 0 and d.mv and (d.units or 0) >= GW.MIN_UNITS_FOR_HINT) then return nil end
  if (d.boughtPerDay or 0) < GW.MIN_PROVEN_PER_DAY then return nil end
  local here, there = GW.Net(fromSide or GW.house.side, mv), GW.Net(side, d.mv)
  if here <= 0 or there < here * (1 + GW.Opt("betterPct") / 100) then return nil end
  return math.floor((there / here - 1) * 100 + 0.5)
end

--- "~550 sold/day" (proven sales), for hints that send players to another house.
---@param perDay number|nil sales per day
---@return string text "" without a number
function GW.SoldText(perDay)
  if not perDay then return "" end
  return perDay >= 10 and string.format("~%d sold/day", math.floor(perDay + 0.5))
    or string.format("~%.1f sold/day", perDay)
end

--- Sales per day to show for one house: proven sales (partial buys and sweeps) when there are any,
--- else the estimate (listings gone early, which may include cancels). Gear never has proven sales:
--- each piece is its own auction, so it always shows the estimate.
---@param here GoldwrightItemSide|nil
---@return number|nil perDay
---@return boolean proven
function GW.SellRate(here)
  if not here then return nil, false end
  if (here.boughtPerDay or 0) > 0 then return here.boughtPerDay, true end
  return here.soldPerDay, false
end

--- "sold ~16,526/day" (proven) or "sells ~4.2/day (est.)".
---@param here GoldwrightItemSide|nil
---@return string|nil text nil when no rate is known
function GW.SellRateText(here)
  local n, proven = GW.SellRate(here)
  if not n then return nil end
  local num = n >= 10 and GW.Number(math.floor(n + 0.5)) or string.format("%.1f", n)
  return proven and string.format("sold ~%s/day", num) or string.format("sells ~%s/day (est.)", num)
end

--- Net per unit after the house's cut.
---@param side string house ("A", "H", "N"; unknown = 5% cut)
---@param price number price in copper
---@return number copper
function GW.Net(side, price) return price * (1 - (GW.CUT[side] or 0.05)) end

--- Prints one chat line saying why there are no server prices (ONB-2 / ONB-3).
function GW.PrintPackProblem()
  local h = GW.House()
  local want = "Goldwright Data: " .. h.region
  if GW.packStatus == "schema" then
    GW.Print("Your Goldwright data pack doesn't match this version of Goldwright. Update both in your add-on manager.")
  elseif GW.packStatus == "disabled" then
    GW.Print(
      "The data pack for %s %s is installed but disabled. Enable GoldwrightData_%s in the AddOns list.",
      h.region,
      h.ruleset,
      h.packKey
    )
  elseif #(GW.otherPacks or {}) > 0 then
    GW.Print(
      "No data for %s %s: you have %s installed. Install %s for prices in tooltips.",
      h.region,
      h.ruleset,
      table.concat(GW.otherPacks, ", "),
      want
    )
  else
    GW.Print("No data pack for %s %s. Install %s for prices in tooltips.", h.region, h.ruleset, want)
  end
end

--- Prints one chat line when the pack is older than GW.STALE_DAYS (ONB-2); the Sell panel shows the
--- same as a banner (AH-3).
function GW.PrintStaleNotice()
  local days = GW.PackAgeDays()
  if days and days > GW.STALE_DAYS then
    GW.Print("Your price data is %d days old. Update Goldwright Data in your add-on manager.", math.floor(days))
  end
end

-- Bindings.xml labels (Options > Keybindings > AddOns)
BINDING_HEADER_GOLDWRIGHT = "Goldwright"
BINDING_NAME_GOLDWRIGHT_POST = "Post the selected item"
BINDING_NAME_GOLDWRIGHT_CANCEL_NEXT = "Cancel the next undercut auction"
BINDING_NAME_GOLDWRIGHT_TOGGLE = "Open or close Goldwright"

GW.loginHandlers = {}

--- Registers a function to run at PLAYER_LOGIN, after the house and pack are loaded.
---@param fn function called with no arguments (errors are caught and printed)
function GW.OnLogin(fn) table.insert(GW.loginHandlers, fn) end

-- ADDON_LOADED: set up SavedVariables and apply settings. PLAYER_LOGIN: detect the house, load the
-- pack (or explain why not) and run the login handlers.
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    GoldwrightDB = GoldwrightDB or {}
    GoldwrightDB.opt = GoldwrightDB.opt or {}
    if GoldwrightDB.autoShow ~= nil then -- the prototype kept this at the top level
      if GoldwrightDB.autoShow == false then GoldwrightDB.opt.autoShow = false end
      GoldwrightDB.autoShow = nil
    end
    GW.ApplyOptions()
  elseif event == "PLAYER_LOGIN" then
    GW.DetectHouse()
    if not GW.LoadPack() then
      GW.PrintPackProblem()
    else
      GW.PrintStaleNotice()
    end
    for _, fn in ipairs(GW.loginHandlers) do
      local ok, err = pcall(fn)
      if not ok then GW.Print("startup error: %s", tostring(err)) end
    end
  end
end)

--- The tooltip numbers as one chat line, for /gw price <link> (CMD).
---@param msg string an item link, or an item id
---@return string|nil line nil when `msg` holds no item
function GW.PriceLine(msg)
  local id = tonumber(msg:match("item:(%d+)") or msg:match("^%s*(%d+)%s*$") or "")
  if not id then return nil end
  local h = GW.House()
  local d = GW.ItemData(id)
  local here = d and d[h.side]
  local name = msg:match("%[(.-)%]") or ("item " .. id)
  if not here then return string.format("%s: no auction data yet.", name) end
  local parts = {}
  if here.mv then
    parts[#parts + 1] = "market " .. GW.Money(here.mv)
    if here.min then parts[#parts + 1] = "now " .. GW.Money(here.min) end
  else
    parts[#parts + 1] = "none listed now"
  end
  if here.avg7 or here.avg30 then parts[#parts + 1] = "normal " .. GW.Money(here.avg7 or here.avg30) end
  local rate = GW.SellRateText(here)
  if rate then parts[#parts + 1] = rate end
  for _, side in ipairs({ "A", "H", "N" }) do
    if side ~= h.side and d[side] and d[side].mv then
      parts[#parts + 1] = GW.HOUSE_NAMES[side] .. " " .. GW.Money(d[side].mv)
    end
  end
  return string.format("%s (%s): %s", name, GW.HOUSE_NAMES[h.side], table.concat(parts, " · "))
end

local HELP =
  "/gw status · /gw price [item] · /gw sell · /gw auctions · /gw scan · /gw lists · /gw craft · /gw add [item] · /gw config · /gw minimap · /gw welcome · /gw bug"

-- /gw and /goldwright. No command (or "status") prints the house and pack state; other commands
-- open tabs and windows defined in later files, when they exist.
SLASH_GOLDWRIGHT1 = "/gw"
SLASH_GOLDWRIGHT2 = "/goldwright"
SlashCmdList.GOLDWRIGHT = function(raw)
  raw = strtrim(raw or "")
  local cmd, rest = raw:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  local h = GW.House()
  if cmd == "status" or cmd == "" then
    local pack = GW.Pack()
    GW.Print('%s · %s · %s (realm "%s").', h.region, h.ruleset, GW.HOUSE_NAMES[h.side], h.realm)
    if pack then
      GW.Print(
        "Data pack %s %s: snapshot %s, built %s.",
        h.packKey,
        pack.version or "?",
        GW.Age(pack.snapshotAt),
        GW.Age(pack.builtAt)
      )
      GW.PrintStaleNotice()
    else
      GW.PrintPackProblem()
    end
    GW.Print("Searches this minute: %d / %d.", GW.SearchesThisMinute(), GW.SEARCH_LIMIT)
    if GW.CutText then GW.Print("Auction house cut: %s.", GW.CutText()) end
    if cmd == "" then GW.Print("Commands: %s", HELP) end
  elseif cmd == "bug" or cmd == "bugreport" or cmd == "report" then
    if GW.ShowBugReport then GW.ShowBugReport() end
  elseif cmd == "price" then
    GW.Print("%s", GW.PriceLine(rest) or "Usage: /gw price [item link]")
  elseif cmd == "sell" or cmd == "cancel" or cmd == "auctions" then
    if GW.OpenTab then GW.OpenTab(cmd == "sell" and "sell" or "cancel") end
  elseif cmd == "lists" or cmd == "shopping" then
    if GW.OpenTab then GW.OpenTab("shopping") end
  elseif cmd == "add" then
    if not GW.AddToList then return end
    local e, info = GW.AddToList(rest)
    if e then
      GW.Print("Added %s to %s.", e.name, info.name)
    else
      GW.Print("%s", info or "Usage: /gw add [item link or name]")
    end
  elseif (cmd == "craft" or cmd == "crafting") and rest == "reset" then
    if GW.ResetCraftPosition then GW.ResetCraftPosition() end
    GW.Print("The Crafting panel opens next to the profession window again.")
  elseif cmd == "craft" or cmd == "crafting" then
    if GW.ToggleCraftPanel then GW.ToggleCraftPanel() end
  elseif cmd == "scan" then
    if GW.OpenTab and GW.AuctionHouseOpen and GW.AuctionHouseOpen() then GW.OpenTab("scan") end
    if GW.StartScan then GW.StartScan(rest == "anyway") end
  elseif cmd == "config" or cmd == "settings" or cmd == "options" then
    if GW.OpenSettings then GW.OpenSettings() end
  elseif cmd == "minimap" then
    if GW.SetMinimapShown then GW.SetMinimapShown(not GW.MinimapShown()) end
  elseif cmd == "welcome" then
    if GW.ShowWelcome then GW.ShowWelcome() end
  elseif cmd == "autoshow" then
    GW.SetOpt("autoShow", not GW.Opt("autoShow"))
    GW.Print("Open Goldwright with the auction house: %s", GW.Opt("autoShow") and "on" or "off")
  else
    GW.Print("Commands: %s", HELP)
  end
end

--- Makes Escape close `frame` without UISpecialFrames: adding names to that Blizzard table taints
--- the Escape key's game-menu path on this client ("blocked from an action only available to the
--- Blizzard UI" on every Esc, 2026-11-10). The frame takes Escape itself and lets every other key
--- through. Keyboard propagation can't change in combat, so in combat Escape just passes through.
---@param frame table the window to close
function GW.CloseOnEscape(frame)
  frame:EnableKeyboard(true)
  frame:SetPropagateKeyboardInput(true)
  frame:SetScript("OnKeyDown", function(self, key)
    if InCombatLockdown() then return end
    if key == "ESCAPE" then
      self:SetPropagateKeyboardInput(false)
      self:Hide()
      C_Timer.After(0, function()
        if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
      end)
    else
      self:SetPropagateKeyboardInput(true)
    end
  end)
end

-- If the game blocks Goldwright from a protected action, say which one (once per session) and log it.
local blocked = CreateFrame("Frame")
pcall(blocked.RegisterEvent, blocked, "ADDON_ACTION_FORBIDDEN")
pcall(blocked.RegisterEvent, blocked, "ADDON_ACTION_BLOCKED")
blocked:SetScript("OnEvent", function(_, event, addon, fn)
  if addon ~= ADDON_NAME then return end
  GW.Log("%s: %s", event, tostring(fn))
  if not GW.blockedShown then
    GW.blockedShown = true
    GW.Print("the game blocked %s (%s). Please report this.", tostring(fn), event)
  end
end)
