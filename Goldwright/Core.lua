-- Goldwright core: house detection, data pack access, formatting, slash command.
local ADDON_NAME, GW = ...
_G.Goldwright = GW

GW.SIGNAL_BLUE = { 0.56, 0.69, 1.0 }   -- good buy / pays more
GW.SIGNAL_ORANGE = { 0.96, 0.62, 0.29 } -- caution
GW.GOLD = { 0.88, 0.67, 0.23 }          -- brand mark
GW.CUT = { A = 0.05, H = 0.05, N = 0.15 } -- auction house cut (Blackwater 15%: assumed, to confirm)
GW.HOUSE_NAMES = { A = "Alliance", H = "Horde", N = "Blackwater" }

local RULESET_BY_SUFFIX = { PvE = "Normal", PvP = "PvP", RP = "Roleplay", RPPvP = "Roleplay PvP", ["RP-PvP"] = "Roleplay PvP" }

GW.WEBSITE = "goldwright.app"
GW.ICON = "Interface\\Icons\\INV_Misc_Coin_02"

function GW.Print(msg, ...)
  print("|cffe0ac3aGoldwright|r: " .. string.format(msg, ...))
end

---------------------------------------------------------------------------
-- Settings (SET): GoldwrightDB.opt holds only what the player changed; everything else is a default.
---------------------------------------------------------------------------
GW.DEFAULTS = {
  -- tooltip (TT-2..TT-7)
  ttMarket = true, ttNow = true, ttNormal = true, ttTrend = true, ttOthers = true, ttBetter = true, ttVendor = true,
  ttNoData = false,          -- "No auction data yet" line for items we know nothing about
  expandKey = "SHIFT",       -- SHIFT / CTRL / ALT / NONE: hold for the per-house table
  money = "coins",           -- "coins" (coin icons, like the backpack) or "letters" (1g 23s)
  -- signals
  signalPct = 15,            -- tooltip buy / sell signal outside this band around normal (TT-4)
  belowPct = 70,             -- Sell panel warns below this % of normal (SELL-7)
  abovePct = 150,            -- ... and notes above this % (SELL-8)
  betterPct = 20,            -- another house must net this % more (TT-6, SELL-9)
  -- selling
  undercut = "1c",           -- "1c" (1 copper under), "match" or "pct"
  undercutPct = 5,
  duration = 3,              -- 1 = 2 h, 2 = 8 h, 3 = 24 h
  autoShow = true,           -- open Goldwright with the auction house
  -- bait detection (live listings in game; the data pack uses the server's fixed rule)
  bait = true, baitShare = 1, baitGap = 30,
  -- launcher
  minimap = "auto",          -- "auto" = only when the game has no add-on compartment; true / false
}

function GW.Opt(key)
  local o = GoldwrightDB and GoldwrightDB.opt
  local v = o and o[key]
  if v == nil then return GW.DEFAULTS[key] end
  return v
end

GW.optionListeners = {}
function GW.OnOptionsChanged(fn) table.insert(GW.optionListeners, fn) end

function GW.SetOpt(key, value)
  GoldwrightDB = GoldwrightDB or {}
  GoldwrightDB.opt = GoldwrightDB.opt or {}
  if value == GW.DEFAULTS[key] then value = nil end
  GoldwrightDB.opt[key] = value
  GW.ApplyOptions()
end

function GW.ResetOptions()
  if GoldwrightDB then GoldwrightDB.opt = {} end
  GW.ApplyOptions()
end

-- Push settings into the pricing rules and tell open panels to redraw.
function GW.ApplyOptions()
  if GW.RULES then
    GW.RULES.bait = GW.Opt("bait")
    GW.RULES.baitMaxShare = GW.Opt("baitShare") / 100
    GW.RULES.baitGap = GW.Opt("baitGap") / 100
  end
  for _, fn in ipairs(GW.optionListeners) do pcall(fn) end
end

-- Hold-to-expand key for tooltips.
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

-- "1g 23s 47c", dropping zero units (or coin icons, per setting).
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

---------------------------------------------------------------------------
-- Search throttle (shared by Sell and Cancel): the server allows about 100 searches a minute.
---------------------------------------------------------------------------
GW.SEARCH_LIMIT = 100
GW.searches = {}
function GW.NoteSearch() table.insert(GW.searches, GetTime()) end
function GW.SearchesThisMinute()
  local now, n = GetTime(), 0
  for i = #GW.searches, 1, -1 do
    if now - GW.searches[i] > 60 then table.remove(GW.searches, i) else n = n + 1 end
  end
  return n
end
-- Why a search can't go out now: "limit" (our 100 a minute) or "busy" (the game says the auction
-- house isn't ready for another request, e.g. right after a post); nil when it can.
function GW.SearchBlocked()
  if GW.SearchesThisMinute() >= GW.SEARCH_LIMIT then return "limit" end
  if C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then return "busy" end
  return nil
end
function GW.CanSearch() return GW.SearchBlocked() == nil end

-- The waiting text for a blocked search.
function GW.WaitText()
  return GW.SearchBlocked() == "limit" and "waiting for a search slot (100 a minute)…" or "waiting for the auction house…"
end

-- Debug log of auction house traffic, kept in SavedVariables (read with npm run gw:log).
function GW.Log(msg, ...)
  if not GoldwrightDB then return end
  GoldwrightDB.searchLog = GoldwrightDB.searchLog or {}
  local log = GoldwrightDB.searchLog
  log[#log + 1] = string.format("%s %s", date("%H:%M:%S"), string.format(msg, ...))
  while #log > 80 do table.remove(log, 1) end
end

function GW.Age(epoch)
  if not epoch or epoch == 0 then return "unknown" end
  local d = GetServerTime() - epoch
  if d < 90 then return "just now" end
  if d < 3600 then return math.floor(d / 60) .. " min ago" end
  if d < 172800 then return math.floor(d / 3600) .. " h ago" end
  return math.floor(d / 86400) .. " days ago"
end

-- Region + ruleset (from the realm name suffix, e.g. "CAMWOW US1 Realm 5 PvE") + faction.
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

GW.PACK_SCHEMA = 1 -- data pack format this version reads (server/src/rollup/datapack.mjs)

local loadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
local numAddOns = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
local addOnInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo

-- Load the player's data add-on (load-on-demand GoldwrightData_<REGION>_<Ruleset>) once.
-- GW.packStatus: "loaded", "missing", "disabled", "schema" (pack too new or too old) or the
-- client's reason string; GW.otherPacks lists installed data packs for other regions / rulesets.
function GW.LoadPack()
  local h = GW.house or GW.DetectHouse()
  local folder = "GoldwrightData_" .. h.packKey
  if not (GoldwrightData and GoldwrightData[h.packKey]) then
    local ok, reason = loadAddOn(folder)
    if not ok then
      GW.packStatus = reason == "MISSING" and "missing" or reason == "DISABLED" and "disabled" or (reason or "missing"):lower()
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

function GW.Pack()
  return GW.pack
end

-- Days since the pack's snapshot (nil without a pack).
function GW.PackAgeDays()
  local p = GW.pack
  if not (p and p.snapshotAt and p.snapshotAt > 0) then return nil end
  return (GetServerTime() - p.snapshotAt) / 86400
end
GW.STALE_DAYS = 3

-- Switch rulesets at runtime (settings override): load-on-demand packs need no /reload.
function GW.ReloadPack()
  GW.pack, GW.packStatus = nil, nil
  GW.ResetCache()
  GW.DetectHouse()
  return GW.LoadPack()
end

-- Base-36 field ("" or nil = unknown).
local function n36(s)
  if s == nil or s == "" then return nil end
  return tonumber(s, 36)
end
GW.N36 = n36

-- Parsed per-house numbers for an item key (item id, or "id:bonus" for suffix gear), cached:
-- { A = { mv, min, units, baitPrice, baitUnits, avg7, avg30, soldPerDay, boughtPerDay }, H = ..., N = ... }
-- soldPerDay = estimated (bought or cancelled early); boughtPerDay = proven sales (partial buys + sweeps).
local cache = {}
function GW.ResetCache() cache = {} end
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
      mv = n36(mv), min = n36(min), units = n36(units) or 0,
      baitPrice = n36(baitPrice) or 0, baitUnits = n36(baitUnits) or 0,
      avg7 = n36(avg7), avg30 = n36(avg30), soldPerDay = sold10 and sold10 / 10,
      boughtPerDay = bought10 and bought10 / 10,
      source = "server", at = pack.snapshotAt,
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

-- 30 daily typical prices (index 1 = the day starting at pack.histFrom; nil = no data), or nil.
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

-- Hour-of-day profile: { prices = [24], units = [24] } indexed 1..24 = UTC 00..23 (nil = no data).
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

-- What a vendor pays for one (from the client's item data; 0/nil when unsellable or not cached).
function GW.VendorPrice(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local sell = select(11, getInfo(itemID))
  return sell or 0
end

GW.MIN_UNITS_FOR_HINT = 10 -- a house needs this many units listed before we point players at it
GW.MIN_PROVEN_PER_DAY = 5 -- ...and this many proven sales per day (partial buys + sweeps)

-- Whether another house really pays more: >= 20% more net of both cuts, enough units listed and
-- proven buyers at that price (not just asking prices). Returns the % gain or nil.
function GW.BetterHouse(d, side, mv)
  if not (d and mv and mv > 0 and d.mv and (d.units or 0) >= GW.MIN_UNITS_FOR_HINT) then return nil end
  if (d.boughtPerDay or 0) < GW.MIN_PROVEN_PER_DAY then return nil end
  local here, there = GW.Net(GW.house.side, mv), GW.Net(side, d.mv)
  if here <= 0 or there < here * (1 + GW.Opt("betterPct") / 100) then return nil end
  return math.floor((there / here - 1) * 100 + 0.5)
end

-- "~550 sold/day" (proven sales), for hints that send players to another house.
function GW.SoldText(perDay)
  if not perDay then return "" end
  return perDay >= 10 and string.format("~%d sold/day", math.floor(perDay + 0.5)) or string.format("~%.1f sold/day", perDay)
end

-- Net per unit after the house's cut.
function GW.Net(side, price)
  return price * (1 - (GW.CUT[side] or 0.05))
end

-- One chat line saying why there are no server prices (ONB-2 / ONB-3).
function GW.PrintPackProblem()
  local h = GW.house or GW.DetectHouse()
  local want = "Goldwright Data: " .. h.region
  if GW.packStatus == "schema" then
    GW.Print("Your Goldwright data pack doesn't match this version of Goldwright. Update both in your add-on manager.")
  elseif GW.packStatus == "disabled" then
    GW.Print("The data pack for %s %s is installed but disabled. Enable GoldwrightData_%s in the AddOns list.", h.region, h.ruleset, h.packKey)
  elseif #(GW.otherPacks or {}) > 0 then
    GW.Print("No data for %s %s: you have %s installed. Install %s for prices in tooltips.", h.region, h.ruleset, table.concat(GW.otherPacks, ", "), want)
  else
    GW.Print("No data pack for %s %s. Install %s for prices in tooltips.", h.region, h.ruleset, want)
  end
end


-- One chat line when the pack is old (ONB-2); the Sell panel shows the same as a banner (AH-3).
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
function GW.OnLogin(fn) table.insert(GW.loginHandlers, fn) end

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
    if not GW.LoadPack() then GW.PrintPackProblem() else GW.PrintStaleNotice() end
    for _, fn in ipairs(GW.loginHandlers) do
      local ok, err = pcall(fn)
      if not ok then GW.Print("startup error: %s", tostring(err)) end
    end
  end
end)

-- /gw price <link>: the tooltip numbers in chat (CMD).
function GW.PriceLine(msg)
  local id = tonumber(msg:match("item:(%d+)") or msg:match("^%s*(%d+)%s*$") or "")
  if not id then return nil end
  local h = GW.house or GW.DetectHouse()
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
  if here.soldPerDay then
    local n = here.soldPerDay
    parts[#parts + 1] = n >= 10 and string.format("sells ~%d/day (est.)", math.floor(n + 0.5)) or string.format("sells ~%.1f/day (est.)", n)
  end
  for _, side in ipairs({ "A", "H", "N" }) do
    if side ~= h.side and d[side] and d[side].mv then parts[#parts + 1] = GW.HOUSE_NAMES[side] .. " " .. GW.Money(d[side].mv) end
  end
  return string.format("%s (%s): %s", name, GW.HOUSE_NAMES[h.side], table.concat(parts, " · "))
end

local HELP = "/gw status · /gw price [item] · /gw sell · /gw auctions · /gw scan · /gw lists · /gw add [item] · /gw config · /gw minimap · /gw welcome"

SLASH_GOLDWRIGHT1 = "/gw"
SLASH_GOLDWRIGHT2 = "/goldwright"
SlashCmdList.GOLDWRIGHT = function(raw)
  raw = strtrim(raw or "")
  local cmd, rest = raw:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  local h = GW.house or GW.DetectHouse()
  if cmd == "status" or cmd == "" then
    local pack = GW.Pack()
    GW.Print("%s · %s · %s (realm \"%s\").", h.region, h.ruleset, GW.HOUSE_NAMES[h.side], h.realm)
    if pack then
      GW.Print("Data pack %s %s: snapshot %s, built %s.", h.packKey, pack.version or "?", GW.Age(pack.snapshotAt), GW.Age(pack.builtAt))
      GW.PrintStaleNotice()
    else
      GW.PrintPackProblem()
    end
    GW.Print("Searches this minute: %d / %d.", GW.SearchesThisMinute(), GW.SEARCH_LIMIT)
    if cmd == "" then GW.Print("Commands: %s", HELP) end
  elseif cmd == "price" then
    GW.Print("%s", GW.PriceLine(rest) or "Usage: /gw price [item link]")
  elseif cmd == "sell" or cmd == "cancel" or cmd == "auctions" then
    if GW.OpenTab then GW.OpenTab(cmd == "sell" and "sell" or "cancel") end
  elseif cmd == "lists" or cmd == "shopping" then
    if GW.OpenTab then GW.OpenTab("shopping") end
  elseif cmd == "add" then
    if not GW.AddToList then return end
    local e, info = GW.AddToList(rest)
    if e then GW.Print("Added %s to %s.", e.name, info.name) else GW.Print("%s", info or "Usage: /gw add [item link or name]") end
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

-- Escape closes our windows without UISpecialFrames: adding names to that Blizzard table taints the
-- Escape key's game-menu path on this client ("blocked from an action only available to the
-- Blizzard UI" on every Esc, 2026-11-10). The frame takes Escape itself and lets every other key
-- through. Keyboard propagation can't change in combat, so in combat Escape just passes through.
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
