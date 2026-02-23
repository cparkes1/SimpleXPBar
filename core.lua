-- ---------------------------------------------------------
-- 1. Configuration & Main Frame
-- ---------------------------------------------------------
local ADDON_NAME = "SimpleXPBar"
local MAX_LEVEL_RETAIL = 80 
local MAX_LEVEL_TBC    = 70

local DEFAULT_WIDTH = 600 
local DEFAULT_HEIGHT = 24
local FONT_MAIN = "Fonts\\FRIZQT__.TTF"
local TEXTURE = "Interface\\AddOns\\Details\\images\\bar_textures\\texture2020.tga"
local ICON = "Interface\\AddOns\\SimpleXPBar\\icon.tga" 

local COLOR_XP = {0.5, 0.2, 0.8, 1}
local COLOR_QUEST = {1, 0.6, 0, 1}
local COLOR_BG = {0, 0, 0, 0.6}

local f = CreateFrame("Frame", ADDON_NAME, UIParent, "BackdropTemplate")
f:SetSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
f:EnableMouse(true)
f:SetMovable(true)
f:SetResizable(true) 
f:SetClampedToScreen(true)
f:SetPoint("CENTER", nil, "CENTER", 0, -200)

if f.SetResizeBounds then
    f:SetResizeBounds(400, 15, 1200, 100) 
else
    f:SetMinResize(400, 15)
end

-- Create Background
f.bg = f:CreateTexture(nil, "BACKGROUND")
f.bg:SetAllPoints(true)
f.bg:SetColorTexture(unpack(COLOR_BG))

-- [[ FIX: CREATE THE BARS BEFORE THE LABELS ]]
f.xpBar = CreateFrame("StatusBar", nil, f)
f.xpBar:SetStatusBarTexture(TEXTURE)
f.xpBar:SetAllPoints(f)
f.xpBar:SetStatusBarColor(unpack(COLOR_XP))
f.xpBar:SetFrameLevel(2)

f.questBar = CreateFrame("StatusBar", nil, f)
f.questBar:SetStatusBarTexture(TEXTURE)
f.questBar:SetStatusBarColor(unpack(COLOR_QUEST))
f.questBar:SetFrameLevel(1)
f.questBar:SetPoint("TOPLEFT", f.xpBar:GetStatusBarTexture(), "TOPRIGHT", 0, 0)
f.questBar:SetPoint("BOTTOMLEFT", f.xpBar:GetStatusBarTexture(), "BOTTOMRIGHT", 0, 0)

local function CreateLabel(point, relPoint, x, y, size, justify)
    local fs = f.xpBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetFont(FONT_MAIN, size, "OUTLINE")
    fs:SetPoint(point, f, relPoint, x, y)
    if justify then fs:SetJustifyH(justify) end
    return fs
end

f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", function(self)
    if not IsControlKeyDown() then -- Move when NOT holding Ctrl (Ctrl is for resizing)
        self:StartMoving()
    end
end)
f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Save the new position to your database immediately
    local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
    if SimpleXPBarDB then
        SimpleXPBarDB.point = {point, nil, relativePoint, xOfs, yOfs}
    end
end)

f.textCenter = CreateLabel("CENTER", "CENTER", 0, 1, 14)
f.textTL = CreateLabel("BOTTOMLEFT", "TOPLEFT", 2, 4, 12, "LEFT")
f.textTR = CreateLabel("BOTTOMRIGHT", "TOPRIGHT", -2, 4, 12, "RIGHT")
f.textBL = CreateLabel("TOPLEFT", "BOTTOMLEFT", 2, -4, 12, "LEFT")
f.textBR = CreateLabel("TOPRIGHT", "BOTTOMRIGHT", -2, -4, 12, "RIGHT")

-- ---------------------------------------------------------
-- 2. Version Detection & Setup
-- ---------------------------------------------------------
local IS_RETAIL = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
local IS_CLASSIC = (WOW_PROJECT_ID == WOW_PROJECT_CLASSIC) or (WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC)

-- Database Defaults
local defaults = {
    show = true,
    point = {"CENTER", nil, "CENTER", 0, -200},
    width = DEFAULT_WIDTH,
    height = DEFAULT_HEIGHT,
    minimap = { hide = false },
}

