--- Bug report (/gw bug): a window with a ready-made report, already selected so Ctrl+C copies it. It
--- starts with the three questions only the player can answer, then a diagnostics block with
--- everything needed to reproduce a problem: versions, game build, region / ruleset / house, the open
--- auction house, data and scan ages, changed settings, other loaded add-ons and Goldwright's recent
--- log. Fits one Discord message (GW.BUG_REPORT_MAX characters). Never includes character names.
---
--- Read-only: GetBuildInfo, C_AddOns (GetAddOnMetadata, GetNumAddOns, GetAddOnInfo, IsAddOnLoaded).
local _, GW = ...

local UI = GW.UI

--- Longest report, in characters: Discord allows 2,000 per message, with room for what players add.
GW.BUG_REPORT_MAX = 1900
--- Where to paste it.
GW.BUG_REPORT_WHERE =
  "#bug-reports on the Goldwright Discord (discord.gg/PX22TFh4UZ), or github.com/goldwrightapp/goldwright-addon/issues"

--- Calls a C_AddOns function, or the old global of the same name on clients without C_AddOns.
---@param name string function name, e.g. "GetAddOnMetadata"
---@param ... any arguments
---@return any ... its results (nothing when neither exists)
local function addons(name, ...)
  local f = (C_AddOns and C_AddOns[name]) or _G[name]
  if f then return f(...) end
end

--- Goldwright's version from its .toc.
---@return string version e.g. "0.2.1"
function GW.Version() return addons("GetAddOnMetadata", "Goldwright", "Version") or "?" end

--- Loaded add-ons other than Goldwright and Blizzard's own, by folder name.
---@return string[] names sorted
local function otherAddOns()
  local out = {}
  for i = 1, addons("GetNumAddOns") or 0 do
    local name = addons("GetAddOnInfo", i)
    if name and addons("IsAddOnLoaded", name) and not name:find("^Blizzard_") and not name:find("^Goldwright") then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- Settings the player changed from their defaults, as "key=value".
---@return string[] pairs sorted
local function changedSettings()
  local out = {}
  for k, v in pairs(GoldwrightDB and GoldwrightDB.opt or {}) do
    out[#out + 1] = k .. "=" .. tostring(v)
  end
  table.sort(out)
  return out
end

--- Joins names up to `max` characters, ending with "+N more" when they don't all fit.
---@param names string[]
---@param max number
---@return string text
local function joinUpTo(names, max)
  local text, shown = "", 0
  for i, n in ipairs(names) do
    local next = (i == 1) and n or (text .. ", " .. n)
    if #next > max then break end
    text, shown = next, i
  end
  if shown < #names then text = text .. (shown > 0 and ", " or "") .. "+" .. (#names - shown) .. " more" end
  return text
end

--- The report text: questions for the player, then diagnostics in a code block (newest log lines
--- last, as many as fit in GW.BUG_REPORT_MAX).
---@return string report
function GW.BugReport()
  local h = GW.House()
  local version, build, _, toc = GetBuildInfo()
  local pack = GW.Pack()
  local scans = {}
  for _, side in ipairs({ "A", "H", "N" }) do
    local t = GW.LastScanText and GW.LastScanText(side)
    if t then scans[#scans + 1] = GW.HOUSE_NAMES[side] .. " " .. t end
  end
  local open = GW.AuctionHouseOpen and GW.AuctionHouseOpen()
  local diag = {
    "Goldwright " .. GW.Version(),
    string.format("WoW %s (%s, interface %s)", tostring(version), tostring(build), tostring(toc)),
    string.format('%s · %s · %s (realm "%s")', h.region, h.ruleset, GW.HOUSE_NAMES[h.side] or "?", h.realm or "?"),
    "Auction house open: " .. (open and (GW.HOUSE_NAMES[GW.AuctionSide and GW.AuctionSide() or h.side] or "?") or "no"),
    pack and string.format(
      "Data %s %s: snapshot %s, built %s",
      h.packKey or "?",
      pack.version or "?",
      GW.Age(pack.snapshotAt),
      GW.Age(pack.builtAt)
    ) or ("Data: none loaded for " .. (h.packKey or "?")),
    "Scans: " .. (#scans > 0 and table.concat(scans, "; ") or "none"),
    "Cut: " .. (GW.CutText and GW.CutText() or "?"),
  }
  local settings = changedSettings()
  diag[#diag + 1] = "Settings changed: " .. (#settings > 0 and joinUpTo(settings, 200) or "none")
  local others = otherAddOns()
  diag[#diag + 1] = "Other add-ons: " .. (#others > 0 and joinUpTo(others, 300) or "none")

  local head = table.concat({
    "**What happened:**",
    "**What you expected:**",
    "**Steps:** 1. … 2. … 3. …",
    "",
    "```",
  }, "\n") .. "\n" .. table.concat(diag, "\n") .. "\n"
  local tail = "```"
  -- Recent log lines, newest last, as many as fit.
  local log = GoldwrightDB and GoldwrightDB.searchLog or {}
  local lines = {}
  local used = #head + #tail + #"Recent log:\n"
  for i = #log, 1, -1 do
    local line = tostring(log[i]):sub(1, 140)
    if used + #line + 1 > GW.BUG_REPORT_MAX then break end
    table.insert(lines, 1, line)
    used = used + #line + 1
  end
  local logText = #lines > 0 and ("Recent log:\n" .. table.concat(lines, "\n") .. "\n") or ""
  return head .. logText .. tail
end

local win -- the window, built on first use

--- Opens the bug report window with a fresh report, selected for copying.
function GW.ShowBugReport()
  if not win then
    win = UI.Window("GoldwrightBugReport", 560, 430, { title = "Report a Bug", strata = "DIALOG", movable = true })
    win:SetPoint("CENTER")
    win.hint = UI.FontString(win, "GameFontHighlightSmall", "LEFT")
    win.hint:SetPoint("TOPLEFT", 18, -32)
    win.hint:SetWidth(520)
    win.hint:SetText(
      "Press Ctrl+C to copy, then paste it into " .. GW.BUG_REPORT_WHERE .. ". Fill in the first three lines there."
    )
    local area
    area, win.box = UI.TextArea(win, 480)
    area:SetPoint("TOPLEFT", 14, -62)
    area:SetPoint("BOTTOMRIGHT", -14, 48)
    win.box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    local close = UI.Button(win, "Close", 100, 24, function() win:Hide() end)
    close:SetPoint("BOTTOMRIGHT", -16, 16)
    local again = UI.Button(win, "Select All", 100, 24, function()
      win.box:SetFocus()
      win.box:HighlightText()
    end)
    again:SetPoint("RIGHT", close, "LEFT", -8, 0)
  end
  win.box:SetText(GW.BugReport())
  win:Show()
  win.box:SetFocus()
  win.box:HighlightText()
end
