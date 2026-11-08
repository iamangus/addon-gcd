local addonName = ...

-- Blizzard's dummy "Global Cooldown" spell. Its cooldown is whitelisted as
-- never-secret, which lets an addon read the start/duration and animate a bar
-- the same way Blizzard's own swing timers do.
local GCD_SPELL_ID = 61304
local POLL_INTERVAL = 0.05

local DEFAULTS = {
    width = 213,
    height = 15,
    scale = 1,
    alpha = 1,
    style = "mainhand",
    locked = true,
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = -160,
}

local DB_VERSION = 2

local STYLE_TEXTURES = {
    mainhand = "ui-swingtimerbar-filling-mainhand",
    offhand = "ui-swingtimerbar-filling-offhand",
    ranged = "ui-swingtimerbar-filling-ranged",
}

local db
local bar
local status
local pip
local typeLabel
local typeLabelShadow
local timeLabel
local moveFrame

local gcdActive = false
local gcdStartTime
local gcdDuration
local gcdEndTime
local useDurationTimer = false
local isTest = false
local restartBlockedUntil = 0
local pollElapsed = 0

local HAS_DURATION_API = type(C_Spell) == "table"
    and type(C_Spell.GetSpellCooldownDuration) == "function"

local INTERPOLATION = (Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate) or 0
local ELAPSED_DIRECTION = (Enum and Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.ElapsedTime) or 0

local function IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) or false
end

local function Describe(value)
    if IsSecret(value) then
        return "secret"
    end
    return tostring(value)
end

local function Print(message)
    print("|cff33ff99GCD Bar|r: " .. tostring(message))
end

local function CopyDefaults(destination, source)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(destination[key]) ~= "table" then
                destination[key] = {}
            end
            CopyDefaults(destination[key], value)
        elseif destination[key] == nil then
            destination[key] = value
        end
    end
end

local function ApplyPosition()
    if not bar then
        return
    end

    bar:ClearAllPoints()
    bar:SetPoint(
        db.point or DEFAULTS.point,
        UIParent,
        db.relativePoint or db.point or DEFAULTS.relativePoint,
        db.x or 0,
        db.y or 0
    )
end

local function UpdateShadowWidth()
    if typeLabelShadow then
        typeLabelShadow:SetWidth(math.min(171, math.max(1, (db.width or DEFAULTS.width) - 12)))
    end
end

local function ApplyStyle()
    if not status then
        return
    end

    local texture = STYLE_TEXTURES[db.style] or STYLE_TEXTURES[DEFAULTS.style]
    status:SetStatusBarTexture(texture)

    local statusBarTexture = status:GetStatusBarTexture()
    if pip and statusBarTexture then
        pip:ClearAllPoints()
        pip:SetPoint("RIGHT", statusBarTexture, "RIGHT", 0, 0)
    end
end

local function ApplySize()
    if not bar then
        return
    end
    bar:SetSize(db.width, db.height)
    UpdateShadowWidth()
end

local function ClearGCD()
    gcdActive = false
    useDurationTimer = false
    isTest = false
    gcdStartTime = nil
    gcdDuration = nil
    gcdEndTime = nil
    restartBlockedUntil = GetTime() + POLL_INTERVAL

    if not status then
        return
    end

    -- Removing the range also removes any duration-object timer.
    status:SetMinMaxValues(0, 1)
    status:SetValue(0)

    if pip then
        pip:Hide()
    end
    if timeLabel then
        timeLabel:SetText("0.0")
        timeLabel:Show()
    end
end

local function GetGCDInfo()
    if type(C_Spell) ~= "table" or type(C_Spell.GetSpellCooldown) ~= "function" then
        return nil
    end
    return C_Spell.GetSpellCooldown(GCD_SPELL_ID)
end

local function IsGCDActive(info)
    if not info then
        return false
    end

    if info.isActive ~= nil then
        return info.isActive
    end

    local duration = info.duration
    if duration ~= nil and not IsSecret(duration) then
        return duration > 0
    end

    return false
end

