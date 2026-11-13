--- My Auctions (cancel) tab (CXL-1..7): your auctions with "Lowest" / "Undercut" status from one search per
--- distinct item (throttle-aware, with progress), the cancel cost per row, one cancel per click,
--- "Cancel next undercut" (button and key binding) and "Repost in Sell".
--- Lives inside the Goldwright panel: SellPanel.lua switches tabs and forwards events here.
local _, GW = ...
local L = GW.L

local ROWS, ROW_H = 12, 28
local CHECK_TIMEOUT = 6 -- seconds to wait for one item's search
local CANCEL_TIMEOUT = 8
local UI = GW.UI
local fs, setColor, qualityColor = UI.FontString, UI.SetColor, UI.QualityColor
local GREY = UI.GREY

local view

--- One of your auctions, as shown in a row.
---@class CancelRow
---@field id number auction id
---@field itemKey table the auction's item key
---@field keyStr string item key as a string, used to share one search between rows of the same item
---@field itemID number
---@field name string
---@field icon number texture file id
---@field quality number?
---@field link string? item link, for the tooltip
---@field qty number quantity in the auction
---@field unit number? buyout per unit; nil for bid-only auctions
---@field bidOnly boolean no buyout
---@field sold boolean sold, money on its way by mail
---@field isCommodity boolean?
---@field timeLeft string time left as text
---@field cancelling boolean? a cancel was sent and has no answer yet
---@field cancelAt number? GetTime() when the cancel was sent
---@field status string "undercut", "lowest", "sold", "bid", "unknown", "checking" or "unchecked"
---@field now number? cheapest real price of other sellers
---@field bait number? cheaper bait price that was ignored

--- One item waiting for (or running) its check search.
---@class CancelCheck
---@field keyStr string
---@field itemKey table
---@field name string

--- State of the My Auctions tab.
---@class CancelViewState
---@field list CancelRow[] your auctions
---@field offset number scroll offset into list
---@field results table<string, { listings: table[], unknown: boolean?, at: number }> search results by keyStr
---@field queue CancelCheck[] items still to check
---@field checked number checks finished in this round
---@field total number checks in this round
---@field cancelled table<number, boolean> auction ids cancelled since login or /reload (kept out of the list)
---@field current CancelCheck? the check whose search is running
---@field token table? identifies the running check, so its timeout can tell it is still current
---@field waiting boolean? waiting for the search throttle
---@field loaded boolean? the owned-auctions list has arrived
---@field refreshing boolean? the Refresh button asked for the list: re-check everything
---@field returning boolean? the tab was just opened: re-check old results
---@field lastCancel CancelRow? the auction we last asked to cancel
---@field repost CancelRow? the last cancelled auction, for "Repost in Sell"
local cv = { list = {}, offset = 0, results = {}, queue = {}, checked = 0, total = 0, cancelled = {} }
local STALE = 300 -- seconds before a check counts as old when you come back to the tab

--- Shows a short message at the bottom of the tab.
---@param text string
---@param color number[]? {r, g, b}
local function toast(text, color) UI.Toast(view, text, color) end

--- An item key as "itemID:itemLevel:itemSuffix:battlePetSpeciesID".
---@param k table? item key
---@return string
local function keyString(k)
  if not k then return "?" end
  return table.concat({ k.itemID or 0, k.itemLevel or 0, k.itemSuffix or 0, k.battlePetSpeciesID or 0 }, ":")
end

---------------------------------------------------------------------------
-- data
---------------------------------------------------------------------------

--- `s` when it is a non-empty string, else nil.
---@param s any
---@return string|nil
local function nonEmpty(s) return type(s) == "string" and s ~= "" and s or nil end

