--- One chart building block for every Goldwright chart (goldwright-addon #38): a plot area with its
--- background, base line, message and legend, and pooled pieces to draw with. A window makes as many
--- charts as it needs (GW.Chart.New) and draws each from its own pools: Begin, then lines, dots,
--- bars and reference lines, then Finish hides what that drawing didn't use. Drawn once per change
--- (an item picked, a switch, a setting): no OnUpdate, no work while idle.
---
--- Price lines are Line objects with a soft-edged texture (Media/ChartLine.tga, written by
--- tools/chart-media.mjs) at a fixed thickness in screen pixels, so they look smooth and even at any
--- UI scale; a round dot marks each day (or hour) with data, and a line can have a faint fill under
--- it. Clients without Line objects get dots only (or bars, chosen by the caller).
---
--- Hover (#13): a chart's marks (the days or hours with data, left to right, in plot coordinates)
--- can be inspected with the mouse or a controller: a thin line and a dot snap to the nearest mark
--- and the game tooltip shows its values. The mouse is only watched while it is over the chart.
local _, GW = ...

local UI = GW.UI

local Chart = {
  LABEL_PAD = 13, -- room for the small labels inside the plot
  WEIGHT = 1.75, -- a price line's weight, in screen pixels
  DOT = 5, -- a day dot's size, in screen pixels
  MARK = 9, -- the hovered day's dot, in screen pixels
  STEADY = 0.1, -- a price scale shows at least ±10% around the normal price
}
GW.Chart = Chart

local MEDIA = "Interface\\AddOns\\Goldwright\\Media\\"
local LINE_TEX, DOT_TEX, FILL_TEX = MEDIA .. "ChartLine", MEDIA .. "ChartDot", MEDIA .. "ChartFill"
local DASH, DASH_GAP = 4, 4 -- the dashed reference line
local all = {} -- every chart made, redrawn when the UI scale changes

---@class GoldwrightChart
---@field key string what the chart is ("history", "hours", "market", ...)
---@field w number plot width
---@field h number plot height
---@field plot table plot frame
---@field msg table message shown instead of the plot
---@field below table legend under the x labels
---@field extras table[] frames outside the plot shown and hidden with it
---@field lines table[] pooled Line objects
---@field texs table[] pooled textures (bars, reference lines, fills, markers)
---@field dots table[] pooled round dots
---@field nLines number
---@field nTexs number
---@field nDots number
---@field useLines boolean the client can create Line objects
---@field ready boolean the last drawing had something to show
---@field marks table[]|nil the days or hours that can be inspected, left to right ({ x, y?, ... })
---@field at number|nil index into marks of the one inspected now
---@field tooltip fun(c: GoldwrightChart, p: table)|nil fills the game tooltip for a mark (default: p.title and p.rows)
---@field onClick fun(i: number)|nil a click (or the controller's A) on mark i
---@field redraw fun()|nil draws the chart again (after a UI scale change)
---@field hit table|nil the frame over the plot that takes the mouse
---@field cross table|nil the thin line on the inspected mark
---@field mark table|nil the dot on the inspected mark
---@field ring table|nil the halo behind that dot
---@field lit table|nil the light column behind the inspected bar

--- Screen pixels to the plot's UI units: the size of one pixel inside the chart.
---@param c GoldwrightChart
---@return number
function Chart.Pixel(c)
  local f = PixelUtil and PixelUtil.GetPixelToUIUnitFactor and PixelUtil.GetPixelToUIUnitFactor()
  if not f and GetPhysicalScreenSize then
    local _, h = GetPhysicalScreenSize()
    f = h and h > 0 and 768 / h or nil
  end
  local s = c.plot:GetEffectiveScale()
  return (f or 1) / ((s and s > 0) and s or 1)
end

--- Lets a piece sit between pixels, so slopes and dots don't jump to the pixel grid.
---@param t table texture or Line
local function free(t)
  if t.SetSnapToPixelGrid then
    t:SetSnapToPixelGrid(false)
    t:SetTexelSnappingBias(0)
  end
end

--- Creates a chart at the box's plot area in `parent`: plot frame with background and base line,
--- the message shown instead of it and the legend under it.
---@param parent table
---@param key string
---@param box { x: number, y: number, w: number, h: number } the plot area in `parent`
---@return GoldwrightChart
function Chart.New(parent, key, box)
  local T = UI.Tokens()
  local c = {
    key = key,
    w = box.w,
    h = box.h,
    lines = {},
    texs = {},
    dots = {},
    nLines = 0,
    nTexs = 0,
    nDots = 0,
    extras = {},
  }
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
  c.msg = UI.FontString(parent, "GameFontDisableSmall", "LEFT", "OVERLAY")
  UI.SetColor(c.msg, T.faint)
  c.msg:SetPoint("TOPLEFT", box.x, box.y - 4)
  c.msg:SetWidth(box.w)
  c.below = UI.FontString(parent, "GameFontHighlightSmall", "LEFT", "OVERLAY") -- legend under the x labels
  UI.SetColor(c.below, T.faint)
  c.below:SetPoint("TOPLEFT", box.x, box.y - box.h - 20)
  c.extras[1] = c.below
  -- Lines exist in this client if the plot can make one; otherwise dots (and bars).
  local ok, probe = pcall(function() return c.plot:CreateLine(nil, "OVERLAY") end)
  c.useLines = ok and probe ~= nil
  if c.useLines then
    probe:Hide()
    c.lines[1] = probe
  end
  all[#all + 1] = c
  return c
end

--- Starts a drawing: every pooled piece is free again.
---@param c GoldwrightChart
function Chart.Begin(c)
  c.nLines, c.nTexs, c.nDots = 0, 0, 0
end

--- Ends a drawing: hides the pooled pieces it didn't use.
---@param c GoldwrightChart
function Chart.Finish(c)
  for _, pool in ipairs({ { c.lines, c.nLines }, { c.texs, c.nTexs }, { c.dots, c.nDots } }) do
    for i = pool[2] + 1, #pool[1] do
      pool[1][i]:Hide()
    end
  end
end

--- A pooled texture at (x, y) from the plot's bottom-left, w x h (at least 1 x 1): a flat colour,
--- or `file` tinted with it.
---@param c GoldwrightChart
---@param file string|nil
---@return table texture
local function piece(c, file, x, y, w, h, color, alpha, layer, sub)
  c.nTexs = c.nTexs + 1
  local t = c.texs[c.nTexs]
  if not t then
    t = c.plot:CreateTexture(nil, "ARTWORK")
    c.texs[c.nTexs] = t
  end
  t:SetDrawLayer(layer or "ARTWORK", sub or 0)
  t:ClearAllPoints()
  t:SetPoint("BOTTOMLEFT", c.plot, "BOTTOMLEFT", x, y)
  t:SetSize(math.max(1, w), math.max(1, h))
  if file then
    t:SetTexture(file)
    t:SetVertexColor(color[1], color[2], color[3], alpha or 1)
  else
    t:SetColorTexture(color[1], color[2], color[3], alpha or 1)
    t:SetVertexColor(1, 1, 1, 1)
  end
  t:SetTexCoord(0, 1, 0, 1)
  t:Show()
  return t
end

--- Draws a filled rectangle (bars, markers, shaded ranges).
---@param c GoldwrightChart
---@param x number left, from the plot's bottom-left
---@param y number bottom
---@param w number width
---@param h number height
---@param color number[] {r, g, b}
---@param alpha number? default 1
---@param layer string? draw layer (default "ARTWORK")
---@param sub number? sublevel (default 0)
---@return table texture
function Chart.Rect(c, x, y, w, h, color, alpha, layer, sub) return piece(c, nil, x, y, w, h, color, alpha, layer, sub) end

--- Draws a dashed horizontal line across the plot at height y.
---@param c GoldwrightChart
---@param y number
---@param color number[]
function Chart.Dashed(c, y, color)
  local x = 0
  while x < c.w do
    piece(c, nil, x, y - 0.5, math.min(DASH, c.w - x), 1, color, 1, "BORDER")
    x = x + DASH + DASH_GAP
  end
end

--- Draws a round dot centred on (x, y), `size` screen pixels across (default Chart.DOT), above the
--- lines.
---@param c GoldwrightChart
---@param x number
---@param y number
---@param color number[]
---@param size number|nil
---@param alpha number|nil
---@return table texture
function Chart.Dot(c, x, y, color, size, alpha)
  c.nDots = c.nDots + 1
  local d = c.dots[c.nDots]
  if not d then
    d = c.plot:CreateTexture(nil, "OVERLAY")
    d:SetDrawLayer("OVERLAY", 2)
    d:SetTexture(DOT_TEX)
    free(d)
    c.dots[c.nDots] = d
  end
  local s = (size or Chart.DOT) * Chart.Pixel(c)
  d:ClearAllPoints()
  d:SetPoint("CENTER", c.plot, "BOTTOMLEFT", x, y)
  d:SetSize(s, s)
  d:SetVertexColor(color[1], color[2], color[3], alpha or 1)
  d:Show()
  return d
end

--- Draws one segment of a line from the Line pool: the soft-edged texture, `weight` screen pixels
--- of colour (the texture's clear edges make it twice as thick).
---@param c GoldwrightChart
---@return table line
local function segment(c, x1, y1, x2, y2, color, weight)
  c.nLines = c.nLines + 1
  local l = c.lines[c.nLines]
  if not l then
    l = c.plot:CreateLine(nil, "OVERLAY")
    c.lines[c.nLines] = l
  end
  if not l.soft then
    l:SetTexture(LINE_TEX)
    l:SetDrawLayer("OVERLAY", 0)
    free(l)
    l.soft = true
  end
  l:SetThickness(2 * weight * Chart.Pixel(c))
  l:SetVertexColor(color[1], color[2], color[3], 1)
  l:SetStartPoint("BOTTOMLEFT", c.plot, x1, y1)
  l:SetEndPoint("BOTTOMLEFT", c.plot, x2, y2)
  l:Show()
  return l
end

--- Fills the area under one segment down to the bottom of the plot: a rectangle up to its lower end
--- and a triangle (Media/ChartFill.tga, flipped when the line falls) up to the line.
---@param c GoldwrightChart
local function fillUnder(c, x1, y1, x2, y2, color, alpha)
  local lo, hi = math.min(y1, y2), math.max(y1, y2)
  if lo > 0 then piece(c, nil, x1, 0, x2 - x1, lo, color, alpha, "BORDER", -1) end
  if hi - lo >= 0.5 then
    local t = piece(c, FILL_TEX, x1, lo, x2 - x1, hi - lo, color, alpha, "BORDER", -1)
    if y2 < y1 then t:SetTexCoord(1, 0, 0, 1) end
  end
end

--- Draws a line through points: straight segments between neighbouring points with a value (never
--- curved: it only connects real days), a dot on each point, and optionally a faint fill under it.
--- Without Line objects only the dots. A point between two gaps always gets its dot.
---@param c GoldwrightChart
---@param pts { x: number, y: number? }[] points (nil y = gap)
---@param color number[] {r, g, b}
---@param opts { weight: number?, dots: boolean?, fill: number? }|nil weight in screen pixels
---  (default Chart.WEIGHT); dots false = only lone points; fill = the fill's alpha (none by default)
function Chart.Line(c, pts, color, opts)
  opts = opts or {}
  local weight = opts.weight or Chart.WEIGHT
  for i = 1, #pts do -- every entry is a table, so # is safe here
    local p, prev, nxt = pts[i], pts[i - 1], pts[i + 1]
    if p.y then
      local joined = c.useLines and nxt and nxt.y
      if joined then
        if opts.fill then fillUnder(c, p.x, p.y, nxt.x, nxt.y, color, opts.fill) end
        segment(c, p.x, p.y, nxt.x, nxt.y, color, weight)
      end
      local alone = not (prev and prev.y) and not (nxt and nxt.y)
      if opts.dots ~= false or alone or not c.useLines then Chart.Dot(c, p.x, p.y, color) end
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
function Chart.Range(values, n, extra)
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

--- A price scale that never zooms in further than ±10% around the normal price `mid`, so a quiet
--- week (99c to 1s 15c) stays near the middle while bigger moves still use the full height. Whole
--- copper at both ends, never below 0.
---@param lo number
---@param hi number
---@param mid number|nil the normal price (nil: lo and hi as they are)
---@return number lo
---@return number hi
function Chart.Steady(lo, hi, mid)
  if mid and mid > 0 then
    lo = math.min(lo, mid * (1 - Chart.STEADY))
    hi = math.max(hi, mid * (1 + Chart.STEADY))
  end
  return math.max(0, math.floor(lo)), math.ceil(hi)
end

--- Value to height: lo sits at `bottom`, hi at `top` (plot coordinates), in a straight line.
---@param lo number
---@param hi number must be above lo (Chart.Range and Chart.Steady make sure)
---@param bottom number
---@param top number
---@return fun(v: number): number y
function Chart.Scale(lo, hi, bottom, top)
  return function(v) return bottom + (v - lo) / (hi - lo) * (top - bottom) end
end

--- Value to height across a chart's plot, leaving room for the small labels at the top and bottom.
---@param c GoldwrightChart
---@param lo number
---@param hi number
---@return fun(v: number): number y
function Chart.PlotScale(c, lo, hi) return Chart.Scale(lo, hi, Chart.LABEL_PAD, c.h - Chart.LABEL_PAD) end

---------------------------------------------------------------------------
-- hover (#13): exact values for the mark under the mouse (or the controller)
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
function Chart.TooltipRow(label, value)
  local T = UI.Tokens()
  GameTooltip:AddDoubleLine(label, value, T.label[1], T.label[2], T.label[3], 1, 1, 1)
end

--- The default tooltip of a mark: its title and rows (a row without a value is a line).
---@param p { title: string, rows: table[] }
local function rowsTooltip(_, p)
  GameTooltip:SetText(p.title, 1, 1, 1)
  for _, r in ipairs(p.rows or {}) do
    if r[2] then
      Chart.TooltipRow(r[1], r[2])
    else
      GameTooltip:AddLine(r[1], 1, 1, 1)
    end
  end
end

--- Stops inspecting a chart: the line, dot, column and tooltip go.
---@param c GoldwrightChart
function Chart.ClearHover(c)
  c.at = nil
  if not c.cross then return end
  c.cross:Hide()
  c.mark:Hide()
  c.ring:Hide()
  c.lit:Hide()
  if GameTooltip:GetOwner() == c.hit then GameTooltip:Hide() end
end

--- Inspects mark i: a thin line and a round dot on it (a light column behind a bar: p.bx, p.bw)
--- and its tooltip beside it, on the side with more room. nil stops.
---@param c GoldwrightChart
---@param i number|nil index into c.marks
function Chart.Inspect(c, i)
  local p = i and c.marks and c.marks[i]
  if not p then return Chart.ClearHover(c) end
  c.at = i
  c.cross:ClearAllPoints()
  c.cross:SetPoint("BOTTOMLEFT", c.plot, "BOTTOMLEFT", p.x - 0.5, 0)
  c.cross:Show()
  if p.y then
    local px = Chart.Pixel(c)
    for _, t in ipairs({ { c.ring, Chart.MARK + 4 }, { c.mark, Chart.MARK } }) do
      t[1]:ClearAllPoints()
      t[1]:SetPoint("CENTER", c.plot, "BOTTOMLEFT", p.x, p.y)
      t[1]:SetSize(t[2] * px, t[2] * px)
      t[1]:Show()
    end
  else
    c.mark:Hide()
    c.ring:Hide()
  end
  if p.bx then
    c.lit:ClearAllPoints()
    c.lit:SetPoint("BOTTOMLEFT", c.plot, "BOTTOMLEFT", p.bx, 0)
    c.lit:SetSize(p.bw, c.h)
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
  local fill = c.tooltip or rowsTooltip
  fill(c, p)
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
  if i ~= c.at then Chart.Inspect(c, i) end
end

--- Gives a chart its hover: a frame over the plot that takes the mouse (no work until the mouse is
--- over it), the line, dot and column it draws, a click (c.onClick), and the controller's inspect
--- (A, then left / right through the marks, A or B to stop; Gamepad.Adjustable).
---@param c GoldwrightChart
function Chart.AddHover(c)
  local T = UI.Tokens()
  c.cross = c.plot:CreateTexture(nil, "OVERLAY")
  c.cross:SetSize(1, c.h)
  c.cross:SetColorTexture(T.text[1], T.text[2], T.text[3], 0.45)
  c.cross:Hide()
  -- the dot on the inspected price, with a halo in the plot's colour to lift it off the line
  c.ring = c.plot:CreateTexture(nil, "OVERLAY", nil, 6)
  c.ring:SetTexture(DOT_TEX)
  c.ring:SetVertexColor(T.chartBg[1], T.chartBg[2], T.chartBg[3], 1)
  free(c.ring)
  c.ring:Hide()
  c.mark = c.plot:CreateTexture(nil, "OVERLAY", nil, 7)
  c.mark:SetTexture(DOT_TEX)
  c.mark:SetVertexColor(T.gold[1], T.gold[2], T.gold[3], 1)
  free(c.mark)
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
    Chart.ClearHover(c)
  end
  hit:SetScript("OnLeave", stop)
  hit:SetScript("OnHide", stop)
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
        Chart.Inspect(c, n)
      end,
      step = 1,
      min = function() return 1 end,
      max = count,
      enabled = function() return c.ready and count() > 0 end,
      show = function(on)
        if on then
          Chart.Inspect(c, c.at or count())
        else
          Chart.ClearHover(c)
        end
      end,
    })
    -- A again (done) on a mark acts like a click on it.
    local adjust = hit.OnSmartNavClick
    hit.OnSmartNavClick = function(self)
      local at = editing() and c.at
      adjust(self)
      if at and c.onClick then c.onClick(at) end
    end
  end
end

-- A new UI scale (or screen size) changes how many UI units a screen pixel is: the charts on screen
-- draw again so their lines and dots keep their size in pixels.
local scale = CreateFrame("Frame")
for _, e in ipairs({ "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }) do
  pcall(scale.RegisterEvent, scale, e)
end
scale:SetScript("OnEvent", function()
  for _, c in ipairs(all) do
    if c.redraw and c.plot:IsVisible() then c.redraw() end
  end
end)