local function StartGCDDuration()
    if not HAS_DURATION_API or type(status.SetTimerDuration) ~= "function" then
        return false
    end

    local durationObject = C_Spell.GetSpellCooldownDuration(GCD_SPELL_ID)
    if not durationObject then
        return false
    end

    status:SetMinMaxValues(0, 1)
    local ok = pcall(status.SetTimerDuration, status, durationObject, INTERPOLATION, ELAPSED_DIRECTION)
    if not ok then
        return false
    end

    gcdActive = true
    useDurationTimer = true
    isTest = false
    gcdStartTime = nil
    gcdDuration = nil
    gcdEndTime = nil

    if pip then
        pip:Show()
    end
    if timeLabel then
        -- Duration objects cannot be read, so there is no number to show.
        timeLabel:Hide()
    end
    return true
end

local function StartGCD(info)
    if not info then
        return false
    end

    local startTime, duration = info.startTime, info.duration
    if IsSecret(startTime) or IsSecret(duration) then
        return StartGCDDuration()
    end

    if not startTime or not duration or duration <= 0 then
        return false
    end

    local endTime = startTime + duration
    if endTime <= GetTime() then
        return false
    end

    gcdActive = true
    useDurationTimer = false
    isTest = false
    gcdStartTime = startTime
    gcdDuration = duration
    gcdEndTime = endTime

    status:SetMinMaxValues(0, 1)
    local remaining = math.max(0, gcdEndTime - GetTime())
    status:SetValue(math.max(0, math.min(1, (duration - remaining) / duration)))
    if pip then
        pip:Show()
    end
    if timeLabel then
        timeLabel:Show()
        timeLabel:SetFormattedText("%.1f", remaining)
    end
    return true
end

local function PollGCD(force)
    if not bar then
        return
    end

    local info = GetGCDInfo()
    local active = IsGCDActive(info)

    if isTest then
        if active then
            -- A real GCD interrupted the preview.
            isTest = false
            gcdActive = false
        else
            return
        end
    end

    if active then
        if not gcdActive and (force or GetTime() >= restartBlockedUntil) then
            if not StartGCD(info) then
                ClearGCD()
            end
        end
    elseif gcdActive then
        ClearGCD()
    end
end

local function StartTest()
    local now = GetTime()
    isTest = true
    gcdActive = true
    useDurationTimer = false
    gcdStartTime = now
    gcdDuration = 1.5
    gcdEndTime = now + 1.5

    status:SetMinMaxValues(0, 1)
    status:SetValue(0)
    if pip then
        pip:Show()
    end
    if timeLabel then
        timeLabel:Show()
        timeLabel:SetFormattedText("%.1f", 1.5)
    end
end

local function OnUpdate(_, elapsed)
    pollElapsed = pollElapsed + elapsed
    if pollElapsed >= POLL_INTERVAL then
        pollElapsed = 0
        PollGCD(false)
    end

    if not gcdActive or useDurationTimer or not gcdEndTime then
        return
    end

    local remaining = gcdEndTime - GetTime()
    if remaining <= 0 then
        ClearGCD()
        return
    end

    status:SetValue((gcdDuration - remaining) / gcdDuration)
    if timeLabel then
        timeLabel:SetFormattedText("%.1f", remaining)
    end
end

local function SetMoveMode(enabled)
    if not bar then
        return
    end

    db.locked = not enabled
    bar:EnableMouse(enabled)

    if enabled then
        bar:RegisterForDrag("LeftButton")
        moveFrame:Show()
    else
        moveFrame:Hide()
    end
end