--- Reads the owned auctions the client has (after QueryOwnedAuctions) into cv.list (CXL-1).
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
      local unit = a.buyoutAmount
        and (isCommodity and a.buyoutAmount or math.floor(a.buyoutAmount / math.max(1, qty) + 0.5))
      local sold = Enum and Enum.AuctionStatus and a.status == Enum.AuctionStatus.Sold
      list[#list + 1] = {
        id = a.auctionID,
        itemKey = key,
        keyStr = keyString(key),
        itemID = key.itemID,
        -- An item the client hasn't loaded yet has an empty name ("[]" in its link): fall through
        -- to the next source, and to "item <id>" last; ITEM_KEY_ITEM_INFO_RECEIVED re-reads it.
        name = nonEmpty(a.itemLink and a.itemLink:match("%[(.-)%]")) or nonEmpty(info and info.itemName) or nonEmpty(
          C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(key.itemID)
        ) or string.format(L["item %s"], tostring(key.itemID)),
        icon = (info and info.iconFileID)
          or (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(key.itemID))
          or 134400,
        quality = info and info.quality,
        link = a.itemLink,
        qty = qty,
        unit = unit,
        bidOnly = not a.buyoutAmount,
        sold = sold,
        isCommodity = isCommodity,
        timeLeft = GW.TimeLeftText(a.timeLeftSeconds, a.timeLeft),
      }
      if i <= 3 then
        GW.Log(
          "owned %d: %s qty=%s buyout=%s commodity=%s status=%s",
          i,
          list[#list].name,
          tostring(qty),
          tostring(a.buyoutAmount),
          tostring(isCommodity),
          tostring(a.status)
        )
      end
    end
  end
  -- keep the cancelling flag across re-reads
  local old = {}
  for _, r in ipairs(cv.list) do
    old[r.id] = r
  end
  for _, r in ipairs(list) do
    local o = old[r.id]
    if o and o.cancelling then
      r.cancelling, r.cancelAt = o.cancelling, o.cancelAt
    end
  end
  cv.list = list
end

--- Sets the status of every row from the cached search results (CXL-2).
---@return { undercut: number, lowest: number, unchecked: number } counts for the summary line
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
  sold = { L["Sold: money comes by mail"], GREY },
  bid = { L["Bid only: not checked"], GREY },
  unknown = { L["Unknown (no answer)"], GREY },
  checking = { L["Checking…"], GREY },
  unchecked = { L["Not checked yet"], GREY },
}

