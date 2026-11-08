local addonName = ...

-- Forever does not expose the old spell 61304 dummy GCD. Instead, use the
-- same two pieces of information Blizzard's CooldownViewer uses:
--   1. SPELL_UPDATE_COOLDOWN reports startRecoveryCategory 133 when the GCD begins.
--   2. SpellCooldownInfo.timeUntilEndOfStartRecovery is the remaining GCD.
local GLOBAL_RECOVERY_CATEGORY = (Constants
    and Constants.SpellCooldownConsts
    and Constants.SpellCooldownConsts.GLOBAL_RECOVERY_CATEGORY) or 133
local POLL_INTERVAL = 0.05
local MAX_GCD_DURATION = 2.0
local GCD_CACHE_TTL = 30

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
local gcdDuration
local gcdEndTime
local gcdFromFallback = false
local lastKnownGCDDuration
local lastKnownGCDTime = 0
local isTest = false
local restartBlockedUntil = 0
local pollElapsed = 0

local lastSpellID
local lastBaseSpellID
local lastCategory
local lastStartRecoveryCategory
local lastItemID

local function IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) or false
end

local function SafeValue(value)
    if IsSecret(value) then
        return nil
    end
    return value
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
    isTest = false
    gcdDuration = nil
    gcdEndTime = nil
    gcdFromFallback = false
    restartBlockedUntil = GetTime() + POLL_INTERVAL

    if not status then
        return
    end

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

local function GetCooldownInfo(spellID)
    local safeSpellID = SafeValue(spellID)
    if not safeSpellID or type(C_Spell) ~= "table" or type(C_Spell.GetSpellCooldown) ~= "function" then
        return nil
    end
    return C_Spell.GetSpellCooldown(safeSpellID)
end

local function StartGCDFromRemaining(remaining, fromFallback)
    remaining = SafeValue(remaining)
    if type(remaining) ~= "number" or remaining <= 0 then
        return false
    end

    local now = GetTime()
    gcdActive = true
    isTest = false
    gcdFromFallback = fromFallback == true
    gcdDuration = remaining
    gcdEndTime = now + remaining
    lastKnownGCDDuration = remaining
    lastKnownGCDTime = now

    status:SetMinMaxValues(0, 1)
    status:SetValue(0)
    if pip then
        pip:Show()
    end
    if timeLabel then
        timeLabel:Show()
        timeLabel:SetFormattedText("%.1f", remaining)
    end
    return true
end

local function StartGCDFromTimes(startTime, duration)
    startTime = SafeValue(startTime)
    duration = SafeValue(duration)
    if type(startTime) ~= "number" or type(duration) ~= "number" or duration <= 0 then
        return false
    end

    local endTime = startTime + duration
    local now = GetTime()
    if endTime <= now then
        return false
    end

    gcdActive = true
    isTest = false
    gcdFromFallback = false
    gcdDuration = duration
    gcdEndTime = endTime
    lastKnownGCDDuration = duration
    lastKnownGCDTime = now

    local remaining = endTime - now
    status:SetMinMaxValues(0, 1)
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

local function RefineGCD(remaining)
    remaining = SafeValue(remaining)
    if type(remaining) ~= "number" or remaining <= 0 or not gcdDuration or not gcdEndTime then
        return false
    end

    local now = GetTime()
    local elapsed = now - (gcdEndTime - gcdDuration)
    local total = elapsed + remaining
    if total <= 0 then
        return false
    end

    gcdDuration = total
    gcdEndTime = now + remaining
    gcdFromFallback = false
    lastKnownGCDDuration = total
    lastKnownGCDTime = now

    status:SetValue(math.max(0, math.min(1, elapsed / total)))
    if timeLabel then
        timeLabel:SetFormattedText("%.1f", remaining)
    end
    return true
end

local function GetFallbackGCDDuration()
    if type(lastKnownGCDDuration) == "number"
        and lastKnownGCDDuration >= 0.5 and lastKnownGCDDuration <= MAX_GCD_DURATION
        and (GetTime() - lastKnownGCDTime) <= GCD_CACHE_TTL then
        return lastKnownGCDDuration
    end

    local energy = (Enum and Enum.PowerType and Enum.PowerType.Energy) or 3
    local powerType = SafeValue(UnitPowerType("player"))
    if powerType == energy then
        return 1.0
    end

    local haste = SafeValue(UnitSpellHaste("player"))
    if type(haste) ~= "number" then
        haste = 0
    end

    return math.max(0.75, 1.5 / (1 + haste / 100))
end