local function CreateBar()
    bar = CreateFrame("Frame", nil, UIParent)
    bar:SetSize(db.width, db.height)
    bar:SetFrameStrata("MEDIUM")
    bar:SetFrameLevel(100)
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:SetAlpha(db.alpha)

    -- The same atlas art as Blizzard's swing timers.
    local background = bar:CreateTexture(nil, "BACKGROUND")
    background:SetAtlas("ui-swingtimerbar-background")
    background:SetAllPoints(bar)

    local border = bar:CreateTexture(nil, "BACKGROUND")
    border:SetAtlas("ui-swingtimerbar-frame")
    border:SetAllPoints(bar)

    status = CreateFrame("StatusBar", nil, bar)
    status:SetPoint("TOPLEFT", bar, "TOPLEFT", 5, -4)
    status:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -5, 4)
    status:SetMinMaxValues(0, 1)
    status:SetValue(0)
    status:SetFrameLevel(bar:GetFrameLevel() + 1)

    pip = status:CreateTexture(nil, "OVERLAY")
    pip:SetAtlas("ui-swingtimerbar-pip", true)
    pip:Hide()

    typeLabelShadow = status:CreateTexture(nil, "OVERLAY")
    typeLabelShadow:SetAtlas("ui-swingtimerbar-textshadow-left")
    typeLabelShadow:SetPoint("TOPLEFT")
    typeLabelShadow:SetPoint("BOTTOMLEFT")

    typeLabel = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    typeLabel:SetJustifyH("LEFT")
    typeLabel:SetPoint("LEFT", 10, 0)
    typeLabel:SetText("GCD")

    timeLabel = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timeLabel:SetJustifyH("RIGHT")
    timeLabel:SetPoint("RIGHT", -10, 0)
    timeLabel:SetText("0.0")

    ApplyStyle()
    UpdateShadowWidth()

    moveFrame = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    moveFrame:SetAllPoints(bar)
    moveFrame:SetFrameLevel(bar:GetFrameLevel() + 10)
    moveFrame:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    moveFrame:SetBackdropBorderColor(1, 0.82, 0, 1)
    moveFrame:Hide()

    local moveText = moveFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moveText:SetPoint("BOTTOM", moveFrame, "TOP", 0, 4)
    moveText:SetText("Drag to move  -  /gcd to lock")
    moveText:SetTextColor(1, 0.82, 0, 1)

    bar:SetScript("OnDragStart", function(self)
        if db.locked then
            return
        end
        self:StartMoving()
    end)

    bar:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()

        local point, _, relativePoint, x, y = self:GetPoint(1)
        db.point = point
        db.relativePoint = relativePoint
        db.x = x
        db.y = y
    end)

    bar:SetScript("OnUpdate", OnUpdate)

    ApplyPosition()
    SetMoveMode(not db.locked)
end

local function ResetSettings()
    db.width = DEFAULTS.width
    db.height = DEFAULTS.height
    db.scale = DEFAULTS.scale
    db.alpha = DEFAULTS.alpha
    db.style = DEFAULTS.style
    db.point = DEFAULTS.point
    db.relativePoint = DEFAULTS.relativePoint
    db.x = DEFAULTS.x
    db.y = DEFAULTS.y
    db.locked = true

    ApplySize()
    bar:SetScale(db.scale)
    bar:SetAlpha(db.alpha)
    ApplyStyle()
    ApplyPosition()
    SetMoveMode(false)
    ClearGCD()
end

local function PrintHelp()
    Print("commands:")
    Print("  /gcd - toggle move mode")
    Print("  /gcd lock - lock the bar")
    Print("  /gcd reset - reset position, size, and style")
    Print("  /gcd width <120-852> - set width")
    Print("  /gcd height <15-60> - set height")
    Print("  /gcd scale <0.5-2> - set scale")
    Print("  /gcd opacity <10-100> - set opacity percentage")
    Print("  /gcd style <mainhand|offhand|ranged> - set fill color")
    Print("  /gcd test - preview the bar")
    Print("  /gcd debug - print GCD API state")
end

local function ParseNumber(value, minimum, maximum)
    local number = tonumber(value)
    if not number then
        return nil
    end
    return math.max(minimum, math.min(maximum, number))
end