--- Redraws the rows, the progress line, the summary and the "Cancel Next Undercut" button.
local function render()
  if not (view and view:IsShown()) then return end
  local counts = computeStatuses()
  local moved = false
  for i, row in ipairs(view.rows) do
    local r = cv.list[i + cv.offset]
    row.r = r
    -- A row that now shows a different auction (after a cancel or a refresh moved the list) takes
    -- no clicks for a moment, so a second click on the same spot can't cancel the wrong auction.
    local id = r and r.id
    if id ~= row.shownId then
      row.shownId, row.since = id, GetTime()
      moved = moved or id ~= nil
    end
    if r then
      row:Show()
      row.icon:SetTexture(r.icon)
      row.name:SetText(r.name .. "  |cff9a9aa2×" .. r.qty .. "|r")
      setColor(row.name, qualityColor(r.quality))
      row.price:SetText(r.unit and GW.Money(r.unit) or L["bid"])
      row.time:SetText(r.timeLeft)
      local text, color
      if r.status == "undercut" then
        text, color = string.format(L["Undercut · now %s"], GW.Money(r.now)), GW.SIGNAL_ORANGE
      elseif r.status == "lowest" then
        text, color =
          r.bait and string.format(L["Lowest real · bait at %s ignored"], GW.Money(r.bait)) or L["Lowest"],
          GW.SIGNAL_BLUE
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
        row.cancel:SetText(
          r.cancelling and L["Cancelling…"]
            or (cost and cost > 0 and string.format(L["Cancel · %s"], GW.Money(cost)) or L["Cancel"])
        )
        row.cancel:SetEnabled(not r.cancelling and GetTime() - row.since >= GW.CONFIRM_DELAY)
      end
    else
      row:Hide()
    end
  end
  if moved then C_Timer.After(GW.CONFIRM_DELAY + 0.05, render) end

  local progress
  if cv.waiting then
    -- A capitalised key, not :upper() on the first byte (that breaks Cyrillic, Korean and Chinese).
    progress = string.format(L["%s · checked %d of %d"], GW.WaitText(true), cv.checked, cv.total)
  elseif cv.total > 0 then
    progress =
      string.format(L["Checked %d of %d · %d searches this minute"], cv.checked, cv.total, GW.SearchesThisMinute())
  else
    progress = #cv.list > 0 and GW.Plural(GW.SearchesThisMinute(), "%d search this minute", "%d searches this minute")
      or ""
  end
  view.progress:SetText(progress)

  if #cv.list == 0 then
    view.empty:SetText(cv.loaded and L["You have no auctions at this auction house."] or L["Loading your auctions…"])
    view.empty:Show()
  else
    view.empty:Hide()
  end
  local parts = {}
  if counts.undercut > 0 then parts[#parts + 1] = GW.Plural(counts.undercut, "%d undercut", "%d undercut") end
  if counts.lowest > 0 then parts[#parts + 1] = GW.Plural(counts.lowest, "%d lowest", "%d lowest") end
  if counts.unchecked > 0 then parts[#parts + 1] = GW.Plural(counts.unchecked, "%d not checked", "%d not checked") end
  view.summary:SetText(
    #parts > 0
        and string.format(
          L["%s. One click cancels one auction; its deposit is not refunded."],
          table.concat(parts, " · ")
        )
      or ""
  )
  view.next:SetEnabled(GW.NextUndercut(cv.list) ~= nil)
end

---------------------------------------------------------------------------
-- checks (one search per distinct item, throttle-aware)
---------------------------------------------------------------------------
local checkNext

--- Stores the result of the running check and moves on to the next one.
---@param k CancelCheck the check (ignored if it is no longer the running one)
---@param listings table[]? the listings found
---@param unknown boolean? true when the search gave no answer
local function finishCheck(k, listings, unknown)
  if cv.current ~= k then return end
  cv.results[k.keyStr] = { listings = listings or {}, unknown = unknown, at = GetTime() }
  cv.current, cv.token = nil, nil
  cv.checked = cv.checked + 1
  render()
  C_Timer.After(0.1, checkNext)
end

--- Reads the search results for a check.
---@param k CancelCheck
---@param final boolean the timeout fired: an empty result now counts as no answer
---@param eventName string? for the log
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

--- Starts the next queued search when the throttle allows, else retries later.
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
    C_Timer.After(GW.SEARCH_RETRY, checkNext)
    return
  end
  table.remove(cv.queue, 1)
  cv.waiting = false
  cv.current = k
  local token = {}
  cv.token = token
  GW.NoteSearch()
  C_AuctionHouse.SendSearchQuery(k.itemKey, GW.PriceSorts(), true)
  render()
  C_Timer.After(CHECK_TIMEOUT, function()
    if cv.token == token and cv.current == k then readFor(k, true, "timeout") end
  end)
end

--- Queues one search per distinct item. A check already running keeps going; new items join the queue.
---@param mode "new"|"stale"|"all" "new": only items never checked (the game refreshes the auction list after
--- every post and cancel, and that must not cost searches); "stale": also checks older than 5 minutes
--- (coming back to the tab); "all": the Refresh button
local function startChecks(mode)
  local busy = cv.current ~= nil or #cv.queue > 0
  if mode == "all" then
    cv.current, cv.token = nil, nil
  end
  if mode == "all" or not busy then
    cv.queue, cv.checked, cv.total = {}, 0, 0
  end
  local queued = {}
  for _, k in ipairs(cv.queue) do
    queued[k.keyStr] = true
  end
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

--- Asks the server for your auctions (answered by OWNED_AUCTIONS_UPDATED); counts as a search.
local function queryOwned()
  if not C_AuctionHouse.QueryOwnedAuctions then return end
  local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } }
  GW.NoteSearch()
  C_AuctionHouse.QueryOwnedAuctions(sorts)
end

---------------------------------------------------------------------------
-- cancelling (CXL-4..7)
---------------------------------------------------------------------------

--- Cancels one auction, after checking combat, whether it can be cancelled and the cancel cost.
---@param r CancelRow?
local function cancelRow(r)
  if not r or r.sold or r.cancelling then return end
  if InCombatLockdown and InCombatLockdown() then return toast(L["Not in combat."], GW.SIGNAL_ORANGE) end
  if C_AuctionHouse.CanCancelAuction and not C_AuctionHouse.CanCancelAuction(r.id) then
    return toast(L["That auction can't be cancelled."], GW.SIGNAL_ORANGE)
  end
  local cost = C_AuctionHouse.GetCancelCost and C_AuctionHouse.GetCancelCost(r.id) or 0
  if cost > (GetMoney and GetMoney() or 0) then
    return toast(string.format(L["Cancelling costs %s: not enough money."], GW.Money(cost)), GW.SIGNAL_ORANGE)
  end
  r.cancelling, r.cancelAt = true, GetTime()
  cv.lastCancel = r
  C_AuctionHouse.CancelAuction(r.id)
  GW.Log("cancel sent: %s x%d (auction %s, cost %d)", r.name, r.qty, tostring(r.id), cost)
  toast(string.format(L["Cancelling %s…"], r.name), GREY)
  render()
  C_Timer.After(CANCEL_TIMEOUT, function()
    if r.cancelling and r.cancelAt and GetTime() - r.cancelAt >= CANCEL_TIMEOUT - 0.1 then
      r.cancelling = nil
      toast(
        string.format(L["No answer from the auction house for %s. Refresh to see if it was cancelled."], r.name),
        GW.SIGNAL_ORANGE
      )
      render()
    end
  end)
end

--- AUCTION_CANCELED: removes the auction from the list and offers "Repost in Sell".
--- The id the event carries didn't match the row's in game (2026-11-10), so this falls back to the
--- auction we just asked to cancel. Cancelled ids stay out of the list even if the game's next refresh
--- still has them.
---@param auctionID any the event's argument
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
  toast(string.format(L["Cancelled %d × %s. It comes back by mail."], r.qty, r.name), GW.SIGNAL_BLUE)
  view.repost:Show()
  render()
end

--- Cancels the first undercut auction in the list (CXL-6: button and key binding).
function GW.CancelNextUndercut()
  if not (view and view:IsShown()) then return end
  local r = GW.NextUndercut(cv.list)
  if r then
    cancelRow(r)
  else
    toast(L["No undercut auctions left."], GREY)
  end
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------

--- Creates the tab's frames: header, Refresh, column titles, rows and the bottom bar.
---@param parent table the panel's inset frame
local function build(parent)
  view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints()

  local h = UI.Header(view, L["Your auctions"], 12, -8)
  view.progress = fs(view, "GameFontDisableSmall", "LEFT")
  view.progress:SetPoint("LEFT", h, "RIGHT", 12, 0)
  local refresh = UI.Button(view, L["Refresh"], 90, 22)
  refresh:SetPoint("TOPRIGHT", -12, -4)
  refresh:SetScript("OnClick", function()
    toast("")
    cv.refreshing = true
    queryOwned()
  end)

  local cols = {
    { L["Item"], 12 },
    { L["Your price"], 380 },
    { L["Time left"], 500 },
    { L["Status"], 600 },
    { L["Action"], 832 },
  }
  for _, c in ipairs(cols) do
    local f = fs(view, "GameFontDisableSmall", "LEFT")
    f:SetPoint("TOPLEFT", c[2], -34)
    f:SetText(c[1])
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
    UI.Stripe(row, i)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 6, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = fs(row, "GameFontHighlight", "LEFT")
    row.name:SetPoint("LEFT", 34, 0)
    row.name:SetWidth(330)
    row.name:SetWordWrap(false)
    row.price = fs(row, "GameFontHighlight", "LEFT")
    row.price:SetPoint("LEFT", 374, 0)
    row.time = fs(row, "GameFontHighlightSmall", "LEFT")
    row.time:SetPoint("LEFT", 494, 0)
    row.status = fs(row, "GameFontHighlightSmall", "LEFT")
    row.status:SetPoint("LEFT", 594, 0)
    row.status:SetWidth(230)
    row.status:SetWordWrap(false)
    row.cancel = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.cancel:SetSize(130, 22)
    row.cancel:SetPoint("LEFT", 826, 0)
    row.cancel:SetScript("OnClick", function()
      if GetTime() - (row.since or 0) < GW.CONFIRM_DELAY then return end -- the row just changed
      cancelRow(row.r)
    end)
    row:SetScript("OnEnter", function(self)
      if not (self.r and self.r.link) then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(self.r.link)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    view.rows[i] = row
  end

  view.empty = fs(view, "GameFontDisable", "CENTER")
  view.empty:SetPoint("CENTER", 0, 20)

  view.summary = fs(view, "GameFontHighlightSmall", "LEFT")
  view.summary:SetPoint("BOTTOMLEFT", 12, 40)
  view.toast = fs(view, "GameFontHighlightSmall", "LEFT")
  view.toast:SetPoint("BOTTOMLEFT", 12, 16)
  view.toast:SetWidth(560)
  view.repost = UI.Button(view, L["Repost in Sell"], 130, 24)
  view.repost:SetPoint("BOTTOMLEFT", 580, 10)
  view.repost:SetScript("OnClick", function()
    if cv.repost and GW.SellItem then GW.SellItem(cv.repost.itemID) end
  end)
  view.repost:Hide()
  view.next = UI.Button(view, L["Cancel Next Undercut"], 220, 26)
  view.next:SetPoint("BOTTOMRIGHT", -12, 10)
  view.next:SetScript("OnClick", GW.CancelNextUndercut)
end

---------------------------------------------------------------------------
-- interface for SellPanel.lua
---------------------------------------------------------------------------

--- The My Auctions tab, shown and hidden by the panel's tab bar (SellPanel.lua).
GW.CancelView = {}

--- Shows the tab (building it on first use) and asks for your auctions.
---@param parent table the panel's inset frame
function GW.CancelView.Show(parent)
  if not view then build(parent) end
  view:Show()
  cv.loaded = cv.loaded and #cv.list > 0
  cv.returning = true -- the next list update re-checks old results
  render()
  queryOwned()
end

--- Hides the tab and drops the running and queued checks.
function GW.CancelView.Hide()
  if view then view:Hide() end
  cv.current, cv.token, cv.queue, cv.waiting = nil, nil, {}, false
end

--- Handles an auction house event while the tab is shown.
---@param event string
---@param arg1 any first event argument
---@param arg2 any second event argument (the message text for UI_ERROR_MESSAGE)
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
    if r and r.cancelling and GetTime() - (r.cancelAt or 0) < CANCEL_TIMEOUT and GW.IsAuctionError(arg1, arg2) then
      r.cancelling = nil
      toast(arg2, GW.SIGNAL_ORANGE)
      render()
    end
  elseif event == "BAG_UPDATE_DELAYED" then
    render()
  end
end

-- Events only the Cancel tab needs; SellPanel.lua forwards everything else while this tab is shown.
local extra = CreateFrame("Frame")
for _, e in ipairs({ "OWNED_AUCTIONS_UPDATED", "AUCTION_CANCELED", "ITEM_KEY_ITEM_INFO_RECEIVED" }) do
  pcall(extra.RegisterEvent, extra, e)
end
extra:SetScript("OnEvent", function(_, event, arg1, arg2)
  if GW.activeTab == "cancel" then GW.CancelView.OnEvent(event, arg1, arg2) end
end)

--- For tests and /dump: the tab's state and frame.
---@return CancelViewState cv
---@return table|nil view
function GW.CancelView.Debug() return cv, view end
