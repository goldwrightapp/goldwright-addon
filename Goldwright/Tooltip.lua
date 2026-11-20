--- Item tooltip lines (TT-1..TT-9), added to the game's own tooltip. Default: "Goldwright · Min price",
--- how it sells, a buy / sell signal when notable and one line per other house; holding the expand key
--- (Shift by default) adds the averages, your sales, listings and the data age below. Reads only our own stored data and the client's
--- item cache: never asks the server for anything.
local _, GW = ...
local L = GW.L

local GREY = { 0.80, 0.80, 0.82 }
local WHITE = { 1, 1, 1 }
local SIDES = { "A", "H", "N" }

--- Adds a label / value line: grey label, value in `rc`.
---@param tt table tooltip
---@param left string label
---@param right string value
---@param rc number[]? value colour {r, g, b} (default white)
local function addPair(tt, left, right, rc)
  rc = rc or WHITE
  tt:AddDoubleLine(left, right, GREY[1], GREY[2], GREY[3], rc[1], rc[2], rc[3])
end

--- Adds a single line.
---@param tt table tooltip
---@param text string
---@param c number[]? colour {r, g, b} (default grey)
---@param wrap boolean? wrap long text
local function addLine(tt, text, c, wrap)
  c = c or GREY
  tt:AddLine(text, c[1], c[2], c[3], wrap)
end

--- A rounded count with thousands separators.
local function count(n) return GW.Number(math.floor(n + 0.5)) end

---------------------------------------------------------------------------
-- Per-item cache: link -> resolved pack key, parsed data and the slower lookups. Cleared with the
-- item data cache (GW.ResetCache: new pack, new scan, ruleset switch).
---------------------------------------------------------------------------
local cache, cacheSize = {}, 0
local baseReset = GW.ResetCache

