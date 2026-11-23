--- @file Which ruleset the player's character is on: Normal, PvP, Roleplay or Roleplay PvP
--- (goldwright-addon #28). Since Forever 1.60.1 "Live Update 2" (client build 71037, 2026-11-20)
--- the game hides the realm's name and ID from add-ons, against layer hopping, and the ruleset used
--- to come from the realm's name. The game's own rules still say it, instantly (C_GameRules; seen
--- in game 2026-11-22, and AceDB-3.0 reads them the same way).
---
--- GW.DetermineRuleset, in order:
--- 1. Settings › Ruleset, the player's own override ("settings");
--- 2. the game's rules ("rules");
--- 3. this character's answer to the ruleset popup, in case a later patch hides the rules too
---    ("chosen");
--- 4. Normal ("default"): GW.CheckHouse (Core.lua) then says so and shows the popup once.
local _, GW = ...
local L = GW.L

--- This character's key for what Goldwright remembers per character (the ruleset popup's answer,
--- the Buy tab's recent lookups): "US/Bomo".
---@param region? string (default: the player's)
---@return string|nil
function GW.CharKey(region)
  local name = UnitName and UnitName("player")
  region = region or (GW.House and GW.House().region) or "US"
  return name and name ~= "" and (region .. "/" .. name) or nil
end
local charKey = GW.CharKey

--- The ruleset from the game's rules (C_GameRules). Neither PvP nor RP active is Normal. nil when
--- the rules aren't there, or on Hardcore (Goldwright has no Hardcore data yet).
---@return string|nil ruleset
function GW.GameRulesRuleset()
  local rules = Enum and Enum.GameRule
  if not (C_GameRules and C_GameRules.IsGameRuleActive and rules and rules.PvPRuleset and rules.RPRuleset) then
    return nil
  end
  local function active(rule)
    if rule == nil then return false end
    local ok, on = pcall(C_GameRules.IsGameRuleActive, rule)
    return ok and on == true
  end
  if active(rules.HardcoreRuleset) then return nil end
  local pvp, rp = active(rules.PvPRuleset), active(rules.RPRuleset)
  if rp and pvp then return "Roleplay PvP" end
  if rp then return "Roleplay" end
  if pvp then return "PvP" end
  return "Normal"
end

--- The ruleset for this character, and where it came from.
---@param region string "US", "EU", ...
---@return string ruleset "Normal", "PvP", "Roleplay" or "Roleplay PvP"
---@return string from "settings", "rules", "chosen" or "default"
function GW.DetermineRuleset(region)
  local override = GoldwrightDB and GoldwrightDB.rulesetOverride
  if override then return override, "settings" end
  local rules = GW.GameRulesRuleset()
  if rules then return rules, "rules" end
  local key = charKey(region)
  local chosen = key and GoldwrightDB and GoldwrightDB.charRulesets and GoldwrightDB.charRulesets[key]
  if chosen then return chosen, "chosen" end
  return "Normal", "default"
end

--- Saves this character's answer to the popup and switches to its data pack at once.
---@param ruleset string
function GW.SetCharacterRuleset(ruleset)
  local key = charKey(GW.House().region)
  if not (key and GoldwrightDB) then return end
  GoldwrightDB.charRulesets = GoldwrightDB.charRulesets or {}
  GoldwrightDB.charRulesets[key] = ruleset
  GW.ReloadPack()
  GW.ApplyOptions()
  if not GW.pack then GW.PrintPackProblem() end
end

--- Whether this character was already asked (the popup shows once).
---@return boolean
function GW.RulesetAsked()
  local key = charKey(GW.House().region)
  return not key or (GoldwrightDB and GoldwrightDB.rulesetAsked and GoldwrightDB.rulesetAsked[key]) == true
end

--- Marks this character as asked.
function GW.MarkRulesetAsked()
  local key = charKey(GW.House().region)
  if not (key and GoldwrightDB) then return end
  GoldwrightDB.rulesetAsked = GoldwrightDB.rulesetAsked or {}
  GoldwrightDB.rulesetAsked[key] = true
end

---------------------------------------------------------------------------
-- The popup: only when the game's rules don't answer (a future client could hide them too)
---------------------------------------------------------------------------
local popup
local W = 470

--- Saves a choice from the popup and closes it.
---@param ruleset string
local function choose(ruleset)
  GW.MarkRulesetAsked()
  if popup then popup:Hide() end
  GW.SetCharacterRuleset(ruleset)
  GW.Print(L["Using %s %s prices for this character."], GW.House().region, ruleset)
end

--- Builds the popup.
local function create()
  local UI = GW.UI
  popup = UI.Window("GoldwrightRulesetPopup", W, 150, { title = "Goldwright", strata = "DIALOG", movable = true })
  popup:SetPoint("CENTER", 0, 120)
  local lead = UI.Text(popup, "GameFontHighlight", "text", "LEFT")
  lead:SetPoint("TOPLEFT", 20, -36)
  lead:SetWidth(W - 40)
  lead:SetText(L["Goldwright can't tell which realm type you play on."])
  local body = UI.Text(popup, "GameFontHighlightSmall", "muted", "LEFT")
  body:SetPoint("TOPLEFT", lead, "BOTTOMLEFT", 0, -8)
  body:SetWidth(W - 40)
  body:SetText(L["Blizzard now hides it from add-ons. Pick yours so prices come from the right auction house:"])
  popup.buttons = {}
  local x = 20
  for _, o in ipairs({
    { "Normal", L["Normal"] },
    { "PvP", L["PvP"] },
    { "Roleplay", L["RP"] },
    { "Roleplay PvP", L["RP-PvP"] },
  }) do
    local b = UI.Button(popup, o[2], 100, 24, function() choose(o[1]) end)
    b:SetPoint("TOPLEFT", x, -102)
    b.ruleset = o[1]
    popup.buttons[#popup.buttons + 1] = b
    x = x + 108
  end
  -- Closing it without a choice counts as asked: the chat line at login keeps pointing to Settings.
  popup:HookScript("OnHide", function() GW.MarkRulesetAsked() end)
end

--- Shows the ruleset popup (once per character; GW.CheckHouse decides when).
function GW.ShowRulesetPopup()
  if InCombatLockdown and InCombatLockdown() then return end -- not now; asked again next login
  if not popup then create() end
  popup:Show()
end

--- For tests: the popup.
function GW.RulesetPopup() return popup end
