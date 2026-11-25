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

---------------------------------------------------------------------------
-- gear variants (goldwright-addon #58): random-suffix gear ("Medicine Staff of the Tiger") shares
-- one item id with its other suffixes; Goldwright Data keeps each one under "id:bonus"
---------------------------------------------------------------------------
--- The item id and bonus ids of a data key: 4575 -> 4575, nil; "4575:12727" -> 4575, { 12727 }.
---@param key number|string
---@return number|nil itemID
---@return number[]|nil bonus
function GW.ItemNames.SplitKey(key)
  if type(key) == "number" then return key, nil end
  if type(key) ~= "string" then return nil, nil end
  local id, rest = key:match("^(%d+):([%d:]+)$")
  if not id then return tonumber(key), nil end
  local bonus = {}
  for b in rest:gmatch("%d+") do
    bonus[#bonus + 1] = tonumber(b)
  end
  return tonumber(id), bonus
end

--- An item link for a data key, with its bonus ids, so the game names and shows that variant.
---@param key number|string
---@return string|nil link "item:4575::::::::::::1:12727"
function GW.ItemNames.KeyLink(key)
  local id, bonus = GW.ItemNames.SplitKey(key)
  if not id then return nil end
  if not bonus then return "item:" .. id end
  return "item:" .. id .. string.rep(":", 12) .. #bonus .. ":" .. table.concat(bonus, ":")
end

--- The auction house's item key for a gear variant: the base item's key with the variant's suffix
--- number (GW.SUFFIX_KEYS, the game data's name id of the suffix; 12727 "of the Tiger" -> 14307).
--- On WoW Forever each variant is listed under its own key, so a search with the plain key (suffix
--- 0) finds none of a variant's listings (#58).
---@param key number|string "id:bonus"
---@return table|nil itemKey nil for a plain item or a suffix without a known number
function GW.ItemNames.AuctionKey(key)
  local id, bonus = GW.ItemNames.SplitKey(key)
  if not (id and bonus and C_AuctionHouse and C_AuctionHouse.MakeItemKey) then return nil end
  for _, b in ipairs(bonus) do
    local suffix = GW.SUFFIX_KEYS and GW.SUFFIX_KEYS[b]
    if suffix then
      local itemKey = C_AuctionHouse.MakeItemKey(id)
      if type(itemKey) ~= "table" then return nil end
      itemKey.itemSuffix = suffix
      return itemKey
    end
  end
  return nil
end

local variantNames = {} -- data key -> name, once known

--- A gear variant's full name ("Medicine Staff of the Tiger"): the game's name for the variant's
--- link in the player's language when it has one, else the base name and the suffix's English name,
--- else the base name with the bonus id.
---@param key number|string
---@return string|nil
function GW.ItemNames.Variant(key)
  if variantNames[key] then return variantNames[key] end
  local id, bonus = GW.ItemNames.SplitKey(key)
  if not id then return nil end
  local base = GW.ItemNames.Of(id)
  if not bonus then return base end
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local ok, game = pcall(function() return get and get(GW.ItemNames.KeyLink(key)) end)
  local known = ok and type(game) == "string" and game ~= ""
  if known and game ~= base then
    variantNames[key] = game
    return game
  end
  if not base then return nil end
  local name
  for _, b in ipairs(bonus) do
    local suffix = GW.SUFFIX_NAMES and GW.SUFFIX_NAMES[b]
    if suffix then
      name = base .. " " .. suffix
      break
    end
  end
  name = name or string.format("%s (%s)", base, table.concat(bonus, ":"))
  -- the game answered without a suffix: it won't name this variant, so keep ours (a variant it
  -- hasn't loaded yet is asked again next time, as the game may name it then)
  if known then variantNames[key] = name end
  return name
end

local variantPack, variantIndex = false, {} -- the pack the index was built from; base id -> its variant keys

--- The variant keys Goldwright Data has for an item ("4575:12727", ...), built once per data pack.
---@param id number
---@return string[]|nil
function GW.ItemNames.Variants(id)
  if variantPack ~= GW.pack then
    variantPack, variantIndex = GW.pack, {}
    for key in pairs(GW.pack and GW.pack.items or {}) do
      local base = type(key) == "string" and tonumber(key:match("^(%d+):"))
      if base then
        variantIndex[base] = variantIndex[base] or {}
        table.insert(variantIndex[base], key)
      end
    end
  end
  return variantIndex[id]
end

--- Units sold a day of a data key at any house, for ordering variants (busiest first).
---@param key number|string
---@return number
local function soldPerDay(key)
  local n = 0
  for _, s in pairs(GW.ItemData(key) or {}) do
    n = n + (s.boughtPerDay or s.soldPerDay or 0)
  end
  return n
end

--- Up to `max` items whose name matches what was typed: names starting with it first, then a word
--- starting with it, then anywhere; items with prices before items without; shorter names first.
--- Gear variants (#58) come right after their base item, busiest first: typing the base name lists
--- them, typing a variant's full name ("medicine staff of the tiger") finds it.
---@param typed string
---@param max number
---@return { id: number, key: number|string, name: string }[] key: the data key ("id:bonus" for a variant)
local lowerOf = {} -- name -> lower-case name, so typing doesn't lower-case every name again

--- Whether Goldwright has prices for an item: the pack's table first (cheap), then the full lookup.
---@param id number
---@return boolean
local function hasData(id)
  if GW.pack and GW.pack.items and GW.pack.items[id] ~= nil then return true end
  return GW.ItemData(id) ~= nil
end

--- The gear variants of an item whose name contains `q`, busiest first, then by name.
---@param id number
---@param q string lower-case
---@return { id: number, key: string, name: string }[]
local function variantsMatching(id, q)
  local list = {}
  for _, key in ipairs(GW.ItemNames.Variants(id) or {}) do
    local name = GW.ItemNames.Variant(key)
    if name and name:lower():find(q, 1, true) then
      list[#list + 1] = { id = id, key = key, name = name, sold = soldPerDay(key) }
    end
  end
  table.sort(list, function(a, b)
    if a.sold ~= b.sold then return a.sold > b.sold end
    return a.name < b.name
  end)
  return list
end

--- Up to `max` items whose name matches what was typed: names starting with it first, then a word
--- starting with it, then anywhere; items with prices before items without; shorter names first.
--- Gear variants (#58) come right after their base item, busiest first: typing the base name lists
--- them, typing a variant's full name ("medicine staff of the tiger") finds it.
--- Fast on every keystroke, also for one letter: one pass over the names keeps only the best `max`
--- items, and only the variants of the items shown are looked at.
---@param typed string
---@param max number
---@return { id: number, key: number|string, name: string }[] key: the data key ("id:bonus" for a variant)
function GW.ItemNames.Match(typed, max)
  local q = typed and typed:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
  if q == "" then return {} end
  -- whether a match (rank, name, id) goes before entry m: rank, shorter name, name, id
  local function beats(rank, name, id, m)
    if rank ~= m.rank then return rank < m.rank end
    if #name ~= #m.name then return #name < #m.name end
    if name ~= m.name then return name < m.name end
    return id < m.id
  end
  local top, seen, typedBases = {}, {}, {}
  -- keeps the best `max` matches in order (an insertion into a short list). A match is compared
  -- before its table is made, so the thousands that don't make the list cost no memory.
  local function keep(rank, name, id)
    local n = #top
    if n >= max and not beats(rank, name, id, top[n]) then return end
    local i = n + 1
    while i > 1 and beats(rank, name, id, top[i - 1]) do
      top[i] = top[i - 1]
      i = i - 1
    end
    top[i] = { id = id, key = id, name = name, rank = rank }
    if #top > max then top[#top] = nil end
  end
  local function consider(id, name)
    if seen[id] or type(name) ~= "string" then return end
    seen[id] = true
    local lower = lowerOf[name]
    if not lower then
      lower = name:lower()
      lowerOf[name] = lower
    end
    local at = lower:find(q, 1, true)
    if at then
      local rank = at == 1 and 0 or (lower:find(" " .. q, 1, true) and 1 or 2)
      if not hasData(id) then rank = rank + 3 end
      keep(rank, name, id)
    elseif #q > #lower + 1 and q:sub(1, #lower + 1) == lower .. " " then
      -- the base item of a typed variant name ("medicine staff of the tiger")
      typedBases[#typedBases + 1] = id
    end
  end
  for id, name in pairs(GoldwrightDB and GoldwrightDB.seenNames or {}) do
    consider(id, name)
  end
  for id, name in pairs(GW.ItemNames.FromData() or {}) do
    consider(id, name)
  end
  local out = {}
  local function add(m)
    if #out < max then out[#out + 1] = { id = m.id, key = m.key, name = m.name } end
  end
  -- a variant's full name typed: those variants first; then each item shown, followed by its variants
  for _, id in ipairs(typedBases) do
    for _, v in ipairs(variantsMatching(id, q)) do
      add(v)
    end
  end
  for _, m in ipairs(top) do
    if #out >= max then break end
    add(m)
    if #out < max then
      for _, v in ipairs(variantsMatching(m.id, q)) do
        add(v)
      end
    end
  end
  return out
end
