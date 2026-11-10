-- Pricing rules: the Lua twin of server/src/pricing.mjs (keep them identical).
local _, GW = ...

GW.RULES = {
  depthShare = 0.05,
  minDepthUnits = 5,
  baitGap = 0.3,
  baitMaxShare = 0.01,
  baitMinUnits = 3,
}

-- listings: array of { price = unitCopper, qty = n, own = bool }
-- returns { mv, minReal, units, baitUnits, baitPrice, firstRealIndex, sorted } or nil
function GW.MarketStats(listings)
  local R = GW.RULES
  local l = {}
  for _, x in ipairs(listings) do
    if x.price and x.price > 0 and x.qty and x.qty > 0 then l[#l + 1] = x end
  end
  table.sort(l, function(a, b) return a.price < b.price end)
  local units = 0
  for _, x in ipairs(l) do units = units + x.qty end
  if units == 0 then return nil end

  if units < R.minDepthUnits then
    return { mv = l[1].price, minReal = l[1].price, units = units, baitUnits = 0, baitPrice = 0, firstRealIndex = 1, sorted = l }
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
