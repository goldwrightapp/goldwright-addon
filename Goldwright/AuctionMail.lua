--- The auction house cut, measured: when the mailbox opens, Goldwright reads the invoices of sold
--- auctions (GetInboxInvoiceInfo: sale total and "Auction House Cut") without opening or taking the
--- mail, learns each house's real rate, and uses it everywhere prices are netted (GW.CUT, GW.Net).
---
--- Which house: from the mail's sender ("Alliance Auction House", "Horde Auction House", Blackwater's),
--- by the faction name in the client's language (GW.MailHouse), so it works on every client.
--- Rate: the percentage (in 0.5% steps) that explains the most invoices, since the game rounds each
--- cut down to whole copper (86c at 5% is a 4c cut). Stored in GoldwrightDB.ahCut; buyer names are
--- never read or stored. Read-only calls: GetInboxNumItems, GetInboxHeaderInfo, GetInboxInvoiceInfo.
local _, GW = ...
local L = GW.L

--- The assumed cuts, before any sale is measured (Core.lua's GW.CUT at load).
GW.CUT_ASSUMED = { A = GW.CUT.A, H = GW.CUT.H, N = GW.CUT.N }
--- Invoices kept per house for the estimate.
local MAX_SALES = 50
--- Smallest sale that counts, in copper: from 2s a 1c rounding error moves the rate by at most 0.5%
--- (a 10c sale with a 1c cut would fit anything from 10% to 19%).
GW.CUT_MIN_SALE = 200

--- A faction name without its last letter when it has 4 or more, so a grammatical ending in the
--- sender still matches ("Орда" in "Аукционный дом Орды"); short names (Korean, Chinese) stay whole.
---@param name string|nil e.g. "Horde", "Allianz", "部落"
---@return string|nil
local function stem(name)
  if type(name) ~= "string" or name == "" then return nil end
  local chars = {}
  for ch in name:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chars[#chars + 1] = ch
  end
  if #chars < 4 then return name end
  return table.concat(chars, "", 1, #chars - 1)
end

--- The house of an auction house mail, from its sender. Works in every client language: the sender
--- is the house's name ("Alliance Auction House", "Auktionshaus der Allianz", "얼라이언스 경매장"),
--- which holds the faction's name in the client's language (FACTION_ALLIANCE, FACTION_HORDE); an
--- auction mail naming neither faction is Blackwater's.
---@param sender string|nil e.g. "Alliance Auction House"
---@param isAuction boolean|nil true when the mail is known to come from an auction house (it has an
---  invoice); otherwise only English auction house senders count
---@return string|nil side "A", "H" or "N"; nil for other mail
function GW.MailHouse(sender, isAuction)
  if type(sender) ~= "string" or sender == "" then return nil end
  if not isAuction and not sender:find("Auction House", 1, true) then return nil end
  if sender:find("Blackwater", 1, true) or sender:find("Neutral", 1, true) then return "N" end
  local names = { A = { "Alliance", FACTION_ALLIANCE }, H = { "Horde", FACTION_HORDE } }
  for _, side in ipairs({ "A", "H" }) do
    for _, name in ipairs(names[side]) do
      local s = stem(name)
      if s and sender:find(s, 1, true) then return side end
    end
  end
  return "N"
end

--- The cut rate that best explains a house's sales: the 0.5% step whose rounded-down cuts match the
--- most invoices (exactly, or off by a copper); ties prefer whole percents, then the plain average.
---@param sales { bid: number, cut: number }[]
---@return number|nil rate e.g. 0.05; nil without sales
function GW.CutRate(sales)
  if not sales or #sales == 0 then return nil end
  local sumBid, sumCut = 0, 0
  for _, s in ipairs(sales) do
    sumBid, sumCut = sumBid + s.bid, sumCut + s.cut
  end
  local avg = sumCut / sumBid
  local best, bestScore, bestWhole, bestDist
  for step = 1, 60 do -- 0.5% .. 30%
    local r = step / 200
    -- An exact match (the cut rounded down) counts 2, off by a copper 1.
    local score = 0
    for _, s in ipairs(sales) do
      local off = math.abs(math.floor(s.bid * r) - s.cut)
      score = score + (off == 0 and 2 or off == 1 and 1 or 0)
    end
    -- Ties: whole percentages first (cuts are set in whole percent), then the closest to the average.
    local whole = step % 2 == 0
    local dist = math.abs(r - avg)
    local better = not best
      or score > bestScore
      or (score == bestScore and whole and not bestWhole)
      or (score == bestScore and whole == bestWhole and dist < bestDist)
    if better then
      best, bestScore, bestWhole, bestDist = r, score, whole, dist
    end
  end
  return best
end

--- The learned data, created on first use.
---@return { seen: table<string, boolean>, sales: table<string, { bid: number, cut: number }[]> } data
local function data()
  GoldwrightDB = GoldwrightDB or {}
  local d = GoldwrightDB.ahCut or {}
  d.seen = d.seen or {}
  d.sales = d.sales or {}
  GoldwrightDB.ahCut = d
  return d
end

--- Applies the measured rates to GW.CUT (houses without sales keep the assumed rate).
function GW.ApplyMeasuredCuts()
  local sales = GoldwrightDB and GoldwrightDB.ahCut and GoldwrightDB.ahCut.sales or {}
  for side, assumed in pairs(GW.CUT_ASSUMED) do
    GW.CUT[side] = GW.CutRate(sales[side]) or assumed
  end
end

--- Reads the sale invoices in the mailbox and learns from the new ones.
---@return number added invoices learned now
function GW.LearnFromMail()
  if not (GetInboxNumItems and GetInboxInvoiceInfo and GetInboxHeaderInfo) then return 0 end
  local d, added = data(), 0
  for i = 1, GetInboxNumItems() or 0 do
    local invoiceType, itemName, _, bid, _, deposit, cut = GetInboxInvoiceInfo(i)
    if invoiceType == "seller" and (bid or 0) >= GW.CUT_MIN_SALE and cut then
      local _, _, sender, subject = GetInboxHeaderInfo(i)
      local side = GW.MailHouse(sender, true) -- a seller invoice: it is auction house mail
      -- One key per sale (the money in the mail drops to 0 once taken, so it is left out).
      local key = table.concat({ tostring(sender), tostring(subject), tostring(itemName), bid, cut, deposit or 0 }, "|")
      if side and not d.seen[key] then
        d.seen[key] = true
        local list = d.sales[side] or {}
        list[#list + 1] = { bid = bid, cut = cut }
        while #list > MAX_SALES do
          table.remove(list, 1)
        end
        d.sales[side] = list
        added = added + 1
      end
    end
  end
  if added > 0 then
    GW.ApplyMeasuredCuts()
    GW.Log("mail: learned %d sale invoice(s); cuts A=%s H=%s N=%s", added, GW.CUT.A, GW.CUT.H, GW.CUT.N)
  end
  return added
end

--- One line about the cuts, e.g. "Alliance 5% (3 sales) · Horde 5% (assumed) · Blackwater 15% (assumed)".
---@return string text
function GW.CutText()
  local sales = GoldwrightDB and GoldwrightDB.ahCut and GoldwrightDB.ahCut.sales or {}
  local parts = {}
  for _, side in ipairs({ "A", "H", "N" }) do
    local n = sales[side] and #sales[side] or 0
    local pct = (GW.CUT[side] or 0) * 100
    parts[#parts + 1] = string.format(
      "%s %s%% (%s)",
      GW.HOUSE_NAMES[side],
      pct == math.floor(pct) and string.format("%d", pct) or string.format("%.1f", pct),
      n > 0 and GW.Plural(n, "%d sale", "%d sales") or L["assumed"]
    )
  end
  return table.concat(parts, " · ")
end

local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "MAIL_INBOX_UPDATE")
pcall(ev.RegisterEvent, ev, "PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    GW.ApplyMeasuredCuts() -- what earlier sessions learned
  else
    GW.LearnFromMail()
  end
end)
