--- The Level up tab of the Crafting window (docs/product/level-up-planner.md §1): the cheapest route
--- from the open profession's skill to 300 (LevelPlan.lua), as steps on the left and everything
--- still to buy on the right, with a gold total and a button that turns it into a shopping list.
---
--- The plan is worked out when the tab first opens for a profession (or on "Re-plan with today's
--- prices") and kept in GoldwrightDB.levelPlans per character and profession, so it doesn't change
--- under the player after they've bought materials. Steps already done are dimmed, the current one
--- is marked, and the have / buy column follows the bags (and bank, as far as the client knows it).
--- Recipes still to learn are greyed with where to learn them.
---
--- Read-only: only our own frames; client getters only (C_TradeSkillUI.GetRecipeInfo, GetItemCount,
--- item info, C_Map.GetAreaInfo, UnitName).
local _, GW = ...
local L = GW.L

local UI = GW.UI
local fs, setColor = UI.FontString, UI.SetColor
local GREY, WHITE = UI.GREY, UI.WHITE
local GOLD = { 1, 0.82, 0 }
local ORANGE = { 1, 0.5, 0.25 }
local GREEN = { 0.45, 0.85, 0.45 }

local STEP_ROWS, STEP_H, STEP_W = 12, 30, 420
local TICK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t" -- the game's ready-check tick (fonts may lack a tick)
--- Rank names, translated (the plan keeps the English name).
local RANK_NAMES = { Journeyman = L["Journeyman"], Expert = L["Expert"], Artisan = L["Artisan"] }
local MAT_ROWS, MAT_H = 13, 18

---@class LevelViewState
---@field plan GoldwrightLevelPlan|nil the plan shown
---@field at number|nil when it was worked out (server time)
---@field why string|nil why there is no plan
---@field line number|nil skill line shown
---@field stepOffset number scroll offset into the steps
---@field matOffset number scroll offset into the materials
---@field shopping table|nil GW.LevelPlanShopping rows
local state = { stepOffset = 0, matOffset = 0 }
local view -- the frame, built on first Show

GW.LevelView = {}

--- An item's name from the client, or "Item 1234" while it isn't cached.
---@param id number
---@return string
local function itemName(id)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
  if not name then
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    name = getInfo and getInfo(id)
  end
  return name or string.format(L["Item %s"], id)
end

--- A recipe's name and icon from the open profession window.
---@param spell number
---@return string name
---@return number|string|nil icon
local function recipeInfo(spell)
  local api = C_TradeSkillUI
  local ok, info = pcall(api and api.GetRecipeInfo, spell)
  if ok and type(info) == "table" and info.name then return info.name, info.icon end
  return string.format(L["Recipe %s"], spell), nil
end

--- Where the plans are kept: GoldwrightDB.levelPlans["Name-Realm:line"].
---@param line number
---@return string
local function planKey(line)
  local name = UnitName and UnitName("player") or "?"
  -- Stable across Forever's realm rename (build 71037 blanks the realm name, #28).
  local realm = GW.RealmKey()
  return name .. "-" .. realm .. ":" .. line
end

--- The open profession's skill line, when it's one the planner covers.
---@return number|nil
local function openLine()
  for _, id in ipairs(GW.RecipeIDs()) do
    for line, list in pairs(GW.RECIPES or {}) do
      if list[id] then return line end
    end
  end
  return nil
end

--- Works the plan out again from today's prices and keeps it.
local function replan()
  local plan, why = GW.LevelPlanNow()
  state.plan, state.why, state.stepOffset, state.matOffset = plan, why, 0, 0
  state.at = GetServerTime and GetServerTime() or nil
  if plan then
    GoldwrightDB.levelPlans = GoldwrightDB.levelPlans or {}
    GoldwrightDB.levelPlans[planKey(plan.skillLine)] = { plan = plan, at = state.at }
  end
end

--- The kept plan for the open profession, else a new one. A kept plan is used while the skill is
--- still inside it.
local function loadPlan()
  local line = openLine()
  state.line = line
  if not line then
    state.plan, state.why = nil, "no window"
    return
  end
  local kept = GoldwrightDB.levelPlans and GoldwrightDB.levelPlans[planKey(line)]
  local skill = GW.ProfessionSkill(line)
  if kept and kept.plan and skill and skill >= kept.plan.from and skill < kept.plan.to then
    state.plan, state.at, state.why = kept.plan, kept.at, nil
    return
  end
  replan()
end

--- The second line of a step: what to learn first, and anything to craft first.
---@param s GoldwrightLevelStep
---@return string text
---@return number[] color
local function stepSub(s)
  if s.kind == "rank" then
    local r = s.rank
    local text
    if r.how == "book" then
      text =
        string.format(L["Read the book %s · %s"], itemName(r.item), GW.Money(math.floor((s.cost or r.cost) + 0.5)))
    elseif r.how == "quest" then
      text = string.format(L["Quest: %s · level %d"], r.quest or "?", r.level)
    else
      text = string.format(L["At the trainer · %s"], GW.Money(s.cost or r.cost))
    end
    if s.levelShort then return text .. " · " .. string.format(L["needs level %d"], r.level), ORANGE end
    return text, GREY
  end
  local parts = {}
  if s.learn then
    if s.learn.pattern then
      local p = GW.RecipePattern and GW.RecipePattern(state.plan.skillLine, s.spell)
      local horde = UnitFactionGroup and UnitFactionGroup("player") == "Horde"
      local where
      for _, v in ipairs(p and p.vendors or {}) do
        if (horde and v.horde) or (not horde and v.alliance) then
          local zone = C_Map and C_Map.GetAreaInfo and v.zone > 0 and C_Map.GetAreaInfo(v.zone)
          where = zone and string.format(L["%s in %s"], v.name, zone) or v.name
          break
        end
      end
      local price = s.learn.cost and GW.Money(math.floor(s.learn.cost + 0.5)) or L["price unknown"]
      parts[#parts + 1] = string.format(L["Pattern · %s"], price) .. (where and (" · " .. where) or "")
    else
      parts[#parts + 1] = s.learn.cost and string.format(L["Learn at a trainer · %s"], GW.Money(s.learn.cost))
        or L["Learn at a trainer"]
    end
  end
  for _, i in ipairs(s.intermediates or {}) do
    parts[#parts + 1] = string.format(L["first craft %d× %s"], i.crafts, (recipeInfo(i.spell)))
  end
  return table.concat(parts, " · "), GREY
end

--- Draws the steps: done dimmed with a tick, the current one marked, unlearned greyed.
local function renderSteps()
  local plan = state.plan
  local skill = plan and GW.ProfessionSkill(plan.skillLine) or 0
  local steps = plan and plan.steps or {}
  for i, row in ipairs(view.steps) do
    local s = steps[i + state.stepOffset]
    row.s = s
    if not s then
      row:Hide()
    else
      row:Show()
      local done = s.kind == "craft" and skill >= s.to or (s.kind == "rank" and skill > s.from)
      local current = not done and skill >= s.from and (s.kind == "rank" or skill < s.to)
      row.range:SetText(s.kind == "rank" and tostring(s.from) or string.format("%d-%d", s.from, s.to))
      if s.kind == "rank" then
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
        row.name:SetText(string.format(L["%s rank"], (RANK_NAMES[s.rank.name] or s.rank.name)))
      else
        local name, icon = recipeInfo(s.spell)
        row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local safe = s.safe or s.crafts
        row.name:SetText(
          safe > s.crafts and string.format(L["%d× %s (%d on average)"], safe, name, s.crafts)
            or string.format("%d× %s", safe, name)
        )
      end
      local sub, subColor = stepSub(s)
      row.sub:SetText(sub)
      setColor(row.sub, subColor)
      -- Not learned yet: greyed, so it's clear it has to be learned first.
      local unlearned = s.kind == "craft" and s.learn ~= nil
      setColor(row.name, done and GREY or (unlearned and GREY or (s.kind == "rank" and GOLD or WHITE)))
      row.icon:SetDesaturated(unlearned or done)
      row:SetAlpha(done and 0.45 or 1)
      row.tick:SetShown(done)
      row.cur:SetShown(current)
    end
  end
end

--- Draws the shopping side: need / have / buy per material and the totals.
local function renderShopping()
  local plan = state.plan
  local side = GW.CraftSide()
  local function price(item) return (GW.MaterialPrice(item, side)) end
  -- Bags and bank (as far as the client knows the bank), like the Sell tab reads its counts.
  local function have(item)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(item, true) or 0 end
    return GetItemCount and GetItemCount(item, true) or 0
  end
  local list, total = {}, 0
  if plan then
    list, total = GW.LevelPlanShopping(plan, have, price)
  end
  state.shopping = list
  for i, row in ipairs(view.mats) do
    local r = list[i + state.matOffset]
    row.r = r
    if not r then
      row:Hide()
    else
      row:Show()
      local vendor = GW.VendorSellsFor and GW.VendorSellsFor(r.item)
      row.name:SetText(itemName(r.item) .. (vendor and (" (" .. L["vendor"] .. ")") or ""))
      row.counts:SetText(string.format("%d / %d", r.have, r.need))
      setColor(row.counts, r.buy == 0 and GREEN or WHITE)
      row.cost:SetText(r.buy == 0 and TICK or (r.cost and GW.Money(math.floor(r.cost + 0.5)) or L["no price"]))
    end
  end
  if not plan then
    view.total:SetText("")
    for _, v in ipairs(view.parts) do
      v:SetText("")
    end
    view.unknown:SetText("")
    return
  end
  local matCost = total - plan.training - (plan.patternCost or 0)
  view.total:SetText(string.format(L["About %s to reach %d"], GW.Money(math.floor(total + 0.5)), plan.to))
  view.parts[1]:SetText(GW.Money(math.floor(matCost + 0.5)))
  view.parts[2]:SetText(GW.Money(plan.training))
  view.parts[3]:SetText(GW.Money(math.floor((plan.patternCost or 0) + 0.5)))
  local unknown = next(plan.unknownPrices or {}) or plan.unknownTraining or plan.unknownPatterns
  view.unknown:SetText(unknown and L["Some prices are unknown; the total leaves them out."] or "")
end

--- Redraws the whole tab.
local function render()
  if not view then return end
  local plan = state.plan
  local msg
  if not plan then
    if state.why == "skill unknown" then
      msg = L["The game didn't say your skill in this profession. Close the profession window and open it again."]
    else
      msg =
        L["Level up covers Alchemy, Blacksmithing, Enchanting, Engineering, Leatherworking, Tailoring and First Aid."]
    end
  elseif plan.from >= plan.to then
    msg = string.format(L["You're at %d: nothing left to level."], plan.from)
  end
  view.message:SetText(msg or "")
  view.message:SetShown(msg ~= nil)
  view.body:SetShown(plan ~= nil and msg == nil)
  view.replan:SetShown(state.line ~= nil)
  if not plan then return end
  local skill = GW.ProfessionSkill(plan.skillLine) or plan.from
  view.title:SetText(
    string.format(L["%s: skill %d to %d"], GW.ProfessionName() or L["Crafting"], math.max(skill, plan.from), plan.to)
  )
  local note = state.at
      and string.format(L["Planned %s with the prices then; the plan stays until you re-plan."], GW.Age(state.at))
    or ""
  if plan.gap then note = note .. " " .. string.format(L["No known recipe gives points past %d."], plan.gap) end
  view.note:SetText(note)
  renderSteps()
  renderShopping()
end
GW.LevelView.Render = render

--- Turns what's left to buy into a Goldwright shopping list ("Level up: First Aid"), replacing an
--- older one of the same name. Vendor goods are left out: buy those from a vendor.
local function makeShoppingList()
  if not state.plan then return end
  local name = string.format(L["Level up: %s"], GW.ProfessionName() or L["Crafting"])
  local parts = { (name:gsub("[%^;\n]", " ")) }
  for _, r in ipairs(state.shopping or {}) do
    if r.buy > 0 and not (GW.VendorSellsFor and GW.VendorSellsFor(r.item)) then
      local max = r.unit and math.ceil(r.unit * 1.2) or nil
      parts[#parts + 1] = "item;id=" .. r.item .. (max and (";max=" .. max) or "") .. ";qty=" .. r.buy
    end
  end
  if #parts == 1 then
    GW.Print(L["You have everything to buy already."])
    return
  end
  local lists = GW.ImportLists(table.concat(parts, "^"))
  local list = lists[1]
  if not list then return end
  local all = GW.Lists()
  local at
  for i, l in ipairs(all) do
    if l.name == list.name then at = i end
  end
  at = at or (#all + 1)
  all[at] = list
  GW.ShopView.OpenList(at)
  GW.Print(string.format(L['Shopping list "%s" ready: run it at the auction house, Shopping tab.'], list.name))
end

--- Builds the tab inside `parent` (the Crafting window's inset).
---@param parent table
local function create(parent)
  view = CreateFrame("Frame", nil, parent)
  view:SetAllPoints()

  view.message = fs(view, "GameFontHighlight", "CENTER")
  view.message:SetPoint("TOP", 0, -120)
  view.message:SetWidth(520)

  view.replan = UI.Button(view, L["Re-plan with Today's Prices"], 200, 22, function()
    replan()
    render()
  end)
  view.replan:SetPoint("TOPRIGHT", -10, -8)

  local body = CreateFrame("Frame", nil, view)
  body:SetAllPoints()
  view.body = body
  view.title = fs(body, "GameFontNormalLarge", "LEFT")
  view.title:SetPoint("TOPLEFT", 10, -10)
  view.title:SetWidth(STEP_W)
  view.title:SetWordWrap(false)
  view.note = fs(body, "GameFontDisableSmall", "LEFT")
  view.note:SetPoint("TOPLEFT", 10, -32)
  view.note:SetWidth((GW.CRAFT_INNER_W or 764) - 24)
  view.note:SetWordWrap(false)

  -- steps (left)
  local list = CreateFrame("Frame", nil, body)
  list:SetPoint("TOPLEFT", 6, -50)
  list:SetSize(STEP_W, STEP_ROWS * STEP_H)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    local n = state.plan and #state.plan.steps or 0
    state.stepOffset = math.max(0, math.min(state.stepOffset - delta, math.max(0, n - STEP_ROWS)))
    renderSteps()
  end)
  view.steps = {}
  for i = 1, STEP_ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetSize(STEP_W, STEP_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * STEP_H)
    UI.Stripe(row, i)
    row.cur = row:CreateTexture(nil, "BACKGROUND")
    row.cur:SetAllPoints()
    row.cur:SetColorTexture(0.24, 0.37, 0.66, 0.35)
    row.cur:Hide()
    row.range = fs(row, "GameFontNormalSmall", "RIGHT")
    row.range:SetPoint("LEFT", 0, 0)
    row.range:SetWidth(56)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 62, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.tick = fs(row, "GameFontHighlight", "CENTER")
    row.tick:SetPoint("CENTER", row.icon, "CENTER", 0, 0)
    row.tick:SetText(TICK)
    row.name = fs(row, "GameFontHighlight", "LEFT")
    row.name:SetPoint("TOPLEFT", 90, -2)
    row.name:SetWidth(STEP_W - 94)
    row.name:SetWordWrap(false)
    row.sub = fs(row, "GameFontDisableSmall", "LEFT")
    row.sub:SetPoint("BOTTOMLEFT", 90, 2)
    row.sub:SetWidth(STEP_W - 94)
    row.sub:SetWordWrap(false)
    row:SetScript("OnEnter", function(self)
      local s = self.s
      if not s then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if s.kind == "craft" then
        local r = GW.RecipeInfo(state.plan.skillLine, s.spell)
        GameTooltip:SetText((recipeInfo(s.spell)))
        local safe = s.safe or s.crafts
        GameTooltip:AddLine(string.format(L["Skill %d to %d: about %d crafts"], s.from, s.to, s.crafts), 1, 1, 1)
        if safe > s.crafts then
          GameTooltip:AddLine(
            string.format(
              L["Yellow recipes don't give a point every time: materials for %d crafts are enough 49 times in 50. Spares sell back."],
              safe
            ),
            0.7,
            0.7,
            0.72,
            true
          )
        end
        for _, rg in ipairs(r and r.reagents or {}) do
          GameTooltip:AddDoubleLine(itemName(rg[1]), "×" .. rg[2] * safe, 1, 1, 1, 1, 1, 1)
        end
        if s.costPerCraft then
          GameTooltip:AddLine(
            string.format(L["%s per craft"], GW.Money(math.floor(s.costPerCraft + 0.5))),
            0.7,
            0.7,
            0.72
          )
        end
      else
        GameTooltip:SetText(string.format(L["%s rank"], (RANK_NAMES[s.rank.name] or s.rank.name)))
        GameTooltip:AddLine((stepSub(s)), 1, 1, 1, true)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    view.steps[i] = row
  end

  UI.Divider(body, STEP_W + 16)

  -- shopping (right)
  local x = STEP_W + 28
  local w = (GW.CRAFT_INNER_W or 764) - x - 16
  local COST_W, COUNT_W = 110, 66 -- money with coin icons needs ~110 px ("36g 44s 57c")
  UI.Header(body, string.format(L["To reach %d"], 300), x, -50)
  local cols = fs(body, "GameFontDisableSmall", "RIGHT")
  cols:SetPoint("TOPRIGHT", body, "TOPLEFT", x + w - COST_W - 4, -52)
  cols:SetText(L["have / need"])
  view.toReach = cols
  view.mats = {}
  local mats = CreateFrame("Frame", nil, body)
  mats:SetPoint("TOPLEFT", x, -70)
  mats:SetSize(w, MAT_ROWS * MAT_H)
  mats:EnableMouseWheel(true)
  mats:SetScript("OnMouseWheel", function(_, delta)
    local n = state.shopping and #state.shopping or 0
    state.matOffset = math.max(0, math.min(state.matOffset - delta, math.max(0, n - MAT_ROWS)))
    renderShopping()
  end)
  for i = 1, MAT_ROWS do
    local m = CreateFrame("Frame", nil, mats)
    m:SetSize(w, MAT_H)
    m:SetPoint("TOPLEFT", 0, -(i - 1) * MAT_H)
    m.name = fs(m, "GameFontHighlightSmall", "LEFT")
    m.name:SetPoint("LEFT", 0, 0)
    m.name:SetWidth(w - COST_W - COUNT_W - 8)
    m.name:SetWordWrap(false)
    m.counts = fs(m, "GameFontHighlightSmall", "RIGHT")
    m.counts:SetPoint("RIGHT", -(COST_W + 4), 0)
    m.counts:SetWidth(COUNT_W)
    m.cost = fs(m, "GameFontHighlightSmall", "RIGHT")
    m.cost:SetPoint("RIGHT", 0, 0)
    m.cost:SetWidth(COST_W)
    m.cost:SetWordWrap(false)
    view.mats[i] = m
  end
  -- Totals: the headline, then one row per part (label left, amount right), then a note.
  local ty = -70 - MAT_ROWS * MAT_H - 8
  view.total = fs(body, "GameFontNormal", "LEFT")
  view.total:SetPoint("TOPLEFT", x, ty)
  view.total:SetWidth(w)
  view.total:SetWordWrap(false)
  view.parts = {}
  for i, label in ipairs({ L["Materials"], L["Training and books"], L["Patterns"] }) do
    local l = fs(body, "GameFontHighlightSmall", "LEFT")
    l:SetPoint("TOPLEFT", x, ty - 6 - i * 16)
    l:SetText(label)
    setColor(l, GREY)
    local v = fs(body, "GameFontHighlightSmall", "RIGHT")
    v:SetPoint("TOPRIGHT", body, "TOPLEFT", x + w, ty - 6 - i * 16)
    v:SetWidth(COST_W)
    v:SetWordWrap(false)
    view.parts[i] = v
  end
  view.unknown = fs(body, "GameFontDisableSmall", "LEFT")
  view.unknown:SetPoint("TOPLEFT", x, ty - 6 - 4 * 16 - 2)
  view.unknown:SetWidth(w)
  view.shop = UI.Button(body, L["Make Shopping List"], 160, 22, makeShoppingList)
  view.shop:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", x, 8)

  -- The bags change while levelling: the have / buy column follows; the skill moves the steps.
  local ev = CreateFrame("Frame")
  for _, e in ipairs({ "BAG_UPDATE_DELAYED", "SKILL_LINES_CHANGED", "TRADE_SKILL_LIST_UPDATE" }) do
    pcall(ev.RegisterEvent, ev, e)
  end
  ev:SetScript("OnEvent", function()
    if view:IsShown() and state.plan then
      renderSteps()
      renderShopping()
    end
  end)
end

--- Shows the tab in `parent` and plans (or loads the kept plan) for the open profession.
---@param parent table the Crafting window's inset
function GW.LevelView.Show(parent)
  if not view then create(parent) end
  view:Show()
  loadPlan()
  -- Start the list at the current step.
  if state.plan then
    local skill = GW.ProfessionSkill(state.plan.skillLine) or state.plan.from
    for i, s in ipairs(state.plan.steps) do
      if s.kind == "craft" and skill < s.to then
        state.stepOffset = math.max(0, math.min(i - 2, #state.plan.steps - STEP_ROWS))
        break
      end
    end
  end
  render()
end

--- Hides the tab.
function GW.LevelView.Hide()
  if view then view:Hide() end
end

--- For tests: the view and its state.
function GW.LevelView.Debug() return view, state end
