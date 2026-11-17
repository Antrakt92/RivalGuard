local _, RG = ...
local UI = RG.Register("UI", {})
local M = RG.UIModel

UI.layout = { width = 348, header = 88, footer = 58, rowPadding = 20, settingsWidth = 800, settingsHeight = 610 }

local C = {
    bg = { 0.035, 0.045, 0.065, 0.97 }, panel = { 0.065, 0.080, 0.105, 0.98 },
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
    local self = { app = app, aliases = {}, offset = 0, profileOffset = 0, journalOffset = 0, rows = {}, controls = {}, pages = {}, localized = {}, selected = nil }

    function self:Profile() return app.db:GetProfile() end
    function self:T(key) return RG.Locale.Get(key, self:Profile().locale) end
    function self:F(key, ...) return RG.Locale.Format(key, self:Profile().locale, ...) end
    function self:Now() return app.engine:Now() end

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
        self:Refresh()
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
        end
    end

    local main = CreateFrame("Frame", "RivalGuardNearby", UIParent)
    self.frame = main
    main:SetSize(UI.layout.width, 410)
    main:SetFrameStrata("MEDIUM")
    main:SetClampedToScreen(true)
    main:SetMovable(true)
    main:EnableMouseWheel(true)
    fill(main); outline(main)
    restorePosition(main, "nearby", "RIGHT", -70, 20)

    local header = CreateFrame("Button", nil, main)
    header:SetPoint("TOPLEFT", 0, 0); header:SetPoint("TOPRIGHT", -34, 0); header:SetHeight(28)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() if not self:Profile().display.locked then main:StartMoving() end end)
    header:SetScript("OnDragStop", function() main:StopMovingOrSizing(); savePosition(main, "nearby") end)
    local title = label(header, "addon", 15, C.accent)
    title:SetPoint("LEFT", 12, 0); title:SetJustifyV("MIDDLE")
    local settingsButton = button(main, "…", 30, function() self:OpenSettings() end)
    settingsButton:SetPoint("TOPRIGHT", -3, -2); settingsButton:SetHeight(25)
    settingsButton:SetScript("OnEnter", function() tooltip(settingsButton, self:T("settings"), self:T("listHint")) end)
    settingsButton:SetScript("OnLeave", hideTooltip)
    local statusText = font(main, 11, C.muted)
    statusText:SetPoint("TOPLEFT", 12, -31); statusText:SetWidth(324)
    self.statusText = statusText

    local function makeClassChips(parent, x, y, group, compact)
        local chips = {}
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
            chip:SetScript("OnClick", function()
                local profile = self:Profile()
                profile[group].classes = M.ToggleClass(profile[group].classes, class)
                changed()
            end)
            chip:SetScript("OnEnter", function() tooltip(chip, RG.Locale.Class(class, self:Profile().locale), self:T(group == "display" and "displayClasses" or "alertClasses")) end)
            chip:SetScript("OnLeave", hideTooltip)
            chips[#chips + 1] = { frame = chip, class = class, group = group }
        end
        self.controls[#self.controls + 1] = { kind = "classes", chips = chips }
        return chips
    end

    self.quickChips = makeClassChips(main, 12, -53, "display", true)

    local empty = label(main, "noEnemies", 14, C.text)
    empty:SetPoint("TOPLEFT", 15, -104); empty:SetWidth(318); empty:SetJustifyH("CENTER")
    local emptyHelp = label(main, "noEnemiesHelp", 11, C.muted)
    emptyHelp:SetPoint("TOPLEFT", 20, -130); emptyHelp:SetWidth(308); emptyHelp:SetJustifyH("CENTER")
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
        row.detailText = font(row, 10, C.muted)
        row.detailText:SetPoint("TOPLEFT", 36, -19); row.detailText:SetWidth(280)
        row.mark = font(row, 15, C.gold, "RIGHT")
        row.mark:SetPoint("TOPRIGHT", -8, -3); row.mark:SetText("!")
        row:SetScript("OnClick", function() if row.contact then self:Select(row.contact) end end)
        row:SetScript("OnEnter", function()
            if not row.contact then return end
            tooltip(row, row.nameText:GetText(), self:T("rowHint") .. "\n" .. self:T("noTarget"))
        end)
        row:SetScript("OnLeave", hideTooltip)
        row:Hide()
        self.rows[i] = row
    end

    local more = font(main, 10, C.muted, "CENTER")
    more:SetPoint("BOTTOMLEFT", 10, 43); more:SetPoint("BOTTOMRIGHT", -10, 43); self.moreText = more
    local pauseButton = button(main, self:T("pause"), 118, function()
        local paused = self.pauseUntil and self.pauseUntil > self:Now()
        if paused then app.engine:Resume(); self.pauseUntil = nil
        else app.engine:Pause(600); self.pauseUntil = self:Now() + 600 end
        self:Refresh()
    end)
    pauseButton:SetPoint("BOTTOMLEFT", 10, 9); self.pauseButton = pauseButton
    local muteButton = button(main, self:T("mute"), 111, function() app:ToggleMute(); self:Refresh() end)
    muteButton:SetPoint("LEFT", pauseButton, "RIGHT", 5, 0); self.muteButton = muteButton
    local demoButton = localButton(main, "demo", 85, function() app:Demo() end)
    demoButton:SetPoint("LEFT", muteButton, "RIGHT", 5, 0)
    demoButton:SetScript("OnEnter", function() tooltip(demoButton, self:T("demo"), self:T("demoTip")) end)
    demoButton:SetScript("OnLeave", hideTooltip)
    main:SetScript("OnMouseWheel", function(_, delta)
        local count = #M.Rows(app.engine:Snapshot(), self:Profile(), self:Now(), self.aliases)
        self.offset = math.max(0, math.min(math.max(0, count - self:Profile().display.maxRows), self.offset - delta))
        self:Refresh()
    end)

    local banner = CreateFrame("Frame", "RivalGuardAlert", UIParent)
    self.banner = banner
    banner:SetSize(440, 84); banner:SetFrameStrata("HIGH"); banner:SetClampedToScreen(true)
    banner:SetMovable(true); banner:EnableMouse(false)
    fill(banner, { 0.035, 0.05, 0.075, 0.97 }); self.bannerOutline = outline(banner, { 0.37, 0.78, 0.92, 1 })
    restorePosition(banner, "alert", "TOP", 0, -180)
    banner.icon = banner:CreateTexture(nil, "ARTWORK")
    banner.icon:SetPoint("LEFT", 14, 0); banner.icon:SetSize(42, 42)
    banner.title = font(banner, 16, C.accent)
    banner.title:SetPoint("TOPLEFT", 70, -14); banner.title:SetWidth(350)
    banner.body = font(banner, 13)
    banner.body:SetPoint("TOPLEFT", 70, -40); banner.body:SetWidth(350)
    banner:RegisterForDrag("LeftButton")
    banner:SetScript("OnDragStart", function() if self.bannerPreview then banner:StartMoving() end end)
    banner:SetScript("OnDragStop", function() banner:StopMovingOrSizing(); savePosition(banner, "alert") end)
    banner:Hide()

    local settings = CreateFrame("Frame", "RivalGuardSettings", UIParent)
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
    scrollbar:SetWidth(12); scrollbar:SetOrientation("VERTICAL"); scrollbar:SetMinMaxValues(0, 500); scrollbar:SetValueStep(20)
    fill(scrollbar, C.panel)
    scrollbar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    scrollbar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value) end)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local maximum = math.max(0, (self.pageHeight or 0) - scroll:GetHeight())
        scrollbar:SetValue(math.max(0, math.min(maximum, scrollbar:GetValue() - delta * 40)))
    end)
    self.scroll, self.scrollbar = scroll, scrollbar
    settings:Hide()

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

    local function choice(page, key, path, options, y, width)
        local titleText = label(page, key, 13)
        titleText:SetPoint("TOPLEFT", 0, y); titleText:SetWidth(550)
        local b = button(page, "", width or 400, function()
            local current = pathGet(self:Profile(), path)
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
        titleText:SetPoint("TOPLEFT", 0, y); titleText:SetWidth(550)
        makeClassChips(page, 0, y - 28, group, false)
        local allButton = localButton(page, "all", 160, function() self:Profile()[group].classes = {}; changed() end)
        allButton:SetPoint("TOPLEFT", 0, y - 69)
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
    for _, entry in ipairs({ { "alertsEnabled", "alerts.enabled" }, { "sound", "alerts.sound" }, { "banner", "alerts.banner" }, { "alertStealth", "alerts.stealth", "alertStealthTip" }, { "alertTargeting", "alerts.targeting", "alertTargetingTip" }, { "watchedOnly", "alerts.watchedOnly", "watchedOnlyTip" }, { "muteOrdinary", "alerts.muteOrdinary", "muteOrdinaryTip" } }) do
        y = check(alerts, entry[1], entry[2], y, entry[3])
    end
    y = classSelector(alerts, "alerts", y - 10)
    y = slider(alerts, "cooldown", "alerts.cooldown", y, 5, 180, 5, "cooldownTip")
    y = slider(alerts, "returnAfter", "alerts.returnAfter", y, 5, 180, 5, "returnAfterTip")
    y = choice(alerts, "soundChannel", "alerts.channel", { { "Master", "master" }, { "SFX", "sfx" }, { "Dialog", "dialog" }, { "Music", "music" }, { "Ambience", "ambience" } }, y)
    y = check(alerts, "rangeFilter", "range.enabled", y, "rangeFilterTip")
    y = slider(alerts, "rangeYards", "range.yards", y - 6, 5, 100, 5)
    y = choice(alerts, "rangePolicy", "range.policy", { { "possible", "possible" }, { "confirmed", "confirmed" } }, y)
    y = check(alerts, "unknownRange", "range.unknown", y)
    local previewAlert = localButton(alerts, "previewBanner", 200, function() self:PreviewAlert() end)
    previewAlert:SetPoint("TOPLEFT", 0, y - 6)
    alerts.height = -y + 60

    local appearance = CreateFrame("Frame", nil, content); self.pages.appearance = appearance; appearance:SetAllPoints()
    y = section(appearance, "appearance", 0, "appearanceHelp")
    for _, entry in ipairs({ { "locked", "display.locked" }, { "showBadges", "display.showBadges", "showBadgesTip" }, { "highContrast", "display.highContrast" }, { "reducedMotion", "display.reducedMotion" }, { "streamer", "display.streamer", "streamerTip" } }) do
        y = check(appearance, entry[1], entry[2], y, entry[3])
    end
    y = slider(appearance, "textSize", "display.textSize", y - 8, 11, 20, 1)
    y = slider(appearance, "scale", "display.scale", y, 0.75, 1.5, 0.05)
    y = slider(appearance, "maxRows", "display.maxRows", y, 3, 12, 1)
    local preview = localButton(appearance, "previewBanner", 200, function() self:PreviewAlert() end)
    preview:SetPoint("TOPLEFT", 0, y)
    local previewContacts = localButton(appearance, "previewList", 200, function() app:Demo() end)
    previewContacts:SetPoint("LEFT", preview, "RIGHT", 12, 0)
    local resetPos = localButton(appearance, "resetPosition", 260, function()
        self:Profile().positions = {}
        restorePosition(main, "nearby", "RIGHT", -70, 20)
        restorePosition(banner, "alert", "TOP", 0, -180)
    end)
    resetPos:SetPoint("TOPLEFT", 0, y - 45)
    appearance.height = -y + 100

    local profiles = CreateFrame("Frame", nil, content); self.pages.profiles = profiles; profiles:SetAllPoints()
    y = section(profiles, "profiles", 0, "presetHelp")
    self.activeProfileText = font(profiles, 14, C.gold)
    self.activeProfileText:SetPoint("TOPLEFT", 0, y); self.activeProfileText:SetWidth(550)
    local nameTitle = label(profiles, "profileName", 13); nameTitle:SetPoint("TOPLEFT", 0, y - 36)
    local nameInput = CreateFrame("EditBox", nil, profiles, "InputBoxTemplate")
    nameInput:SetPoint("TOPLEFT", 8, y - 65); nameInput:SetSize(345, 26); nameInput:SetAutoFocus(false); nameInput:SetMaxLetters(64)
    nameInput:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
    self.profileInput = nameInput
    local presetTokens = { "balanced", "farming", "quiet", "battleground" }
    self.newPreset = "balanced"
    local presetButton = button(profiles, self:T("balanced"), 180, function()
        local index = 1
        for i, value in ipairs(presetTokens) do if value == self.newPreset then index = i break end end
        self.newPreset = presetTokens[index % #presetTokens + 1]; self:Refresh()
    end)
    presetButton:SetPoint("TOPLEFT", 0, y - 103); self.presetButton = presetButton
    local createProfile = localButton(profiles, "createProfile", 200, function()
        if not app.db.CreateProfile then notify("noProfileAPI") return end
        local name = nameInput:GetText()
        local ok = app.db:CreateProfile(name, self.newPreset)
        if ok then nameInput:SetText(""); nameInput:ClearFocus(); app:ProfileChanged(); notify("profileCreated") else notify("profileError") end
        self:Refresh()
    end)
    createProfile:SetPoint("LEFT", presetButton, "RIGHT", 12, 0)
    self.profileRows = {}
    for i = 1, 10 do
        local row = CreateFrame("Frame", nil, profiles)
        row:SetPoint("TOPLEFT", 0, y - 158 - (i - 1) * 39); row:SetSize(550, 34)
        row.nameText = font(row, 13); row.nameText:SetPoint("LEFT", 0, 0); row.nameText:SetWidth(300); row.nameText:SetJustifyV("MIDDLE")
        row.use = localButton(row, "useProfile", 95, function()
            if not row.profileName then return end
            local use = app.db.UseProfile or app.db.SetProfile
            local ok = use and use(app.db, row.profileName)
            if ok then app:ProfileChanged(); self:Refresh(); notify("profileUsed") else notify("profileError") end
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
    local profilePrev = localButton(profiles, "previous", 120, function() self.profileOffset = math.max(0, self.profileOffset - 10); self:RefreshProfiles() end)
    profilePrev:SetPoint("TOPLEFT", 0, y - 565)
    local profileNext = localButton(profiles, "next", 120, function() self.profileOffset = self.profileOffset + 10; self:RefreshProfiles() end)
    profileNext:SetPoint("LEFT", profilePrev, "RIGHT", 12, 0)
    self.profilePrev, self.profileNext = profilePrev, profileNext
    profiles.height = -y + 615

    local journal = CreateFrame("Frame", nil, content); self.pages.journal = journal; journal:SetAllPoints()
    y = section(journal, "journal", 0, "journalHelp")
    self.journalEmpty = label(journal, "emptyJournal", 14, C.muted)
    self.journalEmpty:SetPoint("TOPLEFT", 0, y); self.journalEmpty:SetWidth(550)
    self.journalRows = {}
    for i = 1, 12 do
        local row = button(journal, "", 550, function() end)
        row:SetPoint("TOPLEFT", 0, y - (i - 1) * 39); row:SetHeight(34)
        row:SetScript("OnClick", function() if row.contact then self:Select(row.contact) end end)
        self.journalRows[i] = row
    end
    local journalPrev = localButton(journal, "previous", 120, function() self.journalOffset = math.max(0, self.journalOffset - 12); self:RefreshJournal() end)
    journalPrev:SetPoint("TOPLEFT", 0, y - 485)
    local journalNext = localButton(journal, "next", 120, function() self.journalOffset = self.journalOffset + 12; self:RefreshJournal() end)
    journalNext:SetPoint("LEFT", journalPrev, "RIGHT", 12, 0)
    self.journalPrev, self.journalNext = journalPrev, journalNext
    journal.height = -y + 535

    local support = CreateFrame("Frame", nil, content); self.pages.support = support; support:SetAllPoints()
    y = section(support, "support", 0, "supportHelp")
    self.supportStatus = font(support, 13, C.text)
    self.supportStatus:SetPoint("TOPLEFT", 0, y); self.supportStatus:SetWidth(550)
    local diagnosticButton = localButton(support, "diagnostics", 260, function() self:ShowDiagnostics() end)
    diagnosticButton:SetPoint("TOPLEFT", 0, y - 140)
    local supportPreview = localButton(support, "demo", 180, function() app:Demo() end)
    supportPreview:SetPoint("LEFT", diagnosticButton, "RIGHT", 12, 0)
    local caution = label(support, "statusHelp", 13, C.muted)
    caution:SetPoint("TOPLEFT", 0, y - 200); caution:SetWidth(550)
    support.height = -y + 290

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

    function self:RefreshControls()
        self.refreshingControls = true
        for _, entry in ipairs(self.localized) do entry.text:SetText(self:T(entry.key)) end
        for _, control in ipairs(self.controls) do
            if control.kind == "check" then
                control.frame:SetChecked(pathGet(self:Profile(), control.path) == true)
            elseif control.kind == "slider" then
                local value = pathGet(self:Profile(), control.path)
                control.frame:SetValue(value)
                control.valueText:SetText(control.step < 1 and string.format("%.2g", value) or tostring(value))
            elseif control.kind == "choice" then
                local value = pathGet(self:Profile(), control.path)
                for _, option in ipairs(control.options) do if option[1] == value then control.frame.label:SetText(self:T(option[2]) .. "  ›") end end
            elseif control.kind == "classes" then
                for _, chip in ipairs(control.chips) do
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
        self.presetButton.label:SetText(self:T(self.newPreset) .. "  ›")
        self.profileOffset = math.max(0, math.min(self.profileOffset, math.max(0, math.floor((#names - 1) / 10) * 10)))
        self.profilePrev:SetEnabled(self.profileOffset > 0)
        self.profileNext:SetEnabled(self.profileOffset + 10 < #names)
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
        local entries = app.db.GetJournal and app.db:GetJournal() or {}
        self.journalEmpty:SetShown(#entries == 0)
        self.journalOffset = math.max(0, math.min(self.journalOffset, math.max(0, math.floor((#entries - 1) / 12) * 12)))
        self.journalPrev:SetEnabled(self.journalOffset > 0)
        self.journalNext:SetEnabled(self.journalOffset + 12 < #entries)
        for i, row in ipairs(self.journalRows) do
            local entry = entries[self.journalOffset + i]
            if entry then
                entry.id = entry.identity
                entry.visible = false
                entry.sources = { journal = true }
                local epoch = time and time() or 0
                local elapsed = math.max(0, M.Number(epoch, 0) - M.Number(entry.lastSeen, 0))
                entry.lastSeen = self:Now() - elapsed
                local list = entry.identity and app.db:GetList()[entry.identity]
                if list then entry.note, entry.listKind = list.note, list.kind end
            end
            row.contact = entry
            row:SetShown(entry ~= nil)
            if entry then
                local name = M.Text(entry.name, self:T("unknownPlayer"))
                if self:Profile().display.streamer then name = self:T("unknownPlayer") .. " " .. i end
                row.label:SetText(name)
            end
        end
    end

    function self:Refresh()
        if self.destroyed then return end
        local profile = self:Profile()
        if self.lastProfile ~= profile then
            restorePosition(main, "nearby", "RIGHT", -70, 20)
            restorePosition(banner, "alert", "TOP", 0, -180)
            self.lastProfile = profile
        end
        local now = self:Now()
        local preview = self.previewUntil and self.previewUntil > now
        if not preview then self.previewContacts, self.previewUntil = nil, nil end
        local snapshot = preview and self.previewContacts or app.engine:Snapshot()
        local rows = M.Rows(snapshot, profile, now, self.aliases)
        local maxRows = math.floor(RG.Util.Clamp(profile.display.maxRows, 3, 12, 8))
        local rowHeight = profile.display.textSize + UI.layout.rowPadding
        main:SetScale(profile.display.scale)
        main:SetHeight(UI.layout.header + math.max(3, math.min(maxRows, #rows)) * rowHeight + UI.layout.footer)
        main:SetShown(profile.display.showList or preview)
        self.offset = math.max(0, math.min(self.offset, math.max(0, #rows - maxRows)))
        local appStatus = app.Status and app:Status() or {}
        if type(appStatus) ~= "table" then appStatus = { detail = appStatus } end
        local paused = appStatus.state == "paused" or (self.pauseUntil and self.pauseUntil > now)
        local status = preview and self:T("demoLabel") or not profile.enabled and self:T("disabled") or paused and self:T("paused") or self:T("active")
        statusText:SetText(status .. " · " .. #rows .. " " .. self:T("nearby"))
        self.pauseButton.label:SetText(self:T(paused and "resume" or "pause"))
        self.muteButton.label:SetText(self:T(profile.alerts.sound and "mute" or "unmute"))
        empty:SetShown(#rows == 0); emptyHelp:SetShown(#rows == 0)
        for i, row in ipairs(self.rows) do
            local data = i <= maxRows and rows[self.offset + i] or nil
            row:SetShown(data ~= nil)
            row.contact = data and data.contact or nil
            if data then
                row:ClearAllPoints(); row:SetPoint("TOPLEFT", 8, -UI.layout.header - (i - 1) * rowHeight)
                row:SetHeight(rowHeight)
                row.nameText:SetFont(STANDARD_TEXT_FONT or "Fonts\\ARIALN.TTF", profile.display.textSize, "")
                row.detailText:SetFont(STANDARD_TEXT_FONT or "Fonts\\ARIALN.TTF", math.max(10, profile.display.textSize - 2), "")
                row.detailText:ClearAllPoints(); row.detailText:SetPoint("TOPLEFT", 36, -profile.display.textSize - 5)
                row.nameText:SetText(data.name)
                if data.class then row.nameText:SetTextColor(classColor(data.class)) else row.nameText:SetTextColor(unpack(C.text)) end
                row.detailText:SetText(data.detail)
                row.detailText:SetTextColor(unpack(profile.display.highContrast and C.text or C.muted))
                row.icon:SetTexture(data.class and ("Interface\\Icons\\ClassIcon_" .. data.class) or "Interface\\Icons\\INV_Misc_QuestionMark")
                row:SetAlpha(data.visible and 1 or profile.display.highContrast and 0.9 or 0.65)
                row.mark:SetShown(data.contact.watched == true or data.contact.listKind == "avoid")
            end
        end
        more:SetText(#rows > maxRows and self:F("moreContacts", #rows - maxRows) or self:T("noTarget"))
        self:RefreshControls()
        self.badges:Refresh()
        if settings:IsShown() then
            if self.currentPage == "profiles" then self:RefreshProfiles() end
            if self.currentPage == "journal" then self:RefreshJournal() end
            if self.currentPage == "support" then
                local lines = { M.Text(appStatus.detail, self:T("sensorReady")) }
                if appStatus.nameplates == false then lines[#lines + 1] = self:T("nameplatesOff") end
                if appStatus.state == "limited" then lines[#lines + 1] = self:T("sensorLimited") end
                if appStatus.state == "disabled" then lines[#lines + 1] = self:T("disabled") end
                self.supportStatus:SetText(table.concat(lines, "\n\n"))
            end
        end
    end

    function self:OpenSettings(page)
        page = self.pages[page] and page or self.currentPage or "overview"
        self.currentPage = page
        for key, frame in pairs(self.pages) do
            frame:SetShown(key == page)
            self.nav[key].bg:SetColorTexture(unpack(key == page and { 0.10, 0.22, 0.28, 1 } or C.panel))
        end
        self.pageHeight = self.pages[page].height
        content:SetHeight(self.pageHeight)
        scrollbar:SetMinMaxValues(0, math.max(0, self.pageHeight - scroll:GetHeight()))
        scrollbar:SetValue(0)
        settings:Show(); self:Refresh()
    end

    function self:Toggle()
        self:Profile().display.showList = not self:Profile().display.showList
        changed()
    end

    function self:Alert(decision)
        if type(decision) ~= "table" then return end
        local profile = self:Profile()
        local showBanner = decision.banner
        if showBanner == nil then showBanner = profile.alerts.banner end
        if not showBanner and not decision.preview then return end
        local contact = decision.contact or decision.player or decision
        local kind = decision.kind or decision.type or "sighting"
        local titles = { watch = "watchTitle", watched = "watchTitle", avoid = "watchTitle", stealth = "stealthTitle", targeting = "targetingTitle", wave = "waveTitle" }
        local titleKey = titles[kind] or "alertTitle"
        banner.title:SetText(self:T(titleKey))
        local count = M.Number(decision.count)
        local name = M.Text(contact.name, self:T("unknownPlayer"))
        if self:Profile().display.streamer then name = self:T("unknownPlayer") end
        banner.body:SetText(count and count > 1 and self:F("waveBody", count) or name)
        local class = M.Text(contact.class, "")
        banner.icon:SetTexture(RG.Defaults.classSet[class] and ("Interface\\Icons\\ClassIcon_" .. class) or "Interface\\Icons\\Ability_Warrior_BattleShout")
        banner.title:SetTextColor(unpack((kind == "watch" or kind == "stealth" or kind == "avoid") and C.gold or C.accent))
        self.bannerPreview = decision.preview == true
        banner:EnableMouse(self.bannerPreview)
        self.bannerUntil = self:Now() + (self.bannerPreview and 12 or 5)
        banner:SetAlpha(1); banner:Show()
    end

    function self:PreviewAlert()
        self:Alert({ kind = "stealth", contact = { name = self:T("demoRogue"), class = "ROGUE" }, sound = true, preview = true })
        if app.PreviewSound then app:PreviewSound("stealth") end
    end

    function self:Preview(contacts, decision)
        self.previewContacts = contacts or {
            { id = "preview-rogue", name = self:T("demoRogue"), class = "ROGUE", visible = true, lastSeen = self:Now(), rangeMin = 10, rangeMax = 20 },
            { id = "preview-hunter", name = self:T("demoHunter"), class = "HUNTER", visible = true, lastSeen = self:Now(), rangeMin = 20, rangeMax = 40 },
            { id = "preview-mage", name = self:T("demoMage"), class = "MAGE", visible = false, lastSeen = self:Now() - 12 },
        }
        self.previewUntil = self:Now() + 15
        decision = decision or { kind = "stealth", contact = self.previewContacts[1] }
        local sample = RG.Util.Copy(decision)
        sample.preview = true
        self:Alert(sample)
        self:Refresh()
    end

    function self:SetNameplate(unit, frame, contact) self.badges:Set(unit, frame, contact) end
    function self:RemoveNameplate(unit) self.badges:Remove(unit) end

    function self:Select(contact)
        self.selected = contact
        self:ShowDetails()
    end

    function self:ShowDetails()
        if not self.detailsFrame then
            local detail = CreateFrame("Frame", "RivalGuardDetails", UIParent)
            self.detailsFrame = detail
            detail:SetSize(470, 450); detail:SetPoint("CENTER", 80, 0)
            detail:SetFrameStrata("DIALOG"); detail:SetClampedToScreen(true); detail:EnableMouse(true)
            fill(detail); outline(detail)
            detail.title = font(detail, 18, C.accent)
            detail.title:SetPoint("TOPLEFT", 18, -16); detail.title:SetWidth(344)
            local close = localButton(detail, "close", 84, function() detail:Hide() end)
            close:SetPoint("TOPRIGHT", -12, -10)
            detail.info = font(detail, 13, C.text)
            detail.info:SetPoint("TOPLEFT", 18, -57); detail.info:SetWidth(432)
            detail.notice = label(detail, "noTarget", 11, C.muted)
            detail.notice:SetPoint("TOPLEFT", 18, -155); detail.notice:SetWidth(432)
            local actions = { { "watch", "Watch" }, { "avoid", "Avoid" }, { "ignore", "Ignore" } }
            for i, action in ipairs(actions) do
                local method = action[2]
                local b = localButton(detail, action[1], 130, function()
                    local contact = self.selected
                    if not contact then return end
                    if not contact.identity then notify("identityUnknown") return end
                    if method == "Avoid" and app.db.SetList then
                        local entry = app.db:GetList()[contact.identity]
                        local kind = "avoid"
                        if entry and entry.kind == "avoid" then kind = entry.note and "note" or nil end
                        local ok = app.db:SetList(contact.identity, kind, entry and entry.note)
                        if not ok then notify("saveFailed") return end
                        app:ProfileChanged()
                    elseif app[method] then
                        local ok = app[method](app, contact)
                        if not ok then notify("saveFailed") return end
                    else notify("noListAPI") return end
                    self:Refresh(); self:ShowDetails()
                end)
                b:SetPoint("TOPLEFT", 18 + (i - 1) * 142, -192)
            end
            local remove = localButton(detail, "removeList", 150, function()
                local contact = self.selected
                if not contact or not contact.identity then notify("identityUnknown") return end
                if not app.db.SetList then notify("noListAPI") return end
                local entry = app.db:GetList()[contact.identity]
                app.db:SetList(contact.identity, entry and entry.note and "note" or nil, entry and entry.note)
                app:ProfileChanged(); self:Refresh(); self:ShowDetails()
            end)
            remove:SetPoint("TOPLEFT", 18, -231)
            local noteTitle = label(detail, "note", 13)
            noteTitle:SetPoint("TOPLEFT", 18, -275)
            detail.note = CreateFrame("EditBox", nil, detail, "InputBoxTemplate")
            detail.note:SetPoint("TOPLEFT", 25, -304); detail.note:SetSize(420, 28)
            detail.note:SetAutoFocus(false); detail.note:SetMaxLetters(160)
            detail.note:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
            local save = localButton(detail, "saveNote", 160, function()
                local contact = self.selected
                if not contact or not contact.identity then notify("identityUnknown") return end
                if not app.SetNote then notify("noListAPI") return end
                local ok = app:SetNote(contact, detail.note:GetText())
                detail.note:ClearFocus()
                notify(ok == false and "saveFailed" or "saved")
            end)
            save:SetPoint("TOPLEFT", 18, -350)
            local help = label(detail, "identityUnknown", 11, C.muted)
            help:SetPoint("TOPLEFT", 18, -393); help:SetWidth(432)
            detail.identityHelp = help
            if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "RivalGuardDetails" end
        end
        local detail, contact = self.detailsFrame, self.selected
        if not contact then detail:Hide() return end
        local name = M.Text(contact.name, self:T("unknownPlayer"))
        if self:Profile().display.streamer then name = self:T("unknownPlayer") end
        detail.title:SetText(name)
        local class = M.Text(contact.class, "")
        local lines = { RG.Defaults.classSet[class] and RG.Locale.Class(class, self:Profile().locale) or self:T("unknownClass") }
        lines[#lines + 1] = M.State(contact, self:Now(), self:Profile().locale)
        local sourceNames = {}
        for source in pairs(contact.sources or {}) do
            local cleanSource = M.Text(source, "")
            if cleanSource ~= "" then sourceNames[#sourceNames + 1] = cleanSource end
        end
        table.sort(sourceNames)
        lines[#lines + 1] = self:T("reason") .. ": " .. (#sourceNames > 0 and table.concat(sourceNames, ", ") or self:T("observed"))
        detail.info:SetText(table.concat(lines, "\n"))
        local entry = contact.identity and app.db:GetList()[contact.identity]
        detail.note:SetText(M.Text(entry and entry.note or contact.note, "", 160))
        detail.identityHelp:SetShown(not contact.identity)
        detail:Show()
    end

    function self:ShowDiagnostics()
        if not self.copyFrame then
            local copy = CreateFrame("Frame", "RivalGuardDiagnostics", UIParent)
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
        self.copyFrame.edit:SetText(report)
        self.copyFrame:Show(); self.copyFrame.edit:SetFocus(); self.copyFrame.edit:HighlightText()
    end

    local ticker = CreateFrame("Frame", nil, UIParent)
    self.ticker = ticker
    ticker:SetScript("OnUpdate", function(_, elapsed)
        self.updateAcc = (self.updateAcc or 0) + elapsed
        if banner:IsShown() and self.bannerUntil then
            local left = self.bannerUntil - self:Now()
            if left <= 0 then banner:Hide(); banner:EnableMouse(false); self.bannerPreview = false
            elseif not self:Profile().display.reducedMotion then banner:SetAlpha(math.min(1, left * 2)) end
        end
        if self.updateAcc >= 1 then self.updateAcc = 0; self:Refresh() end
    end)
    ticker:RegisterEvent("PLAYER_LOGOUT")
    ticker:SetScript("OnEvent", function() savePosition(main, "nearby"); savePosition(banner, "alert") end)

    function self:Destroy()
        self.destroyed = true
        main:Hide(); settings:Hide(); banner:Hide()
        if self.detailsFrame then self.detailsFrame:Hide() end
        if self.copyFrame then self.copyFrame:Hide() end
        ticker:SetScript("OnUpdate", nil); ticker:UnregisterAllEvents()
        self.badges:Destroy()
    end

    self:Refresh()
    return self
end
