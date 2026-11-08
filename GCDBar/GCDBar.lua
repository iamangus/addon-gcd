local addonName = ...

-- Spell 61304 is Blizzard's dummy "Global Cooldown" spell. Its cooldown is
-- flagged never-secret, and GetSpellCooldownDuration returns the current GCD
-- as an opaque duration object, so the bar keeps working in combat.
local GCD_SPELL_ID = 61304

local DEFAULTS = {
    width = 240,
    height = 16,
    scale = 1,
    locked = true,
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = -160,
}

local DB_VERSION = 1

local db
local bar
local status
local overlay
local overlayText
local useDuration
local fallbackStart
local fallbackDuration

local HAS_DURATION_API = type(C_Spell) == "table"
    and type(C_Spell.GetSpellCooldownDuration) == "function"

local INTERPOLATION = (Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate) or 0
local DIRECTION = (Enum and Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime) or 1

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

local function GetClassColor()
    local _, class = UnitClass("player")
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color then
        return color.r, color.g, color.b
    end
    return 0.20, 0.85, 0.90
end

local function UpdateColor()
    if not status then
        return
    end

    local custom = db and db.customColor
    if custom then
        status:SetStatusBarColor(custom.r, custom.g, custom.b)
    else
        status:SetStatusBarColor(GetClassColor())
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

local function ClearBar()
    if not status then
        return
    end

    -- SetMinMaxValues also removes any duration-object timer.
    status:SetMinMaxValues(0, 1)
    status:SetValue(0)
end

local function OnFallbackUpdate()
    if not fallbackStart or not fallbackDuration then
        return
    end

    local remaining = fallbackStart + fallbackDuration - GetTime()
    if remaining <= 0 then
        fallbackStart = nil
        fallbackDuration = nil
        status:SetValue(0)
    else
        status:SetValue(remaining / fallbackDuration)
    end
end

local function UpdateGCD()
    if not bar then
        return
    end

    if useDuration then
        local duration = C_Spell.GetSpellCooldownDuration(GCD_SPELL_ID)
        if duration then
            status:SetTimerDuration(duration, INTERPOLATION, DIRECTION)
            return
        end
    elseif C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(GCD_SPELL_ID)
        if info and info.startTime and info.duration and info.duration > 0 then
            fallbackStart = info.startTime
            fallbackDuration = info.duration
            local remaining = fallbackStart + fallbackDuration - GetTime()
            status:SetValue(math.max(0, math.min(1, remaining / fallbackDuration)))
            return
        end
    end

    fallbackStart = nil
    fallbackDuration = nil
    ClearBar()
end

local function ShowTest()
    if not bar then
        return
    end

    if useDuration then
        if type(C_DurationUtil) ~= "table" or type(C_DurationUtil.CreateDuration) ~= "function" then
            Print("this client cannot create a preview duration.")
            return
        end

        local duration = C_DurationUtil.CreateDuration()
        duration:SetTimeFromStart(GetTime(), 1.5)
        status:SetTimerDuration(duration, INTERPOLATION, DIRECTION)
    else
        fallbackStart = GetTime()
        fallbackDuration = 1.5
        status:SetMinMaxValues(0, 1)
        status:SetValue(1)
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
        overlay:Show()
    else
        overlay:Hide()
    end
end

local function CreateBar()
    bar = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    bar:SetSize(db.width, db.height)
    bar:SetFrameStrata("MEDIUM")
    bar:SetFrameLevel(100)
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    bar:SetBackdropColor(0, 0, 0, 0.60)
    bar:SetBackdropBorderColor(0, 0, 0, 0.90)

    status = CreateFrame("StatusBar", nil, bar)
    status:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
    status:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
    status:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    status:SetMinMaxValues(0, 1)
    status:SetValue(0)
    status:SetFrameLevel(bar:GetFrameLevel() + 1)

    useDuration = HAS_DURATION_API and type(status.SetTimerDuration) == "function"
    if not useDuration then
        bar:SetScript("OnUpdate", OnFallbackUpdate)
    end

    overlay = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetFrameLevel(bar:GetFrameLevel() + 10)
    overlay:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    overlay:SetBackdropColor(0, 0, 0, 0.35)
    overlay:SetBackdropBorderColor(1, 0.82, 0, 1)

    overlayText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    overlayText:SetPoint("CENTER", overlay, "CENTER", 0, 0)
    overlayText:SetText("Drag to move")
    overlayText:SetTextColor(1, 0.82, 0, 1)
    overlay:Hide()

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

    ApplyPosition()
    bar:SetScale(db.scale)
    UpdateColor()
    SetMoveMode(not db.locked)
