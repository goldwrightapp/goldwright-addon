--- Controller support for WoW Forever's gamepad interface (the Gamepad interface style in the game's
--- settings). The game keeps a list of open windows: the D-pad cursor moves over the buttons of the
--- one it focuses, A presses the selected button, B closes the window, and the triggers (LT/RT) move
--- the focus to the window on the left or right. The game's own windows join that list by
--- themselves; an add-on's window has to announce itself, or the cursor never reaches it (it stays
--- on the auction house window while Goldwright's Sell window is open).
---
--- Every Goldwright window (UI.Window) is handed to GW.Gamepad.Add. While the gamepad style is in
--- use, an open window joins the list a frame after it shows and leaves it a frame after it hides.
--- Since build 70707 (2 Nov 2026) the game lets add-ons call FrameShown / FrameHidden and runs them
--- securely (SecureHelper:WrapFunction), but only out of combat. So every window leaves the list as
--- combat starts, and open ones join again after it: a window left in the list through a fight and
--- closed then stays in, hidden, and the controller drives an invisible window. Switching between
--- mouse and controller in game (INPUT_DEVICE_INTERFACE_TRANSITION) is followed on the next frame.
---
--- Rules (BetterBags' and Baganator's notes, Blizzard's forever branch): never write into the game's
--- binding groups or prompt footers, and never let the game click the window's CloseButton (it does
--- so tainted on purpose): B goes to SmartNavigationCloseHandler, which hides the window itself.
--- The next-frame pass runs from an OnUpdate of our own, not C_Timer (GW2_UI found a C_Timer
--- started from hooks tainted the gamepad UI). Nothing here runs with mouse and keyboard.
local _, GW = ...
local L = GW.L

---@class GoldwrightGamepad
---@field windows table[] { frame, listed } per window, in the order they were added
---@field on boolean the gamepad interface style is the one in use
---@field combat boolean between PLAYER_REGEN_DISABLED and PLAYER_REGEN_ENABLED
---@field driver? table frame whose OnUpdate runs Update once on the next frame
local Gamepad = { windows = {}, byFrame = {}, on = false, combat = false }
GW.Gamepad = Gamepad

--- Whether this client has the game's gamepad interface (WoW Forever).
---@return boolean
function Gamepad.Available()
  return GamepadMode ~= nil
    and GamepadMode.FrameControlsManager ~= nil
    and InputUtil ~= nil
    and InputUtil.IsGamepadUIEnabled ~= nil
end

--- Whether the game refuses an add-on's calls to its gamepad interface right now (combat).
---@return boolean
local function restricted()
  if C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive and Enum and Enum.AddOnRestrictionType then
    if C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Combat) then return true end
  end
  return InCombatLockdown() and true or false
end

--- Runs Update on the next frame.
function Gamepad.Schedule()
  if Gamepad.driver then Gamepad.driver:Show() end
end

--- Takes a Goldwright window into the controller support: while the gamepad style is in use and it
--- is open (out of combat), it is in the game's window list.
---@param frame table the window (UI.Window)
---@return string what "added", "already" or "unavailable"
function Gamepad.Add(frame)
  if not Gamepad.Available() then return "unavailable" end
  if Gamepad.byFrame[frame] then return "already" end
  local rec = { frame = frame, listed = false }
  table.insert(Gamepad.windows, rec)
  Gamepad.byFrame[frame] = rec
  frame:HookScript("OnShow", Gamepad.Schedule)
  frame:HookScript("OnHide", Gamepad.Schedule)
  -- B on the window: undo a number being changed (Gamepad.Adjustable), else hide the window
  -- ourselves, so the game never clicks our CloseButton (tainted).
  frame.SmartNavigationCloseHandler = function()
    if Gamepad.editing then
      Gamepad.EndEdit(true)
    elseif not (frame.goBack and frame.goBack()) then -- a window with pages goes back one page first
      frame:Hide()
    end
    return true
  end
  -- The triggers moved the controller to another window: a number being changed is kept.
  frame.UnfocusGamepad = function() Gamepad.EndEdit(false) end
  Gamepad.Schedule()
  return "added"
end

