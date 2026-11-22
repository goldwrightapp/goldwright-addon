--- Blackwater gaps: items worth carrying between the player's faction house and Blackwater, with how
--- many to carry. The same rule as the website's Gold ideas page (website/lib/gold.ts):
--- - sell price = the selling house's market value, but no more than its 7-day average (a one-day
---   spike doesn't count), less that house's cut; at least +20% over the buy price, no upper limit;
--- - proven buyers where you sell (at least GAP_MIN_PROVEN a day) and a real market (GAP_MIN_UNITS
---   listed there);
--- - how many: "sure" = half a day of proven sales (sells within one 24 h auction even on a slower
---   day or when undercut part of the time), "up to" = a day; both shrink as the selling house
---   already lists more than a day of sales and reach 0 at two days; never more than the buying
---   house lists;
--- - both rounded down to whole stacks (a bag slot each), unless that's less than one stack; goods
---   that stack only.
--- Ranked by profit at the "sure" amount. Reads the data pack (and the player's own full scans, via
--- GW.ItemData); no UI here (GapsView.lua).
local _, GW = ...

GW.GAP_MIN = 0.2
GW.GAP_MIN_PROVEN = 5
GW.GAP_MIN_UNITS = 20

--- How many to carry (website/lib/gold.ts carryAmount).
---@param bought number proven sales a day where you sell
---@param unitsThere number units listed where you sell
---@param unitsHere number units listed where you buy
---@return number sure
---@return number upTo
function GW.CarryAmount(bought, unitsThere, unitsHere)
  if not bought or bought <= 0 then return 0, 0 end
  local room = math.max(0, math.min(1, (2 * bought - (unitsThere or 0)) / bought))
  local here = unitsHere or 0
  return math.min(here, math.floor(0.5 * bought * room)), math.min(here, math.floor(bought * room))
end

--- An item's stack size from the client, or nil while the client doesn't know the item yet.
---@param id number
---@return number|nil
function GW.StackSize(id)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil end
  local stack = select(8, getInfo(id))
  return type(stack) == "number" and stack > 0 and stack or nil
end

--- Rounds an amount down to whole stacks, so a run fills whole bag slots. Less than one stack, or
--- an unknown stack size, stays as it is (never rounds a gap away).
---@param n number
---@param stack number|nil
---@return number amount
---@return number|nil slots bag slots it takes (nil when the stack size is unknown)
function GW.WholeStacks(n, stack)
  if not stack then return n, nil end
  if n >= stack then n = math.floor(n / stack) * stack end
  return n, math.ceil(n / stack)
end