end

local function ResetSettings()
    db.width = DEFAULTS.width
    db.height = DEFAULTS.height
    db.scale = DEFAULTS.scale
    db.point = DEFAULTS.point
    db.relativePoint = DEFAULTS.relativePoint
    db.x = DEFAULTS.x
    db.y = DEFAULTS.y
    db.customColor = nil
    db.locked = true

    bar:SetSize(db.width, db.height)
    bar:SetScale(db.scale)
    ApplyPosition()
    UpdateColor()
    SetMoveMode(false)
end

local function PrintHelp()
    Print("commands:")
    Print("  /gcd - toggle move mode")
    Print("  /gcd lock - lock the bar")
    Print("  /gcd reset - reset position and size")
    Print("  /gcd width <60-800> - set width")
    Print("  /gcd height <4-60> - set height")
    Print("  /gcd scale <0.5-3> - set scale")
    Print("  /gcd color <rrggbb> - set a custom bar color")
    Print("  /gcd class - use your class color")
    Print("  /gcd test - preview the bar")
end

local function ParseNumber(value, minimum, maximum)
    local number = tonumber(value)
    if not number then
        return nil
    end
    return math.max(minimum, math.min(maximum, number))
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
        Print("position and size reset.")
    elseif command == "width" then
        local width = ParseNumber(rest, 60, 800)
        if width then
            db.width = width
            bar:SetSize(db.width, db.height)
            Print("width set to " .. width .. ".")
        else
            Print("usage: /gcd width <60-800>")
        end
    elseif command == "height" then
        local height = ParseNumber(rest, 4, 60)
        if height then
            db.height = height
            bar:SetSize(db.width, db.height)
            Print("height set to " .. height .. ".")
        else
            Print("usage: /gcd height <4-60>")
        end
    elseif command == "scale" then
        local scale = ParseNumber(rest, 0.5, 3)
        if scale then
            db.scale = scale
            bar:SetScale(db.scale)
            Print("scale set to " .. scale .. ".")
        else
            Print("usage: /gcd scale <0.5-3>")
        end
    elseif command == "color" then
        local hex = rest:match("^#?(%x%x%x%x%x%x)$")
        if hex then
            db.customColor = {
                r = tonumber(hex:sub(1, 2), 16) / 255,
                g = tonumber(hex:sub(3, 4), 16) / 255,
                b = tonumber(hex:sub(5, 6), 16) / 255,
            }
            UpdateColor()
            Print("color set to #" .. hex:lower() .. ".")
        else
            Print("usage: /gcd color <rrggbb>")
        end
    elseif command == "class" then
        db.customColor = nil
        UpdateColor()
        Print("using your class color.")
    elseif command == "test" then
        ShowTest()
    else
        PrintHelp()
    end
end

SLASH_GCDBAR1 = "/gcd"
SLASH_GCDBAR2 = "/gcdbar"
SlashCmdList.GCDBAR = HandleCommand

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
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
        db.version = DB_VERSION

        local firstRun = db.welcomed ~= true
        db.welcomed = true

        CreateBar()
        self:UnregisterEvent("ADDON_LOADED")

        if firstRun then
            Print("loaded. Type /gcd to move the bar, or /gcd test to preview it.")
        end
    elseif event == "PLAYER_LOGIN" then
        UpdateColor()
    elseif event == "PLAYER_ENTERING_WORLD" then
        fallbackStart = nil
        fallbackDuration = nil
        ClearBar()
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        UpdateGCD()
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        if arg1 == "player" then
            UpdateGCD()
        end
    end
end)
