local _, RG = ...
local UI = RG.Register("UI", {})
local M = RG.UIModel
local BANNER_PRIORITY = { sighting = 20, returning = 30, wave = 35, targeting = 70, watch = 90, stealth = 100 }
local BANNER_CATEGORIES = { returning = "returningTitle", watch = "watchTitle", watched = "watchTitle", avoid = "watchTitle",
    stealth = "stealthTitle", targeting = "targetingTitle", wave = "waveTitle" }
local BANNER_QUEUE_LIMIT, BANNER_URGENT_PRIORITY = 8, 70
local BANNER_ORDINARY_MAX_AGE, BANNER_URGENT_MAX_AGE = 2, 5
local LIST_KIND_KEYS = { watch = "watched", avoid = "avoided", ignore = "ignored", note = "notesOnly" }
local LIST_FILTERS = { "all", "watch", "avoid", "ignore", "note" }
local SOUND_EVENT_KEYS = { sighting = "eventSighting", returning = "eventReturning", targeting = "eventTargeting",
    stealth = "eventStealth", watch = "eventWatch", wave = "eventWave" }
local SOUND_STATUS_KEYS = { not_requested = "lastSoundNotRequested", sound_gap = "lastSoundGap",
    playback_requested = "lastSoundRequested", playback_unconfirmed = "lastSoundUnconfirmed" }
local WINDOW_MARGIN = 12
local NEARBY_DEFAULT_X, NEARBY_DEFAULT_Y = -70, 20
local nativeSettings = {}

UI.layout = { width = 348, header = 88, footer = 58, rowPadding = 20, settingsWidth = 800, settingsHeight = 610 }

local C = {
    bg = { 0.035, 0.045, 0.065, 1 }, panel = { 0.065, 0.080, 0.105, 1 },
    text = { 0.93, 0.95, 1 }, muted = { 0.63, 0.70, 0.79 }, accent = { 0.37, 0.78, 0.92 },
    gold = { 1, 0.79, 0.30 }, danger = { 1, 0.42, 0.38 }, border = { 0.22, 0.30, 0.39, 1 },
}

local function font(parent, size, color, align)
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetFont(STANDARD_TEXT_FONT or "Fonts\\ARIALN.TTF", size or 13, "")
    text:SetTextColor(unpack(color or C.text))
    text:SetJustifyH(align or "LEFT")
    text:SetJustifyV("TOP")
    return text
end

local function paintText(widget, value)
    if widget.paintedText == value then return end
    widget:SetText(value)
    widget.paintedText = value
end

local function fitCenterOffset(offset, viewport, size, scale)
    local limit = math.max(0, ((viewport - size * scale) / 2 - WINDOW_MARGIN) / scale)
    return math.max(-limit, math.min(offset, limit))
end

local function paintShown(widget, shown)
    if widget.paintedShown == shown then return end
    widget:SetShown(shown)
    widget.paintedShown = shown
end

local function paintEnabled(widget, enabled)
    if widget.paintedEnabled == enabled then return end
    widget:SetEnabled(enabled)
    widget.paintedEnabled = enabled
end

local function fill(frame, color)
    local texture = frame:CreateTexture(nil, "BACKGROUND")
    texture:SetAllPoints()
    texture:SetColorTexture(unpack(color or C.bg))
    return texture
end

local function outline(frame, color)
    local sides = {}
    for i = 1, 4 do
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetColorTexture(unpack(color or C.border))
        sides[i] = t
    end
    sides[1]:SetPoint("TOPLEFT"); sides[1]:SetPoint("TOPRIGHT"); sides[1]:SetHeight(1)
    sides[2]:SetPoint("BOTTOMLEFT"); sides[2]:SetPoint("BOTTOMRIGHT"); sides[2]:SetHeight(1)
    sides[3]:SetPoint("TOPLEFT"); sides[3]:SetPoint("BOTTOMLEFT"); sides[3]:SetWidth(1)
    sides[4]:SetPoint("TOPRIGHT"); sides[4]:SetPoint("BOTTOMRIGHT"); sides[4]:SetWidth(1)
    return sides
end

local function button(parent, text, width, action)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 112, 28)
    b.bg = fill(b, C.panel)
    outline(b)
    b.label = font(b, 12, C.text, "CENTER")
    b.label:SetPoint("LEFT", 7, 0); b.label:SetPoint("RIGHT", -7, 0)
    b.label:SetJustifyV("MIDDLE")
    b.label:SetText(text)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b:SetScript("OnClick", function() if action then action() end end)
    return b
end

local function tooltip(frame, title, body)
    if not GameTooltip then return end
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:SetText(title or "RivalGuard", 1, 1, 1)
    if body and body ~= "" then GameTooltip:AddLine(body, 0.75, 0.82, 0.90, true) end
    GameTooltip:Show()
end

local function hideTooltip()
    if GameTooltip then GameTooltip:Hide() end
end

local function classColor(token)
    local color = (RAID_CLASS_COLORS or {})[token]
    if color then return color.r, color.g, color.b end
    return unpack(C.text)
end

