--- The Goldwright panel beside the auction house: the window, its tab bar (Sell, My Auctions, Shopping,
--- Scan), the status bar, and the Sell tab (SELL-1..18) in the wide layout (#12): "Your bags" on the
--- left; on the right the market card (the item with Lowest now / Normal, last 7 days / Sold per
--- day, one chart with a History / Best time to post switch, Cheapest listings) and the listing card
--- (Fast / Patient, price, quantity, duration, what you get, Post). One listing per
--- click (or key press), then the next item is selected and searched (post queue, SELL-13). Rules
--- without UI live in Selling.lua; colours come from the look (UI.Tokens, Skin.lua).
local _, GW = ...
local L = GW.L

local W, H = 1000, 590
local ROWS, ROW_H = 11, 38 -- bag list
local LADDER_ROWS, LADDER_H = 10, 18 -- cheapest listings
local BAGS_W = 252 -- the bags card
local MARKET_H = 300 -- the market card; the listing card takes the rest
local DURATIONS = { { idx = 1, label = L["2h"] }, { idx = 2, label = L["8h"] }, { idx = 3, label = L["24h"] } }
--- The two strategies (#15). Fast posts at the undercut setting's price (default: match the cheapest
--- listing; same-price listings sell newest first); Patient about 10% above the market price.
local STRATEGIES = {
  { key = "fast", label = L["Fast"] },
  { key = "patient", label = L["Patient"] },
}
local TABS = {
  { key = "sell", label = L["Sell"] },
  { key = "cancel", label = L["My Auctions"] },
  { key = "shopping", label = L["Shopping"] },
  { key = "scan", label = L["Scan"] },
}
local PATIENT_MARKUP = 1.10 -- Patient = ~10% above the market price (rule to tune)
local FAST_OK_RATIO = 0.85 -- default to Fast only if it isn't >15% under the market price
local POST_TIMEOUT = 10 -- seconds to wait for the auction house to confirm a post

--- The warning when a price is far from normal (SELL-7 / SELL-8): against the 7-day normal, else
--- the market price. Takes the percent, then the reference price. Prices close to normal get no
--- warning: the box only shows when something needs attention.
local FAR_ABOVE = 900 -- % above: from here (10x) the warning says "more than 10x", not a huge percent
-- The most one listing can total: what a character can hold (9,999,999g 99s 99c). Above it nobody
-- could buy it, so Post is off and "You get" shows a dash.
local MAX_LISTING = 99999999999
local YOU_GET_FONT, YOU_GET_SMALL = "GameFontNormalHuge", "GameFontNormalLarge" -- "You get": big, or when too wide
local PRICE_CHECK = {
  normal = {
    below = L["%d%% below its normal price (%s): you may be giving it away."],
    above = L["%d%% above its normal price (%s): this may take a while to sell."],
    farAbove = L["More than 10× its normal price (%s): this may take a while to sell."],
  },
  market = {
    below = L["%d%% below the market price (%s): you may be giving it away."],
    above = L["%d%% above the market price (%s): this may take a while to sell."],
    farAbove = L["More than 10× the market price (%s): this may take a while to sell."],
  },
}

--- What each strategy does: under its button while chosen, and in its tooltip.
local REASONS = {
  fast = function() return GW.FastText() end,
  patient = function() return L["Patient: about 10% above the market price; best posted when supply is low."] end,
}

--- A bag item (all stacks of one item id) in the bag list.
---@class SellBagItem
---@field itemID number
---@field count number how many you have in your bags
---@field loc table ItemLocation of the first stack found
---@field bag number bag of the first stack (for the tooltip)
---@field slot number slot of the first stack
---@field quality number?
---@field icon number? texture file id
---@field hidden boolean? hidden with right-click (GoldwrightDB.ignore)
---@field variant string? GW.LinkVariant of the bag item: its random suffix (#25)
---@field name string
---@field isCommodity boolean commodities post any quantity in one listing; other items one per click
---@field unit number? price Fast would post at, from the data pack (per item, #5)
---@field total number unit * count, for sorting and the footer (0 without price data)

--- Strategy prices for the selected item.
---@class SellPrices
---@field fast number Fast price
---@field patient number Patient price
---@field cheapest number cheapest real listing
---@field marketPrice number? the market price itself
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
---@field bags SellBagItem[] the bag list, in display order
---@field offset number scroll offset into bags
---@field sel SellBagItem? the selected item
---@field stats table? market stats from the live search (GW.MarketStats)
---@field duration number duration index (1 = 2h, 2 = 8h, 3 = 24h)
---@field strategy string? "fast" or "patient"; nil for a price you typed
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
local state = { bags = {}, offset = 0, sel = nil, stats = nil, duration = 3, strategy = nil, prices = nil, live = {} }
GW.activeTab = "sell"

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local UI = GW.UI
local setColor, qualityColor = UI.SetColor, UI.QualityColor
local T -- the look's colours (UI.Tokens), set when the panel is built

--- A colour escape ("|cffrrggbb") for an {r, g, b} colour.
---@param c number[]
---@return string
local function hex(c)
  local function b(v) return math.floor(v * 255 + 0.5) end
  return string.format("|cff%02x%02x%02x", b(c[1]), b(c[2]), b(c[3]))
end

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

--- The normal price the Sell tab compares with: the 7-day average, else the 30-day one.
---@param here table|nil the selling house's entry
---@return number|nil
local function normalPrice(here) return here and (here.avg7 or here.avg30) end

--- The other house you can reach when it really pays more (GW.BetterHouse): Blackwater from your
--- faction's house, your faction's house from Blackwater.
---@param here table|nil the selling house's entry
---@param d table|nil the item's entry for all houses
---@return string|nil side the better house
---@return number|nil gain % more after both cuts
local function betterElsewhere(here, d)
  if not (here and d and GW.Opt("ttBetter")) then return nil end -- the "pays more" hints setting (#24)
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

--- Shows a short message about posting in the listing card.
---@param text string
---@param color number[]? {r, g, b}
local function toast(text, color) UI.Toast(panel, text, color) end

--- Whether the player hid this item from the list (right-click).
---@param itemID number
---@return boolean|nil
local function ignored(itemID) return GoldwrightDB.ignore and GoldwrightDB.ignore[itemID] end

--- "~140" items sold per day (one decimal under 10), "–" when unknown.
---@param here table|nil
---@return string
local function perDayText(here)
  local n = GW.SellRate(here)
  if not n then return "–" end
  return "~" .. (n >= 10 and GW.Number(math.floor(n + 0.5)) or GW.Decimal(n))
end

---------------------------------------------------------------------------
-- your bags (SELL-1, SELL-2)
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

--- The bag list's sort orders, in the order the sort button steps through them (#22).
local SORTS = { "value", "name", "category", "quantity" }
local SORT_LABELS = { value = L["Value"], name = L["Name"], category = L["Category"], quantity = L["Quantity"] }

local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local getClassInfo = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo

--- An item's category name for sorting (the game's item type: Trade Goods, Recipe, Armor...).
---@param itemID number
---@return string
local function categoryOf(itemID)
  local classID = getInstant and select(6, getInstant(itemID))
  local name = classID and getClassInfo and getClassInfo(classID)
  return name or (classID and string.format("~%02d", classID)) or "~~"
end

--- Whether bag item a goes before b in the chosen order. Ties fall back to value, then name.
---@param a table
---@param b table
---@param order string
---@return boolean
local function before(a, b, order)
  if order == "name" then
    if a.name ~= b.name then return a.name < b.name end
  elseif order == "category" then
    local ca, cb = a.category or categoryOf(a.itemID), b.category or categoryOf(b.itemID)
    a.category, b.category = ca, cb
    if ca ~= cb then return ca < cb end
  elseif order == "quantity" then
    if a.count ~= b.count then return a.count > b.count end
  end
  if a.total ~= b.total then return a.total > b.total end
  return a.name < b.name
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
        variant = GW.LinkVariant(info.hyperlink), -- which random suffix (#25)
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
    -- the live Fast price once the item was searched this visit, else the data pack's
    local here = packFor(g.itemID)
    g.unit = state.live[g.itemID] or (here and here.min and GW.UndercutPrice(here.min)) or nil
    g.total = g.unit and g.unit * g.count or 0
  end
  -- Sort in the chosen order (value by default) when the panel opens, then keep that order while
  -- it stays open: posting part of a stack lowers its value, and rows jumping around under the mouse
  -- breaks the post queue's flow. Items new to the bags go to the end. state.rank is cleared each
  -- time the panel opens and when the order changes.
  state.rank = state.rank or {}
  local rank = state.rank
  local order = GW.Opt("bagSort") or "value"
  table.sort(list, function(a, b)
    local ra, rb = rank[a.itemID], rank[b.itemID]
    if ra and rb then return ra < rb end
    if ra or rb then return ra ~= nil end
    return before(a, b, order)
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

--- The chip under a bag item's name: one note, the first that applies (hidden; a vendor pays
--- more; another house pays more; far from normal; bait skipped in the data pack).
---@param g SellBagItem
---@return string|nil text
---@return string|nil kind chip colours: "grey", "blue" or "orange"
local function bagNote(g)
  if g.hidden then return L["hidden"], "grey" end
  local here, d = packFor(g.itemID)
  local vendor = GW.VendorPrice(g.itemID)
  if vendor > 0 and g.unit and GW.Net(sellSide(), g.unit) <= vendor then return L["vendor pays more"], "grey" end
  local other, gain = betterElsewhere(here, d)
  if other then return string.format("%s +%d%%", GW.HOUSE_NAMES[other], gain), "blue" end
  local kind, pct = GW.PriceCheck(g.unit, normalPrice(here))
  if kind == "above" and pct >= FAR_ABOVE then return L["over 10× normal"], "orange" end
  if kind == "above" then return string.format(L["%d%% above normal"], pct), "orange" end
  if kind == "below" then return string.format(L["%d%% below normal"], pct), "orange" end
  if here and here.baitUnits and here.baitUnits > 0 then return L["bait skipped"], "orange" end
  return nil
end

--- Redraws the bag list: rows with price each and a note, the item count, the footer and the
--- hidden-items link.
local function renderBags()
  local total, shown = 0, 0
  for _, g in ipairs(state.bags) do
    if not g.hidden then
      total = total + g.total
      shown = shown + 1
    end
  end
  for i, row in ipairs(panel.rows) do
    local g = state.bags[i + state.offset]
    row.g = g
    if g then
      row:Show()
      row.icon:SetTexture(g.icon or 134400)
      row.icon:SetDesaturated(g.hidden and true or false)
      row.name:SetText(g.count > 1 and string.format("%s  %s×%d|r", g.name, hex(T.faint), g.count) or g.name)
      setColor(row.name, g.hidden and T.faint or qualityColor(g.quality))
      row.value:SetText(g.unit and GW.Money(g.unit, true) or "–")
      UI.SetChip(row.chip, bagNote(g))
      -- one line when there is no note, centred like the price
      row.name:ClearAllPoints()
      if row.chip:IsShown() then
        row.name:SetPoint("TOPLEFT", 46, -5)
      else
        row.name:SetPoint("LEFT", 46, 0)
      end
      local on = state.sel and state.sel.itemID == g.itemID or false
      row.sel:SetShown(on)
      row.bar:SetShown(on)
    else
      row:Hide()
    end
  end
  panel.bagCaption:SetText(L["Your bags"] .. " · " .. GW.PluralCount(shown, "%s item", "%s items"))
  panel.sortButton:SetText(
    string.format(L["|cff8fb0ffSort: %s|r"], SORT_LABELS[GW.Opt("bagSort")] or SORT_LABELS.value)
  )
  panel.bagWorth:SetText(string.format(L["Worth about %s"], GW.Money(total)))
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
-- your listing: strategies, price, what you get (SELL-4..11, 17, 18)
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

--- Sets the line under the strategy buttons (why this price).
---@param text string
local function setWhy(text) panel.why:SetText(text or "") end

--- Puts a price the player chose in the price box (the controller's steps, Gamepad.Adjustable):
--- like a typed one, it is "your own price", not a strategy's.
---@param c number copper
local function setOwnPrice(c)
  state.strategy = nil
  state.typed = true
  setUnitPrice(c) -- the price box's change handler recalculates the receipt
  setWhy(L["Your own price."])
end

--- The price that will be posted: what's in the box, copper included for items too (#8).
---@return number unit copper per item
local function postUnit() return getUnitPrice() end

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

--- Shows the warning box with `text`, or hides it when there is nothing to warn about.
---@param text string
local function setWarning(text)
  panel.warn:SetText(text)
  if text == "" then
    panel.warnBox:Hide()
  else
    panel.warnBox:SetHeight(math.floor((panel.warn:GetStringHeight() or 12) + 14.5))
    panel.warnBox:Show()
  end
end

--- Redraws the listing card for the current price, quantity and duration: strategy buttons, what
--- you get (after the cut), the deposit, the time to sell, the warning and the Post button.
local function recalc()
  local g = state.sel
  if not g then return end
  local qty, unit = quantity(), postUnit()

  -- Strategy buttons show their price each.
  local P = state.prices
  for _, b in ipairs(panel.stratButtons) do
    local p = P and P[b.key]
    if p then
      b:SetText(string.format("%s\n%s", b.label, GW.Money(p)))
      b:Enable()
    else
      b:SetText(b.label)
      b:Disable()
    end
    UI.SetSelected(b, state.strategy == b.key)
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
  panel.youGetLabel:SetText(string.format(L["You get, after the %d%% cut"], math.floor(sellCut() * 100 + 0.5)))
  local tooHigh = unit * qty > MAX_LISTING
  -- big font; one size smaller when a large amount doesn't fit the card
  panel.youGet:SetFontObject(YOU_GET_FONT)
  panel.youGet:SetText(tooHigh and "—" or GW.Money(youReceive(unit, qty)))
  if panel.youGet:GetStringWidth() > panel.youGetWidth then panel.youGet:SetFontObject(YOU_GET_SMALL) end
  UI.SetColor(panel.youGet, T.text)
  panel.deposit:SetText(string.format(L["Deposit %s, back when it sells"], deposit and GW.Money(deposit) or "?"))

  -- How many other players' units are listed cheaper than this price: buyers take those first (a
  -- new listing goes first among its own price). A count, not a forecast: others keep posting.
  local here = packFor(g.itemID)
  local cheaper
  if state.stats and unit > 0 then
    cheaper = 0
    for _, l in ipairs(state.stats.sorted) do
      if not l.own and l.price < unit then cheaper = cheaper + l.qty end
    end
  end
  -- too slow for the auction: more listed at or below this price than usually sells in its time
  local hours = GW.TimeToSell(state.stats and state.stats.sorted, unit, qty, (GW.SellRate(here)))
  local auctionHours = GW.DURATION_HOURS[state.duration]
  local tooSlow = hours and auctionHours and hours > auctionHours
  panel.sellTime:SetText(
    not cheaper and ""
      or cheaper == 0 and L["Nothing listed cheaper than you"]
      or string.format(L["%s listed cheaper than you"], GW.Number(cheaper))
  )
  setColor(panel.sellTime, tooSlow and GW.SIGNAL_ORANGE or T.faint)

  -- The warning (SELL-7 / SELL-8): far from the 7-day normal (else the market price), a vendor
  -- paying more, or too slow for the auction's duration.
  local ref, messages = normalPrice(here), PRICE_CHECK.normal
  if not ref then
    ref, messages = (state.stats and state.stats.mv) or (here and here.mv), PRICE_CHECK.market
  end
  local warn = ""
  local kind, pct = GW.PriceCheck(unit, ref)
  if kind == "above" and pct >= FAR_ABOVE then
    warn = string.format(messages.farAbove, GW.Money(ref))
  elseif kind == "below" or kind == "above" then
    warn = string.format(messages[kind], pct, GW.Money(ref))
  end
  local vendor = GW.VendorPrice(g.itemID)
  if vendor > 0 and unit > 0 and GW.Net(sellSide(), unit) <= vendor then
    warn =
      string.format(L["A vendor pays %s each, more than you'd net here. Sell to a vendor instead."], GW.Money(vendor))
  end
  if tooSlow and warn == "" then
    warn = string.format(
      L["At this price it may not all sell within the %d h auction: a lower price or fewer at a time."],
      auctionHours
    )
  end
  if tooHigh then
    warn = string.format(L["Too high: one listing can't be more than %s in total."], GW.Money(MAX_LISTING))
  end
  setWarning(warn)

  -- Only data-pack prices so far (live listings still loading): wait, unless the player typed a price.
  local loading = state.searching and not state.stats and not state.typed
  local p = state.pending
  local confirmWait = p and p.warning and GetTime() - (p.warnedAt or 0) < GW.CONFIRM_DELAY
  panel.post:SetText(
    loading and L["Getting live prices…"]
      or p and p.warning and string.format(L["Confirm: %s"], postLabel(g, qty))
      or postLabel(g, qty)
  )
  panel.post:SetEnabled(
    unit > 0 and not tooHigh and not loading and not confirmWait and (not p or p.warning) and true or false
  )
end

--- Sets state.prices for the selected item from live listings (or the data pack while they load);
--- nil when there is no price at all.
local function computePrices()
  local g, s = state.sel, state.stats
  local cheapest, market, own
  if s then
    local first = s.sorted[s.firstRealIndex]
    cheapest, market, own = first.price, s.mv, first.own
  else
    local here = packFor(g.itemID)
    if here then
      cheapest, market = here.min, here.mv
    end
  end
  if not cheapest then
    state.prices = nil
    return
  end
  local fast = GW.UndercutPrice(cheapest, own)
  -- Patient: ~10% above the market price, never under it and always above Fast
  local ref = market or cheapest
  local patient = math.max(fast + 1, ref, math.floor(ref * PATIENT_MARKUP + 0.5))
  state.prices = { fast = fast, patient = patient, cheapest = cheapest, marketPrice = market, own = own }
end

--- Selects a strategy, puts its price in the box and shows why.
---@param key string "fast" or "patient"
---@param reason string? text for the line under the buttons
local function chooseStrategy(key, reason)
  state.strategy = key
  state.typed = nil
  local p = state.prices and state.prices[key]
  if p then setUnitPrice(p) end
  setWhy(reason)
  recalc()
end

--- Works out the prices and picks the default strategy: Fast, unless selling fast would net less
--- than a vendor pays or be more than 15% under the market price (then Patient).
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
    setWhy(
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
  -- Judge the price Fast would post, not the cheapest listing, and never default to netting less
  -- than a vendor pays.
  local vendor = GW.VendorPrice(state.sel.itemID)
  local fastBelowVendor = vendor > 0 and GW.Net(sellSide(), P.fast) <= vendor and GW.Net(sellSide(), P.patient) > vendor
  if P.own then
    chooseStrategy("fast", loading .. L["Your own listing is already the cheapest; matching it."] .. bait)
  elseif fastBelowVendor then
    chooseStrategy(
      "patient",
      loading
        .. string.format(L["Patient chosen: Fast would net less than a vendor pays (%s)."], GW.Money(vendor))
        .. bait
    )
  elseif P.marketPrice and P.fast < P.marketPrice * FAST_OK_RATIO then
    chooseStrategy(
      "patient",
      loading
        .. string.format(
          L["Patient chosen: Fast would be %d%% under the market price."],
          math.floor((1 - P.fast / P.marketPrice) * 100 + 0.5)
        )
        .. bait
    )
  else
    chooseStrategy("fast", loading .. GW.FastText(GW.Money(P.cheapest)) .. bait)
  end
end

---------------------------------------------------------------------------
-- the market card (SELL-3, 15, 16)
---------------------------------------------------------------------------
--- The note a cheapest-listings row carries (its tooltip and its colour).
---@param s table market stats
---@param i number row index
---@return string|nil note
---@return number[] color price colour
local function ladderNote(s, i)
  local x = s.sorted[i]
  if i < s.firstRealIndex then return L["likely bait, skipped"], T.faint end
  if x.own then return L["yours"], T.gold end
  if i == s.firstRealIndex then return L["cheapest real seller"], T.text end
  return nil, T.text
end

--- Redraws the market card's numbers: Lowest now, Normal (last 7 days), Sold per day, and the
--- cheapest listings with their quantities and the total listed (#11).
local function renderMarket()
  local g, s = state.sel, state.stats
  if not g then return end
  local here = packFor(g.itemID)
  local lowest = (s and s.sorted[s.firstRealIndex].price) or (here and here.min)
  panel.lowest:SetText(lowest and GW.Money(lowest) or "–")
  panel.normal:SetText(here and here.avg7 and GW.Money(here.avg7) or "–")
  panel.perDay:SetText(perDayText(here))
  -- what the number counts, and whether it is an estimate (gear: listings gone early)
  local n, proven = GW.SellRate(here)
  panel.perDayHit.tip = not n and { L["No sales data for this item yet."] }
    or {
      string.format(L["Items bought per day at %s, average of the last 10 days."], GW.HOUSE_NAMES[sellSide()]),
      not proven and L["Estimate: counts listings that went early, so some may have been cancelled."] or nil,
    }

  local maxQty, total = 1, 0
  if s then
    for i, x in ipairs(s.sorted) do
      total = total + x.qty
      if i <= LADDER_ROWS and x.qty > maxQty then maxQty = x.qty end
    end
  end
  for i, r in ipairs(panel.ladder) do
    local x = s and s.sorted[i]
    if x then
      local note, color = ladderNote(s, i)
      r.note = note
      r.price:SetText(GW.Money(x.price, true))
      setColor(r.price, color)
      r.qty:SetText(GW.Number(x.qty))
      UI.SetBar(r.bar, x.qty / maxQty)
      r:Show()
    else
      r.note = nil
      r:Hide()
    end
  end
  panel.listTotal:SetText(s and GW.PluralCount(total, "%s listed", "%s listed") or "")
end

---------------------------------------------------------------------------
-- search
---------------------------------------------------------------------------
--- Listings for an item from the last search, commodity results first, else item results.
--- Shared with the My Auctions tab.
---@param itemID number
---@param itemKey table? item key for item (non-commodity) results
---@param variant string? GW.LinkVariant of the item being priced: item rows of another random suffix
--- are left out. A search (Blizzard's Sell window's above all) can return every suffix of the item,
--- and they share one item id (goldwright-addon #25). "" or nil keeps every row.
---@return { price: number, qty: number, own: boolean?, ownQty: number? }[] list price is per unit
---@return string|nil source "commodity", "item" or nil when empty
---@return number commodityCount number of commodity results the client reported
---@return number itemCount number of item results the client reported
function GW.CollectSearchResults(itemID, itemKey, variant)
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
  -- Item (non-commodity) results group identical auctions into one row: `quantity` is how many
  -- there are and `buyoutAmount` the price of each, not of the row (goldwright-addon #5: dividing
  -- by the count turned 31 Expert Cookbooks at 94s 99c into "3s 6c each"). Only an item that
  -- stacks would carry a whole-stack buyout; on this auction house those are commodities.
  local ni = itemKey and (C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0) or 0
  local stacks = itemKey and GW.MaxStack and (GW.MaxStack(itemKey.itemID) or 1) > 1
  local other = 0
  for i = 1, ni do
    local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if r and r.buyoutAmount and (r.quantity or 0) > 0 then
      local rv = variant and variant ~= "" and r.itemLink and GW.LinkVariant(r.itemLink)
      if rv and rv ~= variant then
        other = other + r.quantity -- another suffix of the item
      else
        local each = stacks and math.floor(r.buyoutAmount / r.quantity + 0.5) or r.buyoutAmount
        list[#list + 1] = { price = each, qty = r.quantity, own = r.containsOwnerItem }
      end
    end
  end
  if other > 0 then GW.Log("left out %d listings of other suffixes (item %s, %s)", other, tostring(itemID), variant) end
  return list, #list > 0 and "item" or nil, nc, ni
end

--- Reads the selected item's search results into state.stats and redraws. An empty result while the
--- search is still running is ignored (no answer yet).
---@param itemKeyFromEvent table? the item key an item-results event carried
---@param eventName string? for the log
local function readResults(itemKeyFromEvent, eventName)
  local g = state.sel
  if not g then return end
  local list, source, nc, ni = GW.CollectSearchResults(g.itemID, itemKeyFromEvent or state.key, g.variant)
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
  local recent = GW.RecentPrice(g.itemID, sellSide())
  state.stats = GW.MarketStats(list, recent)
  GW.SellCharts.Listings(g.itemID, state.stats) -- the Market window's Supply tab
  GW.NoteBaitSearch(g.itemID, g.name, sellSide(), state.stats, recent)
  panel.listStatus:SetText(state.stats and L["searched just now"] or L["no other listings"])
  renderMarket()
  applyDefaultStrategy()
  -- the bag row follows the live price too, so its note and the listing's warning agree
  if state.stats and state.prices then
    state.live[g.itemID] = state.prices.fast
    g.unit, g.total = state.prices.fast, state.prices.fast * g.count
    renderBags()
  end
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

--- Redraws the status bar (AH-2): house, how old the prices are (in orange when the data pack is
--- missing or old, AH-3) and the last full scan; on the Sell tab, its one hint on the right.
local function renderStatus()
  local h = GW.House()
  local pack = GW.Pack()
  local days = GW.PackAgeDays()
  local packText
  if not pack then
    packText = hex(GW.SIGNAL_ORANGE)
      .. string.format(L["No data pack for %s %s: prices come from live listings only"], h.region, h.ruleset)
      .. "|r"
  elseif days and days > GW.STALE_DAYS then
    packText = hex(GW.SIGNAL_ORANGE)
      .. GW.Plural(
        math.floor(days),
        "Data pack is %d day old: update Goldwright Data",
        "Data pack is %d days old: update Goldwright Data"
      )
      .. "|r"
  else
    packText = string.format(L["Prices updated %s"], GW.Age(pack.snapshotAt))
  end
  local scanText = GW.LastScanText and GW.LastScanText(sellSide())
  panel.status:SetText(
    string.format(
      "%s · %s · %s     %s     %s",
      h.region,
      h.ruleset,
      GW.HOUSE_NAMES[sellSide()],
      packText,
      scanText and string.format(L["Last scan %s"], scanText) or L["No full scan yet"]
    )
  )
  panel.hint:SetText(GW.activeTab == "sell" and L["Click an item to price it · right-click to hide it"] or "")
end

--- Sets the auction duration and highlights its button.
---@param idx number 1 = 2h, 2 = 8h, 3 = 24h
local function setDuration(idx)
  state.duration = idx
  for _, b in ipairs(panel.durButtons) do
    UI.SetSelected(b, b.idx == idx)
  end
end

--- Deselects the item, stops its search timers and shows a message in the market card instead.
---@param message string? text to show (default: "Choose an item on the left...")
local function clearSelection(message)
  state.sel, state.stats, state.strategy, state.token = nil, nil, nil, (state.token or 0) + 1
  panel.col2:Hide()
  panel.col3:Hide()
  panel.empty:SetText(message or L["Choose an item on the left to see its market and price it."])
  panel.empty:Show()
  renderBags()
end

--- Selects a bag item: fills the market and listing cards, restores its remembered duration, draws
--- its chart and starts its search.
---@param g SellBagItem
local function selectItem(g)
  state.sel = g
  state.stats = nil
  state.strategy = nil
  state.typed = nil
  panel.iconButton.tex:SetTexture(g.icon or 134400)
  panel.itemName:SetText(g.name)
  setColor(panel.itemName, qualityColor(g.quality))
  panel.itemInfo:SetText(
    string.format(
      L["You have %d · %s"],
      g.count,
      g.isCommodity and L["posts as one listing"] or L["one auction per click"]
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
  toast("")
  panel.col2:Show()
  panel.col3:Show()
  panel.empty:Hide()
  GW.SellCharts.Render(g.itemID, g.name)
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
  if not GW.ReadableText(message) then return false end
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
    local message, color = panel.toast:GetText(), { panel.toast:GetTextColor() }
    selectItem(nextItem)
    toast(message, color) -- "Posted …" stays while the next item loads
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
  if p and not p.warning then return toast(L["Waiting for the auction house…"], T.muted) end
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
    toast(L["Confirmed. Waiting for the auction house…"], T.muted)
    recalc()
    return
  end

  local unit, qty = postUnit(), quantity()
  if unit <= 0 then return toast(L["Set a price first."], GW.SIGNAL_ORANGE) end
  if unit * qty > MAX_LISTING then return end -- the warning says why
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
  GW.NoteBaitPost(g.itemID, sellSide(), unit)
  toast(L["Posting…"], T.muted)
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
--- Tabs that work away from the auction house (the rest are greyed out there, with a tooltip).
local ANYWHERE = { shopping = true }

--- Enables each tab button: all at the auction house, only ANYWHERE tabs elsewhere.
local function updateTabs()
  local atAH = GW.AuctionHouseOpen and GW.AuctionHouseOpen()
  for _, b in ipairs(panel.tabButtons) do
    b:SetEnabled(atAH or ANYWHERE[b.key] or false)
  end
end

--- Switches the panel to a tab and shows or hides each tab's view. Away from the auction house only
--- the ANYWHERE tabs open.
---@param key string "sell", "cancel", "shopping" or "scan"
local function showTab(key)
  if not ANYWHERE[key] and not (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) then key = "shopping" end
  updateTabs()
  GW.activeTab = key
  for _, b in ipairs(panel.tabButtons) do
    UI.SetSelected(b, b.key == key)
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
  renderStatus()
  if key == "sell" then
    scanBags()
    renderBags()
    if state.sel then recalc() end
  end
end

--- The next open tab to the left (-1) or right (1) of the current one, wrapping around; tabs that
--- don't work here (away from the auction house) are skipped. For the controller's LB / RB.
---@param dir number -1 or 1
local function stepTab(dir)
  local n = #panel.tabButtons
  local at = 1
  for i, b in ipairs(panel.tabButtons) do
    if b.key == GW.activeTab then at = i end
  end
  for k = 1, n - 1 do
    local b = panel.tabButtons[(at - 1 + dir * k) % n + 1]
    if b:IsEnabled() then return showTab(b.key) end
  end
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------
--- Builds the window frame: in the Blizzard look (and ElvUI's or EllesmereUI's) the game's title bar
--- with the tabs under it; in Goldwright dark one header row with the coin, the tabs, Sales,
--- Settings and the X. Returns the y offset where the content starts.
---@return number top offset from the window's top to the content (negative)
local function buildFrame()
  panel = UI.Window("GoldwrightSellFrame", W, H, { title = "Goldwright", movable = true })
  GW.panel = panel
  local dark = UI.LookName() == "dark"

  local tabX, tabY, tabH = 12, -27, 24
  if dark then
    local title = panel.TitleText or (type(panel.TitleContainer) == "table" and panel.TitleContainer.TitleText)
    if type(title) == "table" and title.Hide then title:Hide() end
    local coin = panel:CreateTexture(nil, "ARTWORK")
    coin:SetSize(16, 16)
    coin:SetPoint("TOPLEFT", 14, -12)
    coin:SetTexture(GW.ICON)
    coin:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local brand = UI.Text(panel, "GameFontNormal", "gold", "LEFT")
    brand:SetPoint("LEFT", coin, "RIGHT", 7, 0)
    brand:SetText("Goldwright")
    local rule = UI.Rule(panel)
    rule:SetPoint("TOPLEFT", 1, -38)
    rule:SetPoint("TOPRIGHT", -1, -38)
    rule:SetHeight(1)
    if panel.CloseButton then
      panel.CloseButton:ClearAllPoints()
      panel.CloseButton:SetPoint("TOPRIGHT", -8, -8)
    end
    tabX, tabY, tabH = 128, -7, 26
  end

  panel.tabButtons = {}
  local prev
  for i, t in ipairs(TABS) do
    local b = UI.WindowTab(panel, t.label, tabH, function() showTab(t.key) end)
    b.key = t.key
    if i == 1 then
      b:SetPoint("TOPLEFT", tabX, tabY)
    else
      b:SetPoint("LEFT", prev, "RIGHT", dark and 2 or 4, 0)
    end
    -- greyed out away from the auction house: say why
    if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
    b:SetScript("OnEnter", function(self)
      if self:IsEnabled() then return end
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:SetText(L["Open the auction house to use this tab."])
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    panel.tabButtons[i] = b
    prev = b
  end
  local gear = UI.Button(panel, L["Settings"], 84, 20, function()
    if GW.OpenSettings then GW.OpenSettings() end
  end)
  gear:SetPoint("TOPRIGHT", dark and -38 or -12, dark and -9 or -29)
  -- Your sales record has its own window (SalesView.lua): it doesn't need the auction house.
  local sales = UI.Button(panel, L["Sales"], 70, 20, function()
    if GW.OpenSales then GW.OpenSales() end
  end)
  sales:SetPoint("RIGHT", gear, "LEFT", -4, 0)
  panel.salesButton = sales
  -- With a controller, LB / RB switch tabs while the window is open.
  panel.stepTab = stepTab
  if GW.Gamepad and GW.Gamepad.Tabs then GW.Gamepad.Tabs(panel, stepTab) end

  panel.status = UI.Text(panel, "GameFontDisableSmall", "faint", "LEFT")
  panel.status:SetPoint("BOTTOMLEFT", 14, 9)
  panel.hint = UI.Text(panel, "GameFontDisableSmall", "faint", "RIGHT")
  panel.hint:SetPoint("BOTTOMRIGHT", -14, 9)
  return dark and -42 or -54
end

--- Builds the bags card: caption and count, the rows, the footer and the hidden-items link.
---@param view table the Sell view
local function buildBags(view)
  local card = UI.Card(view)
  card:SetPoint("TOPLEFT", 6, -6)
  card:SetPoint("BOTTOMLEFT", 6, 6)
  card:SetWidth(BAGS_W)
  panel.bagCaption = UI.Caption(card, L["Your bags"], 12, -10)
  -- The sort order (#22): each click steps to the next order; the list is re-sorted at once.
  panel.sortButton = CreateFrame("Button", nil, card)
  panel.sortButton:SetSize(110, 16)
  panel.sortButton:SetPoint("TOPRIGHT", -10, -10)
  panel.sortButton:SetNormalFontObject("GameFontHighlightSmall")
  panel.sortButton:SetText(" ")
  panel.sortButton:GetFontString():SetJustifyH("RIGHT")
  panel.sortButton:GetFontString():SetPoint("RIGHT")
  UI.HoverTip(panel.sortButton, L["Order of your bags: value, name, category or quantity. Click for the next."])
  panel.sortButton:SetScript("OnClick", function()
    local cur = GW.Opt("bagSort") or "value"
    local nextOrder = SORTS[1]
    for i, k in ipairs(SORTS) do
      if k == cur then nextOrder = SORTS[i % #SORTS + 1] end
    end
    GW.SetOpt("bagSort", nextOrder)
    state.rank, state.offset = nil, 0
    scanBags()
    renderBags()
  end)

  panel.rows = {}
  local list = CreateFrame("Frame", nil, card)
  list:SetPoint("TOPLEFT", 1, -30)
  list:SetSize(BAGS_W - 2, ROWS * ROW_H)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    state.offset = math.max(0, math.min(state.offset - delta, math.max(0, #state.bags - ROWS)))
    renderBags()
  end)
  for i = 1, ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetSize(BAGS_W - 2, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local line = UI.Rule(row, "rowLine")
    line:SetPoint("TOPLEFT")
    line:SetPoint("TOPRIGHT")
    line:SetHeight(1)
    local lit = row:CreateTexture(nil, "HIGHLIGHT")
    lit:SetAllPoints()
    lit:SetColorTexture(T.hover[1], T.hover[2], T.hover[3], T.hover[4])
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(T.selected[1], T.selected[2], T.selected[3], T.selected[4])
    row.sel:Hide()
    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.bar:SetPoint("TOPLEFT")
    row.bar:SetPoint("BOTTOMLEFT")
    row.bar:SetWidth(2)
    row.bar:SetColorTexture(T.gold[1], T.gold[2], T.gold[3], 1)
    row.bar:Hide()
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(28, 28)
    row.icon:SetPoint("LEFT", 10, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = UI.FontString(row, "GameFontHighlight", "LEFT")
    row.name:SetPoint("TOPLEFT", 46, -5)
    row.name:SetWidth(BAGS_W - 46 - 78)
    row.name:SetWordWrap(false)
    row.chip = UI.Chip(row)
    row.chip:SetPoint("TOPLEFT", 46, -21)
    row.value = UI.Text(row, "GameFontHighlightSmall", "muted", "RIGHT")
    row.value:SetPoint("RIGHT", -10, 0)
    row.value:SetWidth(74)
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

  local foot = UI.Rule(card)
  foot:SetPoint("BOTTOMLEFT", 1, 44)
  foot:SetPoint("BOTTOMRIGHT", -1, 44)
  foot:SetHeight(1)
  panel.bagWorth = UI.Text(card, "GameFontHighlightSmall", "faint", "LEFT")
  panel.bagWorth:SetPoint("BOTTOMLEFT", 12, 26)
  local each = UI.Text(card, "GameFontHighlightSmall", "faint", "RIGHT")
  each:SetPoint("BOTTOMRIGHT", -12, 26)
  each:SetText(L["price each"])
  panel.hiddenLink = CreateFrame("Button", nil, card)
  panel.hiddenLink:SetSize(150, 16)
  panel.hiddenLink:SetPoint("BOTTOMLEFT", 10, 6)
  panel.hiddenLink:SetNormalFontObject("GameFontHighlightSmall")
  panel.hiddenLink:SetText(" ")
  panel.hiddenLink:GetFontString():SetJustifyH("LEFT")
  panel.hiddenLink:GetFontString():SetPoint("LEFT")
  panel.hiddenLink:SetScript("OnClick", function()
    state.showHidden = not state.showHidden
    scanBags()
    renderBags()
  end)
end

--- Builds the market card: the item and its three numbers, the chart, and the cheapest listings.
---@param card table
local function buildMarket(card)
  local col2 = CreateFrame("Frame", nil, card)
  col2:SetAllPoints()
  panel.col2 = col2
  local width = W - 16 - BAGS_W - 20 -- the card's width
  local split = width - 238 -- chart | cheapest listings

  panel.iconButton = CreateFrame("Button", nil, col2)
  panel.iconButton:SetSize(36, 36)
  panel.iconButton:SetPoint("TOPLEFT", 12, -11)
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
  panel.itemName = UI.FontString(col2, "GameFontNormalLarge", "LEFT")
  panel.itemName:SetPoint("TOPLEFT", 58, -12)
  panel.itemName:SetWidth(300)
  panel.itemName:SetWordWrap(false)
  panel.itemInfo = UI.Text(col2, "GameFontHighlightSmall", "muted", "LEFT")
  panel.itemInfo:SetPoint("TOPLEFT", 58, -32)

  -- three numbers, each a label over one big value
  local stats = {
    { L["Lowest now"], "lowest", 100 },
    { L["Normal, last 7 days"], "normal", 124 },
    { L["Sold per day"], "perDay", 84 },
  }
  local x = width - 12
  for i = #stats, 1, -1 do
    local s = stats[i]
    x = x - s[3]
    local lab = UI.Text(col2, "GameFontNormalSmall", "label", "LEFT")
    lab:SetPoint("TOPLEFT", x, -12)
    lab:SetText(s[1])
    local val = UI.Text(col2, "GameFontHighlightLarge", "text", "LEFT")
    val:SetPoint("TOPLEFT", x, -28)
    panel[s[2]] = val
    x = x - 8
  end
  -- hovering Sold per day says what it counts (renderMarket fills .tip)
  local hit = CreateFrame("Frame", nil, col2)
  hit:SetPoint("TOPLEFT", panel.perDay, "TOPLEFT", 0, 18)
  hit:SetSize(84, 44)
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", function(self)
    if not self.tip then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(L["Sold per day"], 1, 1, 1)
    for _, line in ipairs(self.tip) do
      GameTooltip:AddLine(line, nil, nil, nil, true)
    end
    GameTooltip:Show()
  end)
  hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.perDayHit = hit
  local rule = UI.Rule(col2)
  rule:SetPoint("TOPLEFT", 1, -58)
  rule:SetPoint("TOPRIGHT", -1, -58)
  rule:SetHeight(1)
  local v = UI.Rule(col2)
  v:SetPoint("TOPLEFT", split, -58)
  v:SetPoint("BOTTOMLEFT", split, 1)
  v:SetWidth(1)

  -- the chart: price history or best time to post (SellCharts.lua)
  GW.SellCharts.Create(col2, { x = 12, y = -68, w = split - 24, h = MARKET_H - 68 - 6 })
  panel.charts = GW.SellCharts

  -- cheapest listings: price each | quantity bar | quantity
  local lx = split + 12
  local lw = width - lx - 12
  UI.Caption(col2, L["Cheapest listings"], lx, -71)
  panel.ladder = {}
  for i = 1, LADDER_ROWS do
    local r = CreateFrame("Frame", nil, col2)
    r:SetSize(lw, LADDER_H)
    r:SetPoint("TOPLEFT", lx, -92 - (i - 1) * LADDER_H)
    r:EnableMouse(true)
    local line = UI.Rule(r, "rowLine")
    line:SetPoint("TOPLEFT")
    line:SetPoint("TOPRIGHT")
    line:SetHeight(1)
    r.price = UI.FontString(r, "GameFontHighlightSmall", "RIGHT")
    r.price:SetPoint("LEFT", 0, 0)
    r.price:SetWidth(78)
    r.bar = UI.Bar(r, lw - 78 - 8 - 40, 6)
    r.bar:SetPoint("LEFT", 86, 0)
    r.qty = UI.Text(r, "GameFontHighlightSmall", "muted", "RIGHT")
    r.qty:SetPoint("RIGHT", 0, 0)
    r.qty:SetWidth(38)
    r:SetScript("OnEnter", function(self)
      if not self.note then return end
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetText(self.note)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:Hide()
    panel.ladder[i] = r
  end
  local y = -92 - LADDER_ROWS * LADDER_H - 6
  panel.listTotal = UI.Text(col2, "GameFontHighlightSmall", "muted", "LEFT")
  panel.listTotal:SetPoint("TOPLEFT", lx, y)
  panel.listStatus = UI.Text(col2, "GameFontDisableSmall", "faint", "RIGHT")
  panel.listStatus:SetPoint("TOPRIGHT", col2, "TOPLEFT", lx + lw, y)
end

--- Builds the listing card: strategies and the warning | price, quantity, duration | what you get
--- and Post.
---@param card table
local function buildListing(card)
  local col3 = CreateFrame("Frame", nil, card)
  col3:SetAllPoints()
  panel.col3 = col3
  local width = W - 16 - BAGS_W - 20
  local aW, bW = 262, 238 -- column widths; the third takes the rest

  -- strategies
  UI.Caption(col3, L["Your listing"], 12, -10)
  panel.stratButtons = {}
  for i, st in ipairs(STRATEGIES) do
    local b = UI.NewButton(col3)
    b:SetSize(118, 38)
    b:SetPoint("TOPLEFT", 12 + (i - 1) * 122, -30)
    if not UI.Skinned() then -- the game's button: a smaller font, so two lines and longer names fit
      b:SetNormalFontObject("GameFontNormalSmall")
      b:SetHighlightFontObject("GameFontHighlightSmall")
      b:SetDisabledFontObject("GameFontDisableSmall")
    end
    b.key, b.label = st.key, st.label
    b:SetText(st.label)
    b:SetScript("OnClick", function() chooseStrategy(st.key, REASONS[st.key]()) end)
    if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(REASONS[st.key](), 1, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    panel.stratButtons[i] = b
  end
  panel.why = UI.Text(col3, "GameFontHighlightSmall", "muted", "LEFT")
  panel.why:SetPoint("TOPLEFT", 12, -74)
  panel.why:SetWidth(aW - 22)
  panel.warnBox = UI.Flat(CreateFrame("Frame", nil, col3), T.warnBg, T.warnBorder)
  panel.warnBox:SetPoint("TOPLEFT", panel.why, "BOTTOMLEFT", 0, -6)
  panel.warnBox:SetWidth(aW - 22)
  panel.warn = UI.Text(panel.warnBox, "GameFontHighlightSmall", "warnText", "LEFT")
  panel.warn:SetPoint("TOPLEFT", 8, -7)
  panel.warn:SetWidth(aW - 38)
  panel.warnBox:Hide()

  -- price, quantity, duration
  local v1 = UI.Rule(col3)
  v1:SetPoint("TOPLEFT", aW, -1)
  v1:SetPoint("BOTTOMLEFT", aW, 1)
  v1:SetWidth(1)
  local bx = aW + 12
  local pl = UI.Text(col3, "GameFontNormalSmall", "label", "LEFT")
  pl:SetPoint("TOPLEFT", bx, -12)
  pl:SetText(L["Price each"])
  if MoneyInputFrame_SetCopper and MoneyInputFrame_GetCopper then
    panel.money = CreateFrame("Frame", "GoldwrightSellPrice", col3, "MoneyInputFrameTemplate")
    UI.SkinMoney("GoldwrightSellPrice")
    panel.money:SetPoint("TOPLEFT", bx + 4, -28)
    if MoneyInputFrame_SetOnValueChangedFunc then
      MoneyInputFrame_SetOnValueChangedFunc(panel.money, function()
        -- The money boxes report changes a moment after we set them, so only a price that differs
        -- from the chosen strategy's is the player's own.
        local chosen = state.strategy and state.prices and state.prices[state.strategy]
        if not state.settingPrice and getUnitPrice() ~= chosen and getUnitPrice() > 0 then
          state.strategy = nil
          state.typed = true
          setWhy(L["Your own price."])
        end
        recalc()
      end)
    end
  else
    panel.copperBox = UI.NewEditBox(col3)
    panel.copperBox:SetSize(120, 22)
    panel.copperBox:SetPoint("TOPLEFT", bx + 6, -28)
    panel.copperBox:SetAutoFocus(false)
    panel.copperBox:SetScript("OnTextChanged", function(_, userInput)
      if userInput then
        state.strategy = nil
        state.typed = true
      end
      recalc()
    end)
  end

  -- With a controller: A on a coin box, then left / right changes the price by 1 gold, silver or
  -- copper (held: faster), A keeps it, B puts the old price back (Gamepad.Adjustable).
  if GW.Gamepad then
    local coins = panel.money
        and {
          { _G.GoldwrightSellPriceGold, 10000 },
          { _G.GoldwrightSellPriceSilver, 100 },
          { _G.GoldwrightSellPriceCopper, 1 },
        }
      or { { panel.copperBox, 1 } }
    for _, c in ipairs(coins) do
      if c[1] then
        GW.Gamepad.Adjustable(c[1], {
          get = getUnitPrice,
          set = setOwnPrice,
          step = c[2],
          min = function() return 1 end,
          enabled = function() return state.sel ~= nil end,
        })
      end
    end
  end

  local ql = UI.Text(col3, "GameFontNormalSmall", "label", "LEFT")
  ql:SetPoint("TOPLEFT", bx, -62)
  ql:SetText(L["Quantity"])
  panel.qty = UI.NewEditBox(col3)
  panel.qty:SetSize(46, 20)
  panel.qty:SetPoint("TOPLEFT", bx + 6, -78)
  panel.qty:SetAutoFocus(false)
  panel.qty:SetNumeric(true)
  panel.qty:SetMaxLetters(5)
  panel.qty:SetScript("OnTextChanged", function(self, userInput)
    -- more than you have: the box shows what you have (that is what posts)
    local n, g = tonumber(self:GetText()), state.sel
    if userInput and n and g and g.isCommodity and n > g.count then
      self:SetText(tostring(g.count))
      return -- SetText runs this again
    end
    recalc()
  end)
  panel.qty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  if GW.Gamepad then
    GW.Gamepad.Adjustable(panel.qty, {
      get = function() return tonumber(panel.qty:GetText()) or 1 end,
      set = function(n) panel.qty:SetText(tostring(n)) end,
      step = 1,
      min = function() return 1 end,
      max = function() return state.sel and state.sel.count or 1 end,
      enabled = function() return state.sel ~= nil and panel.qty:IsEnabled() end,
    })
  end
  panel.allButton = UI.Button(col3, L["All"], 38, 20)
  panel.allButton:SetPoint("LEFT", panel.qty, "RIGHT", 6, 0)
  panel.allButton:SetScript("OnClick", function()
    if state.sel then panel.qty:SetText(tostring(state.sel.count)) end
  end)

  local dx = bx + 108
  local dl = UI.Text(col3, "GameFontNormalSmall", "label", "LEFT")
  dl:SetPoint("TOPLEFT", dx, -62)
  dl:SetText(L["Duration"])
  panel.durButtons = {}
  for i, d in ipairs(DURATIONS) do
    local b = UI.ToggleButton(col3, d.label, 36, 20)
    b.idx = d.idx
    b:SetPoint("TOPLEFT", dx + (i - 1) * 39, -78)
    b:SetScript("OnClick", function()
      setDuration(d.idx)
      recalc()
    end)
    panel.durButtons[i] = b
  end
  setDuration(GW.Opt("duration"))

  panel.toast = UI.Text(col3, "GameFontHighlightSmall", "muted", "LEFT")
  panel.toast:SetPoint("TOPLEFT", bx, -112)
  panel.toast:SetWidth(bW - 24)

  -- what you get, and Post
  local v2 = UI.Rule(col3)
  v2:SetPoint("TOPLEFT", aW + bW, -1)
  v2:SetPoint("BOTTOMLEFT", aW + bW, 1)
  v2:SetWidth(1)
  local cx = aW + bW + 12
  local cW = width - cx - 12
  panel.youGetLabel = UI.Text(col3, "GameFontNormalSmall", "label", "LEFT")
  panel.youGetLabel:SetPoint("TOPLEFT", cx, -12)
  panel.youGet = UI.Text(col3, YOU_GET_FONT, "text", "LEFT")
  panel.youGet:SetPoint("TOPLEFT", cx, -29)
  panel.youGetWidth = cW
  panel.deposit = UI.Text(col3, "GameFontHighlightSmall", "faint", "LEFT")
  panel.deposit:SetPoint("TOPLEFT", cx, -58)
  panel.deposit:SetWidth(cW)
  panel.sellTime = UI.Text(col3, "GameFontHighlightSmall", "faint", "LEFT")
  panel.sellTime:SetPoint("TOPLEFT", cx, -73)
  panel.sellTime:SetWidth(cW)
  panel.post = UI.PrimaryButton(col3, L["Post"], cW, 30, postSelected)
  panel.post:SetPoint("BOTTOMLEFT", cx, 12)
  -- a long item name is cut with "..." to fit the button; the tooltip shows the whole label
  local label = panel.post:GetFontString()
  if label then
    label:SetWidth(cW - 16)
    label:SetWordWrap(false)
  end
  panel.post:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(self:GetText() or "", 1, 1, 1)
    GameTooltip:AddLine(L["One listing per click · then the next item is ready"], 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  panel.post:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- Builds the panel window: frame, tab bar, Settings and Sales, the Sell tab's three cards and the
--- status bar. The panel starts hidden.
local function createPanel()
  T = UI.Tokens()
  local top = buildFrame()

  local inset = panel.Inset or panel
  if panel.Inset then
    panel.Inset:ClearAllPoints()
    panel.Inset:SetPoint("TOPLEFT", 8, top)
    panel.Inset:SetPoint("BOTTOMRIGHT", -8, 26)
  end
  panel.inset = inset
  local view = CreateFrame("Frame", nil, inset)
  view:SetAllPoints()
  panel.sellView = view

  buildBags(view)
  local market = UI.Card(view)
  market:SetPoint("TOPLEFT", BAGS_W + 14, -6)
  market:SetPoint("TOPRIGHT", -6, -6)
  market:SetHeight(MARKET_H)
  local listing = UI.Card(view)
  listing:SetPoint("TOPLEFT", market, "BOTTOMLEFT", 0, -8)
  listing:SetPoint("BOTTOMRIGHT", -6, 6)
  panel.empty = UI.Text(view, "GameFontHighlight", "muted", "CENTER")
  panel.empty:SetPoint("CENTER", market, "CENTER", 0, 0)
  panel.empty:SetWidth(500)
  panel.empty:SetText(L["Choose an item on the left to see its market and price it."])
  buildMarket(market)
  buildListing(listing)
  panel.col2:Hide()
  panel.col3:Hide()

  -- HookScript, not SetScript: UI.Window hooks these too (raise, controller window list).
  panel:HookScript("OnShow", function()
    state.rank = nil -- fresh value order for each visit to the auction house
    state.live = {} -- and data pack prices until each item is searched again
    local t = GW.activeTab
    showTab((t == "cancel" or t == "scan" or t == "shopping") and t or "sell")
  end)
  panel:HookScript("OnHide", function()
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
        GW.SellCharts.Render(state.sel.itemID, state.sel.name)
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

--- Shows or hides the panel (away from the auction house: on the Shopping tab).
function GW.ToggleSellPanel()
  if not panel then createPanel() end
  if panel:IsShown() then
    panel:Hide()
  else
    anchorToAuctionHouse()
    panel:Show()
  end
end

--- Opens the panel on a tab. Away from the auction house only Shopping opens (the window centred).
---@param key string "sell", "cancel", "shopping" or "scan"
function GW.OpenTab(key)
  if key ~= "shopping" and not ahOpen() then
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

--- Alt-click on an item in your bags while the Sell tab is open selects it there, with its usual
--- price (goldwright-addon #21). It never posts: posting stays one click on Post.
local lastPick
---@param bag number|nil
---@param slot number|nil
local function pickFromBags(bag, slot)
  if not (panel and panel:IsShown() and GW.activeTab == "sell" and bag and slot) then return end
  -- One click can reach two of the hooks below: act once.
  local key, now = bag .. ":" .. slot, GetTime()
  if lastPick and lastPick.key == key and lastPick.at == now then return end
  lastPick = { key = key, at = now }
  local info = C_Container.GetContainerItemInfo(bag, slot)
  if not (info and info.itemID) then return end
  local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
  if info.isBound or not (loc and loc:IsValid() and C_AuctionHouse.IsSellItemValid(loc, false)) then
    return toast(L["That item can't be sold at the auction house."], GW.SIGNAL_ORANGE)
  end
  if ignored(info.itemID) and not state.showHidden then
    return toast(L["That item is hidden on the Sell tab: show your hidden items below the list."], GW.SIGNAL_ORANGE)
  end
  for pass = 1, 2 do
    for _, g in ipairs(state.bags) do
      if g.itemID == info.itemID then return selectItem(g) end
    end
    if pass == 1 then -- the bags changed since the list was drawn
      scanBags()
      renderBags()
    end
  end
end

---@param button string|nil mouse button
---@return boolean
local function altLeftClick(button)
  return button == "LeftButton" and IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown()
end

--- The bag and slot of a bag item button (Blizzard's bags and add-ons built on its buttons).
---@param button table
---@return number|nil bag
---@return number|nil slot
local function buttonBagSlot(button)
  local bag = button.GetBagID and button:GetBagID() or (button:GetParent() and button:GetParent():GetID())
  return bag, button:GetID()
end

-- The same three places Auctionator listens to, so it works with Blizzard's bags and the bag add-ons
-- that pass clicks on (Baganator, ArkInventory). Post-hooks only: the click itself is unchanged.
if hooksecurefunc then
  for _, fn in ipairs({ "ContainerFrameItemButton_OnClick", "ContainerFrameItemButton_OnModifiedClick" }) do
    if _G[fn] then
      hooksecurefunc(fn, function(self, button)
        if altLeftClick(button) then pickFromBags(buttonBagSlot(self)) end
      end)
    end
  end
  if HandleModifiedItemClick then
    hooksecurefunc("HandleModifiedItemClick", function(_, itemLocation)
      if
        itemLocation
        and itemLocation.IsBagAndSlot
        and itemLocation:IsBagAndSlot()
        and altLeftClick(GetMouseButtonClicked and GetMouseButtonClicked())
      then
        pickFromBags(itemLocation:GetBagAndSlot())
      end
    end)
  end
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
    if panel and panel:IsShown() then
      -- opened away from the auction house (Shopping): dock it and turn the other tabs on
      C_Timer.After(0.2, function()
        anchorToAuctionHouse()
        updateTabs()
        if GW.ShopView then GW.ShopView.Refresh() end
      end)
    elseif GW.Opt("autoShow") then
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
    -- An item search for another suffix of the same item (Blizzard's Browse tab) isn't ours (#25).
    -- Only when both name a suffix: a search for every suffix is sorted out row by row (GW.CollectSearchResults).
    local theirs, ours = type(arg1) == "table" and arg1.itemSuffix or 0, state.key and state.key.itemSuffix or 0
    local otherSuffix = theirs ~= 0 and ours ~= 0 and theirs ~= ours
    if otherSuffix then
      GW.Log("ignored %s: suffix %s, ours %s", event, tostring(arg1.itemSuffix), tostring(state.key.itemSuffix))
    elseif argItem == nil or argItem == state.sel.itemID then
      readResults(type(arg1) == "table" and arg1 or nil, event)
    end
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" or event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    -- Diagnostics.lua records the error with the requests before it.
    if state.pending and event == "AUCTION_HOUSE_SHOW_ERROR" then
      local _, reason = GW.AuctionErrorName(arg1)
      toast(string.format(L["The auction house refused that post: %s."], reason), GW.SIGNAL_ORANGE)
      finishPending()
    end
  end
end)
