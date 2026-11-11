--- Items vendors sell: the built-in profession supplies (VendorSupplies.lua, generated from the
--- Battle.net item API) plus what the player's own merchant visits taught us. The Crafting panel
--- costs these materials at the vendor price instead of the auction house (thread, dye, salt ...).
---
--- Learning: on MERCHANT_SHOW the merchant's list is read with read-only calls (GetMerchantNumItems,
--- GetMerchantItemInfo, GetMerchantItemLink, GetMerchantItemCostInfo). Only items in unlimited supply
--- for gold alone count (no limited stock, no tokens or currencies). The price is what this character
--- pays, reputation discounts included, per unit of the vendor's stack. Stored in
--- GoldwrightDB.vendorPrices; a learned price wins over the built-in one.
local _, GW = ...

--- The learned prices, created on first use.
---@return table<number, number> prices item id -> copper per unit
local function learned()
  GoldwrightDB = GoldwrightDB or {}
  GoldwrightDB.vendorPrices = GoldwrightDB.vendorPrices or {}
  return GoldwrightDB.vendorPrices
end

--- What a vendor sells an item for, per unit.
---@param itemID number|nil
---@return number|nil copper nil when no vendor we know of sells it
function GW.VendorSellsFor(itemID)
  if not itemID then return nil end
  local seen = GoldwrightDB and GoldwrightDB.vendorPrices and GoldwrightDB.vendorPrices[itemID]
  return seen or (GW.VENDOR_SUPPLIES and GW.VENDOR_SUPPLIES[itemID]) or nil
end

--- Reads the open merchant's list and remembers the items it sells in unlimited supply for gold.
---@return number count items remembered
function GW.LearnMerchant()
  if not (GetMerchantNumItems and GetMerchantItemInfo and GetMerchantItemLink) then return 0 end
  local prices, count = learned(), 0
  for i = 1, GetMerchantNumItems() or 0 do
    -- price and stack size are the 3rd and 4th values, numAvailable the 5th (-1 = unlimited), in both
    -- the Classic and the modern merchant API.
    local _, _, price, quantity, numAvailable = GetMerchantItemInfo(i)
    local link = GetMerchantItemLink(i)
    local id = link and tonumber(link:match("item:(%d+)"))
    local costItems = GetMerchantItemCostInfo and GetMerchantItemCostInfo(i) or 0
    if id and price and price > 0 and numAvailable == -1 and costItems == 0 then
      prices[id] = math.ceil(price / math.max(1, quantity or 1))
      count = count + 1
    end
  end
  return count
end

local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "MERCHANT_SHOW")
ev:SetScript("OnEvent", function()
  -- The list can still be loading on the first frame; read it a moment later too.
  GW.LearnMerchant()
  C_Timer.After(0.5, GW.LearnMerchant)
end)
