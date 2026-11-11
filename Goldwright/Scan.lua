--- Full scan (SCAN-1..5) and the Scan tab: C_AuctionHouse.ReplicateItems reads every listing at this
--- auction house, the result is stored per house in GoldwrightScans as market stats per item (not the
--- raw listings) and replaces the data pack's current prices for that house (Core.lua GW.ItemData).
local _, GW = ...

-- ReplicateItems on Forever, verified 2026-11-09 with the GoldwrightDev tool:
-- - the server answers in ~17-18 s with REPLICATE_ITEM_LIST_UPDATE, ~172,000 rows, 0-based;
-- - the item id is the 17th value of GetReplicateItemInfo;
-- - buyout is the listing's total (commodities come split into rows);
-- - one scan that returns data per ~15 min per account is allowed (rejected requests don't count).
local ROWS_PER_TICK = 4000 -- rows read per frame (172k rows in ~2.5 s, verified)
local ITEMS_PER_TICK = 600 -- items priced per frame
local TIMEOUT = 90 -- no data after this many seconds means the server ignored the request
local KEEP_HISTORY = 3
GW.SCAN_COOLDOWN = 15 * 60

-- Q2 (open): which auction houses are Blackwater. Until confirmed, these zones count as neutral.
local NEUTRAL_ZONES = { ["Booty Bay"] = true, ["Gadgetzan"] = true, ["Everlook"] = true }

local UI = GW.UI
local fs, setColor = UI.FontString, UI.SetColor
local GREY = UI.GREY

--- The scan in progress. Fields appear as the scan moves through its phases.
---@class ScanRun
---@field phase "waiting"|"reading"|"pricing" waiting for the server, reading rows, or pricing items
---@field started number GetTime() when the scan was requested
---@field requestedAt number server time of the request
---@field side string house the scan is for: "A", "H" or "N"
---@field early boolean requested before the 15-minute cooldown had passed
---@field dataAfter number? seconds from the request until the server sent data
---@field total number? number of rows the server sent
---@field dataAt number? server time the data arrived
---@field index number? next row to read
---@field first number? first row index (0 on Forever, 1 if the client is 1-based)
---@field last number? last row index
---@field agg table<number, table<number, number>>? itemID -> unit price -> quantity; nil once saved
---@field itemCount number? distinct items seen so far
---@field skipped number? rows skipped (bid-only or no item id)
---@field keys number[]? item ids to price
---@field ki number? next index into keys
---@field out table<number, string>? itemID -> packed stats string, as stored in GoldwrightScans
local run -- nil when idle
local view -- the Scan tab

--- The saved-variables table for scans, with its sub-tables created.
---@return table GoldwrightScans
local function db()
  GoldwrightScans = GoldwrightScans or {}
  GoldwrightScans.houses = GoldwrightScans.houses or {}
  GoldwrightScans.history = GoldwrightScans.history or {}
  return GoldwrightScans
end

---------------------------------------------------------------------------
-- shared helpers (tooltip, Sell, launcher)
---------------------------------------------------------------------------

--- Which house the open auction house is: Blackwater in neutral towns, else your faction's.
---@return string side "A", "H" or "N"
function GW.AuctionSide()
  local sub = GetSubZoneText and GetSubZoneText() or ""
  local zone = GetZoneText and GetZoneText() or ""
  if NEUTRAL_ZONES[sub] or NEUTRAL_ZONES[zone] then return "N" end
  return GW.House().side
end

--- Your saved scans for this region and ruleset, by house side.
---@return table<string, { at: number, total: number, items: table<number, string> }> scans e.g. { A = ..., N = ... }
function GW.HouseScans()
  local houses = GoldwrightScans and GoldwrightScans.houses
  if not houses then return {} end
  local h = GW.House()
  local out = {}
  for _, side in ipairs({ "A", "H", "N" }) do
    local s = houses[h.packKey .. ":" .. side]
    if s and s.items and s.at then out[side] = s end
  end
  return out
end

--- Account-wide: when a full scan last returned data (also counts scans by the GoldwrightDev tool).
---@return number serverTime 0 when there was none
function GW.LastScanDataAt()
  local a = GoldwrightScans and GoldwrightScans.lastDataAt or 0
  local b = type(GoldwrightDevAH) == "table" and GoldwrightDevAH.lastDataAt or 0
  return math.max(a, b)
end

--- Seconds until the next full scan is expected to be allowed.
---@return number seconds 0 when a scan can be requested now
function GW.ScanCooldownLeft()
  local last = GW.LastScanDataAt()
  if last == 0 then return 0 end
  return math.max(0, last + GW.SCAN_COOLDOWN - GetServerTime())
end

--- Formats seconds as "m:ss".
---@param sec number seconds
---@return string text
function GW.ClockText(sec)
  sec = math.max(0, math.floor(sec + 0.5))
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

--- Whether a full scan is in progress.
---@return boolean
function GW.ScanRunning() return run ~= nil end

--- When a house was last scanned, e.g. "14:03 (5 min ago)".
---@param side string|nil house ("A", "H", "N"); default your faction's
---@return string|nil text nil when that house has no saved scan
function GW.LastScanText(side)
  local s = GW.HouseScans()[side or (GW.house and GW.house.side) or "A"]
  if not s then return nil end
  return string.format("%s (%s)", date("%H:%M", s.at), GW.Age(s.at))
end

local n = GW.Number

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

--- Writes a number in base 36 (rounded) to keep the saved scan small.
---@param x number? value
---@return string digits "" for nil, zero or negative values
local function b36(x)
  if not x or x <= 0 then return "" end
  x = math.floor(x + 0.5)
  local s = ""
  while x > 0 do
    local d = x % 36
    s = DIGITS:sub(d + 1, d + 1) .. s
    x = math.floor(x / 36)
  end
  return s
end

---------------------------------------------------------------------------
-- the scan
---------------------------------------------------------------------------
local render -- defined with the view

--- Ends the running scan, records the outcome in GW.lastScan and redraws the tab.
---@param outcome string "saved", "empty", "timeout", "closed" or "error"
---@param detail any extra information (the error message for "error")
local function finish(outcome, detail)
  local r = run
  if not r then return end
  run = nil
  GW.lastScan = {
    outcome = outcome,
    detail = detail,
    requestedAt = r.requestedAt,
    dataAt = r.dataAt,
    total = r.total,
    items = r.itemCount,
    secs = GetTime() - r.started,
    side = r.side,
  }
  GW.Log(
    "scan %s: %s rows, data after %s s, %s",
    outcome,
    tostring(r.total),
    r.dataAfter and string.format("%.1f", r.dataAfter) or "-",
    tostring(detail)
  )
  if render then render() end
end

--- Wraps a step so an error ends the scan with a message instead of a Lua error.
---@param fn function the step
---@return function wrapped
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    if not ok then finish("error", tostring(err)) end
  end
end

--- Pricing phase: turns each item's price/quantity totals into market stats, ITEMS_PER_TICK per frame,
--- then saves the result for this house.
local priceStep
priceStep = guarded(function()
  local r = run
  if not (r and r.phase == "pricing") then return end
  for _ = 1, ITEMS_PER_TICK do
    local id = r.keys[r.ki]
    if not id then break end
    local list = {}
    for price, qty in pairs(r.agg[id]) do
      list[#list + 1] = { price = price, qty = qty }
    end
    local s = GW.MarketStats(list)
    if s then
      -- stored as "mv,minReal,units,baitPrice,baitUnits" in base 36, trailing empty fields dropped
      r.out[id] = (
        table
          .concat({ b36(s.mv), b36(s.minReal), b36(s.units), b36(s.baitPrice), b36(s.baitUnits) }, ",")
          :gsub(",+$", "")
      )
    end
    r.ki = r.ki + 1
  end
  if r.ki <= #r.keys then
    if render then render() end
    C_Timer.After(0, priceStep)
    return
  end
  -- done: store, and let tooltips and the Sell panel use it right away (SCAN-3)
  local d = db()
  local h = GW.House()
  d.houses[h.packKey .. ":" .. r.side] = { at = r.dataAt, total = r.total, items = r.out }
  table.insert(d.history, 1, {
    at = r.dataAt,
    total = r.total,
    secs = math.floor(GetTime() - r.started + 0.5),
    house = string.format("%s · %s · %s", h.region, h.ruleset, GW.HOUSE_NAMES[r.side]),
  })
  while #d.history > KEEP_HISTORY do
    table.remove(d.history)
  end
  r.agg = nil
  GW.ResetCache()
  finish("saved")
  GW.ApplyOptions() -- open panels redraw with the new prices
end)

--- Reading phase: adds up quantity per item and unit price, ROWS_PER_TICK rows per frame, then starts
--- the pricing phase.
local readStep
readStep = guarded(function()
  local r = run
  if not (r and r.phase == "reading") then return end
  local stop = math.min(r.index + ROWS_PER_TICK - 1, r.last)
  local agg = r.agg
  for i = r.index, stop do
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
    if type(itemID) == "number" and buyout and buyout > 0 and count and count > 0 then
      local unit = math.floor(buyout / count + 0.5)
      local m = agg[itemID]
      if not m then
        m = {}
        agg[itemID] = m
        r.itemCount = r.itemCount + 1
      end
      m[unit] = (m[unit] or 0) + count
    else
      r.skipped = r.skipped + 1 -- bid-only or no item id
    end
  end
  r.index = stop + 1
  if r.index <= r.last then
    if render then render() end
    C_Timer.After(0, readStep)
    return
  end
  r.phase = "pricing"
  r.keys, r.ki, r.out = {}, 1, {}
  for id in pairs(agg) do
    r.keys[#r.keys + 1] = id
  end
  if render then render() end
  C_Timer.After(0, priceStep)
end)

--- REPLICATE_ITEM_LIST_UPDATE: the server sent the listings; starts the reading phase.
local function onData()
  local r = run
  if not (r and r.phase == "waiting") then return end
  r.dataAfter = GetTime() - r.started
  local total = C_AuctionHouse.GetNumReplicateItems() or 0
  if total == 0 then return finish("empty") end
  r.total = total
  r.dataAt = GetServerTime()
  db().lastDataAt = r.dataAt -- the cooldown counts from scans that returned data (SCAN-5)
  r.index = 0
  -- 0-based on Forever; tolerate 1-based
  if
    select(17, C_AuctionHouse.GetReplicateItemInfo(0)) == nil
    and select(17, C_AuctionHouse.GetReplicateItemInfo(total)) ~= nil
  then
    r.index = 1
  end
  r.first = r.index
  r.last = r.index + total - 1
  r.agg, r.itemCount, r.skipped = {}, 0, 0
  r.phase = "reading"
  if render then render() end
  C_Timer.After(0, readStep)
end

--- Requests a full scan (SCAN-1). Prints why when it can't start.
---@param anyway boolean request even though the cooldown hasn't passed (the server may ignore it)
function GW.StartScan(anyway)
  if run then return GW.Print("A full scan is already running.") end
  if not (GW.AuctionHouseOpen and GW.AuctionHouseOpen()) then return GW.Print("Open the auction house first.") end
  if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then
    return GW.Print("This client has no full-scan API.")
  end
  local left = GW.ScanCooldownLeft()
  if left > 0 and not anyway then
    return GW.Print("The next full scan is available in %s (15 minutes after your last one).", GW.ClockText(left))
  end
  ---@type ScanRun
  local r =
    { phase = "waiting", started = GetTime(), requestedAt = GetServerTime(), side = GW.AuctionSide(), early = left > 0 }
  run = r
  GW.lastScan = nil
  C_AuctionHouse.ReplicateItems()
  GW.Log("scan requested (side %s, cooldown left %d s)", r.side, left)
  if render then render() end
  C_Timer.After(TIMEOUT, function()
    if run == r and r.phase == "waiting" then finish("timeout") end
  end)
end

local events = CreateFrame("Frame")
pcall(events.RegisterEvent, events, "REPLICATE_ITEM_LIST_UPDATE")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:SetScript("OnEvent", function(_, event)
  if event == "REPLICATE_ITEM_LIST_UPDATE" then
    guarded(onData)()
  elseif event == "AUCTION_HOUSE_CLOSED" and run then
    finish("closed")
  end
end)

---------------------------------------------------------------------------
-- the Scan tab
---------------------------------------------------------------------------

--- What the tab shows for the running scan, the last outcome, or the idle state.
---@return string title
---@return string detail
---@return number progress 0..1 for the progress bar
---@return number[] color title colour {r, g, b}
local function statusText()
  local h = GW.House()
  if run then
    if run.phase == "waiting" then
      return "Waiting for the server…",
        string.format(
          "%d s · usually about 18 s · keep the auction house open%s",
          math.floor(GetTime() - run.started),
          run.early and " · requested before the 15 minutes were up, so the server may ignore it" or ""
        ),
        0,
        GREY
    elseif run.phase == "reading" then
      local p = (run.index - run.first) / run.total
      return string.format("Reading %s listings… %d%%", n(run.total), math.floor(p * 100)),
        "Keep the auction house open",
        p * 0.8,
        GREY
    else
      local p = (run.ki - 1) / math.max(1, #run.keys)
      return string.format("Working out prices for %s items… %d%%", n(#run.keys), math.floor(p * 100)),
        "Keep the auction house open",
        0.8 + p * 0.2,
        GREY
    end
  end
  local last = GW.lastScan
  if last then
    if last.outcome == "saved" then
      return string.format("Scanned %s listings at %s", n(last.total), date("%H:%M", last.dataAt)),
        string.format("Your prices are now current for %s · %s · %s.", h.region, h.ruleset, GW.HOUSE_NAMES[last.side]),
        1,
        GW.SIGNAL_BLUE
    elseif last.outcome == "empty" or last.outcome == "timeout" then
      local next = GW.LastScanDataAt() > 0 and GW.LastScanDataAt() + GW.SCAN_COOLDOWN or nil
      return "The server didn't send data",
        "Full scans are limited to one every 15 minutes per account."
          .. (
            next and next > GetServerTime() and (" Try again at " .. date("%H:%M", next) .. ".")
            or " Try again in a few minutes."
          ),
        0,
        GW.SIGNAL_ORANGE
    elseif last.outcome == "closed" then
      return "The auction house closed before the scan finished",
        "Nothing was saved. The 15 minutes count from when the server sent data.",
        0,
        GW.SIGNAL_ORANGE
    else
      return "The scan failed", tostring(last.detail or ""), 0, GW.SIGNAL_ORANGE
    end
  end
  return "Full scan",
    "Reads every listing at this auction house, about 170,000, in roughly 40 seconds. Tooltips and Sell then use prices current to the minute.",
    0,
    { 1, 1, 1 }
end

--- Redraws the Scan tab: status, progress bar, start button and recent scans.
render = function()
  if not (view and view:IsShown()) then return end
  local title, detail, progress, color = statusText()
  view.title:SetText(title)
  setColor(view.title, color)
  view.detail:SetText(detail)
  view.bar:SetValue(progress)
  view.bar:SetShown(run ~= nil or (GW.lastScan and GW.lastScan.outcome == "saved") or false)

  local left = GW.ScanCooldownLeft()
  if run then
    view.start:SetText("Scanning…")
    view.start:Disable()
    view.anyway:Hide()
  elseif left > 0 then
    view.start:SetText("Next Scan in " .. GW.ClockText(left))
    view.start:Disable()
    -- right after your own successful scan the countdown is certain: no "anyway"
    view.anyway:SetShown(not (GW.lastScan and GW.lastScan.outcome == "saved"))
  else
    view.start:SetText("Start Full Scan")
    view.start:Enable()
    view.anyway:Hide()
  end

  local hist = (GoldwrightScans and GoldwrightScans.history) or {}
  for i, line in ipairs(view.history) do
    local x = hist[i]
    line:SetText(
      x
          and string.format(
            "%s  ·  %s listings  ·  %d s  ·  %s",
            date("%H:%M", x.at),
            n(x.total),
            x.secs or 0,
            x.house or ""
          )
        or ""
    )
  end
  view.histHeader:SetShown(#hist > 0)
end

--- Redraws once a second while the tab is shown (countdown and waiting time).
local function tick()
  if not (view and view:IsShown()) then return end
  render()
  C_Timer.After(1, tick)
end

--- Creates the Scan tab's frames.
---@param parent table the panel's inset frame
local function build(parent)
  view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints()

  view.title = fs(view, "GameFontNormalHuge", "LEFT")
  view.title:SetPoint("TOPLEFT", 40, -40)
  view.title:SetWidth(880)
  view.detail = fs(view, "GameFontHighlight", "LEFT")
  view.detail:SetPoint("TOPLEFT", 40, -76)
  view.detail:SetWidth(880)

  view.bar = CreateFrame("StatusBar", nil, view)
  view.bar:SetSize(600, 14)
  view.bar:SetPoint("TOPLEFT", 40, -112)
  view.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  view.bar:SetStatusBarColor(GW.GOLD[1], GW.GOLD[2], GW.GOLD[3])
  view.bar:SetMinMaxValues(0, 1)
  local bg = view.bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 1, 1, 0.08)

  view.start = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
  view.start:SetSize(240, 32)
  view.start:SetPoint("TOPLEFT", 40, -146)
  view.start:SetScript("OnClick", function() GW.StartScan(false) end)
  -- A quiet text link, not a button: the server almost always ignores an early request.
  view.anyway = CreateFrame("Button", nil, view)
  view.anyway:SetSize(320, 20)
  view.anyway:SetPoint("LEFT", view.start, "RIGHT", 14, 0)
  view.anyway:SetNormalFontObject("GameFontDisableSmall")
  view.anyway:SetHighlightFontObject("GameFontHighlightSmall")
  view.anyway:SetText("or scan anyway (the server may ignore it)")
  view.anyway:GetFontString():SetPoint("LEFT")
  view.anyway:SetScript("OnClick", function() GW.StartScan(true) end)
  view.anyway:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(
      "The 15-minute clock is our estimate. The server may ignore an early request; that doesn't reset the clock.",
      1,
      1,
      1,
      1,
      true
    )
    GameTooltip:Show()
  end)
  view.anyway:SetScript("OnLeave", function() GameTooltip:Hide() end)

  view.histHeader = fs(view, "GameFontNormal", "LEFT")
  view.histHeader:SetPoint("TOPLEFT", 40, -210)
  view.histHeader:SetText("Recent scans")
  view.history = {}
  for i = 1, KEEP_HISTORY do
    local l = fs(view, "GameFontHighlight", "LEFT")
    l:SetPoint("TOPLEFT", 40, -210 - i * 20)
    view.history[i] = l
  end
  local note = fs(view, "GameFontDisableSmall", "LEFT")
  note:SetPoint("BOTTOMLEFT", 40, 20)
  note:SetWidth(880)
  note:SetText(
    "The server allows one full scan every 15 minutes per account. Results are kept per auction house and replace the data pack's current prices until the next data pack is newer."
  )
end

--- The Scan tab, shown and hidden by the panel's tab bar (SellPanel.lua).
GW.ScanView = {}

--- Shows the tab, building it on first use.
---@param parent table the panel's inset frame
function GW.ScanView.Show(parent)
  if not view then build(parent) end
  view:Show()
  tick()
end

--- Hides the tab (a running scan keeps going).
function GW.ScanView.Hide()
  if view then view:Hide() end
end

--- For tests and /dump: the running scan and the tab's frame.
---@return ScanRun|nil run
---@return table|nil view
function GW.ScanView.Debug() return run, view end
