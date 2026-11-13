--- Crafting rules without any UI (CRAFT-1..3): reading a recipe from the open profession window
--- (C_TradeSkillUI, read-only), the cheapest house the player can buy each material from, the
--- value of what the recipe makes, profit after the auction house cut, and the recipe list order.
--- Tested outside the game in server/test/addon-crafting.test.mjs.
---
--- The C_TradeSkillUI field names come from warcraft.wiki.gg (Forever 1.60.1) and are not all
--- confirmed in game yet, so every read is defensive: a missing field means "unknown", never an error.
local _, GW = ...
local L = GW.L

GW.MERCHANTS_FAVOR = 3402 -- currency id of Merchant's Favor (Forever's vendor-recipe currency)

-- Names for currencies the client can't name (no C_CurrencyInfo, or not cached yet).
local CURRENCY_NAMES = { [3402] = L["Merchant's Favor"] }

--- A material slot of a recipe, as GW.ReadRecipe returns it.
---@class GoldwrightReagent
---@field itemID number|nil the item used (nil = unknown material)
---@field qty number|nil how many one craft takes (nil = unknown)

--- A currency a recipe takes (Merchant's Favor), kept apart from gold.
---@class GoldwrightCurrencyCost
---@field currencyID number
---@field qty number|nil how many one craft takes (nil = unknown)
---@field name string display name

--- One recipe of the open profession, read from C_TradeSkillUI.
---@class GoldwrightRecipe
---@field id number recipe spell id
---@field name string recipe name ("Recipe 1234" when unknown)
---@field learned boolean the character knows it
---@field icon number|string|nil icon texture
---@field outputItemID number|nil the item it makes (nil = makes no item, e.g. an enchant, or unknown)
---@field qtyMin number fewest items one craft makes
---@field qtyMax number most items one craft makes
---@field qtyAssumed boolean|nil the client gave no output quantity: 1 is assumed
---@field reagents GoldwrightReagent[] materials bought with gold
---@field currencies GoldwrightCurrencyCost[] currencies (Merchant's Favor), never converted to gold
---@field noSchematic boolean|nil the client returned no schematic: materials and output unknown

--- One priced material line of a recipe.
---@class GoldwrightMaterialCost
---@field itemID number|nil
---@field qty number|nil
---@field unit number|nil market value per unit (nil = no price data)
---@field total number|nil unit * qty (nil = no price data)
---@field side string|nil where that price is from ("A", "H", "N", or "vendor")

--- A recipe's cost, value and profit, as GW.PriceRecipe returns it. Money in copper per craft.
---@class GoldwrightCraftPrice
---@field materials GoldwrightMaterialCost[]
---@field currencies GoldwrightCurrencyCost[]
---@field cost number|nil total cost of the materials (nil when any has no price data)
---@field knownCost number cost of the materials that do have a price
---@field missing number materials without price data
---@field avgQty number average items one craft makes
---@field side string the house the recipe is priced at (GW.CraftSide())
---@field outputUnit number|nil market value of one output item at that house
---@field outputSide string|nil that house (nil = no price data there)
---@field value number|nil outputUnit * avgQty (nil = no price data)
---@field cut number|nil the auction house cut on value at outputSide
---@field net number|nil value - cut
---@field profit number|nil net - cost (nil when anything is unknown)
---@field soldPerDay number|nil estimated sales per day of the output at outputSide
---@field rateText string|nil sales per day of the output there (GW.SellRateText: proven, else estimate)
---@field noOutput boolean|nil the recipe makes no item to sell
---@field hint GoldwrightCraftHint|nil the other house really pays more for the output

--- The other house the player can reach pays clearly more for an output (GW.CraftHint).
---@class GoldwrightCraftHint
---@field side string that house
---@field pct number|nil how much more it nets after both cuts, in % (nil = no price where the panel prices)
---@field boughtPerDay number|nil proven sales per day there

--- Calls `fn(...)` and returns its first result, or nil when it errors or isn't there.
---@param fn function|nil
---@param ... any arguments
---@return any result
local function safe(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, r = pcall(fn, ...)
  if ok then return r end
  return nil
end

--- A positive number or nil.
---@param v any
---@return number|nil
local function num(v)
  if type(v) == "number" and v > 0 then return v end
  return nil
end

--- The display name of a currency: from the client when it knows it, else our own table.
---@param currencyID number
---@return string name
function GW.CurrencyName(currencyID)
  local api = C_CurrencyInfo
  local info = api and safe(api.GetCurrencyInfo, currencyID)
  local name = type(info) == "table" and info.name
  if type(name) == "string" and name ~= "" then return name end
  return CURRENCY_NAMES[currencyID] or string.format(L["Currency %s"], tostring(currencyID))
end

--- Recipe spell ids of the open profession, learned and not (empty until the window has opened).
---@return number[] ids
function GW.RecipeIDs()
  local api = C_TradeSkillUI
  local ids = api and safe(api.GetAllRecipeIDs)
  local out = {}
  if type(ids) ~= "table" then return out end
  for _, id in ipairs(ids) do
    if type(id) == "number" then out[#out + 1] = id end
  end
  return out
end

--- The open profession's name ("Leatherworking"), or nil when the client doesn't say. On Forever
--- GetBaseProfessionInfo names it while the window is open; GetChildProfessionInfo is empty (in game).
---@return string|nil name
function GW.ProfessionName()
  local api = C_TradeSkillUI
  local info = api and safe(api.GetBaseProfessionInfo)
  local name = type(info) == "table" and info.professionName
  if type(name) == "string" and name ~= "" then return name end
  return nil
end

--- Reads one recipe from C_TradeSkillUI (GetRecipeInfo, GetRecipeSchematic, GetRecipeOutputItemData).
--- Optional slots (`required == false`) are left out; a slot's first reagent is the one priced.
--- Reagents with a `currencyID` are kept apart as currencies (CRAFT-3). None were seen in game: on
--- Forever, Merchant's Favor buys recipes from vendors rather than being used in crafts.
---@param recipeID number recipe spell id
---@return GoldwrightRecipe recipe
function GW.ReadRecipe(recipeID)
  local api = C_TradeSkillUI or {}
  local info = safe(api.GetRecipeInfo, recipeID)
  info = type(info) == "table" and info or {}
  local r = {
    id = recipeID,
    name = (type(info.name) == "string" and info.name ~= "") and info.name
      or string.format(L["Recipe %s"], tostring(recipeID)),
    learned = info.learned == true,
    icon = num(info.icon) or (type(info.icon) == "string" and info.icon) or nil,
    reagents = {},
    currencies = {},
    qtyMin = 1,
    qtyMax = 1,
  }
  local s = safe(api.GetRecipeSchematic, recipeID, false)
  local out = safe(api.GetRecipeOutputItemData, recipeID)
  out = type(out) == "table" and out or {}
  if type(s) ~= "table" then
    r.noSchematic = true
    r.outputItemID = num(out.itemID)
    r.icon = r.icon or num(out.icon)
    return r
  end
  r.outputItemID = num(s.outputItemID) or num(out.itemID)
  r.icon = r.icon or num(out.icon) or num(s.icon) -- the schematic's icon is 0 in game
  local qMin, qMax = num(s.quantityMin), num(s.quantityMax)
  if qMin or qMax then
    r.qtyMin, r.qtyMax = qMin or qMax, qMax or qMin
    if r.qtyMax < r.qtyMin then
      r.qtyMin, r.qtyMax = r.qtyMax, r.qtyMin
    end
  else
    r.qtyAssumed = true
  end
  if type(s.reagentSlotSchematics) == "table" then
    for _, slot in ipairs(s.reagentSlotSchematics) do
      if type(slot) == "table" and slot.required ~= false then
        local first = type(slot.reagents) == "table" and slot.reagents[1]
        first = type(first) == "table" and first or {}
        local qty = num(slot.quantityRequired)
        if num(first.currencyID) then
          r.currencies[#r.currencies + 1] =
            { currencyID = first.currencyID, qty = qty, name = GW.CurrencyName(first.currencyID) }
        else
          r.reagents[#r.reagents + 1] = { itemID = num(first.itemID), qty = qty }
        end
      end
    end
  end
  return r
end

--- The houses the player can trade at: their faction's house and Blackwater, never the other faction's.
---@return string[] sides e.g. { "A", "N" }
function GW.ReachableHouses() return { GW.House().side, "N" } end

--- The house the Crafting panel prices at: the player's own faction house unless they switched to
--- Blackwater (GoldwrightDB.craftHouse = "N"). Asking prices never switch it on their own.
---@return string side "A", "H" or "N"
function GW.CraftSide()
  if GoldwrightDB and GoldwrightDB.craftHouse == "N" then return "N" end
  return GW.House().side
end

--- Switches the house the Crafting panel prices at ("N" = Blackwater, anything else = own house).
---@param side string|nil
function GW.SetCraftSide(side)
  GoldwrightDB = GoldwrightDB or {}
  GoldwrightDB.craftHouse = (side == "N" and GW.House().side ~= "N") and "N" or nil
end

--- The other house the player can reach: Blackwater from their faction's house, and back.
---@param side string
---@return string|nil other nil when the player's own house is Blackwater
local function otherHouse(side)
  local own = GW.House().side
  if own == "N" then return nil end
  return side == "N" and own or "N"
end

--- What a material costs: the vendor price when a vendor sells it (thread, dye, salt ...;
--- GW.VendorSellsFor in Vendors.lua), else its market value at `side`. When that house lists none,
--- the other house the player can reach, so the cost stays known (the material line says where).
---@param itemID number|nil
---@param side string|nil the house to price at (default GW.CraftSide())
---@return number|nil unit price per unit in copper (nil = no price data)
---@return string|nil side the house it is from, or "vendor"
function GW.MaterialPrice(itemID, side)
  local vendor = GW.VendorSellsFor and GW.VendorSellsFor(itemID)
  if vendor then return vendor, "vendor" end
  local d = itemID and GW.ItemData(itemID)
  if not d then return nil, nil end
  side = side or GW.CraftSide()
  local mv = d[side] and num(d[side].mv)
  if mv then return mv, side end
  local other = otherHouse(side)
  mv = other and d[other] and num(d[other].mv)
  if mv then return mv, other end
  return nil, nil
end

--- Whether the other reachable house really pays more for an item than `side`: the tooltip's
--- Blackwater rule (GW.BetterHouse: `betterPct` more after both cuts, enough units listed, proven
--- buyers). Also says so when `side` has no price but the other house has proven buyers.
---@param itemID number|nil
---@param side string the house the panel prices at
---@return GoldwrightCraftHint|nil hint nil when there is nothing to point at
function GW.CraftHint(itemID, side)
  local d = itemID and GW.ItemData(itemID)
  local other = otherHouse(side)
  local there = d and other and d[other]
  if not there then return nil end
  local here = d[side] and num(d[side].mv)
  if here then
    local pct = GW.BetterHouse(there, other, here, side)
    return pct and { side = other, pct = pct, boughtPerDay = there.boughtPerDay } or nil
  end
  local proven = (there.units or 0) >= GW.MIN_UNITS_FOR_HINT and (there.boughtPerDay or 0) >= GW.MIN_PROVEN_PER_DAY
  if num(there.mv) and proven then return { side = other, boughtPerDay = there.boughtPerDay } end
  return nil
end

--- CRAFT-2 / CRAFT-3: prices a recipe at one house. Materials cost their market value there
--- (GW.MaterialPrice); the output is worth its market value there times the average number one craft
--- makes, less that house's cut (GW.CUT). `hint` points at the other house when it really pays more.
--- Currencies are listed apart and not converted to gold.
---@param recipe GoldwrightRecipe
---@param side string|nil the house to price at (default GW.CraftSide())
---@return GoldwrightCraftPrice price
function GW.PriceRecipe(recipe, side)
  side = side or GW.CraftSide()
  local p = { materials = {}, currencies = recipe.currencies or {}, knownCost = 0, missing = 0, side = side }
  for _, rg in ipairs(recipe.reagents or {}) do
    local unit, from = GW.MaterialPrice(rg.itemID, side)
    local total = unit and rg.qty and unit * rg.qty or nil
    p.materials[#p.materials + 1] = { itemID = rg.itemID, qty = rg.qty, unit = unit, total = total, side = from }
    if total then
      p.knownCost = p.knownCost + total
    else
      p.missing = p.missing + 1
    end
  end
  if not recipe.noSchematic and p.missing == 0 then p.cost = p.knownCost end
  p.avgQty = ((recipe.qtyMin or 1) + (recipe.qtyMax or recipe.qtyMin or 1)) / 2
  if not recipe.outputItemID then
    p.noOutput = not recipe.noSchematic
    return p
  end
  p.hint = GW.CraftHint(recipe.outputItemID, side)
  local d = GW.ItemData(recipe.outputItemID)
  local data = d and d[side]
  local unit = data and num(data.mv)
  p.soldPerDay = data and data.soldPerDay
  p.rateText = GW.SellRateText(data)
  if not unit then return p end
  p.outputUnit, p.outputSide = unit, side
  p.value = unit * p.avgQty
  p.cut = p.value * (GW.CUT[side] or 0.05)
  p.net = p.value - p.cut
  if p.cost then p.profit = p.net - p.cost end
  return p
end

--- Signed money for profit badges: "+9c", "−4c" (a real minus sign), "0c".
---@param copper number
---@return string text
function GW.SignedMoney(copper)
  local c = math.floor(copper + 0.5)
  if c > 0 then return "+" .. GW.Money(c) end
  if c < 0 then return "−" .. GW.Money(-c) end
  return GW.Money(0)
end

--- A recipe with its price, as GW.SortRecipes sorts them.
---@class GoldwrightRecipeRow
---@field recipe GoldwrightRecipe
---@field price GoldwrightCraftPrice

--- CRAFT-1: sorts recipe rows in place: learned recipes first, then by profit (highest first, unknown
--- profit last) or by name; ties by name, then id.
---@param rows GoldwrightRecipeRow[]
---@param by string|nil "profit" (default) or "name"
---@return GoldwrightRecipeRow[] rows the same table
function GW.SortRecipes(rows, by)
  table.sort(rows, function(a, b)
    local ra, rb = a.recipe, b.recipe
    if ra.learned ~= rb.learned then return ra.learned end
    if by ~= "name" then
      local pa, pb = a.price.profit, b.price.profit
      if pa and pb and pa ~= pb then return pa > pb end
      if (pa == nil) ~= (pb == nil) then return pa ~= nil end
    end
    if ra.name ~= rb.name then return ra.name < rb.name end
    return ra.id < rb.id
  end)
  return rows
end

--- Reads and prices the recipes of the open profession. Unlearned recipes are most of the list in game
--- (Leatherworking: 592 recipes, 24 learned), so they are left out unless asked for.
---@param by string|nil sort order, "profit" (default) or "name"
---@param unlearned boolean|nil include recipes the character hasn't learned (after the learned ones)
---@return GoldwrightRecipeRow[] rows sorted with GW.SortRecipes
---@return number hidden unlearned recipes left out
function GW.CraftRows(by, unlearned)
  local rows, hidden = {}, 0
  for _, id in ipairs(GW.RecipeIDs()) do
    local r = GW.ReadRecipe(id)
    if r.learned or unlearned then
      rows[#rows + 1] = { recipe = r, price = GW.PriceRecipe(r) }
    else
      hidden = hidden + 1
    end
  end
  return GW.SortRecipes(rows, by), hidden
end

--- "Merchant's Favor ×3" (more joined by " + ") for a recipe's currencies; nil without any.
---@param currencies GoldwrightCurrencyCost[]|nil
---@return string|nil text
function GW.CurrencyText(currencies)
  if not currencies or #currencies == 0 then return nil end
  local parts = {}
  for _, c in ipairs(currencies) do
    parts[#parts + 1] = string.format("%s ×%s", c.name, c.qty and tostring(c.qty) or "?")
  end
  return table.concat(parts, " + ")
end
