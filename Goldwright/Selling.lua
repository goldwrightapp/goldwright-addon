-- Selling and cancelling rules without any UI (SELL-4, 7, 8, 13; CXL-2, 6), so they can be tested
-- outside the game (server/test/addon.test.mjs).
local _, GW = ...

-- Gear (non-commodity) auctions only take whole silver: the server answers a buyout with copper in
-- it with "Internal auction error" (seen in game 2026-11-10; all 111,406 item buyouts in a US
-- snapshot are whole silver). Commodities take any copper price.
function GW.SilverFloor(copper)
  return math.max(100, math.floor(copper / 100) * 100)
end

-- SELL-4: price to post against the cheapest real listing, per the undercut setting. Matching your
-- own cheapest listing never undercuts yourself. `wholeSilver` for gear: undercut by 1s, not 1c.
function GW.UndercutPrice(cheapest, own, wholeSilver)
  if not cheapest or cheapest <= 0 then return nil end
  local rule = GW.Opt("undercut")
  local p
  if own or rule == "match" then
    p = cheapest
  elseif rule == "pct" then
    p = math.max(1, math.floor(cheapest * (1 - GW.Opt("undercutPct") / 100)))
  else
    p = math.max(1, cheapest - 1)
  end
  if wholeSilver then
    if p < cheapest then return GW.SilverFloor(p) end -- the next whole silver below
    return GW.SilverFloor(cheapest)
  end
  return p
end

-- One line explaining the undercut rule ("1c under", "1s under" for gear, "matching", "5% under").
function GW.UndercutText(wholeSilver)
  local rule = GW.Opt("undercut")
  if rule == "match" then return "matching" end
  if rule == "pct" then return GW.Opt("undercutPct") .. "% under" end
  return wholeSilver and "1s under" or "1c under"
end

-- SELL-7 / SELL-8: how a unit price compares with normal. Returns kind, pct where kind is
-- "below" (under the warning threshold), "above" (over the overpricing threshold), "under", "over"
-- or "at"; nil without a price or normal.
function GW.PriceCheck(unit, normal)
  if not (unit and unit > 0 and normal and normal > 0) then return nil end
  local ratio = unit / normal
  local pct = math.floor(math.abs(1 - ratio) * 100 + 0.5)
  if ratio < GW.Opt("belowPct") / 100 then return "below", pct end
  if ratio > GW.Opt("abovePct") / 100 then return "above", pct end
  if pct == 0 then return "at", 0 end
  return ratio < 1 and "under" or "over", pct
end