--- Clears the tooltip cache, then the item data cache (wraps Core's GW.ResetCache).
---@param ... any passed on to the original GW.ResetCache
function GW.ResetCache(...)
  cache, cacheSize = {}, 0
  return baseReset(...)
end

--- Number of items in the tooltip cache (for tests).
---@return number
function GW.TooltipCacheSize() return cacheSize end

--- Parses an item link: "item:id:enchant:gem1:gem2:gem3:gem4:suffix:unique:level:spec:mods:context:
--- numBonus:bonus...". Empty fields count as 0.
---@param link string|nil item link
---@return number|nil id nil when the link holds no item
---@return number[] bonus the bonus ids, sorted
---@return number suffix the suffix field
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

local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

--- What a vendor pays for one, and how the item binds, from the client's item cache only: if the
--- client hasn't cached the item, GetItemInfo would ask the server, so we skip it.
---@param id number item id
---@return { vendor: number, bindType: number? }|nil info nil when the item isn't cached
local function cachedInfo(id)
  local isCached = C_Item and C_Item.IsItemDataCachedByID
  if isCached and not isCached(id) then return nil end
  local r = { getInfo(id) }
  if r[1] == nil then return nil end
  return { name = r[1], vendor = r[11] or 0, bindType = r[14] }
end

local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

--- Whether an item is a weapon or armour: the only items with random suffixes ("(any suffix)" label).
--- True when the client can't tell.
---@param id number item id
---@return boolean
local function isGear(id)
  if not getInstant then return true end
  local classID = select(6, getInstant(id))
  return classID == nil or classID == 2 or classID == 4
end

--- Everything the tooltip needs about one item, cached per link.
---@class GoldwrightTooltipModel
---@field id number item id
---@field key number|string the pack key that matched (or the base id)
---@field data table<string, GoldwrightItemSide>|nil GW.ItemData result
---@field anySuffix boolean|nil the numbers are for all suffixes together (base id of suffix gear)
---@field info { vendor: number, bindType: number? }|nil client item info

--- Everything about an item that doesn't change between two hovers. Keys: suffix gear tries the
--- exact "id:bonus..." key first (the pack sorts bonus ids the same way), then each single bonus id
--- and the link's suffix field; with none of them in the pack, the base id = all suffixes together.
---@param link string|nil item link
---@param fallbackID number|nil item id when the link can't be parsed
---@return GoldwrightTooltipModel|nil model nil without an item id
local function itemModel(link, fallbackID)
  local ck = link or fallbackID
  local m = cache[ck]
  if m ~= nil then return m end
  local id, bonus, suffix = parseLink(link)
  if not id then
    id, bonus, suffix = fallbackID, {}, 0
  end
  if not id then return nil end
  local key, data, anySuffix
  if #bonus > 0 or suffix ~= 0 then
    local tries = {}
    if #bonus > 0 then tries[1] = id .. ":" .. table.concat(bonus, ":") end
    if #bonus > 1 then
      for _, b in ipairs(bonus) do
        tries[#tries + 1] = id .. ":" .. b
      end
    end
    if suffix ~= 0 then tries[#tries + 1] = id .. ":" .. suffix end
    for _, k in ipairs(tries) do
      data = GW.ItemData(k)
      if data then
        key = k
        break
      end
    end
  end
  if not data then
    key, data = id, GW.ItemData(id)
    anySuffix = data ~= nil and (#bonus > 0 or suffix ~= 0) and isGear(id)
  end
  local info = cachedInfo(id)
  -- The name as the client shows it (sales are recorded by name, from the invoices).
  local name = link and link:match("|h%[(.-)%]|h") or (info and info.name)
  m = { id = id, key = key, data = data, anySuffix = anySuffix, info = info, name = name }
  -- Not in the client's item cache yet: ask again next hover rather than remembering "no vendor price".
  if info or not (C_Item and C_Item.IsItemDataCachedByID) then
    -- Every link is its own entry: keep the cache bounded.
    cacheSize = cacheSize + 1
    if cacheSize > 5000 then
      cache, cacheSize = {}, 1
    end
    cache[ck] = m
  end
  return m
end

---------------------------------------------------------------------------
-- States
---------------------------------------------------------------------------

--- Whether a tooltip line is one of the game's "bound" lines (ITEM_SOULBOUND etc. are Blizzard's
--- own strings).
---@param text string|nil line text
---@return boolean|nil
local function boundLine(text)
  return text
    and (
      text == ITEM_SOULBOUND
      or text == ITEM_ACCOUNTBOUND
      or text == ITEM_BNETACCOUNTBOUND
      or text == ITEM_BIND_TO_ACCOUNT
      or text == ITEM_BIND_TO_BNETACCOUNT
    )
end

-- Bind types that can never go on the auction house: bind on pickup, quest and account-bound.
local NO_AH = { [1] = true, [4] = true, [7] = true, [8] = true }

--- Whether the item can't go on the auction house: its bind type never can, or the tooltip says
--- it is bound already (e.g. an equipped bind-on-equip item). Checks the first 8 lines.
---@param tt table tooltip
---@param tipData table|nil tooltip data from TooltipDataProcessor (with `lines`)
---@param m GoldwrightTooltipModel
---@return boolean
local function notTradeable(tt, tipData, m, product)
  if m.info and NO_AH[m.info.bindType or 0] then return true end
  -- A recipe's tooltip shows the crafted item below it, binding line included: that one isn't the
  -- recipe's (goldwright-addon #7).
  if product then return false end
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

--- TT-9: one line when the pack is missing, unusable or old.
---@param h GoldwrightHouse
---@return string|nil text nil when the pack is fine
local function packFooter(h)
  local pack = GW.Pack()
  if not pack then
    local s = GW.packStatus
    if s == "disabled" then
      return string.format(L["The Goldwright data pack for %s is disabled: enable it in the AddOns list"], h.region)
    end
    if s == "schema" then return L["Your Goldwright data pack doesn't match this version: update both"] end
    return string.format(L["No Goldwright data pack for %s: install it from CurseForge"], h.region)
  end
  if pack.snapshotAt and GetServerTime() - pack.snapshotAt > GW.STALE_DAYS * 86400 then
    local days = math.floor((GetServerTime() - pack.snapshotAt) / 86400)
    return GW.Plural(
      days,
      "Price data is %d day old: update the Goldwright data pack",
      "Price data is %d days old: update the Goldwright data pack"
    )
  end
  return nil
end

--- The first Goldwright line's label: "Goldwright" in gold, then what the price is, in grey.
---@param m GoldwrightTooltipModel|nil
---@param what string|nil e.g. "Min price"; nil = just the name
---@return string label
local function title(m, what)
  local s = "|cffe0ac3aGoldwright|r"
  if m and m.anySuffix then s = s .. " |cff9a9aa2" .. L["(any suffix)"] .. "|r" end
  if what then s = s .. "|cff9a9aa2 · " .. what .. "|r" end
  return s
end

--- Money for the right-hand column: coins after a bigger coin take two digits of room, so the
--- coins line up down the tooltip.
---@param copper number
---@return string text
local function money(copper) return GW.Money(copper, true) end

---------------------------------------------------------------------------
-- Lines
---------------------------------------------------------------------------

--- TT-4: the cheapest real listing against the average, when outside the signal band.
---@param here GoldwrightItemSide
---@param avg number|nil average price
---@return string|nil text nil inside the band
---@return number[]|nil color
local function signal(here, avg)
  if not (avg and avg > 0 and here.mv and here.min) then return nil end
  local pct = math.floor((here.min / avg - 1) * 100 + 0.5)
  local band = GW.Opt("signalPct")
  if pct <= -band then return string.format(L["%d%% below avg: good time to buy"], -pct), GW.SIGNAL_BLUE end
  if pct >= band then return string.format(L["%d%% above avg: good time to sell"], pct), GW.SIGNAL_ORANGE end
  return nil
end

-- Sales a day from which an item "sells fast" / "steady"; below that it "sells slowly".
local FAST, STEADY = 100, 10

--- TT-5: "Sells fast ~1,960 a day · price -5% this week". Proven sales when there are any, else the
--- estimate marked "(est.)" (always for gear); the trend is the 7-day average against the 30-day one.
---@param here GoldwrightItemSide
---@return string|nil text nil when neither part is known
local function sells(here)
  local parts = {}
  local n, proven = GW.SellRate(here)
  if n then
    local num = n >= 10 and GW.Number(math.floor(n + 0.5)) or GW.Decimal(n)
    local fmt = n >= FAST and L["Sells fast ~%s a day"]
      or n >= STEADY and L["Sells steady ~%s a day"]
      or L["Sells slowly ~%s a day"]
    parts[1] = string.format(fmt, num) .. (proven and "" or (" " .. L["(est.)"]))
  end
  if here.avg7 and here.avg30 and here.avg30 > 0 then
    local t = math.floor((here.avg7 / here.avg30 - 1) * 100 + 0.5)
    if t ~= 0 then
      local fmt = #parts > 0 and L["price %s%d%% this week"] or L["Price %s%d%% this week"]
      parts[#parts + 1] = string.format(fmt, t > 0 and "+" or "-", math.abs(t))
    end
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

--- Adds the Goldwright lines for an item that can go on the auction house (TT-2..TT-9). Money is
--- always alone on the right, so the coins form one column; text that isn't money gets its own line.
---@param tt table tooltip
---@param m GoldwrightTooltipModel
---@param h GoldwrightHouse
---@param expanded boolean the expand key is held: show every line
local function tradeableLines(tt, m, h, expanded)
  local O = GW.Opt
  local data = m.data
  local here = data and data[h.side]
  local listed = here and here.mv

  if not data then -- nothing known: keep the tooltip clean unless the player wants a "no data" line
    local footer = packFooter(h)
    if O("ttNoData") or (footer and not GW.Pack()) then
      addLine(tt, title(m, O("ttNoData") and L["No auction data yet"] or nil))
      if footer then addLine(tt, footer, GW.SIGNAL_ORANGE, true) end
    end
    return
  end

  -- The compact lines come first and stay as they are when the expand key is held: the expanded
  -- view only adds lines below them (never between, never instead), so the tooltip only gets
  -- taller. Its added single lines wrap to the width the compact lines set.

  -- TT-3 min price (the cheapest real listing); nothing listed: say so, and the average stands in
  local avg30 = here and (here.avg30 or here.avg7)
  local avgShown -- the average the compact view already showed
  if not O("ttNow") then
    addLine(tt, title(m))
  elseif listed then
    addPair(tt, title(m, L["Min price"]), money(here.min))
  else
    addPair(tt, title(m, L["Min price"]), L["none listed"], GREY)
  end
  if not listed and avg30 and O("ttNormal") then
    avgShown = here.avg30 and "avg30" or "avg7"
    addPair(tt, "  " .. (here.avg30 and L["Avg price (30 days)"] or L["Avg price (7 days)"]), money(avg30))
  end

  -- TT-7 a vendor pays more than the auction house nets after its cut (whole copper)
  local vendor = m.info and m.info.vendor or 0
  if listed and vendor > 0 and O("ttVendor") and math.floor(vendor - GW.Net(h.side, here.min)) >= 1 then
    addLine(tt, L["A vendor pays more than you'd get here"], GW.SIGNAL_ORANGE)
  end

  -- TT-5 how it sells and where the price is heading; TT-4 the buy / sell signal when notable
  if here then
    local s = O("ttTrend") and sells(here)
    if s then addLine(tt, s) end
    local sig, sigColor
    if O("ttNormal") then
      sig, sigColor = signal(here, here.avg7 or here.avg30)
    end
    if sig then addLine(tt, sig, sigColor) end
  end

  -- TT-6 the other houses the player wants, one line each so their prices line up with ours;
  -- when Blackwater really pays more (>= 20% net, real depth, proven buyers) a line says so.
  local function shown(side)
    if side == h.side then return true end
    return O(side == "N" and "ttBlackwater" or "ttOtherFaction")
  end
  for _, side in ipairs(SIDES) do
    local d = data[side]
    if side ~= h.side and shown(side) and d and d.mv then
      addPair(tt, "  " .. GW.HOUSE_NAMES[side], money(d.min or d.mv))
    end
  end
  local gain = listed and h.side ~= "N" and O("ttBetter") and GW.BetterHouse(data.N, "N", here.mv)
  if gain then
    addLine(
      tt,
      string.format(L["Blackwater nets ~%d%% more after its 15%% cut (%s)"], gain, GW.SoldText(data.N.boughtPerDay)),
      GW.SIGNAL_BLUE,
      true
    )
  end

  if expanded then
    -- the 7- and 30-day averages (the one the compact view showed isn't repeated)
    if here and O("ttNormal") then
      if here.avg7 and avgShown ~= "avg7" then addPair(tt, "  " .. L["Avg price (7 days)"], money(here.avg7)) end
      if here.avg30 and avgShown ~= "avg30" then addPair(tt, "  " .. L["Avg price (30 days)"], money(here.avg30)) end
    end
    if listed and O("ttNow") and here.baitUnits > 0 then
      addLine(
        tt,
        GW.Plural(
          here.baitUnits,
          "%d bait listing at %s ignored",
          "%d bait listings at %s ignored",
          GW.Money(here.baitPrice)
        ),
        GW.SIGNAL_ORANGE,
        true
      )
    end
    -- TT-7 deal: listed below what a vendor pays, per unit
    if listed and vendor > 0 and O("ttVendor") and here.min and here.min < vendor then
      addPair(tt, "  " .. L["Deal: buy here, sell to a vendor, each"], money(vendor - here.min), GW.SIGNAL_BLUE)
    end
    -- your own sales of it (Ledger.lua): one line, a second only when some came back unsold
    local name = m.name or (m.info and m.info.name)
    local mine = O("ttSales") and GW.LedgerTooltipInfo and GW.LedgerTooltipInfo(name)
    if mine then
      if mine.sold == 0 then
        addLine(
          tt,
          "  " .. GW.Plural(mine.returns, "You listed it %d time, none sold", "You listed it %d times, none sold"),
          GW.GOLD
        )
      else
        local label = "  " .. string.format(L["You sold %s, last at"], GW.Number(mine.sold))
        tt:AddDoubleLine(label, money(mine.lastUnit), GW.GOLD[1], GW.GOLD[2], GW.GOLD[3], 1, 1, 1)
        if mine.unsold > 0 then
          addLine(
            tt,
            "  " .. GW.Plural(mine.unsold, "%d of yours came back unsold", "%d of yours came back unsold"),
            GW.GOLD
          )
        end
      end
    end
    -- units listed at each house, one line
    local listedAt = {}
    for _, side in ipairs(SIDES) do
      local d = data[side]
      if d and shown(side) then
        listedAt[#listedAt + 1] = GW.HOUSE_NAMES[side] .. " " .. (d.mv and count(d.units) or L["none"])
      end
    end
    if #listedAt > 0 then
      addLine(tt, "  " .. string.format(L["Listed: %s"], table.concat(listedAt, " · ")), nil, true)
    end
    -- where the prices come from, and how old they are
    if here and here.at and here.at > 0 then
      local fmt = here.source == "scan" and L["From your scan %s"] or L["From Goldwright Data %s"]
      addLine(tt, "  " .. string.format(fmt, GW.Age(here.at)))
    end
  end

  local footer = packFooter(h)
  if footer then addLine(tt, footer, GW.SIGNAL_ORANGE, true) end
end

--- Adds Goldwright's lines to an item tooltip: only the vendor price for items that can't go on
--- the auction house, else the full set.
---@param tt table tooltip
---@param link string|nil item link
---@param itemID number item id
---@param tipData table|nil tooltip data from TooltipDataProcessor
---@param product number|nil on a recipe's tooltip, the id of the item it makes
local function addTooltipLines(tt, link, itemID, tipData, product)
  local m = itemModel(link, itemID)
  if not m then return end
  local h = GW.House()
  -- soulbound and other items that can't be sold at the auction house: the vendor line only
  if notTradeable(tt, tipData, m, product) then
    local vendor = m.info and m.info.vendor or 0
    if vendor > 0 and GW.Opt("ttVendor") then
      addPair(tt, L["Goldwright: vendor pays"], string.format(L["%s each"], GW.Money(vendor)), GREY)
    end
    return
  end
  tradeableLines(tt, m, h, GW.ExpandKeyDown())
end

--- Item tooltip hook for GameTooltip and ItemRefTooltip. Finds the item link and id, then adds our
--- lines; an error is printed once and never breaks the tooltip.
---@param tt table tooltip
---@param data table|nil tooltip data (nil on clients without TooltipDataProcessor)
local function onItemTooltip(tt, data)
  if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
  local link, id, shownID
  if tt.GetItem then
    local _
    _, link, shownID = tt:GetItem()
  end
  if not link and data then link = data.hyperlink end
  id = (data and data.id) or shownID
  local linkID = link and tonumber(link:match("item:(%d+)"))
  if not id then id = linkID end
  if not id then return end
  -- A recipe's tooltip comes with the crafted item's link but the recipe's id: the id is what the
  -- tooltip is for (Blueprint: Repair Bot showed the Repair Bot's price, goldwright-addon #7).
  -- Recipes have no suffixes, so the id alone finds them.
  local product
  if linkID and linkID ~= id then
    product, link = linkID, nil
  end
  local ok, err = pcall(addTooltipLines, tt, link, id, data, product)
  if not ok and not GW.tooltipErrorShown then
    GW.tooltipErrorShown = true
    GW.Print("tooltip error (shown once): %s", tostring(err))
  end
end

-- Newer clients: TooltipDataProcessor. Older ones: the OnTooltipSetItem script.
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, onItemTooltip)
else
  GameTooltip:HookScript("OnTooltipSetItem", function(tt) onItemTooltip(tt, nil) end)
  ItemRefTooltip:HookScript("OnTooltipSetItem", function(tt) onItemTooltip(tt, nil) end)
end
