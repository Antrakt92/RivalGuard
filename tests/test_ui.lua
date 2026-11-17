local H = RGTest
local W = assert(loadfile(H.root .. "/tests/support/wow.lua"))()
local modules = { "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Codec.lua", "Core/Database.lua", "Core/Rules.lua", "Core/Engine.lua", "Core/Diagnostics.lua", "Locale/Strings.lua", "UI/Model.lua", "UI/Dialogs.lua", "UI/Badges.lua", "UI/Launcher.lua", "UI/Main.lua" }

local function setup(raw, configure)
    local state = W.New()
    if configure then configure(state) end
    local RG = state:Load(modules)
    local app = { db = RG.Database.New(raw), changes = 0, demos = 0 }
    app.engine = RG.Engine.New({ clock = state.clock.Now, profile = app.db:GetProfile() })
    function app:OnSettingsChanged() self.changes = self.changes + 1; self.engine:SetProfile(self.db:GetProfile()) end
    app.ProfileChanged = app.OnSettingsChanged
    function app:UseProfile(name)
        if not self.db:SetProfile(name) then return false end
        self:ProfileChanged()
        self.ui:Refresh()
        return true
    end
    function app:ToggleMute() self.db:GetProfile().alerts.sound = not self.db:GetProfile().alerts.sound; self:OnSettingsChanged() end
    function app:Demo() self.demos = self.demos + 1 end
    function app:Notify(text) state.messages[#state.messages + 1] = text end
    function app:Status() return { state = "limited", nameplates = false, detail = "Fixture limitation" } end
    function app:ExportDiagnostics() return "RivalGuard fixture report\nNo player data" end
    function app:SetNote(contact, note)
        local entry = self.db:GetList()[contact.identity]
        local ok = self.db:SetList(contact.identity, entry and entry.kind or "note", note, contact)
        if ok then self:OnSettingsChanged() end
        return ok
    end
    local ui = RG.UI.New(app)
    app.ui = ui
    return state, RG, app, ui
end

local function minimap(state, forbidden)
    local map = state.api.CreateFrame("Frame", "Minimap", state.api.UIParent)
    map:SetSize(160, 120)
    map.centerX, map.centerY = 900, 720
    map:SetScale(1.2)
    map.forbidden = forbidden
    state.api.GetCursorPosition = function() return state.cursorX, state.cursorY end
    return map
end

local function nearbyDragHeader(ui)
    for _, child in ipairs(ui.frame.children) do
        if child.scripts.OnDragStart and child.scripts.OnDragStop then return child end
    end
    error("Nearby drag header missing")
end

local function resizeViewport(state, width, height)
    local parent = state.api.UIParent
    local scale = parent:GetEffectiveScale()
    parent:SetSize(width / scale, height / scale)
end

local function compactViewport(state)
    state.api.UIParent:SetScale(1.35)
    resizeViewport(state, 640, 480)
end

local function fitCenteredDialog(state, frame)
    local parent = state.api.UIParent
    local point, relative, anchor, x, y = frame:GetPoint(1)
    H.True(frame:IsShown())
    H.True(frame.clamped)
    H.Equal(point, "CENTER"); H.Equal(relative, parent); H.Equal(anchor, "CENTER")
    H.Nil(frame:GetPoint(2))
    local scale = frame:GetEffectiveScale() / parent:GetEffectiveScale()
    local halfWidth = frame:GetWidth() * scale / 2
    local halfHeight = frame:GetHeight() * scale / 2
    local width, height = parent:GetWidth(), parent:GetHeight()
    local centerX, centerY = width / 2 + x * scale, height / 2 + y * scale
    H.True(centerX - halfWidth >= 0, "dialog left edge exceeds the viewport")
    H.True(centerX + halfWidth <= width, "dialog right edge exceeds the viewport")
    H.True(centerY - halfHeight >= 0, "dialog bottom edge exceeds the viewport")
    H.True(centerY + halfHeight <= height, "dialog top edge exceeds the viewport")
    return x, y
end

H.Test("actual UI initializes through strict frame methods and accessible controls", function()
    local state, _, app, ui = setup()
    H.True(ui.frame:IsShown()); H.False(ui.settings:IsShown())
    H.Equal(ui.settings.strata, "DIALOG")
    H.True(#ui.controls > 20)
    ui:OpenSettings("alerts")
    H.True(ui.settings:IsShown()); H.True(ui.pages.alerts:IsShown()); H.False(ui.pages.overview:IsShown())
    ui.muteButton:Click(); H.False(app.db:GetProfile().alerts.sound)
    ui.pauseButton:Click(); H.True(app.engine.pausedUntil > state.clock.Now())
    ui.pauseButton:Click(); H.Nil(app.engine.pausedUntil)
    H.Equal(#state.blocked, 0)
end)

H.Test("detection and alert status stay separate with guarded automatic-nameplate guidance", function()
    for _, locale in ipairs({ "enUS", "ruRU" }) do
        local state, RG, app, ui = setup(nil, function(fixture) minimap(fixture) end)
        app.db:GetProfile().locale = locale
        local status = { state = "paused", detectionState = "limited", nameplates = true, alwaysNameplates = false }
        local block = "paused"
        function app:Status() return status end
        function app:AlertBlock() return block end
        app.engine:Observe({ token = "target", guid = "Player-Status", name = "Example", class = "ROGUE", hostile = true, isPlayer = true, source = "target" })
        ui:OpenSettings("support")
        local reason = RG.Locale.Reason(block, locale)
        local hint = ui:T("nameplatesAutomatic")
        local text = ui.supportStatus:GetText()
        H.True(text:find(ui:T("sensorLimited"), 1, true) ~= nil)
        H.True(text:find(reason, 1, true) ~= nil)
        H.True(text:find(hint, 1, true) ~= nil)
        H.Equal(ui.statusText:GetText(), ui:T("limited") .. " · " .. ui:F("inViewCount", 1) .. " · " .. ui:T("alertsQuiet"))

        local launcher = assert(ui.launcher).frame
        launcher.scripts.OnEnter(launcher)
        H.True(state.api.GameTooltip:GetText():find(ui:T("limited"), 1, true) ~= nil)
        H.True(state.api.GameTooltip.lines[1]:find(reason, 1, true) ~= nil)
        H.True(state.api.GameTooltip.lines[1]:find(ui:F("inViewCount", 1), 1, true) ~= nil)

        status.alwaysNameplates = nil
        block = nil
        ui:Refresh()
        H.False(ui.supportStatus:GetText():find(hint, 1, true) ~= nil)
        H.False(ui.supportStatus:GetText():find(reason, 1, true) ~= nil)
        H.Equal(ui.statusText:GetText(), ui:T("limited") .. " · " .. ui:F("inViewCount", 1))
        status.nameplates, status.alwaysNameplates = false, false
        ui:Refresh()
        H.True(ui.supportStatus:GetText():find(ui:T("nameplatesOff"), 1, true) ~= nil)
        H.False(ui.supportStatus:GetText():find(hint, 1, true) ~= nil)
    end
end)

H.Test("quick class chips update only display filtering and preserve audible selection", function()
    local _, _, app, ui = setup()
    local before = app.db:GetProfile().alerts.classes
    for _, chip in ipairs(ui.quickChips) do if chip.class == "ROGUE" then chip.frame:Click() end end
    H.False(app.db:GetProfile().display.classes.ROGUE)
    H.Equal(app.db:GetProfile().alerts.classes, before)
    H.True(app.changes > 0)
end)

H.Test("range controls disable with the filter and restore the saved distance policy", function()
    local _, _, app, ui = setup()
    ui:OpenSettings("alerts")
    local controls = {}
    for _, control in ipairs(ui.controls) do
        if control.path then controls[control.path] = control.frame end
    end
    local enabled, yards = assert(controls["range.enabled"]), assert(controls["range.yards"])
    local policy, unknown = assert(controls["range.policy"]), assert(controls["range.unknown"])
    local range = app.db:GetProfile().range
    H.True(enabled.enabled)
    H.False(enabled:GetChecked())
    H.False(yards.enabled)
    H.False(policy.enabled)
    H.False(unknown.enabled)

    enabled:Click()
    H.True(range.enabled)
    H.True(yards.enabled)
    H.True(policy.enabled)
    H.True(unknown.enabled)
    yards:SetValue(65)
    policy:Click()
    unknown:Click()
    H.Equal(range.yards, 65)
    H.Equal(range.policy, "confirmed")
    H.False(range.unknown)

    enabled:Click()
    H.False(range.enabled)
    H.False(yards.enabled)
    H.False(policy.enabled)
    H.False(unknown.enabled)
    policy:Click()
    unknown:Click()
    H.Equal(range.yards, 65)
    H.Equal(range.policy, "confirmed")
    H.False(range.unknown)

    enabled:Click()
    H.True(yards.enabled)
    H.True(policy.enabled)
    H.True(unknown.enabled)
    H.Equal(yards:GetValue(), 65)
    H.Equal(policy.label:GetText(), ui:T("confirmed") .. "  ›")
    H.False(unknown:GetChecked())
end)

H.Test("settings clear known classes independently and let any two classes alert", function()
    local _, RG, app, ui = setup()
    local profile = app.db:GetProfile()
    local function clickButton(page, key)
        for _, child in ipairs(page.children) do
            if child.label and child.label:GetText() == ui:T(key) then child:Click(); return end
        end
        error("missing button " .. key)
    end
    local function toggleAlertClass(class)
        for _, control in ipairs(ui.controls) do
            for _, chip in ipairs(control.chips or {}) do
                if chip.group == "alerts" and chip.class == class then chip.frame:Click(); return end
            end
        end
        error("missing alert class " .. class)
    end
    local function evaluate(class, listEntry)
        return RG.Rules.Evaluate(profile, { hostile = true, isPlayer = true, class = class }, "sighting", { kind = "world" }, listEntry)
    end

    ui:OpenSettings("overview")
    clickButton(ui.pages.overview, "clearClassSelection")
    H.False(RG.Rules.Display(profile, { class = "ROGUE" }))
    H.True(RG.Rules.Display(profile, {}))
    H.True(evaluate("ROGUE").sound)
    ui:OpenSettings("alerts")
    clickButton(ui.pages.alerts, "clearClassSelection")
    H.Nil(evaluate("ROGUE"))
    H.True(evaluate(nil).banner)
    H.False(evaluate(nil).sound)
    H.Equal(evaluate("ROGUE", { kind = "watch" }).kind, "watch")
    toggleAlertClass("HUNTER")
    toggleAlertClass("MAGE")
    H.True(evaluate("HUNTER").sound)
    H.True(evaluate("MAGE").sound)
    H.Nil(evaluate("ROGUE"))
    toggleAlertClass("HUNTER")
    toggleAlertClass("MAGE")
    H.Nil(evaluate("MAGE"))
    local imported = assert(app.db:ImportProfile("Cleared classes", assert(app.db:ExportProfile())))
    for _, class in ipairs(RG.Defaults.classes) do
        H.False(imported.display.classes[class])
        H.False(imported.alerts.classes[class])
    end
    clickButton(ui.pages.alerts, "all")
    H.True(evaluate("ROGUE").sound)
    H.False(RG.Rules.Display(profile, { class = "ROGUE" }))
    H.True(profile.alerts.unknownClass)
end)

H.Test("UI row recycling clears absent contacts and keeps Unicode names", function()
    local _, _, app, ui = setup()
    app.engine:Observe({ token = "nameplate1", guid = "A", name = "Разбойник", class = "ROGUE", hostile = true, isPlayer = true, source = "nameplate" })
    ui:Refresh()
    H.True(ui.rows[1]:IsShown()); H.Equal(ui.rows[1].nameText:GetText(), "Разбойник")
    app.engine:Clear(); ui:Refresh()
    H.False(ui.rows[1]:IsShown()); H.Nil(ui.rows[1].contact)
end)

H.Test("Nearby layout cache follows viewport and font changes across hidden rows", function()
    local state, _, app, ui = setup()
    local display = app.db:GetProfile().display
    display.scale = 1.5
    app.engine:Observe({ token = "nameplate1", guid = "First", name = "First rival", class = "ROGUE", hostile = true, isPlayer = true })
    ui:Refresh()
    local row = ui.rows[1]
    H.Equal(ui.frame:GetScale(), 1.5)
    H.Equal(row.nameText.font[2], 13)

    display.showList, display.textSize = false, 18
    app.engine:Clear()
    ui:Refresh()
    H.False(row:IsShown())
    H.Nil(row.contact)
    state.api.UIParent:SetSize(480, 360)
    display.showList = true
    app.engine:Observe({ token = "nameplate1", guid = "Second", name = "Новый противник", class = "HUNTER", hostile = true, isPlayer = true })
    ui:Refresh()
    H.True(ui.frame:GetScale() < 1.5)
    H.True(row:IsShown())
    H.Equal(row.contact.identity, "guid:Second")
    H.Equal(row.nameText:GetText(), "Новый противник")
    H.Equal(row.nameText.font[2], 18)
    H.Equal(row.detailText.font[2], 16)
    H.Equal(row:GetHeight(), 18 + 20)
end)

H.Test("automatic Nearby anchor keeps tall rows on a compact scaled viewport and restores the wide placement", function()
    local uiScale, physicalWidth, physicalHeight = 1.35, 640, 480
    local state, _, app, ui = setup(nil, function(mock)
        mock.api.UIParent:SetScale(uiScale)
        mock.api.UIParent:SetSize(physicalWidth / uiScale, physicalHeight / uiScale)
    end)
    local parent, frame = state.api.UIParent, ui.frame
    local display = app.db:GetProfile().display
    display.scale = 1.5
    for index = 1, 20 do
        app.engine:Observe({ token = "nameplate" .. index, guid = "Player-Layout-" .. index,
            name = "Layout " .. index, class = "ROGUE", hostile = true, isPlayer = true })
    end

    local function checkBounds(visibleRows)
        local point, relative, anchor, x, y = frame:GetPoint(1)
        H.Equal(point, "RIGHT"); H.Equal(relative, parent); H.Equal(anchor, "RIGHT")
        H.True(frame.clamped)
        H.Nil(frame:GetPoint(2))
        H.True(ui.rows[visibleRows]:IsShown())
        if ui.rows[visibleRows + 1] then H.False(ui.rows[visibleRows + 1]:IsShown()) end
        local scale = frame:GetEffectiveScale() / parent:GetEffectiveScale()
        local right = parent:GetWidth() + x * scale
        local center = parent:GetHeight() / 2 + y * scale
        local halfHeight = frame:GetHeight() * scale / 2
        H.True(right <= parent:GetWidth(), "Nearby right edge exceeds the viewport")
        H.True(right - frame:GetWidth() * scale >= 0, "Nearby left edge exceeds the viewport")
        H.True(center + halfHeight <= parent:GetHeight(), "Nearby top edge exceeds the viewport")
        H.True(center - halfHeight >= 0, "Nearby bottom edge exceeds the viewport")
        return x, y
    end

    local setPoint, anchorWrites = frame.SetPoint, 0
    frame.SetPoint = function(self, ...)
        anchorWrites = anchorWrites + 1
        return setPoint(self, ...)
    end
    for _, rowCount in ipairs({ 8, 20 }) do
        display.maxRows = rowCount
        ui:Refresh()
        checkBounds(rowCount)
        local stable = anchorWrites
        ui:Refresh()
        H.Equal(anchorWrites, stable)

        parent:SetSize(2560 / uiScale, 1920 / uiScale)
        ui:Refresh()
        local wideX, wideY = checkBounds(rowCount)
        H.Equal(wideX, -70); H.Equal(wideY, 20)

        parent:SetSize(physicalWidth / uiScale, physicalHeight / uiScale)
        ui:Refresh()
        checkBounds(rowCount)
    end
end)

H.Test("a locked Nearby drag cannot save an automatic anchor", function()
    local _, _, app, ui = setup()
    local profile = app.db:GetProfile()
    H.True(profile.display.locked)
    local header = nearbyDragHeader(ui)
    header.scripts.OnDragStart(header)
    header.scripts.OnDragStop(header)
    H.Nil(profile.positions.nearby)
end)

H.Test("logout does not turn automatic Nearby placement into a saved anchor", function()
    local state, _, app, ui = setup()
    local profile = app.db:GetProfile()
    H.Nil(profile.positions.nearby)
    state.api.UIParent:SetSize(480, 360)
    ui:Refresh()
    state:Fire("PLAYER_LOGOUT")
    H.Nil(profile.positions.nearby)
end)

H.Test("legacy stock Nearby position adapts on load while logout preserves the stored tuple", function()
    local _, _, original = setup()
    original.db:GetProfile().positions.nearby = { point = "RIGHT", relativePoint = "RIGHT", x = -70, y = 20 }
    original.db:GetProfile().display.scale = 1.5
    local state, _, app, ui = setup(original.db.root, function(mock)
        mock.api.UIParent:SetSize(640 / 1.35, 480 / 1.35)
        mock.api.UIParent:SetScale(1.35)
    end)
    local _, _, _, x = ui.frame:GetPoint(1)
    H.True(x > -70, "legacy stock offset still clips the compact horizontal placement")
    state:Fire("PLAYER_LOGOUT")
    local saved = app.db:GetProfile().positions.nearby
    H.Equal(saved.point, "RIGHT"); H.Equal(saved.relativePoint, "RIGHT")
    H.Equal(saved.x, -70); H.Equal(saved.y, 20)
end)

H.Test("Why describes a new sighting and clears configured outputs on rejection", function()
    local _, RG, app, ui = setup()
    ui.selected = { id = "sample" }
    local result = { allowed = true, reason = "watch_list", sound = false, banner = true, rangeEvidence = "combined" }
    function app:Explain(contact)
        H.Equal(contact.id, "sample")
        return result
    end
    local locale = app.db:GetProfile().locale
    ui:ShowExplanation()
    local frame = ui.explanationFrame
    local scopeFound = false
    for _, child in ipairs(frame.children) do
        if child:GetText() == ui:T("explanationSighting") then scopeFound = true end
    end
    H.True(scopeFound)
    H.Equal(frame.reason:GetText(), RG.Locale.Reason("watch_list", locale))
    H.Equal(frame.outputs:GetText(), ui:T("explanationBannerOnly"))
    H.Equal(frame.rangeEvidence:GetText(), ui:T("rangeEvidenceCombined"))
    result.sound = true
    ui:ShowExplanation()
    H.Equal(frame.outputs:GetText(), ui:T("explanationSoundBanner"))
    result.banner = false
    ui:ShowExplanation()
    H.Equal(frame.outputs:GetText(), ui:T("explanationSoundOnly"))

    for _, reason in ipairs({ "not_observed", "range_outside", "range_unconfirmed", "wave_only", "range_conflict" }) do
        result = { allowed = false, reason = reason, rangeEvidence = reason == "range_conflict" and "conflict" or nil }
        ui:ShowExplanation()
        H.Equal(frame.reason:GetText(), RG.Locale.Reason(reason, locale))
        H.True(frame.reason:GetText() ~= RG.Locale.Reason("unavailable", "enUS"))
        H.True(RG.Locale.Reason(reason, "ruRU") ~= RG.Locale.Reason("unavailable", "ruRU"))
        H.Equal(frame.outputs:GetText(), "")
        H.Equal(frame.rangeEvidence:GetText(), "")
    end
end)

H.Test("Details retains targeting and range provenance only for a live sighting", function()
    for _, locale in ipairs({ "enUS", "ruRU" }) do
        local _, _, app, ui = setup()
        app.db:GetProfile().locale = locale
        local selected = { id = "sample", name = "Example", visible = true, rangeMin = 10, rangeMax = 20,
            rangeEvidence = "spell", targeting = true, hostile = true, isPlayer = true, lastSeen = ui:Now() }
        ui:Select(selected)
        local info = ui.detailsFrame.info:GetText()
        H.True(info:find(ui:T("targeting"), 1, true) ~= nil)
        H.True(info:find(ui:F("rangeBracket", 10, 20) .. " · " .. ui:T("rangeEvidenceSpell"), 1, true) ~= nil)
        ui.selectedOutside = true
        ui:ShowDetails(true)
        H.False(ui.detailsFrame.info:GetText():find(ui:T("rangeEvidenceSpell"), 1, true) ~= nil)
        selected.targeting, selected.rangeEvidence = false, "conflict"
        ui:Select(selected)
        H.True(ui.detailsFrame.info:GetText():find(ui:T("rangeEvidenceConflict"), 1, true) ~= nil)
        H.False(ui.detailsFrame.info:GetText():find(ui:F("rangeBracket", 10, 20), 1, true) ~= nil)
    end
end)

H.Test("profile counts above visible rows remain scrollable without changing actual contacts", function()
    local _, _, app, ui = setup()
    app.db:GetProfile().display.maxRows = 3
    for index = 1, 9 do app.engine:Observe({ token = "nameplate" .. index, guid = tostring(index), name = "Enemy " .. index, class = "ROGUE", hostile = true, isPlayer = true, source = "nameplate" }) end
    ui:Refresh()
    local first = ui.rows[1].contact.id
    ui.frame.scripts.OnMouseWheel(ui.frame, -1)
    H.True(ui.rows[1].contact.id ~= first)
    H.Equal(#app.engine:Snapshot(), 9)
    H.False(ui.rows[4]:IsShown())
end)

H.Test("preview is isolated from live contacts journal and watchlists", function()
    local state, _, app, ui = setup()
    local profile = app.db:GetProfile()
    local enabled = profile.alerts.banner
    ui:PreviewAlert()
    H.Equal(profile.alerts.banner, enabled)
    H.True(ui.banner:IsShown()); H.True(ui.bannerPreview)
    H.Equal(#app.engine:Snapshot(), 0); H.Equal(#app.db:GetJournal(), 0)
    H.Equal(next(app.db:GetList()), nil)
    state:Advance(20)
    H.False(ui.banner:IsShown())
    H.Equal(#app.engine:Snapshot(), 0)
end)

H.Test("sample Why stays separate from live details and expires with the preview", function()
    local state, RG, app, ui = setup()
    local profile = app.db:GetProfile()
    profile.display.classes = { MAGE = true }
    profile.display.showUnknown = false
    local live = app.engine:Observe({ token = "target", guid = "Player-Live", name = "Live Enemy", class = "MAGE", hostile = true, isPlayer = true, source = "target" })
    ui:Select(live)
    local details = ui.detailsFrame
    local liveHeight = details:GetHeight()
    function app:Explain(contact)
        if not contact.preview then return { allowed = true, reason = "event_matched", banner = true } end
        return profile.alerts.banner and { preview = true, allowed = true, reason = "watch_list", banner = true }
            or { preview = true, allowed = false, reason = "outputs_disabled" }
    end
    ui:ShowExplanation()
    local sample = { id = "sample", name = "Sample Hunter", class = "HUNTER", visible = true, watched = true,
        hostile = true, isPlayer = true, targeting = true, rangeMin = 20, rangeMax = 30 }
    ui:OpenSettings("support")
    H.True(ui.settings:IsShown())
    H.Equal(ui:Preview({ sample }), ui:Now() + 15)
    H.False(ui.settings:IsShown())
    H.False(ui.selectedOutside)
    H.Equal(ui.selected.id, live.id)
    H.True(ui.explanationFrame:IsShown())
    H.Equal(ui.rows[1].contact.id, sample.id)
    H.Nil(sample.preview)
    ui.rows[1]:Click()
    H.False(ui.explanationFrame:IsShown())
    H.True(ui.detailsFrame.info:GetText():find(ui:T("demoWatched"), 1, true) ~= nil)
    H.True(ui.detailsFrame.info:GetText():find(ui:T("targeting"), 1, true) ~= nil)
    H.True(ui.detailsFrame.info:GetText():find(ui:F("demoRange", ui:F("rangeBracket", 20, 30)), 1, true) ~= nil)
    H.Equal(ui.detailsFrame.notice:GetText(), ui:T("demoWhy"))
    H.False(details.listActions.watch:IsShown())
    H.False(details.note:IsShown())
    H.True(details:GetHeight() < liveHeight)
    ui:ShowExplanation()
    H.Equal(ui.explanationFrame.event:GetText(), ui:T("demoSighting"))
    H.Equal(ui.explanationFrame.outputs:GetText(), ui:T("explanationBannerOnly"))
    profile.alerts.banner = false
    ui:SettingsChanged()
    H.Equal(ui.explanationFrame.reason:GetText(), RG.Locale.Reason("outputs_disabled", profile.locale))
    H.Equal(ui.explanationFrame.outputs:GetText(), "")
    state:Advance(16)
    ui:Refresh()
    H.False(ui.detailsFrame:IsShown()); H.False(ui.explanationFrame:IsShown())
    H.Nil(ui.selected)
    ui:Select(live)
    H.True(details.listActions.watch:IsShown())
    H.True(details.note:IsShown())
    H.Equal(details:GetHeight(), liveHeight)
    H.Equal(#app.db:GetJournal(), 0)
    H.Nil(next(app.db:GetList()))
end)

H.Test("normal alerts honor per-decision banner suppression", function()
    local _, _, _, ui = setup()
    ui:Alert({ kind = "sighting", banner = false, sound = true, contact = { name = "Enemy", class = "ROGUE" } })
    H.False(ui.banner:IsShown())
end)

H.Test("diagnostic copy window only exposes the generated bounded report", function()
    local _, _, _, ui = setup()
    ui:ShowDiagnostics()
    H.True(ui.copyFrame:IsShown())
    H.True(ui.copyFrame.edit:GetText():find("fixture report", 1, true) ~= nil)
    H.True(ui.copyFrame.edit.highlighted)
    H.Equal(ui.copyFrame.strata, "DIALOG")
end)

H.Test("diagnostic copy fits a compact viewport on open and resize without resetting the report", function()
    local state, _, app, ui = setup(nil, compactViewport)
    local reports = 0
    function app:ExportDiagnostics()
        reports = reports + 1
        return "RivalGuard\ncontext=world\nalerts=ready"
    end
    ui:OpenSettings("support")
    ui:ShowDiagnostics()
    local copy = ui.copyFrame
    local report = copy.edit:GetText()
    H.Equal(copy:GetWidth(), 660); H.Equal(copy:GetHeight(), 490)
    fitCenteredDialog(state, copy)
    H.True(copy:GetScale() < 1)
    H.True(copy.edit.highlighted); H.True(copy.edit:HasFocus())
    resizeViewport(state, 1920, 1080)
    state:Advance(1.1)
    fitCenteredDialog(state, copy)
    H.Equal(copy:GetScale(), 1)
    H.Equal(copy.edit:GetText(), report); H.True(copy.edit:HasFocus())
    H.Equal(reports, 1)
    copy.edit.scripts.OnEscapePressed(copy.edit)
    H.False(copy:IsShown()); H.False(copy.edit:HasFocus())
    resizeViewport(state, 640, 480)
    ui:ShowDiagnostics()
    H.Equal(ui.copyFrame, copy)
    fitCenteredDialog(state, copy)
    H.Equal(copy.edit:GetText(), report); H.True(copy.edit:HasFocus())
    H.Equal(reports, 2)
end)

H.Test("live contact details fit a narrow resize and keep the selected contact and focused note", function()
    local state, _, app, ui = setup(nil, compactViewport)
    local contact = app.engine:Observe({ token = "target", guid = "Player-DetailsFit", name = "Rival",
        class = "ROGUE", hostile = true, isPlayer = true, source = "target" })
    ui:Select(contact)
    local detail = ui.detailsFrame
    H.Equal(detail:GetWidth(), 470); H.Equal(detail:GetHeight(), 555)
    fitCenteredDialog(state, detail)
    detail.note:SetFocus()
    detail.note:SetText("Uncommitted draft")
    detail.note.scripts.OnTextChanged(detail.note, true)
    resizeViewport(state, 480, 640)
    state:Advance(1.1)
    local narrowX = fitCenteredDialog(state, detail)
    H.True(narrowX < 80)
    H.Equal(ui.selected.identity, contact.identity)
    H.Equal(detail.note:GetText(), "Uncommitted draft"); H.True(detail.note:HasFocus())
    resizeViewport(state, 1920, 1080)
    ui:Refresh()
    local wideX, wideY = fitCenteredDialog(state, detail)
    H.Equal(wideX, 80); H.Equal(wideY, 0)
    H.Equal(detail.note:GetText(), "Uncommitted draft"); H.True(detail.note:HasFocus())
    H.Nil(app.db:GetList()[contact.identity])
end)

H.Test("short sample details keep their horizontal offset inside a compact viewport", function()
    local state, _, _, ui = setup(nil, compactViewport)
    ui:Preview({ { id = "sample", name = "Sample Hunter", class = "HUNTER", visible = true, hostile = true, isPlayer = true } })
    ui.rows[1]:Click()
    local detail = ui.detailsFrame
    H.Equal(detail:GetHeight(), 245)
    local compactX = fitCenteredDialog(state, detail)
    H.True(compactX < 80)
    H.False(detail.note:IsShown())
    resizeViewport(state, 1920, 1080)
    ui:Refresh()
    local wideX, wideY = fitCenteredDialog(state, detail)
    H.Equal(wideX, 80); H.Equal(wideY, 0)
    H.Equal(ui.selected.id, "sample")
end)

for _, hasSound in ipairs({ false, true }) do
    H.Test("explanation fits on compact screens " .. (hasSound and "with" or "without") .. " last sound", function()
        local state, _, app, ui = setup(nil, compactViewport)
        local contact = app.engine:Observe({ token = "target", guid = "Player-ExplanationFit", name = "Rival",
            class = "HUNTER", hostile = true, isPlayer = true, source = "target" })
        function app:Explain()
            return { allowed = true, reason = "event_matched", banner = true,
                lastSound = hasSound and { kind = "sighting", status = "playback_requested" } or nil }
        end
        ui:Select(contact)
        ui.detailsFrame.why:Click()
        local why = ui.explanationFrame
        H.Equal(why:GetHeight(), hasSound and 370 or 290)
        H.Equal(why.lastSound:IsShown(), hasSound)
        local reason = why.reason:GetText()
        local _, compactY = fitCenteredDialog(state, why)
        H.True(compactY < 80)
        resizeViewport(state, 1920, 1080)
        ui:Refresh()
        local wideX, wideY = fitCenteredDialog(state, why)
        H.Equal(wideX, 0); H.Equal(wideY, 80)
        H.Equal(ui.selected.identity, contact.identity)
        H.Equal(why.reason:GetText(), reason)
    end)
end

for _, dialog in ipairs({
    { "guideDialog", function(ui) return ui:ShowGuide(true) end, function(frame) return frame.stepText end },
    { "rulesDialog", function(ui) ui:OpenRules() end, function(frame) return frame.nameInput end },
    { "transferDialog", function(ui) ui:OpenTransfer("export") end, function(frame) return frame.edit end },
}) do
    H.Test(dialog[1] .. " fits after resizing while visible and after reopening", function()
        local state, _, _, ui = setup()
        dialog[2](ui)
        local frame = ui[dialog[1]]
        local textWidget = dialog[3](frame)
        local text = textWidget:GetText()
        H.Equal(frame:GetScale(), 1)
        compactViewport(state)
        ui:Refresh()
        fitCenteredDialog(state, frame)
        H.Equal(textWidget:GetText(), text)
        frame:Hide()
        resizeViewport(state, 1920, 1080)
        dialog[2](ui)
        H.Equal(ui[dialog[1]], frame)
        fitCenteredDialog(state, frame)
        H.Equal(frame:GetScale(), 1)
        H.Equal(textWidget:GetText(), text)
    end)
end

H.Test("UI teardown detaches ticker while hidden main window does not stop refreshes", function()
    local state, _, app, ui = setup()
    app.db:GetProfile().display.showList = false
    ui:Refresh(); H.False(ui.frame:IsShown())
    app.db:GetProfile().display.showList = true
    state:Advance(1.1)
    H.True(ui.frame:IsShown())
    ui:Destroy()
    H.False(ui.frame:IsShown()); H.Nil(ui.ticker:GetScript("OnUpdate"))
    H.Nil(next(ui.ticker.events))
end)

H.Test("drag saved mixed anchors survive strict export database reload and UI restore", function()
    local state, _, app, ui = setup()
    app.db:GetProfile().display.locked = false
    local dragHeader = nearbyDragHeader(ui)
    dragHeader.scripts.OnDragStart(dragHeader)
    ui.frame:ClearAllPoints()
    ui.frame:SetPoint("TOPLEFT", state.api.UIParent, "BOTTOMRIGHT", 123, -87)
    ui.frame:SetPoint("TOPRIGHT", state.api.UIParent, "BOTTOMRIGHT", 471, -87)
    dragHeader.scripts.OnDragStop(dragHeader)
    local saved = app.db:GetProfile().positions.nearby
    H.Equal(saved.point, "TOPLEFT"); H.Equal(saved.relativePoint, "BOTTOMRIGHT")
    H.Equal(saved.x, 123); H.Equal(saved.y, -87)
    H.Equal(type(app.db:ExportProfile()), "string", "dragged profile must remain valid for strict export")
    local fresh, _, restored, restoredUI = setup(app.db.root)
    local point, parent, relativePoint, x, y = restoredUI.frame:GetPoint(1)
    H.Equal(point, "TOPLEFT"); H.Equal(parent, fresh.api.UIParent)
    H.Equal(relativePoint, "BOTTOMRIGHT"); H.Equal(x, 123); H.Equal(y, -87)
    H.Equal(restored.db:GetProfile().positions.nearby.relativePoint, "BOTTOMRIGHT")
    fresh.api.UIParent:SetSize(640 / 1.35, 480 / 1.35)
    restoredUI:Refresh()
    point, parent, relativePoint, x, y = restoredUI.frame:GetPoint(1)
    H.Equal(point, "TOPLEFT"); H.Equal(parent, fresh.api.UIParent)
    H.Equal(relativePoint, "BOTTOMRIGHT"); H.Equal(x, 123); H.Equal(y, -87)
end)

H.Test("logout with nil GetPoint preserves prior valid saved position", function()
    local state, _, app, ui = setup()
    app.db:GetProfile().display.locked = false
    local header = nearbyDragHeader(ui)
    header.scripts.OnDragStart(header)
    ui.frame:ClearAllPoints(); ui.frame:SetPoint("BOTTOM", state.api.UIParent, "TOP", 15, 30)
    header.scripts.OnDragStop(header)
    local saved = app.db:GetProfile().positions.nearby
    H.Equal(saved.point, "BOTTOM"); H.Equal(saved.relativePoint, "TOP")
    header.scripts.OnDragStart(header)
    ui.frame:ClearAllPoints()
    state:Fire("PLAYER_LOGOUT")
    H.Equal(app.db:GetProfile().positions.nearby, saved)
    H.Equal(saved.x, 15); H.Equal(saved.y, 30)
end)

H.Test("logout saves the current position when the Nearby window is being deliberately dragged", function()
    local state, _, app, ui = setup()
    local profile = app.db:GetProfile()
    profile.display.locked = false
    local header = nearbyDragHeader(ui)
    header.scripts.OnDragStart(header)
    ui.frame:ClearAllPoints()
    ui.frame:SetPoint("LEFT", state.api.UIParent, "LEFT", 47, -38)
    H.Nil(profile.positions.nearby)
    state:Fire("PLAYER_LOGOUT")
    local saved = profile.positions.nearby
    H.Equal(saved.point, "LEFT"); H.Equal(saved.relativePoint, "LEFT")
    H.Equal(saved.x, 47); H.Equal(saved.y, -38)
end)

H.Test("advanced rule editor uses detached drafts and applies valid rules on save", function()
    local _, RG, app, ui = setup()
    ui:OpenRules()
    local dialog = assert(ui.rulesDialog)
    H.True(dialog:IsShown())
    dialog.nameInput:SetText("No ordinary alert")
    dialog.action:Click()
    dialog.priority:SetValue(85)
    H.Equal(#app.db:GetProfile().rules, 0)
    dialog.save:Click()
    H.Equal(#app.db:GetProfile().rules, 1)
    local rule = app.db:GetProfile().rules[1]
    H.Equal(rule.name, "No ordinary alert"); H.Equal(rule.action, "suppress"); H.Equal(rule.priority, 85)
    local decision, reason = RG.Rules.Evaluate(app.db:GetProfile(), { id = "A", hostile = true, isPlayer = true, class = "ROGUE" }, "sighting", { kind = "world" })
    H.Nil(decision); H.Equal(reason, "custom_suppressed")
    dialog.nameInput:SetText("|invalid")
    dialog.save:Click()
    H.Equal(app.db:GetProfile().rules[1], rule)
    dialog.delete:Click()
    H.Equal(#app.db:GetProfile().rules, 0)
end)

H.Test("clear selection in a rule supports arbitrary subsets and profile transfer", function()
    local _, RG, app, ui = setup()
    ui:OpenRules()
    local dialog = ui.rulesDialog
    local profile = app.db:GetProfile()
    dialog.nameInput:SetText("Selected class rule")
    dialog.clearClasses:Click()
    H.Equal(#profile.rules, 0)
    dialog.save:Click()
    local savedClasses = profile.rules[1].classes
    local imported = assert(app.db:ImportProfile("Cleared selection", assert(app.db:ExportProfile())))
    for _, class in ipairs(RG.Defaults.classes) do
        H.False(savedClasses[class])
        H.False(imported.rules[1].classes[class])
    end

    local function applies(class)
        local decision = RG.Rules.Evaluate(profile, { hostile = true, isPlayer = true, class = class }, "sighting", { kind = "world" })
        return decision and decision.ruleName
    end
    H.Nil(applies("ROGUE"))
    H.Nil(applies(nil))
    dialog.knownClassOnly:Click()
    dialog.save:Click()
    H.Equal(applies(nil), "Selected class rule")
    for _, chip in ipairs(dialog.classes) do
        if chip.class == "HUNTER" or chip.class == "MAGE" then chip.frame:Click() end
    end
    H.False(savedClasses.HUNTER)
    H.False(savedClasses.MAGE)
    dialog.save:Click()
    H.Equal(applies("HUNTER"), "Selected class rule")
    H.Equal(applies("MAGE"), "Selected class rule")
    H.Nil(applies("ROGUE"))
    dialog.allClasses:Click()
    dialog.save:Click()
    H.Nil(next(profile.rules[1].classes))
    H.Equal(applies("ROGUE"), "Selected class rule")
end)

H.Test("stale rule draft cannot overwrite a switched profile", function()
    local _, _, app, ui = setup()
    ui:OpenRules()
    local dialog = ui.rulesDialog
    dialog.nameInput:SetText("Stale draft")
    assert(app.db:CreateProfile("Other")); assert(app.db:SetProfile("Other"))
    dialog.save:Click()
    H.Equal(#app.db:GetProfile().rules, 0)
    H.Equal(#app.db.root.profiles.Default.rules, 0)
end)

H.Test("profile import requires preview and changed text invalidates authorization", function()
    local _, _, app, ui = setup()
    app.db:GetProfile().alerts.cooldown = 77
    local encoded = assert(app.db:ExportProfile())
    ui:OpenTransfer("import")
    local dialog = assert(ui.transferDialog)
    dialog.nameInput:SetText("Imported")
    dialog.edit:SetText(encoded)
    H.False(dialog.apply.enabled)
    dialog.apply:Click(); H.Nil(app.db.root.profiles.Imported)
    dialog.preview:Click(); H.True(dialog.apply.enabled)
    dialog.edit:SetText(encoded .. "bad")
    H.False(dialog.apply.enabled)
    dialog.preview:Click(); H.False(dialog.apply.enabled)
    dialog.edit:SetText(encoded); dialog.preview:Click(); dialog.apply:Click()
    H.Equal(app.db.root.profiles.Imported.alerts.cooldown, 77)
    H.Equal(app.db:GetActiveProfileName(), "Default")
    H.False(dialog:IsShown())
end)

H.Test("profile export and import cannot replace active or existing settings", function()
    local _, _, app, ui = setup()
    local active = app.db:GetProfile()
    ui:OpenTransfer("export")
    local dialog = ui.transferDialog
    local exported = dialog.edit:GetText()
    H.True(exported:match("^RG1:") ~= nil)
    H.True(dialog.edit.highlighted)
    H.False(dialog.apply:IsShown())
    ui:OpenTransfer("import")
    dialog.nameInput:SetText("Default"); dialog.edit:SetText(exported)
    dialog.preview:Click(); dialog.apply:Click()
    H.Equal(app.db:GetProfile(), active)
    H.Equal(#app.db:ListProfiles(), 1)
    H.True(dialog:IsShown())
end)

H.Test("profile setup describes the selected preset and creation keeps the active profile", function()
    local state, _, app, ui = setup()
    ui:OpenSettings("profiles")
    H.False(ui.profilePrev:IsShown()); H.False(ui.profileNext:IsShown())
    H.Equal(ui.presetDescription:GetText(), ui:T("balancedTip"))
    for _, preset in ipairs({ "farming", "quiet", "battleground" }) do
        ui.presetChoices[preset]:Click()
        H.Equal(ui.presetDescription:GetText(), ui:T(preset .. "Tip"))
    end
    ui.profileInput:SetText("Matches")
    ui.createProfile:Click()
    H.Equal(app.db:GetActiveProfileName(), "Default")
    H.Equal(state.messages[#state.messages], ui:F("profileCreated", "Matches"))
    H.Equal(ui.profileRows[2].profileName, "Matches")
    ui.profileRows[2].use:Click()
    local profile = app.db:GetProfile()
    H.Equal(app.db:GetActiveProfileName(), "Matches")
    H.False(profile.context.world); H.True(profile.context.battleground)
    H.True(profile.alerts.muteOrdinary); H.False(profile.alerts.targeting)
end)

H.Test("profile and journal pagination retain entries beyond first page", function()
    local state, _, app, ui = setup()
    for index = 1, 12 do assert(app.db:CreateProfile(string.format("Profile %02d", index))) end
    ui.scroll:SetHeight(430)
    ui:OpenSettings("profiles")
    H.True(ui.profileNext.enabled)
    local fullPageHeight = ui.pageHeight
    ui.scrollbar:SetValue(fullPageHeight - ui.scroll:GetHeight())
    ui.profileNext:Click()
    H.Equal(ui.profileRows[1].profileName, "Profile 10")
    H.True(ui.pageHeight < fullPageHeight)
    H.Equal(ui.scrollbar:GetValue(), ui.pageHeight - ui.scroll:GetHeight())
    H.True(ui.profilePrev:IsShown()); H.True(ui.profilePrev.enabled)
    H.True(ui.profileNext:IsShown()); H.False(ui.profileNext.enabled)
    ui.profileRows[1].use:Click()
    H.Equal(app.db:GetActiveProfileName(), "Profile 10")
    for index = 1, 15 do app.db:Record({ identity = "guid:" .. index, name = "Enemy " .. index, class = "HUNTER" }, state.api.time() - index, "Fixture Zone") end
    ui:OpenSettings("journal")
    H.True(ui.journalNext.enabled)
    ui.journalNext:Click()
    H.Equal(ui.journalRows[1].contact.name, "Enemy 13")
    H.False(ui.journalNext.enabled)
end)

H.Test("a delete confirmation cannot apply to a replacement with the old profile name", function()
    local _, _, app, ui = setup()
    local renamed = assert(app.db:CreateProfile("Patrol"))
    ui:OpenSettings("profiles")
    ui.profileRows[2].delete:Click()
    assert(app.db:RenameProfile("Patrol", "Later"))
    local replacement = assert(app.db:CreateProfile("Patrol"))
    ui:RefreshProfiles()
    H.Equal(ui.profileRows[3].profileName, "Patrol")
    ui.profileRows[3].delete:Click()
    H.Equal(app.db:GetProfile("Patrol"), replacement)
    ui.profileRows[3].delete:Click()
    H.Nil(app.db:GetProfile("Patrol"))
    H.Equal(app.db:GetProfile("Later"), renamed)
end)

H.Test("live banner priority resists waves and previews while stronger danger preempts", function()
    local _, _, _, ui = setup()
    local function alert(kind, priority, name)
        ui:Alert({ kind = kind, priority = priority, banner = true, contact = { id = kind, name = name, class = "ROGUE" } })
    end
    alert("watch", 90, "Watched player")
    alert("wave", 35, "Group arrival")
    H.Equal(ui.banner.body:GetText(), "Watched player")
    ui:PreviewAlert()
    H.Equal(ui.banner.body:GetText(), "Watched player")
    H.False(ui.bannerPreview)
    alert("stealth", 100, "Confirmed stealth")
    H.Equal(ui.banner.body:GetText(), "Confirmed stealth")
    H.Equal(ui.activeBanner.kind, "stealth")
end)

H.Test("default banner adapts to viewport width while an intentional drag preserves its anchor", function()
    local state, _, app, ui = setup()
    local banner, positions = ui.banner, app.db:GetProfile().positions
    local _, _, _, wide = banner:GetPoint(1)
    state.api.UIParent:SetSize(1024, 576)
    ui:Refresh()
    local _, _, _, compact = banner:GetPoint(1)
    H.True(compact < wide)
    H.Nil(positions.alert)

    local function move(x)
        banner.scripts.OnDragStart(banner)
        H.True(banner.moving)
        banner:ClearAllPoints()
        banner:SetPoint("TOP", state.api.UIParent, "TOP", x, -120)
    end
    ui:PreviewAlert()
    move(50)
    ui:Alert({ kind = "watch", priority = 90, banner = true, contact = { id = "first", name = "Rival" } })
    H.False(banner.moving)
    local _, _, _, restored = banner:GetPoint(1)
    H.Equal(restored, compact)
    banner.scripts.OnDragStop(banner)
    H.Nil(positions.alert)

    ui:ClearBanners()
    ui:PreviewAlert()
    move(72)
    banner.scripts.OnDragStop(banner)
    H.Equal(positions.alert.x, 72)
    state.api.UIParent:SetSize(1920, 1080)
    ui:Refresh()
    local _, _, _, saved = banner:GetPoint(1)
    H.Equal(saved, 72)
end)

H.Test("ordinary banners keep the newest fresh sighting and skip old queued sightings", function()
    local state, _, _, ui = setup()
    ui:Alert({ kind = "watch", priority = 90, contact = { id = "W", name = "Watch" } })
    ui:Alert({ kind = "sighting", priority = 69, contact = { id = "A", name = "Old" } })
    state:Advance(2.75)
    ui:Alert({ kind = "sighting", priority = 69, contact = { id = "B", name = "Fresh" } })
    state:Advance(0.5)
    ui:Alert({ kind = "sighting", priority = 69, contact = { id = "C", name = "Newest" } })
    H.Equal(ui.banner.body:GetText(), "Watch")
    state:Advance(0.85)
    H.Equal(ui.banner.body:GetText(), "Newest")

    ui:Alert({ kind = "watch", priority = 90, contact = { id = "W2", name = "Watch 2" } })
    ui:Alert({ kind = "sighting", priority = 69, contact = { id = "D", name = "Stale" } })
    state:Advance(4.1)
    H.False(ui.banner:IsShown()); H.Equal(#ui.bannerQueue, 0)
end)

H.Test("urgent banners retain the older equal-priority warning for up to five seconds", function()
    local state, _, _, ui = setup()
    ui:Alert({ kind = "stealth", priority = 100, contact = { id = "S", name = "Confirmed stealth" } })
    state:Advance(0.25)
    ui:Alert({ kind = "targeting", priority = 70, contact = { id = "W1", name = "First urgent" } })
    state:Advance(0.75)
    ui:Alert({ kind = "targeting", priority = 70, contact = { id = "W2", name = "Second urgent" } })
    state:Advance(3.1)
    H.Equal(ui.banner.body:GetText(), "First urgent")
    state:Advance(4.1)
    H.False(ui.banner:IsShown()); H.Equal(#ui.bannerQueue, 0)
end)

H.Test("returning encounters use a distinct localized banner heading", function()
    local _, _, app, ui = setup()
    for locale, title in pairs({ enUS = "Opponent returned", ruRU = "Противник снова рядом" }) do
        app.db:GetProfile().locale = locale
        ui:ClearBanners()
        ui:Alert({ kind = "returning", contact = { id = "R", name = "Returning player" } })
        H.Equal(ui.banner.title:GetText(), title)
        H.Equal(ui.banner.title:GetText(), ui:T("returningTitle"))
        H.True(ui.banner.title:GetText() ~= ui:T("alertTitle"))
    end
end)

H.Test("banner queue is capped and duplicate identity events do not inflate it", function()
    local _, _, _, ui = setup()
    ui:Alert({ kind = "stealth", priority = 100, contact = { id = "S", name = "Stealth" } })
    for index = 1, 20 do
        local decision = { kind = "sighting", priority = 20, contact = { id = "C" .. index, name = "Enemy " .. index } }
        ui:Alert(decision); ui:Alert(decision)
    end
    H.Equal(#ui.bannerQueue, 8)
    local seen = {}
    for _, queued in ipairs(ui.bannerQueue) do
        H.Nil(seen[queued.key]); seen[queued.key] = true
    end
    H.Equal(ui.banner.body:GetText(), "Stealth")
end)

H.Test("guide preview dismisses and persists through reload while Alerts is available only on step two", function()
    local _, _, app, ui = setup()
    H.True(ui:ShowGuide(false))
    local dialog = assert(ui.guideDialog)
    local heading = dialog.heading:GetText()
    H.False(app.db:HasSeenGuide()); H.False(dialog.back.enabled)
    H.False(dialog.openAlerts:IsShown())
    dialog.next:Click()
    H.True(dialog.heading:GetText() ~= heading)
    H.True(dialog.openAlerts:IsShown())
    dialog.back:Click(); H.Equal(dialog.heading:GetText(), heading)
    H.False(dialog.openAlerts:IsShown())
    dialog.preview:Click(); H.Equal(app.demos, 1)
    H.Equal(#app.engine:Snapshot(), 0); H.Equal(#app.db:GetJournal(), 0)
    H.False(dialog:IsShown()); H.True(app.db:HasSeenGuide())
    local _, _, nextApp, nextUI = setup(app.db.root)
    H.True(nextApp.db:HasSeenGuide()); H.False(nextUI:ShowGuide(false))
    H.True(nextUI:ShowGuide(true)); H.True(nextUI.guideDialog:IsShown())
    nextUI.guideDialog.next:Click()
    nextUI.guideDialog.next:Click()
    H.False(nextUI.guideDialog.openAlerts:IsShown())
    nextUI.guideDialog.back:Click()
    H.True(nextUI.guideDialog.openAlerts:IsShown())
    nextUI.guideDialog.openAlerts:Click()
    H.False(nextUI.guideDialog:IsShown()); H.True(nextApp.db:HasSeenGuide())
    H.True(nextUI.settings:IsShown())
    H.True(nextUI.pages.alerts:IsShown())
    H.Equal(nextUI.currentPage, "alerts")
    H.Equal(nextApp.demos, 0)
end)

H.Test("journal search filters recent encounters and notes without exposing IDs", function()
    local state, _, app, ui = setup()
    local epoch = state.api.time()
    app.db:Record({ identity = "guid:PrivateId-1", name = "Moon Weaver", class = "DRUID", hostile = true, isPlayer = true }, epoch - 30, "Zone")
    app.db:Record({ identity = "guid:PrivateId-2", name = "Dawn Runner", class = "HUNTER", hostile = true, isPlayer = true }, epoch - 10, "Zone")
    assert(app.db:SetList("guid:PrivateId-1", "watch", "Enemy camp", { name = "Moon Weaver", class = "DRUID" }))
    ui:OpenSettings("journal")
    ui.journalSearch:SetText("  enemy CAMP  ")
    H.Equal(ui.journalRows[1].contact.name, "Moon Weaver")
    H.Nil(ui.journalRows[2].contact)
    H.Nil(ui.journalRows[1].label:GetText():find("PrivateId", 1, true))
    ui.journalSearch:SetText("nothing matches")
    H.True(ui.journalEmpty:IsShown()); H.Nil(ui.journalRows[1].contact)
end)

H.Test("personal browser includes unseen saved entries and filters by list kind", function()
    local _, _, app, ui = setup()
    assert(app.db:SetList("guid:Watch-A", "watch", "Watch note", { name = "Alpha", class = "ROGUE" }))
    assert(app.db:SetList("guid:Avoid-B", "avoid", "Avoid note", { name = "Beta", class = "HUNTER" }))
    ui:OpenSettings("journal"); ui.journalPersonal:Click()
    H.Equal(ui.journalRows[1].contact.name, "Alpha")
    H.True(ui.journalRows[1].contact.savedOnly)
    H.Equal(ui.journalRows[2].contact.name, "Beta")
    ui.journalFilterChoices.watch:Click()
    H.Equal(ui.journalRows[1].contact.name, "Alpha")
    H.Nil(ui.journalRows[2].contact)
    ui.journalRows[1]:Click()
    H.True(ui.detailsFrame:IsShown())
    H.Equal(ui.detailsFrame.title:GetText(), "Alpha")
    H.Equal(ui.detailsFrame.note:GetText(), "Watch note")
    H.Nil(ui.detailsFrame.info:GetText():find("Watch-A", 1, true))
end)

H.Test("clear journal requires a timely second click and leaves personal lists intact", function()
    local state, _, app, ui = setup()
    app.db:Record({ identity = "guid:Keep", name = "Keep", class = "HUNTER", hostile = true, isPlayer = true }, state.api.time(), "Zone")
    assert(app.db:SetList("guid:Keep", "watch", "Keep note", { name = "Keep" }))
    ui:OpenSettings("journal")
    ui.journalClear:Click(); H.Equal(#app.db:GetJournal(), 1)
    state:Advance(7)
    ui.journalClear:Click(); H.Equal(#app.db:GetJournal(), 1)
    ui.journalClear:Click(); H.Equal(#app.db:GetJournal(), 0)
    H.Equal(app.db:GetList()["guid:Keep"].note, "Keep note")
end)

H.Test("membership buttons preserve notes and full record deletion is explicit", function()
    local _, _, app, ui = setup()
    local identity = "guid:Membership"
    assert(app.db:SetList(identity, "watch", "Keep forever", { name = "Rival", class = "ROGUE" }))
    ui:OpenSettings("journal"); ui.journalPersonal:Click(); ui.journalRows[1]:Click()
    local detail = ui.detailsFrame
    detail.listActions.avoid:Click()
    H.Equal(app.db:GetList()[identity].kind, "avoid")
    H.Equal(app.db:GetList()[identity].note, "Keep forever")
    detail.removeMembership:Click()
    H.Equal(app.db:GetList()[identity].kind, "note")
    H.Equal(app.db:GetList()[identity].note, "Keep forever")
    detail.removeSaved:Click(); H.True(app.db:GetList()[identity] ~= nil)
    detail.removeSaved:Click(); H.Nil(app.db:GetList()[identity]); H.False(detail:IsShown())
end)

H.Test("cleared saved note remains empty when details refresh", function()
    local _, _, app, ui = setup()
    local identity = "guid:NoteClear"
    assert(app.db:SetList(identity, "watch", "Prior note", { name = "Rival", class = "ROGUE" }))
    ui:OpenSettings("journal"); ui.journalPersonal:Click(); ui.journalRows[1]:Click()
    H.Equal(ui.detailsFrame.note:GetText(), "Prior note")
    assert(app:SetNote(ui.selected, ""))
    H.Nil(app.db:GetList()[identity].note)
    ui:ShowDetails(true)
    H.Equal(ui.detailsFrame.note:GetText(), "")
end)

H.Test("nameplate badges distinguish current target focus and watch membership", function()
    local state, _, app, ui = setup()
    local profile = app.db:GetProfile()
    profile.display.badgeTarget, profile.display.badgeFocus = true, true
    profile.display.badgeSize, profile.display.badgeOffset = 30, 8
    state:Unit("nameplate1", {})
    local plate = state.plates.nameplate1
    local contact = { name = "Enemy", class = "ROGUE", hostile = true, isPlayer = true, watched = true, currentTarget = true, currentFocus = false }
    ui:SetNameplate("nameplate1", plate, contact)
    local badge = assert(ui.badges.active.nameplate1)
    H.True(badge:IsShown()); H.True(badge.target:IsShown()); H.False(badge.focus:IsShown()); H.True(badge.marker:IsShown())
    H.Equal(badge:GetWidth(), 30)
    local _, _, _, offset = badge:GetPoint(1)
    H.Equal(offset, 8)
    contact.currentTarget, contact.currentFocus = false, true
    ui:SetNameplate("nameplate1", plate, contact)
    H.False(badge.target:IsShown()); H.True(badge.focus:IsShown())
    contact.listKind = "ignore"
    ui:SetNameplate("nameplate1", plate, contact)
    H.False(badge:IsShown())
end)

H.Test("badge geometry waits for combat end and unsafe parent receives nothing", function()
    local state, _, app, ui = setup()
    local profile = app.db:GetProfile()
    local contact = { name = "Enemy", class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", {}); state:Unit("nameplate2", {}); state:Unit("nameplate3", {})
    local plate = state.plates.nameplate1
    ui:SetNameplate("nameplate1", plate, contact)
    local badge = assert(ui.badges.active.nameplate1)
    local width = badge:GetWidth()
    state.combat = true
    profile.display.badgeSize = width + 4
    ui:SetNameplate("nameplate1", plate, contact)
    ui:SetNameplate("nameplate2", state.plates.nameplate2, contact)
    H.Equal(badge:GetWidth(), width); H.Nil(ui.badges.active.nameplate2)
    state.combat = false
    ui:SetNameplate("nameplate1", plate, contact)
    H.Equal(badge:GetWidth(), width + 4)
    state.plates.nameplate3.forbidden = true
    ui:SetNameplate("nameplate3", state.plates.nameplate3, contact)
    H.Nil(ui.badges.active.nameplate3)
    H.Equal(#state.blocked, 0)
end)

H.Test("badge visual updates stay selective through style changes and frame reuse", function()
    local state, _, app, ui = setup()
    state:Unit("nameplate1", {}); state:Unit("nameplate2", {})
    local first, second = state.plates.nameplate1, state.plates.nameplate2
    local contact = { id = "first", class = "ROGUE", hostile = true, isPlayer = true, currentTarget = true, watched = true }
    ui:SetNameplate("nameplate1", first, contact)
    local badge = assert(ui.badges.active.nameplate1)
    local writes = {}
    local function count(frame, method, key)
        local original = frame[method]
        frame[method] = function(...)
            writes[key] = (writes[key] or 0) + 1
            return original(...)
        end
    end
    count(badge, "SetShown", "root")
    count(badge.target, "SetShown", "target")
    count(badge.focus, "SetShown", "focus")
    count(badge.marker, "SetShown", "watch")
    count(badge.icon, "SetTexture", "texture")

    contact.currentTarget, contact.currentFocus = false, true
    ui:SetNameplate("nameplate1", first, contact)
    H.Equal(writes.target, 1); H.Equal(writes.focus, 1)
    H.Nil(writes.root); H.Nil(writes.texture); H.Nil(writes.watch)
    H.False(badge.target:IsShown()); H.True(badge.focus:IsShown())

    state.combat = true
    local display = app.db:GetProfile().display
    display.badgeSize, display.badgeOffset = 33, 11
    ui.badges:Refresh()
    H.Equal(badge:GetWidth(), 24)
    H.Equal(writes.target, 1); H.Equal(writes.focus, 1)
    state.combat = false
    ui.badges:Refresh()
    H.Equal(badge:GetWidth(), 33)
    local _, _, _, offset = badge:GetPoint(1)
    H.Equal(offset, 11)

    ui:RemoveNameplate("nameplate1")
    H.False(badge:IsShown())
    ui:SetNameplate("nameplate2", second, { id = "second", class = "HUNTER", hostile = true, isPlayer = true })
    H.Equal(ui.badges.active.nameplate2, badge)
    H.Equal(badge:GetParent(), second)
    H.True(badge:IsShown()); H.False(badge.marker:IsShown()); H.False(badge.focus:IsShown())
    H.Equal(writes.root, 2); H.Equal(writes.texture, 1); H.Equal(writes.watch, 1)
    H.Equal(#state.blocked, 0)
end)

H.Test("advanced rule settings survive tab changes and constrain real decisions", function()
    local _, RG, app, ui = setup()
    ui:OpenRules()
    local dialog = ui.rulesDialog
    dialog.nameInput:SetText("Listed enemies close by")
    dialog.priority:SetValue(78)
    dialog.conditions:Click()
    H.True(dialog.conditionPanel:IsShown()); H.False(dialog.basicPanel:IsShown())
    dialog.context:Click()
    dialog.list:Click()
    dialog.range:SetValue(25)
    dialog.rangePolicy:Click()
    dialog.basic:Click()
    H.Equal(dialog.nameInput:GetText(), "Listed enemies close by")
    H.Equal(dialog.priority:GetValue(), 78)
    H.Equal(#app.db:GetProfile().rules, 0)
    dialog.save:Click()
    local profile = app.db:GetProfile()
    local rule = profile.rules[1]
    H.Equal(rule.context, "world"); H.Equal(rule.list, "listed"); H.Equal(rule.range, 25)
    H.Equal(rule.rangePolicy, "confirmed"); H.False(rule.rangeUnknown)
    local contact = { id = "fixture", class = "ROGUE", hostile = true, isPlayer = true, rangeMin = 8, rangeMax = 25 }
    local watch = { kind = "watch" }
    local function decision(context, list)
        return assert(RG.Rules.Evaluate(profile, contact, "sighting", { kind = context }, list))
    end
    H.Equal(decision("world", watch).ruleName, rule.name)
    H.Nil(decision("world").ruleName)
    H.Nil(decision("battleground", watch).ruleName)
    contact.rangeMax = 35
    H.Nil(decision("world", watch).ruleName)
    local restored = assert(app.db:PreviewImport(assert(app.db:ExportProfile())))
    H.Equal(restored.rules[1].rangePolicy, "confirmed")
end)

H.Test("minimap launcher toggles nearby from left click and opens settings from right click", function()
    local state, _, app, ui = setup(nil, minimap)
    local launcher = assert(ui.launcher)
    H.Equal(launcher.frame:GetParent(), state.api.Minimap)
    H.True(launcher.frame:IsShown()); H.True(ui.frame:IsShown())
    launcher.frame:Click("LeftButton"); H.False(ui.frame:IsShown())
    launcher.frame:Click("RightButton"); H.True(ui.settings:IsShown())
    H.False(ui.frame:IsShown())
    app.db:GetProfile().display.minimap = false
    ui:Refresh(); H.False(launcher.frame:IsShown())
end)

H.Test("minimap drag commits angle on release and cancels during combat or profile switch", function()
    local state, _, app, ui = setup(nil, minimap)
    local launcher, map = assert(ui.launcher), state.api.Minimap
    local frame, profile = launcher.frame, app.db:GetProfile()
    local function position(dx, dy)
        state.cursorX = (map.centerX + dx) * map:GetEffectiveScale()
        state.cursorY = (map.centerY + dy) * map:GetEffectiveScale()
    end
    local initial = profile.display.minimapAngle
    position(100, 0)
    frame.scripts.OnDragStart(frame)
    H.Equal(profile.display.minimapAngle, initial)
    frame.scripts.OnDragStop(frame)
    H.Equal(profile.display.minimapAngle, 0)
    H.Nil(frame:GetScript("OnUpdate"))
    position(0, 100); frame.scripts.OnDragStart(frame)
    state.combat = true
    ui:Refresh(); H.Nil(frame:GetScript("OnUpdate"))
    frame.scripts.OnDragStop(frame)
    H.Equal(profile.display.minimapAngle, 0)
    state.combat = false
    position(0, 100); frame.scripts.OnDragStart(frame)
    assert(app.db:CreateProfile("Second")); assert(app.db:SetProfile("Second"))
    ui:Refresh(); frame.scripts.OnDragStop(frame)
    H.Equal(profile.display.minimapAngle, 0)
    H.Equal(app.db:GetProfile().display.minimapAngle, initial)
end)

H.Test("forbidden minimap skips launcher and leaves settings usable", function()
    local _, _, _, ui = setup(nil, function(state) minimap(state, true) end)
    H.Nil(ui.launcher)
    ui:OpenSettings("appearance")
    H.True(ui.settings:IsShown())
    H.False(ui.launcherReset.enabled)
end)
