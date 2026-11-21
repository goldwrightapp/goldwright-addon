--- The Sell tab's chart (SELL-15 price history, SELL-16 best time to post): one wide plot area in
--- the market card, a History / Best time to post switch above it. Each chart is an object of its
--- own (GoldwrightChart) drawn into the same place; only the chosen one shows. Line objects draw
--- price lines (bars or dots where CreateLine is missing), textures draw bars and reference lines.
--- Drawn once per selected item (or switch / settings change) from pooled objects: no OnUpdate, no
--- work while idle. The numbers come from Selling.lua (GW.HistoryWindow, ...), tested without the UI.
---
--- Each drawing keeps what it drew in plot coordinates (chart.marks: the days or hours with data).
--- Hovering a chart (#13) snaps a thin line to the nearest of those and shows its exact values in
--- the game tooltip; with a controller, A on the chart then left / right does the same. The hover
--- runs only while the mouse is over a chart. A click on a day opens the Market window (#16), whose
--- four tabs reuse the same chart pieces.
local _, GW = ...
local L = GW.L

local LABEL_PAD = 13 -- room for the small labels inside the plot
local DASH, DASH_GAP = 4, 4 -- the dashed reference line
-- "Nov 9" by month, so each language can put the day first ("9. Nov.").
local MONTH_DAY = {
  L["Jan %d"],
  L["Feb %d"],
  L["Mar %d"],
  L["Apr %d"],
  L["May %d"],
  L["Jun %d"],
  L["Jul %d"],
  L["Aug %d"],
  L["Sep %d"],
  L["Oct %d"],
  L["Nov %d"],
  L["Dec %d"],
}

--- A short date in the client's language: "Nov 9" (German "9. Nov.").
---@param t number time (seconds)
---@return string
function GW.DateLabel(t) return string.format(MONTH_DAY[tonumber(date("%m", t))], tonumber(date("%d", t))) end

local UI = GW.UI

--- One chart: its frames and the pools of lines and textures it draws with.
---@class GoldwrightChart
---@field key string "history", "hours" or "market"
---@field w number plot width
---@field h number plot height
---@field lines table[] pooled Line objects
---@field texs table[] pooled textures
---@field nLines number lines used in the current drawing
---@field nTexs number textures used in the current drawing
---@field plot table plot frame
---@field msg table message shown instead of the plot
---@field below table legend under the x labels
---@field ready boolean the last drawing had something to show
---@field useLines boolean the client can create Line objects
---@field extras table[] frames outside the plot shown and hidden with it
---@field days number|nil history: days shown (7 or 30)
---@field hi table|nil history: top price label
---@field lo table|nil history: bottom price label
---@field xFirst table|nil history: first day label
---@field xLast table|nil history: last day label
---@field houses table|nil history: the other houses' prices, right of the legend
---@field toggles table[]|nil history: the 7d / 30d buttons
---@field points { x: number, y: number?, day: number, price: number? }[]|nil history: drawn points
---@field units table|nil hours: "up to n listed" label
---@field price table|nil hours: price range label
---@field bars { x: number, w: number, hour: number, units: number, price: number? }[]|nil hours: drawn bars
---@field window GoldwrightPostWindow|nil hours: the window drawn last (for tests)
---@field marks table[]|nil the days or hours that can be inspected, left to right
---@field at number|nil index into marks of the one inspected now
---@field ref number|nil history: the dashed line's price
---@field refLabel string|nil history: its name in the tooltip
---@field hit table|nil the frame over the plot that takes the mouse
---@field cross table|nil the thin line on the inspected day or hour
---@field mark table|nil the dot on the inspected price
---@field lit table|nil the light column behind the inspected hour

--- The Sell tab chart (GW.SellCharts).
---@class GoldwrightSellCharts
---@field history GoldwrightChart|nil
---@field hours GoldwrightChart|nil
---@field view string "history" or "hours": the chart shown
---@field caption table|nil the caption naming the chart shown
---@field switch table[]|nil the History / Best time to post buttons
local Charts = { view = "history" }
GW.SellCharts = Charts
local hist, hrs -- the two chart objects
local current -- item id drawn last
local currentName -- its name, for your own sales (GW.LedgerSalesByDay)

--- A colour escape ("|cffrrggbb") for an {r, g, b} colour.
---@param c number[]
---@return string
local function hex(c)
  local function b(v) return math.floor(v * 255 + 0.5) end
  return string.format("|cff%02x%02x%02x", b(c[1]), b(c[2]), b(c[3]))
end

--- A colour escape for a word in a chart's key: the colour of what it names, lightened (toward
--- white by `k`, default 0.45) so dark bar and line colours stay readable as text.
---@param c number[]
---@param k number|nil
---@return string
local function keyHex(c, k)
  k = k or 0.45
  return hex({ c[1] + (1 - c[1]) * k, c[2] + (1 - c[2]) * k, c[3] + (1 - c[3]) * k })
end

--- A chart label font string, drawn above the plot textures (OVERLAY), in a quiet colour.
---@param parent table
---@param template string? font object (default "GameFontDisableSmall")
---@param justify string?
---@return table fontString
local function fs(parent, template, justify)
  local f = UI.FontString(parent, template or "GameFontDisableSmall", justify, "OVERLAY")
  UI.SetColor(f, UI.Tokens().faint)
  return f
end

--- The house being sold at: the open auction house (Blackwater in neutral towns).
local function side() return GW.AuctionSide and GW.AuctionSide() or GW.House().side end

--- "Nov 9" for a server time (UTC date).
---@param epoch number
---@return string
local function dayLabel(epoch)
  local t = date("!*t", epoch)
  return string.format(MONTH_DAY[t.month], t.day)
end

---------------------------------------------------------------------------
-- drawing primitives (pooled)
---------------------------------------------------------------------------

--- Creates a chart at the box's plot area: plot frame with background and base line, message and
--- legend.
---@param parent table the market card
---@param key string "history" or "hours"
---@param box { x: number, y: number, w: number, h: number } the plot area in `parent`
---@return GoldwrightChart
local function newChart(parent, key, box)
  local T = UI.Tokens()
  local c = { key = key, w = box.w, h = box.h, lines = {}, texs = {}, nLines = 0, nTexs = 0, extras = {} }
  c.plot = CreateFrame("Frame", nil, parent)
  c.plot:SetPoint("TOPLEFT", box.x, box.y)
  c.plot:SetSize(box.w, box.h)
  local bg = c.plot:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(T.chartBg[1], T.chartBg[2], T.chartBg[3], T.chartBg[4] or 1)
  local base = c.plot:CreateTexture(nil, "BORDER")
  base:SetPoint("BOTTOMLEFT")
  base:SetPoint("BOTTOMRIGHT")
  base:SetHeight(1)
  base:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
  c.msg = fs(parent, "GameFontDisableSmall", "LEFT")
  c.msg:SetPoint("TOPLEFT", box.x, box.y - 4)
  c.msg:SetWidth(box.w)
  c.below = fs(parent, "GameFontHighlightSmall", "LEFT") -- legend under the x labels
  c.below:SetPoint("TOPLEFT", box.x, box.y - box.h - 20)
  c.extras[1] = c.below
  -- Lines exist in this client if the plot can make one; otherwise bars and dots.
  local ok, probe = pcall(function() return c.plot:CreateLine(nil, "OVERLAY") end)
  c.useLines = ok and probe ~= nil
  if c.useLines then
    probe:Hide()
    c.lines[1] = probe
  end
  return c
end

--- Starts a drawing: every pooled object is free again.
---@param c GoldwrightChart
local function begin(c)
  c.nLines, c.nTexs = 0, 0
end

--- Ends a drawing: hides the pooled objects it didn't use.
---@param c GoldwrightChart
local function finish(c)
  for i = c.nLines + 1, #c.lines do
    c.lines[i]:Hide()
  end
  for i = c.nTexs + 1, #c.texs do
    c.texs[i]:Hide()
  end
end

--- Draws a filled rectangle from the texture pool (at least 1 x 1 pixel).
---@param c GoldwrightChart
---@param x number left, from the plot's bottom-left
---@param y number bottom, from the plot's bottom-left
---@param w number width
---@param h number height
---@param color number[] {r, g, b}
---@param alpha number? default 1
---@param layer string? draw layer (default "ARTWORK")
---@return table texture
local function rect(c, x, y, w, h, color, alpha, layer)
  c.nTexs = c.nTexs + 1
  local t = c.texs[c.nTexs]
  if not t then
    t = c.plot:CreateTexture(nil, "ARTWORK")
    c.texs[c.nTexs] = t
  end
  t:SetDrawLayer(layer or "ARTWORK")
  t:ClearAllPoints()
  t:SetPoint("BOTTOMLEFT", c.plot, "BOTTOMLEFT", x, y)
  t:SetSize(math.max(1, w), math.max(1, h))
  t:SetColorTexture(color[1], color[2], color[3], alpha or 1)
  t:Show()
  return t
end

--- Draws a dashed horizontal line across the plot at height y.
---@param c GoldwrightChart
---@param y number
---@param color number[]
local function dashed(c, y, color)
  local x = 0
  while x < c.w do
    rect(c, x, y - 0.5, math.min(DASH, c.w - x), 1, color, 1, "BORDER")
    x = x + DASH + DASH_GAP
  end
end

--- Draws a line segment from the line pool (only when the client has Line objects).
---@param c GoldwrightChart
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param color number[] {r, g, b}
---@param thickness number? default 2
---@return table line
local function segment(c, x1, y1, x2, y2, color, thickness)
  c.nLines = c.nLines + 1
  local l = c.lines[c.nLines]
  if not l then
    l = c.plot:CreateLine(nil, "OVERLAY")
    c.lines[c.nLines] = l
  end
  l:SetThickness(thickness or 2)
  l:SetColorTexture(color[1], color[2], color[3], 1)
  l:SetStartPoint("BOTTOMLEFT", c.plot, x1, y1)
  l:SetEndPoint("BOTTOMLEFT", c.plot, x2, y2)
  l:Show()
  return l
end

--- Draws a price line through points: lines where the client has them, dots otherwise; single
--- points between gaps get a dot either way.
---@param c GoldwrightChart
---@param pts { x: number, y: number? }[] points (nil y = gap)
---@param color number[] {r, g, b}
---@param dots boolean|nil also draw a dot on every point
---@param thickness number|nil line thickness (default 2)
local function polyline(c, pts, color, dots, thickness)
  for i = 1, #pts do -- every entry is a table, so # is safe here
    local p, prev, nxt = pts[i], pts[i - 1], pts[i + 1]
    if p.y then
      if c.useLines and nxt and nxt.y then segment(c, p.x, p.y, nxt.x, nxt.y, color, thickness or 2) end
      local alone = not (prev and prev.y) and not (nxt and nxt.y)
      if dots or alone or not c.useLines then rect(c, p.x - 1.5, p.y - 1.5, 3, 3, color, 1, "OVERLAY") end
    end
  end
end

--- Lowest and highest of values[1..n] (nil = gap) and `extra`. A flat range is widened a little
--- so it can be drawn.
---@param values table<number, number>
---@param n number entries to look at
---@param extra number|nil one more value to include
---@return number|nil lo nil when every value is missing
---@return number|nil hi
local function range(values, n, extra)
  local lo, hi
  for i = 1, n + 1 do
    local v = values[i]
    if i == n + 1 then v = extra end
    if v then
      if not lo or v < lo then lo = v end
      if not hi or v > hi then hi = v end
    end
  end
  if not lo then return nil end
  if hi == lo then
    lo, hi = math.max(0, lo * 0.95 - 1), hi * 1.05 + 1
  end
  return lo, hi
end

--- Shows the chosen chart: its plot and extras when it has something to show, else its message.
--- The other chart is hidden; the caption names the chart shown and its switch button is selected.
local function refresh()
  if not hist then return end
  for _, c in ipairs({ hist, hrs }) do
    local on = Charts.view == c.key
    c.plot:SetShown(on and c.ready)
    c.msg:SetShown(on and not c.ready)
    for _, f in ipairs(c.extras) do
      f:SetShown(on and c.ready)
    end
  end
  Charts.caption:SetText(Charts.view == "hours" and L["Best time to post"] or L["Price history"])
  for _, b in ipairs(Charts.switch) do
    UI.SetSelected(b, b.view == Charts.view)
  end
end

--- Records whether a chart has something to show (or the message instead) and refreshes.
---@param c GoldwrightChart
---@param ready boolean
---@param msg string|nil message when not ready
local function showChart(c, ready, msg)
  c.ready = ready and true or false
  c.msg:SetText(msg or "")
  refresh()
end

---------------------------------------------------------------------------
-- SELL-15: price history
---------------------------------------------------------------------------

--- The other houses' market prices for the legend: "Horde 3s 90c · Blackwater none listed".
---@param itemID number
---@return string
local function otherHouses(itemID)
  local d = GW.ItemData(itemID)
  if not d then return "" end
  local parts = {}
  for _, s in ipairs({ "A", "H", "N" }) do
    if s ~= side() then
      local there = d[s]
      parts[#parts + 1] = (there and there.mv) and string.format("%s %s", GW.HOUSE_NAMES[s], GW.Money(there.mv))
        or string.format(L["%s none listed"], GW.HOUSE_NAMES[s])
    end
  end
  return table.concat(parts, " · ")
end

--- Draws the price history chart for an item: daily prices over 7 or 30 days against the normal
--- price (the header's "Normal, last 7 days"), or a message while there is too little history.
---@param itemID number
local function drawHistory(itemID)
  local c = hist
  local T = UI.Tokens()
  begin(c)
  c.points, c.marks = nil, nil
  local values, from = GW.History(itemID, side())
  local pack = GW.Pack()
  local w = values and GW.HistoryWindow(values, from, pack and pack.snapshotAt, c.days)
  if not pack then
    showChart(c, false, L["Price history comes with the Goldwright Data pack."])
  elseif not w or w.total < GW.HISTORY_MIN_DAYS then
    local have = w and w.total or 0
    showChart(
      c,
      false,
      have > 0 and string.format(L["Insufficient history: %d of %d days."], have, GW.HISTORY_MIN_DAYS)
        or L["Insufficient history."]
    )
  else
    local d = GW.ItemData(itemID)
    local here = d and d[side()]
    local normal = here and here.avg7
    local ref = normal or (here and here.avg30) or w.avg
    local n = c.days
    local lo, hi = range(w.values, n, ref)
    local function y(v) return LABEL_PAD + (v - lo) / (hi - lo) * (c.h - 2 * LABEL_PAD) end
    dashed(c, y(ref), T.chartRef)
    local pts = {}
    for i = 1, n do
      local v = w.values[i]
      pts[i] = { x = 3 + (i - 1) / (n - 1) * (c.w - 6), y = v and y(v), day = w.firstDay + (i - 1) * 86400, price = v }
    end
    if c.useLines then
      polyline(c, pts, T.gold, n <= 7)
    else
      local bw = c.w / n
      for i = 1, n do
        local v = w.values[i]
        if v then rect(c, (i - 1) * bw + 0.5, 0, bw - 1, y(v), T.gold, 0.85) end
      end
    end
    c.points = pts
    -- your own sales that day: a gold square on the price line (the Market window's "you sold"
    -- marker), "you sold" in the key, and a line in the tooltip
    local sales = GW.LedgerSalesByDay and GW.LedgerSalesByDay(currentName, side()) or {}
    local marks, anySold = {}, false
    for _, p in ipairs(pts) do
      local sold = sales[p.day]
      if sold and sold.qty > 0 then
        p.sold, p.each, anySold = sold.qty, sold.money / sold.qty, true
        local sy = p.y or 4.5
        rect(c, p.x - 4.5, sy - 4.5, 9, 9, { 0, 0, 0 }, 1, "ARTWORK")
        rect(c, p.x - 3.5, sy - 3.5, 7, 7, T.gold, 1, "OVERLAY")
      end
      if p.price then marks[#marks + 1] = p end
    end
    c.marks = marks
    c.ref, c.refLabel = ref, normal and L["Normal, last 7 days"] or L["30-day average"]
    c.hi:SetText(GW.Money(hi))
    c.lo:SetText(GW.Money(lo))
    c.xFirst:SetText(dayLabel(w.firstDay))
    c.xLast:SetText(dayLabel(w.firstDay + (n - 1) * 86400))
    local key = normal and L["%s—|r daily price    %s- -|r normal %s"]
      or L["%s—|r daily price    %s- -|r 30-day average %s"]
    c.below:SetText(
      string.format(key, hex(T.gold), keyHex(T.chartRef), GW.Money(ref))
        .. (anySold and ("    " .. string.format(L["%syou sold|r"], hex(T.gold))) or "")
    )
    c.houses:SetText(otherHouses(itemID))
    showChart(c, true)
  end
  for _, b in ipairs(c.toggles) do
    UI.SetSelected(b, b.days == c.days)
  end
  finish(c)
end

---------------------------------------------------------------------------
-- SELL-16: hour of day (local time) + best time to post
---------------------------------------------------------------------------

--- Draws the hour-of-day chart for an item in local time: units listed per hour as bars (the best
--- posting window highlighted), the price as a line, and the best-time callout.
---@param itemID number
local function drawHours(itemID)
  local c = hrs
  local T = UI.Tokens()
  begin(c)
  c.bars, c.marks = nil, nil
  local profile = GW.Hours(itemID, side())
  local offset = math.floor(GW.UTCOffsetHours() + 0.5)
  local units, prices
  if profile then
    units, prices = GW.LocalHours(profile, offset)
  end
  local maxU = 0
  for h = 1, 24 do
    if units and units[h] and units[h] > maxU then maxU = units[h] end
  end
  if not GW.Pack() then
    showChart(c, false, L["The hourly pattern comes with the Goldwright Data pack."])
  elseif not profile or maxU == 0 then
    showChart(c, false, L["Appears once there are enough hourly snapshots of this item (about two weeks)."])
  else
    local win = GW.BestPostWindow(profile, offset)
    local bw = c.w / 24
    local top = c.h - LABEL_PAD - 1
    local bars = {}
    for h = 1, 24 do
      local u = units[h]
      if u and u > 0 then
        local inWin = win and not win.flat and (h - 1 - win.start) % 24 < GW.POST_WINDOW
        rect(c, (h - 1) * bw + 0.5, 0, bw - 1.5, math.max(1, u / maxU * top), GW.SIGNAL_BLUE, inWin and 0.9 or 0.3)
        bars[#bars + 1] = { x = (h - 1) * bw, w = bw, hour = h - 1, units = u, price = prices[h] }
      end
    end
    c.bars = bars
    -- a faint line at the current hour
    local now = (date("*t") or {}).hour or 0
    rect(c, (now + 0.5) * bw, 0, 1, c.h, T.faint, 0.8, "BORDER")
    local lo, hi = range(prices, 24)
    local marks = {}
    for h = 1, 24 do
      if (units[h] or 0) > 0 or prices[h] then
        marks[#marks + 1] = {
          x = (h - 0.5) * bw,
          y = lo and prices[h] and (6 + (prices[h] - lo) / (hi - lo) * (top - 10)) or nil,
          hour = h - 1,
          units = units[h],
          price = prices[h],
          inWin = win and not win.flat and (h - 1 - win.start) % 24 < GW.POST_WINDOW or false,
          now = h - 1 == now,
        }
      end
    end
    c.marks = marks
    if lo then
      local pts = {}
      for h = 1, 24 do
        local p = prices[h]
        pts[h] = { x = (h - 0.5) * bw, y = p and (6 + (p - lo) / (hi - lo) * (top - 10)) }
      end
      polyline(c, pts, T.gold, false)
      -- the real price range (range() widens a flat one so it can be drawn): one price if flat
      local pmin, pmax
      for h = 1, 24 do
        local p = prices[h]
        if p then
          pmin, pmax = math.min(pmin or p, p), math.max(pmax or p, p)
        end
      end
      c.price:SetText(pmin == pmax and GW.Money(pmin) or (GW.Money(pmin) .. "–" .. GW.Money(pmax)))
    else
      c.price:SetText("")
    end
    c.units:SetText(string.format(L["up to %s listed"], GW.Number(math.floor(maxU + 0.5))))
    c.below:SetText(GW.BestPostText(win) or "")
    UI.SetColor(c.below, (win and not win.flat) and GW.SIGNAL_BLUE or T.muted)
    c.window = win
    showChart(c, true)
  end
  finish(c)
end

---------------------------------------------------------------------------
-- hover (#13): exact values for the day or hour under the mouse (or the controller)
---------------------------------------------------------------------------
local HOVER_EVERY = 0.05 -- seconds between looks at the mouse while it is over a chart

--- The mark nearest to x (plot coordinates).
---@param c GoldwrightChart
---@param x number
---@return number|nil index into c.marks
local function nearest(c, x)
  local best, at
  for i, p in ipairs(c.marks or {}) do
    if not best or math.abs(p.x - x) < math.abs(best.x - x) then
      best, at = p, i
    end
  end
  return at
end

--- One tooltip row: a label on the left, the value on the right (money in one column).
---@param label string
---@param value string
local function row(label, value)
  local T = UI.Tokens()
  GameTooltip:AddDoubleLine(label, value, T.label[1], T.label[2], T.label[3], 1, 1, 1)
end

--- Fills the game tooltip for one mark. The rows are always the same, in the same order; your
--- sales and the notes under the hour only appear when they apply.
---@param c GoldwrightChart
---@param p table the mark
local function fillTooltip(c, p)
  if p.rows then -- the Market window: a title and its rows (a row without a value is a line)
    GameTooltip:SetText(p.title, 1, 1, 1)
    for _, r in ipairs(p.rows) do
      if r[2] then
        row(r[1], r[2])
      else
        GameTooltip:AddLine(r[1], 1, 1, 1)
      end
    end
  elseif c.key == "history" then
    GameTooltip:SetText(dayLabel(p.day), 1, 1, 1)
    row(L["Market price"], GW.Money(p.price, true))
    row(c.refLabel, GW.Money(c.ref, true))
    if p.sold then row(string.format(L["You sold %d, each"], p.sold), GW.Money(p.each, true)) end
    GameTooltip:AddLine(L["Click to open Market"], 0.6, 0.6, 0.65)
  else
    local title = string.format(L["%s–%s your time"], GW.HourLabel(p.hour), GW.HourLabel((p.hour + 1) % 24))
    GameTooltip:SetText(title, 1, 1, 1)
    row(L["Listed (14-day average)"], p.units and GW.Number(math.floor(p.units + 0.5)) or "–")
    row(L["Market price"], p.price and GW.Money(p.price, true) or "–")
    if p.inWin then
      local b = GW.SIGNAL_BLUE
      GameTooltip:AddLine(L["In the best time to post"], b[1], b[2], b[3])
    end
    if p.now then GameTooltip:AddLine(L["Now"], 0.7, 0.7, 0.72) end
  end
end

--- Stops inspecting a chart: the line, dot, column and tooltip go.
---@param c GoldwrightChart
local function clearHover(c)
  c.at = nil
  if not c.cross then return end
  c.cross:Hide()
  c.mark:Hide()
  c.lit:Hide()
  if GameTooltip:GetOwner() == c.hit then GameTooltip:Hide() end
end

--- Inspects one mark: the line and dot on it (on the hour chart a light column) and its tooltip
--- beside it, on the side with more room.
---@param c GoldwrightChart
---@param i number|nil index into c.marks
local function inspect(c, i)
  local p = i and c.marks and c.marks[i]
  if not p then return clearHover(c) end
  c.at = i
  c.cross:ClearAllPoints()
  c.cross:SetPoint("BOTTOMLEFT", c.plot, "BOTTOMLEFT", p.x - 0.5, 0)
  c.cross:Show()
  if p.y then
    c.mark:ClearAllPoints()
    c.mark:SetPoint("CENTER", c.plot, "BOTTOMLEFT", p.x, p.y)
    c.mark:Show()
  else
    c.mark:Hide()
  end
  -- a light column behind the hour (or any mark with bx / bw)
  local bx, bw = p.bx, p.bw
  if not bx and c.key == "hours" then
    bw = c.w / 24
    bx = p.hour * bw
  end
  if bx then
    c.lit:ClearAllPoints()
    c.lit:SetPoint("BOTTOMLEFT", c.plot, "BOTTOMLEFT", bx, 0)
    c.lit:SetSize(bw, c.h)
    c.lit:Show()
  else
    c.lit:Hide()
  end
  local right = p.x > c.w / 2
  GameTooltip:SetOwner(c.hit, "ANCHOR_NONE")
  GameTooltip:ClearAllPoints()
  GameTooltip:SetPoint(
    right and "BOTTOMRIGHT" or "BOTTOMLEFT",
    c.plot,
    "BOTTOMLEFT",
    p.x + (right and -12 or 12),
    math.min((p.y or c.h / 2) + 12, c.h)
  )
  fillTooltip(c, p)
  GameTooltip:Show()
end

--- While the mouse is over a chart: every HOVER_EVERY seconds, the mark nearest the mouse.
---@param self table the chart's hit frame
---@param elapsed number
local function track(self, elapsed)
  local c = self.chart
  c.wait = (c.wait or 0) - elapsed
  if c.wait > 0 then return end
  c.wait = HOVER_EVERY
  local left = c.plot:GetLeft()
  if not left then return end
  local x = GetCursorPosition() / self:GetEffectiveScale() - left
  local i = nearest(c, x)
  if i ~= c.at then inspect(c, i) end
end

--- Gives a chart its hover: a frame over the plot that takes the mouse (no work until the mouse
--- is over it), the line, dot and column it draws, and the controller's inspect (A, then left /
--- right through the marks, A or B to stop; Gamepad.Adjustable).
---@param c GoldwrightChart
local function addHover(c)
  local T = UI.Tokens()
  c.cross = c.plot:CreateTexture(nil, "OVERLAY")
  c.cross:SetSize(1, c.h)
  c.cross:SetColorTexture(T.text[1], T.text[2], T.text[3], 0.45)
  c.cross:Hide()
  c.mark = c.plot:CreateTexture(nil, "OVERLAY", nil, 7)
  c.mark:SetSize(7, 7)
  c.mark:SetColorTexture(T.gold[1], T.gold[2], T.gold[3], 1)
  c.mark:Hide()
  c.lit = c.plot:CreateTexture(nil, "BORDER")
  c.lit:SetColorTexture(1, 1, 1, 0.07)
  c.lit:Hide()
  local hit = CreateFrame("Button", nil, c.plot)
  hit:SetAllPoints()
  hit.chart = c
  hit:SetScript("OnEnter", function(self)
    c.wait = 0
    self:SetScript("OnUpdate", track)
    track(self, 0)
  end)
  local function stop(self)
    self:SetScript("OnUpdate", nil)
    clearHover(c)
  end
  hit:SetScript("OnLeave", stop)
  hit:SetScript("OnHide", stop)
  -- a click on a day: the Sell tab's price history opens the Market window (c.onClick)
  hit:SetScript("OnClick", function()
    if c.at and c.onClick then c.onClick(c.at) end
  end)
  c.hit = hit
  if GW.Gamepad and GW.Gamepad.Adjustable then
    local function count() return c.marks and #c.marks or 0 end
    local function editing() return GW.Gamepad.editing and GW.Gamepad.editing.box == hit end
    GW.Gamepad.Adjustable(hit, {
      get = function() return c.at or count() end,
      set = function(n)
        if not editing() then return end
        inspect(c, n)
      end,
      step = 1,
      min = function() return 1 end,
      max = count,
      enabled = function() return c.ready and count() > 0 end,
      show = function(on)
        if on then
          inspect(c, c.at or count())
        else
          clearHover(c)
        end
      end,
    })
    -- A again (done) on a day of the Sell tab's price history opens it, like a click.
    local adjust = hit.OnSmartNavClick
    hit.OnSmartNavClick = function(self)
      local day = editing() and c.at
      adjust(self)
      if day and c.onClick then c.onClick(day) end
    end
  end
end

--- Inspects mark i of a chart as the mouse or the controller would (tests use it too).
---@param key string "history", "hours" or "market" (the Market window's chart)
---@param i number|nil index into that chart's marks; nil stops
function Charts.Inspect(key, i)
  local c = key == "hours" and hrs or key == "market" and Charts.MarketChart() or hist
  if c then inspect(c, i) end
end

---------------------------------------------------------------------------
-- construction and API
---------------------------------------------------------------------------

--- Builds the chart in the market card: the caption, the History / Best time to post switch, and
--- both charts in the same plot area (price history with 7d / 30d toggles; best time to post with
--- hour labels in the player's time).
---@param parent table the market card
---@param box { x: number, y: number, w: number, h: number } the chart's area in `parent`: caption
---  row at the top, then the plot, x labels and legend
function Charts.Create(parent, box)
  local T = UI.Tokens()
  Charts.caption = UI.Caption(parent, L["Price history"], box.x, box.y - 3)
  Charts.switch = {}
  local right = box.x + box.w
  for i, s in ipairs({ { "hours", L["Best time to post"] }, { "history", L["History"] } }) do
    local b = UI.ToggleButton(parent, s[2], 80, 20)
    local text = b:GetFontString()
    b:SetWidth(math.floor((text and text:GetStringWidth() or 60) + 22))
    b:SetPoint("TOPRIGHT", parent, "TOPLEFT", right, box.y + 1)
    right = right - b:GetWidth() - 4
    b.view = s[1]
    b:SetScript("OnClick", function()
      Charts.view = s[1]
      refresh()
    end)
    Charts.switch[i] = b
  end

  local plot = { x = box.x, y = box.y - 30, w = box.w, h = box.h - 30 - 36 }
  hist = newChart(parent, "history", plot)
  hist.days = 7
  hist.hi = fs(hist.plot, "GameFontDisableSmall", "LEFT")
  hist.hi:SetPoint("TOPLEFT", 3, -2)
  hist.lo = fs(hist.plot, "GameFontDisableSmall", "LEFT")
  hist.lo:SetPoint("BOTTOMLEFT", 3, 3)
  hist.xFirst = fs(parent, "GameFontDisableSmall", "LEFT")
  hist.xFirst:SetPoint("TOPLEFT", plot.x, plot.y - plot.h - 4)
  hist.xLast = fs(parent, "GameFontDisableSmall", "RIGHT")
  hist.xLast:SetPoint("TOPRIGHT", parent, "TOPLEFT", plot.x + plot.w, plot.y - plot.h - 4)
  hist.houses = fs(parent, "GameFontDisableSmall", "RIGHT")
  hist.houses:SetPoint("TOPRIGHT", parent, "TOPLEFT", plot.x + plot.w, plot.y - plot.h - 20)
  UI.SetColor(hist.below, T.faint)
  for _, f in ipairs({ hist.xFirst, hist.xLast, hist.houses }) do
    hist.extras[#hist.extras + 1] = f
  end
  hist.toggles = {}
  for i, days in ipairs({ 7, 30 }) do
    local b = UI.NewToggleButton(parent)
    b:SetSize(34, 18)
    b:SetPoint("LEFT", Charts.caption, "RIGHT", 10 + (i - 1) * 36, 0)
    b:SetNormalFontObject("GameFontHighlightSmall")
    b:SetText(string.format(L["%dd"], days))
    b.days = days
    b:SetScript("OnClick", function()
      hist.days = days
      if current then drawHistory(current) end
      Charts.MarketDays(current, days)
    end)
    hist.toggles[i] = b
    hist.extras[#hist.extras + 1] = b
  end

  hrs = newChart(parent, "hours", plot)
  local tz = fs(parent, "GameFontDisableSmall", "RIGHT")
  tz:SetPoint("TOPRIGHT", parent, "TOPLEFT", plot.x + plot.w, plot.y - plot.h - 4)
  tz:SetText(L["your time"])
  hrs.extras[#hrs.extras + 1] = tz
  hrs.units = fs(hrs.plot, "GameFontDisableSmall", "LEFT")
  hrs.units:SetPoint("TOPLEFT", 3, -2)
  hrs.price = fs(hrs.plot, "GameFontDisableSmall", "RIGHT")
  hrs.price:SetPoint("TOPRIGHT", -3, -2)
  for _, h in ipairs({ 0, 6, 12, 18 }) do
    local l = fs(parent, "GameFontDisableSmall", "LEFT")
    l:SetPoint("TOPLEFT", plot.x + h * plot.w / 24, plot.y - plot.h - 4)
    l:SetText(GW.HourLabel(h))
    hrs.extras[#hrs.extras + 1] = l
  end
  hrs.below:SetWidth(plot.w)
  addHover(hist)
  addHover(hrs)
  -- a click on a day of the price history opens the Market window (#16)
  hist.onClick = function() Charts.OpenMarket(current, currentName, hist.days) end
  Charts.history, Charts.hours = hist, hrs
  refresh()
end

---------------------------------------------------------------------------
-- Market (#16): one window, five tabs (Price, Demand, Supply, Resell, Your trades). Each tab is one big
-- answer and a few words over one chart and a one-line key, for the house you sell at over the
-- last 7 or 30 days (whichever the Sell tab's price history shows). Hovering the chart (or the controller's A) shows exact numbers.
---------------------------------------------------------------------------
local MW, MH = 600, 420
local GREEN = { 0.31, 0.77, 0.42 } -- Resell's profit zone
local BOUGHT = { 0.44, 0.59, 1 } -- Your trades: what you bought
local MARKET_TABS = {
  { key = "price", label = L["Price"] },
  { key = "demand", label = L["Demand"] },
  { key = "supply", label = L["Supply"] },
  { key = "resell", label = L["Resell"] },
  { key = "trades", label = L["Your trades"] },
}

--- The Market window and what it shows.
---@class GoldwrightMarketWindow
---@field frame table the window
---@field chart GoldwrightChart the chart ("market"), drawn by the open tab
---@field tab string "price", "demand", "supply", "resell" or "trades"
---@field tabs table[] the tab buttons
---@field big table the big value
---@field words table the few words after it
---@field chip table Resell's verdict, in place of the words
---@field itemID number|nil
---@field name string|nil
---@field days number 7 or 30: the days shown, as on the Sell tab's price history
local mw
local live = {} -- the Sell tab's live listings: { itemID, stats } (Charts.Listings)

--- The selling house's data pack entry for the open item, and its normal price (the 7-day
--- average, else the 30-day one).
---@return table|nil here
---@return number|nil normal
local function houseData()
  local d = GW.ItemData(mw.itemID)
  local here = d and d[side()]
  return here, here and (here.avg7 or here.avg30)
end

--- The open item's last 30 daily prices at the house you sell at; nil without any.
---@return GoldwrightHistoryWindow|nil
local function window30()
  local pack = GW.Pack()
  local values, from = GW.History(mw.itemID, side())
  local w = pack and values and GW.HistoryWindow(values, from, pack.snapshotAt, mw.days)
  return w and w.known > 0 and w or nil
end

--- The message for a tab that needs price history it doesn't have.
---@return string
local function noHistory()
  return GW.Pack() and L["No price history for this item yet."]
    or L["Price history comes with the Goldwright Data pack."]
end

--- The live listings the Sell tab found for the open item, or nil.
---@return GoldwrightMarketStats|nil
local function liveStats() return live.itemID == mw.itemID and live.stats or nil end

--- Today's price: the cheapest real listing now (live, else the data pack's), else the last day's.
---@param w GoldwrightHistoryWindow|nil
---@return number|nil copper
local function nowPrice(w)
  local s = liveStats()
  local first = s and s.sorted[s.firstRealIndex]
  if first then return first.price end
  local here = houseData()
  if here and here.min then return here.min end
  for i = mw.days, 1, -1 do
    if w and w.values[i] then return w.values[i] end
  end
end

--- Says in one line why a tab has nothing to draw, in place of its chart.
---@param msg string
local function blank(msg)
  local c = mw.chart
  c.ready = false
  c.plot:Hide()
  for _, f in ipairs(c.extras) do
    f:Hide()
  end
  c.msg:SetText(msg)
  c.msg:Show()
end

--- Shows the chart a tab drew, with its labels.
local function ready()
  local c = mw.chart
  c.ready = true
  c.plot:Show()
  for _, f in ipairs(c.extras) do
    f:Show()
  end
  c.msg:Hide()
end

--- The scales of a 30-day price chart from lo to hi, with its axis labels.
---@param w GoldwrightHistoryWindow
---@param lo number
---@param hi number
---@return fun(i: number): number x day index to plot x
---@return fun(v: number): number y price to plot y
local function dayScale(w, lo, hi)
  local c = mw.chart
  c.hi:SetText(GW.Money(hi))
  c.lo:SetText(GW.Money(lo))
  c.xFirst:SetText(dayLabel(w.firstDay))
  c.xLast:SetText(dayLabel(w.firstDay + (mw.days - 1) * 86400))
  local function x(i) return 3 + (i - 1) / (mw.days - 1) * (c.w - 6) end
  local function y(v) return LABEL_PAD + (v - lo) / (hi - lo) * (c.h - 2 * LABEL_PAD) end
  return x, y
end

--- The daily price line's points (no y on days without a price).
---@param w GoldwrightHistoryWindow
---@param x fun(i: number): number
---@param y fun(v: number): number
---@return table[] points
local function dayPoints(w, x, y)
  local pts = {}
  for i = 1, mw.days do
    local v = w.values[i]
    pts[i] = { x = x(i), y = v and y(v), day = w.firstDay + (i - 1) * 86400, price = v }
  end
  return pts
end

--- The hover marks of a price line: the days with a price, each with its date and rows(p).
---@param pts table[]
---@param rows fun(p: table): table[]
---@return table[] marks
local function dayMarks(pts, rows)
  local marks = {}
  for _, p in ipairs(pts) do
    if p.price then
      p.title, p.rows = dayLabel(p.day), rows(p)
      marks[#marks + 1] = p
    end
  end
  return marks
end

--- The normal range of the shown days: the 25th to the 75th percentile of their daily prices, and
--- an axis top one spike can't stretch (1.1 x the 95th percentile, as Undermine Exchange does).
---@param w GoldwrightHistoryWindow
---@return number low
---@return number high
---@return number top
---@return number lowest
local function normalRange(w)
  local v = {}
  for i = 1, mw.days do
    if w.values[i] then v[#v + 1] = w.values[i] end
  end
  table.sort(v)
  local function pct(p) return v[math.max(1, math.min(#v, math.floor(p * (#v - 1) + 1.5)))] end
  return pct(0.25), pct(0.75), math.min(v[#v], math.floor(pct(0.95) * 1.1 + 0.5)), v[1]
end

--- Shades the normal range across the plot.
---@param c GoldwrightChart
---@param y fun(v: number): number
---@param low number
---@param high number
---@param alpha number
local function shadeRange(c, y, low, high, alpha)
  local T = UI.Tokens()
  rect(c, 0, y(low), c.w, math.max(1, y(high) - y(low)), T.chartRef, alpha, "BORDER")
end

--- A day chart's scales from lo to hi, clipping anything above hi to the top.
---@param w GoldwrightHistoryWindow
---@param lo number
---@param hi number
---@return fun(i: number): number x
---@return fun(v: number): number y
local function clippedScale(w, lo, hi)
  if hi <= lo then
    lo, hi = math.max(0, lo * 0.95 - 1), hi * 1.05 + 1
  end
  local x, y = dayScale(w, lo, hi)
  return x, function(v) return y(math.min(v, hi)) end
end

--- Price: today's price against the normal range of the shown days (cheap, normal or dear), over the
--- daily price line, the shaded range and a dot for now.
local function drawPrice()
  local c, T = mw.chart, UI.Tokens()
  local w = window30()
  if not w then return blank(noHistory()) end
  local low, high, top, lowest = normalRange(w)
  local now = nowPrice(w)
  mw.big:SetText(now and GW.Money(now) or "–")
  if now then
    local dearer, cheaper = 0, 0
    for i = 1, mw.days do
      local v = w.values[i]
      if v and v > now then dearer = dearer + 1 end
      if v and v < now then cheaper = cheaper + 1 end
    end
    if now < low then
      mw.words:SetText(string.format(L["cheaper than %d of the last %d days"], dearer, w.known))
    elseif now > high then
      mw.words:SetText(string.format(L["higher than %d of the last %d days"], cheaper, w.known))
    else
      mw.words:SetText(L["in the normal range"])
    end
  end
  local x, y = clippedScale(w, math.min(lowest, now or lowest), math.max(top, high, math.min(now or 0, top)))
  shadeRange(c, y, low, high, 0.35)
  local pts = dayPoints(w, x, y)
  polyline(c, pts, T.gold)
  if now then rect(c, x(mw.days) - 3.5, y(now) - 3.5, 7, 7, T.text, 1, "OVERLAY") end
  local range = GW.Money(low) .. " – " .. GW.Money(high)
  c.marks = dayMarks(
    pts,
    function(p) return { { L["Market price"], GW.Money(p.price, true) }, { L["Normal range"], range } } end
  )
  c.below:SetText(
    string.format(L["%s—|r daily price    %snormal range|r    %snow|r"], hex(T.gold), keyHex(T.chartRef), hex(T.text))
  )
  c.note:SetText(L["Normal range: the middle half of the days shown."])
  ready()
end

--- Demand: how much sells a day, as bars under the price line (the volume chart every market tool
--- shows). Proven sales (partial buys and swept stacks) are solid; the estimated rest (listings that
--- vanished early, which may include cancels) is lighter on top. The big answer compares the last 3
--- days with the days shown: busier, quieter or as usual.
local function drawDemand()
  local c, T = mw.chart, UI.Tokens()
  local w = window30()
  if not w then return blank(noHistory()) end
  local daily, from = GW.Daily(mw.itemID, side())
  if not daily then
    return blank(
      GW.pack and GW.pack.daily and L["No daily sales for this item yet."]
        or L["Daily sales come with a newer Goldwright Data pack."]
    )
  end
  local pack = GW.Pack()
  local proven = GW.HistoryWindow(daily.proven, from, pack and pack.snapshotAt, mw.days)
  local est = GW.HistoryWindow(daily.est, from, pack and pack.snapshotAt, mw.days)
  if not (est and est.known > 0) then return blank(L["No daily sales for this item yet."]) end
  -- proven counts when the item has any; else the estimate, said as such
  local useProven = proven
    and proven.known > 0
    and (function()
      for i = 1, mw.days do
        if (proven.values[i] or 0) > 0 then return true end
      end
    end)()
  local series = useProven and proven or est
  local sum, n, recent, rn = 0, 0, 0, 0
  for i = 1, mw.days do
    local v = series.values[i]
    if v then
      sum, n = sum + v, n + 1
      if i > mw.days - 3 then
        recent, rn = recent + v, rn + 1
      end
    end
  end
  local avg = n > 0 and sum / n or 0
  local now = rn > 0 and recent / rn or nil
  if now then
    local text = GW.Number(math.floor(now + 0.5))
    mw.big:SetText(string.format(useProven and L["~%s sold a day"] or L["~%s sold a day (est.)"], text))
    local r = avg > 0 and now / avg or 1
    mw.words:SetText(r > 1.25 and L["busier than usual"] or r < 0.8 and L["quieter than usual"] or L["about as usual"])
  end
  -- bars: one per day, proven solid with the estimated rest lighter on top
  local top = 1
  for i = 1, mw.days do
    top = math.max(top, est.values[i] or 0, proven and proven.values[i] or 0)
  end
  top = top * 1.1
  local bw = c.w / mw.days
  local function bh(v) return math.max(1, v / top * (c.h - LABEL_PAD - 2)) end
  local marks = {}
  for i = 1, mw.days do
    local e, p = est.values[i], proven and proven.values[i]
    if e or p then
      local x = (i - 1) * bw + 1
      local pv = math.min(p or 0, e or p or 0)
      if pv > 0 then rect(c, x, 0, bw - 2, bh(pv), T.barFill, 1) end
      if e and e > pv then
        rect(c, x, pv > 0 and bh(pv) or 0, bw - 2, bh(e) - (pv > 0 and bh(pv) or 0), T.barFill, 0.35)
      end
      local rows = {}
      if p then rows[#rows + 1] = { L["Proven sales"], GW.Number(math.floor(p + 0.5)) } end
      if e then rows[#rows + 1] = { L["Est. sales"], GW.Number(math.floor(e + 0.5)) } end
      if w.values[i] then rows[#rows + 1] = { L["Market price"], GW.Money(w.values[i], true) } end
      marks[#marks + 1] = {
        x = (i - 0.5) * bw,
        y = bh(math.max(e or 0, p or 0)),
        bx = (i - 1) * bw,
        bw = bw,
        title = dayLabel(est.firstDay + (i - 1) * 86400),
        rows = rows,
      }
    end
  end
  c.marks = marks
  -- the price line on its own scale, over the bars
  local plo, phi = range(w.values, mw.days)
  if plo then
    local pts = {}
    for i = 1, mw.days do
      local v = w.values[i]
      pts[i] = { x = (i - 0.5) * bw, y = v and (LABEL_PAD + (v - plo) / (phi - plo) * (c.h - 2 * LABEL_PAD)) }
    end
    polyline(c, pts, T.gold)
  end
  c.hi:SetText(string.format(L["%s a day"], GW.Number(math.floor(top + 0.5))))
  c.xFirst:SetText(dayLabel(est.firstDay))
  c.xLast:SetText(dayLabel(est.firstDay + (mw.days - 1) * 86400))
  c.below:SetText(
    string.format(
      L["%sproven sales|r    %sest. sales|r    %s—|r price"],
      keyHex(T.barFill, 0.6),
      keyHex(T.barFill, 0.35),
      hex(T.gold)
    )
  )
  c.note:SetText(L["Est. sales add listings that vanished early, which may include cancels."])
  ready()
end

--- Supply: how much is listed now against how much is usually listed at this hour of the day (the
--- 14-day average). A fact about today compared with its own usual, never a forecast.
local function drawSupply()
  local c, T = mw.chart, UI.Tokens()
  local s = liveStats()
  if not s then return blank(L["No live listings for this item right now."]) end
  mw.big:SetText(string.format(L["%s listed"], GW.Number(s.units)))
  local profile = GW.Hours(mw.itemID, side())
  local units = profile and GW.LocalHours(profile, math.floor(GW.UTCOffsetHours() + 0.5))
  local nowH = (date("*t") or {}).hour or 0
  local usual = units and units[nowH + 1]
  if not (usual and usual > 0) then
    return blank(L["Appears once there are enough hourly snapshots of this item (about two weeks)."])
  end
  local r = s.units / usual
  if r >= 2 then
    mw.words:SetText(string.format(L["%s× usual for this hour"], GW.Decimal(math.floor(r * 10 + 0.5) / 10)))
  elseif r > 1.25 then
    mw.words:SetText(string.format(L["%d%% more than usual at this hour"], math.floor((r - 1) * 100 + 0.5)))
  elseif r < 0.8 then
    mw.words:SetText(string.format(L["%d%% less than usual at this hour"], math.floor((1 - r) * 100 + 0.5)))
  else
    mw.words:SetText(L["about as usual for this hour"])
  end
  local top = s.units
  for h = 1, 24 do
    top = math.max(top, units[h] or 0)
  end
  top = top * 1.05
  local bw = c.w / 24
  local function y(v) return 2 + v / top * (c.h - LABEL_PAD - 4) end
  local pts, marks = {}, {}
  for h = 1, 24 do
    local u = units[h]
    pts[h] = { x = (h - 0.5) * bw, y = u and u > 0 and y(u) or nil }
    if u and u > 0 then
      local rows = { { L["Usually listed"], GW.Number(math.floor(u + 0.5)) } }
      if h - 1 == nowH then rows[2] = { L["Listed now"], GW.Number(s.units) } end
      marks[#marks + 1] = {
        x = pts[h].x,
        y = h - 1 == nowH and y(s.units) or pts[h].y,
        title = string.format(L["%s–%s your time"], GW.HourLabel(h - 1), GW.HourLabel(h % 24)),
        rows = rows,
      }
    end
  end
  rect(c, (nowH + 0.5) * bw, 0, 1, c.h, T.faint, 0.8, "BORDER")
  polyline(c, pts, GW.SIGNAL_BLUE)
  rect(c, (nowH + 0.5) * bw - 3.5, y(s.units) - 3.5, 7, 7, T.text, 1, "OVERLAY")
  c.marks = marks
  c.hi:SetText(GW.Number(math.floor(top + 0.5)))
  c.xFirst:SetText(GW.HourLabel(0))
  c.xMid:SetText(GW.HourLabel(12))
  c.xLast:SetText(L["your time"])
  c.below:SetText(string.format(L["%s—|r usually listed at each hour    %snow|r"], hex(GW.SIGNAL_BLUE), hex(T.text)))
  c.note:SetText(L["Usually: the 14-day average at that hour of the day."])
  ready()
end

--- Resell: buy under the low end of the normal range less the house's cut, and you profit even
--- reselling at the low end of normal. Today's verdict, and the daily price line over the profit zone.
local function drawResell()
  local c, T = mw.chart, UI.Tokens()
  local w = window30()
  if not w then return blank(noHistory()) end
  local low, high, top, lowest = normalRange(w)
  local keep = 1 - (GW.CUT[side()] or 0.05)
  local under = math.floor(low * keep)
  local now = nowPrice(w)
  mw.big:SetText(string.format(L["Buy under %s"], GW.Money(under)))
  if now and now < under then
    UI.SetChip(mw.chip, L["Buy now"], "blue")
  elseif now then
    UI.SetChip(mw.chip, string.format(L["Now %s: wait"], GW.Money(now)), "grey")
  end
  local x, y = clippedScale(w, math.min(lowest, under), math.max(top, high))
  shadeRange(c, y, low, high, 0.2)
  rect(c, 0, 0, c.w, y(under), GREEN, 0.12, "BORDER")
  dashed(c, y(under), GREEN)
  local pts = dayPoints(w, x, y)
  polyline(c, pts, T.gold)
  for _, p in ipairs(pts) do
    if p.price and p.price < under then rect(c, p.x - 2.5, p.y - 2.5, 5, 5, GREEN, 1, "OVERLAY") end
  end
  local profitLabel = string.format(L["Profit each, resold at %s"], GW.Money(low))
  c.marks = dayMarks(
    pts,
    function(p)
      return {
        { L["Market price"], GW.Money(p.price, true) },
        { profitLabel, p.price < under and GW.Money(low * keep - p.price, true) or "–" },
      }
    end
  )
  c.below:SetText(string.format(L["%s—|r profit zone: buy here, resell at the low end of normal"], hex(GREEN)))
  c.note:SetText(L["After the house's cut. Normal range: the middle half of the days shown."])
  ready()
end

--- Your trades: your profit on the item over the shown days (what your sales netted after the cut,
--- less what those units cost at your average buying price), with your buys and sales on the price
--- line over the normal range.
local function drawTrades()
  local c, T = mw.chart, UI.Tokens()
  local w = window30()
  if not w then return blank(noHistory()) end
  local at = side()
  local days, boughtQty, boughtMoney, soldQty, soldNet = {}, 0, 0, 0, 0
  for _, e in ipairs(GW.LedgerEvents and GW.LedgerEvents(nil) or {}) do
    local i = math.floor((e.t - w.firstDay) / 86400) + 1
    local trade = e.kind == "sold" or e.kind == "bought"
    -- a trade with an unknown house counts for every house (as on the Sell tab's chart)
    if trade and e.item == mw.name and (not e.house or e.house == at) and i >= 1 and i <= mw.days then
      local d = days[i] or {}
      days[i] = d
      local k = d[e.kind] or { qty = 0, money = 0 }
      d[e.kind] = k
      k.qty, k.money = k.qty + e.qty, k.money + (e.money or 0)
      if e.kind == "bought" then
        boughtQty, boughtMoney = boughtQty + e.qty, boughtMoney + (e.money or 0)
      else
        soldQty, soldNet = soldQty + e.qty, soldNet + (e.money or 0) - (e.cut or 0)
      end
    end
  end
  local profit = boughtQty > 0 and soldQty > 0 and soldNet - soldQty * boughtMoney / boughtQty or nil
  mw.big:SetText(profit and ((profit >= 0 and "+" or "−") .. GW.Money(math.abs(profit))) or "–")
  mw.words:SetText(
    (boughtQty + soldQty == 0) and string.format(L["No trades in the last %d days."], mw.days)
      or string.format(L["profit after the cut · bought %d · sold %d"], boughtQty, soldQty)
  )
  -- the scale takes your own prices too
  local low, high, top, lowest = normalRange(w)
  local lo, hi = lowest, math.max(top, high)
  for i = 1, mw.days do
    for _, k in pairs(days[i] or {}) do
      local each = k.money / math.max(1, k.qty)
      lo, hi = math.min(lo, each), math.max(hi, each)
    end
  end
  local x, y = clippedScale(w, lo, hi)
  shadeRange(c, y, low, high, 0.2)
  local pts = dayPoints(w, x, y)
  polyline(c, pts, T.faint, false, 1.5)
  local marks = {}
  for i, p in ipairs(pts) do
    local d = days[i]
    if p.price or d then
      local rows = {}
      if p.price then rows[#rows + 1] = { L["Market price"], GW.Money(p.price, true) } end
      local dotY
      for _, kind in ipairs({ "bought", "sold" }) do
        local k = d and d[kind]
        if k then
          local each = k.money / math.max(1, k.qty)
          local size = math.min(14, 5 + math.floor(math.sqrt(k.qty) / 3))
          rect(c, p.x - size / 2, y(each) - size / 2, size, size, kind == "bought" and BOUGHT or T.gold, 1, "OVERLAY")
          local text = kind == "bought" and L["Bought %d at %s each"] or L["Sold %d at %s each"]
          rows[#rows + 1] = { string.format(text, k.qty, GW.Money(each, true)) }
          dotY = y(each)
        end
      end
      p.title, p.rows, p.y = dayLabel(p.day), rows, dotY or p.y
      marks[#marks + 1] = p
    end
  end
  c.marks = marks
  c.below:SetText(
    string.format(
      L["%sbought|r    %ssold|r    %s—|r price    %snormal range|r"],
      hex(BOUGHT),
      hex(T.gold),
      keyHex(T.faint, 0.3),
      keyHex(T.chartRef)
    )
  )
  ready()
end

local DRAW = { price = drawPrice, demand = drawDemand, supply = drawSupply, resell = drawResell, trades = drawTrades }

--- Draws the open tab and marks its button.
local function renderTab()
  local c = mw.chart
  begin(c)
  clearHover(c)
  c.marks = nil
  mw.big:SetText("")
  mw.words:SetText("")
  UI.SetChip(mw.chip, nil)
  for _, f in ipairs({ c.below, c.note, c.hi, c.lo, c.xFirst, c.xMid, c.xLast }) do
    f:SetText("")
  end
  DRAW[mw.tab]()
  finish(c)
  for _, b in ipairs(mw.tabs) do
    UI.SetSelected(b, b.key == mw.tab)
  end
end

--- Opens a tab.
---@param key string "price", "demand", "supply", "resell" or "trades"
local function showTab(key)
  mw.tab = key
  renderTab()
end

--- The tab to the left (-1) or right (1) of the open one, wrapping (LB / RB on a controller).
---@param dir number
local function stepTab(dir)
  local at = 1
  for i, t in ipairs(MARKET_TABS) do
    if t.key == mw.tab then at = i end
  end
  showTab(MARKET_TABS[(at - 1 + dir) % #MARKET_TABS + 1].key)
end

--- Builds the Market window: the item, the four tabs, and one card with the big answer, the chart
--- and its key.
local function buildMarket()
  local T = UI.Tokens()
  mw = { tab = "price", days = 30 }
  local f = UI.Window("GoldwrightMarket", MW, MH, { title = L["Market"], movable = true })
  f:SetPoint("CENTER")
  if f.Inset then f.Inset:Hide() end
  mw.frame = f
  mw.icon = f:CreateTexture(nil, "ARTWORK")
  mw.icon:SetSize(32, 32)
  mw.icon:SetPoint("TOPLEFT", 16, -34)
  mw.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  mw.title = UI.Text(f, "GameFontNormalLarge", "text", "LEFT")
  mw.title:SetPoint("TOPLEFT", 58, -36)
  mw.sub = UI.Text(f, "GameFontHighlightSmall", "muted", "LEFT")
  mw.sub:SetPoint("TOPLEFT", 58, -56)

  mw.tabs = {}
  local x = 12
  for i, t in ipairs(MARKET_TABS) do
    local b = UI.WindowTab(f, t.label, 24, function() showTab(t.key) end)
    b:SetPoint("TOPLEFT", x, -76)
    x = x + b:GetWidth() + 4
    b.key = t.key
    mw.tabs[i] = b
  end

  local cardW, cardH = MW - 24, MH - 112
  local card = UI.Card(f)
  card:SetPoint("TOPLEFT", 12, -100)
  card:SetSize(cardW, cardH)
  mw.big = UI.Text(card, "GameFontHighlightLarge", "text", "LEFT")
  mw.big:SetPoint("TOPLEFT", 12, -14)
  mw.words = UI.Text(card, "GameFontHighlight", "muted", "LEFT")
  mw.words:SetPoint("LEFT", mw.big, "RIGHT", 12, 0)
  mw.chip = UI.Chip(card)
  mw.chip:SetPoint("LEFT", mw.big, "RIGHT", 12, 0)

  local box = { x = 12, y = -46, w = cardW - 24, h = cardH - 46 - 58 }
  local c = newChart(card, "market", box)
  c.msg:SetFontObject("GameFontHighlight")
  c.msg:SetPoint("TOPLEFT", card, "TOPLEFT", box.x, box.y - 12)
  c.msg:SetSpacing(4)
  c.hi = fs(c.plot, "GameFontDisableSmall", "LEFT")
  c.hi:SetPoint("TOPLEFT", 3, -2)
  c.lo = fs(c.plot, "GameFontDisableSmall", "LEFT")
  c.lo:SetPoint("BOTTOMLEFT", 3, 3)
  local xy = box.y - box.h - 4
  c.xFirst = fs(card, "GameFontDisableSmall", "LEFT")
  c.xFirst:SetPoint("TOPLEFT", box.x, xy)
  c.xMid = fs(card, "GameFontDisableSmall", "CENTER")
  c.xMid:SetPoint("TOP", card, "TOPLEFT", box.x + box.w / 2, xy)
  c.xLast = fs(card, "GameFontDisableSmall", "RIGHT")
  c.xLast:SetPoint("TOPRIGHT", card, "TOPLEFT", box.x + box.w, xy)
  UI.SetColor(c.below, T.faint)
  for _, l in ipairs({ c.xFirst, c.xMid, c.xLast }) do
    c.extras[#c.extras + 1] = l
  end
  -- a quiet second line under the key: what "normal range" or "usually" means
  c.note = fs(card, "GameFontDisableSmall", "LEFT")
  c.note:SetPoint("TOPLEFT", box.x, box.y - box.h - 34)
  c.extras[#c.extras + 1] = c.note
  addHover(c)
  mw.chart = c
  if GW.Gamepad and GW.Gamepad.Tabs then GW.Gamepad.Tabs(f, stepTab) end
  f:Hide()
end

--- Opens the Market window for an item on its Price tab (a click on the Sell tab's price history).
--- It only shows; it never changes anything on the Sell tab.
---@param itemID number
---@param name string|nil the item's name (your own trades are kept by name)
---@param days number|nil 7 or 30: the days the Sell tab's price history shows (default 30)
function Charts.OpenMarket(itemID, name, days)
  if not itemID then return end
  if not mw then buildMarket() end
  mw.itemID, mw.name, mw.tab, mw.days = itemID, name, "price", days or 30
  local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
  mw.icon:SetTexture(icon or 134400)
  mw.title:SetText(name or string.format(L["item %d"], itemID))
  mw.sub:SetText(string.format(L["%s · last %d days"], GW.HOUSE_NAMES[side()], mw.days))
  mw.frame:Show()
  renderTab()
end

--- Follows the Sell tab's 7d / 30d in an open Market window of the same item.
---@param itemID number|nil
---@param days number
function Charts.MarketDays(itemID, days)
  if mw and mw.frame:IsShown() and mw.itemID == itemID and mw.days ~= days then
    mw.days = days
    mw.sub:SetText(string.format(L["%s · last %d days"], GW.HOUSE_NAMES[side()], days))
    renderTab()
  end
end

--- The Sell tab's live listings of an item, for Supply. Redraws an open Market window of that item.
---@param itemID number|nil
---@param stats GoldwrightMarketStats|nil
function Charts.Listings(itemID, stats)
  live.itemID, live.stats = itemID, stats
  if mw and mw.frame:IsShown() and mw.itemID == itemID then renderTab() end
end

--- Opens a tab of the Market window (tests, and the controller's LB / RB through stepTab).
---@param key string "price", "demand", "supply", "resell" or "trades"
function Charts.MarketTab(key)
  if mw then showTab(key) end
end

--- The Market window's chart, once the window exists.
---@return GoldwrightChart|nil
function Charts.MarketChart() return mw and mw.chart end

--- The Market window's state (tests).
---@return GoldwrightMarketWindow|nil
function Charts.Market() return mw end

--- Shows one chart: "history" or "hours".
---@param view string
function Charts.Show(view)
  Charts.view = view == "hours" and "hours" or "history"
  refresh()
end

--- Redraws both charts for an item. Does nothing before Charts.Create.
---@param itemID number|nil item id (nil clears the remembered item)
---@param name string|nil its name, to mark your own sales on the price history
function Charts.Render(itemID, name)
  if name or itemID ~= current then currentName = name end
  current = itemID
  if not (hist and itemID) then return end
  clearHover(hist)
  clearHover(hrs)
  drawHistory(itemID)
  drawHours(itemID)
end
