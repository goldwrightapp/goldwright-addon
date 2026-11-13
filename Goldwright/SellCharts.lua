--- The Sell panel's two charts (SELL-15 price history, SELL-16 best time to post): Line objects for
--- price lines (bars or dots where CreateLine is missing), Textures for bars and reference lines.
--- Drawn once per selected item (or toggle / settings change) from pooled objects: no OnUpdate, no
--- work while idle. The numbers come from Selling.lua (GW.HistoryWindow, ...), tested without the UI.
local _, GW = ...
local L = GW.L

local CW, PH = 182, 80 -- chart width, plot height
local GAP = 16 -- between the two charts
local TOP = -286 -- header row in col2
local PLOT_Y = TOP - 18 -- plot top
local LABEL_PAD = 13 -- room for the small labels inside the plot
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
local UI = GW.UI
local GREY = UI.GREY

--- One chart: its frames and the pools of lines and textures it draws with.
---@class GoldwrightChart
---@field lines table[] pooled Line objects
---@field texs table[] pooled textures
---@field nLines number lines used in the current drawing
---@field nTexs number textures used in the current drawing
---@field header table title font string
---@field plot table plot frame
---@field msg table message shown instead of the plot
---@field below table legend / callout under the x labels
---@field useLines boolean the client can create Line objects
---@field extras table[]|nil frames outside the plot shown and hidden with it
---@field days number|nil history: days shown (7 or 30)
---@field hi table|nil history: top price label
---@field lo table|nil history: bottom price label
---@field xFirst table|nil history: first day label
---@field xLast table|nil history: last day label
---@field toggles table[]|nil history: the 7d / 30d buttons
---@field units table|nil hours: "up to n listed" label
---@field price table|nil hours: price range label
---@field window GoldwrightPostWindow|nil hours: the window drawn last (for tests)

--- The Sell panel charts (GW.SellCharts).
---@class GoldwrightSellCharts
---@field history GoldwrightChart|nil
---@field hours GoldwrightChart|nil
local Charts = {}
GW.SellCharts = Charts
local hist, hrs -- the two chart objects
local current -- item id drawn last

--- A colour escape ("|cffrrggbb") for an {r, g, b} colour.
---@param c number[]
---@return string
local function hex(c)
  local function b(v) return math.floor(v * 255 + 0.5) end
  return string.format("|cff%02x%02x%02x", b(c[1]), b(c[2]), b(c[3]))
end

--- A chart label font string, drawn above the plot textures (OVERLAY).
---@param parent table
---@param template string? font object (default "GameFontDisableSmall")
---@param justify string?
---@return table fontString
local function fs(parent, template, justify)
  return UI.FontString(parent, template or "GameFontDisableSmall", justify, "OVERLAY")
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

--- Creates a chart: header, plot frame with background and base line, message and callout.
---@param parent table the Sell panel's middle column
---@param x number left offset in `parent`
---@param title string chart heading
---@return GoldwrightChart
local function newChart(parent, x, title)
  local c = { lines = {}, texs = {}, nLines = 0, nTexs = 0 }
  c.header = fs(parent, "GameFontNormal", "LEFT")
  c.header:SetPoint("TOPLEFT", x, TOP)
  c.header:SetText(title)
  c.plot = CreateFrame("Frame", nil, parent)
  c.plot:SetPoint("TOPLEFT", x, PLOT_Y)
  c.plot:SetSize(CW, PH)
  local bg = c.plot:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 1, 1, 0.03)
  local base = c.plot:CreateTexture(nil, "BORDER")
  base:SetPoint("BOTTOMLEFT")
  base:SetPoint("BOTTOMRIGHT")
  base:SetHeight(1)
  base:SetColorTexture(1, 1, 1, 0.15)
  c.msg = fs(parent, "GameFontDisableSmall", "LEFT")
  c.msg:SetPoint("TOPLEFT", x, PLOT_Y - 2)
  c.msg:SetWidth(CW)
  c.below = fs(parent, "GameFontHighlightSmall", "LEFT") -- legend / callout under the x labels
  c.below:SetPoint("TOPLEFT", x, PLOT_Y - PH - 18)
  c.below:SetWidth(CW)
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
local function polyline(c, pts, color, dots)
  for i = 1, #pts do -- every entry is a table, so # is safe here
    local p, prev, nxt = pts[i], pts[i - 1], pts[i + 1]
    if p.y then
      if c.useLines and nxt and nxt.y then segment(c, p.x, p.y, nxt.x, nxt.y, color, 2) end
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

