--- Selling and cancelling rules without any UI (SELL-4, 7, 8, 13, 15, 16; CXL-2, 6), so they can be
--- tested outside the game (server/test/addon.test.mjs).
local _, GW = ...

--- Rounds a gear buyout down to whole silver, at least 1s. Gear (non-commodity) auctions only
--- take whole silver: the server answers a buyout with copper in it with "Internal auction error"
--- (seen in game 2026-11-10; all 111,406 item buyouts in a US snapshot are whole silver).
--- Commodities take any copper price.
---@param copper number price in copper
---@return number copper whole silver, at least 100
function GW.SilverFloor(copper) return math.max(100, math.floor(copper / 100) * 100) end

--- SELL-4: the price to post against the cheapest real listing, per the undercut setting.
--- Matching your own cheapest listing never undercuts yourself.
---@param cheapest number|nil cheapest real unit price in copper
---@param own boolean|nil the cheapest listing is the player's own
---@param wholeSilver boolean|nil gear: undercut by 1s, not 1c, and post whole silver
---@return number|nil copper nil without a cheapest price
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

--- One phrase explaining the undercut rule: "1c under", "1s under" for gear, "matching" or "5% under".
---@param wholeSilver boolean|nil gear
---@return string text
function GW.UndercutText(wholeSilver)
  local rule = GW.Opt("undercut")
  if rule == "match" then return "matching" end
  if rule == "pct" then return GW.Opt("undercutPct") .. "% under" end
  return wholeSilver and "1s under" or "1c under"
end

--- SELL-7 / SELL-8: how a unit price compares with normal. The kind is "below" (under the warning
--- threshold), "above" (over the overpricing threshold), "under", "over" or "at".
---@param unit number|nil unit price in copper
---@param normal number|nil normal price in copper
---@return string|nil kind nil without a price or normal
---@return number|nil pct distance from normal in %, rounded
function GW.PriceCheck(unit, normal)
  if not (unit and unit > 0 and normal and normal > 0) then return nil end
  local ratio = unit / normal
  local pct = math.floor(math.abs(1 - ratio) * 100 + 0.5)
  if ratio < GW.Opt("belowPct") / 100 then return "below", pct end
  if ratio > GW.Opt("abovePct") / 100 then return "above", pct end
  if pct == 0 then return "at", 0 end
  return ratio < 1 and "under" or "over", pct
end

--- SELL-13: what to select after posting `postedID`. Gear posts one auction per click, so with
--- copies left (`keepSame`) the same item stays selected; otherwise the next item below it that is
--- still in your bags. We don't jump back to items you skipped.
---@param before table[] bag list (entries with `itemID`) in the order shown when you posted
---@param after table[] the bag list rescanned afterwards
---@param postedID number item id just posted
---@param keepSame boolean|nil keep the same item selected while copies are left
---@return table|nil entry the entry from `after` to select, nil at the end of the list
function GW.NextInQueue(before, after, postedID, keepSame)
  local present = {}
  for _, g in ipairs(after) do
    present[g.itemID] = g
  end
  if keepSame and present[postedID] then return present[postedID] end
  local idx
  for i, g in ipairs(before) do
    if g.itemID == postedID then
      idx = i
      break
    end
  end
  if not idx then return nil end
  for i = idx + 1, #before do
    local g = present[before[i].itemID]
    if g and g.itemID ~= postedID then return g end
  end
  return nil
end

--- CXL-2: checks one of your auctions against that item's current listings. A commodity row that
--- holds your units can hold other sellers' units at the same price (qty - ownQty).
---@param myUnit number your unit price in copper
---@param listings table[]|nil `{ price, qty, own, ownQty }` rows as the search returns them
---@return string status "lowest" or "undercut"
---@return number|nil now the cheapest other real price
---@return number|nil bait price of bait listings under yours that were ignored
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

--- CXL-6: the first undercut auction in list order that can still be cancelled.
---@param rows table[] auction rows with `status`, `cancelling` and `sold`
---@return table|nil row
function GW.NextUndercut(rows)
  for _, r in ipairs(rows) do
    if r.status == "undercut" and not r.cancelling and not r.sold then return r end
  end
  return nil
end

local BANDS = { [0] = "Short", [1] = "Medium", [2] = "Long", [3] = "Very long" }

--- Time left as "1 h 20 min" / "23 h" from seconds; the time-left band name when the client gives
--- no seconds.
---@param seconds number|nil seconds left
---@param band number|nil time-left band (0..3)
---@return string text "?" when neither is known
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

--- The price history window GW.HistoryWindow returns.
---@class GoldwrightHistoryWindow
---@field values table<number, number> [days] daily prices (nil = no price that day)
---@field firstDay number server time of values[1]'s UTC midnight
---@field known number prices in the window
---@field total number prices in all 30 days
---@field avg number mean of all 30 days' prices

