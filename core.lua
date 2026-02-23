-- ---------------------------------------------------------
-- 1. Configuration & Constants
-- ---------------------------------------------------------
local ADDON_NAME = "SimpleXPBar"
local MAX_LEVEL_RETAIL = 80 
local MAX_LEVEL_TBC    = 70

local DEFAULT_WIDTH, DEFAULT_HEIGHT = 600, 24
local FONT_MAIN = [[Fonts\FRIZQT__.TTF]]
local TEXTURE = [[Interface\AddOns\Details\images\bar_textures\texture2020.tga]]
local ICON = [[Interface\AddOns\SimpleXPBar\icon.tga]] 

local COLOR_XP    = {0.5, 0.2, 0.8, 1}
local COLOR_QUEST = {1, 0.6, 0, 1}
local COLOR_BG    = {0, 0, 0, 0.6}

local IS_RETAIL = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
local defaults = {
    show = true, locked = false, width = DEFAULT_WIDTH, height = DEFAULT_HEIGHT,
    point = {"CENTER", nil, "CENTER", 0, -200}, minimap = { hide = false },
}

-- ---------------------------------------------------------
-- 2. State Variables
-- ---------------------------------------------------------
local sessionStart = GetTime()
local sessionXPGained, lastXP = 0, 0
local levelTimeBase, levelTimeReference = 0, GetTime()
local cachedQuestData, totalQuestXP = {}, 0

-- ---------------------------------------------------------
-- 3. Helper Functions
-- ---------------------------------------------------------
local function FormatNumber(n)
    if not n or n == 0 then return "0" end
    if n >= 1000000 then return string.format("%.2fM", n / 1000000)
    elseif n >= 1000 then return string.format("%.1fk", n / 1000)
    else return tostring(n) end
end

local function FormatTime(s)
    if s >= 3600 then return string.format("%dh %dm", s/3600, (s%3600)/60)
    else return string.format("%dm %ds", s/60, s%60) end
end

local function IsMaxLevel()
    return UnitLevel("player") >= (IS_RETAIL and MAX_LEVEL_RETAIL or MAX_LEVEL_TBC)
end

-- ---------------------------------------------------------
-- 4. Quest Logic (Scanner)
-- ---------------------------------------------------------
local scanner = CreateFrame("GameTooltip", "SimpleXPScanner", nil, "GameTooltipTemplate")
scanner:SetOwner(WorldFrame, "ANCHOR_NONE")

local function UpdateQuestXP()
    totalQuestXP = 0
    wipe(cachedQuestData)
    
    if IS_RETAIL then
        for i = 1, C_QuestLog.GetNumQuestLogEntries() do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and C_QuestLog.IsComplete(info.questID) then
                scanner:ClearLines()
                scanner:SetQuestLogItem("reward", 1, info.questLogIndex or i)
                for j = 1, scanner:NumLines() do
                    local text = _G["SimpleXPScannerTextLeft"..j]:GetText()
                    if text then
                        local amt = text:match("(%d+)%s+Experience") or text:match("Experience:%s+(%d+)")
                        if amt then
                            local xp = tonumber(amt) or 0
                            totalQuestXP = totalQuestXP + xp
                            table.insert(cachedQuestData, {title = info.title, xp = xp})
                            break
                        end
                    end
                end
            end
        end
    else
        local oldSel = GetQuestLogSelection()
        for i = 1, GetNumQuestLogEntries() do
            local title, _, _, isHeader, _, isComp = GetQuestLogTitle(i)
            if not isHeader and isComp then
                SelectQuestLogEntry(i)
                local xp = GetQuestLogRewardXP() or 0
                totalQuestXP = totalQuestXP + xp
                table.insert(cachedQuestData, {title = title, xp = xp})
            end
        end
        if oldSel > 0 then SelectQuestLogEntry(oldSel) end
    end
end

-- ---------------------------------------------------------
-- 5. UI Construction
-- ---------------------------------------------------------
local f = CreateFrame("Frame", ADDON_NAME, UIParent, "BackdropTemplate")
f:SetMovable(true); f:SetResizable(true); f:SetClampedToScreen(true); f:EnableMouse(true)

