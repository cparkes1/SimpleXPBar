-- Configuration
local ADDON_NAME = "SimpleXPBar"
local DEFAULT_WIDTH = 600 
local DEFAULT_HEIGHT = 24
local FONT_MAIN = "Fonts\\FRIZQT__.TTF"
local FONT_SIZE_MAIN = 16
local FONT_SIZE_OUTER = 14 
local TEXTURE = "Interface\\AddOns\\Details\\images\\bar_textures\\texture2020.tga"
local ICON = "Interface\\AddOns\\SimpleXPBar\\icon.tga" 

-- Colors
local COLOR_XP = {0.5, 0.2, 0.8, 1}
local COLOR_QUEST = {1, 0.6, 0, 1}
local COLOR_BG = {0, 0, 0, 0.6}

-- Detect Game Version
local IS_RETAIL = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)

-- Database Defaults
local defaults = {
    show = true,
    point = {"CENTER", nil, "CENTER", 0, -200},
    width = DEFAULT_WIDTH,
    height = DEFAULT_HEIGHT,
    minimap = { hide = false }, -- This stores the icon position
}

-- Session Variables
local sessionStart = GetTime()
local sessionXPGained = 0
local lastXP = 0
local levelTimeBase = 0
local levelTimeReference = GetTime()
local cachedQuestData = {} 
local simpleXPLDB -- Define here for scope

-- ---------------------------------------------------------
-- 1. Main XP Bar Frame
-- ---------------------------------------------------------
local f = CreateFrame("Frame", ADDON_NAME, UIParent, "BackdropTemplate")
f:SetSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
f:EnableMouse(true)
f:SetMovable(true)
f:SetResizable(true) 
f:SetClampedToScreen(true)
f:Hide() 

if f.SetResizeBounds then
    f:SetResizeBounds(400, 15)
else
    f:SetMinResize(400, 15)
end

f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
    SimpleXPBarDB.point = {point, nil, relativePoint, xOfs, yOfs}
end)

f.bg = f:CreateTexture(nil, "BACKGROUND")
f.bg:SetAllPoints(true)
f.bg:SetColorTexture(unpack(COLOR_BG))

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

-- ---------------------------------------------------------
-- 2. Text Labels
-- ---------------------------------------------------------
local function CreateLabel(point, relPoint, x, y, size, justify)
    local fs = f.xpBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetFont(FONT_MAIN, size, "OUTLINE")
    fs:SetPoint(point, f, relPoint, x, y)
    if justify then fs:SetJustifyH(justify) end
    return fs
end

f.textCenter = CreateLabel("CENTER", "CENTER", 0, 1, FONT_SIZE_MAIN)
f.textTL = CreateLabel("BOTTOMLEFT", "TOPLEFT", 2, 4, FONT_SIZE_OUTER, "LEFT")
f.textTR = CreateLabel("BOTTOMRIGHT", "TOPRIGHT", -2, 4, FONT_SIZE_OUTER, "RIGHT")
f.textBL = CreateLabel("TOPLEFT", "BOTTOMLEFT", 2, -4, FONT_SIZE_OUTER, "LEFT")
f.textBR = CreateLabel("TOPRIGHT", "BOTTOMRIGHT", -2, -4, FONT_SIZE_OUTER, "RIGHT")

-- ---------------------------------------------------------
-- 3. Resize & Tooltip
-- ---------------------------------------------------------
f.resize = CreateFrame("Frame", nil, f)
f.resize:SetSize(20, 20) 
f.resize:SetPoint("BOTTOMRIGHT")
f.resize:SetFrameLevel(10)
f.resize:Hide()

f.resize.tex = f.resize:CreateTexture(nil, "OVERLAY")
f.resize.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
f.resize.tex:SetAllPoints(true)

