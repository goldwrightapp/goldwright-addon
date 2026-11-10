-- Item tooltip lines (requirements TT-1..TT-9), added to the game's own tooltip.
-- Default: at most 4 lines under the header (TT-2 market value, TT-3 now, TT-4 signal or TT-5
-- trend, TT-6 other houses). Holding the expand key (Shift by default) adds the rest.
-- Reads only our own stored data and the client's item cache: never asks the server for anything.
local _, GW = ...

local GREY = { 0.80, 0.80, 0.82 }
local WHITE = { 1, 1, 1 }
local SIDES = { "A", "H", "N" }

local function addPair(tt, left, right, rc)
  rc = rc or WHITE
  tt:AddDoubleLine(left, right, GREY[1], GREY[2], GREY[3], rc[1], rc[2], rc[3])
end
local function addLine(tt, text, c, wrap)
  c = c or GREY
  tt:AddLine(text, c[1], c[2], c[3], wrap)
end

local function count(n)
  n = math.floor(n + 0.5)
  return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

---------------------------------------------------------------------------
-- Per-item cache: link -> resolved pack key, parsed data and the slower lookups. Cleared with the
-- item data cache (GW.ResetCache: new pack, new scan, ruleset switch).
---------------------------------------------------------------------------
local cache, cacheSize = {}, 0
local baseReset = GW.ResetCache
function GW.ResetCache(...)
  cache, cacheSize = {}, 0
  return baseReset(...)
end
function GW.TooltipCacheSize() return cacheSize end

