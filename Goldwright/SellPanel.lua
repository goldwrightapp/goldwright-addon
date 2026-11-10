-- Goldwright panel beside the auction house: tab bar (Sell, Cancel; Shopping and Scan later) and the
-- Sell tab, layout B (requirements SELL-1..18): three columns read left to right:
-- 1 Choose (bags) -> 2 Market (stats, listings, charts) -> 3 Your listing (strategies, price, receipt, Post).
-- Posting: one listing per click (or key press); afterwards the next item is selected and searched
-- (post queue, SELL-13). Rules without UI live in Selling.lua.
local _, GW = ...

local W, H = 1000, 560
local ROWS, ROW_H = 13, 30
local DURATIONS = { { idx = 1, label = "2h" }, { idx = 2, label = "8h" }, { idx = 3, label = "24h" } }
local STRATEGIES = {
  { key = "fast", label = "Sell Fast" },
  { key = "typical", label = "Typical" },
  { key = "patient", label = "Patient" },
}
local TABS = {
  { key = "sell", label = "Sell" },
  { key = "cancel", label = "My Auctions" },
  { key = "shopping", label = "Shopping" },
  { key = "scan", label = "Scan" },
}
local PATIENT_MARKUP = 1.10       -- Patient = ~10% above typical (rule to tune)
local FAST_OK_RATIO = 0.85        -- default to "Sell fast" only if it isn't >15% under typical
local POST_TIMEOUT = 10           -- seconds to wait for the auction house to confirm a post

local panel -- the frame, created on first use
local state = { bags = {}, offset = 0, sel = nil, stats = nil, duration = 3, strategy = nil, prices = nil }
GW.activeTab = "sell"

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function fs(parent, template, justify)
  local f = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
  if justify then f:SetJustifyH(justify) end
  return f
end

local function setColor(f, c) f:SetTextColor(c[1], c[2], c[3]) end
local GREY = { 0.70, 0.70, 0.72 }
local WHITE = { 1, 1, 1 }

local function qualityColor(q)
  if C_Item and C_Item.GetItemQualityColor and q then
    local r, g, b = C_Item.GetItemQualityColor(q)
    if r then return { r, g, b } end
  end
  local c = ITEM_QUALITY_COLORS and q and ITEM_QUALITY_COLORS[q]
  return c and { c.r, c.g, c.b } or { 1, 1, 1 }
end

-- Server numbers for this house, only when the item is listed now (history-only entries have no mv).
local function packFor(itemID)
  local d = GW.ItemData(itemID)
  local here = d and d[(GW.house or GW.DetectHouse()).side]
  return here and here.mv and here or nil, d
end

local function itemCount(itemID)
  if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(itemID, false) or 0 end
  return GetItemCount and GetItemCount(itemID) or 0
end

local function divider(parent, x)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetColorTexture(1, 1, 1, 0.08)
  t:SetPoint("TOPLEFT", x, -6)
  t:SetPoint("BOTTOMLEFT", x, 6)
  t:SetWidth(1)
end

local function toast(text, color)
  if not panel then return end
  panel.toast:SetText(text or "")
  setColor(panel.toast, color or WHITE)
end

local function ignored(itemID) return GoldwrightDB.ignore and GoldwrightDB.ignore[itemID] end