f:SetScript("OnEnter", function(self)
    self.resize:Show()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("XP Breakdown")
    local totalQ = 0
    if cachedQuestData and #cachedQuestData > 0 then
        GameTooltip:AddLine("Completed Quests:", 1, 0.8, 0)
        for _, q in ipairs(cachedQuestData) do
            if q.title and q.xp then
                GameTooltip:AddDoubleLine(q.title, "+" .. q.xp .. " xp", 1, 1, 1, 0, 1, 0)
                totalQ = totalQ + q.xp
            end
        end
        GameTooltip:AddLine(" ")
    else
        GameTooltip:AddLine("No completed quests.", 0.6, 0.6, 0.6)
    end
    local rested = GetXPExhaustion() or 0
    local formatFunc = FormatLargeNumber or tostring
    GameTooltip:AddDoubleLine("Total Quest XP:", formatFunc(totalQ), 1, 0.6, 0, 1, 1, 1)
    if rested > 0 then GameTooltip:AddDoubleLine("Rested XP:", formatFunc(rested), 0, 0.5, 1, 1, 1, 1) end
    GameTooltip:Show()
end)

f:SetScript("OnLeave", function(self) 
    if not self:IsMouseOver() then
        if not self.isResizing then self.resize:Hide() end
        GameTooltip:Hide()
    end
end)

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
        SimpleXPBarDB.width = f:GetWidth()
        SimpleXPBarDB.height = f:GetHeight()
        if f.UpdateAll then f:UpdateAll() end
    end
end)

-- ---------------------------------------------------------
-- 4. Logic Functions
-- ---------------------------------------------------------
local function FormatTime(s)
    if s >= 3600 then
        return string.format("%dh %dm", math.floor(s/3600), math.floor((s%3600)/60))
    else
        return string.format("%dm %ds", math.floor(s/60), s%60)
    end
end

local function FormatNumber(n)
    if n >= 1000 then return string.format("%.1fk", n/1000) else return tostring(n) end
end

local function GetCompletedQuestXP()
    local totalXP = 0
    wipe(cachedQuestData) 
    
    if IS_RETAIL then
        local numEntries = C_QuestLog.GetNumQuestLogEntries()
        for i = 1, numEntries do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and C_QuestLog.IsComplete(info.questID) then
                local xp = C_QuestLog.GetQuestRewardXP(info.questID)
                if xp and xp > 0 then 
                    totalXP = totalXP + xp 
                    table.insert(cachedQuestData, {title=info.title, xp=xp})
                end
            end
        end
        return totalXP
    end

    local numEntries = GetNumQuestLogEntries()
    local selectedIndex = GetQuestLogSelection()
    for i = 1, numEntries do
        local title, _, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
        if not isHeader then
            local actuallyComplete = false
            if questID and C_QuestLog.IsComplete and C_QuestLog.IsComplete(questID) then actuallyComplete = true
            elseif questID and IsQuestComplete and IsQuestComplete(questID) then actuallyComplete = true
            elseif (isComplete == 1 or isComplete == true) then actuallyComplete = true end
            
            if actuallyComplete then
                SelectQuestLogEntry(i)
                local xp = GetQuestLogRewardXP()
                if xp and xp > 0 then 
                    totalXP = totalXP + xp 
                    table.insert(cachedQuestData, {title=title, xp=xp})
                end
            end
        end
    end
    if selectedIndex > 0 then SelectQuestLogEntry(selectedIndex) end
    return totalXP
end

local function IsMaxLevel()
    local currentLevel = UnitLevel("player")
    local maxLevel = GetMaxPlayerLevel and GetMaxPlayerLevel() or 70
    return currentLevel >= maxLevel
end

local function UpdateTextAndTimers()
    local currentXP = UnitXP("player")
    local maxXP = UnitXPMax("player")
    if maxXP == 0 then return end 
    
    local restedXP = GetXPExhaustion() or 0
    local questXP = GetCompletedQuestXP()
    local remainingXP = maxXP - currentXP
    local now = GetTime()
    local sessionTime = now - sessionStart
    local currentLevelTime = levelTimeBase + (now - levelTimeReference)
    
    local xpRate = 0
    if sessionTime > 0 and sessionXPGained > 0 then
        xpRate = sessionXPGained / sessionTime
    end
    local xpPerHour = xpRate * 3600
    local ttlText = (xpRate > 0) and FormatTime(remainingXP / xpRate) or "N/A"

    f.textTL:SetText(string.format("Level Time: |cffFFFFFF%s|r", FormatTime(currentLevelTime)))
    f.textTR:SetText(string.format("Session Time: |cffFFFFFF%s|r", FormatTime(sessionTime)))
    
    local currentPct = (currentXP / maxXP) * 100
    local questPct = (questXP / maxXP) * 100
    local totalPct = currentPct + questPct
    
    f.textCenter:SetText(string.format(
        "Level %d        %d / %d (Remaining: %d)        %.1f%% [+%.1f%%]",
        UnitLevel("player"), currentXP, maxXP, remainingXP, currentPct, totalPct
    ))
    
    f.textBL:SetText(string.format("Next Level: |cffFFFFFF%s|r (%s XP/Hr)", ttlText, FormatNumber(math.floor(xpPerHour))))
    f.textBR:SetText(string.format("Quest: |cffFFA500%.1f%%|r - Rested: |cff0088FF%.1f%%|r", questPct, (restedXP / maxXP) * 100))