local function paintNearbyRow(row, data, index, profile)
    row.contact = data and data.contact or nil
    if not data then paintShown(row, false); return end

    local display = profile.display
    local textSize = display.textSize
    local face = STANDARD_TEXT_FONT or "Fonts\\ARIALN.TTF"
    if row.paintedSize ~= textSize then
        local height = textSize + UI.layout.rowPadding
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 8, -UI.layout.header - (index - 1) * height)
        row:SetHeight(height)
        row.detailText:ClearAllPoints(); row.detailText:SetPoint("TOPLEFT", 36, -textSize - 5)
    end
    if row.paintedSize ~= textSize or row.paintedFace ~= face then
        row.nameText:SetFont(face, textSize, "")
        row.detailText:SetFont(face, math.max(10, textSize - 2), "")
        row.nameText.paintedText, row.detailText.paintedText = nil, nil
        row.paintedSize, row.paintedFace = textSize, face
    end
    paintText(row.nameText, data.name)
    local red, green, blue
    if data.class and not display.highContrast then red, green, blue = classColor(data.class)
    else red, green, blue = unpack(C.text) end
    if red ~= row.nameRed or green ~= row.nameGreen or blue ~= row.nameBlue then
        row.nameText:SetTextColor(red, green, blue)
        row.nameRed, row.nameGreen, row.nameBlue = red, green, blue
    end
    local level = M.Number(data.contact.level)
    local detail = level and (RG.Locale.Format("levelShort", profile.locale, level) .. " · " .. data.detail) or data.detail
    paintText(row.detailText, detail)
    if row.detailContrast ~= display.highContrast then
        row.detailText:SetTextColor(unpack(display.highContrast and C.text or C.muted))
        row.detailContrast = display.highContrast
    end
    local iconClass = data.class or ""
    if row.iconClass ~= iconClass then
        row.icon:SetTexture(data.class and ("Interface\\Icons\\ClassIcon_" .. data.class) or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.iconClass = iconClass
    end
    local alpha = data.visible and 1 or display.highContrast and 0.9 or 0.65
    if row.paintedAlpha ~= alpha then row:SetAlpha(alpha); row.paintedAlpha = alpha end
    local currentTarget = data.visible and data.contact.currentTarget == true
    local currentFocus = data.visible and data.contact.currentFocus == true
    paintText(row.mark, currentTarget and "▼" or currentFocus and "◆" or "!")
    paintShown(row.mark, data.contact.watched == true or data.contact.listKind == "avoid" or currentTarget or currentFocus)
    paintShown(row, true)
end

local function pathGet(profile, path)
    local value = profile
    for key in path:gmatch("[^.]+") do
        if type(value) ~= "table" then return nil end
        value = value[key]
    end
    return value
end

local function pathSet(profile, path, value)
    local target, last = profile, nil
    for key in path:gmatch("[^.]+") do
        if last then target = target[last] end
        last = key
    end
    target[last] = value
end

function UI.New(app)
    local self = { app = app, aliases = {}, previewAliases = {}, offset = 0, profileOffset = 0, journalOffset = 0, rows = {}, controls = {}, pages = {}, localized = {}, windows = {}, bannerQueue = {}, selected = nil }
    -- Keep partial initialization reachable so the caller can clean it up.
    app.ui = self

    function self:Destroy()
        if self.destroyed then return end
        self.destroyed = true
        if self.ticker then self.ticker:SetScript("OnUpdate", nil); self.ticker:UnregisterAllEvents() end
        if self.badges then self.badges:Destroy() end
        if self.launcher then self.launcher:Destroy() end
        if nativeSettings.owner == self then
            nativeSettings.owner = nil
            if nativeSettings.panel and nativeSettings.panel.open then nativeSettings.panel.open:SetEnabled(false) end
        end
        for name, frame in pairs(self.windows) do
            frame:Hide()
            if _G[name] == frame then _G[name] = nil end
        end
        if UISpecialFrames then
            for i = #UISpecialFrames, 1, -1 do
                if self.windows[UISpecialFrames[i]] then table.remove(UISpecialFrames, i) end
            end
        end
    end

    function self:Window(name, parent)
        -- Escape uses the global reference; anonymous native frames remain safe to recreate.
        local frame = CreateFrame("Frame", nil, parent or UIParent)
        self.windows[name] = frame
        _G[name] = frame
        return frame
    end

    function self:FitWindow(frame, width, height, requested)
        local screenWidth = M.Number(UIParent:GetWidth(), 1920)
        local screenHeight = M.Number(UIParent:GetHeight(), 1080)
        local scale = math.min(requested or 1, math.max(0.1, (screenWidth - 2 * WINDOW_MARGIN) / width),
            math.max(0.1, (screenHeight - 2 * WINDOW_MARGIN) / height))
        if frame.paintedScale ~= scale then
            frame:SetScale(scale)
            frame.paintedScale = scale
        end
        return scale, screenWidth, screenHeight
    end

    function self:FitOffsetWindow(frame, x, y)
        local width, height = frame:GetWidth(), frame:GetHeight()
        local scale, screenWidth, screenHeight = self:FitWindow(frame, width, height, 1)
        x = fitCenterOffset(x, screenWidth, width, scale)
        y = fitCenterOffset(y, screenHeight, height, scale)
        if frame.paintedCenterX == x and frame.paintedCenterY == y then return end
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
        frame.paintedCenterX, frame.paintedCenterY = x, y
    end

    function self:RegisterNativeSettings()
        if self.destroyed or not app.initialized then return false end
        if nativeSettings.registered then
            nativeSettings.owner = self
            self.nativeSettingsPanel = nativeSettings.panel
            self.nativeSettingsPanel.OnRefresh()
            return true
        end
        if nativeSettings.attempted then return false end
        local api = app.api and app.api.Settings or Settings
        if type(api) ~= "table" or type(api.RegisterCanvasLayoutCategory) ~= "function" or type(api.RegisterAddOnCategory) ~= "function" then
            return false
        end
        -- Settings cannot unregister a category. Never replay an attempt with an uncertain outcome.
        nativeSettings.attempted = true
        local ok, panel = pcall(function()
            local frame = CreateFrame("Frame", nil, UIParent)
            frame:Hide()
            frame.title = font(frame, 23, C.accent)
            frame.title:SetPoint("TOPLEFT", 24, -32); frame.title:SetText("RivalGuard")
            frame.description = font(frame, 14, C.text)
            frame.description:SetPoint("TOPLEFT", 24, -76); frame.description:SetPoint("TOPRIGHT", -24, -76)
            frame.open = button(frame, "", 280, function()
                local owner = nativeSettings.owner
                if owner and not owner.destroyed then owner:OpenSettings() end
            end)
            frame.open:SetPoint("TOPLEFT", 24, -155)
            frame.OnRefresh = function()
                local owner = nativeSettings.owner
                local available = owner and not owner.destroyed
                frame.description:SetText(available and owner:T("nativeSettingsHelp") or RG.Locale.Get("nativeUnavailable"))
                frame.open.label:SetText(available and owner:T("openSettings") or RG.Locale.Get("openSettings"))
                frame.open:SetEnabled(available == true)
            end
            frame:SetScript("OnShow", frame.OnRefresh)
            local category = api.RegisterCanvasLayoutCategory(frame, "RivalGuard")
            if type(category) ~= "table" then return nil end
            api.RegisterAddOnCategory(category)
            return frame
        end)
        if not ok or not panel then return false end
        nativeSettings.registered, nativeSettings.panel, nativeSettings.owner = true, panel, self
        self.nativeSettingsPanel = panel
        panel.OnRefresh()
        return true
    end

    function self:Profile() return app.db:GetProfile() end
    function self:T(key) return RG.Locale.Get(key, self:Profile().locale) end
    function self:F(key, ...) return RG.Locale.Format(key, self:Profile().locale, ...) end
    function self:Now() return app.engine:Now() end
    function self:AlertBlock() return app.AlertBlock and app:AlertBlock() end

    function self:DetectionKey(status)
        local state = type(status) == "table" and (status.detectionState or status.state)
        if not self:Profile().enabled or state == "disabled" then return "disabled" end
        if state == "limited" then return "limited" end
        return "active"
    end

    function self:UpdateClasses()
        if self.classAvailability then return end
        local tokens, known
        if app.SupportedClasses then tokens, known = app:SupportedClasses() end
        self.classAvailability = nil
        if known and type(tokens) == "table" then
            local available = {}
            for _, token in ipairs(tokens) do if RG.Defaults.classSet[token] then available[token] = true end end
            if next(available) then self.classAvailability = available; self.controlsDirty = true end
        end
    end

    function self:SettingsChanged()
        self.controlsDirty = true
        self.dataPage = nil
        if self.badges then self.badges:ClearHighlight() end
        local profile = self:Profile()
        if profile.display.streamer then
            if self.journalSearch then self.journalSearch:SetText(""); self.journalSearch:ClearFocus() end
            if self.detailsFrame then self.detailsFrame.note:ClearFocus(); self.detailsFrame.note:SetText("") end
            hideTooltip()
        end
        local config = self:AlertConfig(profile)
        if self.alertProfile ~= profile or self.alertConfig ~= config then self:ClearBanners() end
        self.alertProfile, self.alertConfig = profile, config
        if self.activeBanner then self:PaintBanner(self.activeBanner) end
        self:Refresh()
    end

    function self:AlertConfig(profile)
        if not RG.Codec then return nil end
        return RG.Codec.Encode({ enabled = profile.enabled, alerts = profile.alerts, context = profile.context,
            range = profile.range, rules = profile.rules })
    end

    local function label(parent, key, size, color)
        local text = font(parent, size, color)
        text:SetText(self:T(key))
        self.localized[#self.localized + 1] = { text = text, key = key }
        return text
    end

    local function localButton(parent, key, width, action)
        local b = button(parent, self:T(key), width, action)
        self.localized[#self.localized + 1] = { text = b.label, key = key }
        return b
    end

    local function changed()
        if app.OnSettingsChanged then app:OnSettingsChanged() else app:ProfileChanged() end
        self:SettingsChanged()
    end

    local function listEntry(contact)
        if app.ResolveList then return app:ResolveList(contact) end
        local identity = M.EditableIdentity(contact)
        if identity then return app.db:GetList()[identity], identity end
    end

    local function journalListEntry(identity)
        if app.ResolveJournalListEntry then return app:ResolveJournalListEntry(identity) end
        return app.db:GetList()[identity]
    end

    local function setList(contact, kind, note)
        if app.SetList then return app:SetList(contact, kind, note) end
        local identity = M.EditableIdentity(contact)
        if not identity then return nil end
        local ok = app.db.SetList and app.db:SetList(identity, kind, note, contact)
        if ok then app:ProfileChanged() end
        return ok
    end

    local function notify(key)
        if app.Notify then app:Notify(self:T(key)) end
    end

    local allowedPoints = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

    local function restorePosition(frame, key, point, x, y)
        local saved = self:Profile().positions[key]
        local relative = type(saved) == "table" and (saved.relativePoint or saved.relative)
        if type(saved) == "table" and allowedPoints[saved.point] and allowedPoints[relative] then
            point, x, y = saved.point, M.Number(saved.x, x), M.Number(saved.y, y)
            frame:ClearAllPoints()
            frame:SetPoint(point, UIParent, relative, x, y)
        else
            frame:ClearAllPoints()
            frame:SetPoint(point, UIParent, point, x, y)
        end
        frame:SetUserPlaced(true)
    end

    local function savePosition(frame, key)
        local point, _, relative, x, y = frame:GetPoint(1)
        x, y = M.Number(x), M.Number(y)
        if allowedPoints[point] and allowedPoints[relative] and x and y then
            self:Profile().positions[key] = { point = point, relativePoint = relative, x = x, y = y }
            return true
        end
    end

    local function bannerDefaultPoint()
        local width = M.Number(UIParent:GetWidth(), 1920)
        if width <= 1150 then return -math.min(108, math.max(0, (width - 465) / 2)) end
        return 0
    end

    local main = self:Window("RivalGuardNearby", UIParent)
    self.frame = main
    main:SetSize(UI.layout.width, 410)
    main:SetFrameStrata("MEDIUM")
    main:SetClampedToScreen(true)
    main:SetMovable(true)
    main:EnableMouseWheel(true)
    local mainBackground = fill(main); local mainBorder = outline(main)
    local nearbyMoveProfile, nearbyDefaultX, nearbyDefaultY
    local function restoreNearby()
        if nearbyMoveProfile then main:StopMovingOrSizing(); nearbyMoveProfile = nil end
        restorePosition(main, "nearby", "RIGHT", NEARBY_DEFAULT_X, NEARBY_DEFAULT_Y)
        nearbyDefaultX, nearbyDefaultY = NEARBY_DEFAULT_X, NEARBY_DEFAULT_Y
    end

    local function fitNearby(height, profile)
        if nearbyMoveProfile then return end
        local width = UI.layout.width
        local scale, screenWidth, screenHeight = self:FitWindow(main, width, height, profile.display.scale)
        local saved = profile.positions.nearby
        -- Older builds saved the stock anchor on logout. Fit it like a default.
        if saved and not (saved.point == "RIGHT" and (saved.relativePoint or saved.relative) == "RIGHT"
            and saved.x == NEARBY_DEFAULT_X and saved.y == NEARBY_DEFAULT_Y) then return end
        local x = math.max(NEARBY_DEFAULT_X, -math.max(0, (screenWidth - WINDOW_MARGIN) / scale - width))
        local y = fitCenterOffset(NEARBY_DEFAULT_Y, screenHeight, height, scale)
        if x == nearbyDefaultX and y == nearbyDefaultY then return end
        main:ClearAllPoints()
        main:SetPoint("RIGHT", UIParent, "RIGHT", x, y)
        nearbyDefaultX, nearbyDefaultY = x, y
    end
    restoreNearby()

    local header = CreateFrame("Button", nil, main)
    header:SetPoint("TOPLEFT", 0, 0); header:SetPoint("TOPRIGHT", -34, 0); header:SetHeight(28)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function()
        local profile = self:Profile()
        if profile.display.locked then return end
        nearbyMoveProfile = profile
        main:StartMoving()
    end)
    header:SetScript("OnDragStop", function()
        if not nearbyMoveProfile then return end
        main:StopMovingOrSizing()
        local moveProfile = nearbyMoveProfile
        nearbyMoveProfile = nil
        if moveProfile == self:Profile() and not savePosition(main, "nearby") then restoreNearby() end
    end)
    local title = label(header, "addon", 15, C.accent)
    title:SetPoint("LEFT", 12, 0); title:SetJustifyV("MIDDLE")
    local settingsButton = button(main, "…", 30)
    self.nearbySettingsButton = settingsButton
    settingsButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    settingsButton:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then self:OpenProfilePicker() else self:OpenSettings() end
    end)
    settingsButton:SetPoint("TOPRIGHT", -3, -2); settingsButton:SetHeight(25)
    settingsButton:SetScript("OnEnter", function()
        tooltip(settingsButton, self:F("currentProfileChoice", app.db:GetActiveProfileName()), self:T("profilePickerTip"))
    end)
    settingsButton:SetScript("OnLeave", hideTooltip)
    local statusText = font(main, 11, C.muted)
    statusText:SetPoint("TOPLEFT", 12, -31); statusText:SetWidth(324)
    self.statusText = statusText

    local function makeClassChips(parent, x, y, group, compact)
        local chips = {}
        local alertClasses = group == "alerts"
        local size, gap = compact and 21 or 29, compact and 3 or 7
        for i, token in ipairs(RG.Defaults.classes) do
            local class = token
            local chip = CreateFrame("Button", nil, parent)
            chip:SetSize(size, size)
            chip:SetPoint("TOPLEFT", x + (i - 1) * (size + gap), y)
            chip.bg = fill(chip, C.panel)
            chip.icon = chip:CreateTexture(nil, "ARTWORK")
            chip.icon:SetPoint("TOPLEFT", 2, -2); chip.icon:SetPoint("BOTTOMRIGHT", -2, 2)
            chip.icon:SetTexture("Interface\\Icons\\ClassIcon_" .. class)
            chip.edge = outline(chip)
            if alertClasses then chip:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
            chip:SetScript("OnClick", function(_, mouseButton)
                local settings = self:Profile()[group]
                if alertClasses and mouseButton == "RightButton" then
                    if settings.classes[class] == true and next(settings.classes) == class
                        and not next(settings.classes, class) and not settings.unknownClass then return end
                    settings.classes = { [class] = true }
                    settings.unknownClass = false
                else
                    settings.classes = M.ToggleClass(settings.classes, class)
                end
                changed()
            end)
            chip:SetScript("OnEnter", function()
                tooltip(chip, RG.Locale.Class(class, self:Profile().locale), self:T(alertClasses and "classSoloTip" or "displayClasses"))
            end)
            chip:SetScript("OnLeave", hideTooltip)
            chips[#chips + 1] = { frame = chip, class = class, group = group }
        end
        self.controls[#self.controls + 1] = { kind = "classes", chips = chips, x = x, y = y, size = size, gap = gap }
        return chips
    end

    self.quickChips = makeClassChips(main, 12, -53, "display", true)

    local empty = label(main, "noEnemies", 14, C.text)
    empty:SetPoint("TOPLEFT", 15, -104); empty:SetWidth(318); empty:SetJustifyH("CENTER")
    local emptyHelp = label(main, "noEnemiesHelp", 11, C.muted)
    emptyHelp:SetPoint("TOPLEFT", 20, -130); emptyHelp:SetWidth(308); emptyHelp:SetJustifyH("CENTER")
    emptyHelp:SetHeight(63)
    self.empty, self.emptyHelp = empty, emptyHelp

    for i = 1, 20 do
        local row = CreateFrame("Button", nil, main)
        row:SetPoint("TOPLEFT", 8, -UI.layout.header - (i - 1) * 33)
        row:SetSize(UI.layout.width - 16, 33)
        row.bg = fill(row, { 0.09, 0.115, 0.15, i % 2 == 0 and 0.7 or 0.25 })
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetPoint("LEFT", 6, 0); row.icon:SetSize(22, 22)
        row.nameText = font(row, 13)
        row.nameText:SetPoint("TOPLEFT", 36, -2); row.nameText:SetWidth(252)
        if row.nameText.SetMaxLines then row.nameText:SetMaxLines(1) end
        row.detailText = font(row, 10, C.muted)
        row.detailText:SetPoint("TOPLEFT", 36, -19); row.detailText:SetWidth(280)
        if row.detailText.SetMaxLines then row.detailText:SetMaxLines(1) end
        row.mark = font(row, 15, C.gold, "RIGHT")
        row.mark:SetPoint("TOPRIGHT", -8, -3); row.mark:SetText("!")
        row:SetScript("OnClick", function() if row.contact then self:Select(row.contact) end end)
        row:SetScript("OnEnter", function()
            if not row.contact then return end
            tooltip(row, row.nameText:GetText(), self:T("rowHint") .. "\n" .. self:T("noTarget"))
        end)
        row:SetScript("OnLeave", hideTooltip)
        paintShown(row, false)
        self.rows[i] = row
    end

    local more = font(main, 10, C.muted, "CENTER")
    more:SetPoint("BOTTOMLEFT", 10, 43); more:SetPoint("BOTTOMRIGHT", -10, 43); self.moreText = more
    function self:TogglePause()
        local untilTime = M.Number(app.engine.pausedUntil)
        local paused = untilTime and untilTime > self:Now()
        if paused then app.engine:Resume() else app.engine:Pause(600); self:ClearBanners() end
        self:Refresh()
    end
    local pauseButton = button(main, self:T("pause"), 118, function() self:TogglePause() end)
    pauseButton:SetPoint("BOTTOMLEFT", 10, 9); self.pauseButton = pauseButton
    local muteButton = button(main, self:T("mute"), 111, function() app:ToggleMute(); self:SettingsChanged() end)
    muteButton:SetPoint("LEFT", pauseButton, "RIGHT", 5, 0); self.muteButton = muteButton
    local demoButton = localButton(main, "demo", 85, function() app:Demo() end)
    demoButton:SetPoint("LEFT", muteButton, "RIGHT", 5, 0)
    demoButton:SetScript("OnEnter", function() tooltip(demoButton, self:T("demo"), self:T("demoTip")) end)
    demoButton:SetScript("OnLeave", hideTooltip)
    main:SetScript("OnMouseWheel", function(_, delta)
        local count = self.renderedCount or 0
        self.offset = math.max(0, math.min(math.max(0, count - self:Profile().display.maxRows), self.offset - delta))
        self:Refresh()
    end)

    local banner = self:Window("RivalGuardAlert", UIParent)
    self.banner = banner
    banner:SetSize(440, 84); banner:SetFrameStrata("HIGH"); banner:SetClampedToScreen(true)
    banner:SetMovable(true); banner:EnableMouse(false)
    fill(banner, { 0.035, 0.05, 0.075, 1 }); self.bannerOutline = outline(banner, { 0.37, 0.78, 0.92, 1 })
    local function restoreBanner()
        self.bannerDefaultOffset = bannerDefaultPoint()
        restorePosition(banner, "alert", "TOP", self.bannerDefaultOffset, -180)
    end
    local function cancelBannerMove()
        if not self.bannerMoveProfile then return end
        banner:StopMovingOrSizing()
        self.bannerMoveProfile = nil
        restoreBanner()
    end
    restoreBanner()
    banner.icon = banner:CreateTexture(nil, "ARTWORK")
    banner.icon:SetPoint("LEFT", 14, 0); banner.icon:SetSize(42, 42)
    banner.title = font(banner, 16, C.accent)
    banner.title:SetPoint("TOPLEFT", 70, -14); banner.title:SetWidth(350)
    if banner.title.SetMaxLines then banner.title:SetMaxLines(1) end
    banner.body = font(banner, 13)
    banner.body:SetPoint("TOPLEFT", 70, -40); banner.body:SetWidth(350); banner.body:SetHeight(38)
    banner:RegisterForDrag("LeftButton")
    banner:SetScript("OnDragStart", function()
        if self.bannerPreview then self.bannerMoveProfile = self:Profile(); banner:StartMoving() end
    end)
    banner:SetScript("OnDragStop", function()
        if not self.bannerMoveProfile then return end
        local originalProfile = self.bannerMoveProfile
        self.bannerMoveProfile = nil
        banner:StopMovingOrSizing()
        if originalProfile == self:Profile() and self.bannerPreview then savePosition(banner, "alert") end
    end)
    banner:Hide()

    local settings = self:Window("RivalGuardSettings", UIParent)
    self.settings = settings
    settings:SetSize(UI.layout.settingsWidth, UI.layout.settingsHeight)
    settings:SetPoint("CENTER"); settings:SetFrameStrata("DIALOG"); settings:SetClampedToScreen(true)
    settings:SetMovable(true); settings:EnableMouse(true)
    fill(settings); outline(settings)
    local settingsHeader = CreateFrame("Button", nil, settings)
    settingsHeader:SetPoint("TOPLEFT", 0, 0); settingsHeader:SetPoint("TOPRIGHT", -100, 0); settingsHeader:SetHeight(47)
    settingsHeader:RegisterForDrag("LeftButton")
    settingsHeader:SetScript("OnDragStart", function() settings:StartMoving() end)
    settingsHeader:SetScript("OnDragStop", function() settings:StopMovingOrSizing() end)
    local settingsTitle = font(settingsHeader, 19, C.accent)
    settingsTitle:SetPoint("LEFT", 18, 0); settingsTitle:SetText("RivalGuard")
    local settingsClose = localButton(settings, "close", 84, function() settings:Hide() end)
    settingsClose:SetPoint("TOPRIGHT", -12, -10)
    local settingsHint = label(settings, "settingsHint", 11, C.muted)
    settingsHint:SetPoint("TOPLEFT", 184, -54); settingsHint:SetWidth(566)
    if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "RivalGuardSettings" end

    local scroll = CreateFrame("ScrollFrame", nil, settings)
    scroll:SetPoint("TOPLEFT", 180, -82); scroll:SetPoint("BOTTOMRIGHT", -32, 16)
    scroll:EnableMouseWheel(true)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(570, 1000); scroll:SetScrollChild(content)
    self.content = content
    local scrollbar = CreateFrame("Slider", nil, settings)
    scrollbar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 7, 0); scrollbar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 7, 0)
    scrollbar:SetWidth(12); scrollbar:SetOrientation("VERTICAL"); scrollbar:SetMinMaxValues(0, 500); scrollbar:SetValueStep(1)
    fill(scrollbar, C.panel)
    scrollbar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    scrollbar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value) end)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local maximum = math.max(0, (self.pageHeight or 0) - scroll:GetHeight())
        scrollbar:SetValue(math.max(0, math.min(maximum, scrollbar:GetValue() - delta * 40)))
    end)
    self.scroll, self.scrollbar = scroll, scrollbar
    settings:Hide()

    local function resizeSettingsPage(height, resetScroll)
        self.pageHeight = height
        content:SetHeight(height)
        local maximum = math.max(0, height - scroll:GetHeight())
        scrollbar:SetMinMaxValues(0, maximum)
        scrollbar:SetValue(resetScroll and 0 or math.min(maximum, scrollbar:GetValue()))
    end

    local function section(page, key, y, explanation)
        local h = label(page, key, 16, C.accent)
        h:SetPoint("TOPLEFT", 0, y); h:SetWidth(550)
        if explanation then
            local desc = label(page, explanation, 12, C.muted)
            desc:SetPoint("TOPLEFT", 0, y - 28); desc:SetWidth(550)
            return y - 78
        end
        return y - 36
    end

    local function check(page, key, path, y, tip)
        local b = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
        b:SetPoint("TOPLEFT", -2, y); b:SetSize(26, 26)
        local t = label(b, key, 13)
        t:SetPoint("LEFT", b, "RIGHT", 3, 0); t:SetWidth(515); t:SetJustifyV("MIDDLE")
        b:SetHitRectInsets(0, -510, 0, 0)
        b:SetScript("OnClick", function() pathSet(self:Profile(), path, b:GetChecked() and true or false); changed() end)
        b:SetScript("OnEnter", function() tooltip(b, self:T(key), self:T(tip or key)) end)
        b:SetScript("OnLeave", hideTooltip)
        self.controls[#self.controls + 1] = { kind = "check", frame = b, path = path }
        return y - 34
    end

    local function slider(page, key, path, y, low, high, step, tip)
        local t = label(page, key, 13)
        t:SetPoint("TOPLEFT", 0, y); t:SetWidth(370)
        local valueText = font(page, 13, C.accent, "RIGHT")
        valueText:SetPoint("TOPRIGHT", -16, y); valueText:SetWidth(130)
        local s = CreateFrame("Slider", nil, page)
        s:SetPoint("TOPLEFT", 4, y - 29); s:SetSize(532, 16); s:SetOrientation("HORIZONTAL")
        s:SetMinMaxValues(low, high); s:SetValueStep(step)
        if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
        fill(s, C.panel); outline(s)
        s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        s:SetScript("OnValueChanged", function(_, value)
            if self.refreshingControls then return end
            value = math.floor(value / step + 0.5) * step
            pathSet(self:Profile(), path, value)
            valueText:SetText(step < 1 and string.format("%.2g", value) or tostring(value))
            changed()
        end)
        s:SetScript("OnEnter", function() tooltip(s, self:T(key), self:T(tip or key)) end)
        s:SetScript("OnLeave", hideTooltip)
        self.controls[#self.controls + 1] = { kind = "slider", frame = s, path = path, valueText = valueText, step = step }
        return y - 65
    end

    local function choice(page, key, path, options, y, width, soundPicker)
        local titleText = label(page, key, 13)
        titleText:SetPoint("TOPLEFT", 0, y); titleText:SetWidth(550)
        local b
        b = button(page, "", width or 400, function()
            local profile = self:Profile()
            if soundPicker and self.OpenSoundPicker then
                self:OpenSoundPicker(b, options, function()
                    if self:Profile() == profile then return pathGet(profile, path) end
                end, function(value)
                    if pathGet(profile, path) == value then return end
                    pathSet(profile, path, value)
                    changed()
                end)
                return
            end
            local current = pathGet(profile, path)
            local index = 0
            for i, option in ipairs(options) do if option[1] == current then index = i break end end
            pathSet(self:Profile(), path, options[index % #options + 1][1])
            changed()
        end)
        b:SetPoint("TOPLEFT", 0, y - 25)
        self.controls[#self.controls + 1] = { kind = "choice", frame = b, path = path, options = options }
        return y - 65
    end

    local function classSelector(page, group, y)
        local titleText = label(page, group == "display" and "displayClasses" or "alertClasses", 13)
        titleText:SetPoint("TOPLEFT", 0, y); titleText:SetWidth(group == "alerts" and 290 or 550)
        makeClassChips(page, 0, y - 28, group, false)
        local allButton = localButton(page, "all", 160, function() self:Profile()[group].classes = {}; changed() end)
        allButton:SetPoint("TOPLEFT", 0, y - 69)
        local clearButton = localButton(page, "clearClassSelection", 140, function()
            self:Profile()[group].classes = M.ClearClasses()
            changed()
        end)
        clearButton:SetPoint("LEFT", allButton, "RIGHT", 12, 0)
        clearButton:SetScript("OnEnter", function()
            tooltip(clearButton, self:T("clearClassSelection"), self:T("clearClassSelectionTip"))
        end)
        clearButton:SetScript("OnLeave", hideTooltip)
        if group == "alerts" then
            local soloHint = label(page, "classSoloHint", 12, C.muted)
            soloHint:SetPoint("TOPRIGHT", -20, y); soloHint:SetWidth(250); soloHint:SetJustifyH("RIGHT")
            self.alertAllClassesButton = allButton
            local presetButton = localButton(page, "hunterRogueClasses", 220, function()
                local alerts = self:Profile().alerts
                alerts.classes = { HUNTER = true, ROGUE = true }
                alerts.unknownClass = false
                changed()
            end)
            presetButton:SetPoint("LEFT", clearButton, "RIGHT", 12, 0)
            presetButton:SetScript("OnEnter", function()
                tooltip(presetButton, self:T("hunterRogueClasses"), self:T("hunterRogueClassesTip"))
            end)
            presetButton:SetScript("OnLeave", hideTooltip)
            self.hunterRogueButton = presetButton
            return check(page, "alertUnknownClass", "alerts.unknownClass", y - 108, "alertUnknownClassTip")
        end
        return y - 110
    end

    local overview = CreateFrame("Frame", nil, content); self.pages.overview = overview
    overview:SetAllPoints()
    local y = section(overview, "overview", 0, "statusHelp")
    y = check(overview, "enabled", "enabled", y, "enabledTip")
    y = check(overview, "showList", "display.showList", y, "showListTip")
    y = check(overview, "showUnknown", "display.showUnknown", y, "showUnknownTip")
    y = classSelector(overview, "display", y - 14)
    y = section(overview, "contexts", y - 6)
    for _, key in ipairs({ "world", "battleground", "arena", "instance", "sanctuary", "resting", "flight" }) do
        y = check(overview, key, "context." .. key, y)
    end
    y = choice(overview, "language", "locale", { { "auto", "automatic" }, { "enUS", "english" }, { "ruRU", "russian" } }, y - 12)
    overview.height = -y + 20

    local alerts = CreateFrame("Frame", nil, content); self.pages.alerts = alerts; alerts:SetAllPoints()
    y = section(alerts, "alerts", 0, "classesTip")
    self.advancedRulesButton = localButton(alerts, "rules", 200, function() if self.OpenRules then self:OpenRules() end end)
    self.advancedRulesButton:SetPoint("TOPRIGHT", -20, 0)
    y = classSelector(alerts, "alerts", y)
    self.alertProfileStatus = font(alerts, 13, C.gold)
    self.alertProfileStatus:SetPoint("TOPLEFT", 0, y - 4); self.alertProfileStatus:SetWidth(550)
    if self.alertProfileStatus.SetMaxLines then self.alertProfileStatus:SetMaxLines(1) end
    self.ordinaryAlertStatus = font(alerts, 12, C.text)
    self.ordinaryAlertStatus:SetPoint("TOPLEFT", 0, y - 25); self.ordinaryAlertStatus:SetWidth(550)
    self.returningAlertStatus = font(alerts, 12, C.text)
    self.returningAlertStatus:SetPoint("TOPLEFT", 0, y - 69); self.returningAlertStatus:SetWidth(550)
    y = section(alerts, "alertRange", y - 120)
    y = check(alerts, "rangeFilter", "range.enabled", y, "rangeFilterTip")
    local firstRangeControl = #self.controls + 1
    y = slider(alerts, "rangeYards", "range.yards", y - 6, 5, 100, 5)
    y = choice(alerts, "rangePolicy", "range.policy", { { "possible", "possible" }, { "confirmed", "confirmed" } }, y)
    y = check(alerts, "unknownRange", "range.unknown", y)
    for index = firstRangeControl, #self.controls do self.controls[index].requiresRange = true end
    y = section(alerts, "alertOutput", y - 8)
    for _, entry in ipairs({ { "alertsEnabled", "alerts.enabled" }, { "sound", "alerts.sound" }, { "banner", "alerts.banner" },
        { "alertStealth", "alerts.stealth", "alertStealthTip" }, { "alertTargeting", "alerts.targeting", "alertTargetingTip" },
        { "highlightTargeting", "display.highlightTargeting", "highlightTargetingTip" },
        { "watchedOnly", "alerts.watchedOnly", "watchedOnlyTip" }, { "muteOrdinary", "alerts.muteOrdinary", "muteOrdinaryTip" } }) do
        y = check(alerts, entry[1], entry[2], y, entry[3])
    end
    y = slider(alerts, "cooldown", "alerts.cooldown", y - 10, 5, 180, 5, "cooldownTip")
    y = slider(alerts, "returnAfter", "alerts.returnAfter", y, 5, 180, 5, "returnAfterTip")
    y = choice(alerts, "soundChannel", "alerts.channel", { { "Master", "master" }, { "SFX", "sfx" }, { "Dialog", "dialog" }, { "Music", "music" }, { "Ambience", "ambience" } }, y)
    y = section(alerts, "sounds", y - 4)
    local soundOptions = RG.Defaults.soundOptions
    for _, entry in ipairs({ { "sighting", "eventSighting" }, { "returning", "eventReturning" }, { "watch", "eventWatch" }, { "stealth", "eventStealth" }, { "targeting", "eventTargeting" }, { "wave", "eventWave" } }) do
        local kind = entry[1]
        local rowY = y
        y = choice(alerts, entry[2], "alerts.sounds." .. kind, soundOptions, y, 380, true)
        local listen = localButton(alerts, "previewSound", 150, function() if app.PreviewSound then app:PreviewSound(kind) end end)
        listen:SetPoint("TOPLEFT", 395, rowY - 25)
    end
    local previewAlert = localButton(alerts, "previewBanner", 200, function() self:PreviewAlert() end)
    previewAlert:SetPoint("TOPLEFT", 0, y - 6)
    alerts.height = -y + 60

    local appearance = CreateFrame("Frame", nil, content); self.pages.appearance = appearance; appearance:SetAllPoints()
    y = section(appearance, "appearance", 0, "appearanceHelp")
    for _, entry in ipairs({ { "locked", "display.locked" }, { "showBadges", "display.showBadges", "showBadgesTip" }, { "highContrast", "display.highContrast" }, { "reducedMotion", "display.reducedMotion" }, { "streamer", "display.streamer", "streamerTip" } }) do
        y = check(appearance, entry[1], entry[2], y, entry[3])
    end
    y = section(appearance, "badgeOptions", y - 8)
    y = check(appearance, "badgeTarget", "display.badgeTarget", y, "badgeTargetTip")
    y = check(appearance, "badgeFocus", "display.badgeFocus", y, "badgeFocusTip")
    y = slider(appearance, "badgeSize", "display.badgeSize", y - 6, 16, 40, 1)
    y = slider(appearance, "badgeOffset", "display.badgeOffset", y, 0, 30, 1)
    y = slider(appearance, "textSize", "display.textSize", y - 8, 11, 20, 1)
    y = slider(appearance, "scale", "display.scale", y, 0.75, 1.5, 0.05)
    y = slider(appearance, "maxRows", "display.maxRows", y, 3, 20, 1)
    y = section(appearance, "minimapLauncher", y - 6)
    y = check(appearance, "minimapLauncher", "display.minimap", y, "minimapLauncherTip")
    local launcherReset = localButton(appearance, "launcherReset", 310, function()
        local profile = self:Profile()
        profile.display.minimapAngle = RG.Defaults.profile.display.minimapAngle
        if self.launcher then self.launcher:Refresh() end
    end)
    launcherReset:SetPoint("TOPLEFT", 0, y)
    self.launcherReset = launcherReset
    y = y - 45
    local preview = localButton(appearance, "previewBanner", 200, function() self:PreviewAlert() end)
    preview:SetPoint("TOPLEFT", 0, y)
    local previewContacts = localButton(appearance, "previewList", 200, function() app:Demo() end)
    previewContacts:SetPoint("LEFT", preview, "RIGHT", 12, 0)
    local resetPos = localButton(appearance, "resetPosition", 260, function()
        self:Profile().positions = {}
        restoreNearby()
        cancelBannerMove(); restoreBanner()
        self:Refresh()
    end)
    resetPos:SetPoint("TOPLEFT", 0, y - 45)
    appearance.height = -y + 100

    local profiles = CreateFrame("Frame", nil, content); self.pages.profiles = profiles; profiles:SetAllPoints()
    y = section(profiles, "profiles", 0, "presetHelp")
    self.activeProfileText = font(profiles, 14, C.gold)
    self.activeProfileText:SetPoint("TOPLEFT", 0, y); self.activeProfileText:SetWidth(550)
    local presetTokens = { "balanced", "farming", "quiet", "battleground" }
    self.newPreset, self.presetChoices = "balanced", {}
    local presetTitle = label(profiles, "preset", 13); presetTitle:SetPoint("TOPLEFT", 0, y - 36)
    for i, preset in ipairs(presetTokens) do
        local choice = localButton(profiles, preset, 129, function()
            self.newPreset = preset
            self:RefreshProfiles()
        end)
        choice:SetPoint("TOPLEFT", (i - 1) * 140, y - 58)
        choice:SetScript("OnEnter", function() tooltip(choice, self:T(preset), self:T(preset .. "Tip")) end)
        choice:SetScript("OnLeave", hideTooltip)
        self.presetChoices[preset] = choice
    end
    local presetDescription = font(profiles, 13, C.muted)
    presetDescription:SetPoint("TOPLEFT", 0, y - 95); presetDescription:SetWidth(550)
    self.presetDescription = presetDescription
    local nameTitle = label(profiles, "profileName", 13); nameTitle:SetPoint("TOPLEFT", 0, y - 136)
    local nameInput = CreateFrame("EditBox", nil, profiles, "InputBoxTemplate")
    nameInput:SetPoint("TOPLEFT", 8, y - 158); nameInput:SetSize(345, 26); nameInput:SetAutoFocus(false); nameInput:SetMaxLetters(64)
    if nameInput.SetMaxBytes then nameInput:SetMaxBytes(64) end
    nameInput:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
    self.profileInput = nameInput
    local firstProfileRowY, profileRowSpacing, profilePageSize = y - 244, 39, 10
    local function createProfile(activate)
        if not app.db.CreateProfile then notify("noProfileAPI") return end
        local name = RG.Util.Text(nameInput:GetText(), 64)
        local created, reason = app.db:CreateProfile(name, self.newPreset)
        if not created then
            if reason == "profile_limit" then notify("profileLimit") else notify("profileError") end
            return
        end
        nameInput:SetText(""); nameInput:ClearFocus()
        local rowTop
        for index, savedName in ipairs(app.db:ListProfiles()) do
            if savedName == name then
                self.profileOffset = math.floor((index - 1) / profilePageSize) * profilePageSize
                rowTop = -firstProfileRowY + (index - self.profileOffset - 1) * profileRowSpacing
                break
            end
        end
        if activate then app:UseProfile(name) elseif app.Notify then app:Notify(self:F("profileCreated", name)) end
        self:RefreshProfiles()
        if rowTop then
            local height = scroll:GetHeight()
            local _, maximum = scrollbar:GetMinMaxValues()
            local visible = math.max(rowTop + 38 - height, math.min(rowTop, scrollbar:GetValue()))
            scrollbar:SetValue(math.max(0, math.min(maximum, visible)))
        end
    end
    self.createAndUseProfile = localButton(profiles, "createAndUseProfile", 202, function() createProfile(true) end)
    self.createAndUseProfile:SetPoint("TOPLEFT", 0, y - 194)
    self.createAndUseProfile.bg:SetColorTexture(0.10, 0.22, 0.28, 1)
    self.createProfile = localButton(profiles, "createProfile", 202, function() createProfile(false) end)
    self.createProfile:SetPoint("LEFT", self.createAndUseProfile, "RIGHT", 12, 0)
    nameInput:SetScript("OnEnterPressed", function() self.createAndUseProfile:Click() end)
    self.profileRows = {}
    for i = 1, profilePageSize do
        local row = CreateFrame("Frame", nil, profiles)
        row:SetPoint("TOPLEFT", 0, firstProfileRowY - (i - 1) * profileRowSpacing); row:SetSize(550, 34)
        row.nameText = font(row, 13); row.nameText:SetPoint("LEFT", 0, 0); row.nameText:SetWidth(300); row.nameText:SetJustifyV("MIDDLE")
        row.use = localButton(row, "useProfile", 95, function()
            if row.profileName then app:UseProfile(row.profileName) end
        end)
        row.use:SetPoint("RIGHT", -105, 0)
        row.delete = localButton(row, "deleteProfile", 95, function()
            if not row.profileName or not app.db.DeleteProfile then return end
            if self.deleteProfileName ~= row.profileName or (self.deleteProfileAt or 0) < self:Now() then
                self.deleteProfileName, self.deleteProfileAt = row.profileName, self:Now() + 5
                notify("deleteConfirm"); return
            end
            local ok = app.db:DeleteProfile(row.profileName)
            self.deleteProfileName = nil
            if ok then app:ProfileChanged(); notify("profileDeleted") else notify("profileError") end
            self:Refresh()
        end)
        row.delete:SetPoint("RIGHT", 0, 0); self.profileRows[i] = row
    end
    local profilePrev = localButton(profiles, "previous", 120, function() self.profileOffset = math.max(0, self.profileOffset - profilePageSize); self:RefreshProfiles() end)
    local profileNext = localButton(profiles, "next", 120, function() self.profileOffset = self.profileOffset + profilePageSize; self:RefreshProfiles() end)
    profileNext:SetPoint("LEFT", profilePrev, "RIGHT", 12, 0)
    self.profilePrev, self.profileNext = profilePrev, profileNext
    local exportProfile = localButton(profiles, "exportProfile", 245, function() if self.OpenTransfer then self:OpenTransfer("export") end end)
    local importProfile = localButton(profiles, "importProfile", 245, function() if self.OpenTransfer then self:OpenTransfer("import") end end)
    importProfile:SetPoint("LEFT", exportProfile, "RIGHT", 12, 0)
    profiles.height = -firstProfileRowY + profileRowSpacing + 54

    local journal = CreateFrame("Frame", nil, content); self.pages.journal = journal; journal:SetAllPoints()
    y = section(journal, "journal", 0, "journalHelp")
    self.journalMode = "recent"
    self.journalFilter = "all"
    self.journalQuery = ""
    self.journalRecent = localButton(journal, "recent", 144, function()
        self.journalMode, self.journalOffset, self.clearJournalUntil = "recent", 0, nil
        self:RefreshJournal()
    end)
    self.journalRecent:SetPoint("TOPLEFT", 0, y)
    self.journalPersonal = localButton(journal, "personalLists", 195, function()
        self.journalMode, self.journalOffset, self.clearJournalUntil = "personal", 0, nil
        self:RefreshJournal()
    end)
    self.journalPersonal:SetPoint("LEFT", self.journalRecent, "RIGHT", 9, 0)
    y = y - 43
    local searchLabel = label(journal, "searchLabel", 12, C.muted)
    searchLabel:SetPoint("TOPLEFT", 0, y); searchLabel:SetWidth(550)
    local search = CreateFrame("EditBox", nil, journal, "InputBoxTemplate")
    search:SetPoint("TOPLEFT", 7, y - 24); search:SetSize(331, 27); search:SetAutoFocus(false); search:SetMaxLetters(128)
    if search.SetMaxBytes then search:SetMaxBytes(128) end
    search:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
    search:SetScript("OnTextChanged", function(box)
        self.journalQuery, self.journalOffset = M.SearchText(box:GetText()), 0
        self:RefreshJournal()
    end)
    self.journalSearch = search
    local clearSearch = localButton(journal, "searchClear", 130, function() search:SetText(""); search:ClearFocus() end)
    clearSearch:SetPoint("TOPLEFT", 356, y - 24)
    y = y - 58
    self.journalFilterButton = button(journal, "", 300, function()
        local index = 1
        for i, value in ipairs(LIST_FILTERS) do if value == self.journalFilter then index = i break end end
        self.journalFilter, self.journalOffset = LIST_FILTERS[index % #LIST_FILTERS + 1], 0
        self:RefreshJournal()
    end)
    self.journalFilterButton:SetPoint("TOPLEFT", 0, y)
    self.journalClear = localButton(journal, "clearJournal", 300, function()
        if not app.db.ClearJournal then return end
        if not self.clearJournalUntil or self.clearJournalUntil < self:Now() then
            self.clearJournalUntil = self:Now() + 6
            self:RefreshJournal()
            if app.Notify then app:Notify(self:T("clearJournalConfirm")) end
            return
        end
        self.clearJournalUntil = nil
        app.db:ClearJournal()
        self:RefreshJournal()
        if app.Notify then app:Notify(self:T("journalCleared")) end
    end)
    self.journalClear:SetPoint("TOPLEFT", 0, y)
    self.journalCount = font(journal, 12, C.muted, "RIGHT")
    self.journalCount:SetPoint("TOPRIGHT", -16, y - 6); self.journalCount:SetWidth(220)
    y = y - 43
    local firstJournalRowY, journalRowSpacing = y, 39
    self.journalEmpty = label(journal, "emptyJournal", 14, C.muted)
    self.journalEmpty:SetPoint("TOPLEFT", 0, y); self.journalEmpty:SetWidth(550)
    self.journalRows = {}
    for i = 1, 12 do
        local row = button(journal, "", 550, function() end)
        row:SetPoint("TOPLEFT", 0, firstJournalRowY - (i - 1) * journalRowSpacing); row:SetHeight(34)
        row:SetScript("OnClick", function() if row.contact then self:Select(row.contact) end end)
        self.journalRows[i] = row
    end
    local function moveJournalPage(direction)
        self.journalOffset = math.max(0, self.journalOffset + direction * #self.journalRows)
        self:RefreshJournal()
        scrollbar:SetValue(0)
    end
    local journalPrev = localButton(journal, "previous", 120, function() moveJournalPage(-1) end)
    local journalNext = localButton(journal, "next", 120, function() moveJournalPage(1) end)
    journalNext:SetPoint("LEFT", journalPrev, "RIGHT", 12, 0)
    self.journalPrev, self.journalNext = journalPrev, journalNext
    local journalRetention = CreateFrame("Frame", nil, journal)
    self.journalRetention = journalRetention
    local retentionY = section(journalRetention, "journalRetention", 0, "retentionHelp")
    retentionY = choice(journalRetention, "retentionMode", "retention.journalMode", { { "all", "retentionAll" }, { "watched", "retentionWatched" }, { "threats", "retentionThreats" } }, retentionY)
    retentionY = slider(journalRetention, "journalDays", "retention.journalDays", retentionY, 0, 90, 1)
    local retentionHeight = -retentionY + 20
    journalRetention:SetSize(550, retentionHeight)
    journal.height = -firstJournalRowY + journalRowSpacing + retentionHeight

    local support = CreateFrame("Frame", nil, content); self.pages.support = support; support:SetAllPoints()
    y = section(support, "support", 0, "supportHelp")
    self.supportStatus = font(support, 13, C.text)
    self.supportStatus:SetPoint("TOPLEFT", 0, y); self.supportStatus:SetWidth(550)
    local diagnosticButton = localButton(support, "diagnostics", 260, function() self:ShowDiagnostics() end)
    diagnosticButton:SetPoint("TOPLEFT", 0, y - 208)
    local supportPreview = localButton(support, "demo", 180, function() app:Demo() end)
    supportPreview:SetPoint("LEFT", diagnosticButton, "RIGHT", 12, 0)
    local guideReplayButton = localButton(support, "guideReplay", 300, function() if self.ShowGuide then self:ShowGuide(true) end end)
    guideReplayButton:SetPoint("TOPLEFT", 0, y - 248)
    local caution = label(support, "statusHelp", 13, C.muted)
    caution:SetPoint("TOPLEFT", 0, y - 296); caution:SetWidth(550)
    support.height = -y + 352

    local pageKeys = { "overview", "alerts", "appearance", "profiles", "journal", "support" }
    self.nav = {}
    for i, key in ipairs(pageKeys) do
        local pageKey = key
        local nav = localButton(settings, key, 146, function() self:OpenSettings(pageKey) end)
        nav:SetPoint("TOPLEFT", 14, -65 - (i - 1) * 39)
        self.nav[key] = nav
        self.pages[key]:Hide()
    end

    self.badges = RG.Badges.New(function() return self:Profile() end)
    if RG.Launcher then self.launcher = RG.Launcher.New(self, tooltip, hideTooltip) end
    self.launcherReset:SetEnabled(self.launcher ~= nil)

    function self:RefreshControls()
        self.refreshingControls = true
        local profile = self:Profile()
        for _, entry in ipairs(self.localized) do entry.text:SetText(self:T(entry.key)) end
        for _, control in ipairs(self.controls) do
            if control.requiresRange then
                control.frame:SetEnabled(profile.range.enabled)
                control.frame:SetAlpha(profile.range.enabled and 1 or 0.5)
            end
            if control.kind == "check" then
                control.frame:SetChecked(pathGet(self:Profile(), control.path) == true)
                if control.path == "display.minimap" then control.frame:SetEnabled(self.launcher ~= nil) end
            elseif control.kind == "slider" then
                local value = pathGet(self:Profile(), control.path)
                control.frame:SetValue(value)
                control.valueText:SetText(control.step < 1 and string.format("%.2g", value) or tostring(value))
            elseif control.kind == "choice" then
                local value = pathGet(self:Profile(), control.path)
                for _, option in ipairs(control.options) do if option[1] == value then control.frame.label:SetText(self:T(option[2]) .. "  ›") end end
            elseif control.kind == "classes" then
                local visibleIndex = 0
                for _, chip in ipairs(control.chips) do
                    local available = not self.classAvailability or self.classAvailability[chip.class] == true
                    chip.frame:SetShown(available)
                    if available then
                        chip.frame:ClearAllPoints()
                        chip.frame:SetPoint("TOPLEFT", control.x + visibleIndex * (control.size + control.gap), control.y)
                        visibleIndex = visibleIndex + 1
                    end
                    local selected = M.ClassEnabled(self:Profile()[chip.group].classes, chip.class)
                    chip.frame.icon:SetDesaturated(not selected)
                    chip.frame.icon:SetAlpha(selected and 1 or 0.28)
                    for _, edge in ipairs(chip.frame.edge) do edge:SetColorTexture(unpack(selected and C.accent or C.border)) end
                end
            end
        end
        self.refreshingControls = false
    end

    function self:RefreshProfiles()
        local names = app.db.ListProfiles and app.db:ListProfiles() or {}
        local activeName = app.db.GetActiveProfileName and app.db:GetActiveProfileName() or "Default"
        self.activeProfileText:SetText(self:T("selectedProfile") .. ": " .. M.Text(activeName, "Default"))
        for _, preset in ipairs(presetTokens) do
            local choice = self.presetChoices[preset]
            local selected = preset == self.newPreset
            choice:SetEnabled(not selected)
            choice.bg:SetColorTexture(unpack(selected and { 0.10, 0.22, 0.28, 1 } or C.panel))
        end
        self.presetDescription:SetText(self:T(self.newPreset .. "Tip"))
        self.profileOffset = math.max(0, math.min(self.profileOffset, math.max(0, math.floor((#names - 1) / profilePageSize) * profilePageSize)))
        local paginated = #names > profilePageSize
        local footerY = firstProfileRowY - math.min(profilePageSize, #names - self.profileOffset) * profileRowSpacing - 12
        self.profilePrev:SetShown(paginated); self.profileNext:SetShown(paginated)
        self.profilePrev:SetEnabled(self.profileOffset > 0)
        self.profileNext:SetEnabled(self.profileOffset + profilePageSize < #names)
        profilePrev:ClearAllPoints(); profilePrev:SetPoint("TOPLEFT", 0, footerY)
        local transferY = paginated and footerY - 43 or footerY
        exportProfile:ClearAllPoints(); exportProfile:SetPoint("TOPLEFT", 0, transferY)
        profiles.height = -transferY + 50
        if self.currentPage == "profiles" and self.pageHeight ~= profiles.height then resizeSettingsPage(profiles.height) end
        for i, row in ipairs(self.profileRows) do
            local name = names[self.profileOffset + i]
            row.profileName = name
            row:SetShown(name ~= nil)
            if name then
                row.nameText:SetText(M.Text(name, ""))
                row.nameText:SetTextColor(unpack(name == activeName and C.accent or C.text))
                row.use:SetEnabled(name ~= activeName)
                row.delete:SetEnabled(name ~= "Default" and name ~= activeName)
            end
        end
    end

    function self:RefreshJournal()
        local profile = self:Profile()
        local entries, list = {}, app.db:GetList()
        local personal = self.journalMode == "personal"
        local pageSize = #self.journalRows
        local count, entryOffset = 0, 0
        local hasJournalEntries = false
        local query = profile.display.streamer and "" or self.journalQuery
        if self.journalSearch.SetEnabled then self.journalSearch:SetEnabled(not profile.display.streamer) end
        if personal then
            for identity, item in pairs(list) do
                if self.journalFilter == "all" or self.journalFilter == item.kind then
                    local searchName = M.SearchText(item.name)
                    if M.Matches(query, item.name, item.note, searchName) then
                        entries[#entries + 1] = { identity = identity, name = item.name, class = item.class, note = item.note,
                            listKind = item.kind, savedOnly = true, searchName = searchName }
                    end
                end
            end
            table.sort(entries, function(a, b)
                if a.searchName ~= b.searchName then return a.searchName < b.searchName end
                return a.identity < b.identity
            end)
            count = #entries
            local lastPage = math.max(0, math.floor((count - 1) / pageSize) * pageSize)
            self.journalOffset = math.max(0, math.min(self.journalOffset, lastPage))
            entryOffset = self.journalOffset
        else
            local matches
            if query ~= "" then
                matches = function(name, note) return M.Matches(query, name, note) end
            end
            entries, count, self.journalOffset, hasJournalEntries = app.db:GetJournalPage(self.journalOffset, pageSize, matches, journalListEntry)
        end
        self.journalRecent.bg:SetColorTexture(unpack(not personal and { 0.10, 0.22, 0.28, 1 } or C.panel))
        self.journalPersonal.bg:SetColorTexture(unpack(personal and { 0.10, 0.22, 0.28, 1 } or C.panel))
        self.journalFilterButton:SetShown(personal)
        self.journalClear:SetShown(not personal)
        self.journalClear:SetEnabled(hasJournalEntries)
        local confirming = self.clearJournalUntil and self.clearJournalUntil >= self:Now()
        self.journalClear.label:SetText(self:T(confirming and "clearJournalNow" or "clearJournal"))
        self.journalFilterButton.label:SetText(self:T(LIST_KIND_KEYS[self.journalFilter] or "allLists") .. "  ›")
        paintText(self.journalCount, self:F("filteredCount", count))
        paintShown(self.journalEmpty, count == 0)
        self.journalEmpty:SetText(self:T(query ~= "" and "noMatches" or personal and "listEmpty" or "emptyJournal"))
        local paginated = count > pageSize
        local visibleRows = math.min(pageSize, count - self.journalOffset)
        local footerY = firstJournalRowY - math.max(1, visibleRows) * journalRowSpacing - 8
        if self.journalFooterY ~= footerY then
            journalPrev:ClearAllPoints(); journalPrev:SetPoint("TOPLEFT", 0, footerY)
            self.journalFooterY = footerY
        end
        local retentionTop = footerY - (paginated and 45 or 0)
        if self.journalRetentionTop ~= retentionTop then
            journalRetention:ClearAllPoints(); journalRetention:SetPoint("TOPLEFT", 0, retentionTop)
            self.journalRetentionTop = retentionTop
        end
        paintShown(journalPrev, paginated); paintShown(journalNext, paginated)
        paintShown(journalRetention, not personal)
        self.journalPrev:SetEnabled(self.journalOffset > 0)
        self.journalNext:SetEnabled(self.journalOffset + pageSize < count)
        journal.height = personal and (-footerY + (paginated and 44 or 0)) or (-retentionTop + retentionHeight)
        if self.currentPage == "journal" and self.pageHeight ~= journal.height then resizeSettingsPage(journal.height) end
        local epoch = not personal and app.engine.epoch and M.Number(app.engine.epoch())
        local now = self:Now()
        for i, row in ipairs(self.journalRows) do
            local entry = entries[entryOffset + i]
            if entry then
                entry.searchName = nil
                entry.id = entry.identity
                entry.visible = false
                entry.sources = { journal = true }
                if not entry.savedOnly then
                    local recorded = M.Number(entry.lastSeen)
                    entry.lastSeen = epoch and epoch > 0 and recorded and recorded > 0 and now - math.max(0, epoch - recorded) or nil
                    local record = journalListEntry(entry.identity)
                    if record then entry.note, entry.listKind = record.note, record.kind end
                end
            end
            row.contact = entry
            paintShown(row, entry ~= nil)
            if entry then
                local name = M.Text(entry.name, self:T("nameUnavailable"))
                if profile.display.streamer then name = self:T("unknownPlayer") .. " " .. (self.journalOffset + i) end
                local tag = personal and self:T(LIST_KIND_KEYS[entry.listKind] or "unlisted") or M.State(entry, now, profile.locale)
                paintText(row.label, name .. "  ·  " .. tag)
            end
        end
    end

    function self:Refresh()
        if self.destroyed then return end
        local profile = self:Profile()
        if self.previousContrast ~= profile.display.highContrast then
            local contrast = profile.display.highContrast
            mainBackground:SetColorTexture(unpack(contrast and { 0.015, 0.020, 0.026, 1 } or C.bg))
            for _, edge in ipairs(mainBorder) do edge:SetColorTexture(unpack(contrast and { 0.55, 0.78, 0.90, 1 } or C.border)) end
            self.previousContrast = contrast
        end
        self:UpdateClasses()
        if self.lastProfile ~= profile then
            restoreNearby()
            cancelBannerMove(); restoreBanner()
            self.lastProfile = profile
            self.alertProfile, self.alertConfig = profile, self:AlertConfig(profile)
            self.controlsDirty = true
        elseif not self.bannerMoveProfile and not profile.positions.alert and self.bannerDefaultOffset ~= bannerDefaultPoint() then
            restoreBanner()
        end
        local now = self:Now()
        local preview = self.previewUntil and self.previewUntil > now
        if self.previewUntil and not preview then
            self.previewContacts, self.previewUntil = nil, nil
            self:ClosePreviewDetails()
        end
        local nearbyShown = profile.display.showList or preview == true
        local detailsShown = self.detailsFrame and self.detailsFrame:IsShown() and self.selected
        local liveDetailsShown = detailsShown and not self.selected.preview
        local liveSnapshot
        if nearbyShown and not preview then liveSnapshot = app.engine:Snapshot() end
        local untilTime = M.Number(app.engine.pausedUntil)
        local paused = untilTime ~= nil and untilTime > now
        local needsStatus = self.statusAt == nil or now - self.statusAt >= 1
            or self.statusPaused ~= paused or self.statusEnabled ~= profile.enabled
            or settings:IsShown() and self.currentPage == "support" and self.statusPage ~= "support"
        if needsStatus then
            self.statusCache = app.Status and app:Status() or {}
            self.statusAt = now
            self.statusPaused, self.statusEnabled = paused, profile.enabled
        end
        self.statusPage = settings:IsShown() and self.currentPage or nil
        local appStatus = self.statusCache or {}
        if type(appStatus) ~= "table" then appStatus = { detail = appStatus } end
        local detection = self:DetectionKey(appStatus)
        local supportShown = self.statusPage == "support"
        local alertBlock = (nearbyShown and not preview or supportShown) and self:AlertBlock()
        if nearbyShown then
            local snapshot = preview and self.previewContacts or liveSnapshot
            local rows = M.Rows(snapshot, profile, now, preview and self.previewAliases or self.aliases)
            self.renderedCount = #rows
            local maxRows = math.floor(RG.Util.Clamp(profile.display.maxRows, 3, 20, 8))
            local rowHeight = profile.display.textSize + UI.layout.rowPadding
            local mainHeight = UI.layout.header + math.max(3, math.min(maxRows, #rows)) * rowHeight + UI.layout.footer
            if self.nearbyHeight ~= mainHeight then
                main:SetHeight(mainHeight)
                self.nearbyHeight = mainHeight
            end
            fitNearby(mainHeight, profile)
            self.offset = math.max(0, math.min(self.offset, math.max(0, #rows - maxRows)))
            local visibleCount = 0
            for _, row in ipairs(rows) do if row.visible and row.contact.behindCamera ~= true then visibleCount = visibleCount + 1 end end
            self.visibleCount = preview and app.engine:CountVisible() or visibleCount
            local status = self:T(preview and "demoLabel" or detection) .. " · " .. self:F("inViewCount", visibleCount)
            if not preview and detection ~= "disabled" and alertBlock then status = status .. " · " .. self:T("alertsQuiet") end
            paintText(statusText, status)
            paintText(self.pauseButton.label, self:T(paused and "resume" or "pause"))
            paintText(self.muteButton.label, self:T(profile.alerts.sound and "mute" or "unmute"))
            paintShown(empty, #rows == 0); paintShown(emptyHelp, #rows == 0)
            for i, row in ipairs(self.rows) do
                local data = i <= maxRows and rows[self.offset + i] or nil
                paintNearbyRow(row, data, i, profile)
            end
            paintText(more, #rows > maxRows and self:F("moreContacts", #rows - maxRows) or self:T("noTarget"))
            if #rows == 0 then
                local titleKey, helpKey = "noEnemies", "noEnemiesHelp"
                if not profile.enabled and not preview then titleKey, helpKey = "noDisabled", "noDisabledHelp"
                elseif #snapshot > 0 or M.Number(appStatus.contacts, 0) > 0 then titleKey, helpKey = "noFiltered", "noFilteredHelp"
                elseif appStatus.nameplates == false and not preview then titleKey, helpKey = "noNameplates", "noNameplatesHelp" end
                empty:SetText(self:T(titleKey)); emptyHelp:SetText(self:T(helpKey))
            end
        else
            self.visibleCount = app.engine:CountVisible()
            self.renderedCount = 0
            if main:IsShown() then
                for _, row in ipairs(self.rows) do
                    row.contact = nil
                    paintShown(row, false)
                end
            end
        end
        if main:IsShown() ~= nearbyShown then main:SetShown(nearbyShown) end
        if self.controlsDirty then self:RefreshControls(); self.controlsDirty = false end
        self.badges:Refresh()
        if self.launcher then self.launcher:Refresh() end
        if settings:IsShown() then
            self:FitWindow(settings, UI.layout.settingsWidth, UI.layout.settingsHeight, 1)
            if self.currentPage == "alerts" then
                local name = app.db.GetActiveProfileName and app.db:GetActiveProfileName() or "Default"
                local blocked = app.AlertBlock and app:AlertBlock(true)
                paintText(self.alertProfileStatus, self:T("selectedProfile") .. ": " .. M.Text(name, "Default"))
                paintText(self.ordinaryAlertStatus, blocked and self:F("ordinaryAlertStatus", RG.Locale.Reason(blocked, profile.locale))
                    or self:T("ordinaryAlertReady"))
                local returning = app.AlertBlock and app:AlertBlock(true, "returning")
                paintText(self.returningAlertStatus, returning and self:F("returningAlertStatus", RG.Locale.Reason(returning, profile.locale))
                    or self:T("returningAlertReady"))
            end
            if self.currentPage == "profiles" and (needsStatus or self.dataPage ~= "profiles") then self:RefreshProfiles() end
            if self.currentPage == "journal" and (needsStatus or self.dataPage ~= "journal") then self:RefreshJournal() end
            if supportShown then
                local detectionText = detection == "disabled" and "sensorDisabled" or detection == "limited" and "sensorLimited" or "sensorReady"
                local lines = { M.Text(appStatus.detail, self:T(detectionText)) }
                if alertBlock then lines[#lines + 1] = RG.Locale.Reason(alertBlock, profile.locale) end
                if appStatus.capabilities and appStatus.capabilities.nameplateEvents == false then
                    lines[#lines + 1] = self:T("nameplateEventsLimited")
                end
                if appStatus.nameplates == false then
                    lines[#lines + 1] = self:T("nameplatesOff")
                elseif appStatus.nameplates == true and appStatus.alwaysNameplates == false then
                    lines[#lines + 1] = self:T("nameplatesAutomatic")
                end
                if appStatus.writable == false then lines[#lines + 1] = self:T("sessionOnly") end
                self.supportStatus:SetText(table.concat(lines, "\n\n"))
            end
            self.dataPage = self.currentPage
        else
            self.dataPage = nil
        end
        if self.dialogs then self.dialogs:Refresh() end
        if liveDetailsShown then
            local current
            if liveSnapshot then
                for _, contact in ipairs(liveSnapshot) do
                    if contact.id == self.selected.id or self.selected.identity and contact.identity == self.selected.identity then current = contact break end
                end
            else
                current = app.engine:SelectedContact(self.selected.id, self.selected.identity)
            end
            if current and not self.selected.savedOnly then self.selected = current end
            self.selectedOutside = current == nil
        end
        if detailsShown then self:ShowDetails(true) end
        if self.explanationFrame and self.explanationFrame:IsShown() then self:ShowExplanation() end
        if self.copyFrame and self.copyFrame:IsShown() then
            self:FitWindow(self.copyFrame, self.copyFrame:GetWidth(), self.copyFrame:GetHeight(), 1)
        end
    end

    function self:OpenSettings(page)
        page = self.pages[page] and page or self.currentPage or "overview"
        if page ~= self.currentPage then self.clearJournalUntil = nil end
        self.currentPage = page
        self.controlsDirty = true
        self.dataPage = nil
        for key, frame in pairs(self.pages) do
            frame:SetShown(key == page)
            self.nav[key].bg:SetColorTexture(unpack(key == page and { 0.10, 0.22, 0.28, 1 } or C.panel))
        end
        resizeSettingsPage(self.pages[page].height, true)
        settings:Show(); self:Refresh()
    end

    function self:Toggle()
        self:Profile().display.showList = not self:Profile().display.showList
        changed()
    end

    function self:PaintBanner(item)
        local kind, class = item.kind, item.class
        local title = kind == "stealth" and M.Stealth(item, self:Profile().locale) or self:T(BANNER_CATEGORIES[kind] or "alertTitle")
        if item.preview then title = self:T("demoLabel") .. " · " .. title end
        banner.title:SetText(title)
        local name = self:Profile().display.streamer and self:T("unknownPlayer") or item.name
        if item.count and item.count > 1 then
            local summary = M.Wave(item.classes, self:Profile().locale)
            banner.body:SetText(self:F("waveBody", item.count) .. (summary ~= "" and ("\n" .. summary) or ""))
        else
            banner.body:SetText(name)
        end
        banner.icon:SetTexture(RG.Defaults.classSet[class] and ("Interface\\Icons\\ClassIcon_" .. class) or "Interface\\Icons\\Ability_Warrior_BattleShout")
        banner.title:SetTextColor(unpack((kind == "watch" or kind == "stealth" or kind == "avoid") and C.gold or C.accent))
    end

    function self:ShowBanner(item, now)
        if not item.preview then cancelBannerMove() end
        self.activeBanner = item
        self.bannerPreview = item.preview
        banner:EnableMouse(self.bannerPreview)
        self.bannerUntil = now + (self.bannerPreview and 12 or 4)
        self:PaintBanner(item)
        banner:SetAlpha(1); self.bannerAlpha = 1; banner:Show()
    end

    function self:ClearBanners()
        self.bannerQueue = {}
        if self.badges.highlight and self.badges.highlight.automatic then self.badges:ClearHighlight() end
        if self.activeBanner and self.activeBanner.preview then return end
        self.activeBanner, self.bannerUntil, self.bannerPreview = nil, nil, false
        banner:Hide(); banner:EnableMouse(false)
    end

    function self:SuppressContactBanners(id, identity)
        id = M.Text(id, "", 256)
        identity = M.Text(identity, "", 256)
        if id == "" and identity == "" then return end
        local function matches(item)
            return not item.preview and ((id ~= "" and item.id == id) or (identity ~= "" and item.identity == identity))
        end
        for index = #self.bannerQueue, 1, -1 do
            if matches(self.bannerQueue[index]) then table.remove(self.bannerQueue, index) end
        end
        local item = self.activeBanner
        if item and matches(item) then
            self.bannerUntil = self:Now()
            self:AdvanceBanner(self.bannerUntil)
        end
    end

    local function bannerHasEvidence(item)
        if item.preview or item.kind ~= "targeting" or not app.HasTargetingEvidence then return true end
        return app:HasTargetingEvidence(item.id)
    end

    local function bannerFresh(item, now)
        local maximumAge = item.priority >= BANNER_URGENT_PRIORITY and BANNER_URGENT_MAX_AGE or BANNER_ORDINARY_MAX_AGE
        return now - item.at <= maximumAge
    end

    function self:AdvanceBanner(now)
        local active = self.activeBanner
        local pausedUntil = M.Number(app.engine.pausedUntil)
        if pausedUntil and pausedUntil > now then
            self:ClearBanners()
            active = self.activeBanner
        end
        if active and self.bannerUntil > now and bannerHasEvidence(active) then
            local left = self.bannerUntil - now
            local alpha = self:Profile().display.reducedMotion and 1 or math.min(1, left * 2)
            if alpha ~= self.bannerAlpha then banner:SetAlpha(alpha); self.bannerAlpha = alpha end
            return
        end
        self.activeBanner, self.bannerUntil, self.bannerPreview = nil, nil, false
        if active then cancelBannerMove(); banner:Hide(); banner:EnableMouse(false) end
        local queue = self.bannerQueue
        while #queue > 0 do
            local item = table.remove(queue, 1)
            if bannerFresh(item, now) and bannerHasEvidence(item) then self:ShowBanner(item, now); return end
        end
    end

    function self:Alert(decision)
        if type(decision) ~= "table" then return end
        local profile = self:Profile()
        local preview = decision.preview == true
        if not preview and (not profile.enabled or not profile.alerts.enabled or not profile.alerts.banner or decision.banner == false) then return end
        local contact = decision.contact or decision.player or decision
        local kind = M.Text(decision.kind, M.Text(decision.type, "sighting"))
        local priority = M.Number(decision.priority, BANNER_PRIORITY[kind] or 20)
        local id = M.Text(contact.id, "", 256)
        local now = self:Now()
        local item = { kind = kind, class = M.Text(contact.class, ""), name = M.Text(contact.name, self:T("unknownPlayer")),
            count = M.Number(decision.count), classes = type(decision.classes) == "table" and RG.Util.Copy(decision.classes) or nil,
            stealthEvidence = M.Text(decision.stealthEvidence or contact.stealthEvidence, ""),
            stealthSpell = M.Text(decision.stealthSpell or contact.stealthSpell, ""),
            id = id, identity = M.Text(contact.identity, "", 256), preview = preview, priority = priority, at = now,
            key = id ~= "" and (kind .. ":" .. id) or nil }
        self:AdvanceBanner(now)
        local active = self.activeBanner
        if preview and active and not active.preview then return end
        if active and item.key and active.key == item.key and active.preview == item.preview then return end
        if not active or active.preview or item.priority > active.priority then self:ShowBanner(item, now); return end
        for i = #self.bannerQueue, 1, -1 do
            local queued = self.bannerQueue[i]
            if not bannerFresh(queued, now) then table.remove(self.bannerQueue, i)
            elseif item.key and item.key == queued.key then return end
        end
        local index = #self.bannerQueue + 1
        for i, queued in ipairs(self.bannerQueue) do
            if item.priority > queued.priority or (item.priority == queued.priority and item.priority < BANNER_URGENT_PRIORITY) then
                index = i
                break
            end
        end
        table.insert(self.bannerQueue, index, item)
        if #self.bannerQueue > BANNER_QUEUE_LIMIT then table.remove(self.bannerQueue) end
    end

    function self:PreviewAlert()
        self:Alert({ kind = "stealth", contact = { name = self:T("demoRogue"), class = "ROGUE" }, sound = true, preview = true })
        if app.PreviewSound then app:PreviewSound("stealth") end
    end

    function self:Preview(contacts, decision)
        self:ClosePreviewDetails()
        self.settings:Hide()
        self.previewContacts = RG.Util.Copy(contacts or {
            { id = "preview-rogue", name = self:T("demoRogue"), class = "ROGUE", visible = true, lastSeen = self:Now(), rangeMin = 10, rangeMax = 20 },
            { id = "preview-hunter", name = self:T("demoHunter"), class = "HUNTER", visible = true, lastSeen = self:Now(), rangeMin = 20, rangeMax = 40 },
            { id = "preview-mage", name = self:T("demoMage"), class = "MAGE", visible = false, lastSeen = self:Now() - 12 },
        })
        for _, contact in ipairs(self.previewContacts) do
            contact.identity, contact.preview, contact.sources = nil, true, { preview = true }
        end
        self.previewAliases = {}
        self.previewUntil = self:Now() + 15
        decision = decision or { kind = "stealth", contact = self.previewContacts[1] }
        local sample = RG.Util.Copy(decision)
        sample.preview = true
        self:Alert(sample)
        self:Refresh()
        return self.previewUntil
    end

    function self:SetNameplate(unit, frame, contact) self.badges:Set(unit, frame, contact) end
    function self:RemoveNameplate(unit) self.badges:Remove(unit) end

    function self:ClosePreviewDetails()
        if self.selected and self.selected.preview then
            self.selected, self.selectedOutside = nil, nil
            if self.detailsFrame then self.detailsFrame:Hide() end
            if self.explanationFrame then self.explanationFrame:Hide() end
        end
    end

    function self:Select(contact)
        if self.explanationFrame then self.explanationFrame:Hide() end
        if self.badges.highlight and not self.badges.highlight.automatic then self.badges:ClearHighlight() end
        self.selected = contact
        self.noteDraft = nil
        self.locateFailed = nil
        self.removeEntryAt, self.removeEntryIdentity = nil, nil
        self.selectedFromJournal = contact.sources and contact.sources.journal == true or false
        self.selectedOutside = self.selectedFromJournal
        self:ShowDetails()
    end

    function self:ShowDetails(refreshOnly)
        if not self.detailsFrame then
            local detail = self:Window("RivalGuardDetails", UIParent)
            self.detailsFrame = detail
            detail:SetSize(470, 555)
            detail:SetFrameStrata("DIALOG"); detail:SetClampedToScreen(true); detail:EnableMouse(true)
            fill(detail); outline(detail)
            detail.title = font(detail, 18, C.accent)
            detail.title:SetPoint("TOPLEFT", 18, -16); detail.title:SetWidth(344)
            if detail.title.SetMaxLines then detail.title:SetMaxLines(1) end
            local close = localButton(detail, "close", 84, function() detail:Hide() end)
            close:SetPoint("TOPRIGHT", -12, -10)
            detail.info = font(detail, 13, C.text)
            detail.info:SetPoint("TOPLEFT", 18, -57); detail.info:SetWidth(432)
            detail.notice = font(detail, 11, C.muted)
            detail.notice:SetWidth(432)
            local function selectedList()
                local contact = self.selected
                local entry, identity = listEntry(contact)
                if identity ~= detail.listIdentity then
                    self:ShowDetails(true)
                    return nil
                end
                if identity then return contact, entry, identity end
            end
            local actions = { "watch", "avoid", "ignore" }
            detail.listActions = {}
            for i, action in ipairs(actions) do
                local kind = action
                local b = localButton(detail, action, 130, function()
                    local contact, entry = selectedList()
                    if not contact then return end
                    local ok = setList(contact, kind, entry and entry.note)
                    if not ok then notify("saveFailed") return end
                    self:SettingsChanged(); self:ShowDetails(true)
                end)
                b:SetPoint("TOPLEFT", 18 + (i - 1) * 142, -222)
                detail.listActions[kind] = b
            end
            local remove = localButton(detail, "removeList", 150, function()
                local contact, entry = selectedList()
                if not contact then return end
                if not entry then return end
                local ok = setList(contact, entry.note and "note" or nil, entry.note)
                if not ok then notify("saveFailed") return end
                notify("confirmRemove"); self:SettingsChanged(); self:ShowDetails(true)
            end)
            remove:SetPoint("TOPLEFT", 18, -261)
            detail.removeMembership = remove
            detail.why = localButton(detail, "why", 150, function() self:ShowExplanation() end)
            detail.locate = localButton(detail, "locate", 109, function()
                self.locateFailed = not app:HighlightContact(self.selected)
                if self.locateFailed or self.noteDraft or detail.note:HasFocus() then self:ShowDetails(true)
                else detail:Hide() end
            end)
            detail.locate:SetPoint("TOPLEFT", 345, -261)
            detail.locate:SetScript("OnEnter", function() tooltip(detail.locate, self:T("locate"), self:T("locateHelp")) end)
            detail.locate:SetScript("OnLeave", hideTooltip)
            local noteTitle = label(detail, "note", 13)
            noteTitle:SetPoint("TOPLEFT", 18, -305)
            detail.note = CreateFrame("EditBox", nil, detail, "InputBoxTemplate")
            detail.note:SetPoint("TOPLEFT", 25, -334); detail.note:SetSize(420, 28)
            detail.note:SetAutoFocus(false); detail.note:SetMaxLetters(512)
            if detail.note.SetMaxBytes then detail.note:SetMaxBytes(512) end
            detail.note:SetScript("OnTextChanged", function(box, userInput)
                local identity = detail.listIdentity
                if userInput and identity and not self:Profile().display.streamer then
                    self.noteDraft = { identity = identity, text = box:GetText() }
                end
            end)
            detail.note:SetScript("OnEscapePressed", function(box)
                self.noteDraft = nil; box:ClearFocus(); self:ShowDetails()
            end)
            detail:SetScript("OnHide", function()
                self.noteDraft = nil; detail.note:ClearFocus()
                self.locateFailed = nil
                if self.explanationFrame then self.explanationFrame:Hide() end
            end)
            local save = localButton(detail, "saveNote", 160, function()
                local contact = selectedList()
                if not contact or self:Profile().display.streamer then return end
                if not app.SetNote then notify("noListAPI") return end
                local ok, _, feedback = app:SetNote(contact, detail.note:GetText())
                detail.note:ClearFocus()
                if ok then self.noteDraft = nil; self:ShowDetails() end
                notify(ok and (feedback or "noteSaved") or "saveFailed")
            end)
            save:SetPoint("TOPLEFT", 18, -380)
            save:SetScript("OnEnter", function() tooltip(save, self:T("saveNote"), self:T("keyboardEditHelp")) end)
            save:SetScript("OnLeave", hideTooltip)
            detail.saveNote, detail.noteTitle = save, noteTitle
            detail.note:SetScript("OnEnterPressed", function() save:Click() end)
            detail.privateNote = label(detail, "notePrivate", 12, C.muted)
            detail.privateNote:SetPoint("TOPLEFT", 18, -334); detail.privateNote:SetWidth(432)
            detail.snooze = button(detail, self:T("snoozeContact"), 274, function()
                local contact = self.selected
                if not self:CanSnooze(contact) then notify("snoozeUnavailable") return end
                local ok = app:Snooze(contact, 600)
                if ok then self:Refresh() else notify("snoozeUnavailable") end
            end)
            detail.snooze:SetPoint("TOPLEFT", 18, -422)
            detail.snooze:SetScript("OnEnter", function()
                local remaining = math.max(0, M.Number(self.selected and self.selected.snoozedUntil, 0) - self:Now())
                local description = remaining > 0 and self:F("snoozedFor", M.Age(remaining, self:Profile().locale)) or self:T("snoozeContact")
                tooltip(detail.snooze, self:T("alerts"), description)
            end)
            detail.snooze:SetScript("OnLeave", hideTooltip)
            local help = label(detail, "identityUnknown", 11, C.muted)
            help:SetPoint("TOPLEFT", 18, -475); help:SetWidth(432)
            detail.identityHelp = help
            detail.removeSaved = localButton(detail, "deleteRecord", 220, function()
                local contact, _, identity = selectedList()
                if not contact or not contact.savedOnly then return end
                if self.removeEntryIdentity ~= identity or (self.removeEntryAt or 0) < self:Now() then
                    self.removeEntryIdentity, self.removeEntryAt = identity, self:Now() + 6
                    detail.removeSaved.label:SetText(self:T("deleteRecordNow"))
                    return
                end
                local ok = setList(contact, nil)
                if not ok then notify("saveFailed") return end
                self.removeEntryAt, self.removeEntryIdentity = nil, nil
                detail:Hide(); self:SettingsChanged(); notify("recordDeleted")
            end)
            detail.removeSaved:SetPoint("TOPRIGHT", -16, -380)
            if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "RivalGuardDetails" end
        end
        local detail, contact = self.detailsFrame, self.selected
        if not contact then detail:Hide() return end
        local profile = self:Profile()
        local preview = contact.preview == true
        if detail.previewLayout ~= preview then
            detail.previewLayout = preview
            detail:SetHeight(preview and 245 or 555)
            detail.notice:ClearAllPoints()
            detail.notice:SetPoint("TOPLEFT", 18, preview and -145 or -185)
            detail.why:ClearAllPoints()
            detail.why:SetPoint("TOPLEFT", preview and 18 or 185, preview and -197 or -261)
        end
        local entry, identity = listEntry(contact)
        if detail.listIdentity ~= identity then
            detail.listIdentity = identity
            self.noteDraft = nil
            detail.note:ClearFocus()
        end
        local name = M.Text(contact.name, self:T(contact.savedOnly and "nameUnavailable" or "unknownPlayer"))
        if profile.display.streamer then name = self:T("unknownPlayer") end
        paintText(detail.title, name)
        local class = M.Text(contact.class, "")
        local lines = { RG.Defaults.classSet[class] and RG.Locale.Class(class, self:Profile().locale) or self:T("unknownClass") }
        local state = contact
        if self.selectedOutside and contact.visible then
            state = { visible = false, lastSeen = contact.lastSeen }
        end
        local stateText = contact.savedOnly and self:T("noCurrentEvidence") or M.State(state, self:Now(), profile.locale)
        local rangeDetail, range = M.RangeDetails(state, profile.locale)
        if preview then
            range = M.Range(contact, profile.locale)
            rangeDetail = self:F("demoRange", range)
        end
        lines[#lines + 1] = rangeDetail and stateText == range and rangeDetail or stateText
        if rangeDetail and stateText ~= range then lines[#lines + 1] = rangeDetail end
        if entry then lines[#lines + 1] = self:F("currentList", self:T(LIST_KIND_KEYS[entry.kind] or "unlisted")) end
        if contact.preview and contact.watched then lines[#lines + 1] = self:T("demoWatched") end
        if not self.selectedOutside and contact.currentTarget == true then lines[#lines + 1] = self:T("yourTarget") end
        if not self.selectedOutside and contact.currentFocus == true then lines[#lines + 1] = self:T("yourFocus") end
        local sourceNames = {}
        for source in pairs(contact.sources or {}) do
            local cleanSource = M.Text(source, "")
            local sourceKeys = { nameplate = "sourceNameplate", target = "sourceTarget", focus = "sourceFocus", mouseover = "sourceMouseover", softenemy = "sourceSoftTarget", journal = "sourceJournal", preview = "demoLabel" }
            if cleanSource ~= "" then sourceNames[#sourceNames + 1] = self:T(sourceKeys[cleanSource] or "observed") end
        end
        table.sort(sourceNames)
        lines[#lines + 1] = self:T("reason") .. ": " .. (#sourceNames > 0 and table.concat(sourceNames, ", ") or self:T("observed"))
        paintText(detail.info, table.concat(lines, "\n"))
        paintText(detail.notice, self:T(contact.preview and "demoWhy" or "noTarget"))
        if profile.display.streamer then
            self.noteDraft = nil; detail.note:ClearFocus(); detail.note:SetText("")
        elseif not refreshOnly or not (detail.note.HasFocus and detail.note:HasFocus()) then
            local pending = self.noteDraft and self.noteDraft.identity == identity and self.noteDraft.text
            detail.note:SetText(pending or M.Text(entry and entry.note, "", 512))
        end
        local showNote = not preview and not profile.display.streamer
        paintShown(detail.noteTitle, showNote)
        paintShown(detail.note, showNote)
        if detail.note.SetEnabled then paintEnabled(detail.note, identity ~= nil) end
        paintShown(detail.saveNote, showNote)
        paintEnabled(detail.saveNote, identity ~= nil)
        paintShown(detail.privateNote, not preview and profile.display.streamer == true)
        local canRequestLocate = type(app.HighlightContact) == "function" and not preview
            and not contact.savedOnly and not self.selectedFromJournal
        paintShown(detail.locate, canRequestLocate)
        paintEnabled(detail.locate, canRequestLocate)
        local locateFailed = canRequestLocate and self.locateFailed
        paintShown(detail.identityHelp, not preview and (identity == nil or locateFailed == true))
        detail.identityHelp:SetText(self:T(locateFailed and "locateUnavailable" or contact.savedOnly and "legacyIdentity" or "identityUnknown"))
        for kind, buttonFrame in pairs(detail.listActions) do
            local listed = entry ~= nil and entry.kind == kind
            paintShown(buttonFrame, not preview)
            paintEnabled(buttonFrame, identity ~= nil and not listed)
            if buttonFrame.paintedListed ~= listed then
                buttonFrame.bg:SetColorTexture(unpack(listed and { 0.10, 0.22, 0.28, 1 } or C.panel))
                buttonFrame.paintedListed = listed
            end
        end
        paintShown(detail.removeMembership, not preview)
        paintEnabled(detail.removeMembership, identity ~= nil and entry ~= nil and entry.kind ~= "note")
        paintShown(detail.removeSaved, contact.savedOnly == true and identity ~= nil and entry ~= nil)
        local confirming = self.removeEntryIdentity == identity and (self.removeEntryAt or 0) >= self:Now()
        detail.removeSaved.label:SetText(self:T(confirming and "deleteRecordNow" or "deleteRecord"))
        local canSnooze = self:CanSnooze(contact)
        local remaining = math.max(0, M.Number(contact.snoozedUntil, 0) - self:Now())
        paintShown(detail.snooze, canSnooze)
        paintText(detail.snooze.label, self:T(remaining > 0 and "resumeContact" or "snoozeContact"))
        self:FitOffsetWindow(detail, 80, 0)
        if not detail:IsShown() then detail:Show() end
    end

    function self:CanSnooze(contact)
        return app.Snooze ~= nil and M.EditableIdentity(contact) ~= nil and not self.selectedOutside and not contact.savedOnly
            and (not contact.sources or not contact.sources.journal) and M.Text(contact.id, "", 256) ~= ""
    end

    local function withSoundCue(text, cue)
        local key = M.Text(cue, "")
        local label = RG.Defaults.soundLabels[key]
        if not label or key == "none" then return text end
        return (text ~= "" and text .. "\n" or "") .. self:F("soundCueEvidence", self:T(label))
    end

    function self:ShowExplanation()
        if not self.explanationFrame then
            local frame = self:Window("RivalGuardExplanation", UIParent)
            self.explanationFrame = frame
            frame:SetSize(460, 290); frame:SetFrameStrata("DIALOG")
            frame:SetClampedToScreen(true); frame:EnableMouse(true)
            fill(frame); outline(frame)
            local titleText = label(frame, "explanation", 17, C.accent)
            titleText:SetPoint("TOPLEFT", 18, -18); titleText:SetWidth(325)
            local close = localButton(frame, "close", 84, function() frame:Hide() end)
            close:SetPoint("TOPRIGHT", -12, -10)
            frame.event = font(frame, 13, C.accent)
            frame.event:SetPoint("TOPLEFT", 18, -57); frame.event:SetWidth(420)
            frame.reason = font(frame, 14, C.text)
            frame.reason:SetPoint("TOPLEFT", 18, -89); frame.reason:SetWidth(420)
            frame.rangeEvidence = font(frame, 13, C.muted)
            frame.rangeEvidence:SetPoint("TOPLEFT", 18, -150); frame.rangeEvidence:SetWidth(420)
            frame.outputs = font(frame, 13, C.accent)
            frame.outputs:SetPoint("TOPLEFT", 18, -178); frame.outputs:SetWidth(420)
            frame.lastSoundHeading = font(frame, 13, C.accent)
            frame.lastSoundHeading:SetPoint("TOPLEFT", 18, -226); frame.lastSoundHeading:SetWidth(420)
            frame.lastSound = font(frame, 14, C.text)
            frame.lastSound:SetPoint("TOPLEFT", 18, -253); frame.lastSound:SetWidth(420)
            frame.help = font(frame, 12, C.muted)
            frame.help:SetPoint("BOTTOMLEFT", 18, 24); frame.help:SetWidth(420)
            if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "RivalGuardExplanation" end
        end
        local result = app.Explain and self.selected and app:Explain(self.selected) or nil
        local frame = self.explanationFrame
        result = type(result) == "table" and result or {}
        local locale = self:Profile().locale
        local preview = result.preview == true or self.selected and self.selected.preview == true
        paintText(frame.event, self:T(preview and "demoSighting" or "explanationSighting"))
        paintText(frame.help, self:T(preview and "demoExplanationHelp" or "explanationHelp"))
        paintText(frame.reason, RG.Locale.Reason(result.reason or "unavailable", locale))
        local rangeEvidence = result.reason ~= "range_conflict" and result.reason ~= "not_observed" and M.RangeProvenance(result.rangeEvidence, locale)
        paintText(frame.rangeEvidence, rangeEvidence or "")
        local output
        if result.allowed == true then
            if result.sound == true and result.banner == true then output = "explanationSoundBanner"
            elseif result.sound == true then output = "explanationSoundOnly"
            elseif result.banner == true then output = "explanationBannerOnly" end
        end
        paintText(frame.outputs, withSoundCue(output and self:T(output) or "", result.soundCue))
        local lastSound = type(result.lastSound) == "table" and result.lastSound or nil
        local soundEvent = lastSound and SOUND_EVENT_KEYS[lastSound.kind]
        local soundStatus = lastSound and SOUND_STATUS_KEYS[lastSound.status]
        local lastCue = lastSound and lastSound.soundCue
        local showSound = not preview and not self.selectedFromJournal and soundEvent ~= nil and soundStatus ~= nil
        paintShown(frame.lastSoundHeading, showSound)
        paintShown(frame.lastSound, showSound)
        paintText(frame.lastSoundHeading, showSound and self:F("lastSoundHeading", self:T(soundEvent)) or "")
        paintText(frame.lastSound, showSound and withSoundCue(self:T(soundStatus), lastCue) or "")
        local height = showSound and 370 or 290
        if frame.soundSectionShown ~= showSound then
            frame:SetHeight(height)
            frame.soundSectionShown = showSound
        end
        self:FitOffsetWindow(frame, 0, 80)
        if not frame:IsShown() then frame:Show() end
    end

    function self:ShowDiagnostics()
        if not self.copyFrame then
            local copy = self:Window("RivalGuardDiagnostics", UIParent)
            self.copyFrame = copy
            copy:SetSize(660, 490); copy:SetPoint("CENTER"); copy:SetFrameStrata("DIALOG")
            copy:SetClampedToScreen(true); copy:EnableMouse(true)
            fill(copy); outline(copy)
            local titleText = label(copy, "copyTitle", 17, C.accent)
            titleText:SetPoint("TOPLEFT", 18, -16)
            local close = localButton(copy, "close", 84, function() copy:Hide() end)
            close:SetPoint("TOPRIGHT", -12, -10)
            local help = label(copy, "copyHelp", 12, C.muted)
            help:SetPoint("TOPLEFT", 18, -53); help:SetWidth(620)
            local scroller = CreateFrame("ScrollFrame", nil, copy, "UIPanelScrollFrameTemplate")
            scroller:SetPoint("TOPLEFT", 18, -93); scroller:SetPoint("BOTTOMRIGHT", -38, 18)
            local edit = CreateFrame("EditBox", nil, scroller)
            edit:SetMultiLine(true); edit:SetAutoFocus(false); edit:SetWidth(596)
            edit:SetFontObject(ChatFontNormal or GameFontNormal)
            edit:SetScript("OnEscapePressed", function(box) box:ClearFocus(); copy:Hide() end)
            copy:SetScript("OnHide", function() edit:ClearFocus() end)
            edit:SetScript("OnTextChanged", function(box)
                local lines = M.Number(box:GetNumLines(), 1)
                box:SetHeight(math.max(350, math.min(100000, lines * 16 + 24)))
            end)
            scroller:SetScrollChild(edit); copy.edit = edit
            if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "RivalGuardDiagnostics" end
        end
        local report = app.ExportDiagnostics and app:ExportDiagnostics() or self:T("reportUnavailable")
        if type(report) ~= "string" then report = self:T("reportUnavailable") end
        if #report > 65536 then report = report:sub(1, 65536) end
        local copy = self.copyFrame
        self:FitWindow(copy, copy:GetWidth(), copy:GetHeight(), 1)
        copy.edit:SetText(report)
        copy:Show(); copy.edit:SetFocus(); copy.edit:HighlightText()
    end

    local ticker = CreateFrame("Frame", nil, UIParent)
    self.ticker = ticker
    ticker:SetScript("OnUpdate", function(_, elapsed)
        self.updateAcc = (self.updateAcc or 0) + elapsed
        local bannersActive = self.activeBanner or #self.bannerQueue > 0
        local highlight = self.badges.highlight
        local now = (bannersActive or self.previewUntil or highlight) and self:Now()
        if highlight and (now >= highlight.checkAt or now >= highlight.expires) then
            if now >= highlight.expires or app:HighlightFrame(highlight.id, highlight.unit, highlight.automatic) ~= highlight.frame then
                self.badges:ClearHighlight()
            else
                highlight.checkAt = now + 0.125
            end
        end
        if bannersActive then self:AdvanceBanner(now) end
        if self.updateAcc >= 1 or self.previewUntil and now >= self.previewUntil then
            self.updateAcc = 0; self:Refresh()
        end
    end)
    ticker:RegisterEvent("PLAYER_LOGOUT")
    ticker:SetScript("OnEvent", function()
        if nearbyMoveProfile == self:Profile() then savePosition(main, "nearby") end
        if self:Profile().positions.alert and not self.bannerMoveProfile then savePosition(banner, "alert") end
    end)

    if RG.UIDialogs then
        self.dialogs = RG.UIDialogs.Attach(self, app, { button = button, label = label, localButton = localButton,
            fill = fill, outline = outline, font = font, changed = changed, notify = notify, tooltip = tooltip, hideTooltip = hideTooltip, C = C })
    end

    self:Refresh()
    return self
end