--- Brings the game's window list in line with what is open: each open window in it, each hidden
--- one out. In combat nothing changes (the windows already left: LeaveForCombat) and the pass runs
--- again when combat ends. Returns how many Goldwright windows are in the list.
---@return number listed
function Gamepad.Update()
  local manager = GamepadMode.FrameControlsManager
  local blocked = Gamepad.combat or restricted()
  local listed = 0
  for _, rec in ipairs(Gamepad.windows) do
    local want = Gamepad.on and rec.frame:IsShown()
    if want and not rec.listed and not blocked then
      rec.listed = true
      manager:FrameShown(rec.frame)
    elseif not want and rec.listed and not blocked then
      rec.listed = false
      manager:FrameHidden(rec.frame)
    end
    if rec.listed then listed = listed + 1 end
  end
  if Gamepad.SyncTabKeys then Gamepad.SyncTabKeys() end -- LB / RB follow the open windows
  if not blocked and Gamepad.ApplyWaitingSteppable then Gamepad.ApplyWaitingSteppable() end
  return listed
end

--- Takes every window out of the game's list and its cursor before the combat restriction comes
--- (ADDON_RESTRICTION_STATE_CHANGED Activating, or PLAYER_REGEN_DISABLED if that comes first);
--- under the restriction the game refuses to take one out. Returns how many left.
---@return number left
function Gamepad.LeaveForCombat()
  if Gamepad.ReleaseTabKeys then Gamepad.ReleaseTabKeys() end
  if not Gamepad.on then return 0 end
  local manager = GamepadMode.FrameControlsManager
  local left = 0
  for _, rec in ipairs(Gamepad.windows) do
    if rec.listed then
      rec.listed = false
      manager:FrameHidden(rec.frame)
      left = left + 1
      if SmartNavigation and SmartNavigation.RemovePanelInfo then SmartNavigation:RemovePanelInfo(rec.frame) end
    end
  end
  return left
end

---------------------------------------------------------------------------
-- Changing a number with the controller
---------------------------------------------------------------------------
-- The game has no on-screen keyboard, and A on a text box doesn't change it. Blizzard's own
-- windows change a value with left / right on the selected control (stack split, sliders);
-- Improved Forever's auction screen does the same, held = faster. Here: A on an adjustable box
-- starts changing it, left / right step it (held: faster), A again keeps the value, B puts the old
-- one back. While a box is being changed the D-pad's four directions are bound to buttons of ours
-- (SetOverrideBindingClick on our own frame, never Blizzard's binding groups) and released the
-- moment it ends: A or B, the window losing the controller (LT / RT) or hiding, combat, or a switch
-- to the mouse. A goes through Blizzard's own click (the box's OnSmartNavClick), so A is never ours.

--- Repeats while left / right is held: the first after HOLD_DELAY seconds, then every
--- REPEAT_EVERY; after STEP_UP repeats the step is 10 times bigger, after STEP_UP2 100 times.
local HOLD_DELAY, REPEAT_EVERY, STEP_UP, STEP_UP2 = 0.35, 0.08, 8, 24

local bindOwner -- frame the D-pad bindings belong to (cleared all at once)
local held -- { dir, elapsed, repeats } while left or right is down

--- One step of the box being changed, `dir` -1 or 1, times `mult`, kept within its bounds.
local function step(dir, mult)
  local e = Gamepad.editing
  if not e then return end
  local spec = e.spec
  local lo = spec.min and spec.min() or 0
  local hi = spec.max and spec.max() or math.huge
  local n = (spec.get() or 0) + dir * spec.step * (mult or 1)
  if n < lo then n = lo end
  if n > hi then n = hi end
  if n ~= spec.get() then spec.set(n) end
end

--- The buttons the D-pad is bound to while a box is being changed.
local function padButton(name, dir)
  local b = CreateFrame("Button", name, UIParent)
  b:RegisterForClicks("AnyDown", "AnyUp")
  b:SetScript("OnClick", function(_, _, down)
    if not dir then return end -- up / down: swallowed, the cursor stays on the box
    if down then
      held = { dir = dir, elapsed = 0, repeats = 0 }
      step(dir, 1)
    else
      held = nil
    end
  end)
  return b
end

