--- Your sales record (B1): what you sold, bought, and what came back unsold, from your auction mail.
---
--- * When the mailbox shows its contents, every auction mail is read once without opening or taking
---   it: sale and purchase invoices (GetInboxInvoiceInfo: item, quantity, price, cut) and returned
---   items ("Auction expired: …", "Auction cancelled: …": the game's own subject templates, so it
---   works in every language). Read-only calls: GetInboxNumItems, GetInboxHeaderInfo,
---   GetInboxInvoiceInfo, GetInboxItem.
--- * Kept in GoldwrightDB.ledger, account-wide: events of the last LEDGER_DAYS days, older ones
---   folded into monthly totals so the saved data stays small. Saved as one short line per event
---   (packed at logout, unpacked on first use): a heavy seller's 90 days stay a few MB at most.
---   Buyer names are never read or stored.
--- * A mail already recorded is recognised by the event itself (same kind, item, quantity, price and
---   cut, and nearly the same arrival time), whether it was read here or came from another
---   computer's export: one matching pass per mailbox read.
--- * While you're online, the game's "a buyer has been found" message plays a sound (setting) and
---   counts toward "sold this session". The amounts come later, from the invoice mail.
--- * After new mail is read, one chat line sums it up ("Mailbox: 12 sales for 3g 40s · 4 expired").
local _, GW = ...
local L = GW.L

