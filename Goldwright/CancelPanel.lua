-- Cancel tab (requirements CXL-1..7): your auctions with "Lowest" / "Undercut" status from one
-- search per distinct item (throttle-aware, with progress), the cancel cost per row, one cancel per
-- click, "Cancel next undercut" (button and key binding) and "Repost in Sell".
-- Lives inside the Goldwright panel (SellPanel.lua switches tabs and forwards events here).
local _, GW = ...

local ROWS, ROW_H = 12, 28
local CHECK_TIMEOUT = 6     -- seconds to wait for one item's search
local CANCEL_TIMEOUT = 8
local GREY = { 0.70, 0.70, 0.72 }
local WHITE = { 1, 1, 1 }
local SORTS = { { sortOrder = 0, reverseSort = false } } -- replaced with Enum values when the frame is built

local view
local cv = { list = {}, offset = 0, results = {}, queue = {}, checked = 0, total = 0, cancelled = {} }
local STALE = 300 -- seconds before a check counts as old when you come back to the tab

local function fs(parent, template, justify)
  local f = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
  if justify then f:SetJustifyH(justify) end
  return f
end
local function setColor(f, c) f:SetTextColor(c[1], c[2], c[3]) end

local function toast(text, color)
  if not view then return end
  view.toast:SetText(text or "")
  setColor(view.toast, color or WHITE)
end

local function keyString(k)
  if not k then return "?" end
  return table.concat({ k.itemID or 0, k.itemLevel or 0, k.itemSuffix or 0, k.battlePetSpeciesID or 0 }, ":")
end

local function qualityColor(q)
  local c = ITEM_QUALITY_COLORS and q and ITEM_QUALITY_COLORS[q]
  return c and { c.r, c.g, c.b } or WHITE
end