local function ensureButtons()
  if bindOwner then return end
  bindOwner = CreateFrame("Frame")
  padButton("GoldwrightPadLess", -1)
  padButton("GoldwrightPadMore", 1)
  padButton("GoldwrightPadStay", nil)
  local ticker = CreateFrame("Frame", nil, bindOwner)
  ticker:SetScript("OnUpdate", function(_, elapsed)
    if not held then return end
    held.elapsed = held.elapsed + elapsed
    local wait = held.repeats == 0 and HOLD_DELAY or REPEAT_EVERY
    if held.elapsed < wait then return end
    held.elapsed = 0
    held.repeats = held.repeats + 1
    step(held.dir, held.repeats > STEP_UP2 and 100 or held.repeats > STEP_UP and 10 or 1)
  end)
end

--- Shows how to change the box (a tooltip on it) and lights it.
local function showEditing(box, on)
  if not box.gwEditGlow then
    local t = box:CreateTexture(nil, "OVERLAY")
    t:SetPoint("TOPLEFT", -4, 2)
    t:SetPoint("BOTTOMRIGHT", 2, -2)
    t:SetColorTexture(GW.GOLD[1], GW.GOLD[2], GW.GOLD[3], 0.22)
    box.gwEditGlow = t
  end
  box.gwEditGlow:SetShown(on)
  if on then
    GameTooltip:SetOwner(box, "ANCHOR_TOP")
    GameTooltip:SetText(L["Left / right: change it (hold for faster)"], 1, 1, 1)
    GameTooltip:AddLine(L["A: done · B: undo"], 0.8, 0.8, 0.8)
    GameTooltip:Show()
  elseif GameTooltip:GetOwner() == box then
    GameTooltip:Hide()
  end
end

--- Starts changing `box` with the controller (A on it).
---@param box table
---@return boolean started
function Gamepad.StartEdit(box)
  local spec = box.gwAdjust
  if not spec or not Gamepad.on or Gamepad.combat or InCombatLockdown() then return false end
  if spec.enabled and not spec.enabled() then return false end
  Gamepad.EndEdit(false)
  ensureButtons()
  Gamepad.editing = { box = box, spec = spec, before = spec.get() }
  SetOverrideBindingClick(bindOwner, true, "PADDLEFT", "GoldwrightPadLess", "LeftButton")
  SetOverrideBindingClick(bindOwner, true, "PADDRIGHT", "GoldwrightPadMore", "LeftButton")
  SetOverrideBindingClick(bindOwner, true, "PADDUP", "GoldwrightPadStay", "LeftButton")
  SetOverrideBindingClick(bindOwner, true, "PADDDOWN", "GoldwrightPadStay", "LeftButton")
  if spec.show then
    spec.show(true)
  else
    showEditing(box, true)
  end
  return true
end

--- Stops changing the box: keeps the value, or with `undo` puts the one from before back. The
--- D-pad goes back to the game's cursor. Does nothing when no box is being changed.
---@param undo? boolean
function Gamepad.EndEdit(undo)
  local e = Gamepad.editing
  if not e then return end
  Gamepad.editing = nil
  held = nil
  if bindOwner and not InCombatLockdown() then ClearOverrideBindings(bindOwner) end
  if e.spec.show then
    e.spec.show(false)
  else
    showEditing(e.box, false)
  end
  if undo and e.spec.get() ~= e.before then e.spec.set(e.before) end
end

--- Lets the controller change a number box: A starts and ends changing it, left / right step it.
--- With mouse and keyboard the box is typed into as before.
---@param box table EditBox
--- `spec.show(on)`, when given, replaces the hint tooltip and glow while the box is being changed
--- (the Sell chart shows its own tooltip for the selected day or hour).
---@param spec { get: fun(): number, set: fun(n: number), step: number, min?: fun(): number, max?: fun(): number, enabled?: fun(): boolean, show?: fun(on: boolean) }
---@return table box
function Gamepad.Adjustable(box, spec)
  if not Gamepad.Available() then return box end
  box.gwAdjust = spec
  box.OnSmartNavClick = function(self)
    if Gamepad.editing and Gamepad.editing.box == self then
      Gamepad.EndEdit(false)
    else
      Gamepad.StartEdit(self)
    end
  end
  box:HookScript("OnHide", function(self)
    if Gamepad.editing and Gamepad.editing.box == self then Gamepad.EndEdit(false) end
  end)
  return box
