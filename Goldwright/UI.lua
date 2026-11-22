--- Shared UI helpers for Goldwright's frames: font strings, colours, buttons, windows and the
--- small layout pieces every tab uses. Loaded right after Core.lua, before any file that builds UI.
--- Only builds frames when called: nothing here runs at load time besides defining functions.
local _, GW = ...

---@class GoldwrightUI
---@field GREY number[] secondary text colour {r, g, b}
---@field WHITE number[] primary text colour {r, g, b}
local UI = {}
GW.UI = UI

UI.GREY = { 0.70, 0.70, 0.72 }
UI.WHITE = { 1, 1, 1 }

--- A font string on `parent`.
---@param parent table frame to create it on
---@param template? string font object (default "GameFontHighlight")
---@param justify? string "LEFT", "CENTER" or "RIGHT"
---@param layer? string draw layer (default "ARTWORK")
---@return table fontString the new font string
function UI.FontString(parent, template, justify, layer)
  local f = parent:CreateFontString(nil, layer or "ARTWORK", template or "GameFontHighlight")
  if justify then f:SetJustifyH(justify) end
  return f
end

--- Sets a font string's text colour from an {r, g, b} table.
---@param f table font string
---@param c number[] colour {r, g, b}
function UI.SetColor(f, c) f:SetTextColor(c[1], c[2], c[3]) end

--- The colour of an item quality, from the client (white when unknown).
---@param q? number item quality (Enum.ItemQuality)
---@return number[] colour {r, g, b}
function UI.QualityColor(q)
  if C_Item and C_Item.GetItemQualityColor and q then
    local r, g, b = C_Item.GetItemQualityColor(q)
    if r then return { r, g, b } end
  end
  local c = ITEM_QUALITY_COLORS and q and ITEM_QUALITY_COLORS[q]
  return c and { c.r, c.g, c.b } or { 1, 1, 1 }
end

--- Shows a one-line message in `owner.toast` (the status line under a tab). Does nothing before
--- the owner frame exists.
---@param owner? table frame with a `toast` font string
---@param text? string message ("" or nil clears it)
---@param color? number[] colour {r, g, b} (default white)
function UI.Toast(owner, text, color)
  if not owner then return end
  owner.toast:SetText(text or "")
  UI.SetColor(owner.toast, color or UI.WHITE)
end

--- A section heading (GameFontNormal, left-aligned) at TOPLEFT x, y of `parent`.
---@param parent table frame to create it on
---@param text string heading text
---@param x number offset from the left of `parent`
---@param y number offset from the top of `parent` (negative is down)
---@return table fontString the heading
function UI.Header(parent, text, x, y)
  local h = UI.FontString(parent, "GameFontNormal", "LEFT")
  h:SetPoint("TOPLEFT", x, y)
  h:SetText(text)
  return h
end

