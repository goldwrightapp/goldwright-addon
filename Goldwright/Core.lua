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
local L = GW.L -- translations (Localization.lua)

GW.SIGNAL_BLUE = { 0.56, 0.69, 1.0 } -- good buy / pays more
GW.SIGNAL_ORANGE = { 0.96, 0.62, 0.29 } -- caution
GW.GOLD = { 0.88, 0.67, 0.23 } -- brand mark
GW.CUT = { A = 0.05, H = 0.05, N = 0.15 } -- auction house cut, assumed; AuctionMail.lua replaces it with the rate measured from sale invoices
-- The faction names are the game's own, in the client's language.
GW.HOUSE_NAMES = { A = FACTION_ALLIANCE or "Alliance", H = FACTION_HORDE or "Horde", N = L["Blackwater"] }
-- Seconds a confirm step (a quoted buy, the auction house's price warning) waits before the same
-- button accepts it, so a double click or a held key can't go straight through it.
GW.CONFIRM_DELAY = 0.8

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
  ttNow = true,
  ttNormal = true,
  ttTrend = true,
  -- Other auction houses (#24): one setting per house, the same on every character; your own
  -- faction's house is always shown (GW.ShowHouse). Tooltip, Sell tab chart line.
  ttAlliance = false, -- off: most players can't get items to the other faction
  ttHorde = false,
  ttBlackwater = true,
  ttBetter = true, -- "another house pays more" hints: tooltip, Sell tab bag tags, Crafting panel
  ttVendor = true,
  ttNoData = false, -- "No auction data yet" line for items we know nothing about
  ttSales = true, -- "You sold 34 · last 4s 90c each" (expanded view, Ledger.lua)
  -- Sell tab
  bagSort = "value", -- order of the bag list: "value", "name", "category" or "quantity" (#22)
  windowScale = 1, -- size of Goldwright's windows, 0.6 to 1 (#23: Steam Deck, small screens)
  -- sales record (Ledger.lua)
  saleSound = true, -- a sound when the game says an auction sold
  mailSummary = true, -- one chat line after new auction mail is read
  mailButton = true, -- a "Your sales" button beside the mailbox (SalesView.lua)
  expandKey = "SHIFT", -- SHIFT / CTRL / ALT / NONE: hold for the per-house table
  money = "coins", -- "coins" (coin icons, like the backpack) or "letters" (1g 23s)
  -- signals
  signalPct = 15, -- tooltip buy / sell signal outside this band around normal (TT-4)
  belowPct = 70, -- Sell panel warns below this % of normal (SELL-7)
  abovePct = 150, -- ... and notes above this % (SELL-8)
  betterPct = 20, -- another house must net this % more (TT-6, SELL-9)
  -- selling
  undercut = "match", -- Fast's price: "match" (same-price listings sell newest first, #15), "1c" or "pct"
  undercutPct = 5,
  duration = 3, -- 1 = 2 h, 2 = 8 h, 3 = 24 h
  autoShow = true, -- open Goldwright with the auction house
  craftAutoShow = true, -- open the Crafting panel with a profession window (off: /gw craft opens it)
  elvSkin = true, -- with ElvUI running, Goldwright's windows take its look (UI.Skin)
  look = "blizzard", -- Goldwright's own look: "blizzard" (flat, like the game's windows) or "dark" (Skin.lua)
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

--- Whether an event argument is text Goldwright may read. The game can pass "secret" strings (in
--- combat, or chat it protects): type() says "string", but reading one from add-on code is an error
--- ("attempt to index local 'msg' (a secret string value…)"). Those are skipped.
---@param v any
---@return boolean
function GW.ReadableText(v)
  if type(v) ~= "string" then return false end
  if issecretvalue and issecretvalue(v) then return false end
  return true
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

-- The game's own coin letters in the client's language (German "g s k"), else English.
local SYMBOLS = { g = GOLD_AMOUNT_SYMBOL or "g", s = SILVER_AMOUNT_SYMBOL or "s", c = COPPER_AMOUNT_SYMBOL or "c" }

-- An empty (fully transparent) image: the room of one digit in front of a one-digit coin.
local SPACER = "Interface\\AddOns\\Goldwright\\Media\\Spacer"
local digitWidth

--- The width of one digit in tooltip text, measured once (0 when it can't be measured).
---@return number
local function oneDigit()
  if digitWidth == nil then
    digitWidth = 0
    local fs = GameTooltip
      and GameTooltip.CreateFontString
      and GameTooltip:CreateFontString(nil, "ARTWORK", "GameTooltipText")
    if fs then
      fs:SetText("0")
      digitWidth = math.floor((fs:GetStringWidth() or 0) + 0.5)
      fs:SetText("")
      fs:Hide()
    end
  end
  return digitWidth
end

--- Formats copper as "1g 23s 47c" (or with coin icons, per the `money` setting), dropping zero units.
--- With `column`, silver and copper after a bigger coin take two digits of room ("1s  9c" lines up
--- under "1s 40c"), for amounts right-aligned in a column.
---@param copper number|nil amount in copper (rounded; nil = 0)
---@param column boolean|nil pad one-digit coins after a bigger coin
---@return string text
function GW.Money(copper, column)
  copper = math.floor((copper or 0) + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100
  local icons = GW.Opt("money") == "coins"
  local parts = {}
  local function unit(n, u)
    local pad = ""
    if column and #parts > 0 and type(n) == "number" and n < 10 and oneDigit() > 0 then
      pad = "|T" .. SPACER .. ":1:" .. oneDigit() .. "|t"
    end
    return pad .. n .. (icons and COINS[u] or SYMBOLS[u])
  end
  if g > 0 then parts[#parts + 1] = unit(g >= 1000 and BreakUpLargeNumbers and BreakUpLargeNumbers(g) or g, "g") end
  if s > 0 then parts[#parts + 1] = unit(s, "s") end
  if c > 0 or #parts == 0 then parts[#parts + 1] = unit(c, "c") end
  return table.concat(parts, " ")
end

--- Formats a count with the client's thousands separators ("172,000").
---@param n number
---@return string text
function GW.Number(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n) end

--- Formats a number with one decimal and the client's decimal mark ("4.2", German "4,2"; the game's
--- DECIMAL_SEPERATOR, spelled that way by Blizzard).
---@param n number
---@param places number|nil decimals (default 1)
---@return string text
function GW.Decimal(n, places)
  local s = string.format("%." .. (places or 1) .. "f", n)
  local mark = DECIMAL_SEPERATOR
  if type(mark) == "string" and mark ~= "" and mark ~= "." then s = s:gsub("%.", mark, 1) end
  return s
end

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
---@param capital boolean|nil starts a line: "Waiting for…" instead of "waiting for…"
---@return string text
function GW.WaitText(capital)
  local limit = GW.SearchBlocked() == "limit"
  if capital then
    return limit and L["Waiting for a search slot (100 a minute)…"] or L["Waiting for the auction house…"]
  end
  return limit and L["waiting for a search slot (100 a minute)…"] or L["waiting for the auction house…"]
end

--- Appends a line to the debug log of auction house traffic in SavedVariables (read with
--- npm run gw:log). Keeps the last 80 lines.
---@param msg string format string (string.format)
---@param ... any format arguments
function GW.Log(msg, ...)
  if not GoldwrightDB then return end
  GoldwrightDB.searchLog = GoldwrightDB.searchLog or {}
  local log = GoldwrightDB.searchLog
  log[#log + 1] = string.format("%s %s", date("%m-%d %H:%M:%S"), string.format(msg, ...))
  while #log > 80 do
    table.remove(log, 1)
  end
end

--- How long ago a server time was: "just now", "5 min ago", "3 h ago", "4 days ago" or "unknown".
---@param epoch number|nil server time in seconds (nil or 0 = unknown)
---@return string text
function GW.Age(epoch)
  if not epoch or epoch == 0 then return L["unknown"] end
  local d = GetServerTime() - epoch
  if d < 90 then return L["just now"] end
  if d < 3600 then return string.format(L["%d min ago"], math.floor(d / 60)) end
  if d < 172800 then return string.format(L["%d h ago"], math.floor(d / 3600)) end
  return GW.Plural(math.floor(d / 86400), "%d day ago", "%d days ago")
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
  -- Random suffixes ("id:bonus" keys): a scan reads them from each gear listing's link and lists the
  -- items whose every listing it could read in `suffixes` (#9). For those, a suffix the scan has no
  -- entry for isn't listed. For other items (or scans from before 0.7.3) it can't tell suffixes
  -- apart: a missing suffix key reads as not listed only when the base item isn't in the scan
  -- either; while the base item is listed, the pack's numbers for that suffix stay (#1).
  local baseID = type(key) == "string" and tonumber(key:match("^(%d+):"))
  for side, sc in pairs(GW.HouseScans and GW.HouseScans() or {}) do
    if not (pack and pack.snapshotAt and pack.snapshotAt >= sc.at) then
      local s = sc.items[key]
      local d = out[side]
      local unseen = not s and baseID and sc.items[baseID] ~= nil and not (sc.suffixes and sc.suffixes[baseID])
      if (s or d) and not unseen then
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

--- A comma list of base-36 numbers from the pack: "a,,1b" -> { 10, nil, 47 }.
---@param s string
---@return table<number, number> values nil entries = empty fields (no data)
local function list36(s)
  local out, i = {}, 0
  for x in (s .. ","):gmatch("([^,]*),") do
    i = i + 1
    out[i] = n36(x)
  end
  return out
end

--- The 30 daily typical prices of an item in one house.
---@param key number|string item key
---@param side string house ("A", "H", "N")
---@return number[]|nil prices index 1 = the day starting at pack.histFrom; nil entries = no data
---@return number|nil histFrom server time of day 1
function GW.History(key, side)
  local s = GW.pack and GW.pack.hist and GW.pack.hist[key] and GW.pack.hist[key][side]
  if not s then return nil end
  return list36(s), GW.pack.histFrom
end

--- 30 days of sales and supply of an item in one house, on the same days as GW.History. Units per
--- day: `proven` sold (partial buys and stacks swept below them), `est` sold (all early removals that
--- look like sales; it includes `proven` and is never below it), and the average `listed`. Sales
--- are scaled to a full day; days the server saw too little of are nil. Packs built before
--- 2026-11-21 have no daily series: nil.
---@param key number|string item key
---@param side string house ("A", "H", "N")
---@return { proven: table<number, number>, est: table<number, number>, listed: table<number, number> }|nil daily index 1 = the day starting at pack.histFrom
---@return number|nil histFrom server time of day 1
function GW.Daily(key, side)
  local s = GW.pack and GW.pack.daily and GW.pack.daily[key] and GW.pack.daily[key][side]
  if not s then return nil end
  local p, e, u = strsplit("/", s)
  return { proven = list36(p), est = list36(e or ""), listed = list36(u or "") }, GW.pack.histFrom
end

--- Which variant of an item a link is: random-suffix gear ("of Fire Protection") shares one item id
--- with its other suffixes, and only the link tells them apart (goldwright-addon #25). Returns the
--- link's bonus ids sorted ("12688"), else its suffix field ("s37"), else "" for the plain item;
--- nil without an item link.
---@param link string|nil
---@return string|nil variant
function GW.LinkVariant(link)
  local body = type(link) == "string" and link:match("item:([%-%d:]+)")
  if not body then return nil end
  local f, n = {}, 0
  for x in (body .. ":"):gmatch("([^:]*):") do
    n = n + 1
    f[n] = tonumber(x) or 0
  end
  local bonus = {}
  for b = 1, f[13] or 0 do
    local v = f[13 + b]
    if v and v > 0 then bonus[#bonus + 1] = v end
  end
  if #bonus > 0 then
    table.sort(bonus)
    return table.concat(bonus, ":")
  end
  if (f[7] or 0) ~= 0 then return "s" .. f[7] end
  return ""
end

--- How many of an item fit in one stack, from the client's item data (nil when not loaded yet).
---@param itemID number
---@return number|nil
function GW.MaxStack(itemID)
  if C_Item and C_Item.GetItemMaxStackSizeByID then
    local n = C_Item.GetItemMaxStackSizeByID(itemID)
    if n then return n end
  end
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  return get and select(8, get(itemID)) or nil
end

--- The recent price the bait cliff rule measures against (GW.MarketStats): the lower of the item's
--- 7-day average and yesterday's typical price at that house, from Goldwright Data, so a falling
--- market is recognised within a day. Mirrors recentPrice in server/src/rollup/publish.mjs.
---@param key number|string item key
---@param side string house ("A", "H", "N")
---@return number|nil copper, nil when neither is known
function GW.RecentPrice(key, side)
  local d = key and GW.ItemData and GW.ItemData(key)
  local best = d and d[side] and d[side].avg7
  local hist, from = GW.History(key, side)
  if hist and from then
    local y = math.floor((GetServerTime() - from) / 86400) -- yesterday's index (day 1 starts at histFrom)
    local v = y >= 1 and hist[y]
    if v and v > 0 and (not best or v < best) then best = v end
  end
  return best
end

--- The hour-of-day profile of an item in one house.
---@param key number|string item key
---@param side string house ("A", "H", "N")
---@return { prices: number[], units: number[] }|nil profile indexed 1..24 = UTC 00..23 (nil entries = no data)
function GW.Hours(key, side)
  local s = GW.pack and GW.pack.hours and GW.pack.hours[key] and GW.pack.hours[key][side]
  if not s then return nil end
  local p, u = strsplit("/", s)
  return { prices = list36(p), units = list36(u or "") }
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
GW.HOUSE_OPTION = { A = "ttAlliance", H = "ttHorde", N = "ttBlackwater" }

--- Whether another house's prices are shown (the Other auction houses settings, #24). Your own
--- faction's house, and the house you're standing at, always are.
---@param side string "A", "H" or "N"
---@param at string|nil the house the screen is about (the auction house you're at), if any
---@return boolean
function GW.ShowHouse(side, at)
  if side == (GW.house and GW.house.side) or side == at then return true end
  return GW.Opt(GW.HOUSE_OPTION[side]) and true or false
end

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
  local num = perDay >= 10 and GW.Number(math.floor(perDay + 0.5)) or GW.Decimal(perDay)
  return string.format(L["~%s sold/day"], num)
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
  local num = n >= 10 and GW.Number(math.floor(n + 0.5)) or GW.Decimal(n)
  return string.format(proven and L["sold ~%s/day"] or L["sells ~%s/day (est.)"], num)
end

--- Net per unit after the house's cut.
---@param side string house ("A", "H", "N"; unknown = 5% cut)
---@param price number price in copper
---@return number copper
function GW.Net(side, price) return price * (1 - (GW.CUT[side] or 0.05)) end

--- Prints one chat line saying why there are no server prices (ONB-2 / ONB-3).
function GW.PrintPackProblem()
  local h = GW.House()
  local want = "Goldwright Data" -- one data add-on for every region since 0.4 (CurseForge, Wago)
  if GW.packStatus == "schema" then
    GW.Print(
      L["Your Goldwright data pack doesn't match this version of Goldwright. Update both in your add-on manager."]
    )
  elseif GW.packStatus == "disabled" then
    GW.Print(
      L["The data pack for %s %s is installed but disabled. Enable GoldwrightData_%s in the AddOns list."],
      h.region,
      h.ruleset,
      h.packKey
    )
  elseif #(GW.otherPacks or {}) > 0 then
    GW.Print(
      L["No data for %s %s: you have %s installed. Install %s for prices in tooltips."],
      h.region,
      h.ruleset,
      table.concat(GW.otherPacks, ", "),
      want
    )
  else
    GW.Print(
      L["No data pack for %s %s. Install Goldwright Data from CurseForge or Wago for prices in tooltips."],
      h.region,
      h.ruleset
    )
  end
end

--- Prints one chat line when the pack is older than GW.STALE_DAYS (ONB-2); the Sell panel shows the
--- same as a banner (AH-3).
function GW.PrintStaleNotice()
  local days = GW.PackAgeDays()
  if days and days > GW.STALE_DAYS then
    GW.Print(
      "%s",
      GW.Plural(
        math.floor(days),
        "Your price data is %d day old. Update Goldwright Data in your add-on manager.",
        "Your price data is %d days old. Update Goldwright Data in your add-on manager."
      )
    )
  end
end

-- Bindings.xml labels (Options > Keybindings > AddOns)
BINDING_HEADER_GOLDWRIGHT = "Goldwright"
BINDING_NAME_GOLDWRIGHT_POST = L["Post the selected item"]
BINDING_NAME_GOLDWRIGHT_CANCEL_NEXT = L["Cancel the next undercut auction"]
BINDING_NAME_GOLDWRIGHT_TOGGLE = L["Open or close Goldwright"]

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
    if GoldwrightDB.opt.ttOthers ~= nil then -- 0.7.1 split "Other houses" into a setting per house
      if GoldwrightDB.opt.ttOthers == false then GoldwrightDB.opt.ttBlackwater = false end
      GoldwrightDB.opt.ttOthers = nil
    end
    if GoldwrightDB.opt.ttOtherFaction ~= nil then -- 0.7.5 (#24): one setting per faction's house
      GoldwrightDB.opt.ttAlliance = GoldwrightDB.opt.ttOtherFaction
      GoldwrightDB.opt.ttHorde = GoldwrightDB.opt.ttOtherFaction
      GoldwrightDB.opt.ttOtherFaction = nil
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
      if not ok then GW.Print(L["startup error: %s"], tostring(err)) end
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
  local name = msg:match("%[(.-)%]") or string.format(L["item %s"], id)
  if not here then return string.format(L["%s: no auction data yet."], name) end
  local parts = {}
  if here.mv then
    parts[#parts + 1] = string.format(L["market %s"], GW.Money(here.mv))
    if here.min then parts[#parts + 1] = string.format(L["now %s"], GW.Money(here.min)) end
  else
    parts[#parts + 1] = L["none listed now"]
  end
  if here.avg7 or here.avg30 then
    parts[#parts + 1] = string.format(L["normal %s"], GW.Money(here.avg7 or here.avg30))
  end
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
  "/gw status · /gw price [item] · /gw sell · /gw auctions · /gw sales · /gw scan · /gw lists · /gw watch · /gw gaps · /gw craft · /gw add [item] · /gw config · /gw minimap · /gw welcome · /gw bug"

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
    GW.Print(L['%s · %s · %s (realm "%s").'], h.region, h.ruleset, GW.HOUSE_NAMES[h.side], h.realm)
    if pack then
      GW.Print(
        L["Data pack %s %s: snapshot %s, built %s."],
        h.packKey,
        pack.version or "?",
        GW.Age(pack.snapshotAt),
        GW.Age(pack.builtAt)
      )
      GW.PrintStaleNotice()
    else
      GW.PrintPackProblem()
    end
    GW.Print(L["Searches this minute: %d / %d."], GW.SearchesThisMinute(), GW.SEARCH_LIMIT)
    if GW.CutText then GW.Print(L["Auction house cut: %s."], GW.CutText()) end
    if cmd == "" then GW.Print(L["Commands: %s"], HELP) end
  elseif cmd == "bug" or cmd == "bugreport" or cmd == "report" then
    if GW.ShowBugReport then GW.ShowBugReport() end
  elseif cmd == "price" then
    GW.Print("%s", GW.PriceLine(rest) or L["Usage: /gw price [item link]"])
  elseif cmd == "sell" or cmd == "cancel" or cmd == "auctions" then
    if GW.OpenTab then GW.OpenTab(cmd == "sell" and "sell" or "cancel") end
  elseif cmd == "sales" or cmd == "ledger" then
    if GW.OpenSales then GW.OpenSales() end
  elseif cmd == "lists" or cmd == "shopping" then
    if GW.OpenTab then GW.OpenTab("shopping") end
  elseif cmd == "watch" then
    -- watched shopping lists against your newest data, anywhere (Shopping.lua)
    if GW.WatchedCount and GW.WatchedCount() == 0 then
      GW.Print("%s", L["No list is watched yet: click the spyglass next to a list."])
    elseif GW.WatchCheck then
      GW.WatchCheck(true)
    end
  elseif cmd == "gaps" or cmd == "blackwater" then
    if GW.OpenGaps then GW.OpenGaps() end
  elseif cmd == "add" then
    if not GW.AddToList then return end
    local e, info = GW.AddToList(rest)
    if e then
      GW.Print(L["Added %s to %s."], e.name, info.name)
    else
      GW.Print("%s", info or L["Usage: /gw add [item link or name]"])
    end
  elseif (cmd == "craft" or cmd == "crafting") and rest == "reset" then
    if GW.ResetCraftPosition then GW.ResetCraftPosition() end
    GW.Print(L["The Crafting panel opens next to the profession window again."])
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
  elseif cmd == "gamepad" or cmd == "controller" then
    GW.Print("%s", GW.Gamepad and GW.Gamepad.Status() or "Gamepad: not loaded.")
  elseif cmd == "autoshow" then
    GW.SetOpt("autoShow", not GW.Opt("autoShow"))
    GW.Print(
      GW.Opt("autoShow") and L["Open Goldwright with the auction house: on"]
        or L["Open Goldwright with the auction house: off"]
    )
  else
    GW.Print(L["Commands: %s"], HELP)
  end
end

--- Makes Escape close `frame` through the game's own list of windows that Escape closes
--- (UISpecialFrames), like the game's windows and most add-ons (Auctionator, Baganator, BetterBags,
--- Questie, WeakAuras). The game walks that list in a protected call, so Escape closes our windows in
--- combat too (goldwright-addon #6). Before, each window caught Escape itself, which needs
--- SetPropagateKeyboardInput: blocked in combat, so in combat Escape went to the game (#3). The list
--- had been dropped on 2026-11-10 for a "blocked" message on every Esc whose cause was never logged;
--- blocked actions are logged now (below), so a repeat names the function.
--- Only the name is added, once; an entry is only ever changed in place (GW.EscapeGoesBack).
local escapeFrames = {}

--- Where `name` is in the Escape list, if it is.
---@param name string
---@return number|nil
local function escapeIndex(name)
  for i, v in pairs(UISpecialFrames) do
    if v == name then return i end
  end
end

---@param frame table the window to close (needs a global name)
function GW.CloseOnEscape(frame)
  local name = frame:GetName()
  if not name then return GW.Log("escape: a window without a name can't close on Escape") end
  escapeFrames[frame] = true
  if not escapeIndex(name) then table.insert(UISpecialFrames, name) end
  frame:HookScript("OnHide", function()
    if InCombatLockdown() then GW.Log("escape: %s closed in combat", name) end
  end)
end

local back -- stands in for a window on the Escape list while it shows a page Escape goes back from

--- While `frame` shows a page Escape should go back from (Shopping's list page), its entry in the
--- Escape list names a stand-in frame instead, so Escape hides only the stand-in and the window goes
--- back a page (BetterBags does the same). The entry's value is swapped in place: the game walks the
--- list with pairs, and changing the value of an entry it already has is safe while it does.
---@param frame table a window passed to GW.CloseOnEscape
---@param on boolean
function GW.EscapeGoesBack(frame, on)
  local name = frame:GetName()
  if not name then return end
  if not back then
    back = CreateFrame("Frame", "GoldwrightEscapeBack", UIParent)
    back:Hide()
    back:SetScript("OnHide", function(self)
      local target = self.target
      if not target then return end
      self.target = nil
      GW.Log("escape: %s back a page", name)
      if not (target.goBack and target.goBack()) then target:Hide() end
    end)
  end
  if on then
    local i = escapeIndex(name)
    if i then UISpecialFrames[i] = "GoldwrightEscapeBack" end
    back.target = frame
    back:Show()
    return
  end
  if back.target ~= frame and escapeIndex(name) then return end -- not standing in for it
  back.target = nil
  back:Hide()
  local i = escapeIndex("GoldwrightEscapeBack")
  if i then
    UISpecialFrames[i] = name
  elseif not escapeIndex(name) then
    table.insert(UISpecialFrames, name)
  end
end

-- Combat start and end, with the windows open, for bug reports (#3, #6).
local combatLog = CreateFrame("Frame")
pcall(combatLog.RegisterEvent, combatLog, "PLAYER_REGEN_DISABLED")
pcall(combatLog.RegisterEvent, combatLog, "PLAYER_REGEN_ENABLED")
combatLog:SetScript("OnEvent", function(_, event)
  local shown = {}
  for frame in pairs(escapeFrames) do
    if frame:IsShown() then shown[#shown + 1] = tostring(frame:GetName()) end
  end
  GW.Log(
    "combat %s (open: %s)",
    event == "PLAYER_REGEN_DISABLED" and "starts" or "ends",
    #shown > 0 and table.concat(shown, ", ") or "none"
  )
end)

-- If the game blocks Goldwright from a protected action, say which one (once per session) and log it.
-- Blocks blamed on other add-ons are logged too, without a chat line.
local blocked = CreateFrame("Frame")
pcall(blocked.RegisterEvent, blocked, "ADDON_ACTION_FORBIDDEN")
pcall(blocked.RegisterEvent, blocked, "ADDON_ACTION_BLOCKED")
blocked:SetScript("OnEvent", function(_, event, addon, fn)
  if addon ~= ADDON_NAME then
    -- Another add-on was blamed: only logged, so a "Interface action failed because of an
    -- AddOn" message can be traced from a bug report (goldwright-addon #3).
    GW.Log("%s by %s: %s (combat %s)", event, tostring(addon), tostring(fn), tostring(InCombatLockdown()))
    return
  end
  GW.Log("%s: %s (combat %s)", event, tostring(fn), tostring(InCombatLockdown()))
  if not GW.blockedShown then
    GW.blockedShown = true
    GW.Print(L["the game blocked %s (%s). Please report this."], tostring(fn), event)
  end
end)
