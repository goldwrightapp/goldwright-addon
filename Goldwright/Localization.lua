--- Translations. Every text Goldwright shows a player goes through GW.L, keyed by its English text:
---
---   local L = GW.L
---   label:SetText(L["Market value"])
---   GW.Print(L["Posted %d of %s."], n, name)       -- format strings keep their placeholders
---   L["%d sale|%d sales"]                           -- not like this: plurals go through GW.Plural
---   GW.Plural(n, "%d sale", "%d sales")             -- the right form for the client's language
---
--- A text with no translation shows in English, so a missing line never breaks anything. The
--- translations live in Locale_<code>.lua (one file per WoW client language, loaded before Core.lua;
--- only the client's own is kept). Bug reports, the debug log and diagnostics stay in English: they
--- are read by us. Rules for writing and translating texts: docs/product/localization.md.
local _, GW = ...

--- The client's language, e.g. "enUS", "deDE", "zhTW".
GW.LOCALE = GetLocale and GetLocale() or "enUS"
if GW.LOCALE == "enGB" then GW.LOCALE = "enUS" end

--- Translated text by English text; unknown keys return the English text itself.
GW.L = setmetatable({}, {
  __index = function(_, key) return key end,
})

--- Adds translations for one language (called by the Locale_<code>.lua files).
---@param locale string|string[] the client language(s) these are for, e.g. "deDE" or { "esES", "esMX" }
---@param texts table<string, string> English text -> translated text
function GW.Translate(locale, texts)
  local codes = type(locale) == "table" and locale or { locale }
  for _, code in ipairs(codes) do
    if code == GW.LOCALE then
      for en, tr in pairs(texts) do
        if type(tr) == "string" and tr ~= "" then rawset(GW.L, en, tr) end
      end
      return
    end
  end
end

--- Which plural form a number takes, per language: 1-based index into the forms of a translation.
--- English, German, Spanish, Italian: 1 = one, 2 = other. French and Portuguese (Brazil) also count
--- 0 as one. Russian: one / few / many. Korean and Chinese have one form.
local PLURAL_RULES = {
  frFR = function(n) return n <= 1 and 1 or 2 end,
  ptBR = function(n) return n <= 1 and 1 or 2 end,
  ruRU = function(n)
    local m10, m100 = n % 10, n % 100
    if m10 == 1 and m100 ~= 11 then return 1 end
    if m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14) then return 2 end
    return 3
  end,
  koKR = function() return 1 end,
  zhCN = function() return 1 end,
  zhTW = function() return 1 end,
}
local function englishRule(n) return n == 1 and 1 or 2 end

--- The form of a text that fits a count, translated: GW.Plural(3, "%d sale", "%d sales") -> "3 sales".
--- The translation of the key "one|other" lists the language's own forms separated by "|"
--- (Russian three, Korean and Chinese one); the count is passed to string.format when the chosen
--- form has a placeholder.
---@param n number the count
---@param one string English singular, e.g. "%d sale" or "sale"
---@param other string English plural, e.g. "%d sales" or "sales"
---@param ... any extra string.format arguments after the count
---@return string
function GW.Plural(n, one, other, ...)
  local key = one .. "|" .. other
  local forms = {}
  for form in (rawget(GW.L, key) or key):gmatch("[^|]+") do
    forms[#forms + 1] = form
  end
  local rule = rawget(GW.L, key) and PLURAL_RULES[GW.LOCALE] or englishRule
  local count = math.abs(math.floor(tonumber(n) or 0))
  local form = forms[math.min(rule(count), #forms)] or forms[#forms] or other
  if form:find("%", 1, true) then return string.format(form, n, ...) end
  return form
end