end

function f:UpdateAll()
    if IsMaxLevel() then f:Hide(); return end
    local currentXP = UnitXP("player")
    local maxXP = UnitXPMax("player")
    local questXP = GetCompletedQuestXP()
    local currentWidth = f:GetWidth()

    f.xpBar:SetMinMaxValues(0, maxXP)
    f.xpBar:SetValue(currentXP)
    
    local widthPerXP = currentWidth / maxXP
    local questBarWidth = math.min(questXP * widthPerXP, currentWidth - (currentXP * widthPerXP))
    
    if questBarWidth <= 0 then f.questBar:Hide() else f.questBar:Show(); f.questBar:SetWidth(questBarWidth) end
    UpdateTextAndTimers()
end

-- ---------------------------------------------------------
-- 5. DataBroker & Minimap Initialization
-- ---------------------------------------------------------
local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
local icon = LibStub and LibStub("LibDBIcon-1.0", true)

if ldb then
    simpleXPLDB = ldb:NewDataObject(ADDON_NAME, {
        type = "data source",
        text = ADDON_NAME,
        icon = ICON, 
        OnClick = function(self, button)
            if button == "LeftButton" then
                if IsMaxLevel() then return end
                SimpleXPBarDB.show = not SimpleXPBarDB.show
                if SimpleXPBarDB.show then f:Show(); f:UpdateAll() else f:Hide() end
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine(ADDON_NAME)
            tooltip:AddLine("|cffFFFFFFLeft-Click|r to Toggle Bar")
        end,
    })
end

-- ---------------------------------------------------------
-- 6. Event Handling
-- ---------------------------------------------------------
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
        -- Initialize Database
        SimpleXPBarDB = SimpleXPBarDB or CopyTable(defaults)
        
        -- Register Minimap Icon (THIS WAS THE FIX)
        if icon and simpleXPLDB then
            icon:Register(ADDON_NAME, simpleXPLDB, SimpleXPBarDB.minimap)
        end
        
        if SimpleXPBarDB.point then self:ClearAllPoints(); self:SetPoint(unpack(SimpleXPBarDB.point)) end
        if SimpleXPBarDB.width then self:SetWidth(SimpleXPBarDB.width) end
        if SimpleXPBarDB.height then self:SetHeight(SimpleXPBarDB.height) end
        
        lastXP = UnitXP("player")
        if IsMaxLevel() then self:Hide() elseif SimpleXPBarDB.show then self:Show(); self:UpdateAll() end
        
    elseif event == "PLAYER_ENTERING_WORLD" then
        RequestTimePlayed()
    elseif event == "TIME_PLAYED_MSG" then
        levelTimeBase = arg2
        levelTimeReference = GetTime()
        self:UpdateAll()
    elseif event == "PLAYER_XP_UPDATE" then
        local currentXP = UnitXP("player")
        local diff = currentXP - lastXP
        if diff > 0 then sessionXPGained = sessionXPGained + diff end
        lastXP = currentXP
        self:UpdateAll()
    elseif event == "PLAYER_LEVEL_UP" then
        if IsMaxLevel() then self:Hide(); SimpleXPBarDB.show = false
        else RequestTimePlayed(); self:UpdateAll() end
    elseif SimpleXPBarDB and SimpleXPBarDB.show then
        self:UpdateAll()
    end
end)