local function PrintDebug()
    Print("in combat: " .. tostring(InCombatLockdown()))

    local info = GetGCDInfo()
    if info then
        Print("start=" .. Describe(info.startTime)
            .. " duration=" .. Describe(info.duration)
            .. " active=" .. Describe(info.isActive)
            .. " onGCD=" .. Describe(info.isOnGCD))
    else
        Print("C_Spell.GetSpellCooldown(61304) returned nil")
    end

    local durationObject = HAS_DURATION_API and C_Spell.GetSpellCooldownDuration(GCD_SPELL_ID)
    Print("duration object: " .. tostring(durationObject ~= nil))

    if C_Secrets and C_Secrets.ShouldSpellCooldownBeSecret then
        local ok, secret = pcall(C_Secrets.ShouldSpellCooldownBeSecret, GCD_SPELL_ID)
        Print("cooldown secret: " .. (ok and Describe(secret) or "error"))
    end

    Print("tracking: " .. tostring(gcdActive) .. ", duration timer: " .. tostring(useDurationTimer))
end

local function HandleCommand(message)
    if not bar then
        Print("not loaded yet.")
        return
    end

    local command, rest = (message or ""):match("^(%S*)%s*(.-)$")
    command = (command or ""):lower()
    rest = rest:match("^%s*(.-)%s*$") or rest

    if command == "" then
        SetMoveMode(db.locked)
        if db.locked then
            Print("locked.")
        else
            Print("move mode on - drag the bar, then /gcd to lock.")
        end
    elseif command == "move" or command == "unlock" then
        SetMoveMode(true)
        Print("move mode on - drag the bar, then /gcd to lock.")
    elseif command == "lock" then
        SetMoveMode(false)
        Print("locked.")
    elseif command == "reset" then
        ResetSettings()
        Print("position, size, and style reset.")
    elseif command == "width" then
        local width = ParseNumber(rest, 120, 852)
        if width then
            db.width = width
            ApplySize()
            Print("width set to " .. width .. ".")
        else
            Print("usage: /gcd width <120-852>")
        end
    elseif command == "height" then
        local height = ParseNumber(rest, 15, 60)
        if height then
            db.height = height
            ApplySize()
            Print("height set to " .. height .. ".")
        else
            Print("usage: /gcd height <15-60>")
        end
    elseif command == "scale" then
        local scale = ParseNumber(rest, 0.5, 2)
        if scale then
            db.scale = scale
            bar:SetScale(db.scale)
            Print("scale set to " .. scale .. ".")
        else
            Print("usage: /gcd scale <0.5-2>")
        end
    elseif command == "opacity" then
        local opacity = ParseNumber(rest, 10, 100)
        if opacity then
            db.alpha = opacity / 100
            bar:SetAlpha(db.alpha)
            Print("opacity set to " .. opacity .. "%.")
        else
            Print("usage: /gcd opacity <10-100>")
        end
    elseif command == "style" then
        local style = rest:lower()
        if STYLE_TEXTURES[style] then
            db.style = style
            ApplyStyle()
            Print("style set to " .. style .. ".")
        else
            Print("usage: /gcd style <mainhand|offhand|ranged>")
        end
    elseif command == "test" then
        StartTest()
    elseif command == "debug" then
        PrintDebug()
    else
        PrintHelp()
    end
end

SLASH_GCDBAR1 = "/gcd"
SLASH_GCDBAR2 = "/gcdbar"
SlashCmdList.GCDBAR = HandleCommand

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("SPELL_UPDATE_COOLDOWN")
events:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
events:RegisterEvent("UNIT_SPELLCAST_FAILED")

events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then
            return
        end

        GCDBarDB = GCDBarDB or {}
        db = GCDBarDB
        CopyDefaults(db, DEFAULTS)

        if (db.version or 0) < 2 then
            -- Adopt the swing-timer dimensions and drop the old custom color.
            db.width = DEFAULTS.width
            db.height = DEFAULTS.height
            db.alpha = DEFAULTS.alpha
            db.style = DEFAULTS.style
            db.customColor = nil
        end
        db.version = DB_VERSION

        local firstRun = db.welcomed ~= true
        db.welcomed = true

        CreateBar()
        self:UnregisterEvent("ADDON_LOADED")

        if firstRun then
            Print("loaded. Type /gcd to move the bar, or /gcd test to preview it.")
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        ClearGCD()
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        PollGCD(true)
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        if arg1 == "player" then
            PollGCD(true)
        end
    end
end)