--- One gap.
---@class GoldwrightGap
---@field item number item id
---@field from string house to buy at ("A", "H", "N")
---@field to string house to sell at
---@field buy number market value where you buy (copper)
---@field sell number sell price where you sell (copper, before the cut)
---@field net number sell price after the cut
---@field gain number net / buy - 1
---@field sure number how many to carry, to sell within one auction
---@field upTo number at most
---@field stack number|nil stack size (nil while the client doesn't know the item)
---@field slots number|nil bag slots for `sure`
---@field upToSlots number|nil bag slots for `upTo`
---@field profit number profit at `sure` (copper)
---@field bought number proven sales a day where you sell
---@field max number max price for a shopping list (10% over today's, never above 75% of net)

--- The gaps between the player's faction house and Blackwater, both ways, most profit first.
---@param home string|nil the faction house ("A" or "H"; default the player's)
---@return GoldwrightGap[]
function GW.BlackwaterGaps(home)
  home = home or (GW.House() and GW.House().side) or "A"
  if home == "N" then home = UnitFactionGroup and UnitFactionGroup("player") == "Horde" and "H" or "A" end
  local pack = GW.pack
  local out = {}
  if not (pack and pack.items) then return out end
  local n36 = function(x) return x and x ~= "" and tonumber(x, 36) or nil end
  -- A full scan newer than the data pack is what's listed now at that house (GW.ItemData reads it
  -- the same way): the quick look below uses its prices too, so a gap that opened since the pack
  -- was built shows up, and one that closed drops off (goldwright-addon #35).
  local fresh = {}
  for side, sc in pairs(GW.HouseScans and GW.HouseScans() or {}) do
    if not (pack.snapshotAt and pack.snapshotAt >= sc.at) then fresh[side] = sc.items end
  end
  ---@return number|nil mv the market value at that house now (nil: not listed)
  local function mvAt(side, key, raw)
    local scanned = fresh[side]
    if scanned then
      local s = scanned[key]
      return s and n36(s:match("^([^,]*)")) or nil
    end
    return n36(raw:match("^([^,]*)"))
  end
  for key, raw in pairs(pack.items) do
    -- Random-suffix gear keys ("id:bonus") are left out; a quick look at the prices first, so only
    -- promising items are read in full. Proven sales come from the pack, so it needs both houses.
    if type(key) == "number" and raw.N and raw[home] then
      local nmv = mvAt("N", key, raw.N)
      local hmv = mvAt(home, key, raw[home])
      if nmv and hmv and nmv > 0 and hmv > 0 and (nmv > hmv * 1.2 or hmv > nmv * 1.2) then
        local d = GW.ItemData(key)
        local here, bw = d and d[home], d and d.N
        if here and bw and here.mv and bw.mv and (bw.units or 0) >= GW.GAP_MIN_UNITS then
          for _, leg in ipairs({ { home, here, "N", bw }, { "N", bw, home, here } }) do
            local from, src, to, dst = leg[1], leg[2], leg[3], leg[4]
            local sell = math.min(dst.mv, dst.avg7 or dst.mv)
            local net = GW.Net(to, sell)
            local gain = net / src.mv - 1
            if gain >= GW.GAP_MIN and (dst.boughtPerDay or 0) >= GW.GAP_MIN_PROVEN then
              local sure, upTo = GW.CarryAmount(dst.boughtPerDay, dst.units, src.units)
              local stack = sure >= 1 and GW.StackSize(key) or nil
              local slots, upToSlots
              sure, slots = GW.WholeStacks(sure, stack)
              upTo, upToSlots = GW.WholeStacks(upTo, stack)
              -- goods that stack only: gear (stack size 1) isn't carried by the bagful
              if sure >= 1 and stack ~= 1 then
                out[#out + 1] = {
                  item = key,
                  from = from,
                  to = to,
                  buy = src.mv,
                  sell = sell,
                  net = net,
                  gain = gain,
                  sure = sure,
                  upTo = upTo,
                  stack = stack,
                  slots = slots,
                  upToSlots = upToSlots,
                  profit = (net - src.mv) * sure,
                  bought = dst.boughtPerDay,
                  max = math.min(math.ceil(src.mv * 1.1), math.floor(net * 0.75)),
                }
              end
            end
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return a.item < b.item
  end)
  return out
end

--- Puts a gap on the "Blackwater run" shopping list (made when missing): Want = how many (the
--- "sure" amount unless given), max = the gap's max price. Adding the same item again updates it.
---@param g GoldwrightGap
---@param qty number|nil how many (default g.sure)
---@return GoldwrightShoppingList list
function GW.AddGapToList(g, qty)
  local name = GW.L["Blackwater run"]
  local lists = GW.Lists()
  local list, at
  for i, l in ipairs(lists) do
    if l.name == name then
      list, at = l, i
    end
  end
  if not list then
    list = { name = name, entries = {} }
    lists[#lists + 1] = list
    at = #lists
  end
  local entry
  for _, e in ipairs(list.entries) do
    if e.itemID == g.item then entry = e end
  end
  if not entry then
    entry = { itemID = g.item }
    list.entries[#list.entries + 1] = entry
  end
  entry.name = GW.ShopItemName(g.item) or entry.name or string.format(GW.L["item %d"], g.item)
  entry.want = qty or g.sure
  entry.max, entry.maxPct = g.max, nil
  GW.ShopView.OpenList(at)
  return list
end
