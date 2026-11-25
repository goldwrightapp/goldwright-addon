--- Buying commodities, the one safe way every Goldwright tab uses (Shopping, Buy): Start asks the
--- auction house for the exact price of a quantity (StartCommoditiesPurchase); Confirm, a separate
--- click once the price is known, buys it (ConfirmCommoditiesPurchase). Never automatic.
---
--- The auction house handles one commodity purchase at a time, so there is one here too: starting a
--- new one lets an unconfirmed one go; a confirmed one is never cancelled. The tab that started a
--- purchase hears everything through its onChange callback (also with the tab closed: a confirmed
--- purchase was the player's click), and says it in its own words:
---   "quote"        the exact price arrived (p.unit, p.total)
---   "noPrice"      no price within BUY_TIMEOUT: let go, nothing bought
---   "expired"      a quoted price wasn't confirmed within QUOTE_TIMEOUT: let go, nothing bought
---   "unavailable"  the listings are gone
---   "bought"       done (p.done)
---   "failed"       the purchase failed, nothing bought
---   "unanswered"   no answer after Confirm (reason "timeout"), or the auction house closed first
---                  (reason "closed"): it may have gone through
---   "lateBought" / "lateFailed"  the answer to an unanswered purchase, within LATE_RESULT_WINDOW
--- Blizzard's own Buy tab fires the same events: they only count while we have a purchase going.
---
--- Gear (goldwright-addon #61) is bought one auction at a time at its buyout: StartGear picks the
--- auction and says "quote" at once (its price is fixed, there is no server step); Confirm buys it
--- (PlaceBid, a protected call: only from the player's click). AUCTION_HOUSE_PURCHASE_COMPLETED for that
--- auction is "bought"; an auction house error while it is being bought is "unavailable" when
--- someone else bought it first (the database error the game reports for a gone auction), else
--- "failed".
local _, GW = ...

GW.Purchase = {}

local BUY_TIMEOUT = 12 -- seconds to wait for the exact price before letting the purchase go
local QUOTE_TIMEOUT = 60 -- seconds a quoted price waits for Confirm before it is let go
local CONFIRM_TIMEOUT = 30 -- seconds after Confirm before saying the outcome is unknown
local LATE_RESULT_WINDOW = 300 -- seconds a late result still counts for an unanswered purchase

---@class GoldwrightPurchase
---@field itemID number
---@field gear? boolean one auction bought at its buyout (StartGear)
---@field auctionID? number the gear auction
---@field name string
---@field qty number units asked for
---@field estimate number cost the tab showed, in copper
---@field at number GetTime() of Start
---@field onChange fun(p: GoldwrightPurchase, what: string, reason?: string)
---@field unit? number exact unit price (after "quote")
---@field total? number exact total (after "quote": Confirm is possible)
---@field quotedAt? number GetTime() of the latest quote; Confirm works GW.CONFIRM_DELAY after it
---@field confirming? boolean Confirm was clicked
---@field done? boolean bought
---@field unansweredAt? number GetTime() when we stopped waiting after Confirm

local current -- the purchase between Start and its result
local unanswered -- a confirmed purchase whose answer didn't come in time

--- Tells the purchase's tab what happened; an error there never breaks the purchase.
---@param p GoldwrightPurchase
---@param what string
---@param reason? string
local function tell(p, what, reason)
  if p.onChange then
    local ok, err = pcall(p.onChange, p, what, reason)
    if not ok then GW.Log("purchase callback error: %s", tostring(err)) end
  end
end

--- The purchase going on (started, not finished), if any.
---@return GoldwrightPurchase|nil
function GW.Purchase.Current() return current end

--- Whether Confirm would buy now: the exact price is known and the double-click pause has passed.
---@param p GoldwrightPurchase|nil
---@return boolean
function GW.Purchase.CanConfirm(p)
  return p ~= nil
    and p == current
    and p.total ~= nil
    and not p.confirming
    and GetTime() - (p.quotedAt or 0) >= GW.CONFIRM_DELAY
end

--- Lets the current purchase go if it isn't confirmed yet (a confirmed one is on its way).
---@param p? GoldwrightPurchase only this one (nil: whichever is current)
---@return boolean cancelled
function GW.Purchase.Cancel(p)
  if not current or current.confirming or (p and p ~= current) then return false end
  if not current.gear and C_AuctionHouse.CancelCommoditiesPurchase then
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
  end
  current = nil
  return true
end

--- Picks one gear auction to buy at its buyout (#61). Its price is fixed, so it is "quoted" at once and
--- Confirm (after the usual pause) buys it. Any unconfirmed purchase is let go first; refused while
--- one is being confirmed.
---@param opts { itemID: number, name: string, auctionID: number, buyout: number, onChange: function } plus any fields the tab wants back
---@return GoldwrightPurchase|nil p nil while another purchase is being confirmed
function GW.Purchase.StartGear(opts)
  if current and current.confirming then return nil end
  GW.Purchase.Cancel()
  local p = {}
  for k, v in pairs(opts) do
    p[k] = v
  end
  p.gear, p.qty = true, 1
  p.unit, p.total, p.estimate = opts.buyout, opts.buyout, opts.estimate or opts.buyout
  p.at, p.quotedAt = GetTime(), GetTime()
  local quote = {}
  p.quote = quote
  current, unanswered = p, nil
  GW.Log("purchase gear: %s auction %s for %d", p.name, tostring(p.auctionID), p.total or 0)
  C_Timer.After(QUOTE_TIMEOUT, function()
    if current == p and p.quote == quote and not p.confirming and not p.done then
      GW.Purchase.Cancel(p)
      tell(p, "expired")
    end
  end)
  tell(p, "quote")
  C_Timer.After(GW.CONFIRM_DELAY + 0.05, function()
    if current == p and not p.confirming then tell(p, "ready") end
  end)
  return p
end

--- Asks the auction house for the exact price of `qty` of an item. Any unconfirmed purchase is let go
--- first; refused while one is being confirmed.
---@param opts { itemID: number, name: string, qty: number, estimate: number, onChange: function } plus any fields the tab wants back (e.g. `entry`)
---@return GoldwrightPurchase|nil p nil while another purchase is being confirmed
function GW.Purchase.Start(opts)
  if current and current.confirming then return nil end
  GW.Purchase.Cancel()
  local p = {}
  for k, v in pairs(opts) do
    p[k] = v
  end
  p.at = GetTime()
  current, unanswered = p, nil
  C_AuctionHouse.StartCommoditiesPurchase(p.itemID, p.qty)
  GW.Log("purchase start: %d x %s (estimate %d)", p.qty, p.name, p.estimate or 0)
  -- only a purchase that never got a price is let go here; a quoted one has its own wait
  C_Timer.After(BUY_TIMEOUT, function()
    if current == p and not p.total and not p.confirming then
      GW.Purchase.Cancel(p)
      tell(p, "noPrice")
    end
  end)
  return p
end

--- Gives up waiting for the answer to a confirmed purchase: it may or may not have gone through, and
--- a late answer still counts.
---@param p GoldwrightPurchase
---@param reason string "timeout" or "closed"
local function giveUp(p, reason)
  if current == p then current = nil end
  p.unansweredAt = GetTime()
  unanswered = p
  GW.Log("purchase unanswered: %d x %s (%s)", p.qty, p.name, reason)
  tell(p, "unanswered", reason)
end

--- Confirms the quoted price: the purchase goes through at it.
---@param p GoldwrightPurchase
---@return boolean sent false when there's no price yet, it's too soon after the quote, or it's already on its way
function GW.Purchase.Confirm(p)
  if not GW.Purchase.CanConfirm(p) then return false end
  p.confirming = true
  if p.gear then
    C_AuctionHouse.PlaceBid(p.auctionID, p.total) -- the buyout: the auction is bought outright
  else
    C_AuctionHouse.ConfirmCommoditiesPurchase(p.itemID, p.qty)
  end
  GW.Log("purchase confirm: %d x %s for %d", p.qty, p.name, p.total)
  C_Timer.After(CONFIRM_TIMEOUT, function()
    if current == p and not p.done then giveUp(p, "timeout") end
  end)
  return true
end

--- The auction house's answers about our purchase.
---@param event string
---@param a1 any unit price (COMMODITY_PRICE_UPDATED)
---@param a2 any total price (COMMODITY_PRICE_UPDATED)
local function onEvent(event, a1, a2)
  if event == "AUCTION_HOUSE_CLOSED" then
    local p = current
    current = nil
    if p and p.confirming and not p.done then giveUp(p, "closed") end
    return
  end
  if unanswered and GetTime() - (unanswered.unansweredAt or 0) > LATE_RESULT_WINDOW then unanswered = nil end
  local p = current
  if not p then
    -- the answer to a purchase we stopped waiting for
    if unanswered and not unanswered.gear and event:find("^COMMODITY_PURCHASE") then
      local late = unanswered
      unanswered = nil
      tell(late, event == "COMMODITY_PURCHASE_SUCCEEDED" and "lateBought" or "lateFailed")
    elseif
      unanswered
      and unanswered.gear
      and event == "AUCTION_HOUSE_PURCHASE_COMPLETED"
      and a1 == unanswered.auctionID
    then
      local late = unanswered
      unanswered = nil
      tell(late, "lateBought")
    end
    return
  end
  if p.gear then
    -- gear answers with its own events; the commodity ones aren't ours
    if not p.confirming then return end
    if event == "AUCTION_HOUSE_PURCHASE_COMPLETED" and a1 == p.auctionID then
      p.done, current = true, nil
      tell(p, "bought")
    elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
      current = nil
      local gone = Enum and Enum.AuctionHouseError and a1 == Enum.AuctionHouseError.DatabaseError
      GW.Log("purchase gear error %s", tostring(a1))
      tell(p, gone and "unavailable" or "failed", tostring(a1))
    end
    return
  end
  if event == "COMMODITY_PRICE_UPDATED" then
    if p.confirming then return end
    p.unit, p.total, p.quotedAt = a1, a2, GetTime()
    local quote = {}
    p.quote = quote
    C_Timer.After(QUOTE_TIMEOUT, function()
      if current == p and p.quote == quote and not p.confirming and not p.done then
        GW.Purchase.Cancel(p)
        tell(p, "expired")
      end
    end)
    tell(p, "quote")
    -- Confirm becomes possible after the pause: let the tab redraw then
    C_Timer.After(GW.CONFIRM_DELAY + 0.05, function()
      if current == p and not p.confirming then tell(p, "ready") end
    end)
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
    if p.confirming then return end
    current = nil
    tell(p, "unavailable")
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
    p.done, current = true, nil
    tell(p, "bought")
  elseif event == "COMMODITY_PURCHASE_FAILED" then
    current = nil
    tell(p, "failed")
  end
end

local events = CreateFrame("Frame")
for _, e in ipairs({
  "COMMODITY_PRICE_UPDATED",
  "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED",
  "COMMODITY_PURCHASE_FAILED",
  "AUCTION_HOUSE_PURCHASE_COMPLETED",
  "AUCTION_HOUSE_SHOW_ERROR",
  "AUCTION_HOUSE_CLOSED",
}) do
  pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, a1, a2) onEvent(event, a1, a2) end)

--- For tests: forgets every purchase.
function GW.Purchase.Reset()
  current, unanswered = nil, nil
end