-- SELL-13: what to select after posting `postedID`. `before` is the bag list in the order shown
-- when you posted, `after` the list rescanned afterwards. Gear posts one auction per click, so with
-- copies left (`keepSame`) the same item stays selected; otherwise the next item below it that is
-- still in your bags. Returns nil at the end of the list (we don't jump back to items you skipped).
function GW.NextInQueue(before, after, postedID, keepSame)
  local present = {}
  for _, g in ipairs(after) do present[g.itemID] = g end
  if keepSame and present[postedID] then return present[postedID] end
  local idx
  for i, g in ipairs(before) do
    if g.itemID == postedID then idx = i break end
  end
  if not idx then return nil end
  for i = idx + 1, #before do
    local g = present[before[i].itemID]
    if g and g.itemID ~= postedID then return g end
  end
  return nil
end

-- CXL-2: one of your auctions against that item's current listings.
-- listings: { price, qty, own, ownQty } as the search returns them; a commodity row that holds your
-- units can hold other sellers' units at the same price (qty - ownQty).
-- Returns status ("lowest" / "undercut"), the cheapest other real price, and the price of bait
-- listings under yours that were ignored (or nil).
function GW.AuctionStatus(myUnit, listings)
  local others = {}
  for _, x in ipairs(listings or {}) do
    local q = x.qty or 0
    if x.own then q = q - (x.ownQty or q) end
    if q > 0 and x.price and x.price > 0 then others[#others + 1] = { price = x.price, qty = q } end
  end
  local s = #others > 0 and GW.MarketStats(others)
  if not s then return "lowest", nil, nil end
  local now = s.sorted[s.firstRealIndex].price
  if now < myUnit then return "undercut", now, nil end
  local bait = s.baitUnits > 0 and s.baitPrice < myUnit and s.baitPrice or nil
  return "lowest", now, bait
end

-- CXL-6: the first undercut auction in list order that can still be cancelled.
function GW.NextUndercut(rows)
  for _, r in ipairs(rows) do
    if r.status == "undercut" and not r.cancelling and not r.sold then return r end
  end
  return nil
end

-- "1 h 20 min" / "23 h" from seconds; the time-left band name when the client gives no seconds.
local BANDS = { [0] = "Short", [1] = "Medium", [2] = "Long", [3] = "Very long" }
function GW.TimeLeftText(seconds, band)
  if seconds and seconds > 0 then
    local h, m = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)
    if h >= 2 then return h .. " h" end
    if h == 1 then return "1 h " .. m .. " min" end
    return math.max(1, m) .. " min"
  end
  return BANDS[band] or "?"
end

---------------------------------------------------------------------------
-- Charts (SELL-15, SELL-16): the numbers behind the two Sell-panel charts, without any UI.
---------------------------------------------------------------------------
GW.HISTORY_MIN_DAYS = 7 -- the price history chart shows once this many days have a price

-- SELL-15: the last `days` daily prices of a 30-day history (index 1 = the day starting at
-- histFrom). The window ends on the day of `endEpoch` (the pack's snapshot), else on the last day
-- with a price. Returns { values = [days] (nil = no price that day), firstDay = epoch of
-- values[1]'s UTC midnight, known = prices in the window, total = prices in all 30 days,
-- avg = mean of all of them }, or nil without history.
function GW.HistoryWindow(hist, histFrom, endEpoch, days)
  if not (hist and histFrom) then return nil end
  local n, last, total, sum = 0, nil, 0, 0
  for i, v in pairs(hist) do
    if type(i) == "number" and i > n then n = i end
  end
  for i = 1, n do
    if hist[i] then last, total, sum = i, total + 1, sum + hist[i] end
  end
  if total == 0 then return nil end
  local endIdx = last
  if endEpoch and endEpoch >= histFrom then endIdx = math.min(math.max(n, 30), math.floor((endEpoch - histFrom) / 86400) + 1) end
  local values, known = {}, 0
  local first = endIdx - days + 1
  for k = 1, days do
    local v = hist[first + k - 1]
    values[k] = v
    if v then known = known + 1 end
  end
  return { values = values, firstDay = histFrom + (first - 1) * 86400, known = known, total = total, avg = sum / total }
end

-- Hours the player's clock is ahead of UTC (e.g. -5 in New York in winter, 5.5 in India), from
-- the game's date(): local time against UTC at the same moment.
function GW.UTCOffsetHours(now)
  local l, u = date("*t", now), date("!*t", now)
  local days = 0
  if l.year ~= u.year then days = l.year > u.year and 1 or -1
  else days = l.yday - u.yday end
  return days * 24 + (l.hour - u.hour) + (l.min - u.min) / 60
end

-- An hour-of-day profile (indexed by UTC hour + 1) rearranged to local hours: units[1] / prices[1]
-- are local midnight to 1am. `offset` = whole hours ahead of UTC.
function GW.LocalHours(hours, offset)
  local units, prices = {}, {}
  offset = math.floor((offset or 0) + 0.5)
  for h = 0, 23 do
    local utc = (h - offset) % 24
    units[h + 1] = hours.units and hours.units[utc + 1]
    prices[h + 1] = hours.prices and hours.prices[utc + 1]
  end
  return units, prices
end

-- "12am", "9am", "12pm", "6pm" for a local hour 0..23 (24 wraps to midnight).
function GW.HourLabel(h)
  h = h % 24
  if h == 0 then return "12am" end
  if h == 12 then return "12pm" end
  return h < 12 and (h .. "am") or ((h - 12) .. "pm")
end

GW.POST_WINDOW = 4     -- hours in the "best time to post" window
GW.FLAT_SUPPLY = 0.9   -- a window under 90% of the day's average supply is worth pointing out

-- SELL-16: the 4-hour window (in local time) with the fewest units listed on average. A window
-- needs at least 3 of its 4 hours known (the server sends profiles with up to 4 empty hours).
-- Ties go to the higher average price, then to the earlier start after midnight.
-- Returns { start, stop (local hours, stop exclusive, may wrap), units, price, dayUnits, ratio,
-- flat } or nil when no window has enough data. `flat` = supply barely changes over the day.
function GW.BestPostWindow(hours, offset)
  if not (hours and hours.units) then return nil end
  local units, prices = GW.LocalHours(hours, offset)
  local daySum, dayN = 0, 0
  for h = 1, 24 do
    if units[h] then daySum, dayN = daySum + units[h], dayN + 1 end
  end
  if dayN == 0 then return nil end
  local best
  for s = 0, 23 do
    local uSum, uN, pSum, pN = 0, 0, 0, 0
    for k = 0, GW.POST_WINDOW - 1 do
      local idx = (s + k) % 24 + 1
      if units[idx] then uSum, uN = uSum + units[idx], uN + 1 end
      if prices[idx] then pSum, pN = pSum + prices[idx], pN + 1 end
    end
    if uN >= GW.POST_WINDOW - 1 then
      local avg, price = uSum / uN, pN > 0 and pSum / pN or nil
      local better = not best or avg < best.units - 1e-9
      if best and not better and math.abs(avg - best.units) <= 1e-9 then
        better = (price or -1) > (best.price or -1)
      end
      if better then best = { start = s, stop = (s + GW.POST_WINDOW) % 24, units = avg, price = price } end
    end
  end
  if not best then return nil end
  best.dayUnits = daySum / dayN
  best.ratio = best.dayUnits > 0 and best.units / best.dayUnits or 1
  best.flat = best.ratio >= GW.FLAT_SUPPLY
  return best
end

-- The callout under the hour chart.
function GW.BestPostText(win)
  if not win then return nil end
  if win.flat then return "Supply is about the same all day: post whenever suits you." end
  return string.format("Supply is lowest %s–%s: listings sell fastest.", GW.HourLabel(win.start), GW.HourLabel(win.stop))
end
