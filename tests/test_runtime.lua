local H = RGTest
local W = assert(loadfile(H.root .. "/tests/support/wow.lua"))()

local function setup(raw)
    local state = W.New()
    state.api.RivalGuardDB = raw
    local RG = state:LoadTOC()
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.True(RG.instance.initialized == true, "addon did not initialize from actual TOC")
    return state, RG, RG.instance
end

H.Test("contact snooze removes only its live alerts and resumes without persisting a setting", function()
    local state, RG, app = setup()
    local ui = app.ui
    for index, name in ipairs({ "FirstRival", "SecondRival" }) do
        local guid = "Player-Snooze-" .. index
        assert(app.db:SetList("guid:" .. guid, "watch", nil, { name = name, class = "ROGUE" }))
        local token = "nameplate" .. index
        state:Unit(token, { guid = guid, name = name, class = "ROGUE", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        state:Advance(1)
    end
    H.Equal(ui.banner.body:GetText(), "FirstRival")
    H.Equal(#ui.bannerQueue, 1)
    local first = app.engine:Snapshot()[2]
    H.Equal(first.name, "FirstRival")
    ui:Select(first)
    H.True(ui.detailsFrame.snooze:IsShown())
    local original = assert(RG.Codec.Encode(app.db.root))
    ui.detailsFrame.snooze:Click()
    H.Equal(ui.banner.body:GetText(), "SecondRival")
    H.Equal(ui.detailsFrame.snooze.label:GetText(), ui:T("resumeContact"))
    H.Equal(app.engine:ExplainView(first.id).reason, "contact_snoozed")
    local sent = app.engine.counters.alerts
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-Snoozed", 1784)
    state:Advance(1.5)
    H.Equal(app.engine.counters.alerts, sent)
    ui.detailsFrame.snooze:Click()
    H.Equal(ui.detailsFrame.snooze.label:GetText(), ui:T("snoozeContact"))
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-Resumed", 1784)
    state:Advance(1)
    H.Equal(app.engine.counters.alerts, sent + 1)
    H.Equal(ui.banner.body:GetText(), "FirstRival")
    H.Equal(assert(RG.Codec.Encode(app.db.root)), original)
end)

H.Test("contact snooze applies to a retained encounter but not unnamed or saved-only entries", function()
    local state, _, app = setup()
    state:Unit("nameplate1", { guid = "Player-NoLongerHere", name = "Retained", class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local contact = app.engine:Snapshot()[1]
    app.ui:Select(contact)
    H.True(app.ui.detailsFrame.snooze:IsShown())
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    state:Advance(1)
    H.False(app.engine:Snapshot()[1].visible)
    H.True(app.ui.detailsFrame.snooze:IsShown())
    H.True(app:Snooze(contact, 60))

    state:Unit("nameplate2", { class = "HUNTER", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    local anonymous = app.engine:Snapshot()[1]
    H.Nil(anonymous.identity)
    app.ui:Select(anonymous)
    H.False(app.ui.detailsFrame.snooze:IsShown())
    local applied = app:Snooze(anonymous, 60)
    H.False(applied == true)
    assert(app.db:SetList("guid:OfflineFixture", "watch", nil, { name = "OfflineWatch" }))
    app.ui:OpenSettings("journal")
    app.ui.journalPersonal:Click()
    app.ui.journalRows[1]:Click()
    H.False(app.ui.detailsFrame.snooze:IsShown())
end)

H.Test("manifest load and addon event initialize once with slash commands", function()
    local state, _, app = setup()
    H.Equal(state.api.RivalGuardDB, app.db.root)
    H.Equal(type(state.api.SlashCmdList.RIVALGUARD), "function")
    H.Equal(state.api.SLASH_RIVALGUARD2, "/rg")
    local count = #state.frames
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.Equal(#state.frames, count)
    H.Nil(app.diagnostics.counts.errors)
end)

H.Test("integrated sensors engine and UI deliver one alert with configured sound channel", function()
    local state, _, app = setup()
    app.db:GetProfile().alerts.channel = "Dialog"
    state:Unit("nameplate1", { guid = "Player-fixture-A", name = "PrivateEnemy", class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(1.5)
    H.Equal(#app.engine:Snapshot(), 1)
    H.True(app.ui.rows[1]:IsShown())
    H.Equal(app.ui.rows[1].nameText:GetText(), "PrivateEnemy")
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].channel, "Dialog")
    H.Equal(#app.db:GetJournal(), 1)
    H.Nil(app.diagnostics.counts.errors)
end)

H.Test("cosmetic streamer setting keeps a queued encounter and applies redaction at delivery", function()
    local state, _, app = setup()
    state:Unit("nameplate1", { guid = "Player-Cosmetic", name = "Example Roving Player", class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(app.engine.counters.alerts, 0)
    app.db:GetProfile().display.streamer = true
    app:OnSettingsChanged()
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    state:Advance(1.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.True(app.ui.banner:IsShown())
    H.Equal(app.ui.banner.body:GetText(), app.ui:T("unknownPlayer"))
end)

H.Test("slash pause resume mute and settings operate without hidden side effects", function()
    local state, _, app = setup()
    local slash = state.api.SlashCmdList.RIVALGUARD
    slash("pause 2"); H.Equal(app.engine.pausedUntil, state.clock.Now() + 120)
    slash("resume"); H.Nil(app.engine.pausedUntil)
    slash("mute"); H.False(app.db:GetProfile().alerts.sound)
    slash("settings"); H.True(app.ui.settings:IsShown())
    slash("help"); H.True(#state.messages > 0)
    H.Equal(#state.sounds, 0)
    H.Equal(#app.engine:Snapshot(), 0)
end)

H.Test("demo uses UI-only fixtures and leaves saved history and lists untouched", function()
    local state, RG, app = setup()
    local before = assert(RG.Codec.Encode(app.db.root))
    state.api.SlashCmdList.RIVALGUARD("demo")
    H.Equal(#app.engine:Snapshot(), 0)
    H.Equal(#app.db:GetJournal(), 0)
    H.Equal(next(app.db:GetList()), nil)
    H.Equal(assert(RG.Codec.Encode(app.db.root)), before)
    H.True(app.ui.banner:IsShown())
    state:Advance(20)
    H.Equal(#app.engine:Snapshot(), 0)
    H.Equal(#state.sounds, 0)
end)

H.Test("future saved schema survives initialization settings actions and logout", function()
    local raw = { schemaVersion = 999, activeProfile = "Future", important = { keep = "untouched" } }
    local state, _, app = setup(raw)
    H.False(app.db.writable)
    H.Equal(state.api.RivalGuardDB, raw)
    app:ToggleMute()
    state:Fire("PLAYER_LOGOUT")
    H.Equal(state.api.RivalGuardDB, raw)
    H.Equal(raw.important.keep, "untouched")
    H.Nil(raw.profiles)
end)

H.Test("runtime diagnostics report redacts observed identities and error details", function()
    local state, _, app = setup()
    state:Unit("nameplate1", { guid = "Player-PrivateGUID", name = "PrivateEnemy", class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(1)
    app:SetNote(app.engine:Snapshot()[1], "PrivateNote")
    app.ui.Refresh = function() error("PrivateEnemy PrivateGUID PrivateNote") end
    app.dirty = true; app:Update(1)
    local report = app:ExportDiagnostics()
    H.Nil(report:find("PrivateEnemy", 1, true)); H.Nil(report:find("PrivateGUID", 1, true)); H.Nil(report:find("PrivateNote", 1, true))
    H.True(report:find("ui_refresh", 1, true) ~= nil)
end)

for _, locale in ipairs({ "enUS", "ruRU" }) do
    H.Test("streamer transition redacts open live and saved UI in " .. locale, function()
        local state, RG, app = setup()
        local profile, ui = app.db:GetProfile(), app.ui
        profile.locale = locale
        app:ProfileChanged()
        local identity = "guid:Player-StreamerFixture"
        local name = locale == "ruRU" and "ИгрокПример" or "ExamplePlayer"
        local note, draft = "Test saved note", "Uncommitted note"
        assert(app.db:SetList(identity, "watch", note, { name = name, class = "ROGUE" }))
        state:Unit("nameplate1", { guid = "Player-StreamerFixture", name = name, class = "ROGUE", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        state:Advance(1)
        H.Equal(ui.rows[1].nameText:GetText(), name)
        H.True(ui.banner:IsShown())
        H.Equal(ui.banner.body:GetText(), name)
        ui:OpenSettings("journal")
        ui.journalPersonal:Click()
        ui.journalSearch:SetText(note)
        H.True(ui.journalRows[1]:IsShown())
        ui.journalRows[1]:Click()
        local detail = ui.detailsFrame
        H.Equal(detail.title:GetText(), name)
        H.Equal(detail.note:GetText(), note)
        detail.note:SetFocus()
        detail.note:SetText(draft)
        ui:Refresh()
        H.Equal(detail.note:GetText(), draft)

        profile.display.streamer = true
        app:ProfileChanged()
        H.Nil(ui.rows[1].nameText:GetText():find(name, 1, true))
        H.True(ui.banner:IsShown())
        H.Equal(ui.banner.body:GetText(), RG.Locale.Get("unknownPlayer", locale))
        H.Nil(ui.journalRows[1].label:GetText():find(name, 1, true))
        H.Equal(ui.journalSearch:GetText(), "")
        H.False(ui.journalSearch:HasFocus())
        H.Equal(detail.title:GetText(), RG.Locale.Get("unknownPlayer", locale))
        H.Equal(detail.note:GetText(), "")
        H.False(detail.note:HasFocus())
        H.Equal(app.db:GetList()[identity].note, note)

        profile.display.streamer = false
        app:ProfileChanged()
        H.Equal(ui.banner.body:GetText(), name)
        H.Equal(detail.title:GetText(), name)
        H.Equal(detail.note:GetText(), note)
        H.Equal(#app.db:GetJournal(), 1)
    end)
end

H.Test("target watch and ignore commands toggle only explicit selected identity", function()
    local state, _, app = setup()
    state:Unit("target", { guid = "Player-Target", name = "Enemy", class = "HUNTER", hostile = true, isPlayer = true })
    state.api.SlashCmdList.RIVALGUARD("watch")
    H.Equal(app.db:GetList()["guid:Player-Target"].kind, "watch")
    state.api.SlashCmdList.RIVALGUARD("watch")
    H.Nil(app.db:GetList()["guid:Player-Target"])
    state.api.SlashCmdList.RIVALGUARD("ignore")
    H.Equal(app.db:GetList()["guid:Player-Target"].kind, "ignore")
    H.Equal(#app.engine:Snapshot(), 0)
end)

H.Test("simulated combat UI refresh never mutates protected action attributes", function()
    local state, _, app = setup()
    state.combat = true
    state:Fire("PLAYER_REGEN_DISABLED")
    app.ui:OpenSettings("appearance")
    app:Demo()
    state:Advance(1)
    H.Equal(#state.blocked, 0)
    for _, mutation in ipairs(state.mutations) do H.True(mutation.action ~= "SetAttribute") end
    state.combat = false
    state:Fire("PLAYER_REGEN_ENABLED")
end)

H.Test("fail once before UI creation preserves saved data and allows clean retry", function()
    local state = W.New()
    local raw = { schemaVersion = 1, activeProfile = "Default", profiles = {} }
    state.api.RivalGuardDB = raw
    local RG = state:LoadTOC()
    local create, failures = RG.UI.New, 0
    RG.UI.New = function(app)
        failures = failures + 1
        if failures == 1 then error("injected startup failure") end
        return create(app)
    end
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.False(RG.instance.initialized)
    H.False(RG.instance.initializing)
    H.Equal(state.api.RivalGuardDB, raw)
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.True(RG.instance.initialized)
    H.Equal(state.api.RivalGuardDB, RG.instance.db.root)
end)

H.Test("failed constructed UI is torn down without orphaned update scripts", function()
    local state = W.New()
    local RG = state:LoadTOC()
    local create, partial = RG.UI.New, nil
    RG.UI.New = function(app)
        partial = create(app)
        error("injected post-construction failure")
    end
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.False(RG.instance.initialized)
    H.True(partial ~= nil)
    H.Nil(partial.ticker:GetScript("OnUpdate"), "partially constructed UI ticker still owns live work")
    H.False(partial.frame:IsShown())
    H.Nil(next(partial.ticker.events))
end)

H.Test("sensor startup refusal rolls back UI and does not claim initialization", function()
    local state = W.New()
    local raw = { schemaVersion = 1, profiles = {} }
    state.api.RivalGuardDB = raw
    local RG = state:LoadTOC()
    local construct = RG.Sensors.New
    RG.Sensors.New = function(...)
        local sensors = construct(...)
        sensors.Start = function() return false end
        return sensors
    end
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.False(RG.instance.initialized, "sensor startup refusal must not produce a ready addon")
    H.Equal(state.api.RivalGuardDB, raw)
    H.False(RG.instance.ui.frame:IsShown())
end)

H.Test("watch ignore and note actions preserve notes through repeated toggles", function()
    local _, _, app = setup()
    local contact = { identity = "guid:Player-Note", name = "Enemy", class = "ROGUE" }
    assert(app:SetNote(contact, "Remember this player"))
    for _, action in ipairs({ "Watch", "Watch", "Ignore", "Ignore" }) do
        assert(app[action](app, contact))
        H.Equal(app.db:GetList()[contact.identity].note, "Remember this player")
    end
    H.Equal(app.db:GetList()[contact.identity].kind, "note")
    assert(app:SetNote(contact, ""))
    H.Nil(app.db:GetList()[contact.identity].note)
end)

H.Test("threat journal records a confirmed threat that develops after the first sighting exactly once", function()
    local state, _, app = setup()
    app.db:GetProfile().retention.journalMode = "threats"
    state:Unit("nameplate1", { guid = "Player-LateThreat", name = "Rival", class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(1)
    H.Equal(#app.db:GetJournal(), 0)
    state:Unit("player", { guid = "Player-Local", name = "Self", class = "PRIEST" })
    state:Unit("nameplate1target", { guid = "Player-Local", name = "Self", class = "PRIEST" })
    state:Advance(2)
    local journal = app.db:GetJournal()
    H.Equal(#journal, 1)
    H.Equal(journal[1].identity, "guid:Player-LateThreat")
    H.Equal(journal[1].encounters, 1)
end)

H.Test("watched journal records an existing encounter when the user adds it to Watch once", function()
    local state, _, app = setup()
    app.db:GetProfile().retention.journalMode = "watched"
    state:Unit("nameplate1", { guid = "Player-AddWatch", name = "Rival", class = "HUNTER", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(1)
    H.Equal(#app.db:GetJournal(), 0)
    assert(app:Watch(app.engine:Snapshot()[1]))
    state:Advance(2)
    local journal = app.db:GetJournal()
    H.Equal(#journal, 1)
    H.Equal(journal[1].identity, "guid:Player-AddWatch")
    H.Equal(journal[1].encounters, 1)
end)

H.Test("threat journal records confirmed cast and does not regenerate cleared encounters", function()
    local state, _, app = setup()
    local profile = app.db:GetProfile()
    profile.retention.journalMode = "threats"
    state:Unit("nameplate1", { guid = "Player-Cast", name = "Rival", class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(1)
    H.Equal(#app.db:GetJournal(), 0)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-Fixture", 1784)
    state:Advance(1)
    H.Equal(#app.db:GetJournal(), 1)
    H.Equal(app.db:GetJournal()[1].encounters, 1)
    H.Equal(app.db:ClearJournal(), 1)
    state:Advance(3)
    H.Equal(#app.db:GetJournal(), 0)
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    state.units.nameplate1 = nil
    state:Advance(profile.alerts.returnAfter + 1)
    state:Unit("nameplate1", { guid = "Player-Cast", name = "Rival", class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-Fixture-2", 1784)
    state:Advance(1)
    H.Equal(#app.db:GetJournal(), 1)
    H.Equal(app.db:GetJournal()[1].encounters, 1)
end)

H.Test("status uses clean C_CVar evidence and falls back only when the reader is absent", function()
    local state, _, app = setup()
    local legacyReads = 0
    state.api.GetCVarBool = function() legacyReads = legacyReads + 1; return true end
    state.api.C_CVar = { GetCVarBool = function(name) H.Equal(name, "nameplateShowEnemies"); return false end }
    local status = app:Status()
    H.False(status.nameplates); H.Equal(status.state, "limited"); H.Equal(legacyReads, 0)
    state.api.C_CVar.GetCVarBool = function() return H.Secret("restricted CVar") end
    status = app:Status()
    H.Nil(status.nameplates); H.Equal(legacyReads, 0)
    state.api.C_CVar.GetCVarBool = function() error("blocked CVar") end
    status = app:Status()
    H.Nil(status.nameplates); H.Equal(legacyReads, 0)
    state.api.C_CVar.GetCVarBool = nil
    status = app:Status()
    H.True(status.nameplates); H.Equal(legacyReads, 1)
end)
