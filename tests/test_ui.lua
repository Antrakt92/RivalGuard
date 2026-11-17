local H = RGTest
local W = assert(loadfile(H.root .. "/tests/support/wow.lua"))()
local modules = { "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Codec.lua", "Core/Database.lua", "Core/Rules.lua", "Core/Engine.lua", "Core/Diagnostics.lua", "Locale/Strings.lua", "UI/Model.lua", "UI/Badges.lua", "UI/Main.lua" }

local function setup(raw)
    local state = W.New()
    local RG = state:Load(modules)
    local app = { db = RG.Database.New(raw), changes = 0, demos = 0 }
    app.engine = RG.Engine.New({ clock = state.clock.Now, profile = app.db:GetProfile() })
    function app:OnSettingsChanged() self.changes = self.changes + 1; self.engine:SetProfile(self.db:GetProfile()) end
    app.ProfileChanged = app.OnSettingsChanged
    function app:ToggleMute() self.db:GetProfile().alerts.sound = not self.db:GetProfile().alerts.sound; self:OnSettingsChanged() end
    function app:Demo() self.demos = self.demos + 1 end
    function app:Notify(text) state.messages[#state.messages + 1] = text end
    function app:Status() return { state = "limited", nameplates = false, detail = "Fixture limitation" } end
    function app:ExportDiagnostics() return "RivalGuard fixture report\nNo player data" end
    local ui = RG.UI.New(app)
    app.ui = ui
    return state, RG, app, ui
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

H.Test("quick class chips update only display filtering and preserve audible selection", function()
    local _, _, app, ui = setup()
    local before = app.db:GetProfile().alerts.classes
    for _, chip in ipairs(ui.quickChips) do if chip.class == "ROGUE" then chip.frame:Click() end end
    H.False(app.db:GetProfile().display.classes.ROGUE)
    H.Equal(app.db:GetProfile().alerts.classes, before)
    H.True(app.changes > 0)
end)

H.Test("UI row recycling clears absent contacts and keeps Unicode names", function()
    local _, _, app, ui = setup()
    app.engine:Observe({ token = "nameplate1", guid = "A", name = "Разбойник", class = "ROGUE", hostile = true, isPlayer = true, source = "nameplate" })
    ui:Refresh()
    H.True(ui.rows[1]:IsShown()); H.Equal(ui.rows[1].nameText:GetText(), "Разбойник")
    app.engine:Clear(); ui:Refresh()
    H.False(ui.rows[1]:IsShown()); H.Nil(ui.rows[1].contact)
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
    ui.frame:ClearAllPoints()
    ui.frame:SetPoint("TOPLEFT", state.api.UIParent, "BOTTOMRIGHT", 123, -87)
    ui.frame:SetPoint("TOPRIGHT", state.api.UIParent, "BOTTOMRIGHT", 471, -87)
    local dragHeader
    for _, child in ipairs(ui.frame.children) do
        if child.scripts.OnDragStop then dragHeader = child break end
    end
    H.True(dragHeader ~= nil)
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
end)

H.Test("logout with nil GetPoint preserves prior valid saved position", function()
    local state, _, app, ui = setup()
    ui.frame:ClearAllPoints(); ui.frame:SetPoint("BOTTOM", state.api.UIParent, "TOP", 15, 30)
    state:Fire("PLAYER_LOGOUT")
    local saved = app.db:GetProfile().positions.nearby
    H.Equal(saved.point, "BOTTOM"); H.Equal(saved.relativePoint, "TOP")
    ui.frame:ClearAllPoints()
    state:Fire("PLAYER_LOGOUT")
    H.Equal(app.db:GetProfile().positions.nearby, saved)
    H.Equal(saved.x, 15); H.Equal(saved.y, 30)
end)
