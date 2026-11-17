local _, RG = ...
local UI = RG.Register("UI", {})
local M = RG.UIModel
local BANNER_PRIORITY = { sighting = 20, returning = 30, wave = 35, targeting = 70, watch = 90, stealth = 100 }
local BANNER_CATEGORIES = { watch = "watchTitle", watched = "watchTitle", avoid = "watchTitle", stealth = "stealthTitle", targeting = "targetingTitle", wave = "waveTitle" }
local BANNER_QUEUE_LIMIT, BANNER_MAX_AGE = 8, 5
local LIST_KIND_KEYS = { watch = "watched", avoid = "avoided", ignore = "ignored", note = "notesOnly" }
local LIST_FILTERS = { "all", "watch", "avoid", "ignore", "note" }
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
        local scale = math.min(requested or 1, math.max(0.1, (screenWidth - 24) / width), math.max(0.1, (screenHeight - 24) / height))
        frame:SetScale(scale)
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

    local function setList(contact, kind, note)
        local identity = M.EditableIdentity(contact)
        if not identity then return nil end
        if app.SetList then return app:SetList(contact, kind, note) end
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
        row:Hide()
        self.rows[i] = row
    end

    local more = font(main, 10, C.muted, "CENTER")
    more:SetPoint("BOTTOMLEFT", 10, 43); more:SetPoint("BOTTOMRIGHT", -10, 43); self.moreText = more
    local pauseButton = button(main, self:T("pause"), 118, function()
        local untilTime = M.Number(app.engine.pausedUntil)
        local paused = untilTime and untilTime > self:Now()
        if paused then app.engine:Resume() else app.engine:Pause(600); self:ClearBanners() end
        self:Refresh()
    end)
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
    y = section(alerts, "sounds", y - 4)
    local soundOptions = { { "none", "soundNone" }, { "ping", "soundPing" }, { "warning", "soundWarning" }, { "ready", "soundReady" }, { "whisper", "soundWhisper" }, { "quest", "soundQuest" } }
    for _, entry in ipairs({ { "sighting", "eventSighting" }, { "returning", "eventReturning" }, { "watch", "eventWatch" }, { "stealth", "eventStealth" }, { "targeting", "eventTargeting" }, { "wave", "eventWave" } }) do
        local kind = entry[1]
        local rowY = y
        y = choice(alerts, entry[2], "alerts.sounds." .. kind, soundOptions, y, 380)
        local listen = localButton(alerts, "previewSound", 150, function() if app.PreviewSound then app:PreviewSound(kind) end end)
        listen:SetPoint("TOPLEFT", 395, rowY - 25)
    end
    y = check(alerts, "rangeFilter", "range.enabled", y, "rangeFilterTip")
    y = slider(alerts, "rangeYards", "range.yards", y - 6, 5, 100, 5)
    y = choice(alerts, "rangePolicy", "range.policy", { { "possible", "possible" }, { "confirmed", "confirmed" } }, y)
    y = check(alerts, "unknownRange", "range.unknown", y)
    local previewAlert = localButton(alerts, "previewBanner", 200, function() self:PreviewAlert() end)
    previewAlert:SetPoint("TOPLEFT", 0, y - 6)
    local advancedRules = localButton(alerts, "rules", 240, function() if self.OpenRules then self:OpenRules() end end)
    advancedRules:SetPoint("LEFT", previewAlert, "RIGHT", 12, 0)
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
        restorePosition(main, "nearby", "RIGHT", -70, 20)
        cancelBannerMove(); restoreBanner()
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
    if nameInput.SetMaxBytes then nameInput:SetMaxBytes(64) end
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
    presetButton:SetScript("OnEnter", function() tooltip(presetButton, self:T(self.newPreset), self:T(self.newPreset .. "Tip")) end)
    presetButton:SetScript("OnLeave", hideTooltip)
    local createProfile = localButton(profiles, "createProfile", 200, function()
        if not app.db.CreateProfile then notify("noProfileAPI") return end
        local name = nameInput:GetText()
        local ok = app.db:CreateProfile(name, self.newPreset)
        if ok then nameInput:SetText(""); nameInput:ClearFocus(); app:ProfileChanged(); notify("profileCreated") else notify("profileError") end
        self:Refresh()
    end)
    createProfile:SetPoint("LEFT", presetButton, "RIGHT", 12, 0)
    nameInput:SetScript("OnEnterPressed", function() createProfile:Click() end)
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
    local exportProfile = localButton(profiles, "exportProfile", 245, function() if self.OpenTransfer then self:OpenTransfer("export") end end)
    exportProfile:SetPoint("TOPLEFT", 0, y - 615)
    local importProfile = localButton(profiles, "importProfile", 245, function() if self.OpenTransfer then self:OpenTransfer("import") end end)
    importProfile:SetPoint("LEFT", exportProfile, "RIGHT", 12, 0)
    profiles.height = -y + 670

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
    local retentionY = section(journal, "journalDays", y - 545, "retentionHelp")
    retentionY = choice(journal, "retentionMode", "retention.journalMode", { { "all", "retentionAll" }, { "watched", "retentionWatched" }, { "threats", "retentionThreats" } }, retentionY)
    retentionY = slider(journal, "journalDays", "retention.journalDays", retentionY, 0, 90, 1)
    journal.height = -retentionY + 20

    local support = CreateFrame("Frame", nil, content); self.pages.support = support; support:SetAllPoints()
    y = section(support, "support", 0, "supportHelp")
    self.supportStatus = font(support, 13, C.text)
    self.supportStatus:SetPoint("TOPLEFT", 0, y); self.supportStatus:SetWidth(550)
    local diagnosticButton = localButton(support, "diagnostics", 260, function() self:ShowDiagnostics() end)
    diagnosticButton:SetPoint("TOPLEFT", 0, y - 140)
    local supportPreview = localButton(support, "demo", 180, function() app:Demo() end)
    supportPreview:SetPoint("LEFT", diagnosticButton, "RIGHT", 12, 0)
    local guideReplayButton = localButton(support, "guideReplay", 300, function() if self.ShowGuide then self:ShowGuide(true) end end)
    guideReplayButton:SetPoint("TOPLEFT", 0, y - 180)
    local caution = label(support, "statusHelp", 13, C.muted)
    caution:SetPoint("TOPLEFT", 0, y - 228); caution:SetWidth(550)
    support.height = -y + 310

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
        for _, entry in ipairs(self.localized) do entry.text:SetText(self:T(entry.key)) end
        for _, control in ipairs(self.controls) do
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
        local profile = self:Profile()
        local entries, list = {}, app.db:GetList()
        local personal = self.journalMode == "personal"
        local journalEntries = app.db.GetJournal and app.db:GetJournal() or {}
        local query = profile.display.streamer and "" or self.journalQuery
        if self.journalSearch.SetEnabled then self.journalSearch:SetEnabled(not profile.display.streamer) end
        if personal then
            for identity, item in pairs(list) do
                if (self.journalFilter == "all" or self.journalFilter == item.kind) and M.Matches(query, item.name, item.note) then
                    entries[#entries + 1] = { identity = identity, name = item.name, class = item.class, note = item.note, listKind = item.kind, savedOnly = true }
                end
            end
            table.sort(entries, function(a, b)
                local x, y = M.SearchText(a.name), M.SearchText(b.name)
                if x ~= y then return x < y end
                return a.identity < b.identity
            end)
        else
            for _, item in ipairs(journalEntries) do
                local record = list[item.identity]
                if M.Matches(query, item.name, record and record.note) then entries[#entries + 1] = item end
            end
        end
        self.journalRecent.bg:SetColorTexture(unpack(not personal and { 0.10, 0.22, 0.28, 1 } or C.panel))
        self.journalPersonal.bg:SetColorTexture(unpack(personal and { 0.10, 0.22, 0.28, 1 } or C.panel))
        self.journalFilterButton:SetShown(personal)
        self.journalClear:SetShown(not personal)
        self.journalClear:SetEnabled(#journalEntries > 0)
        local confirming = self.clearJournalUntil and self.clearJournalUntil >= self:Now()
        self.journalClear.label:SetText(self:T(confirming and "clearJournalNow" or "clearJournal"))
        self.journalFilterButton.label:SetText(self:T(LIST_KIND_KEYS[self.journalFilter] or "allLists") .. "  ›")
        self.journalCount:SetText(self:F("filteredCount", #entries))
        self.journalEmpty:SetShown(#entries == 0)
        self.journalEmpty:SetText(self:T(query ~= "" and "noMatches" or personal and "listEmpty" or "emptyJournal"))
        self.journalOffset = math.max(0, math.min(self.journalOffset, math.max(0, math.floor((#entries - 1) / 12) * 12)))
        self.journalPrev:SetEnabled(self.journalOffset > 0)
        self.journalNext:SetEnabled(self.journalOffset + 12 < #entries)
        local epoch = not personal and app.engine.epoch and M.Number(app.engine.epoch())
        local now = self:Now()
        for i, row in ipairs(self.journalRows) do
            local entry = entries[self.journalOffset + i]
            if entry then
                entry.id = entry.identity
                entry.visible = false
                entry.sources = { journal = true }
                if not entry.savedOnly then
                    local recorded = M.Number(entry.lastSeen)
                    entry.lastSeen = epoch and epoch > 0 and recorded and recorded > 0 and now - math.max(0, epoch - recorded) or nil
                    local record = list[entry.identity]
                    if record then entry.note, entry.listKind = record.note, record.kind end
                end
            end
            row.contact = entry
            row:SetShown(entry ~= nil)
            if entry then
                local name = M.Text(entry.name, self:T("nameUnavailable"))
                if profile.display.streamer then name = self:T("unknownPlayer") .. " " .. (self.journalOffset + i) end
                local tag = personal and self:T(LIST_KIND_KEYS[entry.listKind] or "unlisted") or M.State(entry, now, profile.locale)
                row.label:SetText(name .. "  ·  " .. tag)
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
            restorePosition(main, "nearby", "RIGHT", -70, 20)
            cancelBannerMove(); restoreBanner()
            self.lastProfile = profile
            self.alertProfile, self.alertConfig = profile, self:AlertConfig(profile)
            self.controlsDirty = true
        elseif not self.bannerMoveProfile and not profile.positions.alert and self.bannerDefaultOffset ~= bannerDefaultPoint() then
            restoreBanner()
        end
        local now = self:Now()
        local preview = self.previewUntil and self.previewUntil > now
        if not preview then self.previewContacts, self.previewUntil = nil, nil end
        local snapshot = preview and self.previewContacts or app.engine:Snapshot()
        local rows = M.Rows(snapshot, profile, now, preview and self.previewAliases or self.aliases)
        self.renderedCount = #rows
        local maxRows = math.floor(RG.Util.Clamp(profile.display.maxRows, 3, 20, 8))
        local rowHeight = profile.display.textSize + UI.layout.rowPadding
        local mainHeight = UI.layout.header + math.max(3, math.min(maxRows, #rows)) * rowHeight + UI.layout.footer
        main:SetHeight(mainHeight)
        self:FitWindow(main, UI.layout.width, mainHeight, profile.display.scale)
        main:SetShown(profile.display.showList or preview)
        self.offset = math.max(0, math.min(self.offset, math.max(0, #rows - maxRows)))
        local needsStatus = self.statusAt == nil or now - self.statusAt >= 1
            or settings:IsShown() and self.currentPage == "support" and self.statusPage ~= "support"
        if needsStatus then
            self.statusCache = app.Status and app:Status() or {}
            self.statusAt = now
        end
        self.statusPage = settings:IsShown() and self.currentPage or nil
        local appStatus = self.statusCache or {}
        if type(appStatus) ~= "table" then appStatus = { detail = appStatus } end
        local untilTime = M.Number(app.engine.pausedUntil)
        local paused = appStatus.state == "paused" or (untilTime and untilTime > now)
        local visibleCount = 0
        for _, row in ipairs(rows) do if row.visible and row.contact.behindCamera ~= true then visibleCount = visibleCount + 1 end end
        self.visibleCount = preview and 0 or visibleCount
        local status = preview and self:T("demoLabel") or not profile.enabled and self:T("disabled") or paused and self:T("paused") or self:T(appStatus.state == "limited" and "limited" or "active")
        statusText:SetText(status .. " · " .. self:F("inViewCount", visibleCount))
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
                if data.class and not profile.display.highContrast then row.nameText:SetTextColor(classColor(data.class)) else row.nameText:SetTextColor(unpack(C.text)) end
                local level = M.Number(data.contact.level)
                row.detailText:SetText(level and (self:F("levelShort", level) .. " · " .. data.detail) or data.detail)
                row.detailText:SetTextColor(unpack(profile.display.highContrast and C.text or C.muted))
                row.icon:SetTexture(data.class and ("Interface\\Icons\\ClassIcon_" .. data.class) or "Interface\\Icons\\INV_Misc_QuestionMark")
                row:SetAlpha(data.visible and 1 or profile.display.highContrast and 0.9 or 0.65)
                local currentTarget = data.visible and data.contact.currentTarget == true
                local currentFocus = data.visible and data.contact.currentFocus == true
                row.mark:SetText(currentTarget and "▼" or currentFocus and "◆" or "!")
                row.mark:SetShown(data.contact.watched == true or data.contact.listKind == "avoid" or currentTarget or currentFocus)
            end
        end
        more:SetText(#rows > maxRows and self:F("moreContacts", #rows - maxRows) or self:T("noTarget"))
        if self.controlsDirty then self:RefreshControls(); self.controlsDirty = false end
        if #rows == 0 then
            local titleKey, helpKey = "noEnemies", "noEnemiesHelp"
            if not profile.enabled and not preview then titleKey, helpKey = "noDisabled", "noDisabledHelp"
            elseif #snapshot > 0 or M.Number(appStatus.contacts, 0) > 0 then titleKey, helpKey = "noFiltered", "noFilteredHelp"
            elseif appStatus.nameplates == false and not preview then titleKey, helpKey = "noNameplates", "noNameplatesHelp" end
            empty:SetText(self:T(titleKey)); emptyHelp:SetText(self:T(helpKey))
        end
        self.badges:Refresh()
        if self.launcher then self.launcher:Refresh() end
        if settings:IsShown() then
            self:FitWindow(settings, UI.layout.settingsWidth, UI.layout.settingsHeight, 1)
            if self.currentPage == "profiles" and (needsStatus or self.dataPage ~= "profiles") then self:RefreshProfiles() end
            if self.currentPage == "journal" and (needsStatus or self.dataPage ~= "journal") then self:RefreshJournal() end
            if self.currentPage == "support" then
                local lines = { M.Text(appStatus.detail, self:T("sensorReady")) }
                if appStatus.nameplates == false then lines[#lines + 1] = self:T("nameplatesOff") end
                if appStatus.state == "limited" then lines[#lines + 1] = self:T("sensorLimited") end
                if appStatus.state == "disabled" then lines[#lines + 1] = self:T("disabled") end
                if appStatus.writable == false then lines[#lines + 1] = self:T("sessionOnly") end
                self.supportStatus:SetText(table.concat(lines, "\n\n"))
            end
            self.dataPage = self.currentPage
        else
            self.dataPage = nil
        end
        if self.dialogs then self.dialogs:Refresh() end
        if self.detailsFrame and self.detailsFrame:IsShown() and self.selected then
            local current
            for _, contact in ipairs(snapshot) do
                if contact.id == self.selected.id or self.selected.identity and contact.identity == self.selected.identity then current = contact break end
            end
            if current and not self.selected.savedOnly then self.selected = current end
            self.selectedOutside = current == nil
            self:ShowDetails(true)
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

    function self:AdvanceBanner(now)
        local active = self.activeBanner
        local pausedUntil = M.Number(app.engine.pausedUntil)
        if pausedUntil and pausedUntil > now then
            self:ClearBanners()
            active = self.activeBanner
        end
        if active and self.bannerUntil > now then
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
            if now - item.at <= BANNER_MAX_AGE then self:ShowBanner(item, now); return end
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
            stealthEvidence = M.Text(contact.stealthEvidence, ""), stealthSpell = M.Text(contact.stealthSpell, ""),
            id = id, identity = M.Text(contact.identity, "", 256), preview = preview, priority = priority, at = now,
            key = id ~= "" and (kind .. ":" .. id) or nil }
        self:AdvanceBanner(now)
        local active = self.activeBanner
        if preview and active and not active.preview then return end
        if active and item.key and active.key == item.key and active.preview == item.preview then return end
        if not active or active.preview or item.priority > active.priority then self:ShowBanner(item, now); return end
        for i = #self.bannerQueue, 1, -1 do
            local queued = self.bannerQueue[i]
            if now - queued.at > BANNER_MAX_AGE then table.remove(self.bannerQueue, i)
            elseif item.key and item.key == queued.key then return end
        end
        local index = #self.bannerQueue + 1
        for i, queued in ipairs(self.bannerQueue) do if item.priority > queued.priority then index = i break end end
        table.insert(self.bannerQueue, index, item)
        if #self.bannerQueue > BANNER_QUEUE_LIMIT then table.remove(self.bannerQueue) end
    end

    function self:PreviewAlert()
        self:Alert({ kind = "stealth", contact = { name = self:T("demoRogue"), class = "ROGUE" }, sound = true, preview = true })
        if app.PreviewSound then app:PreviewSound("stealth") end
    end

    function self:Preview(contacts, decision)
        self.previewContacts = RG.Util.Copy(contacts or {
            { id = "preview-rogue", name = self:T("demoRogue"), class = "ROGUE", visible = true, lastSeen = self:Now(), rangeMin = 10, rangeMax = 20 },
            { id = "preview-hunter", name = self:T("demoHunter"), class = "HUNTER", visible = true, lastSeen = self:Now(), rangeMin = 20, rangeMax = 40 },
            { id = "preview-mage", name = self:T("demoMage"), class = "MAGE", visible = false, lastSeen = self:Now() - 12 },
        })
        for _, contact in ipairs(self.previewContacts) do contact.identity, contact.preview = nil, true end
        self.previewAliases = {}
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
        self.noteDraft = nil
        self.removeEntryAt, self.removeEntryIdentity = nil, nil
        self.selectedOutside = contact.sources and contact.sources.journal == true or false
        self:ShowDetails()
    end

    function self:ShowDetails(refreshOnly)
        if not self.detailsFrame then
            local detail = self:Window("RivalGuardDetails", UIParent)
            self.detailsFrame = detail
            detail:SetSize(470, 525); detail:SetPoint("CENTER", 80, 0)
            detail:SetFrameStrata("DIALOG"); detail:SetClampedToScreen(true); detail:EnableMouse(true)
            fill(detail); outline(detail)
            detail.title = font(detail, 18, C.accent)
            detail.title:SetPoint("TOPLEFT", 18, -16); detail.title:SetWidth(344)
            if detail.title.SetMaxLines then detail.title:SetMaxLines(1) end
            local close = localButton(detail, "close", 84, function() detail:Hide() end)
            close:SetPoint("TOPRIGHT", -12, -10)
            detail.info = font(detail, 13, C.text)
            detail.info:SetPoint("TOPLEFT", 18, -57); detail.info:SetWidth(432)
            detail.notice = label(detail, "noTarget", 11, C.muted)
            detail.notice:SetPoint("TOPLEFT", 18, -155); detail.notice:SetWidth(432)
            local actions = { "watch", "avoid", "ignore" }
            detail.listActions = {}
            for i, action in ipairs(actions) do
                local kind = action
                local b = localButton(detail, action, 130, function()
                    local contact = self.selected
                    if not contact then return end
                    if not M.EditableIdentity(contact) then notify("identityUnknown") return end
                    local entry = app.db:GetList()[contact.identity]
                    local ok = setList(contact, kind, entry and entry.note)
                    if not ok then notify("saveFailed") return end
                    self:SettingsChanged(); self:ShowDetails(true)
                end)
                b:SetPoint("TOPLEFT", 18 + (i - 1) * 142, -192)
                detail.listActions[kind] = b
            end
            local remove = localButton(detail, "removeList", 150, function()
                local contact = self.selected
                if not M.EditableIdentity(contact) then notify("identityUnknown") return end
                local entry = app.db:GetList()[contact.identity]
                if not entry then return end
                local ok = setList(contact, entry.note and "note" or nil, entry.note)
                if not ok then notify("saveFailed") return end
                notify("confirmRemove"); self:SettingsChanged(); self:ShowDetails(true)
            end)
            remove:SetPoint("TOPLEFT", 18, -231)
            detail.removeMembership = remove
            local why = localButton(detail, "why", 150, function() self:ShowExplanation() end)
            why:SetPoint("TOPLEFT", 185, -231)
            local noteTitle = label(detail, "note", 13)
            noteTitle:SetPoint("TOPLEFT", 18, -275)
            detail.note = CreateFrame("EditBox", nil, detail, "InputBoxTemplate")
            detail.note:SetPoint("TOPLEFT", 25, -304); detail.note:SetSize(420, 28)
            detail.note:SetAutoFocus(false); detail.note:SetMaxLetters(512)
            if detail.note.SetMaxBytes then detail.note:SetMaxBytes(512) end
            detail.note:SetScript("OnTextChanged", function(box, userInput)
                local identity = M.EditableIdentity(self.selected)
                if userInput and identity and not self:Profile().display.streamer then
                    self.noteDraft = { identity = identity, text = box:GetText() }
                end
            end)
            detail.note:SetScript("OnEscapePressed", function(box)
                self.noteDraft = nil; box:ClearFocus(); self:ShowDetails()
            end)
            detail:SetScript("OnHide", function() self.noteDraft = nil; detail.note:ClearFocus() end)
            local save = localButton(detail, "saveNote", 160, function()
                local contact = self.selected
                if not M.EditableIdentity(contact) or self:Profile().display.streamer then return end
                if not app.SetNote then notify("noListAPI") return end
                local ok = app:SetNote(contact, detail.note:GetText())
                detail.note:ClearFocus()
                if ok then self.noteDraft = nil; self:ShowDetails() end
                notify(ok and "noteSaved" or "saveFailed")
            end)
            save:SetPoint("TOPLEFT", 18, -350)
            save:SetScript("OnEnter", function() tooltip(save, self:T("saveNote"), self:T("keyboardEditHelp")) end)
            save:SetScript("OnLeave", hideTooltip)
            detail.saveNote, detail.noteTitle = save, noteTitle
            detail.note:SetScript("OnEnterPressed", function() save:Click() end)
            detail.privateNote = label(detail, "notePrivate", 12, C.muted)
            detail.privateNote:SetPoint("TOPLEFT", 18, -304); detail.privateNote:SetWidth(432)
            detail.snooze = button(detail, self:T("snoozeContact"), 274, function()
                local contact = self.selected
                if not self:CanSnooze(contact) then notify("snoozeUnavailable") return end
                local ok = app:Snooze(contact, 600)
                if ok then self:Refresh() else notify("snoozeUnavailable") end
            end)
            detail.snooze:SetPoint("TOPLEFT", 18, -392)
            detail.snooze:SetScript("OnEnter", function()
                local remaining = math.max(0, M.Number(self.selected and self.selected.snoozedUntil, 0) - self:Now())
                local description = remaining > 0 and self:F("snoozedFor", M.Age(remaining, self:Profile().locale)) or self:T("snoozeContact")
                tooltip(detail.snooze, self:T("alerts"), description)
            end)
            detail.snooze:SetScript("OnLeave", hideTooltip)
            local help = label(detail, "identityUnknown", 11, C.muted)
            help:SetPoint("TOPLEFT", 18, -445); help:SetWidth(432)
            detail.identityHelp = help
            detail.removeSaved = localButton(detail, "deleteRecord", 220, function()
                local contact = self.selected
                if not M.EditableIdentity(contact) or not contact.savedOnly then return end
                if self.removeEntryIdentity ~= contact.identity or (self.removeEntryAt or 0) < self:Now() then
                    self.removeEntryIdentity, self.removeEntryAt = contact.identity, self:Now() + 6
                    detail.removeSaved.label:SetText(self:T("deleteRecordNow"))
                    return
                end
                local ok = setList(contact, nil)
                if not ok then notify("saveFailed") return end
                self.removeEntryAt, self.removeEntryIdentity = nil, nil
                detail:Hide(); self:SettingsChanged(); notify("recordDeleted")
            end)
            detail.removeSaved:SetPoint("TOPRIGHT", -16, -350)
            if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "RivalGuardDetails" end
        end
        local detail, contact = self.detailsFrame, self.selected
        if not contact then detail:Hide() return end
        local profile = self:Profile()
        local identity = M.EditableIdentity(contact)
        local name = M.Text(contact.name, self:T(contact.savedOnly and "nameUnavailable" or "unknownPlayer"))
        if profile.display.streamer then name = self:T("unknownPlayer") end
        detail.title:SetText(name)
        local class = M.Text(contact.class, "")
        local lines = { RG.Defaults.classSet[class] and RG.Locale.Class(class, self:Profile().locale) or self:T("unknownClass") }
        local entry = contact.identity and app.db:GetList()[contact.identity]
        local state = contact
        if self.selectedOutside and contact.visible then
            state = { visible = false, lastSeen = contact.lastSeen }
        end
        lines[#lines + 1] = contact.savedOnly and self:T("noCurrentEvidence") or M.State(state, self:Now(), self:Profile().locale)
        if entry then lines[#lines + 1] = self:F("currentList", self:T(LIST_KIND_KEYS[entry.kind] or "unlisted")) end
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
        detail.info:SetText(table.concat(lines, "\n"))
        if profile.display.streamer then
            self.noteDraft = nil; detail.note:ClearFocus(); detail.note:SetText("")
        elseif not refreshOnly or not (detail.note.HasFocus and detail.note:HasFocus()) then
            local pending = self.noteDraft and self.noteDraft.identity == identity and self.noteDraft.text
            detail.note:SetText(pending or M.Text(entry and entry.note, "", 512))
        end
        detail.noteTitle:SetShown(not profile.display.streamer)
        detail.note:SetShown(not profile.display.streamer)
        if detail.note.SetEnabled then detail.note:SetEnabled(identity ~= nil) end
        detail.saveNote:SetShown(not profile.display.streamer)
        detail.saveNote:SetEnabled(identity ~= nil)
        detail.privateNote:SetShown(profile.display.streamer)
        detail.identityHelp:SetShown(identity == nil)
        detail.identityHelp:SetText(self:T(contact.preview and "noPreviewTarget" or contact.savedOnly and "legacyIdentity" or "identityUnknown"))
        for kind, buttonFrame in pairs(detail.listActions) do
            buttonFrame:SetEnabled(identity ~= nil and (not entry or entry.kind ~= kind))
            buttonFrame.bg:SetColorTexture(unpack(entry and entry.kind == kind and { 0.10, 0.22, 0.28, 1 } or C.panel))
        end
        detail.removeMembership:SetEnabled(identity ~= nil and entry ~= nil and entry.kind ~= "note")
        detail.removeSaved:SetShown(contact.savedOnly == true and identity ~= nil and entry ~= nil)
        local confirming = self.removeEntryIdentity == contact.identity and (self.removeEntryAt or 0) >= self:Now()
        detail.removeSaved.label:SetText(self:T(confirming and "deleteRecordNow" or "deleteRecord"))
        local canSnooze = self:CanSnooze(contact)
        local remaining = math.max(0, M.Number(contact.snoozedUntil, 0) - self:Now())
        detail.snooze:SetShown(canSnooze)
        detail.snooze.label:SetText(self:T(remaining > 0 and "resumeContact" or "snoozeContact"))
        self:FitWindow(detail, 470, 525, 1)
        detail:Show()
    end

    function self:CanSnooze(contact)
        return app.Snooze ~= nil and M.EditableIdentity(contact) ~= nil and not self.selectedOutside and not contact.savedOnly
            and (not contact.sources or not contact.sources.journal) and M.Text(contact.id, "", 256) ~= ""
    end

    function self:ShowExplanation()
        if not self.explanationFrame then
            local frame = self:Window("RivalGuardExplanation", UIParent)
            self.explanationFrame = frame
            frame:SetSize(460, 265); frame:SetPoint("CENTER", 0, 80); frame:SetFrameStrata("DIALOG")
            frame:SetClampedToScreen(true); frame:EnableMouse(true)
            fill(frame); outline(frame)
            local titleText = label(frame, "explanation", 17, C.accent)
            titleText:SetPoint("TOPLEFT", 18, -18); titleText:SetWidth(325)
            local close = localButton(frame, "close", 84, function() frame:Hide() end)
            close:SetPoint("TOPRIGHT", -12, -10)
            frame.reason = font(frame, 14, C.text)
            frame.reason:SetPoint("TOPLEFT", 18, -69); frame.reason:SetWidth(420)
            local help = label(frame, "explanationHelp", 12, C.muted)
            help:SetPoint("BOTTOMLEFT", 18, 24); help:SetWidth(420)
            if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "RivalGuardExplanation" end
        end
        local result = app.Explain and self.selected and app:Explain(self.selected) or nil
        self.explanationFrame.reason:SetText(RG.Locale.Reason(type(result) == "table" and result.reason or "unavailable", self:Profile().locale))
        self:FitWindow(self.explanationFrame, 460, 265, 1)
        self.explanationFrame:Show()
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
        self.copyFrame.edit:SetText(report)
        self.copyFrame:Show(); self.copyFrame.edit:SetFocus(); self.copyFrame.edit:HighlightText()
    end

    local ticker = CreateFrame("Frame", nil, UIParent)
    self.ticker = ticker
    ticker:SetScript("OnUpdate", function(_, elapsed)
        self.updateAcc = (self.updateAcc or 0) + elapsed
        if self.activeBanner or #self.bannerQueue > 0 then self:AdvanceBanner(self:Now()) end
        if self.updateAcc >= 1 then self.updateAcc = 0; self:Refresh() end
    end)
    ticker:RegisterEvent("PLAYER_LOGOUT")
    ticker:SetScript("OnEvent", function()
        savePosition(main, "nearby")
        if self:Profile().positions.alert and not self.bannerMoveProfile then savePosition(banner, "alert") end
    end)

    if RG.UIDialogs then
        self.dialogs = RG.UIDialogs.Attach(self, app, { button = button, label = label, localButton = localButton,
            fill = fill, outline = outline, font = font, changed = changed, notify = notify, tooltip = tooltip, hideTooltip = hideTooltip, C = C })
    end

    self:Refresh()
    return self
end
