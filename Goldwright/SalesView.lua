--- The Sales window (B1): your sales record from Ledger.lua. It doesn't need the auction house, so it
--- is a window of its own, opened from the launcher, /gw sales, the Goldwright panel's Sales button
--- and a button beside the mailbox (setting "mailButton"), where new sales come in. Shows totals for
--- 7 / 30 / 90 days, best sellers, items that keep coming back unsold, and the latest events.
local _, GW = ...
local L = GW.L

local UI = GW.UI
local fs, setColor = UI.FontString, UI.SetColor
local GREY = UI.GREY

local PERIODS = { 7, 30, 90 }
local BEST_ROWS, BACK_ROWS, RECENT_ROWS = 12, 5, 6
--- Items count as "keeps coming back" from this many returns, when at most this share sold.
local BACK_MIN, BACK_MAX_RATE = 2, 0.5

local view, window
local period = 30
local render, showIO -- defined below

--- A label above a big value (the totals row).
---@param parent table
---@param x number
---@param label string
---@return table value font string
local function kpi(parent, x, label)
  local l = fs(parent, "GameFontHighlightSmall", "LEFT")
  l:SetPoint("TOPLEFT", x, -44)
  l:SetText(label)
  setColor(l, GREY)
  local v = fs(parent, "GameFontHighlightLarge", "LEFT")
  v:SetPoint("TOPLEFT", x, -60)
  return v
end

--- A row of font strings at fixed x offsets.
---@param parent table
---@param y number
---@param columns { x: number, w: number, justify: string }[]
---@return table[] cells
local function row(parent, y, columns)
  local cells = {}
  for i, c in ipairs(columns) do
    local f = fs(parent, "GameFontHighlightSmall", c.justify or "LEFT")
    f:SetPoint("TOPLEFT", c.x, y)
    f:SetWidth(c.w)
    f:SetWordWrap(false)
    cells[i] = f
  end
  return cells
end

local BEST_COLS = {
  { x = 16, w = 170 },
  { x = 190, w = 55, justify = "RIGHT" },
  { x = 250, w = 95, justify = "RIGHT" },
  { x = 350, w = 95, justify = "RIGHT" },
}

--- One line about an event: "Nov 12 · Sold 20 × Thick Leather · 99s 40c".
---@param e GoldwrightLedgerEvent
---@return string
local function eventText(e)
  local what
  if e.kind == "sold" then
    what = string.format(L["Sold %s × %s · %s"], GW.Number(e.qty), e.item, GW.Money(e.money - (e.cut or 0)))
  elseif e.kind == "bought" then
    what = string.format(L["Bought %s × %s · %s"], GW.Number(e.qty), e.item, GW.Money(e.money))
  elseif e.kind == "expired" then
    what = string.format(L["Expired %s × %s"], GW.Number(e.qty), e.item)
  else
    what = string.format(L["Cancelled %s × %s"], GW.Number(e.qty), e.item)
  end
  return GW.DateLabel(e.t) .. " · " .. what
end