-- Session Variables
local sessionStart = GetTime()
local sessionXPGained = 0
local lastXP = 0
local levelTimeBase = 0
local levelTimeReference = GetTime()
local cachedQuestData = {} 
local simpleXPLDB 
local scannerTooltip = CreateFrame("GameTooltip", "SimpleXPScannerTooltip", nil, "GameTooltipTemplate")
scannerTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
local scannerTooltip = CreateFrame("GameTooltip", "SimpleXPScanner", nil, "GameTooltipTemplate")
scannerTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

-- ---------------------------------------------------------
-- 3. Resize Handle & Tooltip Logic
-- ---------------------------------------------------------
f.resize = CreateFrame("Frame", nil, f)
f.resize:SetSize(20, 20) 
f.resize:SetPoint("BOTTOMRIGHT")
f.resize:SetFrameLevel(10)

f.resize.tex = f.resize:CreateTexture(nil, "OVERLAY")
f.resize.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
f.resize.tex:SetAllPoints(true)

-- Scripts for Resizing
f.resize:EnableMouse(true)
f.resize:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and IsControlKeyDown() then
        f.isResizing = true
        f:StartSizing("BOTTOMRIGHT")
    end
end)

f.resize:SetScript("OnMouseUp", function(self)
    if f.isResizing then
        f:StopMovingOrSizing()
        f.isResizing = false
        -- Save dimensions
        SimpleXPBarDB.width = f:GetWidth()
        SimpleXPBarDB.height = f:GetHeight()
        if f.UpdateAll then f:UpdateAll() end
    end
end)

-- ---------------------------------------------------------
-- 4. Logic Functions
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

local function GetCompletedQuestXP()
    local totalXP = 0
    wipe(cachedQuestData) 
    
    if IS_RETAIL then
        -- Modern Retail (12.0+) Tooltip Scanning
        local numEntries = C_QuestLog.GetNumQuestLogEntries()
        for i = 1, numEntries do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and C_QuestLog.IsComplete(info.questID) then
                local questXP = 0
                
                -- Clear and set the scanner to the quest log index
                scannerTooltip:ClearLines()
                scannerTooltip:SetQuestLogItem("reward", 1, info.questLogIndex or i)
                
                -- Read the text in the tooltip to find the XP amount
                for j = 1, scannerTooltip:NumLines() do
                    local line = _G["SimpleXPScannerTextLeft"..j]
                    local text = line and line:GetText()
                    if text then
                        -- Matches numbers near the word "Experience"
                        local amount = text:match("(%d?%d?%d?%d?%d?%d?%d?)%s+Experience") or 
                                       text:match("Experience:%s+(%d?%d?%d?%d?%d?%d?%d?)")
                        if amount then
                            questXP = tonumber(amount) or 0
                            break
                        end
                    end
                end

                if questXP > 0 then 
                    totalXP = totalXP + questXP 
                    table.insert(cachedQuestData, {title = info.title, xp = questXP})
                end
            end
        end
    else
        -- Classic / TBC logic (remains unchanged)
        local numEntries = GetNumQuestLogEntries()
        local selectedIndex = GetQuestLogSelection() 
        for i = 1, numEntries do
            local title, _, _, isHeader, _, isComplete = GetQuestLogTitle(i)
            if not isHeader and isComplete then
                SelectQuestLogEntry(i)
                local xp = GetQuestLogRewardXP()
                if xp and xp > 0 then 
                    totalXP = totalXP + xp 
                    table.insert(cachedQuestData, {title = title, xp = xp})
                end
            end
        end
        if selectedIndex and selectedIndex > 0 then SelectQuestLogEntry(selectedIndex) end
    end
    
    return totalXP
end

local function IsMaxLevel()
    local currentLevel = UnitLevel("player")
    local maxLevel = IS_RETAIL and MAX_LEVEL_RETAIL or MAX_LEVEL_TBC
    return currentLevel >= maxLevel
end