local function SetupUI()
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints(true); f.bg:SetColorTexture(unpack(COLOR_BG))

    f.xpBar = CreateFrame("StatusBar", nil, f)
    f.xpBar:SetStatusBarTexture(TEXTURE); f.xpBar:SetAllPoints(f)
    f.xpBar:SetStatusBarColor(unpack(COLOR_XP)); f.xpBar:SetFrameLevel(2)

    f.questBar = CreateFrame("StatusBar", nil, f)
    f.questBar:SetStatusBarTexture(TEXTURE); f.questBar:SetFrameLevel(1)
    f.questBar:SetStatusBarColor(unpack(COLOR_QUEST))
    f.questBar:SetPoint("TOPLEFT", f.xpBar:GetStatusBarTexture(), "TOPRIGHT")
    f.questBar:SetPoint("BOTTOMLEFT", f.xpBar:GetStatusBarTexture(), "BOTTOMRIGHT")

    local function CreateLabel(point, rel, x, y, size, justify)
        local fs = f.xpBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetFont(FONT_MAIN, size, "OUTLINE"); fs:SetPoint(point, f, rel, x, y)
        if justify then fs:SetJustifyH(justify) end
        return fs
    end

    f.textCenter = CreateLabel("CENTER", "CENTER", 0, 1, 14)
    f.textTL = CreateLabel("BOTTOMLEFT", "TOPLEFT", 2, 4, 12, "LEFT")
    f.textTR = CreateLabel("BOTTOMRIGHT", "TOPRIGHT", -2, 4, 12, "RIGHT")
    f.textBL = CreateLabel("TOPLEFT", "BOTTOMLEFT", 2, -4, 12, "LEFT")
    f.textBR = CreateLabel("TOPRIGHT", "BOTTOMRIGHT", -2, -4, 12, "RIGHT")

    f.resize = CreateFrame("Frame", nil, f)
    f.resize:SetSize(20, 20); f.resize:SetPoint("BOTTOMRIGHT"); f.resize:SetFrameLevel(10)
    f.resize.tex = f.resize:CreateTexture(nil, "OVERLAY")
    f.resize.tex:SetTexture([[Interface\ChatFrame\UI-ChatIM-SizeGrabber-Up]]); f.resize.tex:SetAllPoints()
end

-- ---------------------------------------------------------
-- 6. Interaction Logic
-- ---------------------------------------------------------
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", function(self) if not SimpleXPBarDB.locked and not IsControlKeyDown() then self:StartMoving() end end)
f:SetScript("OnDragStop", function(self) 
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    SimpleXPBarDB.point = {p, nil, rp, x, y}
end)

SetupUI() -- Execute UI build

f.resize:EnableMouse(true)
f.resize:SetScript("OnMouseDown", function(self, btn)
    if not SimpleXPBarDB.locked and btn == "LeftButton" and IsControlKeyDown() then
        f.isResizing = true; f:StartSizing("BOTTOMRIGHT")
    end
end)
f.resize:SetScript("OnMouseUp", function()
    if f.isResizing then
        f:StopMovingOrSizing(); f.isResizing = false
        SimpleXPBarDB.width, SimpleXPBarDB.height = f:GetSize()
        f:UpdateAll()
    end
end)