---------------------------------------------------------------------------
-- data
---------------------------------------------------------------------------
-- CXL-1: read the owned auctions the client has (after QueryOwnedAuctions).
local function readOwned()
  local list = {}
  local n = C_AuctionHouse.GetNumOwnedAuctions and C_AuctionHouse.GetNumOwnedAuctions() or 0
  for i = 1, n do
    local a = C_AuctionHouse.GetOwnedAuctionInfo(i)
    if a and a.auctionID and a.itemKey and not cv.cancelled[a.auctionID] then
      local key = a.itemKey
      local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(key)
      local isCommodity = info and info.isCommodity
      local qty = a.quantity or 1
      -- buyoutAmount: per unit for commodities, per auction for items (logged so we can verify in game)
      local unit = a.buyoutAmount and (isCommodity and a.buyoutAmount or math.floor(a.buyoutAmount / math.max(1, qty) + 0.5))
      local sold = Enum and Enum.AuctionStatus and a.status == Enum.AuctionStatus.Sold
      list[#list + 1] = {
        id = a.auctionID, itemKey = key, keyStr = keyString(key), itemID = key.itemID,
        name = (a.itemLink and a.itemLink:match("%[(.-)%]")) or (info and info.itemName) or ("item " .. tostring(key.itemID)),
        icon = (info and info.iconFileID) or (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(key.itemID)) or 134400,
        quality = info and info.quality, link = a.itemLink,
        qty = qty, unit = unit, bidOnly = not a.buyoutAmount, sold = sold, isCommodity = isCommodity,
        timeLeft = GW.TimeLeftText(a.timeLeftSeconds, a.timeLeft),
      }
      if i <= 3 then
        GW.Log("owned %d: %s qty=%s buyout=%s commodity=%s status=%s", i, list[#list].name, tostring(qty), tostring(a.buyoutAmount), tostring(isCommodity), tostring(a.status))
      end
    end
  end
  -- keep the cancelling flag across re-reads
  local old = {}
  for _, r in ipairs(cv.list) do old[r.id] = r end
  for _, r in ipairs(list) do
    local o = old[r.id]
    if o and o.cancelling then r.cancelling, r.cancelAt = o.cancelling, o.cancelAt end
  end
  cv.list = list
end

-- CXL-2: status of every row from the cached search results.
local function computeStatuses()
  local counts = { undercut = 0, lowest = 0, unchecked = 0 }
  for _, r in ipairs(cv.list) do
    local res = cv.results[r.keyStr]
    r.now, r.bait = nil, nil
    if r.sold then
      r.status = "sold"
    elseif r.bidOnly then
      r.status = "bid"
    elseif res and res.unknown then
      r.status = "unknown"
    elseif res then
      r.status, r.now, r.bait = GW.AuctionStatus(r.unit, res.listings)
    elseif cv.current and cv.current.keyStr == r.keyStr then
      r.status = "checking"
    else
      r.status = "unchecked"
    end
    if counts[r.status] then counts[r.status] = counts[r.status] + 1 end
    if r.status == "checking" or r.status == "unknown" then counts.unchecked = counts.unchecked + 1 end
  end
  return counts
end

---------------------------------------------------------------------------
-- rendering
---------------------------------------------------------------------------
local STATUS_TEXT = {
  sold = { "Sold: money comes by mail", GREY },
  bid = { "Bid only: not checked", GREY },
  unknown = { "Unknown (no answer)", GREY },
  checking = { "Checking…", GREY },
  unchecked = { "Not checked yet", GREY },
}

local function render()
  if not (view and view:IsShown()) then return end
  local counts = computeStatuses()
  for i, row in ipairs(view.rows) do
    local r = cv.list[i + cv.offset]
    row.r = r
    if r then
      row:Show()
      row.icon:SetTexture(r.icon)
      row.name:SetText(r.name .. "  |cff9a9aa2×" .. r.qty .. "|r")
      setColor(row.name, qualityColor(r.quality))
      row.price:SetText(r.unit and GW.Money(r.unit) or "bid")
      row.time:SetText(r.timeLeft)
      local text, color
      if r.status == "undercut" then
        text, color = "Undercut · now " .. GW.Money(r.now), GW.SIGNAL_ORANGE
      elseif r.status == "lowest" then
        text, color = r.bait and ("Lowest real · bait at " .. GW.Money(r.bait) .. " ignored") or "Lowest", GW.SIGNAL_BLUE
      else
        text, color = STATUS_TEXT[r.status][1], STATUS_TEXT[r.status][2]
      end
      row.status:SetText(text)
      setColor(row.status, color)
      local cost = (not r.sold and C_AuctionHouse.GetCancelCost) and C_AuctionHouse.GetCancelCost(r.id) or nil
      if r.sold then
        row.cancel:Hide()
      else
        row.cancel:Show()
        row.cancel:SetText(r.cancelling and "Cancelling…" or ("Cancel" .. (cost and cost > 0 and (" · " .. GW.Money(cost)) or "")))
        row.cancel:SetEnabled(not r.cancelling)
      end
    else
      row:Hide()
    end
  end

  local progress
  if cv.waiting then
    local w = GW.WaitText()
    progress = string.format("%s%s · checked %d of %d", w:sub(1, 1):upper(), w:sub(2), cv.checked, cv.total)
  elseif cv.total > 0 then
    progress = string.format("Checked %d of %d · %d searches this minute", cv.checked, cv.total, GW.SearchesThisMinute())
  else
    progress = #cv.list > 0 and string.format("%d searches this minute", GW.SearchesThisMinute()) or ""
  end
  view.progress:SetText(progress)

  if #cv.list == 0 then
    view.empty:SetText(cv.loaded and "You have no auctions at this auction house." or "Loading your auctions…")
    view.empty:Show()
  else
    view.empty:Hide()
  end
  local parts = {}
  if counts.undercut > 0 then parts[#parts + 1] = counts.undercut .. " undercut" end
  if counts.lowest > 0 then parts[#parts + 1] = counts.lowest .. " lowest" end
  if counts.unchecked > 0 then parts[#parts + 1] = counts.unchecked .. " not checked" end
  view.summary:SetText(#parts > 0 and (table.concat(parts, " · ") .. ". One click cancels one auction; its deposit is not refunded.") or "")
  view.next:SetEnabled(GW.NextUndercut(cv.list) ~= nil)
end

---------------------------------------------------------------------------
-- checks (one search per distinct item, throttle-aware)
---------------------------------------------------------------------------
local checkNext

local function finishCheck(k, listings, unknown)
  if cv.current ~= k then return end
  cv.results[k.keyStr] = { listings = listings or {}, unknown = unknown, at = GetTime() }
  cv.current, cv.token = nil, nil
  cv.checked = cv.checked + 1
  render()
  C_Timer.After(0.1, checkNext)
end

local function readFor(k, final, eventName)
  local list = GW.CollectSearchResults(k.itemKey.itemID, k.itemKey)
  GW.Log("cancel check %s for %s: %d listings", eventName or "read", k.name, #list)
  if #list == 0 then
    -- our own auction should be in the results, so empty means no answer yet
    if final then finishCheck(k, nil, true) end
    return
  end
  finishCheck(k, list)
end

checkNext = function()
  if not (view and view:IsShown()) or cv.current then return end
  local k = cv.queue[1]
  if not k then
    cv.waiting = false
    render()
    return
  end
  if not GW.CanSearch() then
    if not cv.waiting then GW.Log("cancel check waiting: %s", tostring(GW.SearchBlocked())) end
    cv.waiting = true
    render()
    C_Timer.After(2, checkNext)
    return
  end
  table.remove(cv.queue, 1)
  cv.waiting = false
  cv.current = k
  local token = {}
  cv.token = token
  GW.NoteSearch()
  C_AuctionHouse.SendSearchQuery(k.itemKey, SORTS, true)
  render()
  C_Timer.After(CHECK_TIMEOUT, function()
    if cv.token == token and cv.current == k then readFor(k, true, "timeout") end
  end)
end

-- Queue one search per distinct item. mode "new": only items never checked (the game refreshes
-- the auction list after every post and cancel, and that must not cost searches); "stale": also
-- checks older than 5 minutes (coming back to the tab); "all": the Refresh button.
-- A check already running keeps going; new items join the queue.
local function startChecks(mode)
  local busy = cv.current ~= nil or #cv.queue > 0
  if mode == "all" then cv.current, cv.token = nil, nil end
  if mode == "all" or not busy then cv.queue, cv.checked, cv.total = {}, 0, 0 end
  local queued = {}
  for _, k in ipairs(cv.queue) do queued[k.keyStr] = true end
  if cv.current then queued[cv.current.keyStr] = true end
  for _, r in ipairs(cv.list) do
    local res = cv.results[r.keyStr]
    local need = mode == "all" or not res or (mode == "stale" and (res.unknown or GetTime() - res.at > STALE))
    if need and not r.sold and not r.bidOnly and not queued[r.keyStr] then
      queued[r.keyStr] = true
      table.insert(cv.queue, { keyStr = r.keyStr, itemKey = r.itemKey, name = r.name })
      cv.total = cv.total + 1
      if mode == "all" then cv.results[r.keyStr] = nil end
    end
  end
  render()
  checkNext()
end

local function queryOwned()
  if not C_AuctionHouse.QueryOwnedAuctions then return end
  local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } }
  GW.NoteSearch()
  C_AuctionHouse.QueryOwnedAuctions(sorts)
end

---------------------------------------------------------------------------
-- cancelling (CXL-4..7)
---------------------------------------------------------------------------
local function cancelRow(r)
  if not r or r.sold or r.cancelling then return end
  if InCombatLockdown and InCombatLockdown() then return toast("Not in combat.", GW.SIGNAL_ORANGE) end
  if C_AuctionHouse.CanCancelAuction and not C_AuctionHouse.CanCancelAuction(r.id) then
    return toast("That auction can't be cancelled.", GW.SIGNAL_ORANGE)
  end
  local cost = C_AuctionHouse.GetCancelCost and C_AuctionHouse.GetCancelCost(r.id) or 0
  if cost > (GetMoney and GetMoney() or 0) then
    return toast("Cancelling costs " .. GW.Money(cost) .. ": not enough money.", GW.SIGNAL_ORANGE)
  end
  r.cancelling, r.cancelAt = true, GetTime()
  cv.lastCancel = r
  C_AuctionHouse.CancelAuction(r.id)
  GW.Log("cancel sent: %s x%d (auction %s, cost %d)", r.name, r.qty, tostring(r.id), cost)
  toast("Cancelling " .. r.name .. "…", GREY)
  render()
  C_Timer.After(CANCEL_TIMEOUT, function()
    if r.cancelling and r.cancelAt and GetTime() - r.cancelAt >= CANCEL_TIMEOUT - 0.1 then
      r.cancelling = nil
      toast("No answer from the auction house for " .. r.name .. ". Refresh to see if it was cancelled.", GW.SIGNAL_ORANGE)
      render()
    end
  end)
end

-- AUCTION_CANCELED: the id it carries didn't match the row's in game (2026-11-10), so fall back to
-- the auction we just asked to cancel. Cancelled ids stay out of the list even if the game's next
-- refresh still has them.
local function onCancelled(auctionID)
  local mine = cv.lastCancel and cv.lastCancel.cancelling and cv.lastCancel or nil
  GW.Log("AUCTION_CANCELED arg=%s (%s), ours=%s", tostring(auctionID), type(auctionID), tostring(mine and mine.id))
  local r
  for i, x in ipairs(cv.list) do
    if x.id == auctionID or (mine and (x == mine or x.id == mine.id)) then
      r = table.remove(cv.list, i)
      break
    end
  end
  r = r or mine
  if not r then return end
  cv.cancelled[r.id] = true
  r.cancelling = nil
  cv.repost = r
  toast(string.format("Cancelled %d × %s. It comes back by mail.", r.qty, r.name), GW.SIGNAL_BLUE)
  view.repost:Show()
  render()
end

-- CXL-6 (button and key binding): cancel the first undercut auction in the list.
function GW.CancelNextUndercut()
  if not (view and view:IsShown()) then return end
  local r = GW.NextUndercut(cv.list)
  if r then cancelRow(r) else toast("No undercut auctions left.", GREY) end
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------
local function build(parent)
  SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints()

  local h = fs(view, "GameFontNormal", "LEFT"); h:SetPoint("TOPLEFT", 12, -8); h:SetText("Your auctions")
  view.progress = fs(view, "GameFontDisableSmall", "LEFT"); view.progress:SetPoint("LEFT", h, "RIGHT", 12, 0)
  local refresh = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
  refresh:SetSize(90, 22); refresh:SetPoint("TOPRIGHT", -12, -4); refresh:SetText("Refresh")
  refresh:SetScript("OnClick", function()
    toast("")
    cv.refreshing = true
    queryOwned()
  end)

  local cols = { { "Item", 12 }, { "Your price", 380 }, { "Time left", 500 }, { "Status", 600 }, { "Action", 832 } }
  for _, c in ipairs(cols) do
    local f = fs(view, "GameFontDisableSmall", "LEFT"); f:SetPoint("TOPLEFT", c[2], -34); f:SetText(c[1])
  end

  local list = CreateFrame("Frame", nil, view)
  list:SetPoint("TOPLEFT", 6, -50)
  list:SetSize(970, ROWS * ROW_H)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    cv.offset = math.max(0, math.min(cv.offset - delta, math.max(0, #cv.list - ROWS)))
    render()
  end)
  view.rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("Frame", nil, list)
    row:SetSize(970, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:EnableMouse(true)
    if i % 2 == 0 then
      local bg = row:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(1, 1, 1, 0.03)
    end
    row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(22, 22); row.icon:SetPoint("LEFT", 6, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = fs(row, "GameFontHighlight", "LEFT"); row.name:SetPoint("LEFT", 34, 0); row.name:SetWidth(330); row.name:SetWordWrap(false)
    row.price = fs(row, "GameFontHighlight", "LEFT"); row.price:SetPoint("LEFT", 374, 0)
    row.time = fs(row, "GameFontHighlightSmall", "LEFT"); row.time:SetPoint("LEFT", 494, 0)
    row.status = fs(row, "GameFontHighlightSmall", "LEFT"); row.status:SetPoint("LEFT", 594, 0); row.status:SetWidth(230); row.status:SetWordWrap(false)
    row.cancel = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.cancel:SetSize(130, 22); row.cancel:SetPoint("LEFT", 826, 0)
    row.cancel:SetScript("OnClick", function() cancelRow(row.r) end)
    row:SetScript("OnEnter", function(self)
      if not (self.r and self.r.link) then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(self.r.link)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    view.rows[i] = row
  end

  view.empty = fs(view, "GameFontDisable", "CENTER"); view.empty:SetPoint("CENTER", 0, 20)

  view.summary = fs(view, "GameFontHighlightSmall", "LEFT"); view.summary:SetPoint("BOTTOMLEFT", 12, 40)
  view.toast = fs(view, "GameFontHighlightSmall", "LEFT"); view.toast:SetPoint("BOTTOMLEFT", 12, 16); view.toast:SetWidth(560)
  view.repost = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
  view.repost:SetSize(130, 24); view.repost:SetPoint("BOTTOMLEFT", 580, 10); view.repost:SetText("Repost in Sell")
  view.repost:SetScript("OnClick", function() if cv.repost and GW.SellItem then GW.SellItem(cv.repost.itemID) end end)
  view.repost:Hide()
  view.next = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
  view.next:SetSize(220, 26); view.next:SetPoint("BOTTOMRIGHT", -12, 10); view.next:SetText("Cancel Next Undercut")
  view.next:SetScript("OnClick", GW.CancelNextUndercut)
end

---------------------------------------------------------------------------
-- interface for SellPanel.lua
---------------------------------------------------------------------------
GW.CancelView = {}

function GW.CancelView.Show(parent)
  if not view then build(parent) end
  view:Show()
  cv.loaded = cv.loaded and #cv.list > 0
  cv.returning = true -- the next list update re-checks old results
  render()
  queryOwned()
end

function GW.CancelView.Hide()
  if view then view:Hide() end
  cv.current, cv.token, cv.queue, cv.waiting = nil, nil, {}, false
end

function GW.CancelView.OnEvent(event, arg1, arg2)
  if not (view and view:IsShown()) then return end
  if event == "OWNED_AUCTIONS_UPDATED" or event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
    readOwned()
    cv.loaded = true
    if event == "OWNED_AUCTIONS_UPDATED" then
      startChecks(cv.refreshing and "all" or cv.returning and "stale" or "new")
      cv.refreshing, cv.returning = false, false
    else
      render()
    end
  elseif event == "AUCTION_CANCELED" then
    onCancelled(arg1)
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "COMMODITY_SEARCH_RESULTS_ADDED" then
    if cv.current and arg1 == cv.current.itemKey.itemID then readFor(cv.current, false, event) end
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED" then
    local k = cv.current
    if k and type(arg1) == "table" and arg1.itemID == k.itemKey.itemID then readFor(k, false, event) end
  elseif event == "UI_ERROR_MESSAGE" then
    local r = cv.lastCancel
    if r and r.cancelling and GetTime() - (r.cancelAt or 0) < CANCEL_TIMEOUT and type(arg2) == "string" then
      r.cancelling = nil
      toast(arg2, GW.SIGNAL_ORANGE)
      render()
    end
  elseif event == "BAG_UPDATE_DELAYED" then
    render()
  end
end

-- Events only the Cancel tab needs; SellPanel.lua forwards everything while this tab is shown.
local extra = CreateFrame("Frame")
for _, e in ipairs({ "OWNED_AUCTIONS_UPDATED", "AUCTION_CANCELED", "ITEM_KEY_ITEM_INFO_RECEIVED" }) do
  pcall(extra.RegisterEvent, extra, e)
end
extra:SetScript("OnEvent", function(_, event, arg1, arg2)
  if GW.activeTab == "cancel" then GW.CancelView.OnEvent(event, arg1, arg2) end
end)

-- For tests and /dump: the tab's state and frame.
function GW.CancelView.Debug() return cv, view end
