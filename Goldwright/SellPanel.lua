--- The Goldwright panel beside the auction house: the window, its tab bar (Sell, My Auctions, Shopping,
--- Scan) and the Sell tab (SELL-1..18), layout B: 1 Choose (bags) -> 2 Market (stats, listings, charts)
--- -> 3 Your listing (strategies, price, receipt, Post). One listing per click (or key press), then the
--- next item is selected and searched (post queue, SELL-13). Rules without UI live in Selling.lua.
local _, GW = ...
local L = GW.L

local W, H = 1000, 560
local ROWS, ROW_H = 13, 30
local DURATIONS = { { idx = 1, label = L["2h"] }, { idx = 2, label = L["8h"] }, { idx = 3, label = L["24h"] } }
local STRATEGIES = {
  { key = "fast", label = L["Sell Fast"] },
  { key = "typical", label = L["Typical"] },
  { key = "patient", label = L["Patient"] },
}
local TABS = {
  { key = "sell", label = L["Sell"] },
  { key = "cancel", label = L["My Auctions"] },
  { key = "shopping", label = L["Shopping"] },
  { key = "scan", label = L["Scan"] },
}
local PATIENT_MARKUP = 1.10 -- Patient = ~10% above typical (rule to tune)
local FAST_OK_RATIO = 0.85 -- default to "Sell fast" only if it isn't >15% under typical
local POST_TIMEOUT = 10 -- seconds to wait for the auction house to confirm a post

--- The market check line under the price (SELL-7 / SELL-8), by price check kind: against the 7-day
--- normal, else the typical price. "at" takes the reference price; the rest the percent, then it.
local PRICE_CHECK = {
  normal = {
    below = L["%d%% below normal (%s): you may be giving it away."],
    above = L["%d%% above normal (%s): unlikely to sell quickly."],
    at = L["Right at normal (%s)."],
    under = L["%d%% under normal (%s): a normal undercut."],
    over = L["%d%% over normal (%s): may take longer to sell."],
  },
  typical = {
    below = L["%d%% below the typical price (%s): you may be giving it away."],
    above = L["%d%% above the typical price (%s): unlikely to sell quickly."],
    at = L["Right at the typical price (%s)."],
    under = L["%d%% under the typical price (%s): a normal undercut."],
    over = L["%d%% over the typical price (%s): may take longer to sell."],
  },
}

--- A bag item (all stacks of one item id) in the Choose column.
---@class SellBagItem
---@field itemID number
---@field count number how many you have in your bags
---@field loc table ItemLocation of the first stack found
---@field bag number bag of the first stack (for the tooltip)
---@field slot number slot of the first stack
---@field quality number?
---@field icon number? texture file id
---@field hidden boolean? hidden with right-click (GoldwrightDB.ignore)
---@field name string
---@field isCommodity boolean commodities post any quantity in one listing; other items one per click
---@field unit number? price Sell Fast would post at, from the data pack
---@field total number unit * count, for sorting and the footer (0 without price data)

--- Strategy prices for the selected item.
---@class SellPrices
---@field fast number Sell Fast price
---@field typical number Typical price
---@field patient number Patient price
---@field cheapest number cheapest real listing
---@field typicalPrice number? the market's typical price
---@field own boolean? the cheapest real listing is yours

--- A post sent to the auction house and not yet confirmed.
---@class SellPendingPost
---@field itemID number
---@field name string
---@field qty number
---@field unit number price per unit
---@field duration number duration index (1 = 2h, 2 = 8h, 3 = 24h)
---@field loc table ItemLocation the post was sent from
---@field commodity boolean
---@field countBefore number item count in the bags before the post
---@field order { itemID: number }[] bag list order when posting, for the post queue
---@field keepSame boolean gear with copies left: keep the same item selected afterwards
---@field at number GetTime() when sent (or confirmed)
---@field warning boolean? the auction house asked to confirm the price (AUCTION_HOUSE_POST_WARNING)
---@field warnedAt number? GetTime() of that warning; Confirm works GW.CONFIRM_DELAY after it
---@field done boolean? the post went through and was handled

--- After a post: what to select next once the bags show the change.
---@class SellAdvance
---@field itemID number
---@field qty number
---@field countBefore number
---@field order { itemID: number }[]
---@field keepSame boolean
---@field at number GetTime() of the post's success

local panel -- the frame, created on first use

--- State of the Sell tab.
---@class SellState
---@field bags SellBagItem[] the Choose column, in display order
---@field offset number scroll offset into bags
---@field sel SellBagItem? the selected item
---@field stats table? market stats from the live search (GW.MarketStats)
---@field duration number duration index (1 = 2h, 2 = 8h, 3 = 24h)
---@field strategy string? "fast", "typical" or "patient"; nil for a price you typed
---@field typed boolean? the player typed the price: later results never replace it
---@field prices SellPrices?
---@field showHidden boolean? show hidden items in the list
---@field hiddenCount number? number of hidden items in the bags
---@field rank table<number, number>? itemID -> list position, fixed while the panel stays open
---@field settingPrice boolean? true while the code sets the price box (not the player)
---@field key table? item key of the selected item, used for its searches
---@field searching boolean? the live search has not answered yet
---@field token number? bumped to cancel pending search timers
---@field pending SellPendingPost? the post waiting for an answer
---@field recent SellPendingPost? the last post, kept a while so a late success still moves the queue on
---@field advance SellAdvance? set after a successful post until the next item is selected
local state = { bags = {}, offset = 0, sel = nil, stats = nil, duration = 3, strategy = nil, prices = nil }
GW.activeTab = "sell"

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local UI = GW.UI
local fs, setColor, qualityColor = UI.FontString, UI.SetColor, UI.QualityColor
local GREY = UI.GREY