--- Shows the plot (and its extras), or hides it and shows a message instead.
---@param c GoldwrightChart
---@param shown boolean
---@param msg string|nil message when hidden
local function showChart(c, shown, msg)
  c.plot:SetShown(shown)
  c.msg:SetShown(not shown)
  c.msg:SetText(msg or "")
  for _, f in ipairs(c.extras or {}) do
    f:SetShown(shown)
  end
end

---------------------------------------------------------------------------
-- SELL-15: price history
---------------------------------------------------------------------------

--- Draws the price history chart for an item: daily prices over 7 or 30 days against the 30-day
--- average, or a message while there is too little history.
---@param itemID number
local function drawHistory(itemID)
  local c = hist
  begin(c)
  local values, from = GW.History(itemID, side())
  local pack = GW.Pack()
  local w = values and GW.HistoryWindow(values, from, pack and pack.snapshotAt, c.days)
  if not pack then
    showChart(c, false, L["Price history comes with the Goldwright Data pack."])
  elseif not w or w.total < GW.HISTORY_MIN_DAYS then
    local have = w and w.total or 0
    -- "since Nov 9": the pipeline's first day of history.
    showChart(
      c,
      false,
      have > 0 and string.format(L["Building history (since Nov 9): %d of %d days so far."], have, GW.HISTORY_MIN_DAYS)
        or L["Building history (since Nov 9)."]
    )
  else
    showChart(c, true)
    local d = GW.ItemData(itemID)
    local here = d and d[side()]
    local avg = (here and here.avg30) or w.avg
    local n = c.days
    local lo, hi = range(w.values, n, avg)
    local function y(v) return LABEL_PAD + (v - lo) / (hi - lo) * (PH - 2 * LABEL_PAD) end
    rect(c, 0, y(avg) - 0.5, CW, 1, GW.SIGNAL_ORANGE, 0.8, "ARTWORK") -- 30-day average
    if c.useLines then
      local pts = {}
      for i = 1, n do
        local v = w.values[i]
        pts[i] = { x = 3 + (i - 1) / (n - 1) * (CW - 6), y = v and y(v) }
      end
      polyline(c, pts, GW.GOLD, n <= 7)
    else
      local bw = CW / n
      for i = 1, n do
        local v = w.values[i]
        if v then rect(c, (i - 1) * bw + 0.5, 0, bw - 1, y(v), GW.GOLD, 0.85) end
      end
    end
    c.hi:SetText(GW.Money(hi))
    c.lo:SetText(GW.Money(lo))
    c.xFirst:SetText(dayLabel(w.firstDay))
    c.xLast:SetText(dayLabel(w.firstDay + (n - 1) * 86400))
    c.below:SetText(string.format(L["%s—|r 30-day average %s"], hex(GW.SIGNAL_ORANGE), GW.Money(avg)))
  end
  for _, b in ipairs(c.toggles) do
    if b.days == c.days then
      b:LockHighlight()
    else
      b:UnlockHighlight()
    end
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
  begin(c)
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
    showChart(c, true)
    local win = GW.BestPostWindow(profile, offset)
    local bw = CW / 24
    local top = PH - LABEL_PAD - 1
    for h = 1, 24 do
      local u = units[h]
      if u and u > 0 then
        local inWin = win and not win.flat and (h - 1 - win.start) % 24 < GW.POST_WINDOW
        rect(c, (h - 1) * bw + 0.5, 0, bw - 1.5, math.max(1, u / maxU * top), GW.SIGNAL_BLUE, inWin and 0.9 or 0.3)
      end
    end
    local lo, hi = range(prices, 24)
    if lo then
      local pts = {}
      for h = 1, 24 do
        local p = prices[h]
        pts[h] = { x = (h - 0.5) * bw, y = p and (6 + (p - lo) / (hi - lo) * (top - 10)) }
      end
      polyline(c, pts, GW.GOLD, false)
      c.price:SetText(GW.Money(lo) .. "–" .. GW.Money(hi))
    else
      c.price:SetText("")
    end
    c.units:SetText(string.format(L["up to %s listed"], GW.Number(math.floor(maxU + 0.5))))
    c.below:SetText(GW.BestPostText(win) or "")
    if win and not win.flat then
      UI.SetColor(c.below, GW.SIGNAL_BLUE)
    else
      UI.SetColor(c.below, GREY)
    end
    c.window = win
  end
  finish(c)
