--- Pricing rules: market value, cheapest real listing and bait detection from a list of listings.
--- The Lua twin of server/src/pricing.mjs (keep them identical).
local _, GW = ...

--- Pricing rule constants. GW.ApplyOptions overwrites the bait fields from the settings.
---@class GoldwrightRules
---@field depthShare number market value = price reached after this share of all listed units
---@field minDepthUnits number at least this many units deep; fewer listed = the cheapest price
---@field baitGap number listings this far (share) below market value can be bait
---@field baitMaxShare number bait holds at most this share of all units...
---@field baitMinUnits number ...or at most this many units, whichever is more
---@field bait boolean|nil false turns bait detection off (set from the settings)
GW.RULES = {
  depthShare = 0.05,
  minDepthUnits = 5,
  baitGap = 0.3,
  baitMaxShare = 0.01,
  baitMinUnits = 3,
}

--- One auction listing as GW.MarketStats reads it.
---@class GoldwrightListing
---@field price number unit price in copper
---@field qty number units
---@field own boolean|nil the player's own listing

--- Market numbers for one item's listings, as GW.MarketStats returns them.
---@class GoldwrightMarketStats
---@field mv number market value per unit (copper)
---@field minReal number cheapest listing that isn't bait
---@field units number units listed
---@field baitUnits number units in the bait listings (0 = no bait)
---@field baitPrice number cheapest bait price (0 = no bait)
---@field firstRealIndex number index in `sorted` of the first listing that isn't bait
---@field sorted GoldwrightListing[] the valid listings, cheapest first

--- Computes market value, the cheapest real price and bait listings: the market value is the
--- price reached after `depthShare` of all units (at least `minDepthUnits`); a few cheap units
--- far below it count as bait and are skipped for the cheapest real price.
---@param listings GoldwrightListing[] listings in any order (no price or no quantity = ignored)
---@return GoldwrightMarketStats|nil stats nil when nothing is listed
function GW.MarketStats(listings)
  local R = GW.RULES
  local l = {}
  for _, x in ipairs(listings) do
    if x.price and x.price > 0 and x.qty and x.qty > 0 then l[#l + 1] = x end
  end
  table.sort(l, function(a, b) return a.price < b.price end)
  local units = 0
  for _, x in ipairs(l) do
    units = units + x.qty
  end
  if units == 0 then return nil end

  -- Too few units for a depth rule: the cheapest listing is the market value, nothing is bait.
  if units < R.minDepthUnits then
    return {
      mv = l[1].price,
      minReal = l[1].price,
      units = units,
      baitUnits = 0,
      baitPrice = 0,
      firstRealIndex = 1,
      sorted = l,
    }
  end

  local target = math.max(R.minDepthUnits, math.ceil(units * R.depthShare))
  local cum, mv = 0, l[#l].price
  for _, x in ipairs(l) do
    cum = cum + x.qty
    if cum >= target then
      mv = x.price
      break
    end
  end

  -- Listings more than baitGap under the market value are bait when they hold only a few units.
  local i, thin = 1, 0
  while i <= #l and l[i].price < mv * (1 - R.baitGap) do
    thin = thin + l[i].qty
    i = i + 1
  end
  local isBait = R.bait ~= false and i > 1 and thin <= math.max(R.baitMinUnits, units * R.baitMaxShare)
  return {
    mv = mv,
    minReal = isBait and l[i].price or l[1].price,
    units = units,
    baitUnits = isBait and thin or 0,
    baitPrice = isBait and l[1].price or 0,
    firstRealIndex = isBait and i or 1,
    sorted = l,
  }
end