---------------------------------------------------------------------------
-- column 1: bags (SELL-1, SELL-2)
---------------------------------------------------------------------------
local function scanBags()
  local groups, list, hidden = {}, {}, 0
  local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
  for bag = 0, lastBag do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and not info.isBound then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if loc and loc:IsValid() and C_AuctionHouse.IsSellItemValid(loc, false) then
          local g = groups[info.itemID]
          if not g then
            local status = C_AuctionHouse.GetItemCommodityStatus(loc)
            g = {
              itemID = info.itemID, count = 0, loc = loc, quality = info.quality,
              bag = bag, slot = slot, icon = info.iconFileID, hidden = ignored(info.itemID) and true or nil,
              name = (info.hyperlink and info.hyperlink:match("%[(.-)%]")) or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(info.itemID)) or ("item " .. info.itemID),
              isCommodity = Enum and Enum.ItemCommodityStatus and status == Enum.ItemCommodityStatus.Commodity,
            }
            groups[info.itemID] = g
            if g.hidden then hidden = hidden + 1 end
            if not g.hidden or state.showHidden then list[#list + 1] = g end
          end
          g.count = g.count + (info.stackCount or 1)
        end
      end
    end
  end
  for _, g in ipairs(list) do
    local here = packFor(g.itemID)
    g.unit = here and here.min and GW.UndercutPrice(here.min, nil, not g.isCommodity) or nil
    g.total = g.unit and g.unit * g.count or 0
  end
  -- Sort by value when the panel opens, then keep that order while it stays open: posting part of
  -- a stack lowers its value, and rows jumping around under the mouse breaks the post queue's flow.
  -- Items new to the bags go to the end. state.rank is cleared each time the panel opens.
  state.rank = state.rank or {}
  local rank = state.rank
  table.sort(list, function(a, b)
    local ra, rb = rank[a.itemID], rank[b.itemID]
    if ra and rb then return ra < rb end
    if ra or rb then return ra ~= nil end
    if a.total ~= b.total then return a.total > b.total end
    return a.name < b.name
  end)
  local maxRank = 0
  for _, r in pairs(rank) do if r > maxRank then maxRank = r end end
  for _, g in ipairs(list) do
    if not rank[g.itemID] then
      maxRank = maxRank + 1
      rank[g.itemID] = maxRank
    end
  end
  state.bags, state.hiddenCount = list, hidden
  -- keep the selection pointing at the fresh entry (counts change after posting)
  if state.sel then
    local fresh = groups[state.sel.itemID]
    if fresh then
      state.sel.count, state.sel.loc, state.sel.bag, state.sel.slot = fresh.count, fresh.loc, fresh.bag, fresh.slot
    end
  end
end

-- First bag slot holding this item that can be posted now (bags shift after every post).
local function findLocation(itemID)
  local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
  for bag = 0, lastBag do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID == itemID and not info.isLocked then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if loc and loc:IsValid() and C_AuctionHouse.IsSellItemValid(loc, false) then return loc end
      end
    end
  end
  return nil
end

local function renderBags()
  local total = 0
  for _, g in ipairs(state.bags) do if not g.hidden then total = total + g.total end end
  for i, row in ipairs(panel.rows) do
    local g = state.bags[i + state.offset]
    row.g = g
    if g then
      row:Show()
      row.icon:SetTexture(g.icon or 134400)
      row.icon:SetDesaturated(g.hidden and true or false)
      row.name:SetText(g.name .. "  |cff9a9aa2×" .. g.count .. "|r")
      setColor(row.name, g.hidden and GREY or qualityColor(g.quality))
      row.sub:SetText(g.total > 0 and ("about " .. GW.Money(g.total)) or "no price data")
      local here, d = packFor(g.itemID)
      local vendor = GW.VendorPrice(g.itemID)
      local note = ""
      if g.hidden then
        note = "|cff9a9aa2hidden|r"
      elseif vendor > 0 and g.unit and GW.Net("A", g.unit) <= vendor then
        note = "|cfff59e4bvendor pays more|r"
      elseif here and d and GW.BetterHouse(d.N, "N", here.mv) then
        note = string.format("|cff8fb0ffBlackwater +%d%%|r", GW.BetterHouse(d.N, "N", here.mv))
      elseif here and here.baitUnits and here.baitUnits > 0 then
        note = "|cfff59e4bbait skipped|r"
      end
      row.note:SetText(note)
      row.sel:SetShown(state.sel and state.sel.itemID == g.itemID)
    else
      row:Hide()
    end
  end
  local shown = #state.bags - (state.showHidden and state.hiddenCount or 0)
  panel.bagFooter:SetText(string.format("%d sellable items · about %s", shown, GW.Money(total)))
  if (state.hiddenCount or 0) > 0 then
    panel.hiddenLink:SetText(string.format(state.showHidden and "|cff8fb0ffhide %d again|r" or "|cff8fb0ff%d hidden · show|r", state.hiddenCount))
    panel.hiddenLink:Show()
  else
    panel.hiddenLink:Hide()
  end
end

---------------------------------------------------------------------------
-- column 3: strategies, price, receipt (SELL-4..11, 17, 18)
---------------------------------------------------------------------------
local function getUnitPrice()
  if panel.money and MoneyInputFrame_GetCopper then return MoneyInputFrame_GetCopper(panel.money) or 0 end
  return tonumber(panel.copperBox and panel.copperBox:GetText() or "") or 0
end

local function setUnitPrice(c)
  state.settingPrice = true
  if panel.money and MoneyInputFrame_SetCopper then MoneyInputFrame_SetCopper(panel.money, c)
  elseif panel.copperBox then panel.copperBox:SetText(tostring(c)) end
  state.settingPrice = false
end

-- The price that will be posted: what's in the box, rounded down to whole silver for gear.
local function postUnit()
  local g, unit = state.sel, getUnitPrice()
  if g and not g.isCommodity and unit > 0 then return GW.SilverFloor(unit), unit % 100 ~= 0 end
  return unit, false
end

-- Commodities post any quantity in one listing; other items post one auction per click.
local function quantity()
  local g = state.sel
  if not g then return 1 end
  if not g.isCommodity then return 1 end
  return math.max(1, math.min(tonumber(panel.qty:GetText()) or 1, g.count))
end

local function youReceive(unit, qty)
  local gross = unit * qty
  return gross - math.floor(gross * GW.CUT.A + 0.5)
end

local function postLabel(g, qty)
  if g.isCommodity then return string.format("Post %d × %s", qty, g.name) end
  if g.count > 1 then return string.format("Post 1 of %d · %s", g.count, g.name) end
  return "Post " .. g.name
end

local function recalc()
  local g = state.sel
  if not g then return end
  local qty, unit, rounded = quantity(), postUnit()

  -- strategy buttons show what you'd receive at the current quantity
  for _, b in ipairs(panel.stratButtons) do
    local p = state.prices and state.prices[b.key]
    if p then
      b:SetText(string.format("%s\n%s", b.label, GW.Money(p)))
      b.receive:SetText("get " .. GW.Money(youReceive(p, qty)))
      b:Enable()
    else
      b:SetText(b.label); b.receive:SetText(""); b:Disable()
    end
    if state.strategy == b.key then b:LockHighlight() else b:UnlockHighlight() end
  end

  -- Deposit from the item's current slot: after a post the remembered slot can be empty, and the
  -- game raises an error for an empty item location (seen in game 2026-11-10).
  local deposit
  if g.isCommodity then
    local ok, d = pcall(C_AuctionHouse.CalculateCommodityDeposit, g.itemID, state.duration, qty)
    deposit = ok and d or nil
  else
    local loc = findLocation(g.itemID)
    if loc then
      local ok, d = pcall(C_AuctionHouse.CalculateItemDeposit, loc, state.duration, qty)
      deposit = ok and d or nil
    end
  end
  local gross = unit * qty
  local cut = math.floor(gross * GW.CUT.A + 0.5)
  panel.r1L:SetText(string.format("Listing total (%d × %s)", qty, GW.Money(unit))); panel.r1R:SetText(GW.Money(gross))
  panel.r2L:SetText("Auction house cut (5%)"); panel.r2R:SetText("−" .. GW.Money(cut))
  panel.r3L:SetText("You receive if all sell"); panel.r3R:SetText(GW.Money(gross - cut))
  panel.r4L:SetText("Deposit now (back when it sells)"); panel.r4R:SetText(deposit and GW.Money(deposit) or "?")

  -- market check line (SELL-7 / SELL-8): against the 7-day normal, else today's typical price
  local here = packFor(g.itemID)
  local normal = here and (here.avg7 or here.avg30)
  local ref, refName = normal, "normal"
  if not ref then ref, refName = (state.stats and state.stats.mv) or (here and here.mv), "the typical price" end
  local warn, warnColor = "", GREY
  local kind, pct = GW.PriceCheck(unit, ref)
  local refText = ref and string.format("%s (%s)", refName, GW.Money(ref)) or ""
  if kind == "below" then
    warn, warnColor = string.format("%d%% below %s: you may be giving it away.", pct, refText), GW.SIGNAL_ORANGE
  elseif kind == "above" then
    warn, warnColor = string.format("%d%% above %s: unlikely to sell quickly.", pct, refText), GW.SIGNAL_ORANGE
  elseif kind == "at" then
    warn = string.format("Right at %s.", refText)
  elseif kind == "under" then
    warn = string.format("%d%% under %s: a normal undercut.", pct, refText)
  elseif kind == "over" then
    warn = string.format("%d%% over %s: may take longer to sell.", pct, refText)
  end
  local vendor = GW.VendorPrice(g.itemID)
  if vendor > 0 and unit > 0 and GW.Net("A", unit) <= vendor then
    warn, warnColor = string.format("A vendor pays %s each, more than you'd net here. Sell to a vendor instead.", GW.Money(vendor)), GW.SIGNAL_ORANGE
  end
  if rounded then
    warn, warnColor = string.format("Gear posts in whole silver: this posts at %s. %s", GW.Money(unit), warn), GW.SIGNAL_ORANGE
  end
  panel.warn:SetText(warn)
  setColor(panel.warn, warnColor)
  panel.post:SetText(state.pending and state.pending.warning and "Confirm: " .. postLabel(g, qty) or postLabel(g, qty))
  panel.post:SetEnabled(unit > 0 and (not state.pending or state.pending.warning) and true or false)
end

-- Strategy prices from live listings (or the data pack while they load).
local function computePrices()
  local g, s = state.sel, state.stats
  local cheapest, typical, own
  if s then
    local first = s.sorted[s.firstRealIndex]
    cheapest, typical, own = first.price, s.mv, first.own
  else
    local here = packFor(g.itemID)
    if here then cheapest, typical = here.min, here.mv end
  end
  if not cheapest then
    state.prices = nil
    return
  end
  local silver = not g.isCommodity -- gear: whole silver only
  local fast = GW.UndercutPrice(cheapest, own, silver)
  local typ = math.max(fast, (typical or cheapest) - 1)
  local patient = math.max(typ + 1, math.floor((typical or cheapest) * PATIENT_MARKUP + 0.5))
  if silver then
    -- 1c under typical doesn't exist for gear: Typical is the typical price itself (whole silver),
    -- Patient rounds up, so the three buttons are three different prices (2s / 3s / 4s on a 3s wall).
    typ = math.max(fast, GW.SilverFloor(typical or cheapest))
    patient = math.max(typ + 100, math.ceil((typical or cheapest) * PATIENT_MARKUP / 100) * 100)
  end
  state.prices = { fast = fast, typical = typ, patient = patient, cheapest = cheapest, typicalPrice = typical, own = own }
end

local function chooseStrategy(key, reason)
  state.strategy = key
  local p = state.prices and state.prices[key]
  if p then setUnitPrice(p) end
  panel.why:SetText(reason or "")
  recalc()
end

local function applyDefaultStrategy()
  computePrices()
  local P, s = state.prices, state.stats
  if not P then
    state.strategy = nil
    setUnitPrice(0)
    panel.why:SetText(state.searching and "Live listings loading…" or "No listings and no price data: type your own price.")
    recalc()
    return
  end
  local loading = state.searching and not s and "Data pack prices while live listings load. " or ""
  local bait = (s and s.baitUnits > 0) and string.format(" Skipped %d likely bait listing%s at %s.", s.baitUnits, s.baitUnits == 1 and "" or "s", GW.Money(s.baitPrice)) or ""
  -- Judge the price Sell fast would post (for gear that's a whole silver under, e.g. 2s on a 3s wall),
  -- not the cheapest listing, and never default to netting less than a vendor pays.
  local vendor = GW.VendorPrice(state.sel.itemID)
  local fastBelowVendor = vendor > 0 and GW.Net("A", P.fast) <= vendor and GW.Net("A", P.typical) > vendor
  if P.own then
    chooseStrategy("fast", loading .. "Your own listing is already the cheapest; matching it." .. bait)
  elseif fastBelowVendor then
    chooseStrategy("typical", string.format("%sTypical chosen: selling fast would net less than a vendor pays (%s).%s", loading, GW.Money(vendor), bait))
  elseif P.typicalPrice and P.fast < P.typicalPrice * FAST_OK_RATIO then
    chooseStrategy("typical", string.format("%sTypical chosen: selling fast would be %d%% under the typical price.%s", loading,
      math.floor((1 - P.fast / P.typicalPrice) * 100 + 0.5), bait))
  else
    chooseStrategy("fast", string.format("%sSell Fast: %s the cheapest listing (%s).%s", loading, GW.UndercutText(not state.sel.isCommodity), GW.Money(P.cheapest), bait))
  end
end

---------------------------------------------------------------------------
-- column 2: market (SELL-3, 15, 16)
---------------------------------------------------------------------------
local function renderMarket()
  local g, s = state.sel, state.stats
  if not g then return end
  local here, d = packFor(g.itemID)
  local typical = (s and s.mv) or (here and here.mv)
  panel.st1:SetText(typical and GW.Money(typical) or "–")
  panel.st2:SetText(s and GW.Money(s.sorted[s.firstRealIndex].price) or (here and GW.Money(here.min)) or "–")
  panel.st3:SetText(s and tostring(#s.sorted) or "–")
  local others = {}
  if d then
    for _, side in ipairs({ "A", "H", "N" }) do
      if side ~= (GW.house or GW.DetectHouse()).side and d[side] and d[side].mv then
        others[#others + 1] = (side == "N" and "BW " or side == "H" and "Horde " or "Ally ") .. GW.Money(d[side].mv)
      end
    end
  end
  panel.st4:SetText(#others > 0 and table.concat(others, "\n") or "–")

  for i, r in ipairs(panel.listRows) do
    local x = s and s.sorted[i]
    if x then
      r.price:SetText(GW.Money(x.price)); r.qty:SetText(tostring(x.qty))
      if i < s.firstRealIndex then
        r.note:SetText("likely bait, skipped"); setColor(r.note, GW.SIGNAL_ORANGE)
        r.price:SetTextColor(0.55, 0.55, 0.58); r.qty:SetTextColor(0.55, 0.55, 0.58)
      else
        r.price:SetTextColor(1, 1, 1); r.qty:SetTextColor(1, 1, 1)
        if x.own then r.note:SetText("yours"); setColor(r.note, GW.GOLD)
        elseif i == s.firstRealIndex then r.note:SetText("cheapest real seller"); setColor(r.note, GW.SIGNAL_BLUE)
        elseif s.mv and x.price == s.mv then r.note:SetText("typical price"); setColor(r.note, GREY)
        else r.note:SetText("") end
      end
    else
      r.price:SetText(""); r.qty:SetText(""); r.note:SetText("")
    end
  end
end

---------------------------------------------------------------------------
-- search
---------------------------------------------------------------------------
-- Listings for an item key from the last search: { price, qty, own, ownQty }. Shared with Cancel.
function GW.CollectSearchResults(itemID, itemKey)
  local list = {}
  local nc = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  for i = 1, nc do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if r then
      local ownQty = r.numOwnerItems or 0
      list[#list + 1] = { price = r.unitPrice, qty = r.quantity, own = r.containsOwnerItem or ownQty > 0, ownQty = ownQty > 0 and ownQty or nil }
    end
  end
  if #list > 0 then return list, "commodity", nc, 0 end
  local ni = itemKey and (C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0) or 0
  for i = 1, ni do
    local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if r and r.buyoutAmount and (r.quantity or 0) > 0 then
      list[#list + 1] = { price = math.floor(r.buyoutAmount / r.quantity + 0.5), qty = r.quantity, own = r.containsOwnerItem }
    end
  end
  return list, #list > 0 and "item" or nil, nc, ni
end

local function readResults(itemKeyFromEvent, eventName)
  local g = state.sel
  if not g then return end
  local list, source, nc, ni = GW.CollectSearchResults(g.itemID, itemKeyFromEvent or state.key)
  GW.Log("%s for %s: %d listings (%s; commodity n=%s, item n=%s)", eventName or "read", g.name, #list, tostring(source), tostring(nc), tostring(ni))
  if #list == 0 and state.searching then return end
  state.searching = false
  state.stats = GW.MarketStats(list)
  panel.listStatus:SetText(state.stats and "searched just now" or "no other listings")
  renderMarket()
  applyDefaultStrategy()
end

local function sendQuery(kind)
  local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  GW.NoteSearch()
  if kind == "sell" then C_AuctionHouse.SendSellSearchQuery(state.key, sorts, true)
  else C_AuctionHouse.SendSearchQuery(state.key, sorts, true) end
  GW.Log("sent %s search for %s (itemID %d, commodity=%s)", kind, state.sel.name, state.sel.itemID, tostring(state.sel.isCommodity))
end

local search
search = function(g)
  -- The exact item key of the item in your bag (with suffix and item level): searching random-suffix
  -- gear ("of the Falcon") by item id alone got no answer in game.
  local key
  local loc = findLocation(g.itemID) or g.loc
  if loc and C_AuctionHouse.GetItemKeyFromItem then
    local ok, k = pcall(C_AuctionHouse.GetItemKeyFromItem, loc)
    if ok then key = k end
  end
  state.key = key or C_AuctionHouse.MakeItemKey(g.itemID)
  GW.Log("item key for %s: id %s, level %s, suffix %s", g.name, tostring(state.key.itemID), tostring(state.key.itemLevel), tostring(state.key.itemSuffix))
  state.stats = nil
  state.searching = true
  state.token = (state.token or 0) + 1
  local token = state.token
  renderMarket()
  applyDefaultStrategy()
  if not GW.CanSearch() then
    -- throttled: wait for a slot instead of firing anyway (§3.5)
    panel.listStatus:SetText(GW.WaitText())
    GW.Log("sell search waiting: %s", tostring(GW.SearchBlocked()))
    C_Timer.After(2, function()
      if state.token == token and state.sel == g and panel:IsShown() then search(g) end
    end)
    return
  end
  panel.listStatus:SetText("searching…")
  -- The normal search answers within a second on Forever; the sell search never answered in game
  -- (log 2026-11-10: every sell search timed out, the general one then answered at once), so it's
  -- only the fallback.
  sendQuery("general")
  C_Timer.After(4, function()
    if state.token ~= token or not state.searching then return end
    readResults(nil, "timeout-4s")
    if state.searching and GW.CanSearch() then sendQuery("sell") end
  end)
  C_Timer.After(8, function()
    if state.token ~= token or not state.searching then return end
    state.searching = false
    readResults(nil, "timeout-8s")
    if not state.stats then
      panel.listStatus:SetText("no answer from the auction house")
      applyDefaultStrategy()
    end
  end)
end

-- Status bar (AH-2) with the data banner (AH-3) when the pack is missing or old.
local function renderStatus()
  local h = GW.house or GW.DetectHouse()
  local pack = GW.Pack()
  local days = GW.PackAgeDays()
  local packText
  if not pack then
    packText = "|cfff59e4bNo data pack for " .. h.region .. " " .. h.ruleset .. ": prices come from live listings only|r"
  elseif days and days > GW.STALE_DAYS then
    packText = string.format("|cfff59e4bData pack is %d days old: update Goldwright Data|r", math.floor(days))
  else
    packText = "Data pack: snapshot " .. GW.Age(pack.snapshotAt)
  end
  local scanText = GW.LastScanText and GW.LastScanText()
  panel.status:SetText(string.format("%s · %s · %s     %s     %s     Searches this minute: %d / %d",
    h.region, h.ruleset, GW.HOUSE_NAMES[h.side], packText, scanText and ("Last scan " .. scanText) or "No full scan yet",
    GW.SearchesThisMinute(), GW.SEARCH_LIMIT))
end

local function setDuration(idx)
  state.duration = idx
  for _, b in ipairs(panel.durButtons) do
    if b.idx == idx then b:LockHighlight() else b:UnlockHighlight() end
  end
end

local function clearSelection(message)
  state.sel, state.stats, state.strategy, state.token = nil, nil, nil, (state.token or 0) + 1
  panel.col2:Hide(); panel.col3:Hide()
  panel.empty:SetText(message or "Choose an item on the left to see its market and price it.")
  panel.empty:Show()
  renderBags()
end

local function selectItem(g)
  state.sel = g
  state.stats = nil
  state.strategy = nil
  panel.iconButton.tex:SetTexture(g.icon or 134400)
  panel.iconButton:Show()
  panel.itemName:SetText(g.name)
  setColor(panel.itemName, qualityColor(g.quality))
  panel.itemInfo:SetText(string.format("You have %d · %s", g.count, g.isCommodity and "commodity: one listing for any quantity" or "item: one auction per click"))
  panel.qty:SetText(tostring(g.isCommodity and g.count or 1))
  if g.isCommodity then panel.qty:Enable() else panel.qty:Disable() end
  panel.allButton:SetShown(g.isCommodity and true or false)
  local remembered = GoldwrightDB.durations and GoldwrightDB.durations[g.itemID]
  setDuration(remembered or GW.Opt("duration"))
  panel.col2:Show(); panel.col3:Show(); panel.empty:Hide()
  GW.SellCharts.Render(g.itemID)
  renderBags()
  search(g)
end

---------------------------------------------------------------------------
-- posting and the post queue (SELL-12, 13, 14)
---------------------------------------------------------------------------
-- Stop waiting; the post stays "recent" for a while so a late success still moves the queue on
-- (an unrelated error message can arrive while a post is on its way).
local function finishPending()
  if state.pending then state.recent = state.pending end
  state.pending = nil
  if state.sel then recalc() end
end

local function postInFlight()
  local p = state.pending or state.recent
  if p and GetTime() - p.at < POST_TIMEOUT + 5 then return p end
  return nil
end

-- After a post: once the bags show it, select the next item (or the same gear with copies left).
local function tryAdvance()
  local a = state.advance
  if not a then return end
  local left = itemCount(a.itemID)
  if left > a.countBefore - a.qty and GetTime() - a.at < 3 then return end -- bags not updated yet
  state.advance = nil
  scanBags()
  local visible = {}
  for _, g in ipairs(state.bags) do if not g.hidden then visible[#visible + 1] = g end end
  local nextItem = GW.NextInQueue(a.order, visible, a.itemID, a.keepSame)
  if nextItem then
    state.offset = 0
    for i, g in ipairs(state.bags) do
      if g == nextItem and i > ROWS then state.offset = i - ROWS end
    end
    selectItem(nextItem)
  else
    clearSelection("That was the last item in the list. Choose another item, or close the auction house.")
  end
end

local function onPosted()
  local p = postInFlight()
  if not p or p.done then return end
  p.done = true
  state.recent = nil
  GoldwrightDB.durations = GoldwrightDB.durations or {}
  GoldwrightDB.durations[p.itemID] = p.duration
  toast(string.format("Posted %d × %s at %s each.", p.qty, p.name, GW.Money(p.unit)), GW.SIGNAL_BLUE)
  GW.Log("posted %d x %s at %d (%s)", p.qty, p.name, p.unit, p.commodity and "commodity" or "item")
  state.advance = { itemID = p.itemID, qty = p.qty, countBefore = p.countBefore, order = p.order, keepSame = p.keepSame, at = GetTime() }
  finishPending()
  C_Timer.After(0.3, tryAdvance)
  C_Timer.After(1.0, tryAdvance)
  C_Timer.After(3.1, tryAdvance)
end

local function postSelected()
  if not (panel and panel:IsShown() and GW.activeTab == "sell") then return end
  local g = state.sel
  if not g then return toast("Choose an item first.", GW.SIGNAL_ORANGE) end
  local p = state.pending
  if p and not p.warning then return toast("Waiting for the auction house…", GREY) end
  if InCombatLockdown and InCombatLockdown() then return toast("Not in combat.", GW.SIGNAL_ORANGE) end

  -- The auction house asked us to confirm this post (AUCTION_HOUSE_POST_WARNING): this click confirms.
  if p and p.warning then
    p.warning = nil
    local loc = findLocation(p.itemID) or p.loc
    if p.commodity and C_AuctionHouse.ConfirmPostCommodity then
      C_AuctionHouse.ConfirmPostCommodity(loc, p.duration, p.qty, p.unit)
    elseif C_AuctionHouse.ConfirmPostItem then
      C_AuctionHouse.ConfirmPostItem(loc, p.duration, 1, nil, p.unit)
    end
    p.at = GetTime()
    toast("Confirmed. Waiting for the auction house…", GREY)
    recalc()
    return
  end

  local unit, qty = postUnit(), quantity()
  if unit <= 0 then return toast("Set a price first.", GW.SIGNAL_ORANGE) end
  local loc = findLocation(g.itemID)
  if not loc then return toast("Can't find that item in your bags any more.", GW.SIGNAL_ORANGE) end
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    return toast("The auction house is busy: click again in a moment.", GW.SIGNAL_ORANGE)
  end

  local order = {}
  for i, b in ipairs(state.bags) do order[i] = { itemID = b.itemID } end
  state.pending = {
    itemID = g.itemID, name = g.name, qty = qty, unit = unit, duration = state.duration, loc = loc,
    commodity = g.isCommodity, countBefore = itemCount(g.itemID), order = order,
    keepSame = not g.isCommodity and g.count > 1, at = GetTime(),
  }
  local token = state.pending
  state.token, state.searching = (state.token or 0) + 1, false -- the item's search timers stop here
  if g.isCommodity then
    C_AuctionHouse.PostCommodity(loc, state.duration, qty, unit)
  else
    C_AuctionHouse.PostItem(loc, state.duration, 1, nil, unit)
  end
  GW.Log("post sent: %d x %s at %d, duration %d", qty, g.name, unit, state.duration)
  toast("Posting…", GREY)
  recalc()
  C_Timer.After(POST_TIMEOUT, function()
    if state.pending == token and not token.warning then
      toast("No answer from the auction house. Check your auctions before posting again.", GW.SIGNAL_ORANGE)
      finishPending()
    end
  end)
end
GW.PostSelected = postSelected

---------------------------------------------------------------------------
-- tabs
---------------------------------------------------------------------------
local function showTab(key)
  GW.activeTab = key
  for _, b in ipairs(panel.tabButtons) do
    if b.key == key then b:LockHighlight() else b:UnlockHighlight() end
  end
  panel.sellView:SetShown(key == "sell")
  if GW.CancelView then
    if key == "cancel" then GW.CancelView.Show(panel.inset) else GW.CancelView.Hide() end
  end
  if GW.ScanView then
    if key == "scan" then GW.ScanView.Show(panel.inset) else GW.ScanView.Hide() end
  end
  if GW.ShopView then
    if key == "shopping" then GW.ShopView.Show(panel.inset) else GW.ShopView.Hide() end
  end
  if key == "sell" then
    scanBags()
    renderBags()
    if state.sel then recalc() end
  end
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------
local function header(parent, text, x, y)
  local h = fs(parent, "GameFontNormal", "LEFT")
  h:SetPoint("TOPLEFT", x, y)
  h:SetText(text)
  return h
end

local function createPanel()
  panel = CreateFrame("Frame", "GoldwrightSellFrame", UIParent, "ButtonFrameTemplate")
  GW.panel = panel
  panel:SetSize(W, H)
  panel:SetFrameStrata("HIGH")
  if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(panel) end
  if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(panel) end
  if panel.SetTitle then panel:SetTitle("Goldwright") elseif panel.TitleText then panel.TitleText:SetText("Goldwright") end
  panel:SetMovable(true)
  panel:EnableMouse(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", panel.StartMoving)
  panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
  GW.CloseOnEscape(panel)

  panel.tabButtons = {}
  local prev
  for i, t in ipairs(TABS) do
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(t.key == "cancel" and 110 or 90, 22)
    b:SetText(t.label)
    b.key = t.key
    if i == 1 then b:SetPoint("TOPLEFT", 14, -30) else b:SetPoint("LEFT", prev, "RIGHT", 4, 0) end
    if t.soon then
      b:Disable()
      if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
      b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(t.label .. ": coming in a later build")
        GameTooltip:Show()
      end)
      b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    else
      b:SetScript("OnClick", function() showTab(t.key) end)
    end
    panel.tabButtons[i] = b
    prev = b
  end
  local gear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  gear:SetSize(90, 22); gear:SetPoint("TOPRIGHT", -14, -30); gear:SetText("Settings")
  gear:SetScript("OnClick", function() if GW.OpenSettings then GW.OpenSettings() end end)

  local inset = panel.Inset or panel
  if panel.Inset then
    panel.Inset:ClearAllPoints()
    panel.Inset:SetPoint("TOPLEFT", 8, -58)
    panel.Inset:SetPoint("BOTTOMRIGHT", -8, 30)
  end
  panel.inset = inset
  local view = CreateFrame("Frame", nil, inset)
  view:SetAllPoints()
  panel.sellView = view

  -- Column 1: choose ----------------------------------------------------------
  header(view, "1 · Choose", 12, -8)
  panel.rows = {}
  local list = CreateFrame("Frame", nil, view)
  list:SetPoint("TOPLEFT", 6, -28)
  list:SetSize(236, ROWS * ROW_H)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    state.offset = math.max(0, math.min(state.offset - delta, math.max(0, #state.bags - ROWS)))
    renderBags()
  end)
  for i = 1, ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetSize(236, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(0.24, 0.37, 0.66, 0.35)
    row.sel:Hide()
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = fs(row, "GameFontHighlight", "LEFT"); row.name:SetPoint("TOPLEFT", 34, -3); row.name:SetWidth(196); row.name:SetWordWrap(false)
    row.sub = fs(row, "GameFontDisableSmall", "LEFT"); row.sub:SetPoint("BOTTOMLEFT", 34, 3)
    row.note = fs(row, "GameFontHighlightSmall", "RIGHT"); row.note:SetPoint("BOTTOMRIGHT", -4, 3)
    row:SetScript("OnClick", function(self, button)
      local g = self.g
      if not g then return end
      if button == "RightButton" then -- SELL-2: "Don't show" (right-click again to bring it back)
        GoldwrightDB.ignore = GoldwrightDB.ignore or {}
        GoldwrightDB.ignore[g.itemID] = not g.hidden or nil
        if state.sel and state.sel.itemID == g.itemID and not g.hidden then clearSelection() end
        scanBags(); renderBags()
        return
      end
      if not g.hidden then selectItem(g) end
    end)
    row:SetScript("OnEnter", function(self)
      if not self.g then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetBagItem(self.g.bag, self.g.slot)
      GameTooltip:AddLine(self.g.hidden and "Right-click: show in this list again" or "Right-click: hide from this list", 0.6, 0.6, 0.65)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    panel.rows[i] = row
  end
  panel.bagFooter = fs(view, "GameFontDisableSmall", "LEFT")
  panel.bagFooter:SetPoint("BOTTOMLEFT", 10, 8)
  panel.hiddenLink = CreateFrame("Button", nil, view)
  panel.hiddenLink:SetSize(110, 16)
  panel.hiddenLink:SetPoint("BOTTOMLEFT", 10, 22)
  panel.hiddenLink:SetNormalFontObject("GameFontHighlightSmall")
  panel.hiddenLink:SetText(" ")
  panel.hiddenLink:GetFontString():SetJustifyH("LEFT")
  panel.hiddenLink:GetFontString():SetPoint("LEFT")
  panel.hiddenLink:SetScript("OnClick", function()
    state.showHidden = not state.showHidden
    scanBags(); renderBags()
  end)
  divider(view, 248)

  panel.empty = fs(view, "GameFontDisable", "CENTER")
  panel.empty:SetPoint("CENTER", view, "CENTER", 124, 0)
  panel.empty:SetWidth(600)
  panel.empty:SetText("Choose an item on the left to see its market and price it.")

  -- Column 2: market ----------------------------------------------------------
  local col2 = CreateFrame("Frame", nil, view)
  col2:SetPoint("TOPLEFT", 258, -8)
  col2:SetSize(380, 440)
  panel.col2 = col2
  header(col2, "2 · Market", 0, 0)

  panel.iconButton = CreateFrame("Button", nil, col2)
  panel.iconButton:SetSize(34, 34)
  panel.iconButton:SetPoint("TOPLEFT", 0, -22)
  panel.iconButton.tex = panel.iconButton:CreateTexture(nil, "ARTWORK")
  panel.iconButton.tex:SetAllPoints()
  panel.iconButton.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  panel.iconButton:SetScript("OnEnter", function(self)
    if not state.sel then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetBagItem(state.sel.bag, state.sel.slot)
    GameTooltip:Show()
  end)
  panel.iconButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.itemName = fs(col2, "GameFontNormalLarge", "LEFT"); panel.itemName:SetPoint("TOPLEFT", panel.iconButton, "TOPRIGHT", 10, -1)
  panel.itemInfo = fs(col2, "GameFontHighlightSmall", "LEFT"); panel.itemInfo:SetPoint("TOPLEFT", panel.itemName, "BOTTOMLEFT", 0, -3)
  setColor(panel.itemInfo, GREY)

  local stats = { { "Typical price", "st1" }, { "Cheapest real", "st2" }, { "Listings", "st3" }, { "Other houses", "st4" } }
  for i, s in ipairs(stats) do
    local x = (i - 1) * 95
    local lab = fs(col2, "GameFontDisableSmall", "LEFT"); lab:SetPoint("TOPLEFT", x, -66); lab:SetText(s[1])
    local val = fs(col2, i == 4 and "GameFontHighlightSmall" or "GameFontHighlightLarge", "LEFT"); val:SetPoint("TOPLEFT", x, -80)
    panel[s[2]] = val
  end

  local lh = header(col2, "Cheapest listings", 0, -120)
  panel.listStatus = fs(col2, "GameFontDisableSmall", "LEFT"); panel.listStatus:SetPoint("LEFT", lh, "RIGHT", 10, 0)
  local c1 = fs(col2, "GameFontDisableSmall", "LEFT"); c1:SetPoint("TOPLEFT", 0, -138); c1:SetText("Price each")
  local c2 = fs(col2, "GameFontDisableSmall", "LEFT"); c2:SetPoint("TOPLEFT", 110, -138); c2:SetText("Quantity")
  local c3 = fs(col2, "GameFontDisableSmall", "LEFT"); c3:SetPoint("TOPLEFT", 190, -138); c3:SetText("Note")
  panel.listRows = {}
  for i = 1, 7 do
    local y = -154 - (i - 1) * 18
    local r = {}
    r.price = fs(col2, "GameFontHighlight", "LEFT"); r.price:SetPoint("TOPLEFT", 0, y)
    r.qty = fs(col2, "GameFontHighlight", "LEFT"); r.qty:SetPoint("TOPLEFT", 110, y)
    r.note = fs(col2, "GameFontHighlightSmall", "LEFT"); r.note:SetPoint("TOPLEFT", 190, y)
    panel.listRows[i] = r
  end

  -- Price history (SELL-15) and best time to post (SELL-16), side by side: SellCharts.lua
  GW.SellCharts.Create(col2)
  panel.charts = GW.SellCharts
  divider(view, 648)

  -- Column 3: your listing ----------------------------------------------------
  local col3 = CreateFrame("Frame", nil, view)
  col3:SetPoint("TOPLEFT", 658, -8)
  col3:SetSize(318, 440)
  panel.col3 = col3
  header(col3, "3 · Your listing", 0, 0)

  panel.stratButtons = {}
  for i, st in ipairs(STRATEGIES) do
    local b = CreateFrame("Button", nil, col3, "UIPanelButtonTemplate")
    b:SetSize(100, 40)
    b:SetPoint("TOPLEFT", (i - 1) * 106, -22)
    b.key, b.label = st.key, st.label
    b:SetText(st.label)
    b.receive = fs(col3, "GameFontHighlightSmall", "CENTER")
    b.receive:SetPoint("TOP", b, "BOTTOM", 0, -2)
    b:SetScript("OnClick", function()
      local reasons = {
        fast = "Sell Fast: " .. GW.UndercutText(state.sel and not state.sel.isCommodity) .. " the cheapest listing.",
        typical = (state.sel and not state.sel.isCommodity) and "Typical: at the typical price (gear posts in whole silver)." or "Typical: 1c under the typical price.",
        patient = "Patient: about 10% above the typical price; best posted when supply is low.",
      }
      chooseStrategy(st.key, reasons[st.key])
    end)
    panel.stratButtons[i] = b
  end
  panel.why = fs(col3, "GameFontDisableSmall", "LEFT"); panel.why:SetPoint("TOPLEFT", 0, -82); panel.why:SetWidth(316)

  local pl = fs(col3, "GameFontNormalSmall", "LEFT"); pl:SetPoint("TOPLEFT", 0, -116); pl:SetText("Price per item (or type your own)")
  if MoneyInputFrame_SetCopper and MoneyInputFrame_GetCopper then
    panel.money = CreateFrame("Frame", "GoldwrightSellPrice", col3, "MoneyInputFrameTemplate")
    panel.money:SetPoint("TOPLEFT", 4, -132)
    if MoneyInputFrame_SetOnValueChangedFunc then
      MoneyInputFrame_SetOnValueChangedFunc(panel.money, function()
        -- The money boxes report changes a moment after we set them, so only a price that differs
        -- from the chosen strategy's is the player's own.
        local chosen = state.strategy and state.prices and state.prices[state.strategy]
        if not state.settingPrice and getUnitPrice() ~= chosen then
          state.strategy = nil
          panel.why:SetText("Your own price.")
        end
        recalc()
      end)
    end
  else
    panel.copperBox = CreateFrame("EditBox", nil, col3, "InputBoxTemplate")
    panel.copperBox:SetSize(120, 22); panel.copperBox:SetPoint("TOPLEFT", 6, -132); panel.copperBox:SetAutoFocus(false)
    panel.copperBox:SetScript("OnTextChanged", recalc)
  end

  local ql = fs(col3, "GameFontNormalSmall", "LEFT"); ql:SetPoint("TOPLEFT", 0, -162); ql:SetText("Quantity")
  panel.qty = CreateFrame("EditBox", nil, col3, "InputBoxTemplate")
  panel.qty:SetSize(50, 22); panel.qty:SetPoint("TOPLEFT", 6, -178)
  panel.qty:SetAutoFocus(false); panel.qty:SetNumeric(true); panel.qty:SetMaxLetters(5)
  panel.qty:SetScript("OnTextChanged", recalc)
  panel.qty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  panel.allButton = CreateFrame("Button", nil, col3, "UIPanelButtonTemplate")
  panel.allButton:SetSize(44, 22); panel.allButton:SetPoint("LEFT", panel.qty, "RIGHT", 6, 0); panel.allButton:SetText("All")
  panel.allButton:SetScript("OnClick", function() if state.sel then panel.qty:SetText(tostring(state.sel.count)) end end)

  local dl = fs(col3, "GameFontNormalSmall", "LEFT"); dl:SetPoint("TOPLEFT", 150, -162); dl:SetText("Duration")
  panel.durButtons = {}
  for i, d in ipairs(DURATIONS) do
    local b = CreateFrame("Button", nil, col3, "UIPanelButtonTemplate")
    b:SetSize(50, 22); b:SetText(d.label)
    b.idx = d.idx
    b:SetPoint("TOPLEFT", 150 + (i - 1) * 54, -178)
    b:SetScript("OnClick", function()
      setDuration(d.idx)
      recalc()
    end)
    panel.durButtons[i] = b
  end
  setDuration(GW.Opt("duration"))

  panel.warn = fs(col3, "GameFontHighlightSmall", "LEFT"); panel.warn:SetPoint("TOPLEFT", 0, -212); panel.warn:SetWidth(316)

  local y = -252
  for i = 1, 4 do
    local l = fs(col3, i == 3 and "GameFontHighlight" or "GameFontHighlightSmall", "LEFT"); l:SetPoint("TOPLEFT", 0, y)
    local r = fs(col3, i == 3 and "GameFontNormal" or "GameFontHighlightSmall", "RIGHT"); r:SetPoint("TOPRIGHT", -4, y)
    if i ~= 3 then setColor(l, GREY) end
    panel["r" .. i .. "L"], panel["r" .. i .. "R"] = l, r
    y = y - (i == 2 and 24 or 18)
  end
  local line = col3:CreateTexture(nil, "ARTWORK"); line:SetColorTexture(1, 1, 1, 0.1); line:SetPoint("TOPLEFT", 0, -290); line:SetSize(314, 1)

  panel.toast = fs(col3, "GameFontHighlightSmall", "LEFT"); panel.toast:SetPoint("BOTTOMLEFT", 0, 58); panel.toast:SetWidth(314)
  panel.post = CreateFrame("Button", nil, col3, "UIPanelButtonTemplate")
  panel.post:SetSize(314, 30); panel.post:SetPoint("BOTTOMLEFT", 0, 22); panel.post:SetText("Post")
  panel.post:SetScript("OnClick", postSelected)
  local postNote = fs(col3, "GameFontDisableSmall", "RIGHT"); postNote:SetPoint("TOPRIGHT", panel.post, "BOTTOMRIGHT", 0, -4)
  postNote:SetText("One listing per click · then the next item is ready")

  col2:Hide(); col3:Hide()

  panel.status = fs(panel, "GameFontDisableSmall", "LEFT")
  panel.status:SetPoint("BOTTOMLEFT", 14, 10)

  panel:SetScript("OnShow", function()
    state.rank = nil -- fresh value order for each visit to the auction house
    renderStatus()
    local t = GW.activeTab
    showTab((t == "cancel" or t == "scan" or t == "shopping") and t or "sell")
  end)
  panel:SetScript("OnHide", function()
    if GW.CancelView then GW.CancelView.Hide() end
    if GW.ScanView then GW.ScanView.Hide() end
    if GW.ShopView then GW.ShopView.Hide() end
  end)
  C_Timer.NewTicker(5, function() if panel:IsShown() then renderStatus() end end)
  GW.OnOptionsChanged(function()
    if not panel:IsShown() then return end
    renderStatus()
    if GW.activeTab == "sell" then
      scanBags(); renderBags()
      if state.sel then renderMarket(); applyDefaultStrategy(); GW.SellCharts.Render(state.sel.itemID) end
    end
  end)
  -- New frames start shown, so the first Show() wouldn't fire OnShow; start hidden instead.
  panel:Hide()
end

local function anchorToAuctionHouse()
  panel:ClearAllPoints()
  if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
    panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 6, 0)
  else
    panel:SetPoint("CENTER")
  end
end

local function ahOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end
GW.AuctionHouseOpen = ahOpen

function GW.ToggleSellPanel()
  if not ahOpen() then
    GW.Print("Open the auction house first.")
    return
  end
  if not panel then createPanel() end
  if panel:IsShown() then panel:Hide() else anchorToAuctionHouse(); panel:Show() end
end

-- Open the panel on a tab ("sell" / "cancel"); only at the auction house.
function GW.OpenTab(key)
  if not ahOpen() then
    GW.Print("Open the auction house first.")
    return
  end
  if not panel then createPanel() end
  GW.activeTab = key
  if panel:IsShown() then showTab(key) else anchorToAuctionHouse(); panel:Show() end
end

-- CXL-7: jump to Sell with this item selected, if it is in your bags.
function GW.SellItem(itemID)
  if not panel then return end
  showTab("sell")
  for _, g in ipairs(state.bags) do
    if g.itemID == itemID and not g.hidden then
      selectItem(g)
      return true
    end
  end
  clearSelection("That item isn't in your bags yet: cancelled auctions come back by mail. Take it from the mailbox, then post it here.")
  return false
end

---------------------------------------------------------------------------
-- events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "BAG_UPDATE_DELAYED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED", "COMMODITY_SEARCH_RESULTS_RECEIVED",
  "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED", "AUCTION_HOUSE_SHOW_ERROR",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_HOUSE_POST_WARNING",
  "UI_ERROR_MESSAGE", "PLAYER_REGEN_DISABLED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, arg1, arg2)
  if event == "AUCTION_HOUSE_SHOW" then
    if GW.Opt("autoShow") then
      C_Timer.After(0.2, function()
        if not panel then createPanel() end
        anchorToAuctionHouse()
        panel:Show()
      end)
    end
    return
  elseif event == "AUCTION_HOUSE_CLOSED" then
    state.pending, state.advance, state.recent = nil, nil, nil
    if panel then panel:Hide() end
    return
  end
  if GW.CancelView and GW.activeTab == "cancel" and panel and panel:IsShown() then
    GW.CancelView.OnEvent(event, arg1, arg2)
    return
  end
  if not (panel and panel:IsShown()) then return end
  if GW.activeTab ~= "sell" and event:find("SEARCH_RESULTS") then return end -- another tab's search

  if event == "BAG_UPDATE_DELAYED" then
    local p = postInFlight()
    if p and not p.done and itemCount(p.itemID) <= p.countBefore - p.qty then onPosted() end -- the post went through
    if state.advance then tryAdvance() return end
    scanBags()
    renderBags()
  elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
    onPosted()
  elseif event == "AUCTION_HOUSE_POST_WARNING" then
    if state.pending then
      state.pending.warning = true
      toast("The auction house asks you to confirm this price. Click Post again to confirm.", GW.SIGNAL_ORANGE)
      recalc()
    end
  elseif event == "UI_ERROR_MESSAGE" then
    local p = state.pending
    if p and not p.warning and GetTime() - p.at < POST_TIMEOUT and type(arg2) == "string" then
      toast(arg2, GW.SIGNAL_ORANGE)
      GW.Log("post error: %s", arg2)
      finishPending()
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    if state.pending then finishPending() end
  elseif event:find("SEARCH_RESULTS") then
    if not state.sel then return end
    local argItem = type(arg1) == "table" and arg1.itemID or arg1
    GW.Log("event %s (item %s)", event, tostring(argItem))
    if argItem == nil or argItem == state.sel.itemID then
      readResults(type(arg1) == "table" and arg1 or nil, event)
    end
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" or event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    GW.Log("event %s (%s)", event, tostring(arg1))
    if state.pending and event == "AUCTION_HOUSE_SHOW_ERROR" then
      toast("The auction house refused that post.", GW.SIGNAL_ORANGE)
      finishPending()
    end
  end
end)