local function TryStartGCD(spellID, fromEvent)
    if fromEvent and not spellID and not lastSpellID and not lastBaseSpellID and not lastItemID then
        -- Ignore cooldown initialization with no associated cast.
        return false
    end

    if gcdActive then
        if isTest then
            if not fromEvent then
                return false
            end
            -- A real GCD cancels the preview.
            isTest = false
            gcdActive = false
        elseif gcdFromFallback and fromEvent then
            -- The first event had no readable timing. If a later event does,
            -- replace the estimate with the real remaining GCD.
            local info = GetCooldownInfo(spellID)
            local remaining = info and SafeValue(info.timeUntilEndOfStartRecovery)
            if type(remaining) == "number" and remaining > 0 then
                return RefineGCD(remaining)
            end
            return false
        else
            return false
        end
    end

    if GetTime() < restartBlockedUntil then
        return false
    end

    local info = GetCooldownInfo(spellID)
    if info then
        local remaining = SafeValue(info.timeUntilEndOfStartRecovery)
        if type(remaining) == "number" and remaining > 0 then
            return StartGCDFromRemaining(remaining, false)
        end

        if info.isOnGCD == true then
            local startTime = SafeValue(info.startTime)
            local duration = SafeValue(info.duration)
            if type(startTime) == "number" and type(duration) == "number"
                and duration > 0 and duration <= MAX_GCD_DURATION then
                return StartGCDFromTimes(startTime, duration)
            end
        end
    end

    if fromEvent then
        -- The event says the GCD started, but the cooldown fields are not
        -- available. Fall back to the last observed or hasted base GCD.
        return StartGCDFromRemaining(GetFallbackGCDDuration(), true)
    end

    return false
end

local function PollGCD()
    if gcdActive then
        if gcdFromFallback then
            local info = GetCooldownInfo(lastSpellID or lastBaseSpellID)
            local remaining = info and SafeValue(info.timeUntilEndOfStartRecovery)
            if type(remaining) == "number" and remaining > 0 then
                RefineGCD(remaining)
            end
        end
        return
    end

    if isTest then
        return
    end
    if GetTime() < restartBlockedUntil then
        return
    end

    local spellID = lastSpellID or lastBaseSpellID
    if not spellID then
        return
    end

    local info = GetCooldownInfo(spellID)
    if not info then
        return
    end

    local remaining = SafeValue(info.timeUntilEndOfStartRecovery)
    if type(remaining) == "number" and remaining > 0 then
        StartGCDFromRemaining(remaining)
        return
    end

    if info.isOnGCD == true then
        local startTime = SafeValue(info.startTime)
        local duration = SafeValue(info.duration)
        if type(startTime) == "number" and type(duration) == "number"
            and duration > 0 and duration <= MAX_GCD_DURATION then
            StartGCDFromTimes(startTime, duration)
        end
    end
end

local function CheckGCDEnd()
    if not gcdActive or isTest then
        return
    end

    local info = GetCooldownInfo(lastSpellID or lastBaseSpellID)
    if not info then
        return
    end

    local remaining = SafeValue(info.timeUntilEndOfStartRecovery)
    if type(remaining) == "number" and remaining <= 0 then
        ClearGCD()
    end
end

local function StartTest()
    local now = GetTime()
    isTest = true
    gcdActive = true
    gcdFromFallback = false
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
        PollGCD()
    end

    if not gcdActive or not gcdEndTime then
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
    Print("last spell: " .. Describe(lastSpellID)
        .. " base: " .. Describe(lastBaseSpellID)
        .. " category: " .. Describe(lastCategory)
        .. " startRecovery: " .. Describe(lastStartRecoveryCategory)
        .. " item: " .. Describe(lastItemID))
    Print("global recovery category: " .. tostring(GLOBAL_RECOVERY_CATEGORY))

    local info = GetCooldownInfo(lastSpellID or lastBaseSpellID)
    if info then
        Print("start=" .. Describe(info.startTime)
            .. " duration=" .. Describe(info.duration)
            .. " active=" .. Describe(info.isActive)
            .. " onGCD=" .. Describe(info.isOnGCD)
            .. " startRecovery=" .. Describe(info.timeUntilEndOfStartRecovery))
    else
        Print("no cooldown info for the last spell")
    end

    Print("tracking: " .. tostring(gcdActive)
        .. " fallback: " .. tostring(gcdFromFallback)
        .. " known GCD: " .. Describe(lastKnownGCDDuration))
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

local function OnSpellUpdateCooldown(spellID, baseSpellID, category, startRecoveryCategory, itemID)
    local safeSpellID = SafeValue(spellID)
    local safeBaseSpellID = SafeValue(baseSpellID)
    local recovery = SafeValue(startRecoveryCategory)

    lastSpellID = safeSpellID or safeBaseSpellID or lastSpellID
    lastBaseSpellID = safeBaseSpellID or lastBaseSpellID
    lastCategory = SafeValue(category)
    lastStartRecoveryCategory = recovery
    lastItemID = SafeValue(itemID)

    if recovery == GLOBAL_RECOVERY_CATEGORY then
        TryStartGCD(lastSpellID, true)
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("SPELL_UPDATE_COOLDOWN")
events:RegisterEvent("UNIT_SPELLCAST_START")
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
events:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
events:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
events:RegisterEvent("UNIT_SPELLCAST_FAILED")

events:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= addonName then
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
        OnSpellUpdateCooldown(...)
    elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_SUCCEEDED"
        or event == "UNIT_SPELLCAST_CHANNEL_START" then
        local unit, _, spellID = ...
        if unit == "player" then
            local safeSpellID = SafeValue(spellID)
            if safeSpellID then
                lastSpellID = safeSpellID
            end
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        local unit = ...
        if unit == "player" then
            CheckGCDEnd()
        end
    end
end)