--- Fills the view from the record.
render = function()
  if not (view and view:IsShown()) then return end
  for _, b in ipairs(view.periodButtons) do
    UI.SetSelected(b, b.days == period)
  end
  local all = GW.LedgerEvents(nil)
  view.empty:SetShown(#all == 0)
  view.content:SetShown(#all > 0)
  view.session:SetText(GW.Plural(GW.session.sold, "This session: %d sale", "This session: %d sales"))
  if #all == 0 then return end

  local t = GW.LedgerTotals(period)
  view.net:SetText(GW.Money(t.net))
  view.sold:SetText(GW.PluralCount(t.sold, "%s unit", "%s units"))
  view.spent:SetText(GW.Money(t.spent))
  view.unsold:SetText(GW.PluralCount(t.unsold, "%s unit", "%s units"))

  local items = GW.LedgerItems(period)
  local shown = 0
  for _, x in ipairs(items) do
    if x.sold > 0 and shown < BEST_ROWS then
      shown = shown + 1
      local r = view.best[shown]
      r[1]:SetText(x.item)
      r[2]:SetText(GW.Number(x.sold))
      r[3]:SetText(GW.Money(x.net))
      r[4]:SetText(string.format("%d%%", math.floor(x.rate * 100 + 0.5)))
    end
  end
  for i = shown + 1, BEST_ROWS do
    for _, c in ipairs(view.best[i]) do
      c:SetText("")
    end
  end
  view.bestNone:SetShown(shown == 0)

  local back = {}
  for _, x in ipairs(items) do
    if x.returns >= BACK_MIN and x.rate <= BACK_MAX_RATE then back[#back + 1] = x end
  end
  table.sort(back, function(a, b) return a.returns > b.returns end)
  for i = 1, BACK_ROWS do
    local x = back[i]
    view.back[i]:SetText(
      x
          and string.format(
            L["%s · back %s · %d%% of yours sold"],
            x.item,
            GW.Plural(x.returns, "%d time", "%d times"),
            math.floor(x.rate * 100 + 0.5)
          )
        or ""
    )
  end
  view.backNone:SetShown(#back == 0)
  view.backHint:SetShown(#back > 0)

  local recent = GW.LedgerEvents(nil)
  for i = 1, RECENT_ROWS do
    local e = recent[#recent - i + 1]
    view.recent[i]:SetText(e and eventText(e) or "")
  end

  local months = GW.LedgerMonths()
  local parts = {}
  for i = 1, math.min(3, #months) do
    parts[#parts + 1] = string.format("%s %s", months[i].month, GW.Money(months[i].net))
  end
  view.months:SetText(#parts > 0 and string.format(L["Earlier months, earned: %s"], table.concat(parts, " · ")) or "")
end

--- The export / import window (built on first use), like the shopping lists'.
local io

--- Opens the window: export shows the record as text to copy; import merges pasted text.
---@param mode "export"|"import"
showIO = function(mode)
  if not io then
    io = UI.Window("GoldwrightSalesIO", 520, 360, { strata = "FULLSCREEN_DIALOG" }) -- above the Sales window
    io:SetPoint("CENTER")
    io.hint = fs(io, "GameFontHighlightSmall", "LEFT")
    io.hint:SetPoint("TOPLEFT", 18, -32)
    io.hint:SetWidth(480)
    local area
    area, io.box = UI.TextArea(io, 440)
    area:SetPoint("TOPLEFT", 14, -54)
    area:SetPoint("BOTTOMRIGHT", -14, 48)
    io.box:SetScript("OnEditFocusGained", function(self)
      if io.mode == "export" then self:HighlightText() end
    end)
    io.ok = UI.Button(io, "", 120, 24, function()
      if io.mode == "import" then
        local added, skipped, problem = GW.ImportLedger(io.box:GetText())
        local msg = GW.Plural(added, "Merged: %d new entry.", "Merged: %d new entries.")
          .. " "
          .. GW.Plural(skipped, "%d was already here.", "%d were already here.")
        if problem then msg = (added + skipped > 0 and msg .. " " or "") .. problem end
        if view then
          view.toast:SetText(msg)
          setColor(view.toast, (added + skipped > 0 and not problem) and GW.SIGNAL_BLUE or GW.SIGNAL_ORANGE)
        end
        GW.Print("%s", msg)
      end
      io:Hide()
      render()
    end)
    io.ok:SetPoint("BOTTOMRIGHT", -16, 16)
  end
  io.mode = mode
  UI.SetTitle(io, mode == "import" and L["Import Sales"] or L["Export Sales"])
  if mode == "import" then
    io.hint:SetText(L["Paste the text from Export on your other computer. Entries already here are skipped."])
    io.box:SetText("")
    if io.box.SetMaxLetters then io.box:SetMaxLetters(GW.LEDGER_IMPORT_LIMITS.chars + 1) end
    io.ok:SetText(L["Merge"])
  else
    -- The period chosen in the window (7 / 30 / 90 days): merging often keeps the text short.
    local text, count = GW.ExportLedger(period)
    io.hint:SetText(
      GW.PluralCount(count, "%s entry", "%s entries")
        .. " · "
        .. GW.Plural(period, "the last %d day", "the last %d days")
        .. ". "
        .. L["Copy this text (Ctrl+A, then Ctrl+C), then use Import on your other computer."]
    )
    if io.box.SetMaxLetters then io.box:SetMaxLetters(0) end
    io.box:SetText(text)
    io.ok:SetText(L["Close"])
    io.box:HighlightText()
  end
  io:Show()
  io.box:SetFocus()
end

--- Creates the view's frames on `parent`.
---@param parent table
local function build(parent)
  view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints()

  view.periodButtons = {}
  local prev
  for i, days in ipairs(PERIODS) do
    local b = UI.ToggleButton(view, GW.Plural(days, "%d day", "%d days"), 80, 22, function()
      period = days
      render()
    end)
    b.days = days
    if i == 1 then
      b:SetPoint("TOPLEFT", 16, -10)
    else
      b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    end
    view.periodButtons[i] = b
    prev = b
  end
  view.importButton = UI.Button(view, L["Import"], 80, 22, function() showIO("import") end)
  view.importButton:SetPoint("TOPRIGHT", -16, -10)
  view.exportButton = UI.Button(view, L["Export"], 80, 22, function() showIO("export") end)
  view.exportButton:SetPoint("RIGHT", view.importButton, "LEFT", -4, 0)
  UI.HoverTip(
    view.exportButton,
    L["Copy your record to merge it into Goldwright on another computer (Import there). WoW keeps add-on data per computer."]
  )
  view.session = fs(view, "GameFontHighlightSmall", "RIGHT")
  view.session:SetPoint("RIGHT", view.exportButton, "LEFT", -12, 0)
  -- The merge result, on its own line above the footer (the top row is full).
  view.toast = fs(view, "GameFontHighlightSmall", "LEFT")
  view.toast:SetPoint("BOTTOMLEFT", 16, 48)
  view.toast:SetWidth(720)

  -- Nothing recorded yet.
  view.empty = CreateFrame("Frame", nil, view)
  view.empty:SetAllPoints()
  local et = fs(view.empty, "GameFontNormalLarge", "LEFT")
  et:SetPoint("TOPLEFT", 16, -60)
  et:SetText(L["No auction mail read yet"])
  local ed = fs(view.empty, "GameFontHighlight", "LEFT")
  ed:SetPoint("TOPLEFT", 16, -88)
  ed:SetWidth(720)
  ed:SetText(
    L["Open a mailbox: Goldwright reads your auction mail (sales, purchases and items that came back unsold) and keeps your record from now on. Nothing is taken out of the mail."]
  )

  local c = CreateFrame("Frame", nil, view)
  c:SetAllPoints()
  view.content = c
  view.net = kpi(c, 16, L["Earned after the cut"])
  view.sold = kpi(c, 200, L["Sold"])
  view.spent = kpi(c, 340, L["Spent buying"])
  view.unsold = kpi(c, 500, L["Came back unsold"])

  UI.Header(c, L["Best sellers"], 16, -100)
  local head = row(c, -122, BEST_COLS)
  head[1]:SetText(L["Item"])
  head[2]:SetText(L["Sold"])
  head[3]:SetText(L["Earned"])
  head[4]:SetText(L["Of yours sold"])
  for _, h in ipairs(head) do
    setColor(h, GREY)
  end
  view.best = {}
  for i = 1, BEST_ROWS do
    view.best[i] = row(c, -122 - i * 18, BEST_COLS)
  end
  view.bestNone = fs(c, "GameFontDisable", "LEFT")
  view.bestNone:SetPoint("TOPLEFT", 16, -144)
  view.bestNone:SetText(L["Nothing sold in this period."])

  UI.Header(c, L["Keeps coming back unsold"], 460, -100)
  view.back = {}
  for i = 1, BACK_ROWS do
    local l = fs(c, "GameFontHighlightSmall", "LEFT")
    l:SetPoint("TOPLEFT", 460, -104 - i * 18)
    l:SetWidth(300)
    l:SetWordWrap(false)
    view.back[i] = l
  end
  view.backNone = fs(c, "GameFontDisable", "LEFT")
  view.backNone:SetPoint("TOPLEFT", 460, -122)
  view.backNone:SetText(L["Nothing so far."])
  view.backHint = fs(c, "GameFontDisableSmall", "LEFT")
  view.backHint:SetPoint("TOPLEFT", 460, -104 - (BACK_ROWS + 1) * 18)
  view.backHint:SetWidth(300)
  view.backHint:SetText(L["Price it lower, or sell it to a vendor."])

  UI.Header(c, L["Latest"], 460, -250)
  view.recent = {}
  for i = 1, RECENT_ROWS do
    local l = fs(c, "GameFontHighlightSmall", "LEFT")
    l:SetPoint("TOPLEFT", 460, -254 - i * 18)
    l:SetWidth(300)
    l:SetWordWrap(false)
    view.recent[i] = l
  end

  view.months = fs(c, "GameFontHighlightSmall", "LEFT")
  view.months:SetPoint("BOTTOMLEFT", 16, 30)
  view.months:SetWidth(720)
  local note = fs(view, "GameFontDisableSmall", "LEFT")
  note:SetPoint("BOTTOMLEFT", 16, 12)
  note:SetWidth(720)
  note:SetText(
    L["From your auction mail, read when you open a mailbox. One record for all characters of this WoW account on this computer; Export and Import merge it with another computer. Buyer names are never stored."]
  )
end

--- Redraws when the record changes (new mail, a sale message).
function GW.OnLedgerChanged() render() end

--- The Sales view, shown and hidden by the panel's tab bar (SellPanel.lua) and by its own window.
GW.SalesView = {}

--- Shows the view on `parent` (the panel's inset or the Sales window), building it on first use.
---@param parent table
function GW.SalesView.Show(parent)
  if not view then build(parent) end
  if view:GetParent() ~= parent then
    view:SetParent(parent)
    view:ClearAllPoints()
    view:SetAllPoints()
  end
  view:Show()
  render()
end

--- Hides the view.
function GW.SalesView.Hide()
  if view then view:Hide() end
end

--- For tests and /dump: the view's frames.
---@return table|nil view
---@return table|nil window
function GW.SalesView.Debug() return view, window end

--- Opens the Sales window (from the launcher, /gw sales, the panel's Sales button or the mailbox).
function GW.OpenSales()
  if not window then
    -- The same strata as the Goldwright panel: it opens in front, and a click brings either one
    -- forward (UI.Window: top-level).
    window = UI.Window("GoldwrightSalesFrame", 800, 520, { title = "Goldwright · " .. L["Sales"], movable = true })
    window:SetPoint("CENTER")
    local inset = window.Inset or window
    if window.Inset then
      window.Inset:ClearAllPoints()
      window.Inset:SetPoint("TOPLEFT", 8, -30)
      window.Inset:SetPoint("BOTTOMRIGHT", -8, 8)
    end
    window.inset = inset
    window:SetScript("OnHide", function()
      if view and view:GetParent() == inset then view:Hide() end
    end)
  end
  window:Show()
  window:Raise() -- already open behind the panel: bring it forward
  GW.SalesView.Show(window.inset)
end

-- A small button beside the mailbox, shown with it (setting "mailButton"). It only opens our window:
-- nothing of the game's mail window is changed.
local mailButton
local mailEvents = CreateFrame("Frame")
pcall(mailEvents.RegisterEvent, mailEvents, "MAIL_SHOW")
mailEvents:SetScript("OnEvent", function()
  if not (MailFrame and GW.Opt("mailButton")) then
    if mailButton then mailButton:Hide() end
    return
  end
  if not mailButton then
    mailButton = UI.Button(MailFrame, L["Your Sales"], 100, 22, function() GW.OpenSales() end)
    mailButton:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 4, -30)
    UI.HoverTip(mailButton, "Goldwright")
  end
  mailButton:Show()
end)

--- For tests: the mailbox button, once the mailbox has been opened.
---@return table|nil
function GW.SalesView.MailButton() return mailButton end