end

---------------------------------------------------------------------------
-- construction and API
---------------------------------------------------------------------------

--- Builds both charts in the Sell panel's middle column, side by side: price history (with 7d /
--- 30d toggles) and best time to post (with hour labels in the player's time).
---@param col2 table the middle column frame
function Charts.Create(col2)
  hist = newChart(col2, 0, L["Price history"])
  hist.days = 7
  hist.hi = fs(hist.plot, "GameFontDisableSmall", "LEFT")
  hist.hi:SetPoint("TOPLEFT", 2, -1)
  hist.lo = fs(hist.plot, "GameFontDisableSmall", "LEFT")
  hist.lo:SetPoint("BOTTOMLEFT", 2, 2)
  hist.xFirst = fs(col2, "GameFontDisableSmall", "LEFT")
  hist.xFirst:SetPoint("TOPLEFT", 0, PLOT_Y - PH - 3)
  hist.xLast = fs(col2, "GameFontDisableSmall", "RIGHT")
  hist.xLast:SetPoint("TOPRIGHT", col2, "TOPLEFT", CW, PLOT_Y - PH - 3)
  hist.extras = { hist.xFirst, hist.xLast, hist.below }
  hist.toggles = {}
  for i, days in ipairs({ 7, 30 }) do
    local b = CreateFrame("Button", nil, col2, "UIPanelButtonTemplate")
    b:SetSize(32, 16)
    b:SetPoint("TOPLEFT", CW - 66 + (i - 1) * 34, TOP + 2)
    b:SetNormalFontObject("GameFontHighlightSmall")
    b:SetText(string.format(L["%dd"], days))
    b.days = days
    b:SetScript("OnClick", function()
      hist.days = days
      if current then drawHistory(current) end
    end)
    hist.toggles[i] = b
    hist.extras[#hist.extras + 1] = b
  end

  local x2 = CW + GAP
  hrs = newChart(col2, x2, L["Best time to post"])
  local tz = fs(col2, "GameFontDisableSmall", "RIGHT")
  tz:SetPoint("TOPRIGHT", col2, "TOPLEFT", x2 + CW, TOP - 1)
  tz:SetText(L["your time"])
  hrs.units = fs(hrs.plot, "GameFontDisableSmall", "LEFT")
  hrs.units:SetPoint("TOPLEFT", 2, -1)
  hrs.price = fs(hrs.plot, "GameFontDisableSmall", "RIGHT")
  hrs.price:SetPoint("TOPRIGHT", -2, -1)
  hrs.extras = { hrs.below }
  for i, h in ipairs({ 0, 6, 12, 18 }) do
    local l = fs(col2, "GameFontDisableSmall", "LEFT")
    l:SetPoint("TOPLEFT", x2 + h * CW / 24, PLOT_Y - PH - 3)
    l:SetText(GW.HourLabel(h))
    hrs.extras[#hrs.extras + 1] = l
  end
  hrs.below:SetWordWrap(true)
  Charts.history, Charts.hours = hist, hrs
end

--- Redraws both charts for an item. Does nothing before Charts.Create.
---@param itemID number|nil item id (nil clears the remembered item)
function Charts.Render(itemID)
  current = itemID
  if not (hist and itemID) then return end
  drawHistory(itemID)
  drawHours(itemID)
end