-- ---------------------------------------------------------
-- 7. Update Core
-- ---------------------------------------------------------
function f:UpdateAll()
    if IsMaxLevel() then f:Hide(); return end
    local cur, max = UnitXP("player"), UnitXPMax("player")
    if max <= 0 then return end

    f.xpBar:SetMinMaxValues(0, max); f.xpBar:SetValue(cur)
    local ratio = f:GetWidth() / max
    local qWidth = math.min(totalQuestXP * ratio, f:GetWidth() - (cur * ratio))
    f.questBar:SetWidth(math.max(1, qWidth)); f.questBar:SetShown(totalQuestXP > 0)

    local now = GetTime()
    local sessionTime = now - sessionStart
    local xpRate = (sessionTime > 0 and sessionXPGained > 0) and (sessionXPGained / sessionTime) or 0
    
    f.textTL:SetText(string.format("Level: |cffFFFFFF%s|r", FormatTime(levelTimeBase + (now - levelTimeReference))))
    f.textTR:SetText(string.format("Session: |cffFFFFFF%s|r", FormatTime(sessionTime)))
    f.textCenter:SetText(string.format("Lvl %d   %s / %s   %.1f%% [+%.1f%%]", UnitLevel("player"), FormatNumber(cur), FormatNumber(max), (cur/max)*100, (totalQuestXP/max)*100))
    f.textBL:SetText(string.format("Next: |cffFFFFFF%s|r (%s/Hr)", (xpRate > 0 and FormatTime((max - cur) / xpRate) or "N/A"), FormatNumber(xpRate * 3600)))
    f.textBR:SetText(string.format("Quest: |cffFFA500%.1f%%|r - Rested: |cff0088FF%.1f%%|r", (totalQuestXP/max)*100, ((GetXPExhaustion() or 0)/max)*100))
end

-- ---------------------------------------------------------
-- 8. Event Handling
-- ---------------------------------------------------------
f:SetScript("OnUpdate", function(self, elap)
    if not SimpleXPBarDB or not SimpleXPBarDB.show then return end
    self.timer = (self.timer or 0) + elap
    if self.timer >= 1 then f:UpdateAll(); self.timer = 0 end
end)

f:RegisterEvent("PLAYER_XP_UPDATE"); f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("PLAYER_ENTERING_WORLD"); f:RegisterEvent("TIME_PLAYED_MSG") 
f:RegisterEvent("QUEST_LOG_UPDATE"); f:RegisterEvent("ADDON_LOADED")

f:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        SimpleXPBarDB = SimpleXPBarDB or CopyTable(defaults)
        f:SetSize(SimpleXPBarDB.width, SimpleXPBarDB.height)
        if f.SetResizeBounds then f:SetResizeBounds(400, 15, 1200, 100) else f:SetMinResize(400, 15) end
        if SimpleXPBarDB.point then f:ClearAllPoints(); f:SetPoint(unpack(SimpleXPBarDB.point)) end
        if icon and simpleXPLDB then icon:Register(ADDON_NAME, simpleXPLDB, SimpleXPBarDB.minimap) end
        lastXP = UnitXP("player")
        UpdateQuestXP()
        if IsMaxLevel() then f:Hide() elseif SimpleXPBarDB.show then f:Show(); f:UpdateAll() end
    elseif event == "PLAYER_ENTERING_WORLD" then RequestTimePlayed()
    elseif event == "TIME_PLAYED_MSG" then levelTimeBase, levelTimeReference = arg2, GetTime(); f:UpdateAll()
    elseif event == "PLAYER_XP_UPDATE" then
        local cur = UnitXP("player")
        if cur > lastXP then sessionXPGained = sessionXPGained + (cur - lastXP) end
        lastXP = cur; f:UpdateAll()
    elseif event == "QUEST_LOG_UPDATE" then UpdateQuestXP(); f:UpdateAll()
    elseif event == "PLAYER_LEVEL_UP" then
        if IsMaxLevel() then f:Hide(); SimpleXPBarDB.show = false else RequestTimePlayed(); f:UpdateAll() end
    end
    f.resize:SetShown(not SimpleXPBarDB.locked)
end)

-- ---------------------------------------------------------
-- 9. Slash Commands
-- ---------------------------------------------------------
SLASH_SIMPLEXPBAR1 = "/sxp"
SlashCmdList["SIMPLEXPBAR"] = function(msg)
    msg = msg:lower():trim()
    if msg == "lock" then
        SimpleXPBarDB.locked = not SimpleXPBarDB.locked
        f.resize:SetShown(not SimpleXPBarDB.locked)
        print("|cffFFA500SimpleXPBar:|r " .. (SimpleXPBarDB.locked and "Locked" or "Unlocked"))
    elseif msg == "reset" then
        SimpleXPBarDB = CopyTable(defaults); ReloadUI()
    else
        print("|cffFFA500SimpleXPBar:|r /sxp lock, /sxp reset")
    end
end