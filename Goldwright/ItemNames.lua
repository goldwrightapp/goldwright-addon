--- Item names Goldwright knows, and finding items by what the player types (goldwright-addon #36,
--- #37). One job: names. Sources, best first: names Goldwright has seen in the player's language
--- (bags, tooltips, shopping lists, lookups; GoldwrightDB.seenNames), Goldwright Data's names folder
--- for the player's language (load-on-demand GoldwrightData_Names_<locale>, else English), and the
--- game's own cache. Used by the Buy tab's lookup; anything that wants "type a name" can use it.
local _, GW = ...
local L = GW.L

GW.ItemNames = {}

--- Remembers an item's name in the player's language, from anything Goldwright sees (bags,
--- tooltips, lookups), so the lookup can suggest it later, also before Goldwright Data has that item's name (#36).
---@param id number|nil
---@param name string|nil
function GW.ItemNames.Note(id, name)
  if type(id) ~= "number" or type(name) ~= "string" or name == "" or not GoldwrightDB then return end
  GoldwrightDB.seenNames = GoldwrightDB.seenNames or {}
  GoldwrightDB.seenNames[id] = name
end

--- Learns the names Goldwright can get without asking the server: everything in your bags and on
--- your shopping lists (the lookup can then suggest them, also before Goldwright Data has them).
function GW.ItemNames.Learn()
  if C_Container and C_Container.GetContainerNumSlots then
    for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
      for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        local link = info and info.hyperlink
        if link and (GW.LinkVariant(link) or "") == "" then GW.ItemNames.Note(info.itemID, link:match("%[(.-)%]")) end
      end
    end
  end
  for _, list in ipairs(GW.Lists and GW.Lists() or {}) do
    for _, e in ipairs(list.entries or {}) do
      if e.itemID and e.name and e.name ~= string.format(L["item %d"], e.itemID) then
        GW.ItemNames.Note(e.itemID, e.name)
      end
    end
  end
end

--- Loads a load-on-demand add-on (the API is looked up when called).
---@param name string
local function loadAddOn(name)
  local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
  if load then return load(name) end
end
local namesTable, namesTried

--- Goldwright Data's item names in the player's language (#36), loaded the first time they're
--- needed: the load-on-demand folder GoldwrightData_Names_<locale>, else English while other
--- languages aren't in the data yet. nil when Goldwright Data has no names folder.
---@return table<number, string>|nil names item id -> name
function GW.ItemNames.FromData()
  if namesTried then return namesTable end
  namesTried = true
  local locale = GetLocale and GetLocale() or "enUS"
  for _, l in ipairs({ locale, "enUS" }) do
    if not (GoldwrightNames and GoldwrightNames[l]) then pcall(loadAddOn, "GoldwrightData_Names_" .. l) end
    if GoldwrightNames and GoldwrightNames[l] then
      namesTable = GoldwrightNames[l]
      break
    end
  end
  return namesTable
end

--- An item's name: from what Goldwright has seen (the player's language), Goldwright Data's names
--- (#36) or the game.
---@param id number
---@return string|nil
function GW.ItemNames.Of(id)
  local seen = GoldwrightDB and GoldwrightDB.seenNames
  local packNames = GW.ItemNames.FromData()
  return (seen and seen[id])
    or (packNames and packNames[id])
    or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
end

--- Up to `max` items whose name matches what was typed: names starting with it first, then a word
--- starting with it, then anywhere; items with prices before items without; shorter names first.
---@param typed string
---@param max number
---@return { id: number, name: string }[]
function GW.ItemNames.Match(typed, max)
  local q = typed and typed:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
  if q == "" then return {} end
  local found = {}
  local function consider(id, name)
    if found[id] or type(name) ~= "string" then return end
    local lower = name:lower()
    local at = lower:find(q, 1, true)
    if not at then return end
    local rank = at == 1 and 0 or (lower:find(" " .. q, 1, true) and 1 or 2)
    if not GW.ItemData(id) then rank = rank + 3 end
    found[id] = { id = id, name = name, rank = rank }
  end
  for id, name in pairs(GoldwrightDB and GoldwrightDB.seenNames or {}) do
    consider(id, name)
  end
  for id, name in pairs(GW.ItemNames.FromData() or {}) do
    consider(id, name)
  end
  local list = {}
  for _, m in pairs(found) do
    list[#list + 1] = m
  end
  table.sort(list, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if #a.name ~= #b.name then return #a.name < #b.name end
    return a.name < b.name
  end)
  local out = {}
  for i = 1, math.min(max, #list) do
    out[i] = { id = list[i].id, name = list[i].name }
  end
  return out
end
