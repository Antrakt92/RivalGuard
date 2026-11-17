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