--- SELL-15: the last `days` daily prices of a 30-day history. The window ends on the day of
--- `endEpoch` (the pack's snapshot), else on the last day with a price.
---@param hist table<number, number>|nil daily prices, index 1 = the day starting at histFrom
---@param histFrom number|nil server time of day 1
---@param endEpoch number|nil server time the window ends on
---@param days number window length in days
---@return GoldwrightHistoryWindow|nil window nil without history
function GW.HistoryWindow(hist, histFrom, endEpoch, days)
  if not (hist and histFrom) then return nil end
  local n, last, total, sum = 0, nil, 0, 0
  for i, v in pairs(hist) do
    if type(i) == "number" and i > n then n = i end
  end
  for i = 1, n do
    if hist[i] then
      last, total, sum = i, total + 1, sum + hist[i]
    end
  end
  if total == 0 then return nil end
  local endIdx = last
  if endEpoch and endEpoch >= histFrom then
    endIdx = math.min(math.max(n, 30), math.floor((endEpoch - histFrom) / 86400) + 1)
  end
  local values, known = {}, 0
  local first = endIdx - days + 1
  for k = 1, days do
    local v = hist[first + k - 1]
    values[k] = v
    if v then known = known + 1 end
  end
  return { values = values, firstDay = histFrom + (first - 1) * 86400, known = known, total = total, avg = sum / total }
end

--- Hours the player's clock is ahead of UTC (e.g. -5 in New York in winter, 5.5 in India), from
--- the game's date(): local time against UTC at the same moment.
---@param now number|nil time to compare at (nil = now)
---@return number hours may be fractional
function GW.UTCOffsetHours(now)
  local l, u = date("*t", now), date("!*t", now)
  local days = 0
  if l.year ~= u.year then
    days = l.year > u.year and 1 or -1
  else
    days = l.yday - u.yday
  end
  return days * 24 + (l.hour - u.hour) + (l.min - u.min) / 60
end

--- Rearranges an hour-of-day profile (indexed by UTC hour + 1) to local hours: units[1] /
--- prices[1] are local midnight to 1am.
---@param hours { prices: number[]?, units: number[]? } profile from GW.Hours
---@param offset number|nil hours ahead of UTC (rounded to whole hours)
---@return table<number, number> units [24] by local hour + 1 (nil = no data)
---@return table<number, number> prices [24] by local hour + 1 (nil = no data)
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

--- "12am", "9am", "12pm", "6pm" for a local hour (24 wraps to midnight).
---@param h number hour 0..23
---@return string label
function GW.HourLabel(h)
  h = h % 24
  if h == 0 then return "12am" end
  if h == 12 then return "12pm" end
  return h < 12 and (h .. "am") or ((h - 12) .. "pm")
end

GW.POST_WINDOW = 4 -- hours in the "best time to post" window
GW.FLAT_SUPPLY = 0.9 -- a window under 90% of the day's average supply is worth pointing out

--- The best posting window GW.BestPostWindow returns.
---@class GoldwrightPostWindow
---@field start number first local hour (0..23)
---@field stop number local hour the window ends (exclusive, may wrap past midnight)
---@field units number average units listed in the window
---@field price number|nil average price in the window
---@field dayUnits number average units listed over the day
---@field ratio number units / dayUnits
---@field flat boolean supply barely changes over the day (ratio >= GW.FLAT_SUPPLY)

--- SELL-16: the 4-hour window (in local time) with the fewest units listed on average. A window
--- needs at least 3 of its 4 hours known (the server sends profiles with up to 4 empty hours).
--- Ties go to the higher average price, then to the earlier start after midnight.
---@param hours { prices: number[]?, units: number[]? }|nil profile from GW.Hours
---@param offset number|nil hours ahead of UTC
---@return GoldwrightPostWindow|nil window nil when no window has enough data
function GW.BestPostWindow(hours, offset)
  if not (hours and hours.units) then return nil end
  local units, prices = GW.LocalHours(hours, offset)
  local daySum, dayN = 0, 0
  for h = 1, 24 do
    if units[h] then
      daySum, dayN = daySum + units[h], dayN + 1
    end
  end
  if dayN == 0 then return nil end
  local best
  for s = 0, 23 do
    local uSum, uN, pSum, pN = 0, 0, 0, 0
    for k = 0, GW.POST_WINDOW - 1 do
      local idx = (s + k) % 24 + 1
      if units[idx] then
        uSum, uN = uSum + units[idx], uN + 1
      end
      if prices[idx] then
        pSum, pN = pSum + prices[idx], pN + 1
      end
    end
    if uN >= GW.POST_WINDOW - 1 then
      local avg, price = uSum / uN, pN > 0 and pSum / pN or nil
      local better = not best or avg < best.units - 1e-9
      if best and not better and math.abs(avg - best.units) <= 1e-9 then better = (price or -1) > (best.price or -1) end
      if better then best = { start = s, stop = (s + GW.POST_WINDOW) % 24, units = avg, price = price } end
    end
  end
  if not best then return nil end
  best.dayUnits = daySum / dayN
  best.ratio = best.dayUnits > 0 and best.units / best.dayUnits or 1
  best.flat = best.ratio >= GW.FLAT_SUPPLY
  return best
end

--- The callout under the hour chart.
---@param win GoldwrightPostWindow|nil window from GW.BestPostWindow
---@return string|nil text nil without a window
function GW.BestPostText(win)
  if not win then return nil end
  if win.flat then return "Supply is about the same all day: post whenever suits you." end
  return string.format(
    "Supply is lowest %s–%s: listings sell fastest.",
    GW.HourLabel(win.start),
    GW.HourLabel(win.stop)
  )
end