local function UpdateTextAndTimers()
    local currentXP, maxXP = UnitXP("player"), UnitXPMax("player")
    if maxXP == 0 then return end 
    
    local now = GetTime()
    local sessionTime = now - sessionStart
    local currentLevelTime = levelTimeBase + (now - levelTimeReference)
    local xpRate = (sessionTime > 0 and sessionXPGained > 0) and (sessionXPGained / sessionTime) or 0
    local xpPerHour = xpRate * 3600
    
    local currentPct, questPct = (currentXP / maxXP) * 100, (GetCompletedQuestXP() / maxXP) * 100
    
    f.textTL:SetText(string.format("Level: |cffFFFFFF%s|r", FormatTime(currentLevelTime)))
    f.textTR:SetText(string.format("Session: |cffFFFFFF%s|r", FormatTime(sessionTime)))
    f.textCenter:SetText(string.format("Lvl %d   %s / %s   %.1f%% [+%.1f%%]", UnitLevel("player"), FormatNumber(currentXP), FormatNumber(maxXP), currentPct, questPct))
    f.textBL:SetText(string.format("Next: |cffFFFFFF%s|r (%s/Hr)", (xpRate > 0 and FormatTime((maxXP - currentXP) / xpRate) or "N/A"), FormatNumber(xpPerHour)))
    f.textBR:SetText(string.format("Quest: |cffFFA500%.1f%%|r - Rested: |cff0088FF%.1f%%|r", questPct, ((GetXPExhaustion() or 0) / maxXP) * 100))
end

function f:UpdateAll()
    if IsMaxLevel() then f:Hide(); return end
    local cur, max = UnitXP("player"), UnitXPMax("player")
    f.xpBar:SetMinMaxValues(0, max)
    f.xpBar:SetValue(cur)
    local qBarWidth = math.min(GetCompletedQuestXP() * (f:GetWidth() / max), f:GetWidth() - (cur * (f:GetWidth() / max)))
    if qBarWidth <= 0 then f.questBar:Hide() else f.questBar:Show(); f.questBar:SetWidth(qBarWidth) end
    UpdateTextAndTimers()
end

-- ---------------------------------------------------------
-- 5. Broker & Events
-- ---------------------------------------------------------
local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
local icon = LibStub and LibStub("LibDBIcon-1.0", true)

if ldb then
    simpleXPLDB = ldb:NewDataObject(ADDON_NAME, {
        type = "data source", text = ADDON_NAME, icon = ICON, 
        OnClick = function(_, btn) if btn == "LeftButton" and not IsMaxLevel() then SimpleXPBarDB.show = not SimpleXPBarDB.show; if SimpleXPBarDB.show then f:Show(); f:UpdateAll() else f:Hide() end end end,
        OnTooltipShow = function(tooltip) tooltip:AddLine(ADDON_NAME); tooltip:AddLine("|cffFFFFFFLeft-Click|r to Toggle Bar") end,
    })
end

f:SetScript("OnUpdate", function(self, elapsed)
    if not SimpleXPBarDB or not SimpleXPBarDB.show then return end
    self.timer = (self.timer or 0) + elapsed
    if self.timer >= 1 then UpdateTextAndTimers(); self.timer = 0 end
end)

f:RegisterEvent("PLAYER_XP_UPDATE")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("TIME_PLAYED_MSG") 
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("ADDON_LOADED")

f:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        SimpleXPBarDB = SimpleXPBarDB or CopyTable(defaults)
        if icon and simpleXPLDB then icon:Register(ADDON_NAME, simpleXPLDB, SimpleXPBarDB.minimap) end
        if SimpleXPBarDB.point then self:ClearAllPoints(); self:SetPoint(unpack(SimpleXPBarDB.point)) end
        if SimpleXPBarDB.width then self:SetWidth(SimpleXPBarDB.width) end
        if SimpleXPBarDB.height then self:SetHeight(SimpleXPBarDB.height) end
        lastXP = UnitXP("player")
        if IsMaxLevel() then self:Hide() elseif SimpleXPBarDB.show then self:Show(); self:UpdateAll() end
    elseif event == "PLAYER_ENTERING_WORLD" then RequestTimePlayed()
    elseif event == "TIME_PLAYED_MSG" then levelTimeBase, levelTimeReference = arg2, GetTime(); self:UpdateAll()
    elseif event == "PLAYER_XP_UPDATE" then
        local cur = UnitXP("player")
        if cur > lastXP then sessionXPGained = sessionXPGained + (cur - lastXP) end
        lastXP = cur
        self:UpdateAll()
    elseif event == "PLAYER_LEVEL_UP" then
        if IsMaxLevel() then self:Hide(); SimpleXPBarDB.show = false else RequestTimePlayed(); self:UpdateAll() end
    elseif SimpleXPBarDB and SimpleXPBarDB.show then self:UpdateAll() end
end)