--- The house you are selling at: the open auction house (Blackwater in neutral towns, else your
--- faction's; GW.AuctionSide in Scan.lua). Reference prices, the cut and hints all follow it.
---@return string side "A", "H" or "N"
local function sellSide() return GW.AuctionSide and GW.AuctionSide() or GW.House().side end

--- The auction house cut where you sell, as a fraction.
---@return number cut e.g. 0.05, or 0.15 at Blackwater
local function sellCut() return GW.CUT[sellSide()] or 0.05 end

--- Data pack numbers for the house you sell at, only when the item is listed there now
--- (history-only entries have no mv).
---@param itemID number
---@return table|nil here that house's entry, or nil when the item isn't listed there now
---@return table|nil data the item's entry for all houses (GW.ItemData)
local function packFor(itemID)
  local d = GW.ItemData(itemID)
  local here = d and d[sellSide()]
  return here and here.mv and here or nil, d
end

--- The other house you can reach when it really pays more (GW.BetterHouse): Blackwater from your
--- faction's house, your faction's house from Blackwater.
---@param here table|nil the selling house's entry
---@param d table|nil the item's entry for all houses
---@return string|nil side the better house
---@return number|nil gain % more after both cuts
local function betterElsewhere(here, d)
  if not (here and d) then return nil end
  local at, own = sellSide(), GW.House().side
  local other = at == "N" and own or "N"
  if other == at then return nil end
  local gain = GW.BetterHouse(d[other], other, here.mv, at)
  if gain then return other, gain end
  return nil
end

--- How many of an item are in your bags (not the bank).
---@param itemID number
---@return number
local function itemCount(itemID)
  if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(itemID, false) or 0 end
  return GetItemCount and GetItemCount(itemID) or 0
end

--- Shows a short message above the Post button.
---@param text string
---@param color number[]? {r, g, b}
local function toast(text, color) UI.Toast(panel, text, color) end

--- Whether the player hid this item from the list (right-click).
---@param itemID number
---@return boolean|nil
local function ignored(itemID) return GoldwrightDB.ignore and GoldwrightDB.ignore[itemID] end

---------------------------------------------------------------------------
-- column 1: bags (SELL-1, SELL-2)
---------------------------------------------------------------------------
--- Calls fn(info, loc, bag, slot) for each bag slot whose item passes want(info) and can be
--- auctioned. Stops at the first non-nil value fn returns, and returns it.
---@param want fun(info: table): any filter on the container item info
---@param fn fun(info: table, loc: table, bag: number, slot: number): any
---@return any result the first non-nil value fn returned
local function eachSellable(want, fn)
  local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
  for bag = 0, lastBag do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and want(info) then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if loc and loc:IsValid() and C_AuctionHouse.IsSellItemValid(loc, false) then
          local result = fn(info, loc, bag, slot)
          if result ~= nil then return result end
        end
      end
    end
  end
  return nil
end

--- Rebuilds state.bags from your bags: unbound items that can be auctioned, one entry per item id,
--- priced from the data pack (SELL-1). Hidden items are left out unless state.showHidden (SELL-2).
local function scanBags()
  local groups, list, hidden = {}, {}, 0
  eachSellable(function(info) return info.itemID and not info.isBound end, function(info, loc, bag, slot)
    local g = groups[info.itemID]
    if not g then
      local status = C_AuctionHouse.GetItemCommodityStatus(loc)
      g = {
        itemID = info.itemID,
        count = 0,
        loc = loc,
        quality = info.quality,
        bag = bag,
        slot = slot,
        icon = info.iconFileID,
        hidden = ignored(info.itemID) and true or nil,
        name = (info.hyperlink and info.hyperlink:match("%[(.-)%]"))
          or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(info.itemID))
          or string.format(L["item %d"], info.itemID),
        isCommodity = Enum and Enum.ItemCommodityStatus and status == Enum.ItemCommodityStatus.Commodity,
      }
      groups[info.itemID] = g
      if g.hidden then hidden = hidden + 1 end
      if not g.hidden or state.showHidden then list[#list + 1] = g end
    end
    g.count = g.count + (info.stackCount or 1)
  end)
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
  for _, r in pairs(rank) do
    if r > maxRank then maxRank = r end
  end
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

--- The first bag slot holding this item that can be posted now (bags shift after every post).
---@param itemID number
---@return table|nil loc ItemLocation
local function findLocation(itemID)
  return eachSellable(
    function(info) return info.itemID == itemID and not info.isLocked end,
    function(_, loc) return loc end
  )
end

--- Redraws the Choose column: rows with value and notes, the footer and the hidden-items link.
local function renderBags()
  local total = 0
  for _, g in ipairs(state.bags) do
    if not g.hidden then total = total + g.total end
  end
  for i, row in ipairs(panel.rows) do
    local g = state.bags[i + state.offset]
    row.g = g
    if g then
      row:Show()
      row.icon:SetTexture(g.icon or 134400)
      row.icon:SetDesaturated(g.hidden and true or false)
      row.name:SetText(g.name .. "  |cff9a9aa2×" .. g.count .. "|r")
      setColor(row.name, g.hidden and GREY or qualityColor(g.quality))
      row.sub:SetText(g.total > 0 and string.format(L["about %s"], GW.Money(g.total)) or L["no price data"])
      local here, d = packFor(g.itemID)
      local vendor = GW.VendorPrice(g.itemID)
      local note = ""
      if g.hidden then
        note = "|cff9a9aa2" .. L["hidden"] .. "|r"
      elseif vendor > 0 and g.unit and GW.Net(sellSide(), g.unit) <= vendor then
        note = "|cfff59e4b" .. L["vendor pays more"] .. "|r"
      elseif betterElsewhere(here, d) then
        local other, gain = betterElsewhere(here, d)
        note = string.format("|cff8fb0ff%s +%d%%|r", GW.HOUSE_NAMES[other], gain)
      elseif here and here.baitUnits and here.baitUnits > 0 then
        note = "|cfff59e4b" .. L["bait skipped"] .. "|r"
      end
      row.note:SetText(note)
      row.sel:SetShown(state.sel and state.sel.itemID == g.itemID)
    else
      row:Hide()
    end
  end
  local shown = #state.bags - (state.showHidden and state.hiddenCount or 0)
  panel.bagFooter:SetText(
    GW.Plural(shown, "%d sellable item · about %s", "%d sellable items · about %s", GW.Money(total))
  )
  if (state.hiddenCount or 0) > 0 then
    panel.hiddenLink:SetText(
      string.format(
        state.showHidden and L["|cff8fb0ffhide %d again|r"] or L["|cff8fb0ff%d hidden · show|r"],
        state.hiddenCount
      )
    )
    panel.hiddenLink:Show()
  else
    panel.hiddenLink:Hide()
  end
end

---------------------------------------------------------------------------
-- column 3: strategies, price, receipt (SELL-4..11, 17, 18)
---------------------------------------------------------------------------
--- The price per item in the price box.
---@return number copper
local function getUnitPrice()
  if panel.money and MoneyInputFrame_GetCopper then return MoneyInputFrame_GetCopper(panel.money) or 0 end
  return tonumber(panel.copperBox and panel.copperBox:GetText() or "") or 0
end

--- Puts a price in the price box (marked as set by the code, not the player).
---@param c number copper
local function setUnitPrice(c)
  state.settingPrice = true
  if panel.money and MoneyInputFrame_SetCopper then
    MoneyInputFrame_SetCopper(panel.money, c)
  elseif panel.copperBox then
    panel.copperBox:SetText(tostring(c))
  end
  state.settingPrice = false
end

--- The price that will be posted: what's in the box, rounded down to whole silver for gear
--- (gear posts in whole silver only).
---@return number unit copper per item
---@return boolean rounded true when the box had copper that gear can't post
local function postUnit()
  local g, unit = state.sel, getUnitPrice()
  if g and not g.isCommodity and unit > 0 then return GW.SilverFloor(unit), unit % 100 ~= 0 end
  return unit, false
end

--- The quantity to post: commodities post any quantity in one listing (from the box, capped at what
--- you have); other items post one auction per click.
---@return number
local function quantity()
  local g = state.sel
  if not g then return 1 end
  if not g.isCommodity then return 1 end
  return math.max(1, math.min(tonumber(panel.qty:GetText()) or 1, g.count))
end

--- What you receive if all sell, after the auction house cut.
---@param unit number copper per item
---@param qty number
---@return number copper
local function youReceive(unit, qty)
  local gross = unit * qty
  return gross - math.floor(gross * sellCut() + 0.5)
end

--- The Post button's text, e.g. "Post 1 of 3 · Item".
---@param g SellBagItem
---@param qty number
---@return string
local function postLabel(g, qty)
  if g.isCommodity then return string.format(L["Post %d × %s"], qty, g.name) end
  if g.count > 1 then return string.format(L["Post 1 of %d · %s"], g.count, g.name) end
  return string.format(L["Post %s"], g.name)
end

--- Redraws column 3 for the current price, quantity and duration: strategy buttons, receipt
--- (deposit, cut, what you receive), the market check line and the Post button.
local function recalc()
  local g = state.sel
  if not g then return end
  local qty, unit, rounded = quantity(), postUnit()

  -- strategy buttons show what you'd receive at the current quantity
  for _, b in ipairs(panel.stratButtons) do
    local p = state.prices and state.prices[b.key]
    if p then
      b:SetText(string.format("%s\n%s", b.label, GW.Money(p)))
      b.receive:SetText(string.format(L["get %s"], GW.Money(youReceive(p, qty))))
      b:Enable()
    else
      b:SetText(b.label)
      b.receive:SetText("")
      b:Disable()
    end
    if state.strategy == b.key then
      b:LockHighlight()
    else
      b:UnlockHighlight()
    end
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
  local cut = math.floor(gross * sellCut() + 0.5)
  panel.r1L:SetText(string.format(L["Listing total (%d × %s)"], qty, GW.Money(unit)))
  panel.r1R:SetText(GW.Money(gross))
  panel.r2L:SetText(string.format(L["Auction house cut (%d%%)"], math.floor(sellCut() * 100 + 0.5)))
  panel.r2R:SetText("−" .. GW.Money(cut))
  panel.r3L:SetText(L["You receive if all sell"])
  panel.r3R:SetText(GW.Money(gross - cut))
  panel.r4L:SetText(L["Deposit now (back when it sells)"])
  panel.r4R:SetText(deposit and GW.Money(deposit) or "?")

  -- market check line (SELL-7 / SELL-8): against the 7-day normal, else today's typical price
  local here = packFor(g.itemID)
  local normal = here and (here.avg7 or here.avg30)
  local ref, messages = normal, PRICE_CHECK.normal
  if not ref then
    ref, messages = (state.stats and state.stats.mv) or (here and here.mv), PRICE_CHECK.typical
  end
  local warn, warnColor = "", GREY
  local kind, pct = GW.PriceCheck(unit, ref)
  if kind == "at" then
    warn = string.format(messages.at, GW.Money(ref))
  elseif kind then
    warn = string.format(messages[kind], pct, GW.Money(ref))
    if kind == "below" or kind == "above" then warnColor = GW.SIGNAL_ORANGE end
  end
  local vendor = GW.VendorPrice(g.itemID)
  if vendor > 0 and unit > 0 and GW.Net(sellSide(), unit) <= vendor then
    warn, warnColor =
      string.format(L["A vendor pays %s each, more than you'd net here. Sell to a vendor instead."], GW.Money(vendor)),
      GW.SIGNAL_ORANGE
  end
  if rounded then
    warn, warnColor =
      string.format(L["Gear posts in whole silver: this posts at %s."], GW.Money(unit)) .. " " .. warn, GW.SIGNAL_ORANGE
  end
  panel.warn:SetText(warn)
  setColor(panel.warn, warnColor)
  -- Only data-pack prices so far (live listings still loading): wait, unless the player typed a price.
  local loading = state.searching and not state.stats and not state.typed
  local p = state.pending
  local confirmWait = p and p.warning and GetTime() - (p.warnedAt or 0) < GW.CONFIRM_DELAY
  panel.post:SetText(
    loading and L["Getting live prices…"]
      or p and p.warning and string.format(L["Confirm: %s"], postLabel(g, qty))
      or postLabel(g, qty)
  )
  panel.post:SetEnabled(unit > 0 and not loading and not confirmWait and (not p or p.warning) and true or false)
end

--- Sets state.prices for the selected item from live listings (or the data pack while they load);
--- nil when there is no price at all.
local function computePrices()
  local g, s = state.sel, state.stats
  local cheapest, typical, own
  if s then
    local first = s.sorted[s.firstRealIndex]
    cheapest, typical, own = first.price, s.mv, first.own
  else
    local here = packFor(g.itemID)
    if here then
      cheapest, typical = here.min, here.mv
    end
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
  state.prices =
    { fast = fast, typical = typ, patient = patient, cheapest = cheapest, typicalPrice = typical, own = own }
end

--- Selects a strategy, puts its price in the box and shows why.
---@param key string "fast", "typical" or "patient"
---@param reason string? text for the line under the buttons
local function chooseStrategy(key, reason)
  state.strategy = key
  state.typed = nil
  local p = state.prices and state.prices[key]
  if p then setUnitPrice(p) end
  panel.why:SetText(reason or "")
  recalc()
end

--- Works out the prices and picks the default strategy: Sell Fast, unless your own listing is
--- already the cheapest (match it), selling fast would net less than a vendor pays, or it would be
--- more than 15% under the typical price (then Typical).
local function applyDefaultStrategy()
  computePrices()
  if state.typed then -- the player's own price stays; the strategy buttons still show the new prices
    recalc()
    return
  end
  local P, s = state.prices, state.stats
  if not P then
    state.strategy = nil
    setUnitPrice(0)
    panel.why:SetText(
      state.searching and L["Live listings loading…"] or L["No listings and no price data: type your own price."]
    )
    recalc()
    return
  end
  local loading = state.searching and not s and (L["Data pack prices while live listings load."] .. " ") or ""
  local bait = (s and s.baitUnits > 0)
      and (" " .. GW.Plural(
        s.baitUnits,
        "Skipped %d likely bait listing at %s.",
        "Skipped %d likely bait listings at %s.",
        GW.Money(s.baitPrice)
      ))
    or ""
  -- Judge the price Sell fast would post (for gear that's a whole silver under, e.g. 2s on a 3s wall),
  -- not the cheapest listing, and never default to netting less than a vendor pays.
  local vendor = GW.VendorPrice(state.sel.itemID)
  local fastBelowVendor = vendor > 0 and GW.Net(sellSide(), P.fast) <= vendor and GW.Net(sellSide(), P.typical) > vendor
  if P.own then
    chooseStrategy("fast", loading .. L["Your own listing is already the cheapest; matching it."] .. bait)
  elseif fastBelowVendor then
    chooseStrategy(
      "typical",
      loading
        .. string.format(L["Typical chosen: selling fast would net less than a vendor pays (%s)."], GW.Money(vendor))
        .. bait
    )
  elseif P.typicalPrice and P.fast < P.typicalPrice * FAST_OK_RATIO then
    chooseStrategy(
      "typical",
      loading
        .. string.format(
          L["Typical chosen: selling fast would be %d%% under the typical price."],
          math.floor((1 - P.fast / P.typicalPrice) * 100 + 0.5)
        )
        .. bait
    )
  else
    chooseStrategy("fast", loading .. GW.SellFastText(not state.sel.isCommodity, GW.Money(P.cheapest)) .. bait)
  end
end

---------------------------------------------------------------------------
-- column 2: market (SELL-3, 15, 16)
---------------------------------------------------------------------------
--- Redraws column 2's numbers: typical price, cheapest real, listing count, other houses, and the
--- cheapest listings with their notes (bait, yours, cheapest real seller, typical price).
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
      if side ~= sellSide() and d[side] and d[side].mv then
        local label = side == "N" and L["BW %s"] or side == "H" and L["Horde %s"] or L["Ally %s"]
        others[#others + 1] = string.format(label, GW.Money(d[side].mv))
      end
    end
  end
  panel.st4:SetText(#others > 0 and table.concat(others, "\n") or "–")

  for i, r in ipairs(panel.listRows) do
    local x = s and s.sorted[i]
    if x then
      r.price:SetText(GW.Money(x.price))
      r.qty:SetText(tostring(x.qty))
      if i < s.firstRealIndex then
        r.note:SetText(L["likely bait, skipped"])
        setColor(r.note, GW.SIGNAL_ORANGE)
        r.price:SetTextColor(0.55, 0.55, 0.58)
        r.qty:SetTextColor(0.55, 0.55, 0.58)
      else
        r.price:SetTextColor(1, 1, 1)
        r.qty:SetTextColor(1, 1, 1)
        if x.own then
          r.note:SetText(L["yours"])
          setColor(r.note, GW.GOLD)
        elseif i == s.firstRealIndex then
          r.note:SetText(L["cheapest real seller"])
          setColor(r.note, GW.SIGNAL_BLUE)
        elseif s.mv and x.price == s.mv then
          r.note:SetText(L["typical price"])
          setColor(r.note, GREY)
        else
          r.note:SetText("")
        end
      end
    else
      r.price:SetText("")
      r.qty:SetText("")
      r.note:SetText("")
    end
  end
end

---------------------------------------------------------------------------
-- search
---------------------------------------------------------------------------
--- Listings for an item from the last search, commodity results first, else item results.
--- Shared with the My Auctions tab.
---@param itemID number
---@param itemKey table? item key for item (non-commodity) results
---@return { price: number, qty: number, own: boolean?, ownQty: number? }[] list price is per unit
---@return string|nil source "commodity", "item" or nil when empty
---@return number commodityCount number of commodity results the client reported
---@return number itemCount number of item results the client reported
function GW.CollectSearchResults(itemID, itemKey)
  local list = {}
  local nc = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  for i = 1, nc do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if r then
      local ownQty = r.numOwnerItems or 0
      list[#list + 1] = {
        price = r.unitPrice,
        qty = r.quantity,
        own = r.containsOwnerItem or ownQty > 0,
        ownQty = ownQty > 0 and ownQty or nil,
      }
    end
  end
  if #list > 0 then return list, "commodity", nc, 0 end
  local ni = itemKey and (C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0) or 0
  for i = 1, ni do
    local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if r and r.buyoutAmount and (r.quantity or 0) > 0 then
      list[#list + 1] =
        { price = math.floor(r.buyoutAmount / r.quantity + 0.5), qty = r.quantity, own = r.containsOwnerItem }
    end
  end
  return list, #list > 0 and "item" or nil, nc, ni
end

--- Reads the selected item's search results into state.stats and redraws. An empty result while the
--- search is still running is ignored (no answer yet).
---@param itemKeyFromEvent table? the item key an item-results event carried
---@param eventName string? for the log
local function readResults(itemKeyFromEvent, eventName)
  local g = state.sel
  if not g then return end
  local list, source, nc, ni = GW.CollectSearchResults(g.itemID, itemKeyFromEvent or state.key)
  GW.Log(
    "%s for %s: %d listings (%s; commodity n=%s, item n=%s)",
    eventName or "read",
    g.name,
    #list,
    tostring(source),
    tostring(nc),
    tostring(ni)
  )
  if eventName and not eventName:find("^timeout") then state.answered = true end
  if #list == 0 and state.searching then return end
  state.searching = false
  state.stats = GW.MarketStats(list)
  panel.listStatus:SetText(state.stats and L["searched just now"] or L["no other listings"])
  renderMarket()
  applyDefaultStrategy()
end

--- Sends a search for state.key, sorted by price; counts it against the search limit.
---@param kind string "sell" for SendSellSearchQuery, anything else for SendSearchQuery
local function sendQuery(kind)
  local sorts = GW.PriceSorts()
  GW.NoteSearch()
  if kind == "sell" then
    C_AuctionHouse.SendSellSearchQuery(state.key, sorts, true)
  else
    C_AuctionHouse.SendSearchQuery(state.key, sorts, true)
  end
  GW.Log(
    "sent %s search for %s (itemID %d, commodity=%s)",
    kind,
    state.sel.name,
    state.sel.itemID,
    tostring(state.sel.isCommodity)
  )
end

--- Searches the live listings for a bag item, waiting for the search throttle if needed. Shows data
--- pack prices until the answer arrives; gives up after 8 seconds.
---@param g SellBagItem
local search
search = function(g)
  -- Use the exact item key of the item in your bag (with suffix and item level): searching
  -- random-suffix gear ("of the Falcon") by item id alone got no answer in game.
  local key
  local loc = findLocation(g.itemID) or g.loc
  if loc and C_AuctionHouse.GetItemKeyFromItem then
    local ok, k = pcall(C_AuctionHouse.GetItemKeyFromItem, loc)
    if ok then key = k end
  end
  state.key = key or C_AuctionHouse.MakeItemKey(g.itemID)
  GW.Log(
    "item key for %s: id %s, level %s, suffix %s",
    g.name,
    tostring(state.key.itemID),
    tostring(state.key.itemLevel),
    tostring(state.key.itemSuffix)
  )
  state.stats = nil
  state.searching = true
  state.answered = false
  state.token = (state.token or 0) + 1
  local token = state.token
  renderMarket()
  applyDefaultStrategy()
  if not GW.CanSearch() then
    -- throttled: wait for a slot instead of firing anyway (§3.5)
    panel.listStatus:SetText(GW.WaitText())
    GW.Log("sell search waiting: %s", tostring(GW.SearchBlocked()))
    C_Timer.After(GW.SEARCH_RETRY, function()
      if state.token == token and state.sel == g and panel:IsShown() then search(g) end
    end)
    return
  end
  panel.listStatus:SetText(L["searching…"])
  -- The normal search answers within a second on Forever; the sell search never answered in game
  -- (log 2026-11-10: every sell search timed out, the general one then answered at once), so the
  -- sell search is only the fallback after 4 seconds.
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
      -- The auction house did answer, with nothing: none listed here (e.g. at Blackwater).
      panel.listStatus:SetText(
        state.answered and string.format(L["none listed at %s right now"], GW.HOUSE_NAMES[sellSide()])
          or L["no answer from the auction house"]
      )
      applyDefaultStrategy()
    end
  end)
end

--- Redraws the status bar (AH-2): house, data pack age (the banner, AH-3, when the pack is missing or
--- old), last full scan and searches this minute.
local function renderStatus()
  local h = GW.House()
  local pack = GW.Pack()
  local days = GW.PackAgeDays()
  local packText
  if not pack then
    packText = "|cfff59e4b"
      .. string.format(L["No data pack for %s %s: prices come from live listings only"], h.region, h.ruleset)
      .. "|r"
  elseif days and days > GW.STALE_DAYS then
    packText = "|cfff59e4b"
      .. GW.Plural(
        math.floor(days),
        "Data pack is %d day old: update Goldwright Data",
        "Data pack is %d days old: update Goldwright Data"
      )
      .. "|r"
  else
    packText = string.format(L["Data pack: snapshot %s"], GW.Age(pack.snapshotAt))
  end
  local scanText = GW.LastScanText and GW.LastScanText(sellSide())
  panel.status:SetText(
    string.format(
      "%s · %s · %s     %s     %s     %s",
      h.region,
      h.ruleset,
      GW.HOUSE_NAMES[sellSide()],
      packText,
      scanText and string.format(L["Last scan %s"], scanText) or L["No full scan yet"],
      string.format(L["Searches this minute: %d / %d"], GW.SearchesThisMinute(), GW.SEARCH_LIMIT)
    )
  )
end

--- Sets the auction duration and highlights its button.
---@param idx number 1 = 2h, 2 = 8h, 3 = 24h
local function setDuration(idx)
  state.duration = idx
  for _, b in ipairs(panel.durButtons) do
    if b.idx == idx then
      b:LockHighlight()
    else
      b:UnlockHighlight()
    end
  end
end

--- Deselects the item, stops its search timers and shows a message in place of columns 2 and 3.
---@param message string? text to show (default: "Choose an item on the left...")
local function clearSelection(message)
  state.sel, state.stats, state.strategy, state.token = nil, nil, nil, (state.token or 0) + 1
  panel.col2:Hide()
  panel.col3:Hide()
  panel.empty:SetText(message or L["Choose an item on the left to see its market and price it."])
  panel.empty:Show()
  renderBags()
end

--- Selects a bag item: fills columns 2 and 3, restores its remembered duration, draws its charts
--- and starts its search.
---@param g SellBagItem
local function selectItem(g)
  state.sel = g
  state.stats = nil
  state.strategy = nil
  state.typed = nil
  panel.iconButton.tex:SetTexture(g.icon or 134400)
  panel.iconButton:Show()
  panel.itemName:SetText(g.name)
  setColor(panel.itemName, qualityColor(g.quality))
  panel.itemInfo:SetText(
    string.format(
      L["You have %d · %s"],
      g.count,
      g.isCommodity and L["commodity: one listing for any quantity"] or L["item: one auction per click"]
    )
  )
  panel.qty:SetText(tostring(g.isCommodity and g.count or 1))
  if g.isCommodity then
    panel.qty:Enable()
  else
    panel.qty:Disable()
  end
  panel.allButton:SetShown(g.isCommodity and true or false)
  local remembered = GoldwrightDB.durations and GoldwrightDB.durations[g.itemID]
  setDuration(remembered or GW.Opt("duration"))
  panel.col2:Show()
  panel.col3:Show()
  panel.empty:Hide()
  GW.SellCharts.Render(g.itemID)
  renderBags()
  search(g)
end

--- Error names (from GetGameMessageInfo) that can answer a post: auction house errors and money.
local POST_ERRORS = { ERR_NOT_ENOUGH_MONEY = true, ERR_ITEM_NOT_FOUND = true, ERR_ITEM_LOCKED = true }

--- Whether a UI_ERROR_MESSAGE is the auction house refusing a post, not something unrelated
--- ("Out of range.", a spell error) that happens to arrive while the post is on its way.
---@param messageType any UI_ERROR_MESSAGE's first argument
---@param message any its text
---@return boolean
function GW.IsAuctionError(messageType, message)
  if type(message) ~= "string" then return false end
  local name = GetGameMessageInfo and type(messageType) == "number" and GetGameMessageInfo(messageType)
  if type(name) == "string" then return name:find("^ERR_AUCTION") ~= nil or POST_ERRORS[name] == true end
  -- Without the error's name, compare the text with the game's own auction and money messages.
  for key in pairs(POST_ERRORS) do
    if _G[key] == message then return true end
  end
  local lower = message:lower()
  return lower:find("auction", 1, true) ~= nil
    or lower:find("money", 1, true) ~= nil
    or lower:find("deposit", 1, true) ~= nil
end

---------------------------------------------------------------------------
-- posting and the post queue (SELL-12, 13, 14)
---------------------------------------------------------------------------
--- Stops waiting for the pending post. It stays "recent" for a while so a late success still moves
--- the queue on (an unrelated error message can arrive while a post is on its way).
local function finishPending()
  if state.pending then state.recent = state.pending end
  state.pending = nil
  if state.sel then recalc() end
end

--- The pending or recent post, if it was sent less than POST_TIMEOUT + 5 seconds ago.
---@return SellPendingPost|nil
local function postInFlight()
  local p = state.pending or state.recent
  if p and GetTime() - p.at < POST_TIMEOUT + 5 then return p end
  return nil
end

--- After a post: once the bags show it (or after 3 seconds), select the next item, or the same gear
--- with copies left (SELL-13).
local function tryAdvance()
  local a = state.advance
  if not a then return end
  local left = itemCount(a.itemID)
  if left > a.countBefore - a.qty and GetTime() - a.at < 3 then return end -- bags not updated yet
  state.advance = nil
  scanBags()
  local visible = {}
  for _, g in ipairs(state.bags) do
    if not g.hidden then visible[#visible + 1] = g end
  end
  local nextItem = GW.NextInQueue(a.order, visible, a.itemID, a.keepSame)
  if nextItem then
    state.offset = 0
    for i, g in ipairs(state.bags) do
      if g == nextItem and i > ROWS then state.offset = i - ROWS end
    end
    selectItem(nextItem)
  else
    clearSelection(L["That was the last item in the list. Choose another item, or close the auction house."])
  end
end

--- The post went through: remember its duration for the item, show a toast and schedule the move to
--- the next item. Handles each post once.
local function onPosted()
  local p = postInFlight()
  if not p or p.done then return end
  p.done = true
  state.recent = nil
  GoldwrightDB.durations = GoldwrightDB.durations or {}
  GoldwrightDB.durations[p.itemID] = p.duration
  toast(string.format(L["Posted %d × %s at %s each."], p.qty, p.name, GW.Money(p.unit)), GW.SIGNAL_BLUE)
  GW.Log("posted %d x %s at %d (%s)", p.qty, p.name, p.unit, p.commodity and "commodity" or "item")
  state.advance = {
    itemID = p.itemID,
    qty = p.qty,
    countBefore = p.countBefore,
    order = p.order,
    keepSame = p.keepSame,
    at = GetTime(),
  }
  finishPending()
  C_Timer.After(0.3, tryAdvance)
  C_Timer.After(1.0, tryAdvance)
  C_Timer.After(3.1, tryAdvance)
end

--- Posts one listing of the selected item (SELL-12), or confirms a post the auction house asked about.
--- Also the key binding (GW.PostSelected); does nothing unless the Sell tab is shown.
local function postSelected()
  if not (panel and panel:IsShown() and GW.activeTab == "sell") then return end
  local g = state.sel
  if not g then return toast(L["Choose an item first."], GW.SIGNAL_ORANGE) end
  local p = state.pending
  if p and not p.warning then return toast(L["Waiting for the auction house…"], GREY) end
  if InCombatLockdown and InCombatLockdown() then return toast(L["Not in combat."], GW.SIGNAL_ORANGE) end

  -- The auction house asked us to confirm this post (AUCTION_HOUSE_POST_WARNING): this click confirms.
  if p and p.warning then
    if GetTime() - (p.warnedAt or 0) < GW.CONFIRM_DELAY then return end -- a double click or held key
    p.warning = nil
    local loc = findLocation(p.itemID) or p.loc
    if p.commodity and C_AuctionHouse.ConfirmPostCommodity then
      C_AuctionHouse.ConfirmPostCommodity(loc, p.duration, p.qty, p.unit)
    elseif C_AuctionHouse.ConfirmPostItem then
      C_AuctionHouse.ConfirmPostItem(loc, p.duration, 1, nil, p.unit)
    end
    p.at = GetTime()
    toast(L["Confirmed. Waiting for the auction house…"], GREY)
    recalc()
    return
  end

  local unit, qty = postUnit(), quantity()
  if unit <= 0 then return toast(L["Set a price first."], GW.SIGNAL_ORANGE) end
  local loc = findLocation(g.itemID)
  if not loc then return toast(L["Can't find that item in your bags any more."], GW.SIGNAL_ORANGE) end
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    return toast(L["The auction house is busy: click again in a moment."], GW.SIGNAL_ORANGE)
  end

  local order = {}
  for i, b in ipairs(state.bags) do
    order[i] = { itemID = b.itemID }
  end
  ---@type SellPendingPost
  state.pending = {
    itemID = g.itemID,
    name = g.name,
    qty = qty,
    unit = unit,
    duration = state.duration,
    loc = loc,
    commodity = g.isCommodity,
    countBefore = itemCount(g.itemID),
    order = order,
    keepSame = not g.isCommodity and g.count > 1,
    at = GetTime(),
  }
  local token = state.pending
  state.token, state.searching = (state.token or 0) + 1, false -- the item's search timers stop here
  if g.isCommodity then
    C_AuctionHouse.PostCommodity(loc, state.duration, qty, unit)
  else
    C_AuctionHouse.PostItem(loc, state.duration, 1, nil, unit)
  end
  GW.Log("post sent: %d x %s at %d, duration %d", qty, g.name, unit, state.duration)
  toast(L["Posting…"], GREY)
  recalc()
  C_Timer.After(POST_TIMEOUT, function()
    if state.pending == token and not token.warning then
      toast(L["No answer from the auction house. Check your auctions before posting again."], GW.SIGNAL_ORANGE)
      finishPending()
    end
  end)
end
GW.PostSelected = postSelected

---------------------------------------------------------------------------
-- tabs
---------------------------------------------------------------------------
--- Switches the panel to a tab and shows or hides each tab's view.
---@param key string "sell", "cancel", "shopping" or "scan"
local function showTab(key)
  GW.activeTab = key
  for _, b in ipairs(panel.tabButtons) do
    if b.key == key then
      b:LockHighlight()
    else
      b:UnlockHighlight()
    end
  end
  panel.sellView:SetShown(key == "sell")
  if GW.CancelView then
    if key == "cancel" then
      GW.CancelView.Show(panel.inset)
    else
      GW.CancelView.Hide()
    end
  end
  if GW.ScanView then
    if key == "scan" then
      GW.ScanView.Show(panel.inset)
    else
      GW.ScanView.Hide()
    end
  end
  if GW.ShopView then
    if key == "shopping" then
      GW.ShopView.Show(panel.inset)
    else
      GW.ShopView.Hide()
    end
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
local header = UI.Header

--- Builds the panel window: tab bar, Settings button, the three Sell columns and the status bar.
--- The panel starts hidden.
local function createPanel()
  panel = UI.Window("GoldwrightSellFrame", W, H, { title = "Goldwright", movable = true })
  GW.panel = panel

  panel.tabButtons = {}
  local prev
  for i, t in ipairs(TABS) do
    local b = UI.Button(panel, t.label, t.key == "cancel" and 110 or 90, 22)
    b.key = t.key
    if i == 1 then
      b:SetPoint("TOPLEFT", 14, -30)
    else
      b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    end
    if t.soon then
      b:Disable()
      if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
      b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(string.format(L["%s: coming in a later build"], t.label))
        GameTooltip:Show()
      end)
      b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    else
      b:SetScript("OnClick", function() showTab(t.key) end)
    end
    panel.tabButtons[i] = b
    prev = b
  end
  local gear = UI.Button(panel, L["Settings"], 90, 22)
  gear:SetPoint("TOPRIGHT", -14, -30)
  gear:SetScript("OnClick", function()
    if GW.OpenSettings then GW.OpenSettings() end
  end)

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
  header(view, L["1 · Choose"], 12, -8)
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
    row.name = fs(row, "GameFontHighlight", "LEFT")
    row.name:SetPoint("TOPLEFT", 34, -3)
    row.name:SetWidth(196)
    row.name:SetWordWrap(false)
    row.sub = fs(row, "GameFontDisableSmall", "LEFT")
    row.sub:SetPoint("BOTTOMLEFT", 34, 3)
    row.note = fs(row, "GameFontHighlightSmall", "RIGHT")
    row.note:SetPoint("BOTTOMRIGHT", -4, 3)
    row:SetScript("OnClick", function(self, button)
      local g = self.g
      if not g then return end
      if button == "RightButton" then -- SELL-2: "Don't show" (right-click again to bring it back)
        GoldwrightDB.ignore = GoldwrightDB.ignore or {}
        GoldwrightDB.ignore[g.itemID] = not g.hidden or nil
        if state.sel and state.sel.itemID == g.itemID and not g.hidden then clearSelection() end
        scanBags()
        renderBags()
        return
      end
      if not g.hidden then selectItem(g) end
    end)
    row:SetScript("OnEnter", function(self)
      if not self.g then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetBagItem(self.g.bag, self.g.slot)
      GameTooltip:AddLine(
        self.g.hidden and L["Right-click: show in this list again"] or L["Right-click: hide from this list"],
        0.6,
        0.6,
        0.65
      )
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
    scanBags()
    renderBags()
  end)
  UI.Divider(view, 248)

  panel.empty = fs(view, "GameFontDisable", "CENTER")
  panel.empty:SetPoint("CENTER", view, "CENTER", 124, 0)
  panel.empty:SetWidth(600)
  panel.empty:SetText(L["Choose an item on the left to see its market and price it."])

  -- Column 2: market ----------------------------------------------------------
  local col2 = CreateFrame("Frame", nil, view)
  col2:SetPoint("TOPLEFT", 258, -8)
  col2:SetSize(380, 440)
  panel.col2 = col2
  header(col2, L["2 · Market"], 0, 0)

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
  panel.itemName = fs(col2, "GameFontNormalLarge", "LEFT")
  panel.itemName:SetPoint("TOPLEFT", panel.iconButton, "TOPRIGHT", 10, -1)
  panel.itemInfo = fs(col2, "GameFontHighlightSmall", "LEFT")
  panel.itemInfo:SetPoint("TOPLEFT", panel.itemName, "BOTTOMLEFT", 0, -3)
  setColor(panel.itemInfo, GREY)

  local stats = {
    { L["Typical price"], "st1" },
    { L["Cheapest real"], "st2" },
    { L["Listings"], "st3" },
    { L["Other houses"], "st4" },
  }
  for i, s in ipairs(stats) do
    local x = (i - 1) * 95
    local lab = fs(col2, "GameFontDisableSmall", "LEFT")
    lab:SetPoint("TOPLEFT", x, -66)
    lab:SetText(s[1])
    local val = fs(col2, i == 4 and "GameFontHighlightSmall" or "GameFontHighlightLarge", "LEFT")
    val:SetPoint("TOPLEFT", x, -80)
    panel[s[2]] = val
  end

  local lh = header(col2, L["Cheapest listings"], 0, -120)
  panel.listStatus = fs(col2, "GameFontDisableSmall", "LEFT")
  panel.listStatus:SetPoint("LEFT", lh, "RIGHT", 10, 0)
  local c1 = fs(col2, "GameFontDisableSmall", "LEFT")
  c1:SetPoint("TOPLEFT", 0, -138)
  c1:SetText(L["Price each"])
  local c2 = fs(col2, "GameFontDisableSmall", "LEFT")
  c2:SetPoint("TOPLEFT", 110, -138)
  c2:SetText(L["Quantity"])
  local c3 = fs(col2, "GameFontDisableSmall", "LEFT")
  c3:SetPoint("TOPLEFT", 190, -138)
  c3:SetText(L["Note"])
  panel.listRows = {}
  for i = 1, 7 do
    local y = -154 - (i - 1) * 18
    local r = {}
    r.price = fs(col2, "GameFontHighlight", "LEFT")
    r.price:SetPoint("TOPLEFT", 0, y)
    r.qty = fs(col2, "GameFontHighlight", "LEFT")
    r.qty:SetPoint("TOPLEFT", 110, y)
    r.note = fs(col2, "GameFontHighlightSmall", "LEFT")
    r.note:SetPoint("TOPLEFT", 190, y)
    panel.listRows[i] = r
  end

  -- Price history (SELL-15) and best time to post (SELL-16), side by side: SellCharts.lua
  GW.SellCharts.Create(col2)
  panel.charts = GW.SellCharts
  UI.Divider(view, 648)

  -- Column 3: your listing ----------------------------------------------------
  local col3 = CreateFrame("Frame", nil, view)
  col3:SetPoint("TOPLEFT", 658, -8)
  col3:SetSize(318, 440)
  panel.col3 = col3
  header(col3, L["3 · Your listing"], 0, 0)

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
        fast = GW.SellFastText(state.sel and not state.sel.isCommodity),
        typical = (state.sel and not state.sel.isCommodity)
            and L["Typical: at the typical price (gear posts in whole silver)."]
          or L["Typical: 1c under the typical price."],
        patient = L["Patient: about 10% above the typical price; best posted when supply is low."],
      }
      chooseStrategy(st.key, reasons[st.key])
    end)
    panel.stratButtons[i] = b
  end
  panel.why = fs(col3, "GameFontDisableSmall", "LEFT")
  panel.why:SetPoint("TOPLEFT", 0, -82)
  panel.why:SetWidth(316)

  local pl = fs(col3, "GameFontNormalSmall", "LEFT")
  pl:SetPoint("TOPLEFT", 0, -116)
  pl:SetText(L["Price per item (or type your own)"])
  if MoneyInputFrame_SetCopper and MoneyInputFrame_GetCopper then
    panel.money = CreateFrame("Frame", "GoldwrightSellPrice", col3, "MoneyInputFrameTemplate")
    panel.money:SetPoint("TOPLEFT", 4, -132)
    if MoneyInputFrame_SetOnValueChangedFunc then
      MoneyInputFrame_SetOnValueChangedFunc(panel.money, function()
        -- The money boxes report changes a moment after we set them, so only a price that differs
        -- from the chosen strategy's is the player's own.
        local chosen = state.strategy and state.prices and state.prices[state.strategy]
        if not state.settingPrice and getUnitPrice() ~= chosen and getUnitPrice() > 0 then
          state.strategy = nil
          state.typed = true
          panel.why:SetText(L["Your own price."])
        end
        recalc()
      end)
    end
  else
    panel.copperBox = CreateFrame("EditBox", nil, col3, "InputBoxTemplate")
    panel.copperBox:SetSize(120, 22)
    panel.copperBox:SetPoint("TOPLEFT", 6, -132)
    panel.copperBox:SetAutoFocus(false)
    panel.copperBox:SetScript("OnTextChanged", function(_, userInput)
      if userInput then
        state.strategy = nil
        state.typed = true
      end
      recalc()
    end)
  end

  local ql = fs(col3, "GameFontNormalSmall", "LEFT")
  ql:SetPoint("TOPLEFT", 0, -162)
  ql:SetText(L["Quantity"])
  panel.qty = CreateFrame("EditBox", nil, col3, "InputBoxTemplate")
  panel.qty:SetSize(50, 22)
  panel.qty:SetPoint("TOPLEFT", 6, -178)
  panel.qty:SetAutoFocus(false)
  panel.qty:SetNumeric(true)
  panel.qty:SetMaxLetters(5)
  panel.qty:SetScript("OnTextChanged", recalc)
  panel.qty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  panel.allButton = UI.Button(col3, L["All"], 44, 22)
  panel.allButton:SetPoint("LEFT", panel.qty, "RIGHT", 6, 0)
  panel.allButton:SetScript("OnClick", function()
    if state.sel then panel.qty:SetText(tostring(state.sel.count)) end
  end)

  local dl = fs(col3, "GameFontNormalSmall", "LEFT")
  dl:SetPoint("TOPLEFT", 150, -162)
  dl:SetText(L["Duration"])
  panel.durButtons = {}
  for i, d in ipairs(DURATIONS) do
    local b = UI.Button(col3, d.label, 50, 22)
    b.idx = d.idx
    b:SetPoint("TOPLEFT", 150 + (i - 1) * 54, -178)
    b:SetScript("OnClick", function()
      setDuration(d.idx)
      recalc()
    end)
    panel.durButtons[i] = b
  end
  setDuration(GW.Opt("duration"))

  panel.warn = fs(col3, "GameFontHighlightSmall", "LEFT")
  panel.warn:SetPoint("TOPLEFT", 0, -212)
  panel.warn:SetWidth(316)

  local y = -252
  for i = 1, 4 do
    local l = fs(col3, i == 3 and "GameFontHighlight" or "GameFontHighlightSmall", "LEFT")
    l:SetPoint("TOPLEFT", 0, y)
    local r = fs(col3, i == 3 and "GameFontNormal" or "GameFontHighlightSmall", "RIGHT")
    r:SetPoint("TOPRIGHT", -4, y)
    if i ~= 3 then setColor(l, GREY) end
    panel["r" .. i .. "L"], panel["r" .. i .. "R"] = l, r
    y = y - (i == 2 and 24 or 18)
  end
  local line = col3:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 1, 1, 0.1)
  line:SetPoint("TOPLEFT", 0, -290)
  line:SetSize(314, 1)

  panel.toast = fs(col3, "GameFontHighlightSmall", "LEFT")
  panel.toast:SetPoint("BOTTOMLEFT", 0, 58)
  panel.toast:SetWidth(314)
  panel.post = UI.Button(col3, L["Post"], 314, 30)
  panel.post:SetPoint("BOTTOMLEFT", 0, 22)
  panel.post:SetScript("OnClick", postSelected)
  local postNote = fs(col3, "GameFontDisableSmall", "RIGHT")
  postNote:SetPoint("TOPRIGHT", panel.post, "BOTTOMRIGHT", 0, -4)
  postNote:SetText(L["One listing per click · then the next item is ready"])

  col2:Hide()
  col3:Hide()

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
  C_Timer.NewTicker(5, function()
    if panel:IsShown() then renderStatus() end
  end)
  GW.OnOptionsChanged(function()
    if not panel:IsShown() then return end
    renderStatus()
    if GW.activeTab == "sell" then
      scanBags()
      renderBags()
      if state.sel then
        renderMarket()
        applyDefaultStrategy()
        GW.SellCharts.Render(state.sel.itemID)
      end
    end
  end)
  -- New frames start shown, so the first Show() wouldn't fire OnShow; start hidden instead.
  panel:Hide()
end

--- Places the panel to the right of the auction house window (centred when that isn't shown).
local function anchorToAuctionHouse()
  panel:ClearAllPoints()
  if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
    panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 6, 0)
  else
    panel:SetPoint("CENTER")
  end
end

--- Whether the auction house window is open.
---@return boolean|nil
local function ahOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end
GW.AuctionHouseOpen = ahOpen

--- Shows or hides the panel; only at the auction house.
function GW.ToggleSellPanel()
  if not ahOpen() then
    GW.Print(L["Open the auction house first."])
    return
  end
  if not panel then createPanel() end
  if panel:IsShown() then
    panel:Hide()
  else
    anchorToAuctionHouse()
    panel:Show()
  end
end

--- Opens the panel on a tab; only at the auction house.
---@param key string "sell", "cancel", "shopping" or "scan"
function GW.OpenTab(key)
  if not ahOpen() then
    GW.Print(L["Open the auction house first."])
    return
  end
  if not panel then createPanel() end
  GW.activeTab = key
  if panel:IsShown() then
    showTab(key)
  else
    anchorToAuctionHouse()
    panel:Show()
  end
end

--- Switches to Sell with this item selected, if it is in your bags (CXL-7: "Repost in Sell").
---@param itemID number
---@return boolean|nil found true when selected, false when not in your bags, nil without a panel
function GW.SellItem(itemID)
  if not panel then return end
  showTab("sell")
  for _, g in ipairs(state.bags) do
    if g.itemID == itemID and not g.hidden then
      selectItem(g)
      return true
    end
  end
  clearSelection(
    L["That item isn't in your bags yet: cancelled auctions come back by mail. Take it from the mailbox, then post it here."]
  )
  return false
end

---------------------------------------------------------------------------
-- events
---------------------------------------------------------------------------
-- Auction house events for the panel. While the My Auctions tab is shown they all go to it;
-- search results for other tabs' searches are ignored here.
local ev = CreateFrame("Frame")
for _, e in ipairs({
  "AUCTION_HOUSE_SHOW",
  "AUCTION_HOUSE_CLOSED",
  "BAG_UPDATE_DELAYED",
  "COMMODITY_SEARCH_RESULTS_UPDATED",
  "COMMODITY_SEARCH_RESULTS_ADDED",
  "COMMODITY_SEARCH_RESULTS_RECEIVED",
  "ITEM_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_ADDED",
  "AUCTION_HOUSE_SHOW_ERROR",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "AUCTION_HOUSE_AUCTION_CREATED",
  "AUCTION_HOUSE_POST_WARNING",
  "UI_ERROR_MESSAGE",
  "PLAYER_REGEN_DISABLED",
}) do
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
    if state.advance then
      tryAdvance()
      return
    end
    scanBags()
    renderBags()
  elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
    onPosted()
  elseif event == "AUCTION_HOUSE_POST_WARNING" then
    if state.pending then
      state.pending.warning = true
      state.pending.warnedAt = GetTime()
      toast(L["The auction house asks you to confirm this price. Click Post again to confirm."], GW.SIGNAL_ORANGE)
      recalc()
      C_Timer.After(GW.CONFIRM_DELAY + 0.05, recalc)
    end
  elseif event == "UI_ERROR_MESSAGE" then
    local p = state.pending
    if p and not p.warning and GetTime() - p.at < POST_TIMEOUT and GW.IsAuctionError(arg1, arg2) then
      toast(arg2, GW.SIGNAL_ORANGE)
      finishPending()
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    if state.pending then finishPending() end
  elseif event:find("SEARCH_RESULTS") then
    if not state.sel then return end
    local argItem = type(arg1) == "table" and arg1.itemID or arg1
    GW.Log("event %s (item %s)", event, tostring(argItem))
    if argItem == nil or argItem == state.sel.itemID then readResults(type(arg1) == "table" and arg1 or nil, event) end
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" or event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    -- Diagnostics.lua records the error with the requests before it.
    if state.pending and event == "AUCTION_HOUSE_SHOW_ERROR" then
      local _, reason = GW.AuctionErrorName(arg1)
      toast(string.format(L["The auction house refused that post: %s."], reason), GW.SIGNAL_ORANGE)
      finishPending()
    end
  end
end)