--- Days of single events kept; older events become monthly totals.
GW.LEDGER_DAYS = 90
--- Auction mail lasts 30 days; a mail's arrival is worked out from its days left. The game may
--- report whole days only, so this is roughly when the mail was first read, not when it arrived.
local MAIL_DAYS = 30
--- Two copies of one mail, read on two computers, are taken to be the same within this time of each
--- other (each computer's time is when it first read the mail).
local SAME_MAIL_SECONDS = 24 * 3600

local pending -- counts read since the last mailbox summary: { sold, net, expired, cancelled, bought, spent }
local byName -- tooltip lookup: item name -> GW.LedgerItems entry; nil = rebuild on next use
local prunedThisSession -- old events were folded into monthly totals this session

--- Event kinds as one letter, in saved lines and exports (upper case = imported from an export).
local KIND_CODE = { sold = "s", bought = "b", expired = "e", cancelled = "c" }
local CODE_KIND = { s = "sold", b = "bought", e = "expired", c = "cancelled" }
--- Limits on pasted text, so a huge or crafted paste can't freeze the game or bloat saved data:
--- enough for a heavy seller's 90 days (27,000 entries are about 1.5 MB).
GW.LEDGER_IMPORT_LIMITS = { chars = 2500000, events = 45000, field = 100 }

--- What an event is, apart from when it arrived.
local function signature(e) return table.concat({ e.kind, e.item, e.qty, e.money or 0, e.cut or 0 }, "|") end
local function byTime(a, b) return a.t < b.t end

--- A name made safe to keep and show: no WoW formatting codes ("|"), no line separators ("^"),
--- no backticks or control characters, at most LEDGER_IMPORT_LIMITS.field characters.
local function safeText(s)
  s = tostring(s or ""):sub(1, GW.LEDGER_IMPORT_LIMITS.field):gsub("[|`%^%c]", "")
  return strtrim(s)
end

--- An event as one line: kind^time^quantity^money^cut^house^character^item.
---@param e GoldwrightLedgerEvent
---@param markImported boolean|nil write the imported mark (saved data), or not (exports)
---@return string
local function lineOf(e, markImported)
  local code = KIND_CODE[e.kind] or "s"
  if markImported and e.imported then code = code:upper() end
  return table.concat({
    code,
    math.floor(e.t),
    e.qty,
    e.money or 0,
    e.cut or 0,
    e.house or "",
    safeText(e.char),
    safeText(e.item),
  }, "^")
end

--- A whole number from text within [lo, hi], else nil.
local function whole(v, lo, hi)
  if type(v) ~= "string" or not v:match("^%d+$") or #v > 15 then return nil end
  local n = tonumber(v)
  return n and n >= lo and n <= hi and n or nil
end

--- One line as an event, or nil when it isn't one.
---@param line string
---@param now number server time (times far from it are refused)
---@return GoldwrightLedgerEvent|nil
local function eventOfLine(line, now)
  local f = {}
  for p in (line .. "^"):gmatch("([^%^]*)%^") do
    f[#f + 1] = p
  end
  local kind = CODE_KIND[(f[1] or ""):lower()]
  local t = whole(f[2], now - 400 * 86400, now + 86400)
  local qty = whole(f[3], 1, 1000000)
  local money = whole(f[4], 0, 10000000 * 10000)
  local cut = whole(f[5], 0, 10000000 * 10000)
  local item = safeText(f[8])
  if not (kind and t and qty and money and cut and item ~= "") then return nil end
  local e = { t = t, kind = kind, item = item, qty = qty }
  if kind == "sold" or kind == "bought" then e.money = money end
  if kind == "sold" then e.cut = math.min(cut, money) end
  if f[6] == "A" or f[6] == "H" or f[6] == "N" then e.house = f[6] end
  local char = safeText(f[7])
  if char ~= "" then e.char = char end
  if f[1] ~= f[1]:lower() then e.imported = true end
  return e
end

--- A sales record event.
---@class GoldwrightLedgerEvent
---@field t number server time (seconds) the mail arrived
---@field kind "sold"|"bought"|"expired"|"cancelled"
---@field item string item name (the client's language)
---@field qty number quantity
---@field money number|nil sold: sale price; bought: price paid (copper)
---@field cut number|nil sold: the auction house cut (copper)
---@field house string|nil "A", "H" or "N" (from the mail's sender)
---@field char string|nil character that got the mail
---@field imported boolean|nil came from another computer's export

--- The record, created on first use; events saved as lines (GW.PackLedger) are unpacked here.
---@return { events: GoldwrightLedgerEvent[], months: table<string, table> }
local function data()
  GoldwrightDB = GoldwrightDB or {}
  local d = GoldwrightDB.ledger or {}
  if d.packed then
    -- Our own lines: one pattern match each (the careful import parser only for a line that
    -- doesn't fit, e.g. edited by hand).
    local events, now = {}, GetServerTime()
    local tonum = tonumber
    for _, line in ipairs(d.packed) do
      local code, t, qty, money, cut, house, char, item =
        line:match("^(%a)%^(%d+)%^(%d+)%^(%d+)%^(%d+)%^([AHN]?)%^([^%^]*)%^(.+)$")
      local kind = code and CODE_KIND[code:lower()]
      local e
      if kind then
        e = { t = tonum(t), kind = kind, item = item, qty = tonum(qty) }
        if kind == "sold" or kind == "bought" then e.money = tonum(money) end
        if kind == "sold" then e.cut = tonum(cut) end
        if house ~= "" then e.house = house end
        if char ~= "" then e.char = char end
        if code ~= code:lower() then e.imported = true end
      else
        e = eventOfLine(line, now)
      end
      if e then events[#events + 1] = e end
    end
    table.sort(events, byTime)
    d.events, d.packed = events, nil
  end
  d.events = d.events or {}
  d.months = d.months or {}
  d.seen = nil -- 0.4.0 kept a mark per mail read; the events themselves tell now
  GoldwrightDB.ledger = d
  -- Old events become monthly totals once per session, when the record is first used (not at
  -- login: unpacking a heavy seller's record takes a moment).
  if not prunedThisSession then
    prunedThisSession = true
    GW.PruneLedger(GetServerTime())
  end
  return d
end

--- Turns the events into one line each for saving (PLAYER_LOGOUT): about a quarter of the size of
--- the tables the game would otherwise write.
function GW.PackLedger()
  local d = GoldwrightDB and GoldwrightDB.ledger
  if not (d and d.events) then return end
  local lines = {}
  for i, e in ipairs(d.events) do
    lines[i] = lineOf(e, true)
  end
  d.packed, d.events = lines, nil
end

--- A Lua pattern from one of the game's message templates with one %s ("Auction expired: %s").
--- Everything around the %s is matched literally; the %s (or %1$s) becomes a capture.
---@param template string|nil
---@return string|nil pattern nil when the template has no %s
function GW.TemplatePattern(template)
  if type(template) ~= "string" then return nil end
  local before, after = template:match("^(.-)%%%d?%$?s(.*)$")
  if not before then return nil end
  local esc = function(s) return (s:gsub("%p", "%%%0")) end
  return "^" .. esc(before) .. "(.+)" .. esc(after) .. "$"
end

--- The patterns of the returned-item mail subjects, by kind.
local function subjectPatterns()
  return {
    expired = GW.TemplatePattern(AUCTION_EXPIRED_MAIL_SUBJECT or "Auction expired: %s"),
    cancelled = GW.TemplatePattern(AUCTION_REMOVED_MAIL_SUBJECT or "Auction cancelled: %s"),
  }
end

--- The month key of a server time, e.g. "2026-11".
local function monthOf(t) return date("%Y-%m", t) end

--- Folds events older than LEDGER_DAYS into monthly totals.
---@param now number server time
function GW.PruneLedger(now)
  local d = data()
  local cutoff = now - GW.LEDGER_DAYS * 86400
  local keep = {}
  for _, e in ipairs(d.events) do
    if e.t >= cutoff then
      keep[#keep + 1] = e
    else
      local m = d.months[monthOf(e.t)] or {}
      if e.kind == "sold" then
        m.sold = (m.sold or 0) + e.qty
        m.net = (m.net or 0) + (e.money or 0) - (e.cut or 0)
      elseif e.kind == "bought" then
        m.bought = (m.bought or 0) + e.qty
        m.spent = (m.spent or 0) + (e.money or 0)
      else
        m.unsold = (m.unsold or 0) + e.qty
      end
      d.months[monthOf(e.t)] = m
    end
  end
  d.events = keep
  byName = nil
end

--- What one mailbox slot holds for the record, or nil for other mail.
---@param i number mailbox index
---@param patterns table subject patterns (subjectPatterns())
---@param now number server time
---@return GoldwrightLedgerEvent|nil
local function eventOf(i, patterns, now)
  local _, _, sender, subject, _, _, daysLeft = GetInboxHeaderInfo(i)
  local t = now - math.max(0, MAIL_DAYS - (tonumber(daysLeft) or MAIL_DAYS)) * 86400
  local invoiceType, itemName, _, bid, _, _, cut, _, _, _, count = GetInboxInvoiceInfo(i)
  if (invoiceType == "seller" or invoiceType == "buyer") and itemName and bid then
    return {
      t = t,
      kind = invoiceType == "seller" and "sold" or "bought",
      item = itemName,
      qty = tonumber(count) or 1,
      money = bid,
      cut = invoiceType == "seller" and (cut or 0) or nil,
      house = GW.MailHouse and GW.MailHouse(sender, true) or nil,
    }
  end
  if type(subject) ~= "string" then return nil end
  for kind, pattern in pairs(patterns) do
    local name = pattern and subject:match(pattern)
    if name then
      -- The returned item itself: retail-style clients give (name, itemID, texture, count), older
      -- ones (name, texture, count).
      local qty = 1
      if GetInboxItem then
        local _, b, c, n4 = GetInboxItem(i, 1)
        qty = tonumber(type(b) == "number" and n4 or c) or 1
      end
      return { t = t, kind = kind, item = name, qty = qty, house = GW.MailHouse and GW.MailHouse(sender, true) }
    end
  end
  return nil
end

--- The mailbox as it was on the current visit (MAIL_SHOW to MAIL_CLOSED): what was there when the
--- visit started and the most of each kind of mail seen since, so the inbox filling up in several
--- steps never makes the same mail look new twice.
local visit

-- Mail the player takes out of the box (or deletes or returns), by kind, until the next read of the
-- visit: the game shows at most 50 mails, so this tells which kind left when one from out of view
-- takes its place (#46). hooksecurefunc runs after the game's own function, while the mail is still
-- in the box; it never changes what the function does.
if hooksecurefunc then
  for _, fn in ipairs({ "TakeInboxMoney", "AutoLootMailItem", "TakeInboxItem", "DeleteInboxItem", "ReturnInboxItem" }) do
    if type(_G[fn]) == "function" then
      hooksecurefunc(fn, function(i)
        if not (visit and visit.taken and type(i) == "number") then return end
        local ok, e = pcall(eventOf, i, subjectPatterns(), GetServerTime())
        if ok and e then visit.taken[#visit.taken + 1] = signature(e) end
      end)
    end
  end
end

--- Which character's mailbox this is (GW.CharacterKey, #46): each character has its own, and keeps it.
---@return string key
---@return string|nil name the character's name, nil when the game doesn't give one
local function mailboxKey() return GW.CharacterKey() end

--- What the mailbox held when it was last read, as signature -> count.
---
--- A character without a record under its key yet (first visit with #46's keys) takes over its older
--- records: "Name-Realm" from before Forever hid the realm, "Name-" from 0.7.3-0.7.5 after it, and
--- "Name~..." from an earlier surname or faction. All of them, the most of each kind of mail any of
--- them held, so no mail that one of them already counted is counted again (#46: 0.7.6 took the
--- stale pre-update record and counted mail twice). Before 0.4.2 nothing was kept: then the events
--- recorded for this character in the last two days stand in for it.
---@param d table the record
---@param key string mailboxKey()
---@param char string|nil character name
---@param now number server time
---@return table<string, number>
local function lastInbox(d, key, char, now)
  if d.inbox[key] then return d.inbox[key] end
  if char then
    local esc = char:gsub("%p", "%%%0")
    local merged, found = {}, false
    for k, snap in pairs(d.inbox) do
      if
        type(k) == "string"
        and type(snap) == "table"
        and (k:match("^" .. esc .. "%-") or k:match("^" .. esc .. "~"))
      then
        found = true
        for s, c in pairs(snap) do
          if c > (merged[s] or 0) then merged[s] = c end
        end
      end
    end
    if found then return merged end
  end
  local counts, from = {}, now - 2 * 86400
  for i = #d.events, 1, -1 do
    local x = d.events[i]
    if x.t < from then break end
    if not x.imported and x.char == char then
      local s = signature(x)
      counts[s] = (counts[s] or 0) + 1
    end
  end
  return counts
end

--- An event imported from another computer that this mail is a copy of (the same mail, read there
--- first), now counted as read here. Times on two computers are each one's own reading time, so the
--- match allows up to SAME_MAIL_SECONDS apart.
---@param d table the record
---@param e GoldwrightLedgerEvent the mail
---@return boolean claimed
local function claimImported(d, e)
  local s = signature(e)
  for i = #d.events, 1, -1 do
    local x = d.events[i]
    if x.t < e.t - SAME_MAIL_SECONDS then break end
    if x.imported and signature(x) == s and math.abs(x.t - e.t) <= SAME_MAIL_SECONDS then
      x.imported = nil -- one mail, one event: it can't stand for another copy
      x.char = x.char or e.char
      return true
    end
  end
  return false
end

--- Reads the mailbox and records auction mail that wasn't in it before. "Before" is what this
--- character's mailbox held the last time it was read (kept in the record), so mail left in the box
--- for days is never counted again, however the game rounds a mail's days left.
---@return number added events added now
function GW.ReadLedgerMail()
  if not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxInvoiceInfo) then return 0 end
  local d, now = data(), GetServerTime()
  d.inbox = d.inbox or {}
  local patterns = subjectPatterns()
  local key, char = mailboxKey()
  local shown, total = GetInboxNumItems()
  shown = shown or 0
  total = math.max(total or shown, shown)
  if not visit or visit.key ~= key then
    visit = { key = key, base = lastInbox(d, key, char, now), seen = {}, gone = {}, taken = {} }
  end
  local events, here = {}, {}
  for i = 1, shown do
    local e = eventOf(i, patterns, now)
    if e then
      events[#events + 1] = e
      local s = signature(e)
      here[s] = (here[s] or 0) + 1
    end
  end
  -- Mail taken out of the box since the last read of this visit (#46). The game shows 50 mails at
  -- most; when one is taken, one from out of view can take its place, so a taken mail can't be told
  -- from the counts alone when both are the same kind. Up to the number the box shrank by: first the
  -- kinds the player took (TakeInboxMoney and the like, watched below), then kinds there are fewer of.
  if visit.last then
    local drop = visit.lastTotal - total
    local took = {}
    for _, s in ipairs(visit.taken) do
      if drop <= 0 then break end
      took[s] = (took[s] or 0) + 1
      drop = drop - 1
    end
    for s, c in pairs(visit.last) do
      local n = math.min(math.max(0, c - (here[s] or 0) - (took[s] or 0)), drop)
      took[s] = (took[s] or 0) + n
      drop = drop - n
    end
    for s, n in pairs(took) do
      if n > 0 then visit.gone[s] = (visit.gone[s] or 0) + n end
    end
  end
  visit.taken = {}
  visit.last, visit.lastTotal = here, total
  -- The n-th mail of a kind is new when the box held fewer than n of that kind before: counting the
  -- ones taken out during this visit, which no longer show.
  local fresh, nth = {}, {}
  for _, e in ipairs(events) do
    local s = signature(e)
    nth[s] = (nth[s] or 0) + 1
    if nth[s] + (visit.gone[s] or 0) > math.max(visit.base[s] or 0, visit.seen[s] or 0) then
      e.char = char
      if claimImported(d, e) then
        byName = nil
      else
        fresh[#fresh + 1] = e
        pending = pending or { sold = 0, net = 0, expired = 0, cancelled = 0, bought = 0, spent = 0 }
        if e.kind == "sold" then
          pending.sold = pending.sold + 1
          pending.net = pending.net + e.money - (e.cut or 0)
        elseif e.kind == "bought" then
          pending.bought = pending.bought + 1
          pending.spent = pending.spent + e.money
        else
          pending[e.kind] = pending[e.kind] + 1
        end
      end
    end
  end
  for s, c in pairs(here) do
    c = c + (visit.gone[s] or 0)
    if c > (visit.seen[s] or 0) then visit.seen[s] = c end
  end
  -- What the box holds now, for the next visit: exactly, unless it holds more than it shows (then
  -- mail out of view is still there, so nothing is forgotten until the box fits on screen again;
  -- less what was taken out during this visit).
  local snapshot = {}
  for s, c in pairs(here) do
    snapshot[s] = c
  end
  if total > shown then
    for s, c in pairs(visit.base) do
      c = c - (visit.gone[s] or 0)
      if (snapshot[s] or 0) < c then snapshot[s] = c end
    end
  end
  d.inbox[key] = snapshot
  if #fresh > 0 then
    -- New mail is recent: each goes into its place near the end, without sorting the whole record.
    table.sort(fresh, byTime)
    local events = d.events
    for _, e in ipairs(fresh) do
      local pos = #events
      while pos >= 1 and events[pos].t > e.t do
        pos = pos - 1
      end
      table.insert(events, pos + 1, e)
    end
    byName = nil
    if d.events[1].t < now - GW.LEDGER_DAYS * 86400 then GW.PruneLedger(now) end
    GW.Log("ledger: %d new auction mail(s)", #fresh)
    if GW.OnLedgerChanged then GW.OnLedgerChanged() end
  end
  return #fresh
end

--- The mailbox summary line for what was read since the last one, or nil when nothing new.
---@return string|nil
function GW.MailSummaryText()
  local p = pending
  if not p then return nil end
  local parts = {}
  if p.sold > 0 then parts[#parts + 1] = GW.Plural(p.sold, "%d sale for %s", "%d sales for %s", GW.Money(p.net)) end
  if p.expired > 0 then parts[#parts + 1] = GW.Plural(p.expired, "%d expired", "%d expired") end
  if p.cancelled > 0 then parts[#parts + 1] = GW.Plural(p.cancelled, "%d cancelled", "%d cancelled") end
  if p.bought > 0 then
    parts[#parts + 1] = GW.Plural(p.bought, "%d bought for %s", "%d bought for %s", GW.Money(p.spent))
  end
  return string.format(L["Mailbox: %s"], table.concat(parts, " · "))
end

--- Prints the mailbox summary (setting "mailSummary") and starts a new one.
function GW.PrintMailSummary()
  local text = GW.MailSummaryText()
  pending = nil
  if text and GW.Opt("mailSummary") then GW.Print("%s", text) end
end

---------------------------------------------------------------------------
-- Export and merge (another computer has its own record: WoW keeps add-on data per computer)
---------------------------------------------------------------------------

--- First line of an export; the format may change with the number.
local EXPORT_HEADER = "GWSALES1"

--- The record as text to copy to another computer: a header line, then one event per line
--- (kind^time^quantity^money^cut^house^character^item), for the last `days` (all kept when nil).
---@param days number|nil
---@return string text
---@return number count events in it
function GW.ExportLedger(days)
  local lines = { EXPORT_HEADER }
  local from = days and GetServerTime() - days * 86400 or 0
  for _, e in ipairs(data().events) do
    if e.t >= from then lines[#lines + 1] = lineOf(e) end
  end
  return table.concat(lines, "\n"), #lines - 1
end

--- Merges an export from another computer: events this record already has (the same mail, read on
--- both computers) are skipped, the rest are added. Events older than LEDGER_DAYS are left out:
--- older months are kept as totals on each computer and can't be merged without counting twice.
---@param text string|nil
---@return number added
---@return number skipped already in the record
---@return string|nil problem why the text was refused, or what was left out
function GW.ImportLedger(text)
  local lim = GW.LEDGER_IMPORT_LIMITS
  text = text or ""
  if #text > lim.chars then return 0, 0, L["That text is too long to be a sales export."] end
  local first = text:match("^%s*([^\r\n]*)")
  if strtrim(first or "") ~= EXPORT_HEADER then
    return 0, 0, L["That isn't a Goldwright sales export. Use Export on the other computer and paste all of it."]
  end
  local d, now = data(), GetServerTime()
  local cutoff = now - GW.LEDGER_DAYS * 86400
  -- Events already here, by signature, each usable once as the match for one imported event.
  local here = {}
  for _, e in ipairs(d.events) do
    local s = signature(e)
    here[s] = here[s] or {}
    table.insert(here[s], { t = e.t })
  end
  local added, skipped, bad, old, n = 0, 0, 0, 0, 0
  for line in text:gmatch("[^\r\n]+") do
    if strtrim(line) ~= EXPORT_HEADER then
      n = n + 1
      if n > lim.events then break end
      local e = eventOfLine(strtrim(line), now)
      if not e then
        bad = bad + 1
      elseif e.t < cutoff then
        old = old + 1
      else
        local s = signature(e)
        local match
        for _, x in ipairs(here[s] or {}) do
          if not x.used and math.abs(x.t - e.t) <= SAME_MAIL_SECONDS then
            match = x
            break
          end
        end
        if match then
          match.used = true
          skipped = skipped + 1
        else
          e.imported = true
          d.events[#d.events + 1] = e
          here[s] = here[s] or {}
          table.insert(here[s], { t = e.t, used = true }) -- a second identical line is a second sale
          added = added + 1
        end
      end
    end
  end
  if added > 0 then
    table.sort(d.events, byTime)
    byName = nil
    GW.Log("ledger: imported %d, skipped %d already here", added, skipped)
    if GW.OnLedgerChanged then GW.OnLedgerChanged() end
  end
  local problem
  if n > lim.events then
    problem = L["Only the first part was read: the text has too many entries."]
  elseif bad > 0 then
    problem = L["Some lines couldn't be read and were left out."]
  elseif old > 0 then
    problem = string.format(L["Entries older than %d days were left out."], GW.LEDGER_DAYS)
  end
  return added, skipped, problem
end

---------------------------------------------------------------------------
-- Reading the record
---------------------------------------------------------------------------

--- Events since a number of days ago (all kept events when days is nil).
---@param days number|nil
---@return GoldwrightLedgerEvent[]
function GW.LedgerEvents(days)
  local events = data().events
  if not days then return events end
  local from, out = GetServerTime() - days * 86400, {}
  for _, e in ipairs(events) do
    if e.t >= from then out[#out + 1] = e end
  end
  return out
end

--- Totals over the last `days`.
---@param days number|nil
---@return { sold: number, sales: number, net: number, cut: number, bought: number, spent: number, unsold: number }
function GW.LedgerTotals(days)
  local s = { sold = 0, sales = 0, net = 0, cut = 0, bought = 0, spent = 0, unsold = 0 }
  for _, e in ipairs(GW.LedgerEvents(days)) do
    if e.kind == "sold" then
      s.sold, s.sales = s.sold + e.qty, s.sales + 1
      s.net, s.cut = s.net + e.money - (e.cut or 0), s.cut + (e.cut or 0)
    elseif e.kind == "bought" then
      s.bought, s.spent = s.bought + e.qty, s.spent + e.money
    else
      s.unsold = s.unsold + e.qty
    end
  end
  return s
end

--- Per item over the last `days`: sold, earned after the cut, units back unsold, times back unsold,
--- the last unit price and how much of what came back or sold did sell.
---@param days number|nil
---@return table[] items { item, sold, net, unsold, returns, lastUnit, lastAt, rate } sorted by earned
function GW.LedgerItems(days)
  local by, list = {}, {}
  for _, e in ipairs(GW.LedgerEvents(days)) do
    if e.kind ~= "bought" then
      local x = by[e.item]
      if not x then
        x = { item = e.item, sold = 0, net = 0, unsold = 0, returns = 0 }
        by[e.item] = x
        list[#list + 1] = x
      end
      if e.kind == "sold" then
        x.sold, x.net = x.sold + e.qty, x.net + e.money - (e.cut or 0)
        if not x.lastAt or e.t >= x.lastAt then
          x.lastAt, x.lastUnit = e.t, e.money / math.max(1, e.qty)
        end
      else
        x.unsold, x.returns = x.unsold + e.qty, x.returns + 1
      end
    end
  end
  for _, x in ipairs(list) do
    x.rate = x.sold / math.max(1, x.sold + x.unsold)
  end
  table.sort(list, function(a, b)
    if a.net ~= b.net then return a.net > b.net end
    return a.item < b.item
  end)
  return list
end

--- What you sold or tried to sell of an item in the last LEDGER_DAYS days, for the tooltip, or nil.
---@param name string|nil item name
---@return { sold: number, unsold: number, returns: number, lastUnit: number }|nil
function GW.LedgerTooltipInfo(name)
  if not name then return nil end
  if not byName then
    -- Built in a local first: reading the record can tidy it (GW.PruneLedger), which clears byName.
    local items, built = GW.LedgerItems(nil), {}
    for _, x in ipairs(items) do
      built[x.item] = x
    end
    byName = built
  end
  return byName[name]
end

--- Your sales of one item at one house, per day (UTC midnight -> units and money before the cut),
--- for the Sell tab's price history. A sale's time is when its mail was read, so it is right to
--- the day at best. Sales whose house is unknown count for every house.
---@param name string|nil item name (the client's language)
---@param house string "A", "H" or "N"
---@return table<number, { qty: number, money: number }>
function GW.LedgerSalesByDay(name, house)
  local out = {}
  if not name then return out end
  for _, e in ipairs(GW.LedgerEvents(nil)) do
    if e.kind == "sold" and e.item == name and (e.house == nil or e.house == house) then
      local day = e.t - e.t % 86400
      local x = out[day] or { qty = 0, money = 0 }
      x.qty, x.money = x.qty + e.qty, x.money + (e.money or 0)
      out[day] = x
    end
  end
  return out
end

--- Monthly totals of events older than LEDGER_DAYS, newest month first.
---@return { month: string, sold: number, net: number, bought: number, spent: number, unsold: number }[]
function GW.LedgerMonths()
  local out = {}
  for month, m in pairs(data().months) do
    out[#out + 1] = {
      month = month,
      sold = m.sold or 0,
      net = m.net or 0,
      bought = m.bought or 0,
      spent = m.spent or 0,
      unsold = m.unsold or 0,
    }
  end
  table.sort(out, function(a, b) return a.month > b.month end)
  return out
end

---------------------------------------------------------------------------
-- Sold this session (the game's sale message)
---------------------------------------------------------------------------
GW.session = { sold = 0 }

--- Handles one system chat message: a sale plays the sound and counts.
---@param msg string|nil
---@return boolean sold the message was a sale
function GW.OnSaleMessage(msg)
  if not GW.ReadableText(msg) then return false end
  local pattern = GW.TemplatePattern(ERR_AUCTION_SOLD_S or "A buyer has been found for your auction of %s.")
  -- pcall as well: a protected message the check above can't recognise is skipped, not an error.
  local ok, hit = pcall(string.match, msg, pattern or "")
  if not pattern or not ok or not hit then return false end
  GW.session.sold = GW.session.sold + 1
  if GW.Opt("saleSound") and PlaySound then
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.AUCTION_WINDOW_CLOSE or 5275, "Master")
  end
  if GW.OnLedgerChanged then GW.OnLedgerChanged() end
  return true
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "MAIL_INBOX_UPDATE", "MAIL_CLOSED", "CHAT_MSG_SYSTEM", "PLAYER_LOGOUT" }) do
  pcall(ev.RegisterEvent, ev, e)
end
local summaryTimer
ev:SetScript("OnEvent", function(_, event, msg)
  if event == "CHAT_MSG_SYSTEM" then
    GW.OnSaleMessage(msg)
  elseif event == "PLAYER_LOGOUT" then
    GW.PackLedger() -- the game writes saved data right after this (logout and /reload)
  elseif event == "MAIL_CLOSED" then
    visit = nil -- the next mailbox visit starts from what the box held at the end of this one
    GW.PrintMailSummary()
  elseif GW.ReadLedgerMail() > 0 and not summaryTimer and C_Timer then
    -- The inbox updates several times while it fills: one summary a moment after the last one.
    summaryTimer = true
    C_Timer.After(2, function()
      summaryTimer = nil
      GW.PrintMailSummary()
    end)
  end
end)