--- Blizzard template widgets, each styled by UI.Skin (Skin.lua) as it is made. The caller sizes,
--- labels and places them. Every Goldwright button, text box, close button and check box comes
--- from here, UI.Button or UI.Window, so the template names live in one place.
---@param parent table frame to create it on
---@return table widget
function UI.NewButton(parent) return UI.Skin("button", CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")) end
--- A button that works as a tab or a toggle (UI.SetSelected shows which one is chosen).
function UI.NewTabButton(parent) return UI.Skin("tab", CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")) end
--- A button for a choice among a few (2h / 8h / 24h, 7d / 30d): boxed like a button in Goldwright
--- dark, a tab in other add-ons' looks (UI.SetSelected shows which one is chosen).
function UI.NewToggleButton(parent)
  return UI.Skin("toggle", CreateFrame("Button", nil, parent, "UIPanelButtonTemplate"))
end
function UI.NewEditBox(parent) return UI.Skin("editbox", CreateFrame("EditBox", nil, parent, "InputBoxTemplate")) end
--- A red X button. It hides its parent itself: the template's own click goes through the game's
--- panel manager (HideUIPanel), which add-on code can't use in combat, so the X did nothing until
--- combat ended and the game said "Interface action failed because of an AddOn" (#3). Callers can
--- still set their own OnClick.
---@param parent table
---@return table button
function UI.NewCloseButton(parent)
  local b = UI.Skin("close", CreateFrame("Button", nil, parent, "UIPanelCloseButton"))
  b:SetScript("OnClick", function() parent:Hide() end)
  return b
end
function UI.NewCheckButton(parent)
  return UI.Skin("check", CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate"))
end

--- A standard red button (UIPanelButtonTemplate). The caller places it.
---@param parent table frame to create it on
---@param label string button text
---@param width number in pixels
---@param height number in pixels
---@param onClick? function OnClick script
---@return table button the new button
function UI.Button(parent, label, width, height, onClick)
  local b = UI.NewButton(parent)
  b:SetSize(width, height)
  b:SetText(label)
  if onClick then b:SetScript("OnClick", onClick) end
  return b
end

--- UI.NewToggleButton with a label, size and click (a choice among a few, like 2h / 8h / 24h).
---@param parent table frame to create it on
---@param label string button text
---@param width number in pixels
---@param height number in pixels
---@param onClick? function OnClick script
---@return table button the new button
function UI.ToggleButton(parent, label, width, height, onClick)
  local b = UI.NewToggleButton(parent)
  b:SetSize(width, height)
  b:SetText(label)
  if onClick then b:SetScript("OnClick", onClick) end
  return b
end

--- UI.Button for a tab or a toggle: the same button, styled as a tab in another add-on's look.
---@param parent table frame to create it on
---@param label string button text
---@param width number in pixels
---@param height number in pixels
---@param onClick? function OnClick script
---@return table button the new button
function UI.TabButton(parent, label, width, height, onClick)
  local b = UI.NewTabButton(parent)
  b:SetSize(width, height)
  b:SetText(label)
  if onClick then b:SetScript("OnClick", onClick) end
  return b
end

--- The main button of a view (Post): red like the others in the Blizzard look, gold in Goldwright
--- dark. The caller places it.
---@param parent table frame to create it on
---@param label string button text
---@param width number in pixels
---@param height number in pixels
---@param onClick? function OnClick script
---@return table button the new button
function UI.PrimaryButton(parent, label, width, height, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b.gwPrimary = true
  UI.Skin("primary", b)
  b:SetSize(width, height)
  b:SetText(label)
  if onClick then b:SetScript("OnClick", onClick) end
  return b
end

---------------------------------------------------------------------------
-- Goldwright's own drawing, in the look's colours (UI.Tokens, Skin.lua)
---------------------------------------------------------------------------
--- Fills a frame with a flat colour and an optional 1-pixel border, drawn under everything else on
--- it. Called again, it only changes the colours. `x` and `y` move the edges in (positive) or out
--- (negative) on the left and right / top and bottom, for widgets whose art reaches past their frame.
---@param f table frame
---@param bg number[] {r, g, b[, a]}
---@param border? number[] {r, g, b[, a]}, nil for none
---@param x? number
---@param y? number
---@return table f
function UI.Flat(f, bg, border, x, y)
  x, y = x or 0, y or 0
  if not f.gwFlat then
    local bgTex = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    bgTex:SetPoint("TOPLEFT", x, -y)
    bgTex:SetPoint("BOTTOMRIGHT", -x, y)
    local edges = {}
    for i, e in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" } }) do
      local t = f:CreateTexture(nil, "BORDER", nil, -8)
      t:SetPoint(e[1], bgTex, e[1])
      t:SetPoint(e[2], bgTex, e[2])
      t:SetHeight(1)
      edges[i] = t
    end
    for i, e in ipairs({ { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
      local t = f:CreateTexture(nil, "BORDER", nil, -8)
      t:SetPoint(e[1], bgTex, e[1])
      t:SetPoint(e[2], bgTex, e[2])
      t:SetWidth(1)
      edges[i + 2] = t
    end
    f.gwFlat = { bg = bgTex, edges = edges }
  end
  local flat = f.gwFlat
  flat.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 1)
  for _, t in ipairs(flat.edges) do
    if border then
      t:SetColorTexture(border[1], border[2], border[3], border[4] or 1)
      t:Show()
    else
      t:Hide()
    end
  end
  return f
end

--- A card: a panel of its own with the look's background and border. The caller places it.
---@param parent table
---@return table frame
function UI.Card(parent)
  local T = UI.Tokens()
  return UI.Flat(CreateFrame("Frame", nil, parent), T.card, T.cardBorder)
end

--- A card's caption at TOPLEFT x, y of `parent`: gold in the Blizzard look; in Goldwright dark
--- small and muted after a gold square.
---@param parent table
---@param text string
---@param x number
---@param y number
---@return table fontString
function UI.Caption(parent, text, x, y)
  local T = UI.Tokens()
  local c = UI.FontString(parent, T.captionMark and "GameFontNormalSmall" or "GameFontNormal", "LEFT")
  if T.captionMark then
    local mark = parent:CreateTexture(nil, "ARTWORK")
    mark:SetSize(5, 5)
    mark:SetPoint("TOPLEFT", x, y - 4)
    mark:SetColorTexture(T.gold[1], T.gold[2], T.gold[3], 1)
    c:SetPoint("TOPLEFT", x + 11, y)
  else
    c:SetPoint("TOPLEFT", x, y)
  end
  UI.SetColor(c, T.caption)
  c:SetText(text)
  return c
end

--- A font string in one of the look's text colours ("text", "muted", "faint", "label", "gold").
---@param parent table
---@param template? string font object (default "GameFontHighlightSmall")
---@param tone? string token name (default "text")
---@param justify? string
---@return table fontString
function UI.Text(parent, template, tone, justify)
  local f = UI.FontString(parent, template or "GameFontHighlightSmall", justify)
  UI.SetColor(f, UI.Tokens()[tone or "text"])
  return f
end

--- A 1-pixel line in the look's divider colour (`tone`: "line", default, or "rowLine"). The caller
--- places it (two points, or one point and a size).
---@param parent table
---@param tone? string
---@return table texture
function UI.Rule(parent, tone)
  local c = UI.Tokens()[tone or "line"]
  local t = parent:CreateTexture(nil, "BORDER")
  t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
  return t
end

--- A chip: a short label on a coloured background (UI.SetChip fills it). Anchor it by its TOPLEFT.
---@param parent table
---@return table frame chip with .text
function UI.Chip(parent)
  local chip = CreateFrame("Frame", nil, parent)
  chip:SetHeight(14)
  chip.bg = chip:CreateTexture(nil, "BACKGROUND")
  chip.bg:SetAllPoints()
  chip.text = UI.FontString(chip, "GameFontHighlightSmall", "LEFT")
  chip.text:SetPoint("LEFT", 5, 0)
  chip:Hide()
  return chip
end

--- Shows a chip with `text` in the colours of `kind` ("blue", "orange" or "grey"), or hides it.
---@param chip table UI.Chip
---@param text? string nil or "" hides it
---@param kind? string
function UI.SetChip(chip, text, kind)
  if not text or text == "" then
    chip:Hide()
    return
  end
  local c = UI.Tokens().chips[kind or "grey"] or UI.Tokens().chips.grey
  chip.bg:SetColorTexture(c[1][1], c[1][2], c[1][3], c[1][4] or 1)
  chip.text:SetText(text)
  UI.SetColor(chip.text, c[2])
  chip:SetWidth(math.floor((chip.text:GetStringWidth() or 0) + 10.5))
  chip:Show()
end

--- A horizontal bar for a share (quantity of a listing): a track and a fill. Anchor it by its LEFT.
---@param parent table
---@param width number
---@param height number
---@return table frame bar with .fill
function UI.Bar(parent, width, height)
  local T = UI.Tokens()
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetSize(width, height)
  bar.track = bar:CreateTexture(nil, "BACKGROUND")
  bar.track:SetAllPoints()
  bar.track:SetColorTexture(T.barTrack[1], T.barTrack[2], T.barTrack[3], 1)
  bar.fill = bar:CreateTexture(nil, "ARTWORK")
  bar.fill:SetPoint("TOPLEFT")
  bar.fill:SetPoint("BOTTOMLEFT")
  bar.fill:SetColorTexture(T.barFill[1], T.barFill[2], T.barFill[3], 1)
  bar.width = width
  return bar
end

--- Fills a bar to `share` (0..1; anything shown gets at least 2 pixels).
---@param bar table UI.Bar
---@param share number
function UI.SetBar(bar, share)
  share = math.max(0, math.min(1, share or 0))
  bar.fill:SetWidth(math.max(2, math.floor(bar.width * share + 0.5)))
  bar.share = share
end

--- A window tab (Sell, My Auctions, ...). In the Blizzard look a tab of its own: a dark tab with a
--- gold label, the selected one lighter with a gold line along its top. In every other look the
--- look's own tab (UI.TabButton). Its width follows the label. UI.SetSelected marks the open one.
---@param parent table
---@param label string
---@param height number
---@param onClick? function
---@return table button
function UI.WindowTab(parent, label, height, onClick)
  if UI.LookName() ~= "blizzard" then
    local b = UI.TabButton(parent, label, 80, height, onClick)
    local text = b:GetFontString()
    b:SetWidth(math.max(60, math.floor((text and text:GetStringWidth() or 40) + 28)))
    return b
  end
  local T = UI.Tokens()
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(height)
  b:SetNormalFontObject("GameFontNormal")
  b:SetHighlightFontObject("GameFontHighlight")
  b:SetDisabledFontObject("GameFontDisable")
  b:SetText(label)
  local text = b:GetFontString()
  b:SetWidth(math.max(60, math.floor((text and text:GetStringWidth() or 40) + 36)))
  UI.Flat(b, { 0.10, 0.094, 0.082, 1 }, T.cardBorder)
  local lit = b:CreateTexture(nil, "HIGHLIGHT")
  lit:SetAllPoints()
  lit:SetColorTexture(1, 1, 1, 0.05)
  b.gwTop = b:CreateTexture(nil, "OVERLAY")
  b.gwTop:SetPoint("TOPLEFT", 1, -1)
  b.gwTop:SetPoint("TOPRIGHT", -1, -1)
  b.gwTop:SetHeight(2)
  b.gwTop:SetColorTexture(0.69, 0.553, 0.298, 1)
  b.gwTop:Hide()
  --- Selected: lighter, a gold line along the top and a white label.
  b.gwSetSelected = function(on)
    UI.Flat(b, on and { 0.20, 0.18, 0.15, 1 } or { 0.10, 0.094, 0.082, 1 }, T.cardBorder)
    b.gwTop:SetShown(on)
    b:SetNormalFontObject(on and "GameFontHighlight" or "GameFontNormal")
  end
  if onClick then b:SetScript("OnClick", onClick) end
  return b
end

--- A thin vertical line between two columns, at x from the left of `parent`.
---@param parent table frame to draw it on
---@param x number offset from the left of `parent`
---@return table texture the line
function UI.Divider(parent, x)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetColorTexture(1, 1, 1, 0.08)
  t:SetPoint("TOPLEFT", x, -6)
  t:SetPoint("BOTTOMLEFT", x, 6)
  t:SetWidth(1)
  return t
end

--- A faint background on every second table row, for readability.
---@param row table row frame
---@param i number row index (1-based)
function UI.Stripe(row, i)
  if i % 2 ~= 0 then return end
  local bg = row:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 1, 1, 0.03)
end

--- Shows `text` in the game tooltip while the mouse is over `frame`.
---@param frame table frame that shows the tip
---@param text string tooltip text
---@param anchor? string tooltip anchor (default "ANCHOR_RIGHT")
function UI.HoverTip(frame, text, anchor)
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetText(text)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- Sets the title of a ButtonFrameTemplate window (older clients have only TitleText).
---@param frame table ButtonFrameTemplate window
---@param text string title text
function UI.SetTitle(frame, text)
  if frame.SetTitle then
    frame:SetTitle(text)
  elseif frame.TitleText then
    frame.TitleText:SetText(text)
  end
end

--- Options for UI.Window.
---@class GoldwrightWindowOptions
---@field title? string window title
---@field strata? string frame strata (default "MEDIUM", the layer of the bags and the auction house; #23)
---@field movable? boolean drag with the left mouse button

--- A framed window on UIParent (ButtonFrameTemplate) without portrait or button bar, closed by
--- Escape through GW.CloseOnEscape (the game's Escape list, so in combat too). The caller places it.
---@param name string global frame name
---@param width number in pixels
---@param height number in pixels
---@param opts? GoldwrightWindowOptions
---@return table frame the new window
local windows = {} -- every UI.Window, for the Window size setting

--- The Window size setting (60–100%, goldwright-addon #23) as a frame scale.
---@return number scale 0.6 to 1
function UI.WindowScale()
  local s = tonumber(GW.Opt and GW.Opt("windowScale")) or 1
  return math.max(0.6, math.min(1, s))
end

--- Applies the Window size setting to every Goldwright window: the whole window shrinks evenly, so
--- nothing inside it moves.
function UI.ApplyWindowScale()
  local s = UI.WindowScale()
  for f in pairs(windows) do
    if f:GetScale() ~= s then f:SetScale(s) end
  end
end

function UI.Window(name, width, height, opts)
  opts = opts or {}
  local f = CreateFrame("Frame", name, UIParent, "ButtonFrameTemplate")
  f:SetSize(width, height)
  windows[f] = true
  f:SetScale(UI.WindowScale())
  f:SetClampedToScreen(true) -- stays on screen when the size setting changes
  -- The game's own layer for bags and the auction house: bags opened later come in front of a
  -- Goldwright window instead of under it, and a click brings either forward (goldwright-addon #23).
  -- Dialogs pass a higher strata.
  f:SetFrameStrata(opts.strata or "MEDIUM")
  if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(f) end
  if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(f) end
  -- A look (Skin.lua) strips the window's own textures, so it is styled before anything is drawn on it.
  UI.Skin("window", f)
  if opts.title then UI.SetTitle(f, opts.title) end
  if opts.movable then
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
  end
  f:EnableMouse(true)
  -- A click anywhere on the window brings it in front of the others on its strata (like the
  -- game's own windows); a new window opens in front.
  f:SetToplevel(true)
  f:HookScript("OnShow", function(self) self:Raise() end)
  -- The template's X hides the window itself, never through HideUIPanel (blocked in combat; see
  -- UI.NewCloseButton).
  local close = f.CloseButton or (name and _G[name .. "CloseButton"])
  if close then close:SetScript("OnClick", function() f:Hide() end) end
  GW.CloseOnEscape(f)
  -- In the game's controller mode the window joins its window list (Gamepad.lua).
  if GW.Gamepad then GW.Gamepad.Add(f) end
  return f
end

--- A framed, scrolling multi-line text box (dark background, tooltip-style border); a click anywhere
--- in the frame focuses the box. Used for text to copy or paste (shopping list import / export,
--- the bug report).
---@param parent table frame to put it in
---@param boxWidth number width of the text inside, in pixels
---@return table area the framed area (anchor it with SetPoint)
---@return table box the multi-line EditBox
function UI.TextArea(parent, boxWidth)
  local area = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  if area.SetBackdrop then
    area:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 14,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    area:SetBackdropColor(0, 0, 0, 0.6)
    area:SetBackdropBorderColor(0.6, 0.6, 0.65, 1)
  end
  local scroll = CreateFrame("ScrollFrame", nil, area, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 8, -8)
  scroll:SetPoint("BOTTOMRIGHT", -28, 8)
  UI.Skin("scrollbar", scroll.ScrollBar)
  local box = CreateFrame("EditBox", nil, scroll)
  box:SetMultiLine(true)
  box:SetFontObject("ChatFontNormal")
  box:SetWidth(boxWidth)
  box:SetAutoFocus(false)
  box:SetTextInsets(2, 2, 2, 2)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  scroll:SetScrollChild(box)
  area:EnableMouse(true)
  area:SetScript("OnMouseDown", function() box:SetFocus() end)
  return area, box
end
