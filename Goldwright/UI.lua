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
---@field strata? string frame strata (default "HIGH")
---@field movable? boolean drag with the left mouse button

--- A framed window on UIParent (ButtonFrameTemplate) without portrait or button bar, closed by
--- Escape through GW.CloseOnEscape (the game's Escape list, so in combat too). The caller places it.
---@param name string global frame name
---@param width number in pixels
---@param height number in pixels
---@param opts? GoldwrightWindowOptions
---@return table frame the new window
function UI.Window(name, width, height, opts)
  opts = opts or {}
  local f = CreateFrame("Frame", name, UIParent, "ButtonFrameTemplate")
  f:SetSize(width, height)
  f:SetFrameStrata(opts.strata or "HIGH")
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