-- "item:id:enchant:gem1:gem2:gem3:gem4:suffix:unique:level:spec:mods:context:numBonus:bonus..." ->
-- id, the sorted bonus ids and the suffix field. Empty fields count as 0.
local function parseLink(link)
  local body = link and link:match("item:([%-%d:]+)")
  if not body then return nil end
  local f, i = {}, 0
  for x in (body .. ":"):gmatch("([^:]*):") do
    i = i + 1
    f[i] = tonumber(x) or 0
  end
  local id = f[1]
  if not id or id <= 0 then return nil end
  local bonus = {}
  local nb = f[13] or 0
  for b = 1, nb do
    local v = f[13 + b]
    if v and v > 0 then bonus[#bonus + 1] = v end
  end
  table.sort(bonus)
  return id, bonus, f[7] or 0
end

-- What a vendor pays for one, and how the item binds, from the client's item cache only: if the
-- client hasn't cached the item, GetItemInfo would ask the server, so we skip it.
local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local function cachedInfo(id)
  local isCached = C_Item and C_Item.IsItemDataCachedByID
  if isCached and not isCached(id) then return nil end
  local r = { getInfo(id) }
  if r[1] == nil then return nil end
  return { vendor = r[11] or 0, bindType = r[14] }
end

-- Weapons and armour: the only items with random suffixes ("(any suffix)" label).
local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local function isGear(id)
  if not getInstant then return true end
  local classID = select(6, getInstant(id))
  return classID == nil or classID == 2 or classID == 4
end

local function lowHigh(key, side)
  local days = GW.History(key, side)
  if not days then return nil end
  local lo, hi
  for i = 1, 30 do
    local v = days[i]
    if v then
      if not lo or v < lo then lo = v end
      if not hi or v > hi then hi = v end
    end
  end
  return lo, hi
end

-- Everything about an item that doesn't change between two hovers. Keys: suffix gear tries the
-- exact "id:bonus..." key first (the pack sorts bonus ids the same way), then each single bonus id
-- and the link's suffix field; with none of them in the pack, the base id = all suffixes together.
local function itemModel(link, fallbackID)
  local ck = link or fallbackID
  local m = cache[ck]
  if m ~= nil then return m end
  local id, bonus, suffix = parseLink(link)
  if not id then id, bonus, suffix = fallbackID, {}, 0 end
  if not id then return nil end
  local key, data, anySuffix
  if #bonus > 0 or suffix ~= 0 then
    local tries = {}
    if #bonus > 0 then tries[1] = id .. ":" .. table.concat(bonus, ":") end
    if #bonus > 1 then for _, b in ipairs(bonus) do tries[#tries + 1] = id .. ":" .. b end end
    if suffix ~= 0 then tries[#tries + 1] = id .. ":" .. suffix end
    for _, k in ipairs(tries) do
      data = GW.ItemData(k)
      if data then key = k break end
    end
  end
  if not data then
    key, data = id, GW.ItemData(id)
    anySuffix = data ~= nil and (#bonus > 0 or suffix ~= 0) and isGear(id)
  end
  local info = cachedInfo(id)
  local h = GW.house or GW.DetectHouse()
  local lo, hi = nil, nil
  if data then lo, hi = lowHigh(key, h.side) end
  m = { id = id, key = key, data = data, anySuffix = anySuffix, info = info, lo = lo, hi = hi }
  -- not cached yet: ask again next hover rather than remembering "no vendor price"
  if info or not (C_Item and C_Item.IsItemDataCachedByID) then
    cacheSize = cacheSize + 1
    if cacheSize > 5000 then cache, cacheSize = {}, 1 end -- every link is its own entry: keep it bounded
    cache[ck] = m
  end
  return m
end

---------------------------------------------------------------------------
-- States
---------------------------------------------------------------------------
-- The game's bound lines (ITEM_SOULBOUND etc. are Blizzard's own strings).
local function boundLine(text)
  return text and (text == ITEM_SOULBOUND or text == ITEM_ACCOUNTBOUND or text == ITEM_BNETACCOUNTBOUND
    or text == ITEM_BIND_TO_ACCOUNT or text == ITEM_BIND_TO_BNETACCOUNT)
end

-- Bind on pickup, quest and account-bound items can never go on the auction house; anything the
-- tooltip says is bound already (an equipped bind-on-equip item) can't either.
local NO_AH = { [1] = true, [4] = true, [7] = true, [8] = true }
local function notTradeable(tt, tipData, m)
  if m.info and NO_AH[m.info.bindType or 0] then return true end
  local lines = tipData and tipData.lines
  if lines then
    for i = 1, math.min(#lines, 8) do
      if boundLine(lines[i].leftText) then return true end
    end
    return false
  end
  local name = tt.GetName and tt:GetName()
  if not name then return false end
  for i = 2, 8 do
    local fs = _G[name .. "TextLeft" .. i]
    if fs and boundLine(fs:GetText()) then return true end
  end
  return false
end

-- How many the player is looking at: the hovered stack (bag, bank and other item buttons keep
-- their count on the button), else how many are in the bags. Returns n and a label.
local function heldCount(tt, id)
  local owner = tt.GetOwner and tt:GetOwner()
  local n = owner and type(owner.count) == "number" and owner.count or 0
  if n > 1 then return n, "Stack of " .. count(n) end
  local inBags = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id) or (GetItemCount and GetItemCount(id)) or 0
  if inBags > 1 then return inBags, count(inBags) .. " in your bags" end
  return 0
end

-- TT-9: the pack is missing, unusable or old (one line, or nil).
local function packFooter(h)
  local pack = GW.Pack()
  if not pack then
    local s = GW.packStatus
    if s == "disabled" then return "The Goldwright data pack for " .. h.region .. " is disabled: enable it in the AddOns list" end
    if s == "schema" then return "Your Goldwright data pack doesn't match this version: update both" end
    return "No Goldwright data pack for " .. h.region .. ": install it from CurseForge"
  end
  if pack.snapshotAt and GetServerTime() - pack.snapshotAt > GW.STALE_DAYS * 86400 then
    return "Price data is " .. GW.Age(pack.snapshotAt):gsub(" ago", "") .. " old: update the Goldwright data pack"
  end
  return nil
end

local function header(tt, m)
  tt:AddLine(" ")
  local label = m and m.anySuffix and "Goldwright |cff9a9aa2(any suffix)|r" or "Goldwright"
  tt:AddLine(label, GW.GOLD[1], GW.GOLD[2], GW.GOLD[3])
end

---------------------------------------------------------------------------
-- Lines
---------------------------------------------------------------------------
-- TT-4: cheapest real listing against normal, when outside the signal band. Returns text, color.
local function signal(here, normal)
  if not (normal and normal > 0 and here.mv and here.min) then return nil end
  local pct = math.floor((here.min / normal - 1) * 100 + 0.5)
  local band = GW.Opt("signalPct")
  if pct <= -band then return string.format("%d%% below normal: good time to buy", -pct), GW.SIGNAL_BLUE end
  if pct >= band then return string.format("%d%% above normal: good time to sell", pct), GW.SIGNAL_ORANGE end
  return nil
end

-- TT-5: "7-day +6% · sells ~420/day (est.)"; sell rate "n/a" until the server has enough history.
local function trend(here)
  local parts = {}
  if here.avg7 and here.avg30 and here.avg30 > 0 then
    local t = math.floor((here.avg7 / here.avg30 - 1) * 100 + 0.5)
    parts[1] = t == 0 and "7-day flat" or string.format("7-day %s%d%%", t > 0 and "+" or "-", math.abs(t))
  end
  local n = here.soldPerDay
  if n then
    parts[#parts + 1] = n >= 10 and string.format("sells ~%s/day (est.)", count(n)) or string.format("sells ~%.1f/day (est.)", n)
  elseif #parts > 0 then
    parts[#parts + 1] = "sells n/a"
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

local function tradeableLines(tt, m, h, expanded)
  local O = GW.Opt
  local data = m.data
  local here = data and data[h.side]
  local listed = here and here.mv

  if not data then -- nothing known: keep the tooltip clean unless the player wants a "no data" line
    local footer = packFooter(h)
    if O("ttNoData") or (footer and not GW.Pack()) then
      header(tt, m)
      if O("ttNoData") then addLine(tt, "No auction data yet") end
      if footer then addLine(tt, footer, GW.SIGNAL_ORANGE, true) end
    end
    return
  end

  header(tt, m)
  local normal = here and (here.avg7 or here.avg30)

  -- TT-2 market value; expanded: × the stack held
  if listed and O("ttMarket") then
    addPair(tt, "Market value", GW.Money(here.mv))
    if expanded then
      local n, label = heldCount(tt, m.id)
      if n > 1 then addPair(tt, "  " .. label, GW.Money(here.mv * n), GREY) end
    end
  end

  -- TT-3 now (cheapest real listing) with source and age; nothing listed: say so, with normal
  if listed then
    if O("ttNow") then
      local src = here.source == "scan" and "your scan " or "server "
      addPair(tt, "Now", GW.Money(here.min) .. "  |cff9a9aa2· " .. src .. GW.Age(here.at) .. "|r")
      if expanded and here.baitUnits > 0 then
        addLine(tt, string.format("%d bait listing%s at %s ignored", here.baitUnits, here.baitUnits == 1 and "" or "s",
          GW.Money(here.baitPrice)), GW.SIGNAL_ORANGE)
      end
    end
  else
    local right = "none listed now"
    if normal and O("ttNormal") then right = right .. " · normal " .. GW.Money(normal) end
    addPair(tt, GW.HOUSE_NAMES[h.side], right, GREY)
  end

  -- one line for TT-4 (when notable) or else TT-5; expanded shows both, plus normal and 30-day range
  if here then
    local sig, sigColor
    if O("ttNormal") then sig, sigColor = signal(here, normal) end
    if expanded and listed and normal and O("ttNormal") then
      addPair(tt, here.avg7 and "Normal (7 days)" or "Normal (30 days)", GW.Money(normal))
    end
    if sig then addLine(tt, sig, sigColor) end
    local tr = O("ttTrend") and trend(here)
    if tr and (expanded or not sig) then addLine(tt, tr) end
  end
  if expanded then
    addPair(tt, "30-day low / high", m.lo and (GW.Money(m.lo) .. " / " .. GW.Money(m.hi)) or "building history", GREY)
  end

  -- TT-6 other houses; when another house really pays more (>= 20% net, real depth, proven
  -- buyers) that evidence takes the line instead. Expanded: the full per-house table.
  local gain = listed and h.side ~= "N" and O("ttBetter") and GW.BetterHouse(data.N, "N", here.mv)
  if gain then
    addLine(tt, string.format("Blackwater nets ~%d%% more after its 15%% cut (%s)", gain, GW.SoldText(data.N.boughtPerDay)), GW.SIGNAL_BLUE)
  elseif O("ttOthers") and not expanded then
    local others = {}
    for _, side in ipairs(SIDES) do
      if side ~= h.side and data[side] and data[side].mv then
        others[#others + 1] = GW.HOUSE_NAMES[side] .. " " .. GW.Money(data[side].mv)
      end
    end
    if #others > 0 then addPair(tt, "Other houses", table.concat(others, " · ")) end
  end

  if expanded then
    -- TT-7 vendor comparison, per unit
    local vendor = m.info and m.info.vendor or 0
    if listed and vendor > 0 and O("ttVendor") then
      if GW.Net(h.side, here.mv) <= vendor then
        addLine(tt, "Vendor pays " .. GW.Money(vendor) .. ": more than the auction house", GW.SIGNAL_ORANGE)
      end
      if here.min and here.min < vendor then
        addLine(tt, string.format("Deal: buy below %s and sell to a vendor (+%s each)", GW.Money(vendor), GW.Money(vendor - here.min)), GW.SIGNAL_BLUE)
      end
    end
    -- per-house table: market value and units listed
    for _, side in ipairs(SIDES) do
      local d = data[side]
      if d then
        local right = d.mv and string.format("%s  ·  %s listed", GW.Money(d.mv), count(d.units))
          or ("none listed" .. (d.avg7 and (" · normal " .. GW.Money(d.avg7)) or ""))
        addPair(tt, "  " .. GW.HOUSE_NAMES[side] .. (side == h.side and " (here)" or ""), right, GREY)
      end
    end
  end

  local footer = packFooter(h)
  if footer then addLine(tt, footer, GW.SIGNAL_ORANGE, true) end
end

local function addTooltipLines(tt, link, itemID, tipData)
  local m = itemModel(link, itemID)
  if not m then return end
  local h = GW.house or GW.DetectHouse()
  -- soulbound and other items that can't be sold at the auction house: the vendor line only
  if notTradeable(tt, tipData, m) then
    local vendor = m.info and m.info.vendor or 0
    if vendor > 0 and GW.Opt("ttVendor") then
      addPair(tt, "Goldwright: vendor pays", GW.Money(vendor) .. " each", GREY)
    end
    return
  end
  tradeableLines(tt, m, h, GW.ExpandKeyDown())
end

local function onItemTooltip(tt, data)
  if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
  local link, id
  if tt.GetItem then link = select(2, tt:GetItem()) end
  if not link and data then link = data.hyperlink end
  id = data and data.id
  if not id and link then id = tonumber(link:match("item:(%d+)")) end
  if not id then return end
  local ok, err = pcall(addTooltipLines, tt, link, id, data)
  if not ok and not GW.tooltipErrorShown then
    GW.tooltipErrorShown = true
    GW.Print("tooltip error (shown once): %s", tostring(err))
  end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, onItemTooltip)
else
  GameTooltip:HookScript("OnTooltipSetItem", function(tt) onItemTooltip(tt, nil) end)
  ItemRefTooltip:HookScript("OnTooltipSetItem", function(tt) onItemTooltip(tt, nil) end)
end
