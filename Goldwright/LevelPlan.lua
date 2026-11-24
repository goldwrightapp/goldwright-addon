-- Level up planner: the cheapest route to take a crafting profession from the current skill to 300
-- (docs/product/level-up-planner.md §3). GW.LevelPlan is a pure calculation over the recipe table
-- (RecipeData.lua) and the prices it is given; GW.LevelPlanNow fills those in from the game for
-- the open profession window. The plan is worked out once and kept: the Level up tab shows it,
-- and only the "have / buy" column follows the bags (GW.LevelPlanShopping).
local _, GW = ...

--- Profession ranks: train at `skill` (and character `level`) to raise the cap from `cap` to the next.
--- `how`: "trainer" (default), "book" (an item to buy and use: `item`, `cost` = its vendor price; the
--- auction house is used when cheaper) or "quest" (free, `quest` names it).
GW.PROFESSION_RANKS = {
  { name = "Journeyman", cap = 75, skill = 50, level = 10, cost = 500 },
  { name = "Expert", cap = 150, skill = 125, level = 20, cost = 5000 },
  { name = "Artisan", cap = 225, skill = 200, level = 35, cost = 50000 },
}

--- Professions whose ranks work differently, by base skill line. First Aid on Forever
--- (wow-professions.com, 2026-11-14): Journeyman from any trainer at 50 for 5s, no level; Expert
--- from the book "Expert First Aid - Under Wraps" at 125 (1g from Deneb Walker in Arathi Highlands
--- or Balai Lok'Wein in Dustwallow Marsh); Artisan from the quest Triage at 225 and level 35.
GW.PROFESSION_RANKS_BY_LINE = {
  [129] = {
    { name = "Journeyman", cap = 75, skill = 50, level = 0, cost = 500 },
    { name = "Expert", cap = 150, skill = 125, level = 0, cost = 10000, how = "book", item = 16084 },
    { name = "Artisan", cap = 225, skill = 225, level = 35, cost = 0, how = "quest", quest = "Triage" },
  },
}

local MAX_DEPTH = 3 -- how deep intermediates are crafted (Light Leather -> Cured Light Hide -> ...)
-- Yellow recipes don't give a point every time, so the average count runs short about half the
-- time (2026-11-16: a player following a guide kept walking back across Stormwind for more).
-- Counts are planned to be enough 49 times in 50: average + 2.054 spreads (normal approximation).
local SAFE_Z = 2.054

--- Chance that one craft at `skill` gives a skill point: orange (below yellow) always; yellow to
--- grey falls in a straight line; grey never (classic rule, to confirm in game).
---@param r table recipe from GW.RecipeInfo
---@param skill number
---@return number chance 0..1
function GW.SkillUpChance(r, skill)
  if skill >= r.grey then return 0 end
  if skill < r.yellow or r.grey <= r.yellow then return 1 end
  return (r.grey - skill) / (r.grey - r.yellow)
end

--- The plan.
---@class GoldwrightLevelStep
---@field kind string "craft" or "rank"
---@field spell number|nil recipe (craft steps)
---@field from number skill at the start
---@field to number skill at the end
---@field crafts number|nil how many to craft on average (rounded up)
---@field safe number|nil how many to be ready for: enough 49 times in 50 (plans from before 2026-11-16 lack it)
---@field learn table|nil { skill, cost, pattern } when the recipe has to be learned first: at a trainer
---  (cost nil = unknown), or from a recipe item (pattern = true; only where no trainer recipe gives points)
---@field costPerCraft number|nil materials per craft at plan time (nil = a price is missing)
---@field intermediates table|nil { {spell, crafts}, ... } to craft first for this step
---@field rank table|nil GW.PROFESSION_RANKS entry (rank steps)
---@field levelShort boolean|nil the character's level is below the rank's

---@class GoldwrightLevelPlan
---@field skillLine number
---@field from number
---@field to number
---@field steps GoldwrightLevelStep[]
---@field materials table<number, number> item id -> count to buy in all (base materials), enough 49 times in 50
---@field averageMaterials table<number, number>|nil item id -> count needed on average
---@field training number copper for recipes and ranks (known prices)
---@field unknownTraining boolean a recipe's trainer price is unknown
---@field unknownPrices table<number, boolean> materials without a price
---@field patterns number[] recipes the plan learns from a recipe item (pattern, plans ...), in order
---@field patternCost number copper for those patterns (known prices)
---@field unknownPatterns boolean a pattern's price is unknown
---@field gap number|nil skill at which no recipe gives points any more (plan stops there)

--- Works out the route.
---@param o table { skillLine, skill, target (default 300), known = {[spell]=true}, price = fn(item) -> copper|nil,
---   specializations = {[spell]=true}, level = character level,
---   maxSkill = the current cap (default: from the ranks), spells = list (default GW.RecipeSpells),
---   patternPrice = fn(spell, recipe) -> copper|nil (what the recipe item teaching it costs),
---   have = fn(item) -> count already owned (free to the plan until used up; default none) }
---@return GoldwrightLevelPlan plan
function GW.LevelPlan(o)
  local line, target = o.skillLine, o.target or 300
  local known, specs = o.known or {}, o.specializations or {}
  local price = o.price or function() return nil end
  -- What you already have (bags and bank) counts as free until the plan has used it up, so a recipe
  -- whose materials you own wins while they last (2026-11-16: 13 Wool Cloth in the bags while the
  -- plan sent the player to buy herbs). Read once per item, when the plan first looks at it.
  local owned, stock = {}, {} -- item -> count at the start / still unused
  local function left(item)
    if owned[item] == nil then
      owned[item] = o.have and o.have(item) or 0
      stock[item] = owned[item]
    end
    return stock[item]
  end
  local recipes, makers = {}, {}
  for _, spell in ipairs(o.spells or GW.RecipeSpells(line)) do
    local r = GW.RecipeInfo(line, spell)
    if r then
      recipes[#recipes + 1] = r
      if r.item and r.item > 0 then
        makers[r.item] = makers[r.item] or {}
        table.insert(makers[r.item], r)
      end
    end
  end
  local learned = {} -- learned on the way (trainer recipes and patterns the plan picks)
  -- What the pattern (recipe item) for a recipe costs: vendor or auction house (nil = unknown).
  local patternPrices = {}
  local function patternCost(r)
    if r.trainer or not o.patternPrice then return nil end
    if patternPrices[r.spell] == nil then patternPrices[r.spell] = o.patternPrice(r.spell, r) or false end
    return patternPrices[r.spell] or nil
  end
  -- What learning a recipe costs: trainer price or pattern price (nil = unknown).
  local function learnCost(r)
    if r.trainer then return r.cost end
    return patternCost(r)
  end
  -- Recipes taught by a recipe item (pattern, plans ...) count like trainer recipes when the pattern
  -- has a price (a vendor sells it or it's on the auction house; for a recipe no source lists, that
  -- price is what shows it can be had). Without a price they're a last resort (`fallback`), used
  -- only where nothing else gives points or has prices (Leatherworking past 250).
  local function available(r, skill, fallback)
    if known[r.spell] or learned[r.spell] then return true end
    if not r.learn or r.learn > skill then return false end
    if r.trainer then return not r.unknown and (not r.specialization or specs[r.specialization] == true) end
    if patternCost(r) then return true end
    return fallback == true and not r.unknown
  end

  -- Cost of one unit of an item at a skill: buying it, or crafting it when that's cheaper (or the
  -- only way). Returns cost (nil = unknown) and the recipe to craft it with (nil = buy).
  local memo
  local function unitCost(item, skill, depth, seen)
    local key = item
    if memo[key] ~= nil then return memo[key][1], memo[key][2] end
    local best, via = price(item), nil
    if left(item) >= 1 then best = 0 end -- yours already: free, and nothing to craft
    if best ~= 0 and depth < MAX_DEPTH then
      for _, m in ipairs(makers[item] or {}) do
        if available(m, skill) and not seen[m.spell] then
          seen[m.spell] = true
          local total = 0
          for _, rg in ipairs(m.reagents) do
            local c = unitCost(rg[1], skill, depth + 1, seen)
            if not c then
              total = nil
              break
            end
            total = total + c * rg[2]
          end
          seen[m.spell] = nil
          if total then
            total = total / (m.makes or 1)
            if not best or total < best then
              best, via = total, m
            end
          end
        end
      end
    end
    memo[key] = { best or false, via }
    return best, via
  end
  -- `perPoint`: crafts this point takes on average. What you own is free only while it covers the
  -- whole point, so the plan never counts on more of it than you have.
  local function craftCost(r, skill, perPoint)
    local total = 0
    for _, rg in ipairs(r.reagents) do
      local c = unitCost(rg[1], skill, 1, { [r.spell] = true })
      if c == 0 and perPoint and left(rg[1]) < rg[2] * perPoint then c = price(rg[1]) end
      if not c then return nil end
      total = total + c * rg[2]
    end
    return total
  end
  -- The base materials behind `count` of an item (crafting the parts that are cheaper to craft),
  -- added into `into`.
  local function expand(item, count, skill, depth, into)
    memo = {}
    local _, via = unitCost(item, skill, depth, {})
    if via then
      local crafts = math.ceil(count / (via.makes or 1))
      for _, rg in ipairs(via.reagents) do
        expand(rg[1], rg[2] * crafts, skill, depth + 1, into)
      end
      return via, crafts
    end
    into[item] = (into[item] or 0) + count
  end
  local function use(mats)
    for item, n in pairs(mats) do
      stock[item] = left(item) - n
    end
  end

  -- Greedy, one skill point at a time: the recipe with the lowest expected cost per point, counting
  -- what you spend (materials and training) only. Selling what you make isn't counted: until
  -- 2026-11-16 it was, and recipes that make several at a time looked nearly free, so the plan
  -- made 1,017 Anti-Venom (and hundreds of nearly grey bandages) to sell into markets that can't
  -- take them; First Aid 5 to 300 cost about 25g up front instead of 16g.
  local picks = {}
  local skill = o.skill
  local gap
  while skill < target do
    memo = {}
    local best, bestCost, bestChance, bestKnown, bestGreen, byPattern
    for pass = 1, 2 do
      for _, r in ipairs(recipes) do
        local chance = available(r, skill, pass == 2) and GW.SkillUpChance(r, skill) or 0
        if chance > 0 then
          local cost = craftCost(r, skill, 1 / (chance * (r.skillUps or 1)))
          local per
          if cost then
            per = cost / (chance * (r.skillUps or 1))
            if not (known[r.spell] or learned[r.spell]) then
              -- Training cost spread over the points this recipe can still give.
              per = per + (learnCost(r) or 0) / math.max(1, math.min(r.grey, target) - skill)
            end
          end
          local green = r.green ~= nil and skill >= r.green
          local better
          if not best then
            better = true
          elseif (per ~= nil) ~= bestKnown then
            better = per ~= nil -- a recipe with known prices beats one without
          elseif green ~= bestGreen then
            better = not green -- green only when nothing orange or yellow is left
          elseif per and per ~= bestCost then
            better = per < bestCost
          elseif chance ~= bestChance then
            better = chance > bestChance
          else
            better = r.spell < best.spell
          end
          if better then
            best, bestCost, bestChance, bestKnown, bestGreen = r, per, chance, per ~= nil, green
          end
        end
      end
      -- Patterns are looked at only when no trainer or known recipe gives points, or none of those
      -- has a known price (pass 2 sees them all again, so a priced pattern beats them).
      if best and (bestKnown or pass == 2) then
        byPattern = pass == 2 and not best.trainer and not known[best.spell] and not learned[best.spell]
        break
      end
    end
    if not best then
      gap = skill
      break
    end
    if not known[best.spell] then learned[best.spell] = true end
    local p = bestChance * (best.skillUps or 1)
    -- Crafts until the point comes: 1/p on average, with spread (1-p)/p^2 (a geometric count).
    picks[#picks + 1] =
      { r = best, skill = skill, crafts = 1 / p, spread = math.max(0, 1 - p) / (p * p), pattern = byPattern }
    if o.have then
      local mats = {}
      for _, rg in ipairs(best.reagents) do
        expand(rg[1], rg[2] / p, skill, 1, mats)
      end
      use(mats)
    end
    skill = skill + 1
  end
  -- The steps below use what you have again from the start, in the same order.
  for item, n in pairs(owned) do
    stock[item] = n
  end

  -- Merge the points into steps, add rank training, and add up the materials.
  local plan = {
    skillLine = line,
    from = o.skill,
    to = gap or target,
    gap = gap,
    steps = {},
    materials = {},
    training = 0,
    unknownTraining = false,
    unknownPrices = {},
    patterns = {},
    patternCost = 0,
    unknownPatterns = false,
  }
  local maxSkill = o.maxSkill
  local ranks = GW.PROFESSION_RANKS_BY_LINE[line] or GW.PROFESSION_RANKS
  local function rankAt(s)
    for _, rank in ipairs(ranks) do
      if s == rank.cap and (not maxSkill or maxSkill <= rank.cap) then return rank end
    end
  end
  -- Per material, the average count and its spread, added up over the steps that use it.
  -- `exact`: the same average before steps round their crafts up.
  local average, exact, spread, stepMats = {}, {}, {}, {}
  local taught = {}
  local i = 1
  while i <= #picks do
    local p = picks[i]
    local rank = rankAt(p.skill)
    if rank then
      -- A rank book costs the cheaper of its vendor price and the auction house.
      local cost = rank.cost
      if rank.how == "book" and rank.item then
        local ah = price(rank.item)
        if ah and ah < cost then cost = ah end
      end
      plan.steps[#plan.steps + 1] = {
        kind = "rank",
        rank = rank,
        cost = cost,
        from = p.skill,
        to = p.skill,
        levelShort = o.level ~= nil and o.level < rank.level or nil,
      }
      plan.training = plan.training + cost
    end
    local step = { kind = "craft", spell = p.r.spell, from = p.skill, to = p.skill + 1 }
    local expected, stepSpread = p.crafts, p.spread
    i = i + 1
    while i <= #picks and picks[i].r == p.r and not rankAt(picks[i].skill) do
      expected = expected + picks[i].crafts
      stepSpread = stepSpread + picks[i].spread
      step.to = picks[i].skill + 1
      i = i + 1
    end
    step.crafts = math.ceil(expected - 1e-9)
    -- From the rounded average, like the materials below, so a step's count and its materials agree.
    step.safe = math.ceil(step.crafts + SAFE_Z * math.sqrt(stepSpread) - 1e-9)
    memo = {}
    step.costPerCraft = craftCost(p.r, step.from)
    if not known[p.r.spell] and not taught[p.r.spell] then
      taught[p.r.spell] = true
      step.learn = { skill = p.r.learn, cost = learnCost(p.r), pattern = not p.r.trainer or nil }
      if step.learn.pattern then
        -- Taught by a recipe item: its price (vendor or auction house) when known.
        plan.patterns[#plan.patterns + 1] = p.r.spell
        if step.learn.cost then
          plan.patternCost = plan.patternCost + step.learn.cost
        else
          plan.unknownPatterns = true
        end
      elseif p.r.cost then
        plan.training = plan.training + p.r.cost
      else
        plan.unknownTraining = true
      end
    end
    local inter, mats = {}, {}
    for _, rg in ipairs(p.r.reagents) do
      local via, crafts = expand(rg[1], rg[2] * step.crafts, step.from, 1, mats)
      if via then inter[#inter + 1] = { spell = via.spell, crafts = crafts } end
    end
    use(mats)
    for item, n in pairs(mats) do
      local per = n / step.crafts
      average[item] = (average[item] or 0) + n
      exact[item] = (exact[item] or 0) + per * expected
      spread[item] = (spread[item] or 0) + per * per * stepSpread
    end
    if #inter > 0 then step.intermediates = inter end
    stepMats[step] = mats
    plan.steps[#plan.steps + 1] = step
  end
  -- What to buy: enough 49 times in 50. Steps that share a material share the extra, so luck on
  -- one evens out against another; spares sell back for about what they cost. Not for what you
  -- own enough of on average: the plan only uses it because it's yours, and if it runs out the
  -- next step simply starts a point or two earlier, so buying more of it would defeat the point.
  plan.averageMaterials = average
  local mine = {}
  for item, n in pairs(average) do
    mine[item] = (owned[item] or 0) >= exact[item] - 1e-9
    local safe = math.max(n, math.ceil(n + SAFE_Z * math.sqrt(spread[item]) - 1e-9))
    plan.materials[item] = mine[item] and math.min(safe, owned[item]) or safe
    -- A missing price matters only for what you'll have to buy.
    if not price(item) and plan.materials[item] > (owned[item] or 0) then plan.unknownPrices[item] = true end
  end
  -- A step made only from what you own: as many crafts as that covers, nothing extra to be ready for.
  for step, mats in pairs(stepMats) do
    local all = next(mats) ~= nil
    for item in pairs(mats) do
      all = all and mine[item]
    end
    if all then step.safe = step.crafts end
  end
  return plan
end

--- What to buy for the rest of a plan, given what the player has: per material the count needed,
--- had, to buy, its unit price and the cost; plus the gold total (materials + training).
---@param plan GoldwrightLevelPlan
---@param have fun(item: number): number count in bags (and bank)
---@param price fun(item: number): number|nil copper per unit
---@return table list { {item, need, have, buy, unit, cost}, ... } most expensive first
---@return number total copper (known prices only)
function GW.LevelPlanShopping(plan, have, price)
  local list, total = {}, plan.training + (plan.patternCost or 0)
  for item, need in pairs(plan.materials) do
    local got = math.min(need, have(item) or 0)
    local unit = price(item)
    local row = { item = item, need = need, have = got, buy = need - got, unit = unit }
    row.cost = unit and row.buy * unit or nil
    if row.cost then total = total + row.cost end
    list[#list + 1] = row
  end
  table.sort(list, function(a, b)
    if (a.cost or -1) ~= (b.cost or -1) then return (a.cost or -1) > (b.cost or -1) end
    return a.item < b.item
  end)
  return list, total
end

--- The open profession's skill and cap. The profession window's own info first; it has been seen
--- saying skill 0 for a character at 80 (2026-11-14), and nobody with a profession is at 0, so
--- then the profession by its skill line, the classic trade skill line, and the character's skill
--- list by name. Read-only getters only.
---@param line number|nil base profession skill line (Leatherworking 165), when known
---@return number|nil skill nil when no source gives a real skill
---@return number|nil max cap
---@return string|nil source which getter answered
function GW.ProfessionSkill(line)
  local api = C_TradeSkillUI or {}
  local ok, base = pcall(api.GetBaseProfessionInfo)
  base = ok and type(base) == "table" and base or {}
  local function real(skill, max, source)
    skill = tonumber(skill)
    if skill and skill > 0 then return skill, tonumber(max), source end
  end
  local s, m, src = real(base.skillLevel, base.maxSkillLevel, "profession window")
  if s then return s, m, src end
  local name = type(base.professionName) == "string" and base.professionName ~= "" and base.professionName or nil
  if line and api.GetProfessionInfoBySkillLineID then
    local okP, info = pcall(api.GetProfessionInfoBySkillLineID, line)
    if okP and type(info) == "table" then
      s, m, src = real(info.skillLevel, info.maxSkillLevel, "skill line")
      if s then return s, m, src end
      name = name
        or (type(info.professionName) == "string" and info.professionName ~= "" and info.professionName)
        or nil
    end
  end
  if GetTradeSkillLine then
    local okT, tName, rank, max = pcall(GetTradeSkillLine)
    if okT and tName ~= "UNKNOWN" then
      s, m, src = real(rank, max, "trade skill line")
      if s then return s, m, src end
    end
  end
  if name and GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() or 0 do
      local n, header, _, rank, _, _, max = GetSkillLineInfo(i)
      if not header and n == name then
        s, m, src = real(rank, max, "skill list")
        if s then return s, m, src end
      end
    end
  end
  return nil, nil, nil
end

--- The plan for the open profession window, from today's prices at the house the Crafting panel
--- prices at. nil when no profession window is open, the profession isn't in the table, or no
--- source gives the skill (then the second result says "skill unknown").
--- Calls only read-only client getters (C_TradeSkillUI.GetAllRecipeIDs, GetRecipeInfo;
--- GW.ProfessionSkill's; IsPlayerSpell; UnitLevel; UnitFactionGroup; C_Item.GetItemCount).
---@param target number|nil the skill to plan up to (default 300, #31)
---@return GoldwrightLevelPlan|nil plan with .skillSource = where the skill came from
---@return string|nil why "no window" or "skill unknown" when there's no plan
function GW.LevelPlanNow(target)
  local api = C_TradeSkillUI
  if not api then return nil, "no window" end
  local known, line = {}, nil
  for _, id in ipairs(GW.RecipeIDs()) do
    local ok, info = pcall(api.GetRecipeInfo, id)
    if ok and type(info) == "table" and info.learned then known[id] = true end
    if not line then
      for l, list in pairs(GW.RECIPES or {}) do
        if list[id] then line = l end
      end
    end
  end
  if not line then return nil, "no window" end
  local skill, maxSkill, source = GW.ProfessionSkill(line)
  if not skill then return nil, "skill unknown" end
  local specs = {}
  for _, spell in ipairs(GW.RecipeSpells(line)) do
    local s = GW.RecipeInfo(line, spell).specialization
    if s and specs[s] == nil then specs[s] = IsPlayerSpell and IsPlayerSpell(s) or false end
  end
  local side = GW.CraftSide()
  local function price(item) return (GW.MaterialPrice(item, side)) end
  local faction = UnitFactionGroup and UnitFactionGroup("player") == "Horde" and "H" or "A"
  local function patternPrice(spell)
    -- The cheaper of a vendor of the player's faction and the auction house (any item teaching it).
    local p = GW.RecipePattern(line, spell)
    if not p then return nil end
    local best = p[faction]
    for _, item in ipairs(p.items) do
      local ah = GW.MaterialPrice(item, side)
      if ah and (not best or ah < best) then best = ah end
    end
    return best
  end
  -- Bags and bank (as far as the client knows the bank), like the Level up tab's have column.
  local function have(item)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(item, true) or 0 end
    return GetItemCount and GetItemCount(item, true) or 0
  end
  local plan = GW.LevelPlan({
    have = have,
    patternPrice = patternPrice,
    skillLine = line,
    skill = skill,
    target = target or 300,
    maxSkill = maxSkill,
    known = known,
    price = price,
    specializations = specs,
    level = UnitLevel and UnitLevel("player") or nil,
  })
  plan.skillSource = source
  return plan
end