end

---------------------------------------------------------------------------
-- Scrolling a list with the D-pad
---------------------------------------------------------------------------
-- Goldwright's lists make only the rows that fit and scroll by changing what those rows show (the
-- mouse wheel). The game's cursor only moves between buttons it can see, so down on the last row
-- went nowhere (#57). A real scroll area wouldn't help: the game skips its buttons outside the
-- visible part too (SmartNavigationMixin:IsButtonValid) and scrolls one only with the right stick.
-- So each row's buttons get up / down overrides, as the charts get left / right: down on the last
-- shown row scrolls the list one step and the cursor goes to the same button of the new last shown
-- row. At the end of the list the override returns nothing, and the game moves the cursor on as
-- usual (out of the list). Up on the first shown row the same way upwards.

local lists = {} -- { list, rows: fun(): table[], offset: fun(): number, applied: boolean }

--- The first and last shown rows.
local function shownRange(rows)
  local first, last
  for i, row in ipairs(rows) do
    if row:IsShown() then
      first = first or i
      last = i
    end
  end
  return first, last
end

--- The row `b` is, or is in, and the key `b` has in that row (a button inside a row frame).
local function rowOf(rows, b)
  for i, row in ipairs(rows) do
    if row == b then return i end
    for k, v in pairs(row) do
      if v == b then return i, k end
    end
  end
end

--- Up / down from `b`: nil to let the game move the cursor as usual, or where it goes after the
--- list scrolled one step (`b` itself: true, it stays).
local function edgeStep(rec, b, dir)
  local rows = rec.rows()
  local i, key = rowOf(rows, b)
  if not i then return nil end
  local first, last = shownRange(rows)
  if i ~= (dir > 0 and last or first) then return nil end
  local wheel = rec.list:GetScript("OnMouseWheel")
  local before = rec.offset()
  if wheel then wheel(rec.list, -dir) end
  if rec.offset() == before then return nil end -- the end of the list: leave it as usual
  first, last = shownRange(rows)
  local row = rows[dir > 0 and last or first]
  local target = row and (key and row[key] or row)
  if not target or target == b then return true end
  -- The list just moved its rows (sorted by Category the next item can sit in another row). The
  -- game skips a button whose position isn't worked out yet (IsRectValid) and the cursor would stay
  -- behind: asking for the position works it out now.
  if target.GetRect then target:GetRect() end
  if target.IsRectValid and not target:IsRectValid() then return true end
  return target
end

--- The buttons in a frame, itself included (the cursor stops on buttons).
local function buttonsOf(frame, out)
  if frame:IsObjectType("Button") then out[#out + 1] = frame end
  for _, child in ipairs({ frame:GetChildren() }) do
    buttonsOf(child, out)
  end
  return out
end

--- Sets the up / down overrides on a list's row buttons. Returns whether the game took them.
local function applyList(rec)
  local dirs = SMART_NAV_INPUT_DIRECTION
  if not (dirs and SmartNavigation_AddJumpNavigationOverride) then return true end
  if restricted() then return false end
  local rows = rec.rows()
  if not rows or #rows == 0 then return false end -- not built yet
  for _, row in ipairs(rows) do
    for _, b in ipairs(buttonsOf(row, {})) do
      for _, d in ipairs({ { dirs.DOWN, 1 }, { dirs.UP, -1 } }) do
        local ok = pcall(SmartNavigation_AddJumpNavigationOverride, b, d[1], function()
          local fine, where = pcall(edgeStep, rec, b, d[2])
          if fine then return where end
        end)
        if not ok then return false end
      end
    end
  end
  return true
end

--- Lets the D-pad scroll a list (#57): `list` is the frame whose OnMouseWheel scrolls it, `rows`
--- returns its rows top to bottom, `offset` how far it is scrolled. The overrides are set on the
--- next Update out of combat (the rows may not be made yet).
---@param list table
---@param rows fun(): table[]
---@param offset fun(): number
function Gamepad.ScrollList(list, rows, offset)
  if not Gamepad.Available() then return end
  lists[#lists + 1] = { list = list, rows = rows, offset = offset }
  Gamepad.Schedule()
end

---------------------------------------------------------------------------
-- Stepping along a chart
---------------------------------------------------------------------------
-- A chart is one control with many points (#19). While the game's cursor is on it, left / right
-- step from point to point and the cursor stays on the chart; up / down leave it as on any control.
-- This uses the game's own per-control direction overrides (SmartNavigation_AddJumpNavigationOverride
-- with a function that returns true: "stay here"), which Blizzard lets add-ons set without taint out
-- of combat, on our own frame only. A acts like a click on the point. Charts made in combat get their
-- overrides on the next Update out of combat.

local waitingSteppable = {} -- { frame, spec } made while the game refused (combat)

--- Sets a chart's left / right overrides. Returns whether the game took them.
local function applySteppable(frame, spec)
  local dirs = SMART_NAV_INPUT_DIRECTION
  if not (dirs and SmartNavigation_AddJumpNavigationOverride) then return true end -- nothing to set
  if restricted() then return false end
  for _, d in ipairs({ { dirs.LEFT, -1 }, { dirs.RIGHT, 1 } }) do
    local ok = pcall(SmartNavigation_AddJumpNavigationOverride, frame, d[1], function()
      spec.step(d[2])
      return true -- the cursor stays on the chart
    end)
    if not ok then return false end
  end
  return true
end

--- Lets the controller step along a chart: while the game's cursor is on `frame`, left / right call
--- spec.step(-1 / 1), selecting it calls spec.show(true), leaving it spec.show(false), A spec.click().
---@param frame table the chart's frame the cursor selects (a Button)
---@param spec { step: fun(dir: number), show: fun(on: boolean), click?: fun() }
---@return table frame
function Gamepad.Steppable(frame, spec)
  if not Gamepad.Available() then return frame end
  frame.OnSmartNavSelect = function() spec.show(true) end
  frame.OnSmartNavDeselect = function() spec.show(false) end
  frame.OnSmartNavClick = function()
    if spec.click then spec.click() end
  end
  if not applySteppable(frame, spec) then waitingSteppable[#waitingSteppable + 1] = { frame = frame, spec = spec } end
  return frame
end

--- Gives the charts made in combat their left / right, and the lists their up / down (#57), from
--- Update, out of combat.
function Gamepad.ApplyWaitingSteppable()
  for i = #waitingSteppable, 1, -1 do
    local w = waitingSteppable[i]
    if applySteppable(w.frame, w.spec) then table.remove(waitingSteppable, i) end
  end
  for _, rec in ipairs(lists) do
    if not rec.applied then rec.applied = applyList(rec) end
  end
end

---------------------------------------------------------------------------
-- Tabs on the shoulder buttons
---------------------------------------------------------------------------
-- LB / RB switch a window's tabs, like the game's own tabbed windows: while a window with tabs is
-- open in the gamepad style (out of combat), PADLSHOULDER / PADRSHOULDER are bound to two hidden
-- buttons of ours (SetOverrideBindingClick on our own frame, as for the number boxes above). The
-- bindings go as the window closes, as combat starts, or on a switch to the mouse.

local tabOwner -- frame the LB / RB bindings belong to
local tabRec -- the window record they act on

--- The buttons LB and RB are bound to: step the bound window's tabs left or right.
local function ensureTabButtons()
  if tabOwner then return end
  tabOwner = CreateFrame("Frame")
  for name, dir in pairs({ GoldwrightPadPrevTab = -1, GoldwrightPadNextTab = 1 }) do
    local b = CreateFrame("Button", name, UIParent)
    b:SetScript("OnClick", function()
      if tabRec and tabRec.frame:IsShown() then tabRec.tabs(dir) end
    end)
  end
end

--- Binds LB / RB to the first open window with tabs, or releases them. Out of combat only.
local function syncTabKeys()
  if not tabOwner or Gamepad.combat or restricted() then return end
  local want
  for _, rec in ipairs(Gamepad.windows) do
    if rec.tabs and rec.listed then want = rec end
  end
  if want == tabRec then return end
  ClearOverrideBindings(tabOwner)
  tabRec = want
  if want then
    SetOverrideBindingClick(tabOwner, true, "PADLSHOULDER", "GoldwrightPadPrevTab", "LeftButton")
    SetOverrideBindingClick(tabOwner, true, "PADRSHOULDER", "GoldwrightPadNextTab", "LeftButton")
  end
end

Gamepad.SyncTabKeys = syncTabKeys

--- Lets LB / RB switch a window's tabs while it is open with the controller.
---@param frame table a window already added (UI.Window)
---@param step fun(dir: number) shows the tab to the left (-1) or right (1)
function Gamepad.Tabs(frame, step)
  local rec = Gamepad.byFrame[frame]
  if not rec then return end
  rec.tabs = step
  ensureTabButtons()
  Gamepad.Schedule()
end

--- Releases LB / RB now (before combat or on a switch to the mouse).
function Gamepad.ReleaseTabKeys()
  if tabOwner and tabRec and not InCombatLockdown() then
    ClearOverrideBindings(tabOwner)
    tabRec = nil
  end
end

--- What the controller support knows, one line (for /gw gamepad).
---@return string
function Gamepad.Status()
  if not Gamepad.Available() then return "Gamepad: not on this client." end
  local mine = {}
  for _, rec in ipairs(Gamepad.windows) do
    if rec.frame:IsShown() then
      table.insert(mine, (rec.frame:GetName() or "?") .. (rec.listed and " (in list)" or " (not in list)"))
    end
  end
  local shown = {}
  local manager = GamepadMode.FrameControlsManager
  for _, f in ipairs(manager.shownFrames or {}) do
    table.insert(shown, type(f) == "table" and f.GetName and f:GetName() or "?")
  end
  return string.format(
    "Gamepad: style %s, combat %s. Goldwright windows open: %s. Game's window list: %s.",
    Gamepad.on and "controller" or "mouse",
    (Gamepad.combat or restricted()) and "yes" or "no",
    #mine > 0 and table.concat(mine, ", ") or "none",
    #shown > 0 and table.concat(shown, ", ") or "empty"
  )
end

if Gamepad.Available() then
  Gamepad.on = InputUtil.IsGamepadUIEnabled() and true or false

  local driver = CreateFrame("Frame")
  driver:Hide()
  driver:SetScript("OnUpdate", function(self)
    self:Hide()
    Gamepad.Update()
  end)
  Gamepad.driver = driver

  local ev = CreateFrame("Frame")
  for _, e in ipairs({
    "INPUT_DEVICE_INTERFACE_TRANSITION",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "ADDON_RESTRICTION_STATE_CHANGED",
    "PLAYER_ENTERING_WORLD",
  }) do
    pcall(ev.RegisterEvent, ev, e)
  end
  ev:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "PLAYER_ENTERING_WORLD" then
      Gamepad.on = InputUtil.IsGamepadUIEnabled() and true or false
      Gamepad.Schedule()
    elseif event == "PLAYER_REGEN_DISABLED" then
      Gamepad.combat = true
      Gamepad.EndEdit(false) -- bindings can't change in combat: give the D-pad back first
      Gamepad.LeaveForCombat()
    elseif event == "PLAYER_REGEN_ENABLED" then
      Gamepad.combat = false
      Gamepad.Schedule()
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
      local E = Enum or {}
      local combatType = E.AddOnRestrictionType and E.AddOnRestrictionType.Combat
      local activating = E.AddOnRestrictionState and E.AddOnRestrictionState.Activating
      if combatType ~= nil and a1 == combatType and a2 == activating then
        Gamepad.EndEdit(false)
        Gamepad.LeaveForCombat()
      else
        Gamepad.Schedule()
      end
    elseif event == "INPUT_DEVICE_INTERFACE_TRANSITION" then
      Gamepad.EndEdit(false)
      local types = Enum and Enum.InputDeviceInterfaceType
      if types and types.Gamepad ~= nil then
        Gamepad.on = a1 == types.Gamepad
      else
        Gamepad.on = InputUtil.IsGamepadUIEnabled() and true or false
      end
      -- Leaving the gamepad style, the game forgets its window list itself.
      if not Gamepad.on then
        for _, rec in ipairs(Gamepad.windows) do
          rec.listed = false
        end
      end
      Gamepad.Schedule()
      if GW.ShopView then GW.ShopView.Refresh() end -- its list tools are dimmed for the mouse only
    end
  end)
end
