local H = RGTest
local W = assert(loadfile(H.root .. "/tests/support/wow.lua"))()

local function setup(raw, configure)
    local state = W.New()
    if configure then configure(state) end
    state.api.RivalGuardDB = raw
    local RG = state:LoadTOC()
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.True(RG.instance.initialized == true, "addon did not initialize from actual TOC")
    return state, RG, RG.instance
end

local function settingButton(ui, path)
    for _, control in ipairs(ui.controls) do
        if control.path == path then return control.frame end
    end
    error("missing settings control " .. path)
end

local function openSoundPicker(ui, button)
    button:Click()
    local picker = assert(ui.soundPicker, "shared sound picker did not open")
    H.True(picker:IsShown())
    return picker
end

local function soundPickerRow(picker, value)
    for _, row in ipairs(picker.rows) do
        if row.value == value then return row end
    end
    error("missing sound option " .. value)
end

local function pickSound(ui, button, value)
    local picker = openSoundPicker(ui, button)
    soundPickerRow(picker, value).choice:Click()
    H.False(picker:IsShown())
end

local function seedPlate(state, index, shape, guid)
    local token = "nameplate" .. index
    state:Unit(token, { guid = guid or ("Player-Seed" .. index), name = "Seed rival " .. index,
        class = "ROGUE", hostile = true, isPlayer = true })
    local frame = state.plates[token]
    if shape ~= "legacy" then frame.namePlateUnitToken = nil end
    if shape == "method" then
        frame.GetUnit = function(self)
            assert(self == frame, "GetUnit receiver must be the enumerated nameplate")
            return token
        end
    elseif shape == "property" then frame.unitToken = token end
    return frame, token
end

H.Test("login reload and world reseeding read stock nameplate tokens without add events", function()
    local function configure(mock)
        local method = seedPlate(mock, 1, "method")
        method.unitToken = "nameplate2"
        seedPlate(mock, 2, "property")
        seedPlate(mock, 3, "legacy")
    end
    local state, _, app = setup(nil, configure)
    local function verify(active, thirdGuid)
        for index = 1, 3 do
            local token = "nameplate" .. index
            local expected = index == 3 and thirdGuid or ("Player-Seed" .. index)
            H.Equal(assert(active.sensors.active[token]).guid, expected)
            H.True(active.ui.badges.active[token].icon:IsVisible())
        end
        H.Equal(#active.engine:Snapshot(), 3)
    end
    verify(app, "Player-Seed3")

    state:Fire("PLAYER_LOGOUT")
    local fresh, _, reloaded = setup(state.api.RivalGuardDB, configure)
    verify(reloaded, "Player-Seed3")
    fresh:Fire("PLAYER_LEAVING_WORLD")
    H.Equal(#reloaded.engine:Snapshot(), 0)
    fresh.plates.nameplate3, fresh.units.nameplate3 = nil, nil
    seedPlate(fresh, 3, "method", "Player-SeedAfterTravel")
    fresh:Fire("PLAYER_ENTERING_WORLD")
    verify(reloaded, "Player-SeedAfterTravel")
end)

H.Test("nameplate seeding ignores unsafe or stale frames and never falls back from unreadable stock tokens", function()
    local reads, forbiddenGetUnit = {}, 0
    local _, _, app = setup(nil, function(mock)
        local api = mock.api
        local first = seedPlate(mock, 1, "method")
        local secret = H.Secret("unreadable stock nameplate token")
        local silent = seedPlate(mock, 2, "legacy")
        silent.GetUnit = function() return nil end
        local throws = seedPlate(mock, 3, "legacy")
        throws.GetUnit = function() error("nameplate GetUnit unavailable") end
        local hiddenToken = seedPlate(mock, 4, "legacy")
        hiddenToken.GetUnit = function() return secret end
        local malformed = seedPlate(mock, 5, "legacy")
        malformed.GetUnit = function() return "target" end
        local hiddenProperty = seedPlate(mock, 6, "legacy")
        hiddenProperty.unitToken = secret
        local forbidden = seedPlate(mock, 7, "legacy")
        forbidden.forbidden = true
        local unreadable = seedPlate(mock, 8, "legacy")
        unreadable.IsForbidden = function() return secret end
        for _, frame in ipairs({ forbidden, unreadable }) do
            frame.GetUnit = function() forbiddenGetUnit = forbiddenGetUnit + 1; return "nameplate1" end
        end
        local _, staleToken = seedPlate(mock, 9, "method")
        local stale = api.CreateFrame("Frame", nil, api.UIParent)
        stale.GetUnit = function() return staleToken end
        stale.namePlateUnitToken = staleToken
        api.C_NamePlate.GetNamePlates = function()
            return { first, first, silent, throws, hiddenToken, malformed, hiddenProperty, forbidden, unreadable, stale }
        end
        local guid = api.UnitGUID
        api.UnitGUID = function(token)
            reads[token] = (reads[token] or 0) + 1
            return guid(token)
        end
    end)
    H.Equal(forbiddenGetUnit, 0)
    H.Equal(#app.engine:Snapshot(), 1)
    H.Equal(app.engine:Snapshot()[1].identity, "guid:Player-Seed1")
    H.Equal(reads.nameplate1, 2, "one seed observation plus the initial poll")
    for index = 2, 9 do
        local token = "nameplate" .. index
        H.Nil(reads[token]); H.Nil(app.sensors.active[token])
    end
end)

H.Test("runtime status reads both nameplate settings through the supported API without writes", function()
    local writes = 0
    local state, _, app = setup(nil, function(fixture)
        fixture.api.C_CVar = {
            GetCVarBool = function(name) return fixture.cvars[name] end,
            SetCVar = function() writes = writes + 1 end,
        }
        fixture.api.GetCVarBool = function() return true end
        fixture.api.SetCVar = function() writes = writes + 1 end
        fixture.cvars.nameplateShowAll = false
    end)
    local status = app:Status()
    H.True(status.nameplates); H.False(status.alwaysNameplates); H.Equal(status.state, "active")
    state.cvars.nameplateShowAll = true
    H.True(app:Status().alwaysNameplates)
    state.cvars.nameplateShowAll = H.Secret("auto nameplates")
    H.Nil(app:Status().alwaysNameplates)
    state.cvars.nameplateShowEnemies = false
    H.Equal(app:Status().state, "limited")
    state.api.C_CVar.GetCVarBool = nil
    H.True(app:Status().alwaysNameplates); H.True(app:Status().nameplates)
    H.Equal(writes, 0)
end)

local function eventRegistrationFixture(unavailableEvent, failure)
    local reject, enumerations = true, 0
    local state, _, app = setup(nil, function(mock)
        local api, secret = mock.api, H.Secret("restricted registration result")
        local create = api.CreateFrame
        function api.CreateFrame(...)
            local frame = create(...)
            local register = frame.RegisterEvent
            function frame:RegisterEvent(event)
                if not reject or event ~= unavailableEvent then return register(self, event) end
                if failure == "throw" then error("unsupported registration fixture") end
                if failure == "secret" then return secret end
                return false
            end
            return frame
        end
        local plates = api.C_NamePlate.GetNamePlates
        api.C_NamePlate.GetNamePlates = function()
            enumerations = enumerations + 1
            return plates()
        end
    end)
    return state, app, function() reject = false end, function() return enumerations end
end

for _, event in ipairs({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }) do
    for _, failure in ipairs({ "false", "throw", "secret" }) do
        H.Test(event .. " registration " .. failure .. " reports limited detection until a successful restart", function()
            local state, app, allowRegistration, enumerations = eventRegistrationFixture(event, failure)
            H.True(app.sensors.running)
            H.Nil(app.sensors.frame.events[event])
            local status = app:Status()
            H.Equal(status.detectionState, "limited")
            H.False(status.capabilities.nameplateEvents)
            H.True(status.capabilities.nameplates); H.True(status.nameplates)
            H.Equal(app.diagnostics.counts.unsupported_events, 1)
            app.ui:OpenSettings("support")
            H.True(app.ui.supportStatus:GetText():find(app.ui:T("nameplateEventsLimited"), 1, true) ~= nil)
            app.ui:ShowDiagnostics()
            local report = app.ui.copyFrame.edit:GetText()
            H.True(report:find("nameplateEvents=false", 1, true) ~= nil)
            H.True(report:find("detection=limited", 1, true) ~= nil)
            H.True(report:find("unsupported_events=1", 1, true) ~= nil)

            local unit = { guid = "Player-Registration", name = "Observed rival", class = "ROGUE", hostile = true, isPlayer = true }
            state:Unit("target", unit)
            state:Fire("PLAYER_TARGET_CHANGED")
            H.True(app.engine:Snapshot()[1].sources.target)
            local before = enumerations()
            state:Unit("nameplate1", unit)
            state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
            if event == "NAME_PLATE_UNIT_ADDED" then H.Nil(app.sensors.active.nameplate1) end
            state:Advance(1.25)
            H.Equal(app.sensors.active.nameplate1.guid, unit.guid)
            if event == "NAME_PLATE_UNIT_ADDED" then H.True(enumerations() - before >= 1 and enumerations() - before <= 2) end
            state.units.nameplate1, state.plates.nameplate1 = nil, nil
            state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
            state:Advance(1.25)
            H.Nil(app.sensors.active.nameplate1)

            local profile = app.db:GetProfile()
            profile.enabled = false
            app:OnSettingsChanged()
            H.False(app.sensors.running)
            H.Equal(app:Status().detectionState, "disabled")
            state.units.target = nil
            allowRegistration()
            profile.enabled = true
            app:OnSettingsChanged()
            H.True(app.sensors.running)
            H.True(app.sensors.frame.events.NAME_PLATE_UNIT_ADDED)
            H.True(app.sensors.frame.events.NAME_PLATE_UNIT_REMOVED)
            H.Equal(app:Status().detectionState, "active")
            H.True(app:Status().capabilities.nameplateEvents)
            H.Equal(app.diagnostics.counts.unsupported_events, 1)
            local healthy = enumerations()
            state:Unit("nameplate2", unit)
            state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
            H.Equal(app.sensors.active.nameplate2.guid, unit.guid)
            state.units.nameplate2, state.plates.nameplate2 = nil, nil
            state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
            H.Nil(app.sensors.active.nameplate2)
            state:Advance(1.25)
            H.Equal(enumerations(), healthy)
            app.ui:ShowDiagnostics()
            report = app.ui.copyFrame.edit:GetText()
            H.True(report:find("nameplateEvents=true", 1, true) ~= nil)
            H.True(report:find("detection=active", 1, true) ~= nil)
        end)
    end
end

H.Test("one optional registration failure is counted without limiting nameplate detection", function()
    local state, app, _, enumerations = eventRegistrationFixture("SPELL_TEXT_UPDATE", "false")
    H.Nil(app.sensors.frame.events.SPELL_TEXT_UPDATE)
    H.Equal(app.diagnostics.counts.unsupported_events, 1)
    H.True(app:Status().capabilities.nameplateEvents)
    H.Equal(app:Status().detectionState, "active")
    app.ui:OpenSettings("support")
    H.Nil(app.ui.supportStatus:GetText():find(app.ui:T("nameplateEventsLimited"), 1, true))
    local before = enumerations()
    state:Advance(1.25)
    H.Equal(enumerations(), before)
end)

for _, fixture in ipairs({
    { "enUS", "Toggle Nearby window", "Pause or resume alerts", "Toggle alert sound" },
    { "ruRU", "Показать или скрыть окно «Рядом»", "Приостановить или возобновить оповещения", "Включить или выключить звук оповещений" },
}) do
    H.Test("keyboard actions use game-language labels and local controls in " .. fixture[1], function()
        local bindingWrites = 0
        local function writeBinding() bindingWrites = bindingWrites + 1 end
        local state, _, app = setup(nil, function(mock)
            mock.locale = fixture[1]
            mock.api.SetBinding, mock.api.SaveBindings, mock.api.SetOverrideBinding = writeBinding, writeBinding, writeBinding
        end)
        local bind = assert(state.api.RivalGuard_Binding)
        H.Equal(state.api.BINDING_HEADER_RIVALGUARD, "RivalGuard")
        H.Equal(state.api.BINDING_NAME_RIVALGUARD_TOGGLE_NEARBY, fixture[2])
        H.Equal(state.api.BINDING_NAME_RIVALGUARD_TOGGLE_PAUSE, fixture[3])
        H.Equal(state.api.BINDING_NAME_RIVALGUARD_TOGGLE_MUTE, fixture[4])

        state.combat = true
        state:Fire("PLAYER_REGEN_DISABLED")
        H.True(app.ui.frame:IsShown())
        bind("nearby"); H.False(app.ui.frame:IsShown())
        bind("unknown"); H.False(app.ui.frame:IsShown())
        bind("nearby"); H.True(app.ui.frame:IsShown())

        app.ui:Alert({ kind = "sighting", contact = { id = "fixture", name = "Fixture" } })
        H.True(app.ui.banner:IsShown())
        bind("pause")
        H.Equal(app.engine.pausedUntil, state.clock.Now() + 600)
        H.False(app.ui.banner:IsShown())
        H.True(app.sensors.running)
        bind("pause"); H.Nil(app.engine.pausedUntil)
        bind("mute"); H.False(app.db:GetProfile().alerts.sound)
        bind("mute"); H.True(app.db:GetProfile().alerts.sound)
        H.Equal(bindingWrites, 0)
        H.Equal(#state.blocked, 0)
    end)
end

H.Test("keyboard dispatch is harmless before the addon initializes", function()
    local state = W.New()
    local RG = state:LoadTOC()
    local bind = assert(state.api.RivalGuard_Binding)
    bind("nearby"); bind("pause"); bind("mute"); bind("highlight")
    H.False(RG.instance.initialized)
    H.Nil(RG.instance.db)
end)

H.Test("runtime alert blocks follow live context without changing detection status", function()
    local state, _, app = setup()
    local profile = app.db:GetProfile()
    H.Nil(app:AlertBlock()); H.Equal(app:Status().state, "active")
    for _, fixture in ipairs({
        { instance = "arena", expected = "context_disabled", setting = "arena" },
        { zone = "sanctuary", expected = "sanctuary", setting = "sanctuary" },
        { resting = true, expected = "resting", setting = "resting" },
        { flight = true, expected = "flight", setting = "flight" },
    }) do
        state.instance, state.zonePVP, state.resting, state.flight = fixture.instance, fixture.zone, fixture.resting, fixture.flight
        state:Fire("ZONE_CHANGED_NEW_AREA")
        H.Equal(app:AlertBlock(), fixture.expected); H.Equal(app:Status().state, "active")
        profile.context[fixture.setting] = true
        app:OnSettingsChanged()
        H.Nil(app:AlertBlock())
        profile.context[fixture.setting] = false
    end
    state.flight = false
    state:Fire("PLAYER_FLAGS_CHANGED", "player")
    H.Nil(app:AlertBlock())
    state.api.IsInInstance = function() return H.Secret("instance membership"), H.Secret("instance type") end
    state:Fire("ZONE_CHANGED_NEW_AREA")
    H.Equal(app:AlertBlock(), "context_disabled"); H.Equal(app:Status().context.kind, "unknown")
end)

H.Test("runtime alert block reports pause and global output controls", function()
    local state, _, app = setup()
    local profile = app.db:GetProfile()
    app.engine:Pause(2)
    H.Equal(app:AlertBlock(), "paused"); H.Equal(app:Status().state, "paused")
    H.Equal(app:Status().detectionState, "active")
    state.cvars.nameplateShowEnemies = false
    H.Equal(app:Status().detectionState, "limited"); H.Equal(app:Status().state, "paused")
    state.cvars.nameplateShowEnemies = true
    state:Advance(2.1)
    H.Nil(app:AlertBlock())
    profile.alerts.sound, profile.alerts.banner = false, false
    app:OnSettingsChanged()
    H.Equal(app:AlertBlock(), "outputs_disabled"); H.Equal(app:Status().state, "active")
    profile.alerts.sound = true
    for kind in pairs(profile.alerts.sounds) do profile.alerts.sounds[kind] = "none" end
    H.Equal(app:AlertBlock(), "outputs_disabled")
    profile.alerts.sounds.wave = "ready"
    H.Nil(app:AlertBlock())
    profile.alerts.enabled = false
    H.Equal(app:AlertBlock(), "disabled"); H.Equal(app:Status().state, "active")
    profile.enabled = false
    app:OnSettingsChanged()
    H.Equal(app:AlertBlock(), "disabled"); H.Equal(app:Status().state, "disabled")
    H.Equal(app:Status().detectionState, "disabled")
end)

local RULE_SOUND_KITS = { MAP_PING = 22001, RAID_WARNING = 22002, READY_CHECK = 22003,
    TELL_MESSAGE = 22004, IG_QUEST_LIST_COMPLETE = 22005 }

local function ruleSoundFixture()
    local function soundKits(mock) mock.api.SOUNDKIT = RULE_SOUND_KITS end
    local state, _, app = setup(nil, soundKits)
    local profile = app.db:GetProfile()
    for event in pairs(profile.alerts.sounds) do profile.alerts.sounds[event] = "none" end
    profile.alerts.channel = "Dialog"
    return state, app, profile, soundKits
end

local function soundRule(name, cue, priority)
    return { name = name, enabled = true, event = "sighting", action = "alert", priority = priority,
        classes = {}, cooldown = 30, sound = true, banner = true, soundCue = cue }
end

local function seeSoundRuleRival(state, index, class)
    local token = "nameplate" .. index
    state:Unit(token, { guid = "Player-RuleCue" .. index, name = "Sound rival " .. index,
        class = class or "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", token)
end

H.Test("the winning rule's cue is audible with event sounds off and contributes to alert status", function()
    local state, app, profile = ruleSoundFixture()
    profile.alerts.banner = false
    profile.rules = { soundRule("First match", "warning", 70), soundRule("Higher priority match", "quest", 90) }
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    state:Advance(0.5)
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)
    H.Equal(state.sounds[1].channel, "Dialog")
    H.Equal(app.engine.history[1].reason, "custom_rule")
    H.False(app.ui.banner:IsShown())
    H.Nil(app:AlertBlock())
    H.Nil(app:AlertBlock(true))

    profile.alerts.sounds.sighting = "ping"
    app:OnSettingsChanged()
    state:Advance(1.5)
    seeSoundRuleRival(state, 2)
    state:Advance(0.5)
    H.Equal(#state.sounds, 2)
    H.Equal(state.sounds[2].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)

    profile.alerts.sounds.sighting = "none"
    for _, rule in ipairs(profile.rules) do rule.context = "battleground" end
    app:OnSettingsChanged()
    H.Equal(app:AlertBlock(), "outputs_disabled")
    H.Equal(app:AlertBlock(true), "outputs_disabled")
end)

H.Test("a grouped alert uses its configured wave cue instead of individual rule cues", function()
    local state, app, profile = ruleSoundFixture()
    profile.alerts.sounds.wave = "ready"
    local rogue, hunter = soundRule("Rogue cue", "warning", 50), soundRule("Hunter cue", "quest", 55)
    rogue.classes, hunter.classes = { ROGUE = true }, { HUNTER = true }
    profile.rules = { rogue, hunter }
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    seeSoundRuleRival(state, 2, "HUNTER")
    seeSoundRuleRival(state, 3)
    state:Advance(1.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "wave")
    H.Equal(app.ui.activeBanner.count, 3)
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.READY_CHECK)
end)

for _, wave in ipairs({ "disabled", "banner", "sound" }) do
    H.Test("a full wave uses available outputs when the group output is " .. wave, function()
        local state, app, profile = ruleSoundFixture()
        profile.alerts.banner = wave == "banner"
        profile.display.streamer = wave == "banner"
        profile.alerts.sounds.sighting = "ping"
        profile.alerts.sounds.wave = wave == "sound" and "ready" or "none"
        local hunter = soundRule("Hunter cue", "quest", 60)
        hunter.classes = { HUNTER = true }
        profile.rules = { hunter }
        app:OnSettingsChanged()
        seeSoundRuleRival(state, 1, "ROGUE")
        seeSoundRuleRival(state, 2, "HUNTER")
        seeSoundRuleRival(state, 3, "MAGE")
        state:Advance(1.5)
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].kind, wave == "disabled" and "sighting" or "wave")
        H.Equal(#state.sounds, wave == "banner" and 0 or 1)
        H.Equal(app.ui.banner:IsShown(), wave == "banner")
        if wave == "disabled" then
            H.Equal(state.sounds[1].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)
            for _, contact in ipairs(app.engine:Snapshot()) do
                local played = contact.class == "HUNTER"
                local outcome = app:Explain(contact).lastSound
                H.Equal(outcome.status, played and "playback_requested" or "sound_gap")
                H.Equal(outcome.soundCue, played and "quest" or "ping")
            end
        elseif wave == "sound" then
            H.Equal(state.sounds[1].id, RULE_SOUND_KITS.READY_CHECK)
        else
            H.Equal(app.ui.activeBanner.count, 3)
            H.True(app.ui.banner.body:GetText():find(app.ui:F("waveBody", 3), 1, true) ~= nil)
            H.Nil(app.ui.banner.body:GetText():find("Sound rival", 1, true))
        end
    end)
end

H.Test("a single wave-only sighting stays silent", function()
    local state, app, profile = ruleSoundFixture()
    profile.alerts.banner = false
    profile.alerts.sounds.wave = "ready"
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    state:Advance(1.5)
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#state.sounds, 0)
    H.False(app.ui.banner:IsShown())
    H.Equal(#app.engine.history, 0)
    H.Nil(app.engine:LastSoundOutcome(app.engine:Snapshot()[1].id))
end)

for _, case in ipairs({ { "unconfirmed", "playback_unconfirmed", "ready" },
    { "paced", "sound_gap", "ready" }, { "banner only", "not_requested" } }) do
    H.Test("wave sound outcomes stay with the members (" .. case[1] .. ")", function()
        local state, app, profile = ruleSoundFixture()
        profile.alerts.classes = { ROGUE = true }
        profile.alerts.sounds.sighting = "ping"
        profile.alerts.sounds.wave = case[3] or "none"
        app:OnSettingsChanged()
        if case[1] == "unconfirmed" then
            local play = state.api.PlaySound
            state.api.PlaySound = function(...)
                play(...)
                return false
            end
        elseif case[1] == "paced" then
            seeSoundRuleRival(state, 5)
            state.clock.Advance(0.85)
            app.engine:Tick()
            H.Equal(app.engine.history[1].kind, "sighting")
            H.Equal(state.sounds[1].id, RULE_SOUND_KITS.MAP_PING)
        end
        for index = 1, 3 do seeSoundRuleRival(state, index) end
        seeSoundRuleRival(state, 4, "HUNTER")
        state.clock.Advance(0.85)
        app.engine:Tick()
        H.Equal(app.engine.history[#app.engine.history].kind, "wave")
        H.Equal(app.ui.activeBanner.kind, "wave")
        H.Equal(#state.sounds, case[1] == "banner only" and 0 or 1)
        for _, contact in ipairs(app.engine:Snapshot()) do
            local outcome = app.engine:LastSoundOutcome(contact.id)
            if contact.name == "Sound rival 4" then H.Nil(outcome)
            elseif contact.name == "Sound rival 5" then H.Equal(outcome.kind, "sighting")
            else
                H.Equal(outcome.kind, "wave")
                H.Equal(outcome.status, case[2])
                H.Equal(outcome.soundCue, case[3])
            end
        end
    end)
end

H.Test("a listed-only rule cue warns for a known Watch identity and keeps ordinary status quiet", function()
    local state, app, profile = ruleSoundFixture()
    profile.alerts.banner = false
    local rule = soundRule("Watch cue", "whisper", 90)
    rule.list = "listed"
    profile.rules = { rule }
    assert(app.db:SetList("guid:Player-RuleCue1", "watch", nil, { name = "Sound rival 1" }))
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1, "UNKNOWN_FIXTURE")
    seeSoundRuleRival(state, 2)
    state:Advance(1.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "watch")
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.TELL_MESSAGE)
    H.Nil(app:AlertBlock())
    H.Equal(app:AlertBlock(true), "outputs_disabled")
end)

for _, blocker in ipairs({ "global mute", "silent rule", "unidentified class" }) do
    H.Test("a rule cue honors " .. blocker, function()
        local state, app, profile = ruleSoundFixture()
        local rule = soundRule("Quiet unless eligible", "quest", 80)
        profile.rules = { rule }
        if blocker == "global mute" then profile.alerts.sound = false end
        if blocker == "silent rule" then rule.sound = false end
        app:OnSettingsChanged()
        seeSoundRuleRival(state, 1, blocker == "unidentified class" and "UNKNOWN_FIXTURE" or nil)
        state:Advance(0.5)
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].reason, "custom_rule")
        H.True(app.ui.banner:IsShown())
        H.Equal(#state.sounds, 0)
        if blocker ~= "unidentified class" then
            profile.alerts.banner = false
            app:OnSettingsChanged()
            H.Equal(app:AlertBlock(), "outputs_disabled")
            H.Equal(app:AlertBlock(true), "outputs_disabled")
        end
    end)
end

H.Test("the event sound picker exposes all cues and separates listening from choosing", function()
    local state, app, profile = ruleSoundFixture()
    local ui = app.ui
    profile.alerts.sound = false
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    local pending = state.RG.Codec.Encode(app.engine.pending)
    local saved = app.db:ExportProfile()
    H.Equal(#app.engine.pending, 1)
    ui:OpenSettings("alerts")
    local control = settingButton(ui, "alerts.sounds.stealth")
    local picker = openSoundPicker(ui, control)
    H.Equal(picker.feedback:GetText(), "")
    H.Equal(#picker.rows, 6)
    for _, value in ipairs({ "none", "ping", "warning", "ready", "whisper", "quest" }) do
        local row = soundPickerRow(picker, value)
        H.True(row.choice:IsShown())
        if value ~= "none" then H.True(row.listen:IsShown()); H.True(row.listen.enabled) end
    end
    local silent = soundPickerRow(picker, "none")
    H.True(not silent.listen:IsShown() or not silent.listen.enabled)
    local quest = soundPickerRow(picker, "quest")
    quest.listen:Click()
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)
    H.Equal(state.sounds[1].channel, "Dialog")
    local function feedback(status, cue)
        H.Equal(picker.feedback:GetText(), ui:T(status) .. "\n" .. ui:F("soundPreviewSelection", ui:T(cue), ui:T("dialog")))
    end
    feedback("lastSoundRequested", "soundQuest")
    local play = state.api.PlaySound
    state.api.PlaySound = function(...)
        play(...)
        return false
    end
    soundPickerRow(picker, "ready").listen:Click()
    H.Equal(#state.sounds, 2)
    H.Equal(state.sounds[2].id, RULE_SOUND_KITS.READY_CHECK)
    feedback("lastSoundUnconfirmed", "soundReady")
    H.Equal(app.db:ExportProfile(), saved)
    H.Equal(state.RG.Codec.Encode(app.engine.pending), pending)
    H.Equal(#app.engine.history, 0)
    H.Nil(app.engine:LastSoundOutcome(app.engine:Snapshot()[1].id))
    H.Equal(profile.alerts.sounds.stealth, "none")
    H.False(profile.alerts.sound)
    H.True(picker:IsShown())
    picker.close:Click()
    quest.choice:Click()
    quest.listen:Click()
    H.False(picker:IsShown())
    H.Equal(picker.feedback:GetText(), "")
    H.Equal(profile.alerts.sounds.stealth, "none")
    H.Equal(#state.sounds, 2)

    openSoundPicker(ui, control)
    H.Equal(picker.feedback:GetText(), "")
    soundPickerRow(picker, "quest").choice:Click()
    H.False(picker:IsShown())
    H.Equal(profile.alerts.sounds.stealth, "quest")
    H.Equal(profile.alerts.sounds.sighting, "none")
    H.Equal(#state.sounds, 2)
    H.Equal(app.engine.counters.alerts, 0)
end)

H.Test("direct Listen identifies no cue and confirms explicitly tested event playback", function()
    local state, app, profile = ruleSoundFixture()
    local ui = app.ui
    profile.alerts.sound = false
    app:OnSettingsChanged()
    ui:OpenSettings("alerts")
    local control = settingButton(ui, "alerts.sounds.sighting")
    local _, _, _, _, rowY = control:GetPoint(1)
    local listen
    for _, child in ipairs(ui.pages.alerts.children) do
        local _, _, _, _, y = child:GetPoint(1)
        if y == rowY and child.label and child.label:GetText() == ui:T("previewSound") then listen = child; break end
    end
    assert(listen):Click()
    local tooltip = state.api.GameTooltip
    H.Equal(tooltip.owner, listen)
    H.Equal(tooltip.lines[#tooltip.lines], ui:T("soundPreviewNone"))
    H.Equal(#state.sounds, 0)
    pickSound(ui, control, "warning")
    local saved = app.db:ExportProfile()
    listen:Click()
    local feedback = tooltip.lines[#tooltip.lines]
    H.True(feedback:find(ui:F("soundPreviewSelection", ui:T("soundWarning"), ui:T("dialog")), 1, true) ~= nil)
    H.True(feedback:find(ui:T("lastSoundRequested"), 1, true) ~= nil)
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.RAID_WARNING)
    H.Equal(state.sounds[1].channel, "Dialog")
    H.Equal(app.db:ExportProfile(), saved)
    H.Equal(#app.engine.history, 0); H.Equal(#app.engine.pending, 0)
end)

H.Test("a picker opened for a previous profile cannot overwrite either profile", function()
    local state, app, original = ruleSoundFixture()
    local ui, db = app.ui, app.db
    app:OnSettingsChanged()
    local other = assert(db:CreateProfile("Other sounds"))
    ui:OpenSettings("alerts")
    local picker = openSoundPicker(ui, settingButton(ui, "alerts.sounds.sighting"))
    local quest = soundPickerRow(picker, "quest")
    assert(db:SetProfile("Other sounds"))
    app:ProfileChanged()
    quest.choice:Click()
    quest.listen:Click()
    H.False(picker:IsShown())
    H.Equal(original.alerts.sounds.sighting, "none")
    H.Equal(other.alerts.sounds.sighting, "ping")
    H.Equal(#state.sounds, 0)
end)

H.Test("advanced rule cue preview is detached and saving makes the cue survive reload", function()
    local state, app, profile, soundKits = ruleSoundFixture()
    profile.alerts.sound, profile.alerts.banner = false, false
    app:OnSettingsChanged()
    local ui = app.ui
    ui:OpenRules()
    local dialog = ui.rulesDialog
    H.False(dialog.previewCue.enabled)
    pickSound(ui, dialog.soundCue, "warning")
    H.True(dialog.previewCue.enabled)
    dialog.previewCue:Click()
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.RAID_WARNING)
    H.Equal(state.sounds[1].channel, "Dialog")
    local tooltip = state.api.GameTooltip
    H.Equal(tooltip.owner, dialog.previewCue)
    H.True(tooltip.lines[#tooltip.lines]:find(ui:F("soundPreviewSelection", ui:T("soundWarning"), ui:T("dialog")), 1, true) ~= nil)
    H.True(tooltip.lines[#tooltip.lines]:find(ui:T("lastSoundRequested"), 1, true) ~= nil)
    H.Equal(#profile.rules, 0)
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#app.engine.history, 0)
    H.False(ui.banner:IsShown())
    dialog.sound:Click()
    H.False(dialog.previewCue.enabled)
    dialog.previewCue:Click()
    H.Equal(#state.sounds, 1)
    dialog.sound:Click()
    H.True(dialog.previewCue.enabled)
    dialog.save:Click()
    H.Equal(profile.rules[1].soundCue, "warning")

    state:Fire("PLAYER_LOGOUT")
    local fresh, _, reloaded = setup(state.api.RivalGuardDB, soundKits)
    H.Equal(reloaded.db:GetProfile().rules[1].soundCue, "warning")
    H.Equal(reloaded:AlertBlock(true), "outputs_disabled")
    fresh.api.RivalGuard_Binding("mute")
    H.Nil(reloaded:AlertBlock(true))
    seeSoundRuleRival(fresh, 1)
    fresh:Advance(1.5)
    H.Equal(reloaded.engine.counters.alerts, 1)
    H.Equal(#fresh.sounds, 1)
    H.Equal(fresh.sounds[1].id, RULE_SOUND_KITS.RAID_WARNING)
end)

H.Test("the rule sound picker previews and selects on its own draft only", function()
    local state, app, profile = ruleSoundFixture()
    profile.alerts.sound = false
    app:OnSettingsChanged()
    local ui = app.ui
    ui:OpenRules()
    local dialog = ui.rulesDialog
    local picker = openSoundPicker(ui, dialog.soundCue)
    H.Equal(#picker.rows, 6)
    local inherited = soundPickerRow(picker, "inherit")
    H.True(inherited.choice:IsShown())
    H.True(not inherited.listen:IsShown() or not inherited.listen.enabled)
    local warning = soundPickerRow(picker, "warning")
    warning.listen:Click()
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.RAID_WARNING)
    H.Equal(ui.dialogs.ruleDraft.soundCue, "inherit")
    H.Equal(#profile.rules, 0)
    warning.choice:Click()
    H.False(picker:IsShown())
    H.Equal(ui.dialogs.ruleDraft.soundCue, "warning")
    H.Equal(#profile.rules, 0)

    picker = openSoundPicker(ui, dialog.soundCue)
    soundPickerRow(picker, "inherit").choice:Click()
    H.Equal(ui.dialogs.ruleDraft.soundCue, "inherit")
    picker = openSoundPicker(ui, dialog.soundCue)
    warning = soundPickerRow(picker, "warning")
    local oldDraft = ui.dialogs.ruleDraft
    for _, child in ipairs(dialog.children) do
        if child.label and child.label:GetText() == ui:T("newRule") then child:Click(); break end
    end
    H.True(ui.dialogs.ruleDraft ~= oldDraft)
    warning.choice:Click()
    warning.listen:Click()
    H.False(picker:IsShown())
    H.Equal(ui.dialogs.ruleDraft.soundCue, "inherit")
    H.Equal(#profile.rules, 0)
    H.Equal(#state.sounds, 1)
end)

H.Test("a new rule defaults to confirmed classes and leaves unknown arrivals on the global schedule", function()
    local state, app, profile = ruleSoundFixture()
    local ui = app.ui
    profile.alerts.sounds.watch = "ready"
    app:OnSettingsChanged()
    ui:OpenRules()
    local dialog = ui.rulesDialog
    H.True(dialog.knownClassOnly:GetChecked())
    for _, chip in ipairs(dialog.classes) do
        if chip.class == "ROGUE" then chip.frame:Click("RightButton"); break end
    end
    dialog.priority:SetValue(80)
    pickSound(ui, dialog.soundCue, "quest")
    dialog.previewCue:Click()
    H.Equal(#state.sounds, 1)
    H.Equal(#profile.rules, 0)
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#app.engine.history, 0)
    H.True(profile.alerts.unknownClass)
    dialog.save:Click()
    H.True(profile.rules[1].knownClassOnly)

    seeSoundRuleRival(state, 1, "UNKNOWN_FIXTURE")
    local unknown = app.engine:Snapshot()[1]
    H.Nil(unknown.class)
    H.Equal(app:Explain(unknown).reason, "event_matched")
    H.False(app:Explain(unknown).sound)
    state.clock.Advance(0.2)
    seeSoundRuleRival(state, 2, "ROGUE")
    state.clock.Advance(0.05)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].reason, "custom_rule")
    H.Equal(ui.activeBanner.name, "Sound rival 2")
    H.Equal(#state.sounds, 2)
    H.Equal(state.sounds[2].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)
    state.clock.Advance(0.6)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 2)
    H.Equal(app.engine.history[2].id, unknown.id)
    H.Equal(app.engine.history[2].reason, "event_matched")
    H.Equal(#state.sounds, 2)

    state.clock.Advance(1.5)
    assert(app.db:SetList("guid:Player-RuleCue3", "watch", nil, { name = "Watched rival" }))
    seeSoundRuleRival(state, 3, "UNKNOWN_FIXTURE")
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 3)
    H.Equal(app.engine.history[3].kind, "watch")
    H.Equal(app.engine.history[3].reason, "watch_list")
    H.Equal(#state.sounds, 3)
    H.Equal(state.sounds[3].id, RULE_SOUND_KITS.READY_CHECK)
end)

H.Test("a confirmed-class suppressing rule suppresses only the matching known Rogue", function()
    local state, app, profile = ruleSoundFixture()
    local rule = soundRule("Do not warn for confirmed rogues", nil, 90)
    rule.action, rule.classes, rule.knownClassOnly = "suppress", { ROGUE = true }, true
    profile.rules = { rule }
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1, "ROGUE")
    local known = app.engine:Snapshot()[1]
    H.Equal(app:Explain(known).reason, "custom_suppressed")
    seeSoundRuleRival(state, 2, "UNKNOWN_FIXTURE")
    state:Advance(1.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].reason, "event_matched")
    H.Equal(app.ui.activeBanner.name, "Sound rival 2")
    H.Equal(#state.sounds, 0)
end)

for _, legacy in ipairs({ false, true }) do
    H.Test("the rule editor and reload keep global unknown behavior for " .. (legacy and "legacy rules" or "explicit opt-out"), function()
        local state, app, profile, soundKits = ruleSoundFixture()
        local rule = soundRule("Rogues when possible", "quest", 90)
        rule.classes = { ROGUE = true }
        if not legacy then rule.knownClassOnly = true end
        profile.rules = { rule }
        app:OnSettingsChanged()
        local ui = app.ui
        ui:OpenRules()
        local dialog = ui.rulesDialog
        H.Equal(dialog.knownClassOnly:GetChecked(), not legacy)
        if legacy then dialog.nameInput:SetText("Renamed legacy rule")
        else dialog.knownClassOnly:Click() end
        H.False(dialog.knownClassOnly:GetChecked())
        H.Equal(profile.rules[1], rule)
        H.Equal(profile.rules[1].knownClassOnly, not legacy and true or nil)
        dialog.save:Click()
        H.Nil(profile.rules[1].knownClassOnly)
        if legacy then H.Equal(profile.rules[1].name, "Renamed legacy rule") end

        state:Fire("PLAYER_LOGOUT")
        local fresh, _, reloaded = setup(state.api.RivalGuardDB, soundKits)
        local active = reloaded.db:GetProfile()
        H.Nil(active.rules[1].knownClassOnly)
        seeSoundRuleRival(fresh, 1, "UNKNOWN_FIXTURE")
        local unknown = reloaded.engine:Snapshot()[1]
        H.Equal(reloaded:Explain(unknown).reason, "custom_rule")
        fresh:Advance(0.5)
        H.Equal(reloaded.engine.counters.alerts, 1)
        H.Equal(reloaded.engine.history[1].reason, "custom_rule")
        H.Equal(#fresh.sounds, 0)

        active.alerts.unknownClass = false
        reloaded:OnSettingsChanged()
        seeSoundRuleRival(fresh, 2, "UNKNOWN_FIXTURE")
        fresh:Advance(1.5)
        H.Equal(reloaded.engine.counters.alerts, 1)
        H.Equal(#fresh.sounds, 0)
    end)
end

local function checkRuleDraft(ui)
    ui.rulesDialog.checkDraft:Click()
    local result = assert(ui.ruleCheckDialog, "rule check did not open")
    H.True(result:IsShown())
    H.Equal(#result.rows, 3)
    return result
end

H.Test("a combined-arrivals draft checks each concrete event at the same distance without saving", function()
    local state, app, profile = ruleSoundFixture()
    profile.locale = "ruRU"
    app:OnSettingsChanged()
    local ui, codec = app.ui, state.RG.Codec
    ui:OpenRules()
    local dialog = ui.rulesDialog
    dialog.event:Click()
    dialog.event:Click()
    H.Equal(ui.dialogs.ruleDraft.event, "arrivals")
    dialog.conditions:Click()
    dialog.range:SetValue(25)
    local saved = assert(codec.Encode(state.api.RivalGuardDB))
    local draft = assert(codec.Encode(ui.dialogs.ruleDraft))
    local preview = checkRuleDraft(ui)
    local function scope(key, event, distance)
        H.Equal(preview.scope:GetText(), ui:F(key, ui:T(event), ui:T("world"), ui:T("listUnlisted"), distance))
        H.Equal(preview.rows[1].result:GetText(), ui:T("ruleCheckDraftWins"))
    end
    H.True(preview.eventButtons.sighting:IsShown())
    H.True(preview.eventButtons.returning:IsShown())
    scope("ruleCheckScope", "eventSighting", 20)
    preview.distanceButtons.threshold:Click()
    local interval = ui:F("rangeBracket", 21, 29)
    scope("ruleCheckScopeDistance", "eventSighting", interval)
    preview.eventButtons.returning:Click()
    scope("ruleCheckScopeDistance", "eventReturning", interval)
    preview.eventButtons.sighting:Click()
    scope("ruleCheckScopeDistance", "eventSighting", interval)
    H.Equal(codec.Encode(state.api.RivalGuardDB), saved)
    H.Equal(codec.Encode(ui.dialogs.ruleDraft), draft)
    H.Equal(#app.engine:Snapshot(), 0)
    H.Equal(#app.engine.pending, 0)
    H.Equal(#app.engine.history, 0)
    H.Equal(#state.sounds, 0)
end)

H.Test("checking a strict Rogue draft is isolated from live observations, audio, and the sample", function()
    local state, app, profile = ruleSoundFixture()
    local ui, RG = app.ui, state.RG
    profile.locale = "ruRU"
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1, "HUNTER")
    app:Demo()
    local sample = ui.rows[1].contact
    H.True(sample.preview)
    H.Equal(sample.class, "ROGUE")
    local liveSampleBefore = app:Explain(sample)
    H.True(liveSampleBefore.allowed)
    H.Equal(liveSampleBefore.reason, "event_matched")

    ui:OpenRules()
    local dialog = ui.rulesDialog
    for _, chip in ipairs(dialog.classes) do
        if chip.class == "ROGUE" then chip.frame:Click("RightButton"); break end
    end
    H.True(dialog.knownClassOnly:GetChecked())
    dialog.action:Click()
    H.Equal(ui.dialogs.ruleDraft.action, "suppress")

    local persistentRoot = state.api.RivalGuardDB
    local savedBefore = assert(RG.Codec.Encode(persistentRoot))
    local contactsBefore = assert(RG.Codec.Encode(app.engine:Snapshot()))
    local pendingBefore = assert(RG.Codec.Encode(app.engine.pending))
    local observationsBefore, soundsBefore = app.engine.counters.observations, #state.sounds
    local banner, activeProfile = ui.activeBanner, app.db:GetActiveProfileName()
    local check = checkRuleDraft(ui)
    H.Equal(app.db:GetActiveProfileName(), activeProfile)
    H.Equal(state.api.RivalGuardDB, persistentRoot)
    H.Equal(app.db:GetProfile(), profile)
    H.Equal(RG.Codec.Encode(persistentRoot), savedBefore)
    H.Equal(RG.Codec.Encode(app.engine:Snapshot()), contactsBefore)
    H.Equal(RG.Codec.Encode(app.engine.pending), pendingBefore)
    H.Equal(app.engine.counters.observations, observationsBefore)
    H.Equal(#app.engine.history, 0); H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#state.sounds, soundsBefore)
    H.Equal(ui.activeBanner, banner)
    local liveSampleAfter = app:Explain(sample)
    H.Equal(liveSampleAfter.allowed, liveSampleBefore.allowed)
    H.Equal(liveSampleAfter.reason, liveSampleBefore.reason)

    local samples = { RG.Locale.Class("ROGUE", profile.locale), RG.Locale.Class("HUNTER", profile.locale), ui:T("unknownClass") }
    for index, row in ipairs(check.rows) do
        H.True(row.sample:IsShown())
        H.Equal(row.sample:GetText(), samples[index])
        H.Equal(row.result:GetText(), ui:T(index == 1 and "ruleCheckDraftWins" or "ruleCheckStandard"))
        H.Equal(row.effect:GetText(), index == 1 and RG.Locale.Reason("custom_suppressed", profile.locale) or ui:T("explanationBannerOnly"))
    end
    H.Equal(check.scope:GetText(), ui:F("ruleCheckScope", ui:T("eventSighting"), ui:T("world"), ui:T("listUnlisted"), 20))
end)

H.Test("rule checking respects saved tie order and replaces an edited rule in place", function()
    local state, app, profile = ruleSoundFixture()
    local first, second = soundRule("Same displayed name", "ready", 90), soundRule("Same displayed name", "quest", 90)
    profile.rules = { first, second }
    app:OnSettingsChanged()
    local ui = app.ui
    ui:OpenRules()
    local dialog = ui.rulesDialog
    dialog.rows[2]:Click()
    local check = checkRuleDraft(ui)
    local otherWins = ui:F("ruleCheckOtherWins", first.name)
    local ready = ui:T("explanationSoundBanner") .. " · " .. ui:T("soundReady")
    local quest = ui:T("explanationSoundBanner") .. " · " .. ui:T("soundQuest")
    H.Equal(check.rows[1].result:GetText(), otherWins)
    H.Equal(check.rows[1].effect:GetText(), ready)
    dialog.priority:SetValue(95)
    ui:Refresh()
    H.False(check:IsShown())
    check = checkRuleDraft(ui)
    H.Equal(check.rows[1].result:GetText(), ui:T("ruleCheckDraftWins"))
    H.Equal(check.rows[1].effect:GetText(), quest)
    H.Equal(profile.rules[2], second)
    H.Equal(second.priority, 90)

    dialog.rows[1]:Click()
    dialog.priority:SetValue(70)
    check = checkRuleDraft(ui)
    H.Equal(check.rows[1].result:GetText(), otherWins)
    H.Equal(check.rows[1].effect:GetText(), quest)
    H.Equal(profile.rules[1], first)
    H.Equal(first.priority, 90)
    H.Equal(#state.sounds, 0)
    H.Equal(#app.engine.history, 0)
    assert(app.db:CreateProfile("Other profile"))
    assert(app.db:SetProfile("Other profile"))
    app:ProfileChanged()
    H.False(check:IsShown())
    H.Equal(#app.db:GetProfile().rules, 0)
end)

H.Test("draft range scenarios distinguish possible, confirmed, and unreadable range", function()
    local state, app, profile = ruleSoundFixture()
    local ui, RG = app.ui, state.RG
    profile.locale = "ruRU"
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1, "ROGUE")
    ui:OpenRules()
    local dialog = ui.rulesDialog
    dialog.conditions:Click()
    dialog.range:SetValue(25)
    H.Equal(ui.dialogs.ruleDraft.rangePolicy, "possible")
    local savedBefore = assert(RG.Codec.Encode(state.api.RivalGuardDB))
    local pendingBefore = assert(RG.Codec.Encode(app.engine.pending))
    local draftBefore = assert(RG.Codec.Encode(ui.dialogs.ruleDraft))
    local check = checkRuleDraft(ui)
    local function result(expected) H.Equal(check.rows[1].result:GetText(), ui:T(expected)) end
    local function scope(key, distance)
        H.Equal(check.scope:GetText(), ui:F(key, ui:T("eventSighting"), ui:T("world"), ui:T("listUnlisted"), distance))
    end
    local function choose(mode, expected)
        check.distanceButtons[mode]:Click()
        H.True(check:IsShown())
        result(expected)
        H.Equal(check.distanceButtons[mode].label:GetText(), ui:T("ruleCheckDistance_" .. mode))
    end
    result("ruleCheckDraftWins")
    scope("ruleCheckScope", 20)
    choose("threshold", "ruleCheckDraftWins")
    scope("ruleCheckScopeDistance", ui:F("rangeBracket", 21, 29))
    choose("far", "ruleCheckStandard")
    scope("ruleCheckScope", 26)
    choose("unknown", "ruleCheckStandard")
    scope("ruleCheckScopeDistance", ui:T("rangeUnknown"))
    choose("near", "ruleCheckDraftWins")
    scope("ruleCheckScope", 20)
    H.Equal(RG.Codec.Encode(state.api.RivalGuardDB), savedBefore)
    H.Equal(RG.Codec.Encode(app.engine.pending), pendingBefore)
    H.Equal(RG.Codec.Encode(ui.dialogs.ruleDraft), draftBefore)
    H.Equal(#state.sounds, 0)
    H.Equal(#app.engine.history, 0)

    dialog.rangePolicy:Click()
    H.Equal(ui.dialogs.ruleDraft.rangePolicy, "confirmed")
    check.distanceButtons.far:Click()
    H.False(check:IsShown())
    check = checkRuleDraft(ui)
    result("ruleCheckDraftWins")
    choose("threshold", "ruleCheckStandard")
    choose("unknown", "ruleCheckStandard")

    dialog.rangeUnknown:Click()
    ui:Refresh()
    H.False(check:IsShown())
    check = checkRuleDraft(ui)
    choose("unknown", "ruleCheckDraftWins")
    H.Equal(#profile.rules, 0)
    H.Equal(RG.Codec.Encode(state.api.RivalGuardDB), savedBefore)
    H.Equal(RG.Codec.Encode(app.engine.pending), pendingBefore)
    H.Equal(#state.sounds, 0)

    dialog.range:SetValue(0)
    check = checkRuleDraft(ui)
    H.False(check.distanceButtons.threshold.enabled)
    check.distanceButtons.threshold:Click()
    scope("ruleCheckScope", 20)
    choose("far", "ruleCheckDraftWins")
    scope("ruleCheckScope", 45)
end)

H.Test("draft check uses the earlier global range gate without bypassing the draft gate", function()
    local state, app, profile = ruleSoundFixture()
    local ui = app.ui
    profile.range.enabled, profile.range.yards, profile.range.policy, profile.range.unknown = true, 30, "confirmed", false
    app:OnSettingsChanged()
    ui:OpenRules()
    local dialog = ui.rulesDialog
    dialog.conditions:Click()
    dialog.range:SetValue(40)
    dialog.rangeUnknown:Click()
    local check = checkRuleDraft(ui)
    H.Equal(check.rows[1].result:GetText(), ui:T("ruleCheckDraftWins"))
    for _, case in ipairs({ { "threshold", "range_unconfirmed" }, { "far", "range_outside" }, { "unknown", "range_unknown" } }) do
        check.distanceButtons[case[1]]:Click()
        if case[1] == "threshold" then
            H.Equal(check.scope:GetText(), ui:F("ruleCheckScopeDistance", ui:T("eventSighting"), ui:T("world"), ui:T("listUnlisted"), ui:F("rangeBracket", 26, 34)))
        elseif case[1] == "far" then
            H.Equal(check.scope:GetText(), ui:F("ruleCheckScope", ui:T("eventSighting"), ui:T("world"), ui:T("listUnlisted"), 31))
        end
        H.Equal(check.rows[1].result:GetText(), ui:T("ruleCheckNoMatch"))
        H.Equal(check.rows[1].effect:GetText(), state.RG.Locale.Reason(case[2], profile.locale))
    end

    profile.range.policy, profile.range.unknown = "possible", true
    app:OnSettingsChanged()
    H.False(check:IsShown())
    dialog.rangePolicy:Click()
    H.Equal(ui.dialogs.ruleDraft.rangePolicy, "confirmed")
    check = checkRuleDraft(ui)
    check.distanceButtons.threshold:Click()
    H.Equal(check.rows[1].result:GetText(), ui:T("ruleCheckDraftWins"))
    check.distanceButtons.unknown:Click()
    H.Equal(check.rows[1].result:GetText(), ui:T("ruleCheckDraftWins"))

    dialog.rangeUnknown:Click()
    ui:Refresh()
    H.False(check:IsShown())
    check = checkRuleDraft(ui)
    check.distanceButtons.unknown:Click()
    H.Equal(check.rows[1].result:GetText(), ui:T("ruleCheckStandard"))
    H.Equal(#profile.rules, 0)
    H.Equal(#state.sounds, 0)
end)

for _, locale in ipairs({ "enUS", "ruRU" }) do
    H.Test("a single-class sound rule can be drafted and named from Alerts in " .. locale, function()
        local state, app, profile = ruleSoundFixture()
        local ui, L = app.ui, state.RG.Locale
        profile.locale = locale
        profile.alerts.classes, profile.alerts.banner = { MAGE = true }, false
        app:OnSettingsChanged()
        ui:OpenSettings("alerts")
        local function buttonIn(frame, key)
            for _, child in ipairs(frame.children) do
                if child.label and child.label:GetText() == ui:T(key) then return child end
            end
            error("missing button " .. key)
        end
        local launcher = buttonIn(ui.pages.alerts, "rules")
        launcher:Click()
        local dialog = ui.rulesDialog
        H.True(dialog:IsShown())
        H.Equal(dialog.nameInput:GetText(), ui:T("ruleNewName"))
        local chips = {}
        for _, chip in ipairs(dialog.classes) do chips[chip.class] = chip.frame end
        local function generated(class) return ui:F("classRuleName", L.Class(class, locale)) end
        local function solo(class)
            chips[class]:Click("RightButton")
            local classes = ui.dialogs.ruleDraft.classes
            H.Equal(state.RG.Util.Count(classes), 1)
            H.True(classes[class])
        end

        solo("ROGUE")
        H.Equal(dialog.nameInput:GetText(), generated("ROGUE"))
        H.Equal(ui.advancedRulesButton, launcher)
        H.Equal(chips.ROGUE.clickButtons[1], "LeftButtonUp")
        H.Equal(chips.ROGUE.clickButtons[2], "RightButtonUp")
        solo("ROGUE")
        H.Equal(dialog.nameInput:GetText(), generated("ROGUE"))
        chips.HUNTER:Click("LeftButton")
        local classes = ui.dialogs.ruleDraft.classes
        H.Equal(state.RG.Util.Count(classes), 2); H.True(classes.ROGUE); H.True(classes.HUNTER)
        solo("HUNTER")
        H.Equal(dialog.nameInput:GetText(), generated("HUNTER"))
        solo("ROGUE")
        H.Equal(dialog.nameInput:GetText(), generated("ROGUE"))
        H.Equal(#profile.rules, 0)
        H.Equal(state.RG.Util.Count(profile.alerts.classes), 1); H.True(profile.alerts.classes.MAGE)
        H.True(profile.alerts.unknownClass)

        pickSound(ui, dialog.soundCue, "quest")
        dialog.save:Click()
        local saved = profile.rules[1]
        H.Equal(saved.name, generated("ROGUE"))
        H.Equal(saved.soundCue, "quest")
        H.Equal(state.RG.Util.Count(saved.classes), 1); H.True(saved.classes.ROGUE)
        seeSoundRuleRival(state, 1, "ROGUE")
        seeSoundRuleRival(state, 2, "HUNTER")
        state:Advance(1.5)
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].reason, "custom_rule")
        H.Equal(#state.sounds, 1)
        H.Equal(state.sounds[1].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)

        solo("HUNTER")
        H.Equal(dialog.nameInput:GetText(), saved.name, "an existing rule keeps its saved name")
        H.True(saved.classes.ROGUE); H.Nil(saved.classes.HUNTER)
        buttonIn(dialog, "newRule"):Click()
        local name = locale == "ruRU" and "Мой сигнал" or "My custom signal"
        dialog.nameInput:SetText(name)
        dialog.nameInput.scripts.OnTextChanged(dialog.nameInput, true)
        solo("HUNTER")
        H.Equal(dialog.nameInput:GetText(), name)
        solo("MAGE")
        H.Equal(dialog.nameInput:GetText(), name)
        H.Equal(#profile.rules, 1)
        H.Equal(state.RG.Util.Count(profile.alerts.classes), 1); H.True(profile.alerts.classes.MAGE)
        H.True(profile.alerts.unknownClass)
    end)
end

H.Test("hidden Nearby skips row production while minimap census and alerts stay live", function()
    local state, RG, app = setup(nil, function(fixture)
        local map = fixture.api.CreateFrame("Frame", "Minimap", fixture.api.UIParent)
        map:SetSize(160, 160)
        fixture.api.C_NamePlateManager = {
            IsNamePlateUnitBehindCamera = function(token) return token == "nameplate3" end,
        }
    end)
    local profile, ui = app.db:GetProfile(), app.ui
    profile.display.classes = { HUNTER = true }
    profile.display.showUnknown = false
    profile.alerts.waveThreshold = 20
    app:ProfileChanged()
    assert(app.db:SetList("guid:Player-Count-4", "ignore", nil, { name = "Ignored Hunter" }))
    local snapshotCalls, rowCalls = 0, 0
    local snapshot, rows = app.engine.Snapshot, RG.UIModel.Rows
    app.engine.Snapshot = function(engine)
        snapshotCalls = snapshotCalls + 1
        return snapshot(engine)
    end
    RG.UIModel.Rows = function(...)
        rowCalls = rowCalls + 1
        return rows(...)
    end

    local launcher = assert(ui.launcher).frame
    launcher:Click()
    H.False(ui.frame:IsShown())
    for index, class in ipairs({ "HUNTER", "MAGE", "HUNTER", "HUNTER", "UNKNOWN_FIXTURE" }) do
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-Count-" .. index, name = "Rival " .. index, class = class, hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    state:Unit("target", state.units.nameplate1)
    state:Fire("PLAYER_TARGET_CHANGED")
    state:Advance(1.5)
    H.Equal(ui.visibleCount, 1)
    launcher.scripts.OnEnter(launcher)
    H.True(state.api.GameTooltip.lines[1]:find(ui:F("inViewCount", 1), 1, true) ~= nil)
    H.True(#state.sounds > 0)
    H.Equal(snapshotCalls, 0)
    H.Equal(rowCalls, 0)

    app:Demo()
    H.True(ui.frame:IsShown())
    H.False(profile.display.showList)
    H.True(rowCalls > 0)
    H.Equal(snapshotCalls, 0)
    local previewRowCalls = rowCalls
    state:Advance(16)
    H.False(ui.frame:IsShown())
    H.Equal(ui.visibleCount, 1)
    H.Equal(snapshotCalls, 0)
    launcher:Click()
    H.True(ui.frame:IsShown())
    H.Equal(snapshotCalls, 0)
    H.True(rowCalls > previewRowCalls)
    H.Equal(ui.rows[1].contact.identity, "guid:Player-Count-1")
end)

H.Test("a live Nearby refresh builds only the visible page in a mixed crowd", function()
    local state, RG, app = setup(nil, function(mock)
        mock.api.C_NamePlateManager = { IsNamePlateUnitBehindCamera = function(token)
            return tonumber(token:match("%d+")) % 6 == 0
        end }
    end)
    local profile, engine, ui = app.db:GetProfile(), app.engine, app.ui
    profile.display.maxRows = 8
    app:OnSettingsChanged()
    local function identity(index) return "guid:Player-NearbyPage-" .. index end
    for index, kind in pairs({ [1] = "watch", [3] = "watch", [5] = "avoid", [7] = "ignore" }) do
        assert(app.db:SetList(identity(index), kind, nil, { name = "Listed rival " .. index }))
    end
    for index = 1, 96 do
        local token = "nameplate" .. index
        local class = index >= 94 and "PRIEST" or ({ "ROGUE", "HUNTER", "MAGE", "UNKNOWN_FIXTURE" })[(index - 1) % 4 + 1]
        state:Unit(token, { guid = "Player-NearbyPage-" .. index, name = "Crowd rival " .. index,
            class = class, hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        if index % 8 == 0 then state.clock.Advance(0.03) end
    end
    for index = 9, 90, 9 do
        local token = "nameplate" .. index
        state.units[token], state.plates[token] = nil, nil
        state:Fire("NAME_PLATE_UNIT_REMOVED", token)
    end
    state:Advance(1.5)
    local alerts, sounds = engine.counters.alerts, #state.sounds
    local rawSnapshot, rawView, rawRows = engine.Snapshot, engine.View, RG.UIModel.Rows
    local stats
    engine.Snapshot = function(self, ...)
        if stats then stats.snapshots = stats.snapshots + 1 end
        return rawSnapshot(self, ...)
    end
    engine.View = function(self, ...)
        if stats then stats.views = stats.views + 1 end
        return rawView(self, ...)
    end
    RG.UIModel.Rows = function(snapshot, ...)
        if stats then stats.input = math.max(stats.input, #snapshot) end
        return rawRows(snapshot, ...)
    end
    local function measure(action)
        stats = { snapshots = 0, views = 0, input = 0 }
        action()
        local observed = stats
        stats = nil
        return observed
    end
    local referenceAliases = {}
    local function checkPage(refresh, offset)
        local expected = rawSnapshot(engine)
        local names = profile.display.streamer and rawRows(expected, profile, engine:Now(), referenceAliases)
        local visible = 0
        for _, contact in ipairs(expected) do
            if contact.visible and contact.behindCamera ~= true then visible = visible + 1 end
        end
        local measured = measure(refresh)
        H.Equal(ui.offset, offset)
        H.Equal(ui.renderedCount, #expected)
        H.Equal(ui.visibleCount, visible)
        H.True(ui.statusText:GetText():find(ui:F("inViewCount", visible), 1, true) ~= nil)
        for index = 1, profile.display.maxRows do
            local wanted, row = expected[offset + index], ui.rows[index]
            H.Equal(row:IsShown(), wanted ~= nil)
            H.Equal(row.contact and row.contact.identity, wanted and wanted.identity)
            if names and wanted then
                H.Equal(row.nameText:GetText(), names[offset + index].name)
                H.Nil(row.nameText:GetText():find("Crowd rival", 1, true))
            end
        end
        H.Equal(measured.snapshots, 0)
        H.True(measured.views <= profile.display.maxRows + 2)
        H.True(measured.input <= profile.display.maxRows)
        H.Equal(engine.counters.alerts, alerts); H.Equal(#state.sounds, sounds)
    end

    local offsetEnd = #rawSnapshot(engine) - profile.display.maxRows
    checkPage(function() ui:Refresh() end, 0)
    ui.rows[1]:Click()
    local selectedIdentity = ui.selected.identity
    checkPage(function() ui.frame.scripts.OnMouseWheel(ui.frame, -500) end, offsetEnd)
    H.Equal(ui.selected.identity, selectedIdentity)
    H.True(ui.detailsFrame:IsShown()); H.False(ui.selectedOutside)
    H.True(ui.rows[1].contact.identity ~= selectedIdentity)
    checkPage(function() ui.frame.scripts.OnMouseWheel(ui.frame, 1) end, offsetEnd - 1)

    profile.display.classes, profile.display.showUnknown = { PRIEST = true }, false
    checkPage(function() app:OnSettingsChanged() end, 0)
    H.Equal(ui.renderedCount, 3)
    H.Equal(ui.visibleCount, 2)

    profile.display.classes, profile.display.showUnknown, profile.display.streamer = {}, true, true
    checkPage(function() app:OnSettingsChanged() end, 0)
    checkPage(function() ui.frame.scripts.OnMouseWheel(ui.frame, -500) end, offsetEnd)
    assert(app.db:SetList(identity(97), "watch", "Local-only note", { name = "Incoming rival" }))
    for index = 97, 98 do
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-NearbyPage-" .. index, name = "Crowd rival " .. index,
            class = "MAGE", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    checkPage(function() ui:Refresh() end, offsetEnd)
    checkPage(function() ui.frame.scripts.OnMouseWheel(ui.frame, 500) end, 0)
    local appended
    for _, contact in ipairs(rawSnapshot(engine)) do if contact.identity == identity(98) then appended = contact; break end end
    assert(app:SetList(assert(appended), "avoid", "Preserve this locally"))
    checkPage(function() ui:Refresh() end, 0)
    profile.display.classes, profile.display.showUnknown = { MAGE = true }, false
    checkPage(function() app:OnSettingsChanged() end, 0)
    profile.display.classes, profile.display.showUnknown = {}, true
    checkPage(function() app:OnSettingsChanged() end, 0)

    local aliasesBefore = RG.Codec.Encode(ui.aliases)
    local listsBefore = RG.Codec.Encode(app.db:GetList())
    local preview = measure(function() app:Demo() end)
    H.Equal(preview.snapshots, 0)
    H.Equal(preview.input, 3)
    H.True(ui.rows[1].contact.preview)
    local demo = rawRows(ui.previewContacts, profile, engine:Now(), {})
    H.Equal(ui.rows[1].nameText:GetText(), demo[1].name)
    H.Equal(RG.Codec.Encode(ui.aliases), aliasesBefore)
    H.Equal(RG.Codec.Encode(app.db:GetList()), listsBefore)
    H.Equal(engine.counters.alerts, alerts); H.Equal(#state.sounds, sounds)
end)

H.Test("an open contact card refreshes in a crowd without building a hidden Nearby list", function()
    local state, RG, app = setup()
    local unit = { guid = "Player-HiddenDetails", name = "First name", realm = "FixtureRealm", class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(0.5)
    local ui = app.ui
    ui.rows[1]:Click()
    H.Equal(ui.detailsFrame.title:GetText(), "First name-FixtureRealm")
    local snapshotCalls, rowCalls, snapshot, rows = 0, 0, app.engine.Snapshot, RG.UIModel.Rows
    app.engine.Snapshot = function(engine)
        snapshotCalls = snapshotCalls + 1
        return snapshot(engine)
    end
    RG.UIModel.Rows = function(...)
        rowCalls = rowCalls + 1
        return rows(...)
    end
    ui:Toggle()
    H.False(ui.frame:IsShown())
    for index = 2, 96 do
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-HiddenCrowd-" .. index, name = "Crowd " .. index,
            class = "HUNTER", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    local observed = app.engine.counters.observations
    app.sensors:Poll()
    H.Equal(app.engine.counters.observations - observed, 96)
    local firstSeen = ui.selected.lastSeen
    unit.name = "Updated name"
    state.clock.Advance(0.5)
    state:Fire("UNIT_NAME_UPDATE", "nameplate1")
    ui:Refresh()
    H.True(ui.detailsFrame:IsShown())
    H.Equal(ui.detailsFrame.title:GetText(), "Updated name-FixtureRealm")
    H.True(ui.selected.lastSeen > firstSeen)
    H.False(ui.selectedOutside)
    H.Equal(ui.visibleCount, 96)
    H.Equal(rowCalls, 0)
    H.Equal(snapshotCalls, 0)

    assert(app.db:SetList("guid:Player-HiddenDetails", "watch", "Saved note",
        { name = "Saved rival", class = "ROGUE" }))
    ui:OpenSettings("journal")
    ui.journalPersonal:Click()
    ui.journalRows[1]:Click()
    ui:Refresh()
    H.True(ui.selected.savedOnly)
    H.Equal(ui.detailsFrame.title:GetText(), "Saved rival")
    H.Equal(ui.detailsFrame.note:GetText(), "Saved note")
    H.False(ui.detailsFrame.locate:IsShown())
    H.Equal(rowCalls, 0)
    H.Equal(snapshotCalls, 0)

    app:Demo()
    H.True(ui.frame:IsShown())
    H.True(ui.selected.savedOnly)
    H.True(rowCalls > 0)
    H.Equal(snapshotCalls, 0)
    ui.rows[1]:Click()
    H.True(ui.selected.preview)
    H.False(ui.detailsFrame.locate:IsShown())
    state.clock.Advance(16)
    ui:Refresh()
    H.False(ui.frame:IsShown())
    H.False(ui.detailsFrame:IsShown())
    H.Equal(snapshotCalls, 0)
end)

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

H.Test("default sighting sound leaves room for a nearby targeting escalation", function()
    local state, _, app = setup()
    state:Unit("player", { guid = "Player-Self" })
    state:Unit("nameplate1", { guid = "Player-Hunter", name = "Hunter", class = "HUNTER", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(1.1)
    H.Equal(#state.sounds, 1)
    H.Equal(app.ui.activeBanner.kind, "sighting")

    state:Unit("nameplate1target", { guid = "Player-Self" })
    state:Fire("UNIT_TARGET", "nameplate1")
    state:Advance(0.4)
    H.Equal(app.ui.activeBanner.kind, "targeting")
    H.Equal(#state.sounds, 2)
    state:Advance(1.6)
    H.Equal(#state.sounds, 2)
    H.Nil(app.diagnostics.counts.errors)
end)

H.Test("contradictory current range probes stay quiet until a fresh in-range reading agrees", function()
    local distances = { nameplate1 = 10, target = 45 }
    local state, _, app = setup(nil, function(fixture)
        fixture.api.UnitDistanceSquared = function(token)
            local distance = distances[token]
            if distance then return distance * distance, true end
        end
    end)
    local range = app.db:GetProfile().range
    range.enabled, range.yards, range.policy, range.unknown = true, 25, "confirmed", false
    app:ProfileChanged()
    local unit = { guid = "Player-RangeCohort", name = "Rival", class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", unit)
    state:Unit("target", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Fire("PLAYER_TARGET_CHANGED")
    local contact = app.engine:Snapshot()[1]
    H.Nil(contact.rangeMax)
    H.Equal(app:Explain(contact).reason, "range_conflict")
    state:Advance(1.5)
    H.Equal(#state.sounds, 0)
    H.False(app.ui.banner:IsShown())

    distances.nameplate1, distances.target = 14, 14
    state:Advance(1.5)
    H.Equal(#state.sounds, 1)
    H.True(app.ui.banner:IsShown())
    H.Equal(app.ui.banner.body:GetText(), unit.name)
end)

H.Test("a cached spell sample does not conflict with a later exact measurement", function()
    local probes = 0
    local state, _, app = setup(nil, function(fixture)
        local api = fixture.api
        api.UnitDistanceSquared = function(token) if token == "target" then return 45 * 45, true end end
        api.Enum = { SpellBookSpellBank = { Player = 0 }, SpellBookItemType = { Spell = 1 } }
        api.C_SpellBook = {
            GetNumSpellBookSkillLines = function() return 1 end,
            GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = 1 } end,
            GetSpellBookItemInfo = function() return { spellID = 123, itemType = 1, isPassive = false, isOffSpec = false } end,
            IsSpellKnown = function() return true end,
            IsSpellBookItemInRange = function() probes = probes + 1; return true end,
        }
        api.C_Spell = {
            GetSpellInfo = function() return { minRange = 0, maxRange = 20 } end,
            IsSpellHarmful = function() return true end,
        }
    end)
    local range = app.db:GetProfile().range
    range.enabled, range.yards, range.policy, range.unknown = true, 25, "confirmed", false
    app:ProfileChanged()
    local unit = { guid = "Player-CachedRange", name = "Moving rival", class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(app.engine:Snapshot()[1].rangeMax, 20)
    H.Equal(probes, 1)
    state.clock.Advance(0.1)
    state:Unit("target", unit)
    state:Fire("PLAYER_TARGET_CHANGED")
    state:Fire("UNIT_FLAGS", "nameplate1")
    H.Equal(probes, 1)
    local contact = app.engine:Snapshot()[1]
    H.Equal(contact.rangeMin, 45)
    H.Equal(contact.rangeMax, 45)
    H.Equal(contact.rangeEvidence, "exact")
    H.Equal(app:Explain(contact).reason, "range_outside")
end)

local function pendingRangeFixture(configure)
    local distances, reads = {}, 0
    local state, RG, app = setup(nil, function(mock)
        mock.api.UnitDistanceSquared = function(token)
            local distance = distances[token]
            if distance then reads = reads + 1; return distance * distance, true end
        end
    end)
    if configure then configure(app.db:GetProfile()); app:OnSettingsChanged() end
    local function see(index, distance)
        local token = "nameplate" .. index
        distances[token] = distance
        state:Unit(token, { guid = "Player-PendingRange" .. index, name = "Range rival " .. index,
            class = "ROGUE", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    local function move(index, distance)
        local token = "nameplate" .. index
        distances[token] = distance
        state:Fire("UNIT_FLAGS", token)
    end
    return state, app, see, move, RG, function() return reads end
end

local function urgentRangeRule(profile, allowUnknown)
    profile.rules = {{ name = "Urgent within 35", enabled = true, event = "sighting", action = "alert",
        priority = 80, classes = {}, cooldown = 0, sound = true, banner = true,
        range = 35, rangePolicy = "confirmed", rangeUnknown = allowUnknown }}
end

for _, locale in ipairs({ "enUS", "ruRU" }) do
    H.Test("measured range distinguishes exactly 20 yards from 20.04 in " .. locale, function()
        local _, app, see, move, RG = pendingRangeFixture(function(profile)
            profile.locale = locale
            profile.range.enabled, profile.range.yards, profile.range.policy, profile.range.unknown = true, 20, "confirmed", false
        end)
        local ui = app.ui
        local function display(expected)
            ui:Refresh()
            H.True(ui.rows[1].detailText:GetText():find(expected, 1, true) ~= nil)
            ui.rows[1]:Click()
            H.True(ui.detailsFrame.info:GetText():find(expected, 1, true) ~= nil)
            H.True(ui.detailsFrame.info:GetText():find(ui:T("rangeEvidenceExact"), 1, true) ~= nil)
        end
        see(1, 20)
        local contact = app.engine:Snapshot()[1]
        H.Equal(contact.rangeMin, 20); H.Equal(contact.rangeMax, 20)
        H.True(app:Explain(contact).allowed)
        display(ui:F("rangeMeasured", 20))

        move(1, 20.04)
        contact = app.engine:Snapshot()[1]
        H.True(contact.rangeMin > 20)
        H.Equal(app:Explain(contact).reason, "range_outside")
        local approximate = ui:F("rangeMeasuredApprox", 20, 4)
        H.True(approximate ~= ui:F("rangeMeasured", 20))
        display(approximate)
        ui:ShowExplanation()
        H.Equal(ui.explanationFrame.reason:GetText(), RG.Locale.Reason("range_outside", locale))
    end)
end

H.Test("a combined spell and interaction range shows the exclusive strict lower bound", function()
    local state, RG, app = setup(nil, function(mock)
        local api = mock.api
        api.Enum = { SpellBookSpellBank = { Player = 0 }, SpellBookItemType = { Spell = 1 } }
        api.C_SpellBook = {
            GetNumSpellBookSkillLines = function() return 1 end,
            GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = 1 } end,
            GetSpellBookItemInfo = function() return { spellID = 123, itemType = 1, isPassive = false, isOffSpec = false } end,
            IsSpellKnown = function() return true end,
            IsSpellBookItemInRange = function() return false end,
        }
        api.C_Spell = {
            GetSpellInfo = function() return { minRange = 0, maxRange = 20 } end,
            IsSpellHarmful = function() return true end,
        }
        api.CheckInteractDistance = function(token, index) return token == "nameplate1" and index == 4 end
    end)
    local profile, ui = app.db:GetProfile(), app.ui
    profile.range.enabled, profile.range.yards, profile.range.policy, profile.range.unknown = true, 20, "confirmed", false
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    local range = app.engine:Snapshot()[1]
    H.Equal(range.rangeMin, 20); H.Equal(range.rangeMax, 28)
    H.Equal(range.rangeEvidence, "combined"); H.True(range.rangeMinExclusive)
    H.Equal(app:Explain(range).reason, "range_outside")
    ui:Refresh()
    ui.rows[1]:Click()
    local expected = ui:F("rangeExclusiveBracket", 20, 28)
    H.True(ui.rows[1].detailText:GetText():find(expected, 1, true) ~= nil)
    H.True(ui.detailsFrame.info:GetText():find(expected, 1, true) ~= nil)
    H.Nil(ui.detailsFrame.info:GetText():find(ui:F("rangeBracket", 20, 28), 1, true))
    H.True(ui.detailsFrame.info:GetText():find(ui:T("rangeEvidenceCombined"), 1, true) ~= nil)
    ui:ShowExplanation()
    H.Equal(ui.explanationFrame.reason:GetText(), RG.Locale.Reason("range_outside", profile.locale))
    local explanation = app:Explain(range)
    H.Equal(explanation.rangeMin, 20); H.Equal(explanation.rangeMax, 28); H.True(explanation.rangeMinExclusive)
    H.True(ui.explanationFrame.rangeEvidence:GetText():find(expected, 1, true) ~= nil)
end)

for _, movesNear in ipairs({ false, true }) do
    H.Test("a new exact range " .. (movesNear and "expedites" or "demotes") .. " a queued sighting", function()
        local state, app, see, move = pendingRangeFixture(function(profile) urgentRangeRule(profile, false) end)
        local initialDistance, newDistance = movesNear and 48 or 21, movesNear and 21 or 48
        local arrival = state.clock.Now()
        see(1, initialDistance)
        local contact = app.engine:Snapshot()[1]
        H.Equal(contact.rangeMax, initialDistance)
        state.clock.Advance(0.2)
        move(1, newDistance)
        H.Equal(app.engine:Snapshot()[1].rangeMax, newDistance)
        H.Equal(app.engine.pending[1].at, arrival)
        state.clock.Advance(0.05)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, movesNear and 1 or 0)
        state.clock.Advance(0.6)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].id, contact.id)
        H.Equal(app.engine.history[1].reason, movesNear and "custom_rule" or "event_matched")
    end)
end

for _, allowUnknown in ipairs({ false, true }) do
    H.Test("expired range " .. (allowUnknown and "uses the rule's unknown-distance urgency" or "removes unsupported urgency"), function()
        local state, app, see = pendingRangeFixture(function(profile)
            urgentRangeRule(profile, allowUnknown)
            profile.alerts.waveWindow = 3
        end)
        see(1, allowUnknown and 48 or 21)
        local contact = app.engine:Snapshot()[1]
        H.Equal(contact.rangeEvidence, "exact")
        state.clock.Advance(2.1)
        H.Equal(app.engine:Snapshot()[1].rangeEvidence, "unknown")
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, allowUnknown and 1 or 0)
        state.clock.Advance(1)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].id, contact.id)
        H.Equal(app.engine.history[1].reason, allowUnknown and "custom_rule" or "event_matched")
    end)
end

H.Test("a queued player now outside strict range does not accelerate a later wave", function()
    local state, app, see, move = pendingRangeFixture(function(profile)
        local range = profile.range
        range.enabled, range.policy, range.yards, range.unknown = true, "confirmed", 35, false
        profile.alerts.waveThreshold = 2
    end)
    see(1, 21)
    local first = app.engine:Snapshot()[1]
    state.clock.Advance(0.3)
    see(2, 21); see(3, 21)
    state.clock.Advance(0.1)
    move(1, 48)
    H.Equal(app:Explain(app.engine:SelectedContact(first.id, first.identity)).reason, "range_outside")
    state.clock.Advance(0.45)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 0)
    state.clock.Advance(0.3)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "wave")
    H.Equal(app.ui.activeBanner.count, 2)
end)

local function pendingEligibilityFixture()
    local unreadable = {}
    local state, _, app = setup(nil, function(mock)
        local read, secret = mock.api.UnitIsEnemy, H.Secret("unreadable unit hostility")
        mock.api.UnitIsEnemy = function(player, token)
            if unreadable[token] then return secret end
            return read(player, token)
        end
    end)
    app.db:GetProfile().alerts.waveThreshold = 2
    app:OnSettingsChanged()
    local function add(index, class)
        local token = "nameplate" .. index
        local unit = { guid = "Player-Eligibility" .. index, name = "Rival " .. index,
            class = class, hostile = true, isPlayer = true }
        state:Unit(token, unit)
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        return unit
    end
    return state, app, add, unreadable
end

for _, reason in ipairs({ "dead", "identity_unconfirmed", "contact_snoozed" }) do
    H.Test("a no-range wave never anchors to a queued player now " .. reason, function()
        local state, app, add, unreadable = pendingEligibilityFixture()
        local unit = add(1, "ROGUE")
        local leader = app.engine:Snapshot()[1]
        if reason == "identity_unconfirmed" then
            state:Unit("focus", unit)
            state:Fire("PLAYER_FOCUS_CHANGED")
        end
        state.clock.Advance(0.3)
        add(2, "HUNTER"); add(3, "MAGE")
        state.clock.Advance(0.1)
        if reason == "dead" then
            unit.dead = true
            state:Fire("UNIT_FLAGS", "nameplate1")
        elseif reason == "identity_unconfirmed" then
            unreadable.nameplate1 = true
            state:Fire("UNIT_FLAGS", "nameplate1")
            H.True(app.engine:SelectedContact(leader.id, leader.identity).hostile)
            unreadable.focus = true
            state:Fire("UNIT_FLAGS", "focus")
            H.Nil(app.engine:SelectedContact(leader.id, leader.identity).hostile)
        else
            assert(app:Snooze(leader, 10))
        end
        H.Equal(app:Explain(app.engine:SelectedContact(leader.id, leader.identity)).reason, reason)
        state.clock.Advance(0.45)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 0)
        H.Equal(#state.sounds, 0)
        state.clock.Advance(0.3)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].kind, "wave")
        H.Equal(app.ui.activeBanner.count, 2)
        H.Equal(app.ui.activeBanner.classes.HUNTER, 1)
        H.Equal(app.ui.activeBanner.classes.MAGE, 1)
        H.Nil(app.ui.activeBanner.classes.ROGUE)
    end)
end

for _, tickWhileDead in ipairs({ false, true }) do
    H.Test("clear alive evidence restores a sighting " .. (tickWhileDead and "after a blocked tick" or "before its first tick"), function()
        local state, app, add = pendingEligibilityFixture()
        local arrival = state.clock.Now()
        local unit = add(1, "ROGUE")
        local original = app.engine:Snapshot()[1]
        state.clock.Advance(0.2)
        unit.dead = true
        state:Fire("UNIT_FLAGS", "nameplate1")
        H.Equal(app:Explain(app.engine:Snapshot()[1]).reason, "dead")
        if tickWhileDead then
            state.clock.Advance(0.65)
            app.engine:Tick()
            H.Equal(#app.engine.pending, 0)
            H.Equal(app.engine.counters.alerts, 0)
        end
        state.clock.Advance(0.1)
        unit.dead = false
        state:Fire("UNIT_FLAGS", "nameplate1")
        H.Equal(app.engine.pending[1].at, tickWhileDead and state.clock.Now() or arrival)
        state.clock.Advance(0.56)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, tickWhileDead and 0 or 1)
        state.clock.Advance(0.3)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].id, original.id)
        H.Equal(app.engine.history[1].kind, "sighting")
    end)
end

local function aliasedLifeFixture(initiallyDead)
    local state, _, app = setup(nil, function(mock)
        function mock.api.UnitIsDeadOrGhost(token)
            local unit = mock.units[token]
            if unit then return unit.dead end
            return false
        end
    end)
    local profile = app.db:GetProfile()
    profile.alerts.muteOrdinary = true
    profile.retention.journalMode = "threats"
    app:OnSettingsChanged()
    local plateUnit = { guid = "Player-AliasedLife", name = "Fixture rogue", class = "ROGUE",
        hostile = true, isPlayer = true, dead = initiallyDead }
    local focusUnit = state.RG.Util.Copy(plateUnit)
    state:Unit("nameplate1", plateUnit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Unit("focus", focusUnit)
    state:Fire("PLAYER_FOCUS_CHANGED")
    local first = assert(app.engine:Snapshot()[1])
    H.Equal(first.dead, initiallyDead)
    H.True(first.sources.nameplate); H.True(first.sources.focus)
    H.Equal(#app.db:GetJournal(), 0)
    local function original()
        return assert(app.engine:SelectedContact(first.id, first.identity))
    end
    return state, app, plateUnit, original
end

H.Test("confirmed same-GUID resurrection allows a Vanish before the cached focus can refresh", function()
    local state, app, unit, original = aliasedLifeFixture(true)
    local now = state.clock.Now()
    unit.dead = false
    state:Fire("UNIT_FLAGS", "nameplate1")
    H.False(original().dead)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-AfterResurrection", 1856)
    H.Equal(state.clock.Now(), now)
    H.Equal(#app.db:GetJournal(), 1)
    H.Equal(app.db:GetJournal()[1].identity, original().identity)
    H.Equal(app.db:GetJournal()[1].encounters, 1)
    app.engine:Tick()
    H.Equal(#app.engine.history, 1)
    H.Equal(app.engine.history[1].kind, "stealth")
    H.Equal(app.engine.history[1].id, original().id)
    H.Equal(#state.sounds, 1)
    H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellVanish")))

    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    local remaining = original()
    H.True(remaining.visible); H.True(remaining.sources.focus)
    H.Nil(remaining.sources.nameplate)
    H.True(remaining.dead ~= true)
    app.engine:Tick()
    H.Equal(#app.engine.history, 1)
end)

H.Test("confirmed death cancels a queued Vanish even when its nameplate leaves before the tick", function()
    local state, app, unit, original = aliasedLifeFixture(false)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-BeforeFreshDeath", 1856)
    H.Equal(#app.engine.pending, 1)
    unit.dead = true
    state:Fire("UNIT_FLAGS", "nameplate1")
    H.True(original().dead)
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    H.True(original().sources.focus)
    app.engine:Tick()
    H.Equal(#app.engine.history, 0)
    H.Equal(#state.sounds, 0)
    H.Nil(app.ui.activeBanner)
end)

for _, evidence in ipairs({ "restricted life", "restricted identity", "different player" }) do
    H.Test("known death from focus survives " .. evidence .. " evidence on another alias", function()
        local state, app, unit, original = aliasedLifeFixture(true)
        local restricted = H.Secret("unreadable resurrection evidence")
        if evidence == "different player" then
            state:Unit("nameplate1", { guid = "Player-DifferentAlive", name = "Another rogue", class = "ROGUE",
                hostile = true, isPlayer = true, dead = false })
        elseif evidence == "restricted identity" then
            local guid, name = state.api.UnitGUID, state.api.UnitName
            state.api.UnitGUID = function(token) if token == "nameplate1" then return restricted end return guid(token) end
            state.api.UnitName = function(token) if token == "nameplate1" then return restricted, restricted end return name(token) end
            state.api.UnitFullName = state.api.UnitName
            unit.dead = false
        else
            unit.dead = restricted
        end
        state:Fire("UNIT_FLAGS", "nameplate1")
        local old = original()
        H.True(old.dead); H.True(old.sources.focus)
        H.Equal(app:Explain(old).reason, "dead")
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "focus", "Cast-UnverifiedResurrection", 1856)
        app.engine:Tick()
        H.Equal(#app.engine.history, 0)
        H.Equal(#app.db:GetJournal(), 0)
        H.Equal(#state.sounds, 0)
    end)
end

H.Test("unchanged exact measurements do not reschedule sightings when no range filter is in use", function()
    local state, app, see, move, RG, reads = pendingRangeFixture()
    local arrival = state.clock.Now()
    local rawEvaluate, evaluations = RG.Rules.Evaluate, 0
    RG.Rules.Evaluate = function(...)
        evaluations = evaluations + 1
        return rawEvaluate(...)
    end
    for index = 1, 8 do see(index, 21) end
    local initial = evaluations
    for _ = 1, 3 do
        state.clock.Advance(0.1)
        for index = 1, 8 do move(index, 21) end
        app.engine:Tick()
    end
    H.Equal(reads(), 32)
    H.Equal(evaluations, initial)
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#app.engine.pending, 8)
    for _, item in ipairs(app.engine.pending) do H.Equal(item.at, arrival) end
    state.clock.Advance(0.55)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.ui.activeBanner.count, 8)
end)

H.Test("a stable range-filtered tick checks each ready and waiting event once", function()
    local state, app, see, _, RG = pendingRangeFixture(function(profile)
        urgentRangeRule(profile, false)
        profile.range.enabled, profile.range.yards, profile.range.policy, profile.range.unknown = true, 40, "confirmed", false
    end)
    see(1, 15); see(2, 21); see(3, 38)
    local evaluate, checked = RG.Rules.Evaluate, {}
    RG.Rules.Evaluate = function(profile, contact, ...)
        local identity = contact.identity
        checked[identity] = (checked[identity] or 0) + 1
        return evaluate(profile, contact, ...)
    end

    state.clock.Advance(0.25)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 2)
    H.Equal(#app.engine.pending, 1)
    H.Equal(checked["guid:Player-PendingRange1"], 1)
    H.Equal(checked["guid:Player-PendingRange2"], 1)
    H.Equal(checked["guid:Player-PendingRange3"], 1)

    state.clock.Advance(0.6)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 3)
    H.Equal(#app.engine.pending, 0)
    H.Equal(checked["guid:Player-PendingRange1"], 1)
    H.Equal(checked["guid:Player-PendingRange2"], 1)
    H.Equal(checked["guid:Player-PendingRange3"], 2)
end)

for _, update in ipairs({ "range", "class", "profile" }) do
    H.Test("a ready range-filtered alert rechecks " .. update .. " after another alert changes it", function()
        local state, app, see, move = pendingRangeFixture(function(profile)
            profile.alerts.classes = { ROGUE = true }
            profile.alerts.muteOrdinary = true
            profile.range.enabled, profile.range.yards, profile.range.policy, profile.range.unknown = true, 35, "confirmed", false
        end)
        local requests = 0
        state.api.PlaySound = function()
            requests = requests + 1
            if requests == 1 then
                if update == "range" then move(2, 48)
                elseif update == "class" then
                    state.units.nameplate2.class = "HUNTER"
                    state:Fire("UNIT_FLAGS", "nameplate2")
                else
                    app.db:GetProfile().alerts.stealth = false
                    app:OnSettingsChanged()
                end
            end
            return true
        end
        see(1, 21); see(2, 21)
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-FirstReady", 1856)
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate2", "Cast-StaleReady", 1856)
        H.Equal(#app.engine.pending, 2)
        state.clock.Advance(0.25)
        app.engine:Tick()
        H.Equal(requests, 1)
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].kind, "stealth")
        H.Equal(app.ui.activeBanner.name, "Range rival 1")
        H.Equal(#app.ui.bannerQueue, 0)
        H.Equal(#app.engine.pending, 0)
    end)
end

for _, queued in ipairs({ false, true }) do
    H.Test("targeting banner retires when evidence ends " .. (queued and "in the queue" or "while shown"), function()
        local state, _, app = setup()
        if queued then
            assert(app.db:SetList("guid:Player-AlertFirst", "watch", nil, { name = "Watched" }))
            state:Unit("nameplate1", { guid = "Player-AlertFirst", name = "Watched", class = "ROGUE" })
            state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
            state:Advance(0.4)
            H.Equal(app.ui.activeBanner.kind, "watch")
        end
        state:Unit("player", { guid = "Player-Self" })
        state:Unit("nameplate2", { guid = "Player-Targeting", name = "Hunter", class = "HUNTER" })
        state:Unit("nameplate2target", { guid = "Player-Self" })
        state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
        state:Advance(0.4)
        if queued then H.Equal(app.ui.bannerQueue[1].kind, "targeting")
        else H.Equal(app.ui.activeBanner.kind, "targeting") end
        state.units.nameplate2target = nil
        state:Fire("UNIT_TARGET", "nameplate2")
        state:Advance(queued and 3.7 or 0.4)
        H.Nil(app.ui.activeBanner)
    end)
end

local function targetingFixture(initialDistance)
    local distance, unknown = initialDistance, false
    local secret = H.Secret("restricted target relation")
    local state, _, app = setup(nil, function(fixture)
        fixture.api.UnitDistanceSquared = function(token)
            if token == "nameplate1" then return distance * distance, true end
        end
        local compare = fixture.api.UnitIsUnit
        fixture.api.UnitIsUnit = function(first, second)
            if unknown and first == "nameplate1target" and second == "player" then return secret end
            return compare(first, second)
        end
    end)
    local profile = app.db:GetProfile()
    profile.range.enabled, profile.range.policy, profile.range.yards, profile.range.unknown = true, "confirmed", 35, false
    profile.alerts.muteOrdinary, profile.alerts.cooldown = true, 0
    app:ProfileChanged()
    state:Unit("player", { guid = "Player-TargetingSelf" })
    state:Unit("nameplate1", { guid = "Player-RangeTargeting", name = "Rival", class = "ROGUE", hostile = true, isPlayer = true })
    state:Unit("nameplate1target", state.units.player)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local function target(value)
        unknown = value == nil
        if not unknown then state.units.nameplate1target = value and state.units.player or nil end
        state:Fire("UNIT_TARGET", "nameplate1")
    end
    return state, app, function(value) distance = value end, target
end

H.Test("continuous targeting recovers once in range and a clean new episode can warn again", function()
    local state, app, setDistance, target = targetingFixture(48)
    state:Advance(0.5)
    H.True(app.engine:Snapshot()[1].targeting)
    H.Equal(app.engine.counters.alerts, 0)
    setDistance(21)
    state:Advance(1)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.ui.activeBanner.kind, "targeting")
    state:Advance(2)
    H.Equal(app.engine.counters.alerts, 1)

    target(false)
    H.False(app.engine:Snapshot()[1].targeting)
    target(true)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 2)
    H.Equal(app.engine.history[2].kind, "targeting")
    state:Advance(1)
    H.Equal(app.engine.counters.alerts, 2)
end)

H.Test("an unreadable target relation does not start a second warning episode", function()
    local state, app, _, target = targetingFixture(21)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    target(nil)
    H.Nil(app.engine:Snapshot()[1].targeting)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    target(true)
    state:Advance(0.5)
    H.True(app.engine:Snapshot()[1].targeting)
    H.Equal(app.engine.counters.alerts, 1)
end)

H.Test("a queued targeting warning canceled by range can recover without emitting stale output", function()
    local state, app, setDistance, target = targetingFixture(21)
    H.Equal(app.engine.counters.alerts, 0)
    setDistance(48)
    state:Fire("UNIT_FLAGS", "nameplate1")
    state:Advance(0.5)
    H.True(app.engine:Snapshot()[1].targeting)
    H.Equal(app.engine.counters.alerts, 0)
    H.False(app.ui.banner:IsShown())

    setDistance(21)
    state:Fire("UNIT_FLAGS", "nameplate1")
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "targeting")
    target(false)
    target(true)
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.False(app.ui.banner:IsShown())
end)

local function aliasedTargetingFixture()
    local state, app, _, nameplateTarget = targetingFixture(21)
    state:Unit("target", state.units.nameplate1)
    state:Unit("targettarget", state.units.player)
    local range = state.api.UnitDistanceSquared
    state.api.UnitDistanceSquared = function(token)
        if token == "target" then return 441, true end
        return range(token)
    end
    state:Fire("PLAYER_TARGET_CHANGED")
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.ui.activeBanner.kind, "targeting")
    local contact = app.engine:Snapshot()[1]
    H.True(contact.sources.nameplate)
    H.True(contact.sources.target)
    H.True(contact.targeting)
    return state, app, nameplateTarget, contact
end

for _, restricted in ipairs({ false, true }) do
    H.Test("rapid targeting changes supersede " .. (restricted and "restricted" or "unchanged") .. " alias evidence", function()
        local state, app, nameplateTarget, original = aliasedTargetingFixture()
        if restricted then
            local raw, secret = state.api.UnitIsUnit, H.Secret("restricted secondary target relation")
            state.api.UnitIsUnit = function(first, second)
                if first == "targettarget" and second == "player" then return secret end
                return raw(first, second)
            end
        end
        local now = state.clock.Now()
        nameplateTarget(false)
        H.False(app.engine:Snapshot()[1].targeting)
        app.ui:AdvanceBanner(now)
        H.Nil(app.ui.activeBanner)

        nameplateTarget(true)
        H.Equal(state.clock.Now(), now)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 2)
        H.Equal(app.engine.history[2].kind, "targeting")
        H.Equal(app.ui.activeBanner.id, original.id)
        H.True(app.ui.banner:IsShown())
    end)
end

H.Test("restricted UNIT_TARGET preserves independent positive alias evidence without rearming", function()
    local state, app, nameplateTarget, original = aliasedTargetingFixture()
    local now = state.clock.Now()
    nameplateTarget(nil)
    H.True(app.engine:Snapshot()[1].targeting)
    app.ui:AdvanceBanner(now)
    H.Equal(app.ui.activeBanner.id, original.id)
    nameplateTarget(true)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.ui.activeBanner.id, original.id)
end)

H.Test("a recycled nameplate with a negative target relation cannot reset the prior owner", function()
    local state, app, nameplateTarget, original = aliasedTargetingFixture()
    state:Unit("nameplate1", { guid = "Player-AliasReplacement", name = "Replacement", class = "MAGE", hostile = true, isPlayer = true })
    nameplateTarget(false)
    local preserved = app.engine:SelectedContact(original.id, original.identity)
    H.True(preserved.targeting)
    H.True(preserved.sources.target)
    H.Nil(preserved.sources.nameplate)
    app.ui:AdvanceBanner(state.clock.Now())
    H.Equal(app.ui.activeBanner.id, original.id)
    state:Fire("UNIT_TARGET", "target")
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
end)

H.Test("fresh same-owner UNIT_FACTION cancels a queued cast and retires the targeting banner", function()
    local state, app, _, original = aliasedTargetingFixture()
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-BeforeFaction", 1856)
    local priorUnit = state.units.nameplate1
    state:Unit("nameplate1", { guid = priorUnit.guid, name = priorUnit.name, class = priorUnit.class,
        hostile = false, isPlayer = true })
    state:Fire("UNIT_FACTION", "nameplate1")
    local current = assert(app.engine:SelectedContact(original.id, original.identity))
    H.Nil(current.sources.target)
    H.Nil(current.sources.nameplate)
    H.False(current.visible)
    H.False(current.hostile)
    app.ui:AdvanceBanner(state.clock.Now())
    H.Nil(app.ui.activeBanner)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(#app.engine.history, 1)
    H.False(app.ui.banner:IsShown())

    state:Unit("nameplate1", priorUnit)
    state:Fire("UNIT_FACTION", "nameplate1")
    current = assert(app.engine:SelectedContact(original.id, original.identity))
    H.True(current.hostile)
    H.True(current.targeting)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 2)
    H.Equal(app.engine.history[2].kind, "targeting")
    H.Equal(app.ui.activeBanner.id, original.id)
end)

H.Test("an unbound plate's clean UNIT_FACTION invalidates cached aliases of its indexed GUID", function()
    local state, app, _, original = aliasedTargetingFixture()
    local prior = state.units.nameplate1
    state:Unit("nameplate2", { guid = prior.guid, name = prior.name, class = prior.class,
        hostile = false, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    H.True(app.sensors.active.nameplate2 ~= nil)
    H.Nil(app.engine.bindings.nameplate2)
    H.True(app.engine:SelectedContact(original.id, original.identity).hostile)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-BeforeUnboundFaction", 1856)

    state:Fire("UNIT_FACTION", "nameplate2")
    local current = assert(app.engine:SelectedContact(original.id, original.identity))
    H.False(current.visible)
    H.False(current.hostile)
    app.ui:AdvanceBanner(state.clock.Now())
    H.Nil(app.ui.activeBanner)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)

    app.sensors:Poll()
    current = assert(app.engine:SelectedContact(original.id, original.identity))
    H.True(current.visible)
    H.True(current.hostile)
    H.True(current.targeting)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 2)
    H.Equal(app.engine.history[2].kind, "targeting")
end)

for _, scenario in ipairs({ "restricted", "recycled", "passive" }) do
    H.Test(scenario .. " faction evidence does not erase the other alias's confirmed hostility", function()
        local state, app, _, original = aliasedTargetingFixture()
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-BeforeAmbiguousFaction", 1856)
        if scenario == "restricted" then
            local read, secret = state.api.UnitIsEnemy, H.Secret("unreadable hostility")
            state.api.UnitIsEnemy = function(player, token)
                if token == "nameplate1" then return secret end
                return read(player, token)
            end
        else
            local prior = state.units.nameplate1
            state:Unit("nameplate1", { guid = scenario == "recycled" and "Player-FriendlyReplacement" or prior.guid,
                name = prior.name, class = prior.class, hostile = false, isPlayer = true })
        end
        if scenario == "passive" then app.sensors:Poll()
        else state:Fire("UNIT_FACTION", "nameplate1") end
        local current = assert(app.engine:SelectedContact(original.id, original.identity))
        H.True(current.sources.target)
        H.True(current.hostile)
        H.True(current.targeting)
        app.ui:AdvanceBanner(state.clock.Now())
        H.Equal(app.ui.activeBanner.id, original.id)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 2)
        H.Equal(app.engine.history[2].kind, "stealth")
        H.Equal(app.ui.activeBanner.id, original.id)
    end)
end

for _, scenario in ipairs({ { kind = "sighting", count = 1 }, { kind = "wave", count = 3 } }) do
    H.Test("a silent " .. scenario.kind .. " banner leaves sound budget for the next warning", function()
        local state, _, app = setup()
        local alerts = app.db:GetProfile().alerts
        alerts.sounds[scenario.kind] = "none"
        alerts.waveThreshold = 3
        alerts.soundGap = 10
        app:ProfileChanged()
        assert(app.db:SetList("guid:Player-Important", "watch", nil, { name = "Watch Rival" }))
        for index = 1, scenario.count do
            local token = "nameplate" .. index
            state:Unit(token, { guid = "Player-Silent-" .. index, name = "Ordinary " .. index, class = "ROGUE", hostile = true, isPlayer = true })
            state:Fire("NAME_PLATE_UNIT_ADDED", token)
        end
        state:Advance(1.5)
        H.Equal(app.ui.activeBanner.kind, scenario.kind)
        H.Equal(#state.sounds, 0)
        state:Unit("nameplate9", { guid = "Player-Important", name = "Watch Rival", class = "ROGUE", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate9")
        state:Advance(0.5)
        H.Equal(app.ui.activeBanner.kind, "watch")
        H.Equal(#state.sounds, 1)
    end)
end

H.Test("Why retains the winning rule and displays its distance scope through cooldown and suppression", function()
    local state, app, see, move = pendingRangeFixture(function(profile)
        profile.locale = "ruRU"
        profile.range.enabled, profile.range.yards, profile.range.policy = true, 35, "confirmed"
        local rule = soundRule("Private rule label", "quest", 80)
        rule.range, rule.rangePolicy = 20, "possible"
        profile.rules = { rule }
    end)
    local ui, profile = app.ui, app.db:GetProfile()
    local rule = profile.rules[1]
    local function show(reason, source, yards, policy, ruleVisible)
        local contact = app.engine:Snapshot()[1]
        local result = app:Explain(contact)
        H.Equal(result.reason, reason)
        H.Equal(result.ruleName, ruleVisible and rule.name or nil)
        H.Equal(result.rangeLimit.source, source)
        H.Equal(result.rangeLimit.yards, yards)
        H.Equal(result.rangeLimit.policy, policy)
        ui:Select(contact); ui:ShowExplanation()
        local frame = ui.explanationFrame
        local key = source == "rule" and "explanationRuleRange" or "explanationGlobalRange"
        H.True(frame.rangeEvidence:GetText():find(ui:F(key, yards, ui:T(policy)), 1, true) ~= nil)
        H.Equal(frame.rule:GetText(), ruleVisible and ui:F("explanationMatchedRule", rule.name) or "")
    end

    see(1, 18)
    show("custom_rule", "rule", 20, "possible", true)
    state:Advance(0.5)
    H.Equal(app.engine.history[1].reason, "custom_rule")
    show("cooldown", "rule", 20, "possible", true)
    move(1, 48)
    show("range_outside", "global", 35, "confirmed", false)
    move(1, 16)
    rule.action = "suppress"
    app:OnSettingsChanged()
    show("custom_suppressed", "rule", 20, "possible", true)
    rule.action, rule.sound, rule.banner = "alert", false, false
    app:OnSettingsChanged()
    show("outputs_disabled", "rule", 20, "possible", true)

    profile.display.streamer = true
    app:OnSettingsChanged()
    H.Equal(ui.explanationFrame.rule:GetText(), "")
    H.True(ui.explanationFrame.rangeEvidence:GetText():find(ui:F("explanationRuleRange", 20, ui:T("possible")), 1, true) ~= nil)
    local report = app:ExportDiagnostics()
    H.Nil(report:find(rule.name, 1, true))
    H.Nil(report:find("rangeLimit", 1, true))
end)

H.Test("Why refreshes live distance independently of an older selection and keeps only fresh alias evidence", function()
    local state, app, see, move = pendingRangeFixture(function(profile)
        profile.range.enabled, profile.range.yards, profile.range.policy, profile.range.unknown = true, 20, "confirmed", false
    end)
    local ui = app.ui
    see(1, 18)
    state:Unit("focus", state.units.nameplate1)
    state:Fire("PLAYER_FOCUS_CHANGED")
    local selected = app.engine:Snapshot()[1]
    ui:Select(selected); ui:ShowExplanation()
    local function valid(yards, reason)
        local result = app:Explain(selected)
        H.Equal(result.rangeMin, yards); H.Equal(result.rangeMax, yards)
        H.Equal(result.reason, reason)
        ui:ShowExplanation()
        local text = ui.explanationFrame.rangeEvidence:GetText()
        H.True(text:find(ui:F("rangeMeasured", yards), 1, true) ~= nil)
        H.True(text:find(ui:T("rangeEvidenceExact"), 1, true) ~= nil)
        return text
    end
    local first = valid(18, "event_matched")
    state.clock.Advance(0.2)
    move(1, 26)
    H.Equal(selected.rangeMax, 18)
    local current = valid(26, "range_outside")
    H.True(current ~= first)
    H.Nil(current:find(ui:F("rangeMeasured", 18), 1, true))
    H.True(current:find(ui:F("explanationGlobalRange", 20, ui:T("confirmed")), 1, true) ~= nil)

    local function unavailable(reason)
        local result = app:Explain(selected)
        H.Equal(result.reason, reason)
        H.Nil(result.rangeMin); H.Nil(result.rangeMax)
        ui:ShowExplanation()
        local text = ui.explanationFrame.rangeEvidence:GetText()
        for _, yards in ipairs({ 18, 26, 17 }) do H.Nil(text:find(ui:F("rangeMeasured", yards), 1, true)) end
    end
    state.clock.Advance(2.1)
    unavailable("range_unknown")
    H.Equal(app:Explain(selected).rangeEvidence, "unknown")

    move(1, 17)
    valid(17, "event_matched")
    state.units.nameplate1, state.plates.nameplate1 = nil, nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    unavailable("range_unknown")
    H.True(app.engine:Snapshot()[1].sources.focus)
    state.units.focus = nil
    state:Fire("PLAYER_FOCUS_CHANGED")
    unavailable("not_observed")
end)

H.Test("sample Why distinguishes the matching rule range from a blocking global scope", function()
    local _, _, app = setup()
    local ui, profile = app.ui, app.db:GetProfile()
    local rule = soundRule("Sample-only explanation fixture", "ready", 80)
    rule.range, rule.rangePolicy, rule.classes = 25, "possible", { ROGUE = true }
    profile.rules = { rule }
    app:OnSettingsChanged()
    app:Demo()
    ui.rows[1]:Click()
    H.True(ui.selected.preview)
    H.Equal(ui.selected.class, "ROGUE")
    local function show(reason, source, yards, policy)
        local explanation = app:Explain(ui.selected)
        H.Equal(explanation.reason, reason)
        H.Equal(explanation.ruleName, source == "rule" and rule.name or nil)
        H.Equal(explanation.rangeLimit.source, source)
        H.Equal(explanation.rangeLimit.yards, yards)
        H.Equal(explanation.rangeLimit.policy, policy)
        H.Equal(explanation.rangeMin, 8); H.Equal(explanation.rangeMax, 20)
        ui:ShowExplanation()
        local key = source == "rule" and "explanationRuleRange" or "explanationGlobalRange"
        H.True(ui.explanationFrame.rangeEvidence:GetText():find(ui:F(key, yards, ui:T(policy)), 1, true) ~= nil)
        H.True(ui.explanationFrame.rangeEvidence:GetText():find(ui:F("demoRange", ui:F("rangeBracket", 8, 20)), 1, true) ~= nil)
    end
    show("custom_rule", "rule", 25, "possible")
    profile.range.enabled, profile.range.yards, profile.range.policy = true, 10, "confirmed"
    app:OnSettingsChanged()
    show("range_unconfirmed", "global", 10, "confirmed")
    H.Equal(#app.db:GetJournal(), 0)
    H.Equal(#app.engine.history, 0)
end)

H.Test("Why shows a live contact's last sound outcome separately from current alert rules", function()
    local playback, requests = false, 0
    local state, RG, app = setup(nil, function(fixture)
        fixture.api.PlaySound = function()
            requests = requests + 1
            return playback
        end
    end)
    local ui, profile = app.ui, app.db:GetProfile()
    profile.alerts.waveThreshold = 20
    app:ProfileChanged()
    local function contact(index)
        local identity = "guid:Player-SoundOutcome-" .. index
        for _, view in ipairs(app.engine:Snapshot()) do if view.identity == identity then return view end end
        error("missing live sound outcome contact")
    end
    local function arrive(index)
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-SoundOutcome-" .. index, name = "Private Sound " .. index,
            class = "ROGUE", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    local function show(index, status, key)
        local current = contact(index)
        local result = app:Explain(current)
        H.True(type(result.lastSound) == "table")
        H.Equal(result.lastSound.kind, "sighting")
        H.Equal(result.lastSound.status, status)
        local cue = status ~= "not_requested" and "ping" or nil
        H.Equal(result.lastSound.soundCue, cue)
        ui:Select(current)
        ui:ShowExplanation()
        local expected = ui:T(key)
        if cue then expected = expected .. "\n" .. ui:F("soundCueEvidence", ui:T("soundPing")) end
        H.Equal(ui.explanationFrame.lastSound:GetText(), expected)
        H.True(ui.explanationFrame.lastSoundHeading:IsShown())
        H.Equal(ui.explanationFrame.lastSoundHeading:GetText(), ui:F("lastSoundHeading", ui:T("eventSighting")))
        return result
    end

    arrive(1)
    H.Nil(app:Explain(contact(1)).lastSound)
    state:Advance(1.25)
    H.Equal(requests, 1)
    H.Equal(show(1, "playback_unconfirmed", "lastSoundUnconfirmed").reason, "cooldown")

    playback = true
    state.clock.Advance(2)
    arrive(2)
    state:Advance(1.25)
    H.Equal(requests, 2)
    show(2, "playback_requested", "lastSoundRequested")
    arrive(3)
    state:Advance(1.1)
    H.Equal(requests, 2)
    show(3, "sound_gap", "lastSoundGap")
    H.Equal(app.engine.history[#app.engine.history].kind, "sighting")

    profile.alerts.sounds.sighting = "none"
    app:ProfileChanged()
    arrive(4)
    state:Advance(1.25)
    H.Equal(requests, 2)
    show(4, "not_requested", "lastSoundNotRequested")
    profile.alerts.enabled = false
    app:ProfileChanged()
    H.Equal(show(2, "playback_requested", "lastSoundRequested").reason, "disabled")
    H.Equal(ui.explanationFrame.reason:GetText(), RG.Locale.Reason("disabled", profile.locale))
    profile.locale = "ruRU"
    app:ProfileChanged()
    H.Equal(show(2, "playback_requested", "lastSoundRequested").reason, "disabled")
    H.Equal(ui.explanationFrame.reason:GetText(), RG.Locale.Reason("disabled", "ruRU"))

    ui:ShowDiagnostics()
    local report = ui.copyFrame.edit:GetText()
    H.Nil(report:find("Private Sound", 1, true))
    H.Nil(report:find("Player-SoundOutcome-", 1, true))
    H.Nil(report:find("lastSound=", 1, true))
    H.Nil(report:find("soundCue", 1, true))
    for _, status in ipairs({ "not_requested", "sound_gap", "playback_requested", "playback_unconfirmed" }) do
        H.Nil(report:find(status, 1, true))
    end
end)

H.Test("Why shows current custom and inherited cues without rewriting the last cue", function()
    local state, app, profile = ruleSoundFixture()
    local ui = app.ui
    profile.alerts.sounds.sighting = "ping"
    profile.alerts.cooldown = 0
    app:OnSettingsChanged()
    local function contact(index)
        local identity = "guid:Player-RuleCue" .. index
        for _, view in ipairs(app.engine:Snapshot()) do if view.identity == identity then return view end end
        error("missing sound cue contact")
    end
    local function show(index, current, currentLabel, historical, historicalLabel)
        local live = contact(index)
        local result = app:Explain(live)
        H.True(result.allowed); H.True(result.sound)
        H.Equal(result.soundCue, current)
        ui:Select(live)
        ui:ShowExplanation()
        local frame = ui.explanationFrame
        H.Equal(frame.outputs:GetText(), ui:T("explanationSoundBanner") .. "\n" .. ui:F("soundCueEvidence", ui:T(currentLabel)))
        if historical then
            H.Equal(result.lastSound.soundCue, historical)
            H.Equal(result.lastSound.status, "playback_requested")
            H.Equal(frame.lastSound:GetText(), ui:T("lastSoundRequested") .. "\n" .. ui:F("soundCueEvidence", ui:T(historicalLabel)))
        else
            H.Nil(result.lastSound)
            H.False(frame.lastSoundHeading:IsShown())
        end
    end

    seeSoundRuleRival(state, 1)
    show(1, "ping", "soundPing")
    state:Advance(1.25)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.MAP_PING)
    show(1, "ping", "soundPing", "ping", "soundPing")

    local custom = soundRule("Quest signal", "quest", 90)
    custom.cooldown = 0
    profile.rules = { custom }
    app:OnSettingsChanged()
    show(1, "quest", "soundQuest", "ping", "soundPing")
    state.clock.Advance(2)
    seeSoundRuleRival(state, 2)
    show(2, "quest", "soundQuest")
    state:Advance(0.5)
    H.Equal(state.sounds[2].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)

    custom.soundCue = "warning"
    profile.locale = "ruRU"
    app:OnSettingsChanged()
    show(2, "warning", "soundWarning", "quest", "soundQuest")

    profile.alerts.sound = false
    app:OnSettingsChanged()
    local muted = app:Explain(contact(2))
    H.Nil(muted.soundCue)
    H.Equal(muted.lastSound.soundCue, "quest")
    H.Equal(ui.explanationFrame.outputs:GetText(), ui:T("explanationBannerOnly"))
    H.Equal(#state.sounds, 2)
end)

H.Test("Why shows a wave member's sound outcome only for a live selection", function()
    local state, RG, app = setup()
    local ui = app.ui
    local profile = app.db:GetProfile()
    profile.alerts.cooldown, profile.locale = 0, "ruRU"
    app:OnSettingsChanged()
    local alert, shared = app.engine.onAlert
    app.engine.onAlert = function(decision)
        if decision.kind == "wave" then shared = decision end
        return alert(decision)
    end
    local function arrive(index)
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-WaveOutcome-" .. index, name = "Rival " .. index,
            class = "ROGUE", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    for index = 1, 3 do arrive(index) end
    state:Advance(1.25)
    H.Equal(app.engine.history[1].kind, "wave")
    H.Equal(#state.sounds, 1)
    local members = app.engine:Snapshot()
    local function containsParticipant(value)
        if type(value) == "table" then
            for key, child in pairs(value) do if containsParticipant(key) or containsParticipant(child) then return true end end
        elseif type(value) == "string" then
            for _, member in ipairs(members) do
                if value == member.id or value == member.identity or value == member.name then return true end
            end
        end
        return false
    end
    H.Equal(shared.count, 3)
    H.False(containsParticipant(shared)); H.False(containsParticipant(app.engine.history[1]))
    for _, view in ipairs(members) do
        local explanation = app:Explain(view)
        H.Equal(explanation.lastSound.kind, "wave")
        H.Equal(explanation.lastSound.status, "playback_requested")
        H.Equal(explanation.lastSound.soundCue, "ready")
        H.Equal(explanation.soundCue, "ping")
    end
    ui:Select(members[1]); ui:ShowExplanation()
    H.Equal(ui.explanationFrame.lastSoundHeading:GetText(), ui:F("lastSoundHeading", ui:T("eventWave")))
    H.Equal(ui.explanationFrame.lastSound:GetText(), ui:T("lastSoundRequested") .. "\n" .. ui:F("soundCueEvidence", ui:T("soundReady")))
    local report = app:ExportDiagnostics()
    for _, member in ipairs(members) do
        H.Nil(report:find(member.identity, 1, true)); H.Nil(report:find(member.name, 1, true))
    end
    arrive(4)
    state:Advance(1.25)
    local identity = "guid:Player-WaveOutcome-4"
    local live
    for _, view in ipairs(app.engine:Snapshot()) do if view.identity == identity then live = view break end end
    H.True(type(app:Explain(assert(live)).lastSound) == "table")

    local function assertNoSection()
        ui:ShowExplanation()
        H.False(ui.explanationFrame.lastSoundHeading:IsShown())
        H.Equal(ui.explanationFrame.lastSound:GetText(), "")
    end
    ui:OpenSettings("journal")
    H.Equal(ui.journalRows[1].contact.identity, identity)
    local recent = app:Explain(ui.journalRows[1].contact)
    H.Nil(recent.lastSound); H.Nil(recent.soundCue)
    ui.journalRows[1]:Click()
    ui:Refresh()
    assertNoSection()

    assert(app.db:SetList(identity, "watch", nil, { name = "Rival 4" }))
    ui.journalPersonal:Click()
    H.True(ui.journalRows[1].contact.savedOnly)
    local saved = app:Explain(ui.journalRows[1].contact)
    H.Nil(saved.lastSound); H.Nil(saved.soundCue)
    ui.journalRows[1]:Click()
    assertNoSection()

    app:Demo()
    ui.rows[1]:Click()
    H.True(ui.selected.preview)
    local sample = app:Explain(ui.selected)
    H.Equal(sample.soundCue, "ping")
    H.Nil(sample.lastSound)
    assertNoSection()
    H.Equal(ui.explanationFrame.outputs:GetText(), ui:T("explanationSoundBanner") .. "\n" .. ui:F("soundCueEvidence", ui:T("soundPing")))
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
    local name = app.ui.rows[1].nameText:GetText()
    H.True(name:match(" %d+$") ~= nil)
    H.Equal(app.ui.banner.body:GetText(), name)
end)

H.Test("a streamer banner delivered while Nearby is hidden shares its alias when the list reopens", function()
    local state, _, app = setup()
    local db, ui = app.db, app.ui
    local profile = db:GetProfile()
    profile.display.streamer, profile.display.showList = true, false
    profile.alerts.muteOrdinary = true
    app:OnSettingsChanged()
    local identity = "guid:Player-RuleCue1"
    assert(db:SetList(identity, "watch", "Keep this private", { name = "Private rival", class = "ROGUE" }))
    for index = 1, 13 do seeSoundRuleRival(state, index, index == 1 and "ROGUE" or "HUNTER") end
    state:Advance(0.5)
    H.False(ui.frame:IsShown())
    H.True(ui.banner:IsShown())
    local alias = ui.banner.body:GetText()
    H.True(alias:match(" %d+$") ~= nil)
    H.Nil(alias:find("Sound rival", 1, true))
    H.Equal(app.engine.counters.alerts, 1)
    ui:Toggle()
    H.True(ui.frame:IsShown())
    H.Equal(ui.rows[1].contact.identity, identity)
    H.Equal(ui.rows[1].nameText:GetText(), alias)
    ui.rows[1]:Click()
    H.Equal(ui.detailsFrame.title:GetText(), alias)
    H.False(ui.detailsFrame.note:IsShown())
    H.Equal(ui.detailsFrame.note:GetText(), "")
    ui.frame.scripts.OnMouseWheel(ui.frame, -100)
    H.True(ui.rows[1].contact.identity ~= identity)
    H.Equal(ui.detailsFrame.title:GetText(), alias)
    ui.frame.scripts.OnMouseWheel(ui.frame, 100)
    H.Equal(ui.rows[1].nameText:GetText(), alias)
    H.Equal(ui.banner.body:GetText(), alias)
    H.Equal(db:GetList()[identity].note, "Keep this private")
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

H.Test("Nearby right-click opens the profile chooser and existing Settings and minimap clicks still work", function()
    local state, _, app = setup(nil, function(mock)
        mock.api.CreateFrame("Frame", "Minimap", mock.api.UIParent):SetSize(160, 160)
    end)
    local ui = app.ui
    local settingsButton
    for _, child in ipairs(ui.frame.children) do
        if child.label and child.label:GetText() == "…" then settingsButton = child; break end
    end
    local ellipsis = assert(settingsButton)
    ellipsis:Click("RightButton")
    local picker = assert(ui.profilePicker, "Nearby right click did not open the profile chooser")
    H.Equal(ui.nearbySettingsButton, ellipsis)
    H.Equal(ellipsis.clickButtons[1], "LeftButtonUp")
    H.Equal(ellipsis.clickButtons[2], "RightButtonUp")
    H.True(picker:IsShown())
    H.False(ui.settings:IsShown())

    picker.manage:Click()
    H.False(picker:IsShown())
    H.True(ui.settings:IsShown()); H.Equal(ui.currentPage, "profiles")
    ui.settings:Hide()
    ellipsis:Click("LeftButton")
    H.True(ui.settings:IsShown()); H.False(picker:IsShown())
    ui.settings:Hide()
    local launcher = assert(ui.launcher).frame
    launcher:Click("RightButton")
    H.True(ui.settings:IsShown()); H.False(picker:IsShown())
    ui.settings:Hide()
    H.True(ui.frame:IsShown())
    launcher:Click("LeftButton"); H.False(ui.frame:IsShown())
    launcher:Click("LeftButton"); H.True(ui.frame:IsShown())
    state.api.SlashCmdList.RIVALGUARD("profile")
    H.True(picker:IsShown())
end)

H.Test("slash profile selects the exact Unicode name, rechecks queued alerts, and persists", function()
    local state, _, app = setup()
    local db, ui = app.db, app.ui
    local original = db:GetProfile()
    local name = "Боевой профиль"
    local hunter = assert(db:CreateProfile(name))
    hunter.alerts.classes = { HUNTER = true }
    seeSoundRuleRival(state, 1, "ROGUE")
    local slash = state.api.SlashCmdList.RIVALGUARD
    slash("profile боевой профиль")
    H.Equal(db:GetActiveProfileName(), "Default")
    H.True(ui.frame:IsShown())
    H.True(state.messages[#state.messages]:find(ui:T("profileMissing"), 1, true) ~= nil)
    slash("profile " .. name)
    H.Equal(db:GetActiveProfileName(), name)
    H.Equal(db:GetProfile(), hunter)
    H.Equal(app.engine.profile, hunter)
    H.True(state.messages[#state.messages]:find(ui:F("profileUsed", name), 1, true) ~= nil)
    H.Nil(next(original.alerts.classes))
    H.Equal(app.engine.counters.alerts, 0)
    seeSoundRuleRival(state, 2, "HUNTER")
    state:Advance(1.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(ui.activeBanner.name, "Sound rival 2")
    H.Equal(#state.sounds, 1)

    state:Fire("PLAYER_LOGOUT")
    local _, _, reloaded = setup(state.api.RivalGuardDB)
    H.Equal(reloaded.db:GetActiveProfileName(), name)
    H.True(reloaded.db:GetProfile().alerts.classes.HUNTER)
    H.Nil(reloaded.db:GetProfile().alerts.classes.ROGUE)
end)

local function quickProfileRow(picker, profileName)
    for _, row in ipairs(picker.rows) do
        if row:IsShown() and row.profileName == profileName then return row end
    end
end

H.Test("the profile chooser paginates and stale names never activate replacement profiles", function()
    local state, _, app = setup()
    local db, ui = app.db, app.ui
    for index = 1, 11 do assert(db:CreateProfile(string.format("Field %02d", index))) end
    local slash = state.api.SlashCmdList.RIVALGUARD
    slash("profile")
    local picker = assert(ui.profilePicker)
    H.True(picker:IsShown())
    H.Equal(#picker.rows, 8)
    local current = assert(quickProfileRow(picker, "Default"))
    H.False(current.enabled)
    H.Equal(current.label:GetText(), ui:F("currentProfileChoice", "Default"))
    H.True(picker.next.enabled); H.False(picker.previous.enabled)
    H.True(quickProfileRow(picker, "Field 07") ~= nil)
    H.Nil(quickProfileRow(picker, "Field 08"))
    picker.next:Click()
    H.True(picker.previous.enabled); H.False(picker.next.enabled)
    H.True(quickProfileRow(picker, "Field 11") ~= nil)
    H.Nil(quickProfileRow(picker, "Default"))
    picker.previous:Click()
    H.False(assert(quickProfileRow(picker, "Default")).enabled)
    picker.next:Click()

    local replaced = assert(quickProfileRow(picker, "Field 10"))
    assert(db:DeleteProfile("Field 10"))
    assert(db:CreateProfile("Field 10", "quiet"))
    replaced:Click()
    H.Equal(db:GetActiveProfileName(), "Default")
    H.False(picker:IsShown())
    slash("profile")
    if not quickProfileRow(picker, "Field 10") then picker.next:Click() end
    local removed = assert(quickProfileRow(picker, "Field 11"))
    assert(db:DeleteProfile("Field 11"))
    assert(db:CreateProfile("Field 12"))
    removed:Click()
    H.Equal(db:GetActiveProfileName(), "Default")
    H.False(picker:IsShown())

    slash("profile")
    if not quickProfileRow(picker, "Field 10") then picker.next:Click() end
    assert(quickProfileRow(picker, "Field 10")):Click()
    H.Equal(db:GetActiveProfileName(), "Field 10")
    H.False(picker:IsShown())
    H.False(db:GetProfile().alerts.sound)

    slash("profile")
    slash("profile Field 01")
    H.Equal(db:GetActiveProfileName(), "Field 01")
    H.False(picker:IsShown())
    slash("profile")
    if not quickProfileRow(picker, "Field 01") then picker.previous:Click() end
    H.False(assert(quickProfileRow(picker, "Field 01")).enabled)

    picker.manage:Click()
    for _, row in ipairs(ui.profileRows) do
        if row.profileName == "Field 02" then row.use:Click(); break end
    end
    H.Equal(db:GetActiveProfileName(), "Field 02")
    H.Equal(app.engine.profile, db:GetProfile())
    H.True(state.messages[#state.messages]:find(ui:F("profileUsed", "Field 02"), 1, true) ~= nil)
end)

H.Test("direct preset choices distinguish saving a paginated profile from creating and using one", function()
    local state, _, app = setup(nil, function(mock) mock.locale = "ruRU" end)
    local db, ui = app.db, app.ui
    local original = db:GetProfile()
    for index = 1, 10 do assert(db:CreateProfile(string.format("Field %02d", index))) end
    ui.scroll:SetHeight(260)
    ui:OpenSettings("profiles")
    local function visibleRow(name)
        for _, row in ipairs(ui.profileRows) do
            if row:IsShown() and row.profileName == name then return row end
        end
    end
    local presets = assert(ui.presetChoices, "direct preset controls are missing")
    H.False(presets.balanced.enabled)
    local count = #db:ListProfiles()
    for _, preset in ipairs({ "farming", "quiet", "battleground", "balanced", "quiet" }) do
        H.True(presets[preset].enabled)
        presets[preset]:Click()
        H.False(presets[preset].enabled)
        H.Equal(presets[preset].label:GetText(), ui:T(preset))
        H.Equal(ui.presetDescription:GetText(), ui:T(preset .. "Tip"))
        H.Equal(#db:ListProfiles(), count)
        H.Equal(db:GetProfile(), original)
    end

    local reserve = "Зулу резерв"
    ui.profileInput:SetText(reserve)
    ui.createProfile:Click()
    H.Equal(#db:ListProfiles(), count + 1)
    H.Equal(db:GetProfile(reserve).preset, "quiet")
    H.False(db:GetProfile(reserve).alerts.sound)
    H.Equal(db:GetProfile(), original)
    H.Equal(app.engine.profile, original)
    local saved = assert(visibleRow(reserve), "new inactive profile should be paged into view")
    H.True(saved.use.enabled)
    local _, _, _, _, rowY = saved:GetPoint(1)
    local rowTop, scrollTop = -rowY, ui.scroll:GetVerticalScroll()
    H.True(rowTop > ui.scroll:GetHeight())
    H.True(rowTop >= scrollTop and rowTop + saved:GetHeight() <= scrollTop + ui.scroll:GetHeight())
    H.True(state.messages[#state.messages]:find(ui:F("profileCreated", reserve), 1, true) ~= nil)
    H.Equal(ui.profileInput:GetText(), "")

    presets.battleground:Click()
    ui.profileInput:SetText(reserve)
    ui.createAndUseProfile:Click()
    H.Equal(ui.profileInput:GetText(), reserve)
    H.Equal(db:GetProfile(), original)
    H.Equal(db:GetProfile(reserve).preset, "quiet")
    H.Equal(#db:ListProfiles(), count + 1)

    seeSoundRuleRival(state, 1, "ROGUE")
    local matches = "Штурм поля боя"
    ui.profileInput:SetText(matches)
    ui.profileInput.scripts.OnEnterPressed(ui.profileInput)
    local current = db:GetProfile()
    H.Equal(db:GetActiveProfileName(), matches)
    H.Equal(app.engine.profile, current)
    H.Equal(current.preset, "battleground")
    H.Equal(app:AlertBlock(true), "context_disabled")
    H.False(assert(visibleRow(matches), "new active profile should be paged into view").use.enabled)
    H.True(ui.activeProfileText:GetText():find(matches, 1, true) ~= nil)
    H.Equal(ui.profileInput:GetText(), "")
    H.Equal(#db:ListProfiles(), count + 2)
    state:Advance(1.5)
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#state.sounds, 0)
    H.True(original.context.world); H.True(original.alerts.sound)

    presets.farming:Click()
    ui.profileInput:SetText("Фарм отдельно")
    ui.createAndUseProfile:Click()
    H.Equal(db:GetActiveProfileName(), "Фарм отдельно")
    H.Equal(app.engine.profile.preset, "farming")
    H.False(assert(visibleRow("Фарм отдельно")).use.enabled)

    for index = #db:ListProfiles() + 1, 20 do assert(db:CreateProfile(string.format("Filler %02d", index))) end
    local currentAtLimit = db:GetProfile()
    ui.profileInput:SetText("Лимит профилей")
    ui.createAndUseProfile:Click()
    H.Equal(#db:ListProfiles(), 20)
    H.Equal(ui.profileInput:GetText(), "Лимит профилей")
    H.Equal(db:GetProfile(), currentAtLimit)
    H.True(state.messages[#state.messages]:find(ui:T("profileLimit"), 1, true) ~= nil)
end)

local function profileSettingsRow(ui, name)
    for _, row in ipairs(ui.profileRows) do
        if row:IsShown() and row.profileName == name then return row end
    end
    error("missing profile row " .. name)
end

H.Test("renaming the active profile preserves its object and queued alert and reloads by the new exact name", function()
    local state, RG, app = setup(nil, function(mock) mock.locale = "ruRU" end)
    local db, ui = app.db, app.ui
    local active = assert(db:CreateProfile("Before rename"))
    active.alerts.classes = { ROGUE = true }
    assert(app:UseProfile("Before rename"))
    seeSoundRuleRival(state, 1)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-BeforeProfileRename", 1856)
    H.Equal(#app.engine.pending, 1)
    local pending, frame = RG.Codec.Encode(app.engine.pending), app.sensors.frame
    local generation = app.sensors.active.nameplate1.generation
    local original = RG.Codec.Encode(db:GetProfile("Default"))

    ui:OpenSettings("profiles")
    H.False(profileSettingsRow(ui, "Default").rename.enabled)
    profileSettingsRow(ui, "Before rename").rename:Click()
    local dialog = assert(ui.profileRenameDialog)
    H.True(dialog:IsShown())
    H.Equal(dialog.input:GetText(), "Before rename")
    for _, invalid in ipairs({ "Default", "Invalid\tname", "   " }) do
        dialog.input:SetText(invalid)
        dialog.apply:Click()
        H.True(dialog:IsShown())
        H.Equal(dialog.input:GetText(), invalid)
        H.Equal(db:GetActiveProfileName(), "Before rename")
        H.Equal(db:GetProfile(), active)
        H.Equal(#db:ListProfiles(), 2)
        H.Equal(dialog.feedback:GetText(), ui:T("profileError"))
    end

    local name = "Новый боевой профиль"
    dialog.input:SetText("  " .. name .. "  ")
    dialog.input.scripts.OnEnterPressed(dialog.input)
    H.False(dialog:IsShown())
    H.Nil(db:GetProfile("Before rename"))
    H.Equal(db:GetProfile(name), active)
    H.Equal(db:GetActiveProfileName(), name)
    H.Equal(app.engine.profile, active)
    H.Equal(app.sensors.frame, frame)
    H.Equal(app.sensors.active.nameplate1.generation, generation)
    H.True(app.sensors.running)
    H.Equal(RG.Codec.Encode(app.engine.pending), pending)
    H.Equal(RG.Codec.Encode(db:GetProfile("Default")), original)
    H.True(ui.activeProfileText:GetText():find(name, 1, true) ~= nil)
    H.True(state.messages[#state.messages]:find(ui:F("profileRenamed", name), 1, true) ~= nil)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "stealth")

    local slash = state.api.SlashCmdList.RIVALGUARD
    slash("profile Default")
    slash("profile Before rename")
    H.Equal(db:GetActiveProfileName(), "Default")
    H.True(state.messages[#state.messages]:find(ui:T("profileMissing"), 1, true) ~= nil)
    slash("profile " .. name)
    H.Equal(db:GetActiveProfileName(), name)
    state:Fire("PLAYER_LOGOUT")
    local _, _, fresh = setup(state.api.RivalGuardDB)
    H.Equal(fresh.db:GetActiveProfileName(), name)
    H.True(fresh.db:GetProfile().alerts.classes.ROGUE)
    H.Nil(fresh.db:GetProfile("Before rename"))
end)

H.Test("renaming an inactive profile preserves the active selection and rejects a stale source", function()
    local _, _, app = setup()
    local db, ui = app.db, app.ui
    local active = db:GetProfile()
    local quiet = assert(db:CreateProfile("Inactive original", "quiet"))
    assert(db:CreateProfile("Stale original", "battleground"))
    ui:OpenSettings("profiles")
    profileSettingsRow(ui, "Inactive original").rename:Click()
    local dialog = assert(ui.profileRenameDialog)
    dialog.input:SetText("Inactive renamed")
    dialog.apply:Click()
    H.Equal(db:GetProfile("Inactive renamed"), quiet)
    H.Nil(db:GetProfile("Inactive original"))
    H.Equal(db:GetProfile(), active); H.Equal(app.engine.profile, active)
    H.True(app.sensors.running)
    H.True(profileSettingsRow(ui, "Inactive renamed").use.enabled)

    profileSettingsRow(ui, "Stale original").rename:Click()
    H.True(dialog:IsShown())
    assert(db:DeleteProfile("Stale original"))
    local replacement = assert(db:CreateProfile("Stale original", "farming"))
    dialog.input:SetText("Must not replace")
    dialog.apply:Click()
    H.Equal(db:GetProfile("Stale original"), replacement)
    H.Nil(db:GetProfile("Must not replace"))
    H.Equal(db:GetProfile(), active)
    H.Equal(dialog.feedback:GetText(), ui:T("profileMissing"))
    H.False(dialog.apply.enabled)
    dialog.input.scripts.OnEscapePressed(dialog.input)
    H.False(dialog:IsShown())
end)

H.Test("a named inactive-profile confirmation preserves pending work and journal state", function()
    local state, RG, app = setup(nil, function(mock) mock.locale = "ruRU" end)
    local db, ui = app.db, app.ui
    local active = assert(db:CreateProfile("Active profile"))
    local name = "Удаляемый профиль"
    local inactive = assert(db:CreateProfile(name, "quiet"))
    assert(app:UseProfile("Active profile"))
    local savedRival = "guid:Player-SavedRival"
    assert(db:SetList(savedRival, "watch", "Seen at the outpost", { name = "SavedRival", class = "HUNTER" }))
    local list = RG.Codec.Encode(db:GetList())
    seeSoundRuleRival(state, 1)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-BeforeProfileDelete", 1856)
    local generation, pending = app.sensors.active.nameplate1.generation, RG.Codec.Encode(app.engine.pending)
    local journal = RG.Codec.Encode(db:GetJournal())
    H.Equal(#app.engine.pending, 1)
    local changed, prune, changes, prunes = app.ProfileChanged, db.Prune, 0, 0
    app.ProfileChanged = function(self, ...)
        changes = changes + 1
        return changed(self, ...)
    end
    db.Prune = function(self, ...)
        prunes = prunes + 1
        return prune(self, ...)
    end
    ui:OpenSettings("profiles")
    H.False(profileSettingsRow(ui, "Default").delete.enabled)
    H.False(profileSettingsRow(ui, "Active profile").delete.enabled)
    profileSettingsRow(ui, name).delete:Click()
    local dialog = assert(ui.profileDeleteDialog, "profile confirmation did not open")
    H.True(dialog:IsShown())
    H.Equal(dialog.current:GetText(), name)
    dialog.cancel:Click()
    H.False(dialog:IsShown())
    H.Equal(db:GetProfile(name), inactive)
    H.Equal(RG.Codec.Encode(app.engine.pending), pending)

    profileSettingsRow(ui, name).delete:Click()
    state.api.SlashCmdList.RIVALGUARD("profile")
    H.True(ui.profilePicker:IsShown())
    H.True(dialog:IsShown())
    dialog.apply:Click()
    H.False(dialog:IsShown())
    H.False(ui.profilePicker:IsShown())
    H.Nil(db:GetProfile(name))
    H.Equal(db:GetProfile(), active); H.Equal(app.engine.profile, active)
    H.Equal(changes, 0); H.Equal(prunes, 0)
    H.Equal(app.sensors.active.nameplate1.generation, generation)
    H.Equal(RG.Codec.Encode(app.engine.pending), pending)
    H.Equal(RG.Codec.Encode(db:GetJournal()), journal)
    H.Equal(RG.Codec.Encode(db:GetList()), list)
    H.True(state.messages[#state.messages]:find(ui:F("profileDeleted", name), 1, true) ~= nil)
    for _, row in ipairs(ui.profileRows) do H.True(row.profileName ~= name) end
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "stealth")
    state:Fire("PLAYER_LOGOUT")
    local _, _, fresh = setup(state.api.RivalGuardDB)
    H.Nil(fresh.db:GetProfile(name))
    H.Equal(fresh.db:GetActiveProfileName(), "Active profile")
    H.Equal(fresh.db:GetList()[savedRival].note, "Seen at the outpost")
end)

for _, change in ipairs({ "replacement", "activation" }) do
    H.Test("profile deletion rejects a previously confirmed " .. change, function()
        local _, _, app = setup()
        local db, ui = app.db, app.ui
        local name = "Do not delete"
        local expected = assert(db:CreateProfile(name, "battleground"))
        ui:OpenSettings("profiles")
        profileSettingsRow(ui, name).delete:Click()
        local dialog = assert(ui.profileDeleteDialog)
        H.True(dialog:IsShown())
        H.Equal(dialog.current:GetText(), name)
        if change == "replacement" then
            assert(db:DeleteProfile(name))
            expected = assert(db:CreateProfile(name, "quiet"))
        else
            assert(app:UseProfile(name))
            H.Equal(app.engine.profile, expected)
        end
        dialog.apply:Click()
        H.Equal(db:GetProfile(name), expected)
        H.Equal(db:GetActiveProfileName(), change == "activation" and name or "Default")
        H.Equal(dialog.feedback:GetText(), ui:T(change == "activation" and "deleteProfileActive" or "profileMissing"))
        H.False(dialog.apply.enabled)
    end)
end

H.Test("copying an inactive profile saves an independent Unicode profile without interrupting a queued alert", function()
    local state, RG, app = setup(nil, function(mock) mock.locale = "ruRU" end)
    local db, ui = app.db, app.ui
    local active = db:GetProfile()
    local source = assert(db:CreateProfile("Copy source", "quiet"))
    source.alerts.classes, source.alerts.sounds.stealth = { HUNTER = true }, "quest"
    source.range.enabled, source.range.yards = true, 25
    local rule = soundRule("Source cue", "quest", 85)
    rule.classes = { HUNTER = true }
    source.rules = { rule }
    for index = 1, 9 do assert(db:CreateProfile(string.format("Field %02d", index))) end
    seeSoundRuleRival(state, 1)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-BeforeProfileCopy", 1856)
    assert(db:SetList("guid:Player-CopyLocal", "watch", "Local note", { name = "Local rival" }))
    local pending = RG.Codec.Encode(app.engine.pending)
    local personal, history = RG.Codec.Encode(db:GetList()), RG.Codec.Encode(db:GetJournal())
    local generation, frame = app.sensors.active.nameplate1.generation, app.sensors.frame
    local changed, changes = app.ProfileChanged, 0
    app.ProfileChanged = function(self, ...)
        changes = changes + 1
        return changed(self, ...)
    end

    ui:OpenSettings("profiles")
    H.True(profileSettingsRow(ui, "Default").copy.enabled)
    profileSettingsRow(ui, "Copy source").copy:Click()
    local dialog = assert(ui.profileCopyDialog)
    H.True(dialog:IsShown())
    H.Equal(dialog.current:GetText(), "Copy source")
    local name = "Резервный профиль"
    dialog.input:SetText("  " .. name .. "  ")
    dialog.input.scripts.OnEnterPressed(dialog.input)
    H.False(dialog:IsShown())
    local copied = assert(db:GetProfile(name))
    H.True(copied ~= source)
    H.Equal(RG.Codec.Encode(copied), RG.Codec.Encode(source))
    H.True(copied.alerts ~= source.alerts and copied.alerts.sounds ~= source.alerts.sounds)
    H.True(copied.rules[1] ~= rule and copied.rules[1].classes ~= rule.classes)
    copied.alerts.sounds.stealth, copied.rules[1].classes.HUNTER = "warning", false
    H.Equal(source.alerts.sounds.stealth, "quest"); H.True(rule.classes.HUNTER)
    H.True(profileSettingsRow(ui, name).use.enabled)
    H.Equal(db:GetProfile(), active); H.Equal(app.engine.profile, active)
    H.Equal(changes, 0)
    H.Equal(app.sensors.frame, frame); H.Equal(app.sensors.active.nameplate1.generation, generation)
    H.Equal(RG.Codec.Encode(app.engine.pending), pending)
    H.Equal(RG.Codec.Encode(db:GetList()), personal); H.Equal(RG.Codec.Encode(db:GetJournal()), history)
    state:Advance(0.5)
    H.Equal(app.engine.history[1].kind, "stealth")
    state:Fire("PLAYER_LOGOUT")
    local _, _, fresh = setup(state.api.RivalGuardDB)
    H.Equal(fresh.db:GetActiveProfileName(), "Default")
    H.Equal(fresh.db:GetProfile(name).alerts.sounds.stealth, "warning")
    H.Equal(fresh.db:GetProfile("Copy source").alerts.sounds.stealth, "quest")
end)

H.Test("explicit profile copying can switch and rejects stale, duplicate, and full targets", function()
    local _, _, app = setup()
    local db, ui = app.db, app.ui
    local default = db:GetProfile()
    assert(db:CreateProfile("Copy from here", "farming"))
    ui:OpenSettings("profiles")
    profileSettingsRow(ui, "Copy from here").copy:Click()
    local dialog = assert(ui.profileCopyDialog)
    dialog.input:SetText("Default")
    dialog.applyAndUse:Click()
    H.True(dialog:IsShown())
    H.Equal(dialog.feedback:GetText(), ui:T("profileError"))
    H.Equal(dialog.input:GetText(), "Default")
    H.Equal(db:GetProfile(), default)
    H.Equal(#db:ListProfiles(), 2)

    assert(db:DeleteProfile("Copy from here"))
    local replacement = assert(db:CreateProfile("Copy from here", "quiet"))
    replacement.enabled = false
    dialog.input:SetText("Must not copy")
    dialog.apply:Click()
    H.Equal(dialog.feedback:GetText(), ui:T("profileMissing"))
    H.Nil(db:GetProfile("Must not copy"))
    H.Equal(db:GetProfile("Copy from here"), replacement)
    H.Equal(db:GetProfile(), default)
    dialog.input.scripts.OnEscapePressed(dialog.input)
    H.False(dialog:IsShown())

    profileSettingsRow(ui, "Copy from here").copy:Click()
    dialog.input:SetText("Activated copy")
    dialog.applyAndUse:Click()
    H.False(dialog:IsShown())
    H.Equal(db:GetActiveProfileName(), "Activated copy")
    H.Equal(app.engine.profile, db:GetProfile())
    H.True(db:GetProfile() ~= replacement)
    H.False(app.sensors.running)
    H.Equal(app:Status().detectionState, "disabled")
    for index = #db:ListProfiles() + 1, 20 do assert(db:CreateProfile(string.format("Filler %02d", index))) end
    ui:OpenSettings("profiles")
    profileSettingsRow(ui, "Activated copy").copy:Click()
    dialog.input:SetText("At capacity")
    dialog.apply:Click()
    H.True(dialog:IsShown())
    H.Equal(dialog.feedback:GetText(), ui:T("profileLimit"))
    H.Equal(dialog.input:GetText(), "At capacity")
    H.Nil(db:GetProfile("At capacity"))
    H.Equal(db:GetActiveProfileName(), "Activated copy")
    H.Equal(#db:ListProfiles(), 20)
end)

local function profileImportPayload(RG, detectionEnabled)
    local detached = RG.Database.New()
    local profile = detached:GetProfile()
    profile.enabled = detectionEnabled
    profile.alerts.sound, profile.alerts.banner = false, true
    profile.alerts.classes = { HUNTER = true, ROGUE = true }
    profile.context.world, profile.context.arena = false, true
    profile.rules = { soundRule("Imported example", "quest", 80) }
    return assert(detached:ExportProfile())
end

H.Test("validated inactive import reveals the normalized profile without replacing active or private data", function()
    local _, RG, app = setup(nil, function(mock) mock.locale = "ruRU" end)
    local db, ui = app.db, app.ui
    local original = db:GetProfile()
    for index = 1, 10 do assert(db:CreateProfile(string.format("Field %02d", index))) end
    local key = "guid:Player-ImportPrivate"
    assert(db:SetList(key, "watch", "Local private note", { name = "Local name", class = "ROGUE" }))
    assert(db:Record({ identity = key, name = "Local name", class = "ROGUE" }, app.engine.epoch()))
    local listBefore, historyBefore = RG.Codec.Encode(db:GetList()), RG.Codec.Encode(db:GetJournal())
    local encoded = profileImportPayload(RG, true)
    ui.scroll:SetHeight(260)
    ui:OpenSettings("profiles")
    ui:OpenTransfer("import")
    local dialog = ui.transferDialog
    local name = "Импорт карты"
    local function enabled(expected)
        H.Equal(dialog.apply.enabled, expected)
        H.Equal(dialog.applyAndUse.enabled, expected)
    end
    enabled(false)
    dialog.nameInput:SetText("  " .. name .. "  ")
    dialog.edit:SetText(encoded)
    enabled(false)
    dialog.apply:Click(); dialog.applyAndUse:Click()
    H.Nil(db:GetProfile(name))
    dialog.preview:Click()
    enabled(true)
    local summary = dialog.summary:GetText()
    H.Equal(summary, table.concat({
        ui:F("importPreview", ui:T("importOn"), ui:T("importOn"), 1),
        ui:F("importPreviewOutput", ui:T("importOff"), ui:T("importOn"), RG.Locale.Class("HUNTER", "ruRU") .. ", " .. RG.Locale.Class("ROGUE", "ruRU")),
        ui:F("importPreviewAreas", ui:T("battleground") .. ", " .. ui:T("arena")),
    }, "\n"))
    H.Nil(summary:find("Local private note", 1, true))
    H.Nil(summary:find(key, 1, true))
    dialog.edit:SetText(encoded .. " ")
    enabled(false)
    dialog.apply:Click(); dialog.applyAndUse:Click()
    H.Nil(db:GetProfile(name))

    dialog.edit:SetText(encoded)
    dialog.preview:Click()
    enabled(true)
    dialog:Hide()
    enabled(false)
    dialog.apply:Click(); dialog.applyAndUse:Click()
    H.Nil(db:GetProfile(name))
    ui:OpenTransfer("import")
    enabled(false)
    dialog.edit:SetText(encoded)
    dialog.preview:Click()
    dialog.nameInput:SetText("Default")
    dialog.apply:Click(); dialog.applyAndUse:Click()
    H.Equal(db:GetProfile(), original)
    H.Equal(#db:ListProfiles(), 11)
    H.True(dialog:IsShown())

    dialog.nameInput:SetText("  " .. name .. "  ")
    dialog.preview:Click()
    dialog.apply:Click()
    H.False(dialog:IsShown())
    H.Equal(db:GetActiveProfileName(), "Default")
    H.Equal(app.engine.profile, original)
    local imported = assert(db:GetProfile(name))
    H.False(imported.alerts.sound); H.True(imported.alerts.banner)
    H.True(imported.alerts.classes.ROGUE); H.True(imported.context.arena)
    H.Equal(imported.rules[1].soundCue, "quest")
    H.Equal(ui.currentPage, "profiles")
    local importedRow
    for _, row in ipairs(ui.profileRows) do if row.profileName == name then importedRow = row; break end end
    H.True(assert(importedRow).use.enabled)
    local _, _, _, _, rowY = importedRow:GetPoint(1)
    local scroll = ui.scroll:GetVerticalScroll()
    H.True(-rowY >= scroll and -rowY + importedRow:GetHeight() <= scroll + ui.scroll:GetHeight())
    H.Equal(RG.Codec.Encode(db:GetList()), listBefore)
    H.Equal(RG.Codec.Encode(db:GetJournal()), historyBefore)
end)

H.Test("explicitly activating an imported profile updates detection and the profile picker", function()
    local state, RG, app = setup()
    local db, ui = app.db, app.ui
    seeSoundRuleRival(state, 1)
    H.True(app.sensors.running)
    H.True(#app.engine.pending > 0)
    local original, name = db:GetProfile(), "Imported quiet profile"
    assert(db:SetList("guid:Player-LocalImport", "avoid", "Keep local", { name = "Local only" }))
    local listBefore, historyBefore = RG.Codec.Encode(db:GetList()), RG.Codec.Encode(db:GetJournal())
    local encoded = profileImportPayload(RG, false)
    ui:OpenSettings("profiles")
    ui:OpenTransfer("import")
    local dialog = ui.transferDialog
    dialog.nameInput:SetText(name)
    dialog.edit:SetText(encoded)
    dialog.preview:Click()
    H.True(dialog.applyAndUse.enabled)
    dialog.applyAndUse:Click()
    H.False(dialog:IsShown())
    H.Equal(db:GetActiveProfileName(), name)
    H.Equal(app.engine.profile, db:GetProfile())
    H.False(app.sensors.running)
    H.Equal(#app.engine.pending, 0)
    H.Equal(app:Status().detectionState, "disabled")
    H.Equal(RG.Codec.Encode(db:GetList()), listBefore)
    H.Equal(RG.Codec.Encode(db:GetJournal()), historyBefore)

    local slash = state.api.SlashCmdList.RIVALGUARD
    slash("profile")
    H.False(assert(quickProfileRow(ui.profilePicker, name)).enabled)
    slash("profile Default")
    H.False(ui.profilePicker:IsShown())
    H.Equal(db:GetProfile(), original); H.Equal(app.engine.profile, original)
    H.True(app.sensors.running)
end)

H.Test("pause control resumes immediately and expires in an otherwise idle world", function()
    local state, _, app = setup()
    local slash = state.api.SlashCmdList.RIVALGUARD
    state.api.GetCVarBool = function() return true end
    state.clock.Advance(2)
    slash("pause 1")
    state:Advance(0.3)
    H.Equal(app.ui.pauseButton.label:GetText(), app.ui:T("resume"))
    slash("resume")
    state:Advance(0.3)
    H.Equal(app.ui.pauseButton.label:GetText(), app.ui:T("pause"))

    state.clock.Advance(2)
    slash("pause 1")
    state:Advance(0.3)
    H.Equal(app.ui.pauseButton.label:GetText(), app.ui:T("resume"))
    state:Advance(61)
    H.Nil(app.engine.pausedUntil)
    H.Equal(app.ui.pauseButton.label:GetText(), app.ui:T("pause"))
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

H.Test("demo rows check the current profile with trusted synthetic inputs", function()
    local state, RG, app = setup()
    local profile = app.db:GetProfile()
    profile.alerts.classes = { HUNTER = true }
    profile.display.classes = { WARRIOR = true }
    profile.range.enabled, profile.range.yards, profile.range.policy, profile.range.unknown = true, 20, "confirmed", false
    app:ProfileChanged()
    app.engine:Pause(60)
    state.resting = true
    state:Fire("PLAYER_UPDATE_RESTING")
    local saved = assert(RG.Codec.Encode(app.db.root))
    app:Demo()
    local results, samples = {}, {}
    for _, row in ipairs(app.ui.rows) do
        if row:IsShown() and row.contact then
            row:Click()
            app.ui:ShowExplanation()
            local contact = app.ui.selected
            results[contact.class] = app:Explain(contact)
            samples[contact.class] = contact
        end
    end
    H.Equal(RG.Util.Count(samples), 3)
    H.False(results.ROGUE.allowed)
    H.Equal(results.ROGUE.reason, "class_filtered")
    H.False(results.HUNTER.allowed)
    H.Equal(results.HUNTER.reason, "range_unconfirmed")
    H.True(results.MAGE.allowed)
    H.Equal(results.MAGE.reason, "watch_list")
    H.True(results.MAGE.preview)
    H.True(results.MAGE.sound)
    local altered = RG.Util.Copy(samples.ROGUE)
    altered.class, altered.watched = "HUNTER", true
    H.Equal(app:Explain(altered).reason, "class_filtered")
    profile.range.yards = 30
    app:ProfileChanged()
    H.True(app:Explain(samples.HUNTER).allowed)
    profile.range.yards = 20
    app:ProfileChanged()
    H.Equal(app:Explain(samples.HUNTER).reason, "range_unconfirmed")
    H.Equal(assert(RG.Codec.Encode(app.db.root)), saved)
    H.Equal(#app.engine.pending, 0)
    H.Equal(#app.engine.history, 0)
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#state.sounds, 0)

    state:Advance(16)
    H.Equal(app:Explain(samples.MAGE).reason, "not_observed")
    H.False(app.ui.detailsFrame:IsShown())
    H.False(app.ui.explanationFrame:IsShown())
    app:Demo()
    H.Equal(app:Explain(samples.MAGE).reason, "not_observed")
end)

H.Test("opening the demo does not replace live details with synthetic contacts", function()
    local state, _, app = setup()
    state:Unit("target", { guid = "Player-BeforePreview", name = "Real rival", class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("PLAYER_TARGET_CHANGED")
    local live = app.engine:Snapshot()[1]
    app.ui:Select(live)
    H.True(app.ui.detailsFrame.snooze:IsShown())
    app:Demo()
    H.Equal(app.ui.selected.id, live.id)
    H.False(app.ui.selectedOutside)
    H.True(app.ui.detailsFrame.snooze:IsShown())
    H.Equal(app.ui.visibleCount, 1)
    H.Nil(app:Explain(live).preview)
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

H.Test("the copied diagnostics include sanitized context coverage and global alert blockers", function()
    local private = {
        "FixturePrivateZone", "FixturePrivateProfile", "FixturePrivateRule",
        "FixturePrivatePlayer", "Player-FixturePrivateGUID", "FixturePrivateNote", "FixturePrivateCVar",
    }
    local state, _, app = setup(nil, function(fixture)
        fixture.api.GetRealZoneText = function() return private[1] end
        fixture.api.C_CVar = { GetCVarBool = function(name) return fixture.cvars[name] end }
        fixture.cvars.nameplateShowEnemies, fixture.cvars.nameplateShowAll = true, false
    end)
    assert(app.db:CreateProfile(private[2]))
    local profile = assert(app.db:SetProfile(private[2]))
    profile.rules = {{ name = private[3], enabled = true, event = "sighting", priority = 20,
        action = "alert", classes = {}, sound = true, banner = true, cooldown = 30 }}
    app:ProfileChanged()
    assert(app.db:SetList("guid:" .. private[5], "watch", private[6], { name = private[4] }))
    state:Unit("nameplate1", { guid = private[5], name = private[4], class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(app.db:GetJournal()[1].zone, private[1])

    local function copied()
        app.ui:ShowDiagnostics()
        local edit = app.ui.copyFrame.edit
        H.True(edit:HasFocus())
        H.True(edit.highlighted)
        local report, fields = edit:GetText(), {}
        for _, value in ipairs(private) do H.Nil(report:find(value, 1, true), "diagnostic leaked fixture data") end
        for line in report:gmatch("[^\n]+") do
            local key, value = line:match("^%s*([%a]+)=([%w_]+)%s*$")
            if key then fields[key] = value end
        end
        return fields
    end

    state.instance = "arena"
    state.cvars.nameplateShowEnemies, state.cvars.nameplateShowAll = false, H.Secret(private[7])
    state:Fire("PLAYER_ENTERING_WORLD")
    local arena = copied()
    H.Equal(arena.context, "arena")
    H.Equal(arena.detection, "limited")
    H.Equal(arena.nameplates, "false")
    H.Equal(arena.alwaysNameplates, "unknown")
    H.Equal(arena.alertBlock, "context_disabled")

    state.instance, state.zonePVP = nil, "sanctuary"
    state.cvars.nameplateShowEnemies, state.cvars.nameplateShowAll = true, false
    state:Fire("ZONE_CHANGED_NEW_AREA")
    local sanctuary = copied()
    H.Equal(sanctuary.context, "world")
    H.Equal(sanctuary.detection, "active")
    H.Equal(sanctuary.nameplates, "true")
    H.Equal(sanctuary.alwaysNameplates, "false")
    H.Equal(sanctuary.alertBlock, "sanctuary")

    state.zonePVP = "contested"
    state:Fire("ZONE_CHANGED_NEW_AREA")
    profile.alerts.sound, profile.alerts.banner = false, false
    app:ProfileChanged()
    local quiet = copied()
    H.Equal(quiet.context, "world")
    H.Equal(quiet.alertBlock, "outputs_disabled")

    local alerts = profile.alerts
    alerts.sound, alerts.stealth, alerts.targeting = true, false, false
    for event in pairs(alerts.sounds) do alerts.sounds[event] = "none" end
    alerts.sounds.stealth, alerts.sounds.targeting = "warning", "ready"
    app:ProfileChanged()
    H.Equal(copied().alertBlock, "outputs_disabled")
    alerts.targeting = true
    app:ProfileChanged()
    H.Equal(copied().alertBlock, "none")

    alerts.targeting = false
    alerts.sounds.sighting, alerts.sounds.returning, alerts.sounds.wave = "ping", "ping", "ready"
    for _, setting in ipairs({ "muteOrdinary", "watchedOnly" }) do
        alerts[setting], alerts.sounds.watch = true, "none"
        app:ProfileChanged()
        H.Equal(copied().alertBlock, "outputs_disabled")
        alerts.sounds.watch = "warning"
        app:ProfileChanged()
        H.Equal(copied().alertBlock, "none")
        alerts[setting] = false
    end
end)

H.Test("the first-run guide shows disabled and automatic nameplate hints only where relevant", function()
    local writes = 0
    local function writeCVar() writes = writes + 1 end
    local state, RG, app = setup(nil, function(mock)
        mock.locale = "ruRU"
        mock.cvars.nameplateShowEnemies, mock.cvars.nameplateShowAll = false, true
        mock.api.C_CVar = { GetCVarBool = function(key) return mock.cvars[key] end, SetCVar = writeCVar }
        mock.api.GetCVarBool, mock.api.SetCVar = function() return true end, writeCVar
    end)
    local ui, guide = app.ui, assert(app.ui.guideDialog)
    local profile = assert(RG.Codec.Encode(app.db:GetProfile()))
    H.True(guide:IsShown())
    H.True(guide.coverage:IsShown())
    H.Equal(guide.coverage:GetText(), ui:T("nameplatesOff"))
    guide.next:Click()
    H.False(guide.coverage:IsShown())
    guide.next:Click()
    H.True(guide.coverage:IsShown())
    H.Equal(guide.coverage:GetText(), ui:T("nameplatesOff"))

    state.cvars.nameplateShowEnemies, state.cvars.nameplateShowAll = true, false
    state:Fire("CVAR_UPDATE", "nameplateShowEnemies", "1")
    state:Advance(0.3)
    guide.back:Click()
    H.False(guide.coverage:IsShown())
    guide.back:Click()
    H.True(guide.coverage:IsShown())
    H.Equal(guide.coverage:GetText(), ui:T("nameplatesAutomatic"))
    guide.skip:Click()
    H.True(app.db:HasSeenGuide())
    H.Equal(RG.Codec.Encode(app.db:GetProfile()), profile)
    H.Equal(writes, 0)
end)

H.Test("guide nameplate coverage follows clean CVar reads after live updates and ignores event values", function()
    local writes = 0
    local function writeCVar() writes = writes + 1 end
    local state, RG, app = setup(nil, function(mock)
        mock.cvars.nameplateShowEnemies, mock.cvars.nameplateShowAll = true, false
        mock.api.C_CVar = { GetCVarBool = function(key) return mock.cvars[key] end, SetCVar = writeCVar }
        mock.api.SetCVar = writeCVar
    end)
    local ui, guide = app.ui, assert(app.ui.guideDialog)
    local profile = assert(RG.Codec.Encode(app.db:GetProfile()))
    local secret = H.Secret("unreadable CVar value or event name")
    local function expected(key)
        H.Equal(guide.coverage:IsShown(), key ~= nil)
        if key then H.Equal(guide.coverage:GetText(), ui:T(key)) end
    end
    local function update(name, eventValue, key)
        H.False(app.dirty)
        state:Fire("CVAR_UPDATE", name, eventValue)
        H.True(app.dirty)
        state:Advance(0.3)
        expected(key)
    end
    state:Advance(0.3)
    expected("nameplatesAutomatic")
    state:Fire("CVAR_UPDATE", secret, "0")
    H.False(app.dirty)
    state:Fire("CVAR_UPDATE", "nameplateShowFriends", "0")
    H.False(app.dirty)

    state.cvars.nameplateShowAll = true
    update("NAMEPLATESHOWALL", "0", nil)
    state.cvars.nameplateShowAll = secret
    update("nAmEpLaTeShOwAlL", "0", nil)
    state.cvars.nameplateShowEnemies = false
    update("NAMEPLATESHOWENEMIES", "1", "nameplatesOff")
    state.cvars.nameplateShowEnemies, state.cvars.nameplateShowAll = nil, false
    update("nameplateShowEnemies", "0", nil)
    state.cvars.nameplateShowEnemies = true
    update("nameplateShowEnemies", secret, "nameplatesAutomatic")

    guide.next:Click()
    expected(nil)
    state.cvars.nameplateShowEnemies = false
    update("nameplateShowEnemies", true, nil)
    guide.next:Click()
    expected("nameplatesOff")
    state.cvars.nameplateShowEnemies, state.cvars.nameplateShowAll = true, true
    update("nameplateShowEnemies", false, nil)
    H.Equal(RG.Codec.Encode(app.db:GetProfile()), profile)
    H.Equal(writes, 0)
end)

H.Test("navigating and skipping a first-run class guide keeps the default alert settings", function()
    local state, RG, app = setup()
    local guide = assert(app.ui.guideDialog)
    local profile = app.db:GetProfile()
    local before = assert(RG.Codec.Encode(profile))
    H.True(guide:IsShown())
    H.False(guide.hunterRogue:IsShown())
    H.False(guide.allClasses:IsShown())
    H.True(guide.preview:IsShown())
    guide.next:Click()
    H.True(guide.hunterRogue:IsShown())
    H.True(guide.allClasses:IsShown())
    H.False(guide.allClasses.enabled)
    H.True(guide.hunterRogue.enabled)
    H.False(guide.preview:IsShown())
    guide.next:Click()
    H.False(guide.hunterRogue:IsShown())
    H.False(guide.allClasses:IsShown())
    H.True(guide.preview:IsShown())
    guide.back:Click()
    guide.skip:Click()
    H.False(guide:IsShown())
    H.True(app.db:HasSeenGuide())
    H.Equal(RG.Codec.Encode(profile), before)
    H.Equal(#state.sounds, 0)
end)

H.Test("Hunter and Rogue selected during first-run setup persists and controls live alerts", function()
    local function russian(state) state.locale = "ruRU" end
    local state, RG, app = setup(nil, russian)
    local guide = assert(app.ui.guideDialog)
    H.True(guide:IsShown())
    guide.next:Click()
    guide.hunterRogue:Click()
    local profile = app.db:GetProfile()
    H.True(guide:IsShown())
    H.False(guide.hunterRogue.enabled)
    H.True(guide.allClasses.enabled)
    H.Equal(guide.hunterRogue.label:GetText(), app.ui:T("hunterRogueClasses"))
    H.Equal(RG.Util.Count(profile.alerts.classes), 2)
    H.True(profile.alerts.classes.HUNTER)
    H.True(profile.alerts.classes.ROGUE)
    H.False(profile.alerts.unknownClass)

    guide.openAlerts:Click()
    H.False(guide:IsShown())
    H.True(app.db:HasSeenGuide())
    H.Equal(app.ui.currentPage, "alerts")
    local fresh, _, reloaded = setup(state.api.RivalGuardDB, russian)
    H.Nil(reloaded.ui.guideDialog)
    local alerts = reloaded.db:GetProfile().alerts
    H.Equal(RG.Util.Count(alerts.classes), 2)
    H.True(alerts.classes.HUNTER)
    H.True(alerts.classes.ROGUE)
    H.False(alerts.unknownClass)
    for index, class in ipairs({ "MAGE", "HUNTER", "UNKNOWN_FIXTURE" }) do seeSoundRuleRival(fresh, index, class) end
    fresh:Advance(1.5)
    H.Equal(#reloaded.engine:Snapshot(), 3)
    H.Equal(#reloaded.engine.history, 1)
    H.Equal(reloaded.ui.activeBanner.name, "Sound rival 2")
    H.Equal(#fresh.sounds, 1)
end)

H.Test("guide replay changes only class filters in the active profile and preserves an eligible queued arrival", function()
    local state, app, profile = ruleSoundFixture()
    local initial = profile
    assert(app.db:CreateProfile("Guide replay", "balanced"))
    assert(app:UseProfile("Guide replay"))
    profile = app.db:GetProfile()
    profile.alerts.classes = { MAGE = true, ROGUE = true }
    profile.alerts.channel = "Dialog"
    profile.alerts.sounds.sighting = "quest"
    profile.display.classes = { MAGE = true }
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    H.Equal(#app.engine.pending, 1)
    local at = app.engine.pending[1].at
    local function withoutAlertClasses(p)
        local copy = state.RG.Util.Copy(p)
        copy.alerts.classes, copy.alerts.unknownClass = nil, nil
        return assert(state.RG.Codec.Encode(copy))
    end
    local expected = withoutAlertClasses(profile)
    H.True(app.ui:ShowGuide(true))
    local guide = app.ui.guideDialog
    guide.next:Click()
    H.True(guide.allClasses.enabled)
    H.True(guide.hunterRogue.enabled)
    guide.hunterRogue:Click()
    H.False(guide.hunterRogue.enabled)
    guide.allClasses:Click()
    H.True(guide:IsShown())
    H.False(guide.allClasses.enabled)
    H.True(guide.hunterRogue.enabled)
    H.Nil(next(profile.alerts.classes))
    H.True(profile.alerts.unknownClass)
    H.Equal(withoutAlertClasses(profile), expected)
    H.Nil(next(initial.alerts.classes))
    H.True(initial.alerts.unknownClass)
    H.Equal(app.db:GetActiveProfileName(), "Guide replay")
    H.Equal(#app.engine.pending, 1)
    H.Equal(app.engine.pending[1].at, at)
    guide.openAlerts:Click()
    H.Equal(app.ui.currentPage, "alerts")
    H.Equal(withoutAlertClasses(profile), expected)
    state:Advance(1.25)
    H.Equal(#app.engine.history, 1)
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)
    H.Equal(state.sounds[1].channel, "Dialog")
end)

H.Test("a guide opened for another profile cannot edit the new active profile", function()
    local state, RG, app = setup()
    local first = app.db:GetProfile()
    local second = assert(app.db:CreateProfile("Another profile", "quiet"))
    local firstBefore, secondBefore = RG.Codec.Encode(first), RG.Codec.Encode(second)
    local guide = app.ui.guideDialog
    guide.next:Click()
    H.True(guide.hunterRogue:IsShown())
    local staleAction = guide.hunterRogue.scripts.OnClick
    state.api.SlashCmdList.RIVALGUARD("profile Another profile")
    H.Equal(app.db:GetProfile(), second)
    H.True(guide:IsShown())
    H.False(guide.hunterRogue:IsShown())
    staleAction(guide.hunterRogue)
    H.Equal(RG.Codec.Encode(first), firstBefore)
    H.Equal(RG.Codec.Encode(second), secondBefore)
    H.True(guide.openAlerts:IsShown())
end)

for _, locale in ipairs({ "enUS", "ruRU" }) do
    H.Test("Alerts explains ordinary sighting eligibility for the selected profile in " .. locale, function()
        local state, RG, app = setup(nil, function(mock) mock.locale = locale end)
        local db, ui = app.db, app.ui
        local function clickSetting(path) settingButton(ui, path):Click() end
        local function status(profileName, reason)
            H.Equal(ui.currentPage, "alerts")
            H.Equal(app:AlertBlock(true), reason)
            H.Equal(ui.alertProfileStatus:GetText(), RG.Locale.Get("selectedProfile", locale) .. ": " .. profileName)
            local result = reason and RG.Locale.Format("ordinaryAlertStatus", locale, RG.Locale.Reason(reason, locale))
                or RG.Locale.Get("ordinaryAlertReady", locale)
            H.Equal(ui.ordinaryAlertStatus:GetText(), result)
        end

        local original = db:GetProfile()
        ui:OpenSettings("alerts")
        ui.hunterRogueButton:Click()
        H.True(original.alerts.classes.HUNTER); H.True(original.alerts.classes.ROGUE)
        ui:OpenSettings("profiles")
        ui.presetChoices.battleground:Click()
        ui.profileInput:SetText("Matches")
        ui.createProfile:Click()
        H.Equal(db:GetActiveProfileName(), "Default")
        H.Equal(ui.profileRows[2].profileName, "Matches")
        ui.profileRows[2].use:Click()
        H.Equal(db:GetActiveProfileName(), "Matches")
        local matchProfile = db:GetProfile()
        H.Equal(matchProfile.preset, "battleground")

        ui:OpenSettings("alerts")
        ui.hunterRogueButton:Click()
        status("Matches", "context_disabled")
        ui:OpenSettings("overview")
        clickSetting("context.world")
        ui:OpenSettings("alerts")
        status("Matches", "ordinary_muted")
        H.Nil(app:AlertBlock(), "priority and personal-list alerts are still eligible")
        local function seeHunter(token, name)
            state:Unit(token, { guid = "Player-Status-" .. token, name = name, class = "HUNTER", hostile = true, isPlayer = true })
            state:Fire("NAME_PLATE_UNIT_ADDED", token)
            state:Advance(1.5)
        end
        seeHunter("nameplate1", "MutedHunter")
        H.Equal(app.engine.counters.alerts, 0)
        state.units.nameplate1 = nil
        state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
        clickSetting("alerts.muteOrdinary")
        status("Matches", nil)
        seeHunter("nameplate2", "EligibleHunter")
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].kind, "sighting")
        H.Equal(ui.activeBanner.name, "EligibleHunter")

        clickSetting("alerts.watchedOnly")
        status("Matches", "watch_only")
        clickSetting("alerts.watchedOnly")
        clickSetting("alerts.banner")
        clickSetting("alerts.sound")
        status("Matches", "outputs_disabled")
        clickSetting("alerts.sound")
        status("Matches", nil)
        pickSound(ui, settingButton(ui, "alerts.sounds.sighting"), "none")
        H.Equal(matchProfile.alerts.sounds.sighting, "none")
        status("Matches", nil)
        pickSound(ui, settingButton(ui, "alerts.sounds.wave"), "none")
        H.Equal(matchProfile.alerts.sounds.wave, "none")
        status("Matches", "outputs_disabled")
        H.Nil(app:AlertBlock(), "other event sounds are still eligible")
        pickSound(ui, settingButton(ui, "alerts.sounds.sighting"), "ping")
        status("Matches", nil)

        state.api.RivalGuard_Binding("pause")
        status("Matches", "paused")
        state.api.RivalGuard_Binding("pause")
        status("Matches", nil)

        state.instance = "arena"
        state:Fire("ZONE_CHANGED_NEW_AREA")
        state:Advance(0.3)
        status("Matches", "context_disabled")
        state.instance = nil
        state:Fire("ZONE_CHANGED_NEW_AREA")
        state:Advance(0.3)
        status("Matches", nil)

        ui:OpenSettings("profiles")
        H.Equal(ui.profileRows[1].profileName, "Default")
        ui.profileRows[1].use:Click()
        H.Equal(db:GetProfile(), original)
        H.Equal(RG.Util.Count(original.alerts.classes), 2)
        H.True(original.alerts.classes.HUNTER); H.True(original.alerts.classes.ROGUE)
        H.False(original.alerts.muteOrdinary); H.True(original.alerts.banner)
        ui:OpenSettings("alerts")
        status("Default", nil)
    end)

    H.Test("Hunters and Rogues quick selection applies to live alerts in " .. locale, function()
        local state, RG, app = setup()
        local profile, ui = app.db:GetProfile(), app.ui
        profile.locale = locale
        app:ProfileChanged()
        ui:OpenSettings("alerts")
        H.Equal(ui.hunterRogueButton.label:GetText(), RG.Locale.Get("hunterRogueClasses", locale))
        ui.hunterRogueButton:Click()
        H.Equal(RG.Util.Count(profile.alerts.classes), 2)
        H.True(profile.alerts.classes.HUNTER)
        H.True(profile.alerts.classes.ROGUE)
        H.False(profile.alerts.unknownClass)
        H.Nil(next(profile.display.classes))
        for index, class in ipairs({ "HUNTER", "ROGUE", "MAGE", "UNKNOWN_FIXTURE" }) do
            local token = "nameplate" .. index
            state:Unit(token, { guid = "Player-Quick-" .. index, name = "Rival " .. index, class = class, hostile = true, isPlayer = true })
            state:Fire("NAME_PLATE_UNIT_ADDED", token)
        end
        state:Advance(1.5)
        H.Equal(#app.engine:Snapshot(), 4)
        H.Equal(app.engine.counters.alerts, 2)
        H.Equal(ui.activeBanner.name, "Rival 1")
        H.Equal(#ui.bannerQueue, 1)
        H.Equal(ui.bannerQueue[1].name, "Rival 2")

        ui.alertAllClassesButton:Click()
        H.Nil(next(profile.alerts.classes))
        H.False(profile.alerts.unknownClass)
        local unknown
        for _, control in ipairs(ui.controls) do
            if control.path == "alerts.unknownClass" then unknown = control.frame break end
        end
        assert(unknown):Click()
        H.True(profile.alerts.unknownClass)
    end)

    H.Test("right-click selects only one Alerts class and persists in " .. locale, function()
        local function localize(mock) mock.locale = locale end
        local state, RG, app = setup(nil, localize)
        local profile, ui = app.db:GetProfile(), app.ui
        profile.display.classes = { MAGE = true }
        profile.alerts.sounds.sighting = "ready"
        profile.alerts.sounds.watch = "whisper"
        app:OnSettingsChanged()
        local watchKey = "guid:Player-ClassSolo4"
        assert(app.db:SetList(watchKey, "watch", "Manual watch remains", { name = "Watched mage", class = "MAGE" }))
        ui:OpenSettings("alerts")
        local function findChip(class, parent)
            for _, control in ipairs(ui.controls) do
                for _, chip in ipairs(control.chips or {}) do
                    if chip.class == class and chip.frame:GetParent() == parent then return chip.frame end
                end
            end
            error("missing class chip " .. class)
        end
        local rogue = findChip("ROGUE", ui.pages.alerts)
        local hunter = findChip("HUNTER", ui.pages.alerts)
        local function onlyRogue()
            H.Equal(RG.Util.Count(profile.alerts.classes), 1)
            H.True(profile.alerts.classes.ROGUE)
            H.False(profile.alerts.unknownClass)
        end

        H.Nil(next(profile.alerts.classes)); H.True(profile.alerts.unknownClass)
        rogue:Click("RightButton")
        onlyRogue()
        H.Equal(#rogue.clickButtons, 2)
        H.Equal(rogue.clickButtons[1], "LeftButtonUp"); H.Equal(rogue.clickButtons[2], "RightButtonUp")
        local hint = RG.Locale.Get("classSoloHint", locale)
        H.True(hint ~= "classSoloHint")
        local hintShown = false
        for _, child in ipairs(ui.pages.alerts.children) do
            if child:GetText() == hint and child:IsShown() then hintShown = true end
        end
        H.True(hintShown)
        for _, frame in ipairs({ findChip("ROGUE", ui.pages.overview), findChip("ROGUE", ui.frame) }) do
            for _, button in ipairs(frame.clickButtons or {}) do
                H.False(button == "RightButtonUp" or button == "RightButtonDown")
            end
        end
        rogue:Click("RightButton")
        onlyRogue()
        hunter:Click("LeftButton")
        H.Equal(RG.Util.Count(profile.alerts.classes), 2)
        H.True(profile.alerts.classes.ROGUE); H.True(profile.alerts.classes.HUNTER)
        rogue:Click("RightButton")
        onlyRogue()
        ui.alertAllClassesButton:Click()
        H.Nil(next(profile.alerts.classes)); H.False(profile.alerts.unknownClass)
        ui.hunterRogueButton:Click()
        H.Equal(RG.Util.Count(profile.alerts.classes), 2)
        H.True(profile.alerts.classes.HUNTER); H.True(profile.alerts.classes.ROGUE)
        rogue:Click("RightButton")
        onlyRogue()
        H.Equal(RG.Util.Count(profile.display.classes), 1); H.True(profile.display.classes.MAGE)
        H.True(profile.alerts.sound); H.Equal(profile.alerts.sounds.sighting, "ready")
        H.Equal(profile.alerts.sounds.watch, "whisper"); H.False(profile.alerts.watchedOnly)
        H.Equal(app.db:GetList()[watchKey].note, "Manual watch remains")

        state:Fire("PLAYER_LOGOUT")
        local fresh, _, reloaded = setup(state.api.RivalGuardDB, localize)
        profile = reloaded.db:GetProfile()
        onlyRogue()
        H.True(profile.display.classes.MAGE)
        H.Equal(profile.alerts.sounds.watch, "whisper")
        local function see(index, class, name)
            local token = "nameplate" .. index
            fresh:Unit(token, { guid = "Player-ClassSolo" .. index, name = name, class = class, hostile = true, isPlayer = true })
            fresh:Fire("NAME_PLATE_UNIT_ADDED", token)
        end
        see(1, "ROGUE", "Selected rogue")
        see(2, "HUNTER", "Excluded hunter")
        see(3, "UNKNOWN_FIXTURE", "Unidentified rival")
        fresh:Advance(2.8)
        H.Equal(reloaded.engine.counters.alerts, 1)
        H.Equal(reloaded.engine.history[1].kind, "sighting")
        H.Equal(reloaded.ui.activeBanner.name, "Selected rogue")
        H.Equal(#fresh.sounds, 1)

        see(4, "MAGE", "Watched mage")
        fresh:Advance(0.5)
        H.Equal(reloaded.engine.counters.alerts, 2)
        H.Equal(reloaded.engine.history[2].kind, "watch")
        H.Equal(reloaded.ui.activeBanner.name, "Watched mage")
        H.Equal(#fresh.sounds, 2)
    end)

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
        H.Equal(ui.banner.body:GetText(), ui.rows[1].nameText:GetText())
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
    state:Fire("PLAYER_TARGET_CHANGED")
    state:Advance(1.5)
    H.Equal(app.ui.activeBanner.kind, "sighting")
    state.api.SlashCmdList.RIVALGUARD("ignore")
    H.Equal(app.db:GetList()["guid:Player-Target"].kind, "ignore")
    H.Equal(#app.engine:Snapshot(), 0)
    H.Nil(app.ui.activeBanner)
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

local function locatorFixture(raw)
    local state, _, app = setup(raw)
    app.db:GetProfile().display.showBadges = false
    app:ProfileChanged()
    local unit = { guid = "Player-LocatorOwner", name = "Rival to locate", class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(0.5)
    local ui = app.ui
    ui.rows[1]:Click()
    H.Equal(ui.selected.identity, "guid:" .. unit.guid)
    H.True(ui.detailsFrame:IsShown())
    H.True(assert(ui.detailsFrame.locate, "missing nameplate highlight action"):IsShown())
    return state, app, ui, unit
end

local function locatorVisible(ui, token)
    local badge = ui.badges.active[token]
    return badge ~= nil and badge.locator ~= nil and badge.locator:IsVisible()
end

local function badgeEvidenceFixture()
    local mode, watch = nil, "guid:Player-BadgeEvidence"
    local state, _, app = setup({ schemaVersion = 1, onboardingSeen = true, lists = {
        [watch] = { kind = "watch", name = "Known-FixtureRealm", class = "ROGUE" },
    } }, function(mock)
        local api, secret = mock.api, H.Secret("unreadable nameplate evidence")
        local guid, name, class = api.UnitGUID, api.UnitName, api.UnitClass
        local hostile, player, same = api.UnitIsEnemy, api.UnitIsPlayer, api.UnitIsUnit
        function api.UnitGUID(token)
            if token == "nameplate1" and mode then return secret end
            return guid(token)
        end
        function api.UnitName(token)
            if token == "nameplate1" and (mode == "all" or mode == "identity") then return secret, secret end
            return name(token)
        end
        api.UnitFullName = api.UnitName
        function api.UnitClass(token)
            if token == "nameplate1" and mode == "all" then return secret, secret end
            return class(token)
        end
        function api.UnitIsEnemy(source, token)
            if token == "nameplate1" and mode == "all" then return secret end
            return hostile(source, token)
        end
        function api.UnitIsPlayer(token)
            if token == "nameplate1" and mode == "all" then return secret end
            return player(token)
        end
        function api.UnitIsUnit(first, second)
            if first == "nameplate1" and (second == "target" or second == "focus") and mode then return secret end
            return same(first, second)
        end
    end)
    local known = { guid = "Player-BadgeEvidence", name = "Known", realm = "FixtureRealm",
        class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", known)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Unit("target", known)
    state:Fire("PLAYER_TARGET_CHANGED")
    state:Unit("focus", known)
    state:Fire("PLAYER_FOCUS_CHANGED")
    state:Fire("UNIT_FLAGS", "nameplate1")
    local function updateVisibility(value, unit)
        mode = value
        state:Unit("nameplate1", unit or known)
        state:Fire("UNIT_FLAGS", "nameplate1")
    end
    return state, app, updateVisibility
end

for _, scenario in ipairs({ "pooled frame", "replacement frame", "healthy events" }) do
    H.Test("unreadable nameplate ownership respects lifecycle evidence with " .. scenario, function()
        local healthy = scenario == "healthy events"
        local state, app
        if healthy then
            local _
            state, _, app = setup()
        else
            state, app = eventRegistrationFixture("NAME_PLATE_UNIT_REMOVED", "false")
        end
        H.Equal(app:Status().capabilities.nameplateEvents, healthy)
        local api, secret = state.api, H.Secret("new plate owner identity")
        local readGuid, readName = api.UnitGUID, api.UnitName
        local restricted = false
        function api.UnitGUID(token)
            if restricted and token == "nameplate1" then return secret end
            return readGuid(token)
        end
        function api.UnitName(token)
            if restricted and token == "nameplate1" then return secret, secret end
            return readName(token)
        end
        api.UnitFullName = api.UnitName

        local oldRogue = { guid = "Player-OldLifecycleOwner", name = "Old Rogue",
            realm = "FixtureRealm", class = "ROGUE", hostile = true, isPlayer = true }
        local oldKey = "guid:" .. oldRogue.guid
        assert(app.db:SetList(oldKey, "watch", "Old personal note", { name = "Old Rogue-FixtureRealm", class = "ROGUE" }))
        state:Unit("player", { guid = "Player-LifecycleSelf" })
        state:Unit("nameplate1", oldRogue)
        state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        state:Unit("focus", oldRogue)
        state:Fire("PLAYER_FOCUS_CHANGED")
        local initial = assert(app.engine:Snapshot()[1])
        local generation = app.sensors.active.nameplate1.generation
        state:Advance(5)
        local old = assert(app.engine:SelectedContact(initial.id, oldKey))
        H.Equal(app.sensors.active.nameplate1.generation, generation)
        H.True(old.sources.nameplate); H.True(old.sources.focus)
        H.Equal(old.class, "ROGUE"); H.Equal(old.listKind, "watch")
        H.Nil(app.ui.activeBanner)
        local historyCount = #app.engine.history
        local newHunter = { guid = "Player-NewLifecycleOwner", name = "New Hunter",
            realm = "FixtureRealm", class = "HUNTER", hostile = true, isPlayer = true }
        if scenario == "replacement frame" then
            state.plates.nameplate1 = state.api.CreateFrame("Frame", nil, api.UIParent)
            state.plates.nameplate1.unitToken = "nameplate1"
        end
        restricted = true
        state:Unit("nameplate1", healthy and oldRogue or newHunter)
        state:Unit("nameplate1target", state.units.player)
        state:Advance(1.25)

        local binding = assert(app.sensors.active.nameplate1)
        local current = assert(app.engine:SelectedContact(binding.contactID))
        old = assert(app.engine:SelectedContact(initial.id, oldKey))
        H.True(old.sources.focus)
        H.Equal(old.class, "ROGUE"); H.Equal(old.listKind, "watch")
        H.Equal(app.db:GetList()[oldKey].note, "Old personal note")
        H.True(current.targeting)
        H.Equal(#app.engine.history, historyCount + 1)
        local warning = app.engine.history[historyCount + 1]
        H.Equal(warning.kind, "targeting")
        H.Equal(warning.id, current.id)
        local banner = assert(app.ui.activeBanner)
        H.Equal(banner.kind, "targeting")
        if healthy then
            H.Equal(current.id, old.id)
            H.Equal(binding.generation, generation)
            H.True(old.sources.nameplate)
            H.Equal(banner.name, old.name)
        else
            H.True(current.id ~= old.id)
            H.True(binding.generation > generation)
            H.Nil(old.sources.nameplate)
            H.True(old.targeting ~= true)
            H.Equal(current.class, "HUNTER")
            H.Nil(current.identity); H.Nil(current.name); H.Nil(current.listKind)
            H.Equal(banner.name, app.ui:T("unknownPlayer"))
            H.Equal(banner.class, "HUNTER")
            H.Equal(#app.db:GetJournal(), 1)
            H.Equal(app.db:GetJournal()[1].identity, oldKey)
        end
    end)
end

for _, restricted in ipairs({ "all", "identity" }) do
    local title = restricted == "all" and "a badge hides when only a different alias has readable evidence"
        or "a badge with fresh class evidence drops markers for an unreadable owner"
    H.Test(title, function()
        local _, app, updateVisibility = badgeEvidenceFixture()
        local ui = app.ui
        local live = app.engine:Snapshot()[1]
        local function badge() return assert(ui.badges.active.nameplate1) end
        local original = badge()
        H.True(original.icon:IsVisible()); H.True(original.marker:IsVisible())
        H.True(original.target:IsVisible()); H.True(original.focus:IsVisible())
        ui:Select(live)
        ui.detailsFrame.locate:Click()
        H.True(locatorVisible(ui, "nameplate1"))

        local replacement = restricted == "identity" and { guid = "Player-RestrictedReplacement", name = "Replacement",
            realm = "FixtureRealm", class = "HUNTER", hostile = true, isPlayer = true } or nil
        updateVisibility(restricted, replacement)
        local aggregated = assert(app.engine:SelectedContact(live.id, live.identity))
        H.True(aggregated.sources.focus)
        H.True(aggregated.hostile)
        H.Equal(aggregated.listKind, "watch")
        H.False(locatorVisible(ui, "nameplate1"))
        if restricted == "all" then
            H.False(original.icon:IsVisible())
        else
            local localBadge = badge()
            H.True(localBadge.icon:IsVisible())
            H.Equal(localBadge.icon.texture, "Interface\\Icons\\ClassIcon_HUNTER")
            H.False(localBadge.marker:IsVisible())
            H.False(localBadge.target:IsVisible()); H.False(localBadge.focus:IsVisible())
        end

        updateVisibility("guid")
        H.True(badge().icon:IsVisible()); H.True(badge().marker:IsVisible())
        H.Equal(badge().icon.texture, "Interface\\Icons\\ClassIcon_ROGUE")
        H.False(badge().target:IsVisible()); H.False(badge().focus:IsVisible())
        updateVisibility(nil)
        H.True(badge().marker:IsVisible())
        H.True(badge().target:IsVisible()); H.True(badge().focus:IsVisible())
        H.False(locatorVisible(ui, "nameplate1"))
    end)
end

local function badgeArtworkVisible(frame)
    if not frame:IsVisible() then return false end
    while frame do
        if frame:GetAlpha() == 0 then return false end
        frame = frame:GetParent()
    end
    return true
end

H.Test("a nameplate protected after attachment can be removed and reused without blocked combat mutations", function()
    local state, app = badgeEvidenceFixture()
    local ui = app.ui
    local unit, plate = state.units.nameplate1, state.plates.nameplate1
    local badge = assert(ui.badges.active.nameplate1)
    local allocated = ui.badges.count
    for _ = 1, 3 do
        ui:Select(app.engine:Snapshot()[1])
        ui.detailsFrame.locate:Click()
        H.True(badgeArtworkVisible(badge.icon))
        H.True(badgeArtworkVisible(badge.locator))

        state.combat = true
        state:Fire("PLAYER_REGEN_DISABLED")
        plate.protected = true
        state.units.nameplate1 = nil
        state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
        H.Equal(#state.blocked, 0)
        H.False(badgeArtworkVisible(badge.icon))
        H.False(badgeArtworkVisible(badge.locator))
        H.Nil(ui.badges.highlight)
        H.Nil(ui.badges.active.nameplate1)
        H.Equal(#ui.badges.pool, 1)

        plate.protected, state.combat = false, false
        state:Fire("PLAYER_REGEN_ENABLED")
        state:Unit("nameplate1", unit)
        state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        H.Equal(ui.badges.active.nameplate1, badge)
        H.Equal(badge:GetParent(), plate)
        H.Equal(ui.badges.count, allocated)
        H.True(badgeArtworkVisible(badge.icon))
        H.False(badgeArtworkVisible(badge.locator))
    end
    H.Nil(app.diagnostics.counts.errors)
end)

H.Test("a recycled token uses a new badge while its old plate remains protected", function()
    local state, app = badgeEvidenceFixture()
    local ui, oldPlate = app.ui, state.plates.nameplate1
    local oldBadge = assert(ui.badges.active.nameplate1)
    ui:Select(app.engine:Snapshot()[1])
    ui.detailsFrame.locate:Click()
    H.True(badgeArtworkVisible(oldBadge.icon)); H.True(badgeArtworkVisible(oldBadge.locator))
    local replacement = state.api.CreateFrame("Frame", nil, state.api.UIParent)
    replacement.namePlateUnitToken = "nameplate1"
    replacement:SetSize(120, 30)

    state.combat = true
    state:Fire("PLAYER_REGEN_DISABLED")
    oldPlate.protected = true
    state.plates.nameplate1 = replacement
    local before = #state.mutations
    -- Keep the old binding active until the normal unit refresh sees the new frame.
    state:Fire("UNIT_FLAGS", "nameplate1")
    H.Equal(#state.blocked, 0)
    H.Nil(ui.badges.active.nameplate1)
    H.Equal(oldBadge:GetParent(), oldPlate)
    H.Equal(oldBadge:GetAlpha(), 0)

    state.combat = false
    state:Fire("PLAYER_REGEN_ENABLED")
    state:Fire("UNIT_FLAGS", "nameplate1")
    local newBadge = assert(ui.badges.active.nameplate1)
    H.True(newBadge ~= oldBadge)
    H.Equal(newBadge:GetParent(), replacement)
    H.True(badgeArtworkVisible(newBadge.icon))
    H.False(badgeArtworkVisible(newBadge.locator))
    H.Equal(ui.badges.count, 2)
    ui:Refresh()
    H.Equal(oldBadge:GetAlpha(), 0)
    H.False(badgeArtworkVisible(oldBadge.icon)); H.False(badgeArtworkVisible(oldBadge.locator))
    local original = { [oldBadge] = true, [oldBadge.icon] = true, [oldBadge.locator] = true }
    for index = before + 1, #state.mutations do H.Nil(original[state.mutations[index].frame]) end

    oldPlate.protected = false
    state:Unit("nameplate2", { guid = "Player-RecycledSafe", name = "Next rival", class = "HUNTER", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    H.Equal(ui.badges.active.nameplate2, oldBadge)
    H.Equal(oldBadge:GetParent(), state.plates.nameplate2)
    H.True(badgeArtworkVisible(oldBadge.icon))
    H.False(badgeArtworkVisible(oldBadge.locator))
    H.Equal(oldBadge.icon.texture, "Interface\\Icons\\ClassIcon_HUNTER")
    H.Equal(ui.badges.active.nameplate1, newBadge)
    H.Equal(ui.badges.count, 2)
    H.Equal(#state.blocked, 0)
    H.Nil(app.diagnostics.counts.errors)
end)

for _, protection in ipairs({ "protected", "unreadable" }) do
    H.Test("a fresh " .. protection .. " parent hides an attached badge before another observation", function()
        local state, app = badgeEvidenceFixture()
        local ui, plate = app.ui, state.plates.nameplate1
        local badge = assert(ui.badges.active.nameplate1)
        ui:Select(app.engine:Snapshot()[1])
        ui.detailsFrame.locate:Click()
        H.True(badgeArtworkVisible(badge.icon))
        H.True(badgeArtworkVisible(badge.locator))
        local isProtected = plate.IsProtected
        state.combat = true
        state:Fire("PLAYER_REGEN_DISABLED")
        if protection == "protected" then plate.protected = true
        else
            local secret = H.Secret("unreadable nameplate protection")
            plate.IsProtected = function() return secret end
        end
        local observations = app.engine.counters.observations
        if protection == "protected" then state:Advance(0.15)
        else ui:Refresh() end
        H.Equal(app.engine.counters.observations, observations)
        H.Equal(#state.blocked, 0)
        H.False(badgeArtworkVisible(badge.icon))
        H.False(badgeArtworkVisible(badge.locator))
        H.Nil(ui.badges.highlight)
        H.Nil(ui.badges.active.nameplate1)
        H.Equal(#ui.badges.pool, 1)

        plate.protected, plate.IsProtected, state.combat = false, isProtected, false
        state:Fire("PLAYER_REGEN_ENABLED")
        state:Fire("UNIT_FLAGS", "nameplate1")
        H.Equal(ui.badges.active.nameplate1, badge)
        H.True(badgeArtworkVisible(badge.icon))
        H.False(badgeArtworkVisible(badge.locator))
        H.Nil(app.diagnostics.counts.errors)
    end)
end

local function automaticLocatorFixture(enabled, configure)
    local relations, restricted = {}, H.Secret("unreadable automatic target relation")
    local state, _, app = setup(nil, function(fixture)
        local compare = fixture.api.UnitIsUnit
        fixture.api.UnitIsUnit = function(first, second)
            if second == "player" and relations[first] then return restricted end
            return compare(first, second)
        end
    end)
    local profile = app.db:GetProfile()
    profile.display.showBadges = false
    if enabled ~= nil then profile.display.highlightTargeting = enabled end
    profile.alerts.muteOrdinary, profile.alerts.cooldown = true, 0
    if configure then configure(profile) end
    app:ProfileChanged()
    state:Unit("player", { guid = "Player-AutomaticSelf" })
    local function proof(token, targeting)
        relations[token .. "target"] = targeting == nil
        state.units[token .. "target"] = targeting and state.units.player or nil
    end
    local function add(index, targeting)
        local token, guid = "nameplate" .. index, "Player-Automatic-" .. index
        state:Unit(token, { guid = guid, name = "Rival " .. index, class = "ROGUE", hostile = true, isPlayer = true })
        proof(token, targeting)
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        for _, view in ipairs(app.engine:Snapshot()) do if view.identity == "guid:" .. guid then return view end end
    end
    local function target(index, targeting)
        local token = "nameplate" .. index
        proof(token, targeting)
        state:Fire("UNIT_TARGET", token)
    end
    return state, app, add, target
end

local function changeFixtureZone(state, instance, zonePVP)
    state.instance, state.zonePVP = instance, zonePVP
    state:Fire("ZONE_CHANGED_NEW_AREA")
end

H.Test("highlight shortcut finds the live banner's rival with Nearby hidden and streamer mode enabled", function()
    local state, _, app = setup()
    local ui, profile = app.ui, app.db:GetProfile()
    local targetChanges = 0
    local function changeTarget() targetChanges = targetChanges + 1 end
    state.api.TargetUnit, state.api.FocusUnit, state.api.ClearTarget = changeTarget, changeTarget, changeTarget
    H.Equal(state.api.BINDING_NAME_RIVALGUARD_HIGHLIGHT_ALERT, ui:T("bindingHighlightAlert"))
    profile.display.classes = { MAGE = true }
    profile.display.showBadges, profile.display.streamer = false, true
    app:OnSettingsChanged()
    local bind = state.api.RivalGuard_Binding
    bind("nearby")
    H.False(ui.frame:IsShown())
    seeSoundRuleRival(state, 1)
    state:Advance(1.25)
    H.Equal(ui.activeBanner.kind, "sighting")
    H.Nil(ui.banner.body:GetText():find("Sound rival 1", 1, true))
    H.Nil(ui.selected)
    H.False(locatorVisible(ui, "nameplate1"))
    bind("highlight")
    H.True(locatorVisible(ui, "nameplate1"))
    H.False(ui.badges.highlight.automatic)
    H.Equal(ui.badges.highlight.id, ui.activeBanner.id)
    H.False(ui.frame:IsShown())
    H.Nil(ui.selected)
    H.Equal(targetChanges, 0)
end)

local function unresolvedBannerFixture(withFocus, holdBanner)
    local state, app, add = automaticLocatorFixture(false)
    local api, secret = state.api, H.Secret("unreadable owner until name update")
    local guid, name = api.UnitGUID, api.UnitName
    local restricted = true
    function api.UnitGUID(token)
        if token == "nameplate1" and restricted then return secret end
        return guid(token)
    end
    function api.UnitName(token)
        if token == "nameplate1" and restricted then return secret, secret end
        return name(token)
    end
    api.UnitFullName = api.UnitName

    if holdBanner then
        add(2, false)
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate2", "Cast-HoldingBanner", 1856)
        state:Advance(0.3)
        H.Equal(app.ui.activeBanner.kind, "stealth")
    end
    local unit = { guid = "Player-ResolvedBanner", name = "Resolved Hunter", class = "HUNTER",
        hostile = true, isPlayer = true }
    local focus
    if withFocus then
        state:Unit("focus", unit)
        state:Fire("PLAYER_FOCUS_CHANGED")
        focus = assert(app.engine.identities["guid:" .. unit.guid])
    end
    state:Unit("nameplate1", unit)
    state:Unit("nameplate1target", state.units.player)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(0.3)
    local anonymous = app.sensors.active.nameplate1.contactID
    H.True(anonymous ~= nil and anonymous ~= focus)
    local function resolve()
        restricted = false
        state:Fire("UNIT_NAME_UPDATE", "nameplate1")
    end
    return state, app, anonymous, focus, unit, resolve
end

for _, withFocus in ipairs({ false, true }) do
    local resolution = withFocus and "merges into an existing focus" or "gains a GUID in place"
    H.Test("the live targeting banner can highlight when its anonymous contact " .. resolution, function()
        local state, app, anonymous, focus, unit, resolve = unresolvedBannerFixture(withFocus)
        local ui, bind = app.ui, state.api.RivalGuard_Binding
        local active = assert(ui.activeBanner)
        H.Equal(active.kind, "targeting")
        H.Equal(active.id, anonymous)
        H.Equal(active.identity, "")
        H.Equal(ui.banner.body:GetText(), ui:T("unknownPlayer"))
        local deadline, observedAt = ui.bannerUntil, active.at
        H.Equal(#app.engine.history, 1)
        H.Equal(#state.sounds, 1)
        H.False(locatorVisible(ui, "nameplate1"))
        resolve()
        state:Advance(0.3)
        local current = assert(ui.activeBanner)
        H.Equal(current.id, focus or anonymous)
        H.Equal(current.identity, "guid:" .. unit.guid)
        H.Equal(ui.banner.body:GetText(), unit.name)
        H.Equal(ui.bannerUntil, deadline)
        H.Equal(current.at, observedAt)
        H.Equal(#app.engine.history, 1)
        H.Equal(#state.sounds, 1)
        H.True(bind("highlight"))
        H.True(locatorVisible(ui, "nameplate1"))
        H.Equal(ui.badges.highlight.id, focus or anonymous)
    end)
end

H.Test("a queued targeting banner retains its queue time when the owner becomes identifiable", function()
    local state, app, anonymous, focus, unit, resolve = unresolvedBannerFixture(true, true)
    local ui = app.ui
    H.Equal(ui.activeBanner.kind, "stealth")
    local queued = assert(ui.bannerQueue[1])
    H.Equal(queued.id, anonymous)
    H.Equal(queued.kind, "targeting")
    local observedAt, deadline = queued.at, ui.bannerUntil
    resolve()
    H.Equal(ui.activeBanner.kind, "stealth")
    H.Equal(ui.bannerUntil, deadline)
    H.Equal(#ui.bannerQueue, 1)
    H.Equal(ui.bannerQueue[1].id, focus)
    H.Equal(ui.bannerQueue[1].identity, "guid:" .. unit.guid)
    H.Equal(ui.bannerQueue[1].at, observedAt)
    local soundCount, delivered = #state.sounds, #app.engine.history
    state.clock.Advance(deadline - state.clock.Now() + 0.01)
    state:Advance(0.25)
    H.Equal(ui.activeBanner.kind, "targeting")
    H.Equal(ui.banner.body:GetText(), unit.name)
    H.Equal(#state.sounds, soundCount)
    H.Equal(#app.engine.history, delivered)
    H.True(state.api.RivalGuard_Binding("highlight"))
    H.True(locatorVisible(ui, "nameplate1"))
end)

H.Test("resolving a banner owner cannot restore a targeting relation lost on the same read", function()
    local state, app, _, _, _, resolve = unresolvedBannerFixture(true)
    H.Equal(app.ui.activeBanner.kind, "targeting")
    state.units.nameplate1target = nil
    resolve()
    state:Advance(0.3)
    H.Nil(app.ui.activeBanner)
    H.False(state.api.RivalGuard_Binding("highlight"))
    H.False(locatorVisible(app.ui, "nameplate1"))
    H.Equal(#state.sounds, 1)
end)

for _, ineligible in ipairs({ "wave", "preview", "expired", "paused" }) do
    H.Test("highlight shortcut declines the current banner when it is " .. ineligible, function()
        local state, _, app = setup()
        local ui, bind = app.ui, state.api.RivalGuard_Binding
        if ineligible == "preview" then
            app:Demo()
            H.True(ui.activeBanner.preview)
        else
            for index = 1, (ineligible == "wave" and 3 or 1) do seeSoundRuleRival(state, index) end
            state:Advance(1.25)
            H.Equal(ui.activeBanner.kind, ineligible == "wave" and "wave" or "sighting")
            if ineligible == "expired" then
                state.clock.Advance(ui.bannerUntil - state.clock.Now() + 0.01)
                H.True(ui.banner:IsShown())
            elseif ineligible == "paused" then
                bind("pause")
                H.True(app.engine.pausedUntil > state.clock.Now())
            end
        end
        local messagesBefore = #state.messages
        bind("highlight")
        H.Nil(ui.badges.highlight)
        H.Equal(#state.messages, messagesBefore + 1)
        H.True(state.messages[#state.messages]:find(ui:T("alertHighlightUnavailable"), 1, true) ~= nil)
    end)
end

H.Test("a failed shortcut on a recycled nameplate preserves a different manual marker", function()
    local state, app, ui = locatorFixture()
    app.db:GetProfile().alerts.muteOrdinary = true
    app:OnSettingsChanged()
    ui.detailsFrame.locate:Click()
    local prior = assert(ui.badges.highlight)
    H.True(locatorVisible(ui, "nameplate1"))
    seeSoundRuleRival(state, 2)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate2", "Cast-ShortcutRival", 1856)
    state:Advance(0.3)
    H.Equal(ui.activeBanner.kind, "stealth")
    state:Unit("nameplate2", { guid = "Player-ShortcutReplacement", name = "Replacement", class = "HUNTER",
        hostile = true, isPlayer = true })
    local messagesBefore = #state.messages
    state.api.RivalGuard_Binding("highlight")
    H.False(locatorVisible(ui, "nameplate2"))
    H.True(locatorVisible(ui, "nameplate1"))
    H.Equal(ui.badges.highlight, prior)
    H.Equal(#state.messages, messagesBefore + 1)
    H.True(state.messages[#state.messages]:find(ui:T("locateUnavailable"), 1, true) ~= nil)
end)

for _, changed in ipairs({ "target relation", "zone context" }) do
    H.Test("highlight shortcut rechecks " .. changed .. " before the next update", function()
        local state, app, add = automaticLocatorFixture(false)
        local ui = app.ui
        add(1, true)
        state:Advance(0.3)
        local active, bind = assert(ui.activeBanner), state.api.RivalGuard_Binding
        H.Equal(active.kind, "targeting")
        H.False(locatorVisible(ui, "nameplate1"))
        if changed == "target relation" then
            state.units.nameplate1target = nil
        else
            state.zonePVP = "sanctuary"
        end
        H.True(app.engine:Snapshot()[1].targeting)
        H.Nil(app:AlertBlock())
        local messagesBefore = #state.messages
        bind("highlight")
        H.False(locatorVisible(ui, "nameplate1"))
        H.Equal(#state.messages, messagesBefore + 1)
        local notice = changed == "target relation" and "locateUnavailable" or "alertHighlightUnavailable"
        H.True(state.messages[#state.messages]:find(ui:T(notice), 1, true) ~= nil)
    end)
end

local function countNameplateRecoveryReads(state, app)
    local reads, scans = 0, 0
    local read, scan = app.client.ReadUnit, state.api.C_NamePlate.GetNamePlates
    function app.client:ReadUnit(token, ...)
        if token == "nameplate1" then reads = reads + 1 end
        return read(self, token, ...)
    end
    state.api.C_NamePlate.GetNamePlates = function(...)
        scans = scans + 1
        return scan(...)
    end
    return function() return reads, scans end
end

H.Test("a mapped nameplate that briefly fails a poll recovers without a new add or stale cast", function()
    local state, app, add = automaticLocatorFixture(true, function(profile)
        profile.display.showBadges = true
    end)
    local ui = app.ui
    local before = assert(add(1, true))
    state:Advance(0.5)
    H.True(locatorVisible(ui, "nameplate1"))
    H.True(badgeArtworkVisible(ui.badges.active.nameplate1.icon))
    local unit = state.units.nameplate1
    local oldGeneration = app.sensors.active.nameplate1.generation
    local counts = countNameplateRecoveryReads(state, app)
    state.units.nameplate1 = nil
    state:Advance(0.3)
    H.Nil(app.sensors.active.nameplate1)
    H.False(app.engine:Snapshot()[1].visible)
    H.Nil(ui.badges.active.nameplate1)
    H.False(locatorVisible(ui, "nameplate1"))
    H.Nil(ui.activeBanner)

    state:Unit("nameplate1", unit)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-BeforeRecovery", 1856)
    state:Advance(0.35)
    local current = assert(app.engine:Snapshot()[1])
    H.Equal(current.identity, before.identity)
    H.True(current.visible)
    H.True(current.targeting)
    H.Nil(current.stealth)
    H.True(app.sensors.active.nameplate1.generation > oldGeneration)
    H.True(badgeArtworkVisible(ui.badges.active.nameplate1.icon))
    H.Equal(app.engine.history[1].kind, "targeting")
    for _, entry in ipairs(app.engine.history) do H.Equal(entry.kind, "targeting") end
    local reads, scans = counts()
    H.True(reads >= 2)
    H.Equal(scans, 0)
end)

H.Test("initial add read failure recovers the plate's current owner exactly once next poll", function()
    local state, _, app = setup()
    local counts = countNameplateRecoveryReads(state, app)
    local token = "nameplate1"
    state:Unit(token, { guid = "Player-InitialTransient" })
    state.units[token] = nil
    state:Fire("NAME_PLATE_UNIT_ADDED", token)
    H.Equal(counts(), 1)
    H.Equal(#app.engine:Snapshot(), 0)
    state:Unit(token, { guid = "Player-InitialRecovered", name = "Recovered rival", class = "HUNTER",
        hostile = true, isPlayer = true })
    state:Advance(0.27)
    local observed = assert(app.engine:Snapshot()[1], "mapped plate should recover on the next scheduled poll")
    H.Equal(observed.identity, "guid:Player-InitialRecovered")
    H.True(observed.visible)
    local reads, scans = counts()
    H.Equal(reads, 2)
    H.Equal(scans, 0)
    state:Advance(1.25)
    H.Equal(#app.engine.history, 1)
    H.Equal(app.engine.history[1].kind, "sighting")
    local journal = app.db:GetJournal()
    H.Equal(#journal, 1)
    H.Equal(journal[1].identity, observed.identity)
    H.Equal(journal[1].encounters, 1)
end)

for _, stop in ipairs({ "remove event", "different frame", "retry budget" }) do
    H.Test("a pending nameplate read recovery stops after " .. stop, function()
        local state, _, app = setup()
        local counts = countNameplateRecoveryReads(state, app)
        local token = "nameplate1"
        state:Unit(token, { guid = "Player-CanceledTransient" })
        state.units[token] = nil
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        if stop == "remove event" then
            state:Fire("NAME_PLATE_UNIT_REMOVED", token)
        elseif stop == "different frame" then
            state.plates[token] = state.api.CreateFrame("Frame", nil, state.api.UIParent)
        else
            state:Advance(1.25)
        end
        state:Unit(token, { guid = "Player-FreshAdd", name = "Fresh rival", class = "HUNTER",
            hostile = true, isPlayer = true })
        state:Advance(1.25)
        H.Equal(#app.engine:Snapshot(), 0)
        H.Equal(#app.db:GetJournal(), 0)
        local reads, scans = counts()
        H.Equal(reads, stop == "retry budget" and 4 or 1)
        H.Equal(scans, 0)

        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        local observed = assert(app.engine:Snapshot()[1])
        H.Equal(observed.identity, "guid:Player-FreshAdd")
        H.True(observed.visible)
    end)
end

local function fullNameplateFixture()
    local state, _, app = setup(nil, function(mock)
        mock.api.SOUNDKIT = RULE_SOUND_KITS
    end)
    local reads, scans = {}, 0
    local readUnit, scan = app.client.ReadUnit, state.api.C_NamePlate.GetNamePlates
    function app.client:ReadUnit(token, ...)
        reads[token] = (reads[token] or 0) + 1
        return readUnit(self, token, ...)
    end
    state.api.C_NamePlate.GetNamePlates = function(...)
        scans = scans + 1
        return scan(...)
    end
    state:Unit("player", { guid = "Player-OverflowSelf" })
    H.True(app:Status().capabilities.nameplateEvents)
    for index = 1, 124 do
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Creature-Capacity" .. index, name = "Fixture NPC",
            class = "WARRIOR", hostile = true, isPlayer = false })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    H.Equal(app.sensors.plateCount, 124)
    H.Equal(#app.engine:Snapshot(), 0)
    local function appear(index, isPlayer)
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-Overflow" .. index, name = "Overflow rogue " .. index,
            class = "ROGUE", hostile = true, isPlayer = isPlayer ~= false })
        state:Unit(token .. "target", state.units.player)
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        H.Nil(app.sensors.active[token])
        H.Nil(reads[token])
        return token
    end
    local function disappear(token)
        state.units[token] = nil
        state:Fire("NAME_PLATE_UNIT_REMOVED", token)
    end
    return state, app, appear, disappear, reads, function() return scans end
end

H.Test("healthy nameplate overflow queues a rival until a slot opens without retaining an unobserved cast", function()
    local state, app, appear, disappear, reads, scans = fullNameplateFixture()
    local first, second = appear(125), appear(126)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", first, "Cast-BeforeOverflowAdmission", 1856)
    state:Advance(0.3)
    H.Nil(reads[first]); H.Nil(reads[second])
    H.Equal(#app.engine.history, 0)
    H.Equal(app.sensors.plateCount, 124)
    disappear("nameplate1")
    H.Equal(app.sensors.plateCount, 123)
    state:Advance(0.3)
    H.Equal(reads[first], 1)
    H.Nil(reads[second])
    H.Equal(app.sensors.plateCount, 124)
    H.Equal(scans(), 0)
    local contact = assert(app.engine:Snapshot()[1])
    H.Equal(contact.identity, "guid:Player-Overflow125")
    H.True(contact.visible); H.True(contact.targeting)
    H.Nil(contact.stealth)
    H.Equal(#app.engine.history, 1)
    H.Equal(app.engine.history[1].id, contact.id)
    H.Equal(app.engine.history[1].kind, "targeting")
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.READY_CHECK)
    H.Equal(app.db:GetJournal()[1].identity, contact.identity)
end)

H.Test("removing an overflow token cancels waiting admission and releases its place in line", function()
    local state, app, appear, disappear, reads, scans = fullNameplateFixture()
    local gone, nextToken = appear(125), appear(126)
    local pooledUnit = state.units[gone]
    disappear(gone)
    -- The number is reusable even when the frame object is still pooled.
    -- Without another ADD, the removed registration cannot admit this unit.
    state:Unit(gone, pooledUnit)
    disappear("nameplate1")
    state:Advance(0.3)
    H.Nil(app.sensors.active[gone])
    H.Nil(reads[gone])
    H.Equal(reads[nextToken], 1)
    H.Equal(app.sensors.plateCount, 124)
    H.Equal(scans(), 0)
    local current = assert(app.engine:Snapshot()[1])
    H.Equal(current.identity, "guid:Player-Overflow126")
    H.Equal(#app.db:GetJournal(), 1)
    H.Equal(app.db:GetJournal()[1].identity, current.identity)
end)

H.Test("Support and copied diagnostics show current nameplate overflow even without any player observations", function()
    local state, app, appear, disappear, reads, scans = fullNameplateFixture()
    local ui, bind = app.ui, state.api.RivalGuard_Binding
    app.db:GetProfile().locale = "ruRU"
    app:OnSettingsChanged()
    ui:OpenSettings("support")
    state:Advance(0.3)
    local function status(deferred, detection, stateName, blocked)
        local current = app:Status()
        H.Equal(current.detectionState, detection)
        H.Equal(current.deferredNameplates, deferred)
        H.Equal(current.state, stateName)
        H.Equal(app:AlertBlock(), blocked)
        H.True(current.capabilities.nameplateEvents)
    end
    local function capacityHint(deferred)
        for count = 0, 2 do
            local message = ui.supportStatus:GetText():find(ui:F("nameplatesCapacity", count), 1, true)
            H.Equal(message ~= nil, deferred == count)
        end
    end
    local function checkReport(deferred, detection)
        ui:ShowDiagnostics()
        local report = ui.copyFrame.edit:GetText()
        H.True(report:find("deferredNameplates=" .. deferred, 1, true) ~= nil)
        H.True(report:find("detection=" .. detection, 1, true) ~= nil)
        H.True(report:find("sensor_capacity=2", 1, true) ~= nil)
        for _, private in ipairs({ "nameplate125", "nameplate126", "Player-Overflow", "Overflow rogue", "Fixture NPC" }) do
            H.Nil(report:find(private, 1, true))
        end
        ui.copyFrame:Hide()
    end

    H.Equal(app:Status().detectionState, "active")
    capacityHint()
    H.False(app.dirty)
    local first, second = appear(125, false), appear(126, false)
    status(2, "limited", "limited", nil)
    state:Advance(0.3)
    capacityHint(2)
    checkReport(2, "limited")
    bind("pause")
    status(2, "limited", "paused", "paused")
    bind("pause")
    status(2, "limited", "limited", nil)
    state:Advance(0.3)

    disappear(first)
    status(1, "limited", "limited", nil)
    state:Advance(0.3)
    capacityHint(1)
    checkReport(1, "limited")
    disappear("nameplate1")
    state:Advance(0.3)
    H.Equal(reads[second], 1)
    H.Equal(scans(), 0)
    status(0, "active", "active", nil)
    capacityHint()
    checkReport(0, "active")
    H.Equal(ui.currentPage, "support")
    H.Equal(#app.engine:Snapshot(), 0)
    H.Equal(#app.db:GetJournal(), 0)
    H.Equal(#state.sounds, 0)
end)

local function partialEnemyFixture()
    local evidence = {}
    local state, _, app = setup(nil, function(mock)
        local api, secret = mock.api, H.Secret("restricted enemy eligibility")
        local player, hostile = api.UnitIsPlayer, api.UnitIsEnemy
        function api.UnitIsPlayer(token)
            local sample = evidence[token]
            if sample then
                if sample.player == nil then return secret end
                return sample.player
            end
            return player(token)
        end
        function api.UnitIsEnemy(unit, token)
            local sample = evidence[token]
            if sample then
                if sample.hostile == nil then return secret end
                return sample.hostile
            end
            return hostile(unit, token)
        end
        function api.UnitCanAttack(unit, token) return api.UnitIsEnemy(unit, token) end
    end)
    local function observe(index, player, hostile)
        local token = "nameplate" .. index
        evidence[token] = { player = player, hostile = hostile }
        state:Unit(token, { guid = "Player-PrivatePartial" .. index, name = "PrivatePartialName" .. index, class = "HUNTER" })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        return token
    end
    local function change(token, player, hostile)
        evidence[token] = { player = player, hostile = hostile }
        state:Fire("UNIT_FLAGS", token)
    end
    return state, app, observe, change
end

H.Test("Support counts only current sightings with one missing eligibility flag and diagnostics stay aggregate", function()
    local state, app, observe, change = partialEnemyFixture()
    local ui, profile = app.ui, app.db:GetProfile()
    profile.locale = "ruRU"
    app:OnSettingsChanged()
    local playerOnly = observe(1, true, nil)
    local hostileOnly = observe(2, nil, true)
    observe(3, nil, nil)
    observe(4, false, true)
    observe(5, true, false)
    H.Equal(#app.db:GetJournal(), 0)
    H.Equal(#app.engine.history, 0)
    H.Nil(app:AlertBlock())
    H.Equal(app:Status().detectionState, "active")
    H.Nil(app:Status().unconfirmedEnemyContacts)
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 2)
    ui:OpenSettings("support")
    state:Advance(1.25)
    local function hint(shown)
        local body = ui.supportStatus:GetText()
        H.Equal(body:find(ui:T("nameplatesIncomplete"), 1, true) ~= nil, shown)
    end
    local function reportContains(count)
        ui:ShowDiagnostics()
        local report = ui.copyFrame.edit:GetText()
        H.True(report:find("unconfirmedEnemyContacts=" .. count, 1, true) ~= nil)
        for _, private in ipairs({ "Player-PrivatePartial", "PrivatePartialName", playerOnly, hostileOnly }) do
            H.Nil(report:find(private, 1, true))
        end
        ui.copyFrame:Hide()
    end
    hint(true)
    reportContains(2)
    H.Equal(#app.engine.history, 0)
    H.Equal(#state.sounds, 0)
    app:Demo()
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 2)
    ui:OpenSettings("support")
    change(playerOnly, true, true)
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 1)
    reportContains(1)
    state:Advance(1.25)
    hint(true)
    H.Equal(app.db:GetJournal()[1].identity, "guid:Player-PrivatePartial1")

    state.units[hostileOnly] = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", hostileOnly)
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 0)
    state:Advance(1.25)
    hint(false)
    reportContains(0)
    H.Equal(app:Status().detectionState, "active")
end)

H.Test("same-owner complementary aliases resolve an incomplete sighting until the confirming alias leaves", function()
    local state, app, observe, change = partialEnemyFixture()
    local token = observe(1, true, nil)
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 1)
    state:Unit("focus", state.units[token])
    change("focus", nil, true)
    H.Equal(#app.engine:Snapshot(), 1)
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 0)
    local complete = app.engine:Snapshot()[1]
    H.True(complete.hostile); H.True(complete.isPlayer)
    state.units.focus = nil
    state:Fire("PLAYER_FOCUS_CHANGED")
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 1)
    change(token, true, true)
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 0)
    change(token, nil, true)
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 1)
    state.clock.Advance(2.1)
    H.Equal(#app.engine:Snapshot(), 1)
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 0)
    change(token, nil, true)
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 1)
    change(token, nil, nil)
    H.Equal(app:Status(true).unconfirmedEnemyContacts, 0)
end)

H.Test("nameplate discovery uses current sanctuary state before the zone event", function()
    local state, _, app = setup()
    state.zonePVP = "sanctuary"
    seeSoundRuleRival(state, 1)
    H.Equal(#app.engine:Snapshot(), 1)
    H.Equal(#app.db:GetJournal(), 0)
    H.Equal(app:AlertBlock(), "sanctuary")
    state:Advance(1.25)
    H.Equal(#app.db:GetJournal(), 0)
    H.Equal(#app.engine.history, 0)
    H.Equal(#state.sounds, 0)
end)

H.Test("a direct target discovery observes the current resting state before the update event", function()
    local state, _, app = setup()
    state.resting = true
    state:Unit("target", { guid = "Player-Resting-Direct", name = "Direct rival", class = "ROGUE",
        hostile = true, isPlayer = true })
    state:Fire("PLAYER_TARGET_CHANGED")
    H.Equal(#app.engine:Snapshot(), 1)
    H.Equal(#app.db:GetJournal(), 0)
    H.Equal(app:AlertBlock(), "resting")
    state:Advance(1.25)
    H.Equal(#app.engine.history, 0)
    H.Equal(#state.sounds, 0)
end)

H.Test("a verified Vanish uses the newly allowed resting context before its update event", function()
    local state, _, app = setup()
    local profile = app.db:GetProfile()
    profile.alerts.muteOrdinary = true
    profile.retention.journalMode = "threats"
    app:OnSettingsChanged()
    state.resting = true
    state:Fire("PLAYER_UPDATE_RESTING")
    seeSoundRuleRival(state, 1)
    H.Equal(app:AlertBlock(), "resting")
    H.Equal(#app.db:GetJournal(), 0)
    state.resting = false
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-AfterResting", 1856)
    H.Nil(app:AlertBlock())
    H.Equal(app.db:GetJournal()[1].encounters, 1)
    state:Advance(0.5)
    H.Equal(#app.engine.history, 1)
    H.Equal(app.engine.history[1].kind, "stealth")
    H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellVanish")))
    H.Equal(#state.sounds, 1)
end)

for _, priority in ipairs({ 1, 50, 100 }) do
    H.Test("a queued Vanish wins over the same rival's Any-rule sighting at priority " .. priority, function()
        local state, app, profile = ruleSoundFixture()
        local rule = soundRule("All warnings", "quest", priority)
        rule.event = "any"
        profile.rules = { rule }
        app:OnSettingsChanged()
        seeSoundRuleRival(state, 1)
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-AnyRuleBurst", 1856)
        state:Advance(0.3)
        H.Equal(#app.engine.history, 1)
        H.Equal(app.engine.history[1].kind, "stealth")
        H.Equal(app.engine.history[1].reason, "custom_rule")
        H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellVanish")))
        H.Equal(#state.sounds, 1)
        H.Equal(state.sounds[1].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)
        state:Advance(1.25)
        H.Equal(#app.engine.history, 1)
        H.Equal(#state.sounds, 1)
    end)
end

H.Test("a winning custom suppression still silences Vanish without canceling the ordinary sighting", function()
    local state, app, profile = ruleSoundFixture()
    local ordinary = soundRule("Ordinary signal", "ping", 50)
    ordinary.event = "any"
    local suppress = soundRule("Suppress Vanish", nil, 51)
    suppress.event, suppress.action = "stealth", "suppress"
    profile.rules = { ordinary, suppress }
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-RuleSuppressed", 1856)
    state:Advance(0.3)
    H.Equal(#app.engine.history, 0)
    H.Equal(#state.sounds, 0)
    state:Advance(1)
    H.Equal(#app.engine.history, 1)
    H.Equal(app.engine.history[1].kind, "sighting")
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.MAP_PING)
end)

H.Test("Vanish upgrades the same rival's active equal-priority sighting banner on a later tick", function()
    local state, app, profile = ruleSoundFixture()
    local rule = soundRule("All urgent banners", "quest", 100)
    rule.event = "any"
    profile.rules = { rule }
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    state:Advance(0.3)
    H.Equal(app.ui.activeBanner.kind, "sighting")
    H.Equal(#state.sounds, 1)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-AfterSighting", 1856)
    state:Advance(0.3)
    H.Equal(#app.engine.history, 2)
    H.Equal(app.engine.history[2].kind, "stealth")
    H.Equal(app.ui.activeBanner.kind, "stealth")
    H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellVanish")))
    H.Equal(#state.sounds, 1)
end)

H.Test("a queued targeting warning wins over the same rival's higher-priority ordinary sighting", function()
    local state, app, add = automaticLocatorFixture(false, function(profile)
        profile.alerts.muteOrdinary = false
        local ordinary = soundRule("Urgent sighting", nil, 100)
        local targeting = soundRule("Custom targeting", nil, 1)
        ordinary.sound, targeting.sound, targeting.event = false, false, "targeting"
        profile.rules = { ordinary, targeting }
    end)
    add(1, true)
    state:Advance(0.3)
    H.Equal(#app.engine.history, 1)
    H.Equal(app.engine.history[1].kind, "targeting")
    H.Equal(app.ui.activeBanner.kind, "targeting")
    state:Advance(1.25)
    H.Equal(#app.engine.history, 1)
    H.Equal(#state.sounds, 0)
end)

H.Test("UNIT_AURA after leaving sanctuary is eligible before the zone event", function()
    local state, _, app = setup(nil, function(fixture)
        fixture.api.C_Secrets = { ShouldAurasBeSecret = function() return false end }
        fixture.api.C_UnitAuras = { GetAuraDataByIndex = function(token, index)
            local owner = fixture.units[token]
            if owner and owner.aura and index == 1 then return { spellId = owner.aura } end
        end }
    end)
    local profile = app.db:GetProfile()
    profile.alerts.muteOrdinary = true
    profile.retention.journalMode = "threats"
    app:OnSettingsChanged()
    changeFixtureZone(state, nil, "sanctuary")
    seeSoundRuleRival(state, 1)
    H.Equal(#app.db:GetJournal(), 0)
    state.zonePVP = nil
    state.units.nameplate1.aura = 1784
    state:Fire("UNIT_AURA", "nameplate1")
    H.Nil(app:AlertBlock())
    H.Equal(app.db:GetJournal()[1].encounters, 1)
    state:Advance(0.5)
    H.Equal(#app.engine.history, 1)
    H.Equal(app.engine.history[1].kind, "stealth")
    H.Equal(app.ui.banner.title:GetText(), app.ui:T("stealthAura"))
    H.Equal(#state.sounds, 1)
end)

H.Test("UNIT_TARGET in sanctuary retires the targeting banner and prevents pending alert replay", function()
    local state, app, add, target = automaticLocatorFixture(true)
    local ui = app.ui
    add(1, true)
    state:Advance(0.5)
    H.Equal(ui.activeBanner.kind, "targeting")
    H.True(locatorVisible(ui, "nameplate1"))
    add(2, false)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate2", "Cast-BeforeSanctuary", 1856)
    state.zonePVP = "sanctuary"
    target(2, true)
    H.Equal(app:AlertBlock(), "sanctuary")
    H.Nil(ui.activeBanner)
    H.False(locatorVisible(ui, "nameplate1"))
    target(2, false)
    state.zonePVP = nil
    state:Fire("ZONE_CHANGED_NEW_AREA")
    state:Advance(0.5)
    H.Equal(#app.engine.history, 1)
    H.Equal(#state.sounds, 1)
    H.Nil(ui.activeBanner)
end)

for _, boundary in ipairs({ "sanctuary", "arena" }) do
    H.Test("a rapid " .. boundary .. " visit retires live targeting and discards a queued Vanish", function()
        local state, app, add = automaticLocatorFixture(true)
        local ui = app.ui
        add(1, true)
        state.clock.Advance(0.25)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(ui.activeBanner.kind, "targeting")
        H.True(locatorVisible(ui, "nameplate1"))
        add(2, false)
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate2", "Cast-BeforeQuietZone", 1856)

        local now = state.clock.Now()
        if boundary == "sanctuary" then changeFixtureZone(state, nil, "sanctuary")
        else changeFixtureZone(state, "arena") end
        H.Equal(app:AlertBlock(), boundary == "sanctuary" and "sanctuary" or "context_disabled")
        H.Nil(ui.activeBanner)
        H.False(ui.banner:IsShown())
        H.False(locatorVisible(ui, "nameplate1"))
        changeFixtureZone(state)
        H.Equal(state.clock.Now(), now)
        H.Nil(app:AlertBlock())
        state.clock.Advance(0.25)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(#state.sounds, 1)
        H.Nil(ui.activeBanner)
        H.Equal(#app.engine:Snapshot(), 2)
    end)
end

H.Test("a true world loading boundary clears the current contacts and their pending alerts", function()
    local state, app, add = automaticLocatorFixture(true)
    add(1, true)
    app.engine:Tick()
    H.Equal(app.ui.activeBanner.kind, "targeting")
    add(2, false)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate2", "Cast-BeforeWorldLoad", 1856)
    state:Fire("PLAYER_LEAVING_WORLD")
    H.Nil(app.ui.activeBanner)
    H.False(locatorVisible(app.ui, "nameplate1"))
    H.Equal(#app.engine:Snapshot(), 0)
    H.Equal(#app.engine.history, 0)
    state.units.nameplate1, state.units.nameplate1target, state.units.nameplate2 = nil, nil, nil
    state:Fire("PLAYER_ENTERING_WORLD")
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Nil(app.ui.activeBanner)
end)

H.Test("a quiet context preserves a sample banner and a deliberate manual locator", function()
    local state, app, add = automaticLocatorFixture(true)
    local ui = app.ui
    ui:Select(assert(add(1, false)))
    ui.detailsFrame.locate:Click()
    H.True(locatorVisible(ui, "nameplate1"))
    H.False(ui.badges.highlight.automatic)
    app:Demo()
    H.True(ui.activeBanner.preview)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-BeforeSampleContext", 1856)
    changeFixtureZone(state, nil, "sanctuary")
    H.True(ui.activeBanner.preview)
    H.True(locatorVisible(ui, "nameplate1"))
    changeFixtureZone(state)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 0)
    H.True(ui.activeBanner.preview)
    H.True(locatorVisible(ui, "nameplate1"))
end)

H.Test("automatic targeting highlight is off by default and opt-in applies only to new warnings", function()
    local state, app, add, target = automaticLocatorFixture()
    local ui, profile = app.ui, app.db:GetProfile()
    H.True(profile.display.highlightTargeting ~= true)
    add(1, true)
    state:Advance(0.5)
    H.Equal(app.engine.history[1].kind, "targeting")
    H.False(locatorVisible(ui, "nameplate1"))
    profile.display.highlightTargeting = true
    app:ProfileChanged()
    state:Advance(0.5)
    H.False(locatorVisible(ui, "nameplate1"))

    target(1, false)
    target(1, true)
    state:Advance(0.5)
    H.Equal(app.engine.history[2].kind, "targeting")
    H.True(locatorVisible(ui, "nameplate1"))
    H.True(ui.badges.highlight.automatic)
    H.False(profile.display.showBadges)
    state:Advance(3.6)
    H.False(locatorVisible(ui, "nameplate1"))
    H.Nil(ui.badges.highlight)
    H.Equal(app.engine.counters.alerts, 2)
end)

H.Test("automatic nameplate highlights preserve the first marker and yield to a manual highlight", function()
    local state, app, add = automaticLocatorFixture(true)
    local ui = app.ui
    add(1, true)
    state:Advance(0.5)
    H.True(locatorVisible(ui, "nameplate1"))
    add(2, true)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 2)
    H.True(locatorVisible(ui, "nameplate1"))
    H.False(locatorVisible(ui, "nameplate2"))

    ui:Select(assert(add(3, false)))
    ui.detailsFrame.locate:Click()
    H.True(locatorVisible(ui, "nameplate3"))
    H.False(locatorVisible(ui, "nameplate1"))
    H.True(ui.badges.highlight.automatic ~= true)
    add(4, true)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 3)
    H.True(locatorVisible(ui, "nameplate3"))
    H.False(locatorVisible(ui, "nameplate4"))
end)

H.Test("automatic highlighting follows a sound-only warning after its pacing delay", function()
    local state, app, add, target = automaticLocatorFixture(true, function(profile) profile.alerts.banner = false end)
    local ui = app.ui
    add(1, true)
    state:Advance(0.5)
    H.Equal(#state.sounds, 1)
    H.True(locatorVisible(ui, "nameplate1"))
    H.Nil(ui.activeBanner)

    target(1, false)
    add(2, true)
    state:Advance(0.5)
    H.Nil(ui.badges.highlight)
    H.Equal(#state.sounds, 1)
    state:Advance(1.2)
    H.Equal(#state.sounds, 2)
    H.True(locatorVisible(ui, "nameplate2"))
    H.Nil(ui.activeBanner)
end)

H.Test("automatic highlights clear when targeting is unreadable or the user pauses or snoozes", function()
    local state, app, add, target = automaticLocatorFixture(true)
    local ui = app.ui
    local view = assert(add(1, true))
    state:Advance(0.5)
    H.True(locatorVisible(ui, "nameplate1"))
    assert(app:Snooze(view, 10))
    state:Advance(0.3)
    H.False(locatorVisible(ui, "nameplate1"))
    assert(app:Snooze(view, 10))
    local function retrigger()
        target(1, false)
        target(1, true)
        state:Advance(0.5)
        H.True(locatorVisible(ui, "nameplate1"))
    end
    retrigger()
    state.api.SlashCmdList.RIVALGUARD("pause 1")
    state:Advance(0.3)
    H.False(locatorVisible(ui, "nameplate1"))
    state.api.SlashCmdList.RIVALGUARD("resume")
    retrigger()
    target(1, nil)
    state:Advance(0.3)
    H.False(locatorVisible(ui, "nameplate1"))
    target(1, true)
    state:Advance(0.3)
    H.False(locatorVisible(ui, "nameplate1"))
    retrigger()
    target(1, false)
    state:Advance(0.3)
    H.False(locatorVisible(ui, "nameplate1"))
    retrigger()
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    H.False(locatorVisible(ui, "nameplate1"))
end)

H.Test("automatic highlights require a targeting warning and freshly verified nameplate owner", function()
    local filteredState, filtered, addFiltered = automaticLocatorFixture(true, function(profile)
        profile.alerts.classes = { HUNTER = true }
    end)
    addFiltered(1, true)
    filteredState:Advance(0.5)
    H.Equal(filtered.engine.counters.alerts, 0)
    H.False(locatorVisible(filtered.ui, "nameplate1"))

    local state, app, add = automaticLocatorFixture(true)
    add(1, true)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-AutomaticSupersedes", 1856)
    state:Advance(0.5)
    H.Equal(app.engine.history[1].kind, "stealth")
    H.False(locatorVisible(app.ui, "nameplate1"))
    add(2, true)
    state:Unit("nameplate2", { guid = "Player-RecycledAuto", name = "Other", class = "ROGUE", hostile = true, isPlayer = true })
    app.engine:Tick()
    H.Equal(app.engine.history[2].kind, "targeting")
    H.False(locatorVisible(app.ui, "nameplate2"))

    local waveState, wave, addWave = automaticLocatorFixture(true, function(profile)
        profile.alerts.muteOrdinary = false
    end)
    for index = 1, 3 do addWave(index, false) end
    waveState:Advance(1.25)
    H.Equal(wave.engine.history[1].kind, "wave")
    H.Nil(wave.ui.badges.highlight)
end)

H.Test("stationary nameplate polling reads all opponents without repainting unchanged badges", function()
    local state, _, app = setup()
    local ui = app.ui
    for index = 1, 64 do
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-Stationary-" .. index, name = "Rival " .. index,
            class = "ROGUE", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    state:Advance(1.25)
    H.Equal(#app.engine:Snapshot(), 64)
    H.Equal(app.engine.history[1].kind, "wave")

    local reads, writes = {}, { SetShown = 0, Show = 0, Hide = 0, SetTexture = 0 }
    local guid = state.api.UnitGUID
    state.api.UnitGUID = function(token)
        if token:match("^nameplate%d+$") then reads[token] = (reads[token] or 0) + 1 end
        return guid(token)
    end
    local function instrument(frame, method)
        local invoke = frame[method]
        frame[method] = function(self, ...)
            writes[method] = writes[method] + 1
            return invoke(self, ...)
        end
    end
    for index = 1, 64 do
        local badge = assert(ui.badges.active["nameplate" .. index])
        H.True(badge.icon:IsVisible())
        for _, region in ipairs({ badge, badge.bg, badge.icon, badge.marker, badge.target, badge.focus, badge.locator }) do
            for _, method in ipairs({ "SetShown", "Show", "Hide" }) do instrument(region, method) end
        end
        instrument(badge.icon, "SetTexture")
    end
    local observed = app.engine.counters.observations
    app.sensors:Poll()
    ui:Refresh()
    H.Equal(app.engine.counters.observations - observed, 64)
    for index = 1, 64 do H.Equal(reads["nameplate" .. index], 1) end
    H.Equal(writes.SetShown + writes.Show + writes.Hide + writes.SetTexture, 0,
        string.format("Stationary badge writes: SetShown=%d Show=%d Hide=%d SetTexture=%d",
            writes.SetShown, writes.Show, writes.Hide, writes.SetTexture))

    local emitted = app.engine.counters.alerts
    state:Unit("player", { guid = "Player-StationarySelf" })
    state:Unit("nameplate1target", state.units.player)
    state:Fire("UNIT_TARGET", "nameplate1")
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, emitted + 1)
    H.Equal(app.engine.history[#app.engine.history].kind, "targeting")
    local first
    for _, contact in ipairs(app.engine:Snapshot()) do
        if contact.identity == "guid:Player-Stationary-1" then first = contact break end
    end
    ui:Select(assert(first))
    ui.detailsFrame.locate:Click()
    H.True(locatorVisible(ui, "nameplate1"))
    state:Advance(3.6)
    H.False(locatorVisible(ui, "nameplate1"))
    H.True(ui.badges.active.nameplate1.icon:IsVisible())
end)

H.Test("stationary Nearby and Details avoid repeat painting while changed contact data still renders", function()
    local state, _, app = setup()
    local ui = app.ui
    for index = 1, 8 do
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-RenderDiff-" .. index, name = "Fixture Rival " .. index,
            class = "ROGUE", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    local function rowFor(index)
        local identity = "guid:Player-RenderDiff-" .. index
        for _, row in ipairs(ui.rows) do
            if row.contact and row.contact.identity == identity then return row end
        end
        error("missing Nearby row for " .. index)
    end
    state:Advance(1.25)
    app.sensors:Poll()
    ui:Refresh()
    H.Equal(ui.renderedCount, 8)
    rowFor(1):Click()
    ui:Refresh()
    local detail = ui.detailsFrame
    H.True(detail:IsShown())
    local lastSeen = rowFor(1).contact.lastSeen
    local writes = {}
    local function track(region, methods)
        for _, method in ipairs(methods) do
            local invoke = assert(region[method])
            region[method] = function(self, ...)
                writes[method] = (writes[method] or 0) + 1
                return invoke(self, ...)
            end
        end
    end
    track(ui.frame, { "SetHeight", "SetScale" })
    track(ui.statusText, { "SetText" })
    track(detail, { "SetHeight", "SetScale" })
    for _, region in ipairs({ detail.title, detail.info, detail.notice, detail.snooze.label }) do
        track(region, { "SetText" })
    end
    for index = 1, 8 do
        local row = ui.rows[index]
        track(row, { "ClearAllPoints", "SetPoint", "SetHeight", "SetAlpha", "SetShown" })
        track(row.nameText, { "SetFont", "SetText", "SetTextColor" })
        track(row.detailText, { "SetFont", "ClearAllPoints", "SetPoint", "SetText", "SetTextColor" })
        track(row.icon, { "SetTexture" })
        track(row.mark, { "SetText", "SetShown" })
    end
    state.clock.Advance(0.5)
    app.sensors:Poll()
    ui:Refresh()
    H.True(rowFor(1).contact.lastSeen > lastSeen)
    H.Equal(ui.selected.lastSeen, rowFor(1).contact.lastSeen)
    local changed, total = {}, 0
    for method, count in pairs(writes) do
        changed[#changed + 1] = method .. "=" .. count
        total = total + count
    end
    table.sort(changed)

    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    ui:Refresh()
    local age = rowFor(1).detailText:GetText()
    state.clock.Advance(3)
    ui:Refresh()
    local lastSeenText = ui:F("lastSeen", ui:F("seconds", 3))
    H.True(age ~= rowFor(1).detailText:GetText())
    H.True(rowFor(1).detailText:GetText():find(lastSeenText, 1, true) ~= nil)
    H.True(detail.info:GetText():find(lastSeenText, 1, true) ~= nil)

    rowFor(2):Click()
    state:Unit("player", { guid = "Player-RenderDiffLocal" })
    state:Unit("nameplate2target", state.units.player)
    state:Fire("UNIT_TARGET", "nameplate2")
    ui:Refresh()
    H.True(rowFor(2).detailText:GetText():find(ui:T("targeting"), 1, true) ~= nil)
    H.True(detail.info:GetText():find(ui:T("targeting"), 1, true) ~= nil)

    app.db:GetProfile().display.streamer = true
    app:OnSettingsChanged()
    H.Nil(rowFor(2).nameText:GetText():find("Fixture Rival 2", 1, true))
    H.Equal(detail.title:GetText(), rowFor(2).nameText:GetText())
    H.Equal(detail.snooze.label:GetText(), ui:T("snoozeContact"))
    detail.snooze:Click()
    H.Equal(detail.snooze.label:GetText(), ui:T("resumeContact"))
    detail.snooze:Click()
    H.Equal(detail.snooze.label:GetText(), ui:T("snoozeContact"))
    H.True(app:Snooze(rowFor(2).contact, 5))
    ui:Refresh()
    H.Equal(detail.snooze.label:GetText(), ui:T("resumeContact"))
    state.clock.Advance(6)
    ui:Refresh()
    H.Equal(detail.snooze.label:GetText(), ui:T("snoozeContact"))

    state.api.UnitDistanceSquared = function(token)
        if token == "nameplate3" then return 400, true end
    end
    state:Fire("UNIT_FLAGS", "nameplate3")
    ui:Refresh()
    rowFor(3):Click()
    H.True(detail.info:GetText():find(ui:T("rangeEvidenceExact"), 1, true) ~= nil)
    state.clock.Advance(3)
    ui:Refresh()
    H.Nil(detail.info:GetText():find(ui:T("rangeEvidenceExact"), 1, true))
    H.True(rowFor(3).detailText:GetText():find(ui:T("rangeUnknown"), 1, true) ~= nil)
    H.True(detail.info:GetText():find(ui:T("rangeEvidenceUnknown"), 1, true) ~= nil, detail.info:GetText())
    H.Equal(total, 0, "Stationary Nearby/Details writes: " .. table.concat(changed, ", "))
end)

H.Test("nameplate highlight works on an already anchored badge in combat and expires", function()
    local state, app, ui = locatorFixture({ schemaVersion = 1, onboardingSeen = true, profiles = { Default = {
        positions = { alert = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 320, y = -180 } },
    } } })
    local badge = assert(ui.badges.active.nameplate1)
    local locator = assert(badge.locator)
    H.Equal(locator.kind, "Frame")
    H.Equal(locator:GetParent(), badge)
    H.Equal(locator.strata, "DIALOG")
    H.Equal(locator.glyph.kind, "FontString")
    H.Equal(locator.glyph:GetParent(), locator)
    local badgeStrata = badge.strata
    H.True(badgeStrata ~= "DIALOG")
    H.Equal(badge:GetParent(), state.plates.nameplate1)
    H.False(locatorVisible(ui, "nameplate1"))
    state:Advance(1)
    H.True(ui.banner:IsShown())
    local alertIcon = ui.banner.icon.texture
    H.Equal(alertIcon, "Interface\\Icons\\ClassIcon_ROGUE")
    local function checkBannerPosition()
        H.Equal(ui.banner.strata, "HIGH")
        local point, relative, relativePoint, x, y = ui.banner:GetPoint(1)
        H.Equal(point, "TOPLEFT")
        H.Equal(relative, state.api.UIParent)
        H.Equal(relativePoint, "TOPLEFT")
        H.Equal(x, 320); H.Equal(y, -180)
        local saved = app.db:GetProfile().positions.alert
        H.Equal(saved.point, point); H.Equal(saved.relativePoint, relativePoint)
        H.Equal(saved.x, x); H.Equal(saved.y, y)
    end
    checkBannerPosition()
    local strataWrites = 0
    local setStrata = locator.SetFrameStrata
    locator.SetFrameStrata = function(self, value)
        strataWrites = strataWrites + 1
        return setStrata(self, value)
    end
    state.combat = true
    state:Fire("PLAYER_REGEN_DISABLED")
    local before = #state.mutations
    ui.detailsFrame.locate:Click()
    H.True(locatorVisible(ui, "nameplate1"))
    H.False(ui.detailsFrame:IsShown())
    H.False(app.db:GetProfile().display.showBadges)
    H.Equal(ui.badges.active.nameplate1, badge)
    H.Equal(badge:GetParent(), state.plates.nameplate1)
    H.False(badge.icon:IsVisible())
    H.Equal(badge.strata, badgeStrata)
    H.Equal(ui.banner.icon.texture, alertIcon)
    local geometry = { SetParent = true, SetPoint = true, ClearAllPoints = true, SetAllPoints = true, SetSize = true, SetWidth = true, SetHeight = true }
    for index = before + 1, #state.mutations do
        local mutation = state.mutations[index]
        if mutation.frame == badge or mutation.frame == locator or mutation.frame == locator.glyph then H.Nil(geometry[mutation.action]) end
    end
    H.Equal(#state.blocked, 0)
    state:Advance(2.2)
    H.True(locatorVisible(ui, "nameplate1"))
    state:Advance(1.4)
    H.False(locatorVisible(ui, "nameplate1"))
    H.Equal(locator.strata, "DIALOG")
    H.Equal(strataWrites, 0)
    checkBannerPosition()
end)

H.Test("a verified but unanchored combat nameplate reports when to retry highlighting", function()
    local state, app, ui = locatorFixture()
    app.db:GetProfile().alerts.muteOrdinary = true
    app:OnSettingsChanged()
    ui.detailsFrame.locate:Click()
    H.True(locatorVisible(ui, "nameplate1"))
    local previous = ui.badges.highlight
    state.combat = true
    state:Fire("PLAYER_REGEN_DISABLED")
    seeSoundRuleRival(state, 2)
    local unit = state.units.nameplate2
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate2", "Cast-UnanchoredCombat", 1856)
    state:Advance(0.3)
    H.Nil(ui.badges.active.nameplate2)
    local banner = assert(ui.activeBanner)
    H.Equal(banner.kind, "stealth")
    H.Equal(banner.identity, "guid:" .. unit.guid)
    local bind = state.api.RivalGuard_Binding
    local function latestNotice(key)
        H.True(state.messages[#state.messages]:find(ui:T(key), 1, true) ~= nil)
    end
    H.False(bind("highlight"))
    latestNotice("locateAfterCombat")
    H.Equal(ui.badges.highlight, previous)
    H.True(locatorVisible(ui, "nameplate1"))
    H.False(locatorVisible(ui, "nameplate2"))

    local contact = assert(app.engine:SelectedContact(banner.id, banner.identity))
    local shown, failure = app:HighlightContact(contact, false, true)
    H.False(shown)
    H.Equal(failure, "locateAfterCombat")
    local combatLockdown, secret = state.api.InCombatLockdown, H.Secret("unreadable combat lockdown")
    state.api.InCombatLockdown = function() return secret end
    H.False(bind("highlight"))
    latestNotice("locateUnavailable")
    H.Equal(ui.badges.highlight, previous)
    state.api.InCombatLockdown = combatLockdown

    state:Unit("nameplate2", { guid = "Player-CombatReplacement", name = "Replacement", class = "HUNTER",
        hostile = true, isPlayer = true })
    H.False(bind("highlight"))
    latestNotice("locateUnavailable")
    H.Equal(ui.badges.highlight, previous)

    state:Unit("nameplate2", unit)
    ui:Select(contact)
    H.True(ui.detailsFrame.locate:IsShown())
    ui.detailsFrame.locate:Click()
    H.True(ui.detailsFrame:IsShown())
    H.True(ui.detailsFrame.identityHelp:IsShown())
    H.Equal(ui.detailsFrame.identityHelp:GetText(), ui:T("locateAfterCombat"))
    H.False(locatorVisible(ui, "nameplate2"))
    H.Equal(#state.blocked, 0)

    state.combat = false
    state:Fire("PLAYER_REGEN_ENABLED")
    state:Advance(0.3)
    H.True(bind("highlight"))
    H.True(locatorVisible(ui, "nameplate2"))
    H.Equal(ui.badges.highlight.id, contact.id)
    H.False(locatorVisible(ui, "nameplate1"))
    H.Equal(#state.blocked, 0)
end)

H.Test("combat highlighting tries an already anchored alias when another verified plate cannot attach", function()
    local state, app, ui = locatorFixture()
    local unit = { guid = "Player-AnchoredAlias", name = "Anchored rogue", class = "ROGUE",
        hostile = true, isPlayer = true }
    app.db:GetProfile().alerts.muteOrdinary = true
    app:OnSettingsChanged()
    state:Unit("nameplate3", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
    local anchored = assert(ui.badges.active.nameplate3)
    state.combat = true
    state:Fire("PLAYER_REGEN_DISABLED")
    state:Unit("nameplate2", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate2", "Cast-WithAnchoredAlias", 1856)
    state:Advance(0.3)
    H.Equal(ui.activeBanner.identity, "guid:" .. unit.guid)
    H.Nil(ui.badges.active.nameplate2)
    local notices = #state.messages
    H.True(state.api.RivalGuard_Binding("highlight"))
    H.True(locatorVisible(ui, "nameplate3"))
    H.Equal(ui.badges.active.nameplate3, anchored)
    H.False(locatorVisible(ui, "nameplate2"))
    H.Equal(#state.messages, notices)
    H.Equal(#state.blocked, 0)
end)

H.Test("nameplate highlight validates the current GUID and never follows a recycled plate", function()
    local state, app, ui, owner = locatorFixture()
    app.db:GetProfile().display.showBadges = true
    app:ProfileChanged()
    local readGUID, secret = state.api.UnitGUID, H.Secret("unreadable locator owner")
    state.api.UnitGUID = function(token)
        if token == "nameplate1" then return secret end
        return readGUID(token)
    end
    ui.detailsFrame.locate:Click()
    H.False(locatorVisible(ui, "nameplate1"))
    state.api.UnitGUID = readGUID

    local replacement = { guid = "Player-LocatorReplacement", name = "Other rival", class = "HUNTER", hostile = true, isPlayer = true }
    state:Unit("nameplate1", replacement)
    ui.detailsFrame.locate:Click()
    H.False(locatorVisible(ui, "nameplate1"))

    state:Unit("nameplate1", owner)
    ui:Refresh()
    ui.detailsFrame.locate:Click()
    H.True(locatorVisible(ui, "nameplate1"))
    state:Unit("nameplate1", replacement)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.False(locatorVisible(ui, "nameplate1"))
    local reused = assert(ui.badges.active.nameplate1)
    H.Equal(reused.locator:GetParent(), reused)
    H.Equal(reused.locator.strata, "DIALOG")
    H.True(reused.icon:IsVisible())
    H.Equal(reused.icon.texture, "Interface\\Icons\\ClassIcon_HUNTER")
    state:Advance(0.5)
    H.False(locatorVisible(ui, "nameplate1"))

    ui.rows[1]:Click()
    ui.detailsFrame.locate:Click()
    H.True(locatorVisible(ui, "nameplate1"))
    state:Unit("nameplate1", owner)
    state:Advance(0.2)
    H.False(locatorVisible(ui, "nameplate1"))
end)

H.Test("nameplate highlight clears on removal and is unavailable in journal and sample details", function()
    local state, app, ui = locatorFixture()
    ui.detailsFrame.locate:Click()
    H.True(locatorVisible(ui, "nameplate1"))
    ui:OpenSettings("journal")
    H.True(ui.journalRows[1]:IsShown())
    ui.journalRows[1]:Click()
    ui:Refresh()
    H.False(ui.detailsFrame.locate:IsShown())

    ui.settings:Hide()
    ui.rows[1]:Click()
    ui.detailsFrame.locate:Click()
    H.True(locatorVisible(ui, "nameplate1"))
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    H.False(locatorVisible(ui, "nameplate1"))
    app:Demo()
    ui.rows[1]:Click()
    H.True(ui.selected.preview)
    H.False(ui.detailsFrame.locate:IsShown())
end)

H.Test("nameplate highlight fails closed when visibility or camera state is restricted", function()
    local state, _, ui = locatorFixture()
    local plate, secret = state.plates.nameplate1, H.Secret("restricted frame evidence")
    local isVisible = plate.IsVisible
    plate.IsVisible = function() return secret end
    ui.detailsFrame.locate:Click()
    H.Nil(ui.badges.highlight)
    H.True(ui.detailsFrame.identityHelp:IsShown())
    H.Equal(ui.detailsFrame.identityHelp:GetText(), ui:T("locateUnavailable"))
    plate.IsVisible = isVisible

    local behind = false
    state.api.C_NamePlateManager = { IsNamePlateUnitBehindCamera = function() return behind end }
    ui.detailsFrame.locate:Click()
    H.True(locatorVisible(ui, "nameplate1"))
    behind = secret
    state:Advance(0.2)
    H.False(locatorVisible(ui, "nameplate1"))
    behind = true
    ui.rows[1]:Click()
    ui.detailsFrame.locate:Click()
    H.False(locatorVisible(ui, "nameplate1"))
end)

H.Test("nameplate highlight leaves a note draft intact", function()
    local _, app, ui = locatorFixture()
    local detail = ui.detailsFrame
    detail.note:SetFocus()
    detail.note:SetText("Unsaved draft")
    detail.note.scripts.OnTextChanged(detail.note, true)
    detail.locate:Click()
    H.True(locatorVisible(ui, "nameplate1"))
    H.True(detail:IsShown())
    H.Equal(detail.note:GetText(), "Unsaved draft")
    H.Nil(app.db:GetList()[ui.selected.identity])
end)

local function recentNoteDraftFixture(raw)
    local state, _, app = setup(raw)
    local unit = { guid = "Player-LocatorOwner", name = "Locator", realm = "FixtureRealm",
        class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(0.5)
    local ui = app.ui
    ui.rows[1]:Click()
    local detail, selected = ui.detailsFrame, ui.selected
    local text = "Private draft after departure"
    detail.note:SetFocus()
    detail.note:SetText(text)
    detail.note.scripts.OnTextChanged(detail.note, true)
    H.Equal(ui.noteDraft.text, text)
    return state, app, ui, detail, selected, text
end

for _, loss in ipairs({ "shard refresh", "shard immediate save", "live retention" }) do
    H.Test("an exact-GUID Nearby note draft can be saved to its Recent record after " .. loss, function()
        local key = "guid:Player-LocatorOwner"
        local alias = "name:Locator-FixtureRealm"
        local lists = loss ~= "shard immediate save" and {
            [key] = { kind = "watch", name = "Locator", class = "ROGUE", note = "Prior exact note" },
            [alias] = { kind = "avoid", name = "Locator-FixtureRealm", class = "ROGUE", note = "Name-based note" },
        } or {}
        local state, app, ui, detail, selected, draft = recentNoteDraftFixture({ schemaVersion = 1, lists = lists })
        H.Equal(detail.listIdentity, key)
        H.Equal(app.db:GetJournal()[1].identity, key)
        state.units.nameplate1 = nil
        if loss == "live retention" then
            state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
            state.clock.Advance(app.db:GetProfile().retention.contactSeconds + 1)
            app.engine:Tick()
        else
            state:Fire("SHARD_TRANSFER")
        end
        H.Equal(#app.engine:Snapshot(), 0)
        H.Nil(app:SetNote(selected, "Direct stale write"))
        local before = app.db:GetList()[key]
        H.Equal(before and before.note, lists[key] and lists[key].note)
        if loss ~= "shard immediate save" then
            ui:Refresh()
            H.True(ui.selectedFromJournal)
            H.True(ui.selected.sources.journal)
            H.Equal(ui.selected.identity, key)
            H.Equal(detail.note:GetText(), draft)
            H.True(detail.note:HasFocus())
            H.Equal(detail.listIdentity, key)
            H.False(detail.locate:IsShown())
            H.False(detail.snooze:IsShown())
        end
        detail.saveNote:Click()
        H.True(ui.selectedFromJournal)
        H.Equal(app.db:GetList()[key].note, draft)
        H.Equal(app.db:GetList()[key].kind, lists[key] and "watch" or "note")
        local unchanged = app.db:GetList()[alias]
        H.Equal(unchanged and unchanged.note, lists[alias] and lists[alias].note)
        H.Equal(detail.note:GetText(), draft)
        H.False(detail.note:HasFocus())
        H.True(detail:IsShown())
    end)
end

for _, unsafe in ipairs({ "missing Recent", "name-bound list", "streamer mode", "cleared Recent" }) do
    H.Test("a departed Nearby note cannot be saved through a " .. unsafe .. " draft fallback", function()
        local aliasKey = "name:Locator-FixtureRealm"
        local raw
        if unsafe == "name-bound list" then
            raw = { schemaVersion = 1, lists = {
                [aliasKey] = { kind = "watch", class = "ROGUE", note = "Original alias note" },
            } }
        end
        local state, app, ui, detail, selected = recentNoteDraftFixture(raw)
        local key = selected.identity
        if unsafe == "name-bound list" then
            H.Equal(ui.noteDraft.identity, aliasKey)
        else
            H.Equal(ui.noteDraft.identity, key)
        end
        H.Equal(app.db:GetJournal()[1].identity, key)
        if unsafe == "missing Recent" then
            H.Equal(app.db:ClearJournal(), 1)
        elseif unsafe == "streamer mode" then
            app.db:GetProfile().display.streamer = true
            app:OnSettingsChanged()
        end
        state.units.nameplate1 = nil
        state:Fire("SHARD_TRANSFER")
        if unsafe == "cleared Recent" then
            ui:Refresh()
            H.True(ui.selectedFromJournal)
            H.True(detail.note:HasFocus())
            H.Equal(app.db:ClearJournal(), 1)
        end
        detail.saveNote:Click()
        ui:Refresh()
        H.Nil(app.db:GetList()[key])
        if unsafe ~= "cleared Recent" then H.False(ui.selectedFromJournal) end
        H.Nil(ui.noteDraft)
        H.False(detail.note:HasFocus())
        H.Equal(detail.note:GetText(), "")
        if unsafe == "name-bound list" then H.Equal(app.db:GetList()[aliasKey].note, "Original alias note") end
    end)
end

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

H.Test("late startup failure leaves no slash aliases or native category until a successful retry", function()
    local state = W.New()
    local raw = { schemaVersion = 1, activeProfile = "Default", profiles = {} }
    state.api.RivalGuardDB = raw
    local RG = state:LoadTOC()
    local registrations, category = {}, { ID = 401 }
    state.api.Settings = {
        RegisterCanvasLayoutCategory = function(panel, title)
            H.True(RG.instance.initialized)
            H.Equal(title, "RivalGuard")
            registrations[#registrations + 1] = panel
            return category
        end,
        RegisterAddOnCategory = function(registered)
            H.Equal(registered, category)
            registrations[#registrations + 1] = registered
        end,
    }
    local create, fail = RG.UI.New, true
    RG.UI.New = function(app)
        local ui = create(app)
        if fail then
            fail = false
            ui.Refresh = function() error("injected final UI refresh failure") end
        end
        return ui
    end
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.False(RG.instance.initialized)
    H.Equal(state.api.RivalGuardDB, raw)
    H.Nil(state.api.SLASH_RIVALGUARD1)
    H.Nil(state.api.SLASH_RIVALGUARD2)
    H.Nil(state.api.SlashCmdList.RIVALGUARD)
    H.Equal(#registrations, 0)

    state:Fire("ADDON_LOADED", "RivalGuard")
    H.True(RG.instance.initialized)
    H.Equal(state.api.SLASH_RIVALGUARD2, "/rg")
    H.Equal(#registrations, 2)
    local panel = registrations[1]
    H.Equal(RG.instance.ui.nativeSettingsPanel, panel)
    panel.open:Click()
    H.True(RG.instance.ui.settings:IsShown())
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.Equal(#registrations, 2)
end)

H.Test("unavailable native Settings registration preserves the custom settings entry", function()
    local state = W.New()
    local RG = state:LoadTOC()
    local attempts = 0
    state.api.Settings = {
        RegisterCanvasLayoutCategory = function()
            attempts = attempts + 1
            error("simulated blocked native registration")
        end,
        RegisterAddOnCategory = function() error("category step must not run") end,
    }
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.True(RG.instance.initialized)
    H.Equal(attempts, 1)
    state.api.SlashCmdList.RIVALGUARD("settings")
    H.True(RG.instance.ui.settings:IsShown())
    state:Fire("ADDON_LOADED", "RivalGuard")
    H.Equal(attempts, 1)
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
    H.Nil(app.db:GetList()[contact.identity])
end)

H.Test("Personal lists avoid copying history and still apply exact name note and kind filters", function()
    local state, RG, app = setup()
    local db, ui = app.db, app.ui
    local alphaA, alphaB = "guid:Player-Order-A", "guid:Player-Order-B"
    local cyrillic, noteOnly = "guid:Player-Cyrillic", "guid:Player-NoteMatch"
    assert(db:SetList(alphaB, "watch", nil, { name = "Alpha", class = "ROGUE" }))
    assert(db:SetList(alphaA, "watch", nil, { name = "alpha", class = "ROGUE" }))
    assert(db:SetList(cyrillic, "watch", nil, { name = "Ёж Север", class = "HUNTER" }))
    assert(db:SetList(noteOnly, "watch", "Local Evac Marker", { name = "Zeta", class = "MAGE" }))
    for index = 5, 1000 do
        assert(db:SetList("guid:Player-List-" .. index, "watch", nil, { name = string.format("Crowd %04d", index) }))
    end
    local epoch = state.api.time()
    for index = 1, 500 do
        assert(db:Record({ identity = "guid:Player-History-" .. index, name = "Encounter " .. index }, epoch - index))
    end
    H.Equal(#db:GetJournal(), 500)
    ui:OpenSettings("journal")
    ui.journalPersonal:Click()
    H.Equal(ui.journalCount:GetText(), ui:F("filteredCount", 1000))
    H.Equal(ui.journalRows[1].contact.identity, alphaA)
    H.Equal(ui.journalRows[2].contact.identity, alphaB)
    H.False(ui.journalClear:IsShown())

    local reads, folds = 0, 0
    local getJournal, searchText = db.GetJournal, RG.UIModel.SearchText
    db.GetJournal = function(database)
        reads = reads + 1
        return getJournal(database)
    end
    RG.UIModel.SearchText = function(value)
        folds = folds + 1
        return searchText(value)
    end
    state.clock.Advance(1.1)
    ui:Refresh()
    local unchangedReads, unchangedFolds = reads, folds
    local function query(text, expected)
        ui.journalSearch:SetText(text)
        H.Equal(ui.journalCount:GetText(), ui:F("filteredCount", #expected))
        for index, identity in ipairs(expected) do H.Equal(ui.journalRows[index].contact.identity, identity) end
        H.Nil(ui.journalRows[#expected + 1].contact)
    end
    query("  ALPHA  ", { alphaA, alphaB })
    query("ЁЖ СЕВЕР", { cyrillic })
    query("eVaC mArKeR", { noteOnly })
    ui.journalRows[1]:Click()
    ui.detailsFrame.note:SetText("New route")
    ui.detailsFrame.saveNote:Click()
    H.True(ui.journalEmpty:IsShown())
    H.Nil(ui.journalRows[1].contact)
    query("new ROUTE", { noteOnly })
    ui.journalFilterChoices.watch:Click()
    ui.journalRows[1]:Click()
    ui.detailsFrame.listActions.avoid:Click()
    H.True(ui.journalEmpty:IsShown())
    H.Nil(ui.journalRows[1].contact)
    ui.journalFilterChoices.avoid:Click()
    H.Equal(ui.journalRows[1].contact.identity, noteOnly)
    H.Equal(ui.journalRows[1].contact.note, "New route")

    H.Equal(unchangedReads, 0, string.format("Personal refresh copied journal %d time(s) and folded %d names", unchangedReads, unchangedFolds))
    H.True(unchangedFolds <= 1000, string.format("Personal refresh folded %d names for 1000 entries", unchangedFolds))
end)

H.Test("direct Personal filters preserve an off-page search and leave the saved list unchanged", function()
    local _, RG, app = setup()
    local db, ui = app.db, app.ui
    for index = 1, 13 do
        assert(db:SetList("guid:Player-FilterWatch" .. index, "watch", "Shared search",
            { name = string.format("Watched rival %02d", index), class = "HUNTER" }))
    end
    for _, kind in ipairs({ "avoid", "ignore", "note" }) do
        assert(db:SetList("guid:Player-Filter-" .. kind, kind, "Shared search " .. kind,
            { name = "Special " .. kind, class = "ROGUE" }))
    end
    assert(db:SetList("guid:Player-NonMatchingFilter", "avoid", "Unrelated text", { name = "Unrelated rival" }))
    local saved = assert(RG.Codec.Encode(db:GetList()))
    ui:OpenSettings("journal")
    local filters = assert(ui.journalFilterChoices, "missing direct Personal filters")
    local kinds = { "all", "watch", "avoid", "ignore", "note" }
    for _, kind in ipairs(kinds) do H.False(filters[kind]:IsVisible()) end
    ui.journalPersonal:Click()
    local function selected(expected)
        H.Equal(ui.journalFilter, expected)
        for _, kind in ipairs(kinds) do
            H.True(filters[kind]:IsVisible())
            H.Equal(filters[kind].enabled, kind ~= expected)
        end
    end
    selected("all")
    local query = "  ShArEd SeArCh  "
    ui.journalSearch:SetText(query)
    H.Equal(ui.journalCount:GetText(), ui:F("filteredCount", 16))
    ui.journalNext:Click()
    H.Equal(ui.journalOffset, 12)

    for _, kind in ipairs({ "note", "ignore", "avoid" }) do
        filters[kind]:Click()
        selected(kind)
        H.Equal(ui.journalOffset, 0)
        H.Equal(ui.journalSearch:GetText(), query)
        H.Equal(ui.journalCount:GetText(), ui:F("filteredCount", 1))
        H.Equal(ui.journalRows[1].contact.identity, "guid:Player-Filter-" .. kind)
        H.Equal(ui.journalRows[1].contact.note, "Shared search " .. kind)
        H.Nil(ui.journalRows[2].contact)
    end
    ui.journalRecent:Click()
    for _, kind in ipairs(kinds) do H.False(filters[kind]:IsVisible()) end
    ui.journalPersonal:Click()
    selected("avoid")
    H.Equal(ui.journalSearch:GetText(), query)
    H.Equal(ui.journalRows[1].contact.listKind, "avoid")
    filters.watch:Click()
    selected("watch")
    H.Equal(ui.journalCount:GetText(), ui:F("filteredCount", 13))
    filters.all:Click()
    selected("all")
    H.Equal(ui.journalCount:GetText(), ui:F("filteredCount", 16))
    H.Equal(RG.Codec.Encode(db:GetList()), saved)
end)

H.Test("a promoted GUID keeps editing the same existing name-based watch record", function()
    local identity = "name:Enemy-FixtureRealm"
    local state, _, app = setup({ schemaVersion = 1, onboardingSeen = true, lists = {
        [identity] = { kind = "watch", name = "Enemy-FixtureRealm", note = "Original note", class = "ROGUE" },
    } })
    local unit = { name = "Enemy", realm = "FixtureRealm", class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local before = app.engine:Snapshot()[1]
    app.ui:Select(before)
    local detail = app.ui.detailsFrame
    H.Equal(detail.note:GetText(), "Original note")

    unit.guid = "Player-Promoted"
    state:Fire("UNIT_NAME_UPDATE", "nameplate1")
    state:Advance(0.5)
    local promoted = app.engine:Snapshot()[1]
    H.Equal(promoted.id, before.id)
    H.Equal(promoted.identity, "guid:Player-Promoted")
    H.Equal(detail.note:GetText(), "Original note")
    detail.note:SetText("Revised note")
    detail.saveNote:Click()
    H.Nil(app.db:GetList()[promoted.identity])
    H.Equal(app.db:GetList()[identity].note, "Revised note")
    H.Equal(app.engine:Snapshot()[1].listKind, "watch")

    detail.removeMembership:Click()
    H.Equal(app.db:GetList()[identity].kind, "note")
    H.Equal(app.db:GetList()[identity].note, "Revised note")
    assert(app:Watch(promoted))
    H.Equal(app.db:GetList()[identity].kind, "watch")
    assert(app:Ignore(promoted))
    H.Equal(app.db:GetList()[identity].kind, "ignore")
    H.Equal(app.db:GetList()[identity].note, "Revised note")
end)

for _, scenario in ipairs({
    { name = "a confirmed Rogue correction expedites its original sighting", before = "MAGE", after = "ROGUE", urgent = true },
    { name = "resolving an unknown class can defer an urgent visual sighting", before = "UNKNOWN_FIXTURE", after = "HUNTER", urgent = false },
}) do
    H.Test(scenario.name, function()
        local state, app, profile = ruleSoundFixture()
        local rule = soundRule("Urgent rogue cue", "quest", 90)
        rule.classes = { ROGUE = true }
        profile.rules = { rule }
        app:OnSettingsChanged()
        local observedAt = state.clock.Now()
        seeSoundRuleRival(state, 1, scenario.before)
        local before = app.engine:Snapshot()[1]
        H.Equal(before.class, scenario.before == "MAGE" and "MAGE" or nil)
        H.Equal(app.engine.counters.alerts, 0)
        state.clock.Advance(0.2)
        state.units.nameplate1.class = scenario.after
        state:Fire("UNIT_NAME_UPDATE", "nameplate1")
        local current = app.engine:Snapshot()[1]
        H.Equal(current.id, before.id)
        H.Equal(current.class, scenario.after)
        H.Equal(app.engine.pending[1].at, observedAt)
        state.clock.Advance(0.05)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, scenario.urgent and 1 or 0)
        H.Equal(#state.sounds, scenario.urgent and 1 or 0)
        if scenario.urgent then H.Equal(state.sounds[1].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE) end

        state.clock.Advance(0.6)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].kind, "sighting")
        H.Equal(app.engine.history[1].reason, scenario.urgent and "custom_rule" or "event_matched")
        H.Equal(app.engine.history[1].id, before.id)
    end)
end

H.Test("readable GUID resolves a pending sighting to Watch without expediting another player", function()
    local state, _, app = setup({ schemaVersion = 1, onboardingSeen = true, lists = {
        ["guid:Player-ResolvedWatch"] = { kind = "watch", name = "Watched-FixtureRealm", class = "ROGUE" },
    } })
    local watched = { name = "Watched", realm = "FixtureRealm", class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", watched)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local first = app.engine:Snapshot()[1]
    H.Equal(first.identity, "name:Watched-FixtureRealm")
    H.Nil(first.listKind)
    seeSoundRuleRival(state, 2, "MAGE")
    local second
    for _, view in ipairs(app.engine:Snapshot()) do if view.identity == "guid:Player-RuleCue2" then second = view end end
    assert(second)

    state.clock.Advance(0.2)
    watched.guid = "Player-ResolvedWatch"
    state:Fire("UNIT_NAME_UPDATE", "nameplate1")
    local current = assert(app.engine:SelectedContact(first.id, first.identity))
    H.Equal(current.identity, "guid:Player-ResolvedWatch")
    H.Equal(current.listKind, "watch")
    state.clock.Advance(0.05)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "watch")
    H.Equal(app.engine.history[1].id, first.id)

    state.clock.Advance(0.6)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 2)
    H.Equal(app.engine.history[2].kind, "sighting")
    H.Equal(app.engine.history[2].id, second.id)
end)

H.Test("merging a queued anonymous plate into a retained GUID keeps its original Watch event", function()
    local identity = "guid:Player-MergedWatch"
    local state, _, app = setup({ schemaVersion = 1, onboardingSeen = true, lists = {
        [identity] = { kind = "watch", name = "Known-FixtureRealm", class = "ROGUE" },
    } }, function(mock) mock.instance = "arena" end)
    local verified = { guid = "Player-MergedWatch", name = "Known", realm = "FixtureRealm",
        class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate2", verified)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    local remembered = app.engine:Snapshot()[1]
    H.Equal(remembered.identity, identity)
    state.units.nameplate2 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
    changeFixtureZone(state)

    local observedAt = state.clock.Now()
    state:Unit("nameplate1", { class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(#app.engine:Snapshot(), 2)
    local queued = app.engine.pending[1]
    H.True(queued.id ~= remembered.id)
    H.Equal(queued.at, observedAt)
    state.clock.Advance(0.2)
    state:Unit("nameplate1", verified)
    state:Fire("UNIT_NAME_UPDATE", "nameplate1")
    H.Equal(#app.engine:Snapshot(), 1)
    H.Equal(#app.engine.pending, 1)
    H.Equal(app.engine.pending[1].at, observedAt)
    H.Equal(app.engine.pending[1].id, remembered.id)
    state.clock.Advance(0.05)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "watch")
    H.Equal(app.engine.history[1].id, remembered.id)
end)

local function queuedNameCollisionFixture(startInArena)
    local state, _, app = setup({ schemaVersion = 1, onboardingSeen = true, lists = {
        ["name:Same-FixtureRealm"] = { kind = "watch", name = "Same-FixtureRealm", class = "ROGUE" },
    } }, function(mock) if startInArena then mock.instance = "arena" end end)
    local function add(index)
        local token, guid = "nameplate" .. index, "Player-Colliding" .. index
        local unit = { guid = guid, name = "Same", realm = "FixtureRealm", class = "ROGUE", hostile = true, isPlayer = true }
        state:Unit(token, unit)
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        for _, contact in ipairs(app.engine:Snapshot()) do if contact.identity == "guid:" .. guid then return contact, unit end end
        error("missing same-name player")
    end
    return state, app, add
end

H.Test("a same-name collision removes Watch urgency without resetting the original wave window", function()
    local state, app, add = queuedNameCollisionFixture()
    local first = add(1)
    H.Equal(first.listKind, "watch")
    state.clock.Advance(0.2)
    local second = add(2)
    H.Nil(second.listKind)
    H.Nil(app.engine:SelectedContact(first.id, first.identity).listKind)
    state.clock.Advance(0.05)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#state.sounds, 0)
    state.clock.Advance(0.6)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 2)
    H.Equal(app.engine.history[1].kind, "sighting"); H.Equal(app.engine.history[1].id, first.id)
    H.Equal(app.engine.history[2].kind, "sighting"); H.Equal(app.engine.history[2].id, second.id)
end)

H.Test("resolving a name collision expedites the remaining owner's queued Watch", function()
    local state, app, add = queuedNameCollisionFixture(true)
    local first, unit = add(1)
    changeFixtureZone(state)
    local second = add(2)
    H.Nil(second.listKind)
    state.clock.Advance(0.2)
    unit.name = "Corrected"
    state:Fire("UNIT_NAME_UPDATE", "nameplate1")
    H.Equal(app.engine:SelectedContact(second.id, second.identity).listKind, "watch")
    state.clock.Advance(0.05)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "watch"); H.Equal(app.engine.history[1].id, second.id)

    state.clock.Advance(0.8)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 2)
    H.Equal(app.engine.history[2].kind, "sighting"); H.Equal(app.engine.history[2].id, first.id)
end)

H.Test("alias merger evaluates queued alerts for the confirmed list membership before coalescing", function()
    local identity = "guid:Player-VerifiedAlias"
    local state, _, app = setup({ schemaVersion = 1, onboardingSeen = true, lists = {
        [identity] = { kind = "watch", name = "Known-FixtureRealm", class = "ROGUE" },
    } })
    local arrival = soundRule("Urgent unlisted arrival", "ready", 95)
    arrival.list = "unlisted"
    local stealth = soundRule("Listed stealth", "warning", 92)
    stealth.event, stealth.list = "stealth", "listed"
    app.db:GetProfile().rules = { arrival, stealth }
    app:OnSettingsChanged()
    local verified = { guid = "Player-VerifiedAlias", name = "Known", realm = "FixtureRealm",
        class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", verified)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local owner = app.engine:Snapshot()[1]
    local castAt = state.clock.Now()
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-BeforeAliasMerge", 1856)
    state.clock.Advance(0.2)
    state:Unit("nameplate2", { class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    H.Equal(#app.engine.pending, 2)
    state.clock.Advance(0.1)
    state:Unit("nameplate2", verified)
    state:Fire("UNIT_NAME_UPDATE", "nameplate2")
    H.Equal(#app.engine:Snapshot(), 1)
    local pendingAt = app.engine.pending[1].at
    state.clock.Advance(0.05)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "stealth")
    H.Equal(app.engine.history[1].id, owner.id)
    H.Equal(pendingAt, castAt)
    H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellVanish")))
    state.clock.Advance(0.8)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
end)

H.Test("a collision invalidates a draft for a name alias without hiding explicit GUID records", function()
    local identity = "name:Same-FixtureRealm"
    local state, _, app = setup({ schemaVersion = 1, onboardingSeen = true, lists = {
        [identity] = { kind = "watch", name = "Same-FixtureRealm", note = "Legacy private note", class = "ROGUE" },
    } })
    local first = { guid = "Player-First", name = "Same", realm = "FixtureRealm", class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", first)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local selected = app.engine:Snapshot()[1]
    app.ui:Select(selected)
    local detail = app.ui.detailsFrame
    H.Equal(detail.note:GetText(), "Legacy private note")
    detail.note:SetFocus()
    detail.note:SetText("Unsaved alias draft")

    state:Unit("nameplate2", { guid = "Player-Second", name = first.name, realm = first.realm, class = first.class, hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    detail.saveNote:Click()
    H.Equal(app.db:GetList()[identity].note, "Legacy private note")
    H.Nil(app.db:GetList()[selected.identity])
    H.Equal(detail.note:GetText(), "")
    H.False(detail.note:HasFocus())
    detail.note:SetText("First GUID only")
    detail.saveNote:Click()
    H.Equal(app.db:GetList()[selected.identity].note, "First GUID only")
    H.Nil(app.db:GetList()["guid:Player-Second"])
    local mismatched = { id = selected.id, identity = "guid:Player-Second", name = first.name }
    H.Nil(app:SetNote(mismatched, "Wrong player"))
    H.Nil(app.db:GetList()[mismatched.identity])
    app.engine:Clear()
    H.Nil(app:SetNote(selected, "Stale observation"))
    H.Equal(app.db:GetList()[selected.identity].note, "First GUID only")

    app.ui:OpenSettings("journal")
    app.ui.journalPersonal:Click()
    for _, row in ipairs(app.ui.journalRows) do
        if row.contact and row.contact.identity == identity then row:Click(); break end
    end
    H.True(app.ui.selected.savedOnly)
    H.Equal(detail.note:GetText(), "Legacy private note")
    detail.note:SetText("Edited explicitly")
    detail.saveNote:Click()
    H.Equal(app.db:GetList()[identity].note, "Edited explicitly")
    H.Equal(app.db:GetList()[selected.identity].note, "First GUID only")
end)

local function recentListAliasFixture(exactEntry, aliasKind)
    local nameKey, guidKey = "name:Enemy-FixtureRealm", "guid:Player-RecentAlias"
    local lists = { [nameKey] = { kind = aliasKind or "watch", name = "Enemy-FixtureRealm", note = "Legacy lookout note", class = "ROGUE" } }
    if exactEntry then lists[guidKey] = { kind = "watch", name = "Enemy-FixtureRealm", note = "Exact entry note", class = "ROGUE" } end
    local state, _, app = setup({ schemaVersion = 1, onboardingSeen = true, lists = lists })
    state:Unit("nameplate1", { guid = "Player-RecentAlias", name = "Enemy", realm = "FixtureRealm",
        class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(app.db:GetJournal()[1].identity, guidKey)
    app.ui:OpenSettings("journal")
    return state, app, nameKey, guidKey
end

local function journalRowFor(ui, identity)
    for _, row in ipairs(ui.journalRows) do
        if row:IsShown() and row.contact and row.contact.identity == identity then return row end
    end
end

H.Test("saving a blank recent note leaves no record and clearing a saved note removes it", function()
    local state, _, app = setup()
    local db, ui = app.db, app.ui
    local identity = "guid:Player-RuleCue1"
    seeSoundRuleRival(state, 1)
    ui:OpenSettings("journal")
    assert(journalRowFor(ui, identity)):Click()
    local detail = ui.detailsFrame
    for _, blank in ipairs({ "", "   " }) do
        detail.note:SetText(blank)
        detail.saveNote:Click()
        H.Nil(db:GetList()[identity])
        H.True(state.messages[#state.messages]:find(ui:T("noteEmpty"), 1, true) ~= nil)
    end
    detail.note:SetText("Stand-alone note")
    detail.saveNote:Click()
    H.Equal(db:GetList()[identity].kind, "note")
    H.Equal(db:GetList()[identity].note, "Stand-alone note")
    ui.journalPersonal:Click()
    assert(journalRowFor(ui, identity)):Click()
    detail.note:SetText("   ")
    detail.saveNote:Click()
    H.Nil(db:GetList()[identity])
    H.Nil(journalRowFor(ui, identity))
    H.True(state.messages[#state.messages]:find(ui:T("noteCleared"), 1, true) ~= nil)
    H.Equal(db:GetJournal()[1].identity, identity)
end)

H.Test("clearing or rejecting a note leaves Watch, Avoid, and Ignore metadata intact", function()
    local state, _, app = setup()
    local db, ui = app.db, app.ui
    for _, kind in ipairs({ "watch", "avoid", "ignore" }) do
        local identity, name = "guid:Player-Clear-" .. kind, "Saved name " .. kind
        assert(db:SetList(identity, kind, "Prior note", { name = name, class = "HUNTER" }))
        ui:OpenSettings("journal")
        ui.journalPersonal:Click()
        assert(journalRowFor(ui, identity)):Click()
        local detail = ui.detailsFrame
        for _, invalid in ipairs({ "\t", "Bad" .. string.char(255), "|HInjected", string.rep("a", 513) }) do
            detail.note:SetText(invalid)
            detail.saveNote:Click()
            H.Equal(db:GetList()[identity].note, "Prior note")
            H.True(state.messages[#state.messages]:find(ui:T("saveFailed"), 1, true) ~= nil)
        end
        detail.note:SetText("")
        detail.saveNote:Click()
        local record = assert(db:GetList()[identity])
        H.Equal(record.kind, kind)
        H.Equal(record.name, name); H.Equal(record.class, "HUNTER")
        H.Nil(record.note)
        H.True(journalRowFor(ui, identity) ~= nil)
        H.True(state.messages[#state.messages]:find(ui:T("noteCleared"), 1, true) ~= nil)
    end
end)

H.Test("legacy empty personal notes disappear on loading SavedVariables", function()
    local state, _, app = setup({ schemaVersion = 1, lists = {
        ["guid:Player-EmptyLegacy"] = { kind = "note", note = "", name = "Empty legacy", class = "ROGUE" },
        ["guid:Player-SpaceLegacy"] = { kind = "note", note = "   ", name = "Spaces legacy", class = "MAGE" },
        ["guid:Player-NoteLegacy"] = { kind = "note", note = "Keep this", name = "Populated legacy", class = "HUNTER" },
        ["guid:Player-WatchLegacy"] = { kind = "watch", name = "Watch without note", class = "HUNTER" },
    } })
    local list, ui = app.db:GetList(), app.ui
    H.Nil(list["guid:Player-EmptyLegacy"]); H.Nil(list["guid:Player-SpaceLegacy"])
    H.Equal(list["guid:Player-NoteLegacy"].note, "Keep this")
    H.Equal(list["guid:Player-WatchLegacy"].kind, "watch")
    ui:OpenSettings("journal")
    ui.journalPersonal:Click()
    H.Nil(journalRowFor(ui, "guid:Player-EmptyLegacy")); H.Nil(journalRowFor(ui, "guid:Player-SpaceLegacy"))
    H.True(journalRowFor(ui, "guid:Player-NoteLegacy") ~= nil)
    state:Fire("PLAYER_LOGOUT")
    local _, _, fresh = setup(state.api.RivalGuardDB)
    H.Equal(state.RG.Util.Count(fresh.db:GetList()), 2)
    H.Equal(fresh.db:GetList()["guid:Player-NoteLegacy"].note, "Keep this")
end)

H.Test("clearing a note from Recent keeps existing membership metadata", function()
    local _, _, app = setup()
    local db, ui = app.db, app.ui
    local identity = "guid:Player-OldNoteMetadata"
    assert(db:SetList(identity, "watch", "Prior note", { name = "Saved name", class = "HUNTER" }))
    assert(db:Record({ identity = identity, name = "Encounter name", class = "ROGUE" }, app.engine.epoch()))
    ui:OpenSettings("journal")
    local row = assert(journalRowFor(ui, identity))
    H.Equal(row.contact.name, "Encounter name")
    H.Equal(row.contact.class, "ROGUE")
    row:Click()
    ui.detailsFrame.note:SetText("")
    ui.detailsFrame.saveNote:Click()
    local saved = db:GetList()[identity]
    H.Equal(saved.kind, "watch"); H.Equal(saved.name, "Saved name"); H.Equal(saved.class, "HUNTER")
    H.Nil(saved.note)
end)

H.Test("Recent uses the verified live list alias for display, editing, and search", function()
    local _, app, nameKey, guidKey = recentListAliasFixture()
    local ui = app.ui
    H.Equal(app.engine:Snapshot()[1].identity, guidKey)
    H.Equal(app.engine:Snapshot()[1].listKind, "watch")
    local row = assert(journalRowFor(ui, guidKey))
    row:Click()
    local detail = ui.detailsFrame
    detail.listActions.avoid:Click()
    local list = app.db:GetList()
    H.Nil(list[guidKey], "reclassifying the Recent card creates a duplicate GUID record")
    H.Equal(list[nameKey].kind, "avoid")
    H.Equal(list[nameKey].note, "Legacy lookout note")
    H.Equal(detail.note:GetText(), "Legacy lookout note")
    H.Equal(app.engine:Snapshot()[1].listKind, "avoid")

    ui.journalSearch:SetText(" lookout NOTE ")
    row = assert(journalRowFor(ui, guidKey), "Recent search missed the effective personal-list note")
    H.Equal(row.contact.listKind, "avoid")
    H.Equal(row.contact.note, "Legacy lookout note")
    ui.rows[1]:Click()
    H.False(ui.selectedFromJournal)
    H.Equal(detail.note:GetText(), "Legacy lookout note")
end)

H.Test("an offline Recent record does not infer a name alias from historical display text", function()
    local state, app, nameKey, guidKey = recentListAliasFixture()
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    local ui = app.ui
    ui.journalRecent:Click()
    assert(journalRowFor(ui, guidKey)):Click()
    local entry, key = app:ResolveList(ui.selected)
    H.Nil(entry); H.Equal(key, guidKey)
    H.Equal(ui.detailsFrame.note:GetText(), "")
    ui.journalSearch:SetText("Legacy lookout note")
    H.Nil(journalRowFor(ui, guidKey))
    H.Equal(app.db:GetList()[nameKey].kind, "watch")
end)

H.Test("Recent prefers an exact GUID record and Personal edits the explicitly selected saved alias", function()
    local _, app, nameKey, guidKey = recentListAliasFixture(true)
    local ui = app.ui
    ui.journalSearch:SetText("Legacy lookout note")
    H.Nil(journalRowFor(ui, guidKey))
    ui.journalSearch:SetText("Exact entry note")
    assert(journalRowFor(ui, guidKey)):Click()
    H.Equal(ui.detailsFrame.note:GetText(), "Exact entry note")
    ui.detailsFrame.listActions.avoid:Click()
    H.Equal(app.db:GetList()[guidKey].kind, "avoid")
    H.Equal(app.db:GetList()[guidKey].note, "Exact entry note")
    H.Equal(app.db:GetList()[nameKey].kind, "watch")

    ui.journalPersonal:Click()
    ui.journalSearch:SetText("Legacy lookout note")
    assert(journalRowFor(ui, nameKey)):Click()
    H.True(ui.selected.savedOnly)
    H.Equal(ui.detailsFrame.note:GetText(), "Legacy lookout note")
    ui.detailsFrame.listActions.ignore:Click()
    H.Equal(app.db:GetList()[nameKey].kind, "ignore")
    H.Equal(app.db:GetList()[nameKey].note, "Legacy lookout note")
    H.Equal(app.db:GetList()[guidKey].kind, "avoid")
end)

H.Test("ambiguous active GUIDs never borrow their shared name note in Recent", function()
    local state, app, nameKey, guidKey = recentListAliasFixture()
    local secondKey = "guid:Player-RecentCollision"
    assert(app.db:Record({ identity = secondKey, name = "Enemy-FixtureRealm", class = "ROGUE" }, state.api.time()))
    state:Unit("nameplate2", { guid = "Player-RecentCollision", name = "Enemy", realm = "FixtureRealm",
        class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    H.Equal(#app.engine:Snapshot(), 2)
    local ui = app.ui
    ui.journalRecent:Click()
    for _, identity in ipairs({ guidKey, secondKey }) do
        assert(journalRowFor(ui, identity)):Click()
        local entry, key = app:ResolveList(ui.selected)
        H.Nil(entry); H.Equal(key, identity)
        H.Equal(ui.detailsFrame.note:GetText(), "")
    end
    ui.journalSearch:SetText("Legacy lookout note")
    H.Nil(journalRowFor(ui, guidKey)); H.Nil(journalRowFor(ui, secondKey))
    H.Equal(app.db:GetList()[nameKey].note, "Legacy lookout note")
end)

H.Test("Recent reclassification uses the effective alias to expedite its queued warning", function()
    local state, app, nameKey, guidKey = recentListAliasFixture(false, "note")
    local ui = app.ui
    H.Equal(app.engine.counters.alerts, 0)
    state.clock.Advance(0.2)
    assert(journalRowFor(ui, guidKey)):Click()
    ui.detailsFrame.listActions.avoid:Click()
    H.Equal(app.db:GetList()[nameKey].kind, "avoid")
    H.Nil(app.db:GetList()[guidKey])
    H.Equal(app.engine.counters.alerts, 0)
    state.clock.Advance(0.05)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "watch")
end)

for _, exactEntry in ipairs({ false, true }) do
    H.Test("saved name-key Ignore respects " .. (exactEntry and "an exact GUID override" or "its effective GUID alias"), function()
        local _, app, nameKey, guidKey = recentListAliasFixture(exactEntry)
        local ui = app.ui
        app.engine:Tick()
        H.Equal(ui.activeBanner.kind, "watch")
        H.Equal(ui.activeBanner.identity, guidKey)
        ui.journalPersonal:Click()
        assert(journalRowFor(ui, nameKey)):Click()
        ui.detailsFrame.listActions.ignore:Click()
        H.Equal(app.db:GetList()[nameKey].kind, "ignore")
        if exactEntry then
            H.Equal(app.db:GetList()[guidKey].kind, "watch")
            H.Equal(ui.activeBanner.identity, guidKey)
            H.True(ui.banner:IsShown())
        else
            H.Nil(app.db:GetList()[guidKey])
            H.Nil(ui.activeBanner)
            H.False(ui.banner:IsShown())
        end
    end)
end

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

local function contactPressureFixture(watched)
    local state, _, app = setup()
    local profile, guid = app.db:GetProfile(), "Player-CapacityOwner"
    profile.retention.maxContacts = 32
    if watched then
        profile.alerts.watchedOnly = true
        assert(app.db:SetList("guid:" .. guid, "watch", nil, { name = "Capacity owner" }))
    else
        profile.retention.journalMode = "threats"
        profile.alerts.muteOrdinary = true
    end
    app:ProfileChanged()
    local unit = { guid = guid, name = "Capacity owner", class = "ROGUE", hostile = true, isPlayer = true }
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(0.5)
    local original, generation = app.engine:Snapshot()[1], app.sensors.active.nameplate1.generation
    for index = 2, 33 do
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-CapacityPeer-" .. index, name = "Peer " .. index, class = "HUNTER", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    H.Equal(#app.engine:Snapshot(), 32)
    H.Equal(app.sensors.active.nameplate1.generation, generation)
    H.Nil(app.engine.contacts[original.id])
    return state, app, unit, original, generation
end

H.Test("contact pressure does not repeat a continuous watch encounter but a genuine return does", function()
    local state, app, unit, original, generation = contactPressureFixture(true)
    local function encounters()
        for _, record in ipairs(app.db:GetJournal()) do
            if record.identity == original.identity then return record.encounters end
        end
    end
    H.Equal(encounters(), 1)
    H.Equal(app.engine.counters.alerts, 1)
    state:Fire("UNIT_FLAGS", "nameplate1")
    state:Advance(0.5)
    H.Equal(app.sensors.active.nameplate1.generation, generation)
    H.Equal(encounters(), 1)
    H.Equal(app.engine.counters.alerts, 1)

    for index = 1, 33 do
        local token = "nameplate" .. index
        state.units[token] = nil
        state:Fire("NAME_PLATE_UNIT_REMOVED", token)
    end
    state.clock.Advance(app.db:GetProfile().alerts.returnAfter + 1)
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(0.5)
    H.True(app.sensors.active.nameplate1.generation ~= generation)
    H.Equal(encounters(), 2)
    H.Equal(app.engine.counters.alerts, 2)
    H.Equal(app.ui.activeBanner.kind, "watch")
end)

H.Test("a newly confirmed threat qualifies a contact even after capacity eviction", function()
    local state, app, _, original, generation = contactPressureFixture(false)
    H.Equal(#app.db:GetJournal(), 0)
    H.Equal(app.engine.counters.alerts, 0)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-AfterPressure", 1856)
    state:Advance(0.5)
    H.Equal(app.sensors.active.nameplate1.generation, generation)
    local journal = app.db:GetJournal()
    H.Equal(#journal, 1)
    H.Equal(journal[1].identity, original.identity)
    H.Equal(journal[1].encounters, 1)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.ui.activeBanner.kind, "stealth")
    H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellVanish")))
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

local function stealthFixture(readable, configure)
    local unit = { guid = "Player-StealthLifecycle", name = "Fixture Rival", class = "ROGUE", hostile = true, isPlayer = true }
    local state, _, app = setup(nil, function(fixture)
        if not readable then return end
        fixture.api.C_Secrets = { ShouldAurasBeSecret = function() return false end }
        fixture.api.C_UnitAuras = { GetAuraDataByIndex = function(token, index)
            if token == "nameplate1" and index == 1 and unit.aura then return { spellId = unit.aura } end
        end }
    end)
    local profile = app.db:GetProfile()
    profile.retention.journalMode = "threats"
    if configure then configure(profile) end
    app:ProfileChanged()
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(#app.db:GetJournal(), 0)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-Lifecycle", 1856)
    return state, app, unit
end

local function queuedSettingsVanish(configure)
    local state, app = stealthFixture(false, function(profile)
        profile.alerts.muteOrdinary = true
        if configure then configure(profile) end
    end)
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#state.sounds, 0)
    H.False(app.ui.banner:IsShown())
    return state, app
end

H.Test("atomic Rogue class selection preserves an already eligible queued Vanish", function()
    local state, app = queuedSettingsVanish()
    local ui = app.ui
    ui:OpenSettings("alerts")
    local rogue
    for _, control in ipairs(ui.controls) do
        for _, chip in ipairs(control.chips or {}) do
            if chip.group == "alerts" and chip.class == "ROGUE" then rogue = chip.frame end
        end
    end
    assert(rogue):Click("RightButton")
    H.Equal(app.engine.counters.alerts, 0)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "stealth")
    H.Equal(ui.banner.title:GetText(), ui:F("stealthCast", ui:T("spellVanish")))
    H.Equal(#state.sounds, 1)
end)

local function addQueuedRival(state, app, index)
    local token, guid = "nameplate" .. index, "Player-QueuedList" .. index
    state:Unit(token, { guid = guid, name = "List rival " .. index, realm = "FixtureRealm",
        class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", token)
    for _, contact in ipairs(app.engine:Snapshot()) do
        if contact.identity == "guid:" .. guid then return contact end
    end
    error("queued list rival not observed")
end

local function battlegroundRule(action)
    return { name = "Battleground sightings", enabled = true, event = "sighting", context = "battleground",
        action = action, priority = 80, classes = {}, sound = false, banner = true, cooldown = 30 }
end

for _, becomesUrgent in ipairs({ false, true }) do
    H.Test("switching an allowed context updates a queued rule that " .. (becomesUrgent and "becomes urgent" or "loses urgency"), function()
        local state, _, app = setup()
        app.db:GetProfile().rules = { battlegroundRule("alert") }
        app:OnSettingsChanged()
        if not becomesUrgent then changeFixtureZone(state, "pvp") end
        local contact = addQueuedRival(state, app, 1)
        state.clock.Advance(0.2)
        changeFixtureZone(state, becomesUrgent and "pvp" or nil)
        H.Nil(app:AlertBlock())
        H.Equal(app.engine.counters.alerts, 0)
        state.clock.Advance(0.05)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, becomesUrgent and 1 or 0)
        H.Equal(#state.sounds, 0)
        state.clock.Advance(0.6)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].reason, becomesUrgent and "custom_rule" or "event_matched")
        H.Equal(app.engine.history[1].id, contact.id)
        H.Equal(#state.sounds, becomesUrgent and 0 or 1)
    end)
end

H.Test("a context-sensitive suppressing rule discards a queued arrival even after leaving that context", function()
    local state, _, app = setup()
    app.db:GetProfile().rules = { battlegroundRule("suppress") }
    app:OnSettingsChanged()
    addQueuedRival(state, app, 1)
    state.clock.Advance(0.2)
    changeFixtureZone(state, "pvp")
    H.Nil(app:AlertBlock())
    changeFixtureZone(state)
    state.clock.Advance(0.65)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#state.sounds, 0)
    H.Nil(app.ui.activeBanner)

    local fresh = addQueuedRival(state, app, 2)
    state.clock.Advance(0.85)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].id, fresh.id)
end)

H.Test("combat events in the same allowed context keep a pending sighting on its original schedule", function()
    local state, _, app = setup()
    local contact = addQueuedRival(state, app, 1)
    state.clock.Advance(0.2)
    state.combat = true
    state:Fire("PLAYER_REGEN_DISABLED")
    H.True(app.engine.context.combat)
    state.clock.Advance(0.05)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 0)
    state.combat = false
    state:Fire("PLAYER_REGEN_ENABLED")
    H.False(app.engine.context.combat)
    state.clock.Advance(0.6)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].id, contact.id)
end)

for _, membership in ipairs({ "watch", "avoid" }) do
    H.Test("adding " .. membership .. " expedites that sighting and leaves another sighting on schedule", function()
        local state, _, app = setup()
        local first = addQueuedRival(state, app, 1)
        local second = addQueuedRival(state, app, 2)
        state.clock.Advance(0.2)
        assert(app:SetList(first, membership))
        H.Equal(app.engine.counters.alerts, 0)
        state.clock.Advance(0.05)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].kind, "watch")
        H.Equal(app.engine.history[1].id, first.id)

        state.clock.Advance(0.6)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 2)
        H.Equal(app.engine.history[2].kind, "sighting")
        H.Equal(app.engine.history[2].id, second.id)
    end)
end

H.Test("removing Watch defers its queued sighting to the original wave deadline", function()
    local state, _, app = setup()
    assert(app.db:SetList("guid:Player-QueuedList1", "watch", "Keep note"))
    local contact = addQueuedRival(state, app, 1)
    state.clock.Advance(0.2)
    app.ui:Select(contact)
    app.ui.detailsFrame.removeMembership:Click()
    local entry = app.db:GetList()[contact.identity]
    H.Equal(entry.kind, "note"); H.Equal(entry.note, "Keep note")
    H.Equal(app.engine.counters.alerts, 0)
    state.clock.Advance(0.05)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#state.sounds, 0)

    state.clock.Advance(0.6)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "sighting")
    H.Equal(app.engine.history[1].id, contact.id)
end)

H.Test("Ignore immediately discards queued Vanish even if removed before the tick", function()
    local state, app = queuedSettingsVanish()
    local contact = app.engine:Snapshot()[1]
    assert(app:Ignore(contact))
    H.Equal(app.db:GetList()[contact.identity].kind, "ignore")
    assert(app:Ignore(contact))
    H.Nil(app.db:GetList()[contact.identity])
    state.clock.Advance(0.25)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#state.sounds, 0)
    H.False(app.ui.banner:IsShown())

    state.clock.Advance(1)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-AfterUnignore", 1856)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "stealth")
end)

H.Test("note edits and edits for an unrelated saved contact keep a queued sighting's deadline", function()
    local state, _, app = setup()
    local contact = addQueuedRival(state, app, 1)
    state.clock.Advance(0.2)
    assert(app:SetNote(contact, "Keep note"))
    assert(app:SetList({ savedOnly = true, identity = "guid:Player-UnrelatedSaved", name = "Unrelated-FixtureRealm", class = "ROGUE" }, "watch"))
    H.Equal(app.db:GetList()[contact.identity].note, "Keep note")
    state.clock.Advance(0.05)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 0)
    state.clock.Advance(0.6)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "sighting")
    H.Equal(app.engine.history[1].id, contact.id)
end)

H.Test("a membership edit does not create an event when no sighting was queued", function()
    local state, _, app = setup()
    app.db:GetProfile().alerts.muteOrdinary = true
    app:OnSettingsChanged()
    local contact = addQueuedRival(state, app, 1)
    assert(app:SetList(contact, "watch"))
    state.clock.Advance(0.85)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 0)
    H.Equal(#state.sounds, 0)
    H.False(app.ui.banner:IsShown())
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-AfterList", 1856)
    app.engine:Tick()
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "stealth")
end)

for _, setting in ipairs({ "sound choice", "mute" }) do
    H.Test("queued Vanish survives a " .. setting .. " change and uses the new output", function()
        local state, app = queuedSettingsVanish(function(profile)
            if setting == "sound choice" then
                profile.alerts.sounds.stealth = "quest"
                profile.alerts.banner = false
            end
        end)
        local ui = app.ui
        local requestedKit = 214748
        if setting == "sound choice" then
            local originalTime = app.engine.pending[1].at
            state.api.SOUNDKIT = { RAID_WARNING = requestedKit }
            state.clock.Advance(0.2)
            ui:OpenSettings("alerts")
            pickSound(ui, settingButton(ui, "alerts.sounds.stealth"), "warning")
            H.Equal(app.db:GetProfile().alerts.sounds.stealth, "warning")
            H.Equal(app.engine.pending[1].at, originalTime)
        else
            state.api.RivalGuard_Binding("mute")
            H.False(app.db:GetProfile().alerts.sound)
        end
        H.Equal(app.engine.counters.alerts, 0)
        H.Equal(#state.sounds, 0)
        state:Advance(0.5)
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].kind, "stealth")
        H.Equal(#state.sounds, setting == "mute" and 0 or 1)
        if setting == "sound choice" then
            H.Equal(state.sounds[1].id, requestedKit)
            H.False(ui.banner:IsShown())
        else
            H.Equal(ui.banner.title:GetText(), ui:F("stealthCast", ui:T("spellVanish")))
        end
        state:Advance(1.5)
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(#state.sounds, setting == "mute" and 0 or 1)
    end)
end

H.Test("a compatible profile switch delivers a queued Vanish after its nameplate leaves", function()
    local state, app = queuedSettingsVanish()
    local ui, db = app.ui, app.db
    local requestedKit = 214749
    state.api.SOUNDKIT = { TELL_MESSAGE = requestedKit }
    local original = db:GetProfile()
    local profile = assert(db:CreateProfile("World alerts"))
    profile.alerts.muteOrdinary, profile.alerts.sounds.stealth, profile.alerts.channel = true, "whisper", "SFX"
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    H.False(app.engine:Snapshot()[1].visible)
    state.clock.Advance(4.4)
    ui:OpenSettings("profiles")
    H.Equal(ui.profileRows[2].profileName, "World alerts")
    ui.profileRows[2].use:Click()
    H.Equal(db:GetActiveProfileName(), "World alerts")
    H.Equal(original.alerts.sounds.stealth, "warning")
    H.Equal(app.engine.counters.alerts, 0)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(ui.activeBanner.kind, "stealth")
    H.Equal(ui.banner.title:GetText(), ui:F("stealthCast", ui:T("spellVanish")))
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, requestedKit); H.Equal(state.sounds[1].channel, "SFX")
end)

for _, blocker in ipairs({ "class settings", "context settings", "profile switch" }) do
    H.Test("a queued Vanish rejected by changed " .. blocker .. " cannot reappear after restoring eligibility", function()
        local state, app = queuedSettingsVanish()
        local profile, db, ui = app.db:GetProfile(), app.db, app.ui
        if blocker == "class settings" then
            profile.alerts.classes = { HUNTER = true }
            app:OnSettingsChanged()
            profile.alerts.classes = {}
            app:OnSettingsChanged()
        elseif blocker == "context settings" then
            profile.context.world = false
            app:OnSettingsChanged()
            profile.context.world = true
            app:OnSettingsChanged()
        else
            assert(db:CreateProfile("Matches", "battleground"))
            ui:OpenSettings("profiles")
            H.Equal(ui.profileRows[2].profileName, "Matches")
            ui.profileRows[2].use:Click()
            H.Equal(db:GetActiveProfileName(), "Matches")
            ui.profileRows[1].use:Click()
            H.Equal(db:GetActiveProfileName(), "Default")
        end
        state:Advance(1.5)
        H.Equal(app.engine.counters.alerts, 0)
        H.Equal(#state.sounds, 0)
        H.False(ui.banner:IsShown())

        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-NewAfterSettings", 1856)
        state:Advance(0.5)
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(#state.sounds, 1)
        H.Equal(ui.activeBanner.kind, "stealth")
    end)
end

H.Test("changing settings does not extend a queued Vanish's original freshness deadline", function()
    local state, app = queuedSettingsVanish()
    state.clock.Advance(4.9)
    state.api.RivalGuard_Binding("mute")
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 0)
    H.False(app.ui.banner:IsShown())
    H.Equal(#state.sounds, 0)
end)

H.Test("a new urgent rule reschedules an already queued ordinary sighting", function()
    local state, _, app = setup()
    state:Unit("nameplate1", { guid = "Player-PriorityChange", name = "Fixture Hunter", class = "HUNTER",
        hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local profile = app.db:GetProfile()
    local observedAt = state.clock.Now()
    profile.rules = {{ name = "Urgent hunters", enabled = true, event = "sighting", action = "alert",
        priority = 80, classes = { HUNTER = true }, sound = false, banner = true, cooldown = 30 }}
    app:OnSettingsChanged()
    H.Equal(app.engine.counters.alerts, 0)
    state:Advance(0.5)
    H.True(state.clock.Now() - observedAt < profile.alerts.waveWindow)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].reason, "custom_rule")
    H.Equal(app.ui.activeBanner.name, "Fixture Hunter")
    H.Equal(#state.sounds, 0)
end)

local function returnStealthFixture(state, app, unit)
    state:Advance(0.5)
    local first = app.db:GetJournal()[1]
    H.Equal(first.encounters, 1)
    H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellVanish")))
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    state.clock.Advance(app.db:GetProfile().alerts.returnAfter + 1)
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    return first
end

local function returnFixtureRival(state, seconds)
    local unit = assert(state.units.nameplate1)
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    state.clock.Advance(seconds)
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
end

H.Test("one combined-arrivals rule alerts for sighting and returning but leaves the Vanish cue alone", function()
    local state, app, profile, soundKits = ruleSoundFixture()
    profile.alerts.banner = false
    profile.alerts.sounds.stealth = "warning"
    app:OnSettingsChanged()
    H.Equal(app:AlertBlock(true), "outputs_disabled")
    H.Equal(app:AlertBlock(true, "returning"), "outputs_disabled")
    local ui = app.ui
    ui:OpenRules()
    local dialog = ui.rulesDialog
    dialog.nameInput:SetText("First and returning rivals", true)
    dialog.event:Click()
    H.Equal(ui.dialogs.ruleDraft.event, "returning")
    dialog.event:Click()
    H.Equal(ui.dialogs.ruleDraft.event, "arrivals")
    dialog.banner:Click()
    pickSound(ui, dialog.soundCue, "quest")
    H.Equal(#profile.rules, 0)
    dialog.save:Click()
    local rule = assert(profile.rules[1])
    H.Equal(rule.event, "sighting")
    H.True(rule.includeReturning)
    H.Equal(rule.soundCue, "quest")
    H.Nil(app:AlertBlock(true))
    H.Nil(app:AlertBlock(true, "returning"))

    local fresh, _, reloaded = setup(state.api.RivalGuardDB, soundKits)
    local persisted = assert(reloaded.db:GetProfile().rules[1])
    H.Equal(persisted.event, "sighting")
    H.True(persisted.includeReturning)
    H.Equal(persisted.soundCue, "quest")
    H.Nil(reloaded:AlertBlock(true))
    H.Nil(reloaded:AlertBlock(true, "returning"))
    seeSoundRuleRival(fresh, 1)
    fresh:Advance(1.25)
    H.Equal(reloaded.engine.history[1].kind, "sighting")
    H.Equal(#fresh.sounds, 1)
    H.Equal(fresh.sounds[1].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)
    returnFixtureRival(fresh, profile.alerts.returnAfter + 1)
    fresh:Advance(1.25)
    H.Equal(reloaded.engine.history[2].kind, "returning")
    H.Equal(#fresh.sounds, 2)
    H.Equal(fresh.sounds[2].id, RULE_SOUND_KITS.IG_QUEST_LIST_COMPLETE)
    fresh:Advance(2)
    fresh:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-OutsideCombinedArrivals", 1856)
    fresh:Advance(0.3)
    H.Equal(reloaded.engine.history[3].kind, "stealth")
    H.Equal(#fresh.sounds, 3)
    H.Equal(fresh.sounds[3].id, RULE_SOUND_KITS.RAID_WARNING)
end)

for _, locale in ipairs({ "enUS", "ruRU" }) do
    H.Test("Alerts reports returning rivals separately from new sightings in " .. locale, function()
        local state, app, profile = ruleSoundFixture()
        local ui, L = app.ui, state.RG.Locale
        local alerts = profile.alerts
        profile.locale, alerts.banner = locale, false
        alerts.sounds.returning = "ready"
        app:OnSettingsChanged()
        ui:OpenSettings("alerts")
        local function status(sighting, returning)
            H.Equal(app:AlertBlock(true), sighting)
            H.Equal(app:AlertBlock(true, "returning"), returning)
            local result = returning and L.Format("returningAlertStatus", locale, L.Reason(returning, locale))
                or L.Get("returningAlertReady", locale)
            H.Equal(ui.returningAlertStatus:GetText(), result)
        end
        status("outputs_disabled", nil)
        seeSoundRuleRival(state, 1)
        state:Advance(1.25)
        H.Equal(#state.sounds, 0)
        returnFixtureRival(state, alerts.returnAfter + 1)
        state:Advance(1.25)
        H.Equal(app.engine.history[1].kind, "returning")
        H.Equal(#state.sounds, 1)
        H.Equal(state.sounds[1].id, RULE_SOUND_KITS.READY_CHECK)

        alerts.sounds.returning, alerts.sounds.sighting = "none", "ping"
        app:OnSettingsChanged()
        status(nil, "outputs_disabled")
        local rule = soundRule("Return cue", "quest", 80)
        rule.event = "returning"
        profile.rules = { rule }
        app:OnSettingsChanged()
        status(nil, nil)

        rule.list = "listed"
        app:OnSettingsChanged()
        status(nil, "outputs_disabled")
        H.Nil(app:AlertBlock())
        rule.list, rule.context = "unlisted", "battleground"
        app:OnSettingsChanged()
        status(nil, "outputs_disabled")
        changeFixtureZone(state, "pvp")
        state:Advance(0.3)
        status(nil, nil)

        settingButton(ui, "alerts.muteOrdinary"):Click()
        status("ordinary_muted", "ordinary_muted")
        settingButton(ui, "alerts.muteOrdinary"):Click()
        settingButton(ui, "alerts.watchedOnly"):Click()
        status("watch_only", "watch_only")
        settingButton(ui, "alerts.watchedOnly"):Click()
        state.api.RivalGuard_Binding("pause")
        status("paused", "paused")
        state.api.RivalGuard_Binding("pause")
        status(nil, nil)
    end)
end

H.Test("a return-only sound plays after a silent first encounter", function()
    local state, app, profile = ruleSoundFixture()
    profile.alerts.banner = false
    profile.alerts.sounds.returning = "ready"
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    state:Advance(1.25)
    H.Equal(#app.engine.history, 0)
    H.Equal(#state.sounds, 0)
    H.Equal(app.db:GetJournal()[1].encounters, 1)

    returnFixtureRival(state, profile.alerts.returnAfter + 1)
    state:Advance(1.25)
    H.Equal(#app.engine.history, 1)
    H.Equal(app.engine.history[1].kind, "returning")
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.READY_CHECK)
    H.False(app.ui.banner:IsShown())
    H.Equal(app.db:GetJournal()[1].encounters, 2)
end)

H.Test("a suppressed return is not retried as a new sighting", function()
    local state, app, profile = ruleSoundFixture()
    profile.alerts.banner = false
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    state:Advance(1.25)
    H.Equal(#state.sounds, 0)
    local rule = soundRule("Suppress returning rivals", nil, 90)
    rule.event, rule.action = "returning", "suppress"
    profile.rules = { rule }
    profile.alerts.sounds.sighting = "ping"
    profile.alerts.sounds.returning = "ready"
    app:OnSettingsChanged()

    returnFixtureRival(state, profile.alerts.returnAfter + 1)
    state:Advance(2)
    H.Equal(#app.engine.history, 0)
    H.Equal(#state.sounds, 0)
    H.Equal(app.db:GetJournal()[1].encounters, 2)
    seeSoundRuleRival(state, 2)
    state:Advance(1.25)
    H.Equal(#app.engine.history, 1)
    H.Equal(app.engine.history[1].kind, "sighting")
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.MAP_PING)
end)

H.Test("a normal long return still alerts and records a second encounter", function()
    local state, _, app = setup()
    local profile = app.db:GetProfile()
    seeSoundRuleRival(state, 1)
    state:Advance(1.25)
    H.Equal(app.engine.history[1].kind, "sighting")
    returnFixtureRival(state, profile.alerts.returnAfter + 1)
    state:Advance(1.25)
    H.Equal(#app.engine.history, 2)
    H.Equal(app.engine.history[2].kind, "returning")
    H.Equal(#state.sounds, 2)
    H.Equal(app.db:GetJournal()[1].encounters, 2)
end)

local function prunedRivalFixture()
    local state, app, profile = ruleSoundFixture()
    profile.alerts.returnAfter = 180
    profile.alerts.sounds.sighting = "ping"
    profile.alerts.sounds.returning = "ready"
    H.Equal(profile.retention.contactSeconds, 120)
    app:OnSettingsChanged()
    seeSoundRuleRival(state, 1)
    state:Advance(1.25)
    H.Equal(app.engine.history[1].kind, "sighting")
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.MAP_PING)
    local token, absentAt = "nameplate1", math.ceil(state.clock.Now())
    local unit = assert(state.units[token])
    state.clock.Advance(absentAt - state.clock.Now())
    state.units[token] = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", token)
    local recent = assert(app.engine:Snapshot()[1])
    H.False(recent.visible)
    H.Equal(recent.lastSeen, absentAt)
    state.clock.Advance(121)
    state:Advance(0.5)
    H.Equal(#app.engine:Snapshot(), 0)
    local journal = app.db:GetJournal()
    H.Equal(#journal, 1)
    H.Equal(journal[1].encounters, 1)
    return state, app, function(absence)
        state.clock.Advance(absentAt + absence - state.clock.Now())
        state:Unit(token, unit)
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        state:Advance(1.25)
        local current = assert(app.engine:Snapshot()[1])
        H.True(current.visible)
        H.Equal(current.identity, recent.identity)
    end
end

for _, absence in ipairs({ 130, 180, 181, 299, 300 }) do
    H.Test("a pruned rival reappearing after " .. absence .. "s respects the encounter threshold and horizon", function()
        local state, app, reappear = prunedRivalFixture()
        reappear(absence)
        if absence < 180 then
            H.Equal(#state.sounds, 1)
            H.Equal(#app.engine.history, 1)
        else
            local nextKind = absence < 300 and "returning" or "sighting"
            H.Equal(#state.sounds, 2)
            H.Equal(#app.engine.history, 2)
            H.Equal(app.engine.history[2].kind, nextKind)
            H.Equal(state.sounds[2].id, nextKind == "returning" and RULE_SOUND_KITS.READY_CHECK or RULE_SOUND_KITS.MAP_PING)
        end
        local journal = app.db:GetJournal()
        H.Equal(#journal, 1)
        H.Equal(journal[1].encounters, absence < 180 and 1 or 2)
        state:Advance(2)
        H.Equal(#state.sounds, absence < 180 and 1 or 2)
    end)
end

for _, reset in ipairs({ "explicit clear", "world load" }) do
    H.Test("a pruned rival starts a fresh encounter after " .. reset, function()
        local state, app, reappear = prunedRivalFixture()
        if reset == "explicit clear" then
            state.api.SlashCmdList.RIVALGUARD("clear")
        else
            state:Fire("PLAYER_LEAVING_WORLD")
            state:Fire("PLAYER_ENTERING_WORLD")
        end
        H.Equal(#app.engine.history, 0)
        H.Equal(app.db:GetJournal()[1].encounters, 1)
        reappear(130)
        H.Equal(#app.engine.history, 1)
        H.Equal(app.engine.history[1].kind, "sighting")
        H.Equal(#state.sounds, 2)
        H.Equal(state.sounds[2].id, RULE_SOUND_KITS.MAP_PING)
        H.Equal(app.db:GetJournal()[1].encounters, 2)
    end)
end

for _, newEncounter in ipairs({ false, true }) do
    H.Test("a previously queued Vanish " .. (newEncounter and "expires at the exact return boundary" or "survives a brief departure"), function()
        local state, _, app = setup()
        app.db:GetProfile().alerts.returnAfter = 5
        app:OnSettingsChanged()
        seeSoundRuleRival(state, 1)
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-PreviousEncounter", 1856)
        H.Equal(app.engine.counters.alerts, 0)
        returnFixtureRival(state, newEncounter and 5 or 4.99)
        local current = app.engine:Snapshot()[1]
        if newEncounter then H.Nil(current.stealth) else H.Equal(current.stealth, "confirmed") end
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, newEncounter and 0 or 1)
        H.Equal(app.db:GetJournal()[1].encounters, newEncounter and 2 or 1)
        if not newEncounter then
            H.Equal(app.engine.history[1].kind, "stealth")
            H.Equal(#state.sounds, 1)
            return
        end

        state.clock.Advance(0.85)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].kind, "returning")
        state.clock.Advance(0.3)
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-NewEncounter", 1856)
        app.engine:Tick()
        H.Equal(app.engine.counters.alerts, 2)
        H.Equal(app.engine.history[2].kind, "stealth")
        H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellVanish")))
        H.Equal(#state.sounds, 2)
        H.Equal(app.db:GetJournal()[1].encounters, 2)
    end)
end

H.Test("a long return with unreadable aura does not inherit an old cast or add a threat", function()
    local state, app, unit = stealthFixture(false)
    local first = returnStealthFixture(state, app, unit)
    local current = app.engine:Snapshot()[1]
    H.True(current.visible)
    H.Nil(current.stealth)
    H.Nil(current.stealthAt)
    H.Nil(current.stealthSpell)
    H.Equal(app.db:GetJournal()[1].lastSeen, first.lastSeen)
    H.Equal(app.db:GetJournal()[1].encounters, 1)
end)

H.Test("a readable stealth aura on long return provides new threat evidence", function()
    local state, app, unit = stealthFixture(true)
    unit.aura = 1784
    local first = returnStealthFixture(state, app, unit)
    local current, journal = app.engine:Snapshot()[1], app.db:GetJournal()
    H.True(current.visible)
    H.Equal(current.stealth, "confirmed")
    H.Equal(current.stealthEvidence, "aura")
    H.Equal(current.stealthAt, state.clock.Now())
    H.Nil(current.stealthSpell)
    H.Equal(journal[1].encounters, 2)
    H.True(journal[1].lastSeen > first.lastSeen)
    state:Advance(0.5)
    H.Equal(app.ui.banner.title:GetText(), app.ui:T("stealthAura"))
end)

H.Test("a queued Vanish banner preserves its spell when the aura is seen and then gone", function()
    local state, app, unit = stealthFixture(true)
    unit.aura = 1784
    state:Fire("UNIT_AURA", "nameplate1")
    unit.aura = nil
    state:Fire("UNIT_AURA", "nameplate1")
    H.Nil(app.engine:Snapshot()[1].stealth)
    H.False(app.ui.banner:IsShown())
    state:Advance(0.5)
    H.Equal(app.ui.activeBanner.kind, "stealth")
    H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellVanish")))
end)

local function fullCapacityWithQueuedVanish()
    local state, _, app = setup()
    local profile = app.db:GetProfile()
    profile.retention.maxContacts = 32
    profile.alerts.classes = { ROGUE = true }
    app:ProfileChanged()
    for index = 1, 32 do
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-Cap-" .. index, name = "Enemy" .. index,
            class = index == 1 and "ROGUE" or "HUNTER", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    state:Advance(3)
    H.Equal(app.engine.contactCount, 32); H.Equal(#app.engine.pending, 0)
    local rogueID = app.engine.bindings.nameplate1.id
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-AtCapacity", 1856)
    state.units.nameplate1 = nil
    state:Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    state:Unit("nameplate1", { guid = "Creature-Cap", name = "Neutral NPC", hostile = false, isPlayer = false })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(app.engine.contactCount, 32); H.Equal(#app.engine.pending, 1)
    H.Equal(app.engine.pending[1].id, rogueID); H.Equal(app.engine.pending[1].stealthSpell, "Vanish")
    return state, app, rogueID
end

local function addFilteredHunterAtCapacity(state)
    state:Unit("nameplate33", { guid = "Player-Cap-New", name = "New Hunter", class = "HUNTER", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate33")
end

H.Test("contact capacity preserves a fresh Vanish from the departing owner of a recycled nameplate", function()
    local state, app, rogueID = fullCapacityWithQueuedVanish()
    local sounds = #state.sounds
    addFilteredHunterAtCapacity(state)
    H.Equal(app.engine.contactCount, 32)
    H.True(app.engine.contacts[rogueID] ~= nil)
    H.True(app.engine.bindings.nameplate33 ~= nil)
    H.Equal(#app.engine.pending, 1); H.Equal(app.engine.pending[1].id, rogueID)
    state:Advance(0.3)
    H.Equal(#state.sounds, sounds + 1)
    local alert = app.engine.history[#app.engine.history]
    H.Equal(alert.kind, "stealth"); H.Equal(alert.id, rogueID)
end)

H.Test("an expired retained Vanish can be evicted ahead of live contacts", function()
    local state, app, rogueID = fullCapacityWithQueuedVanish()
    local liveID = app.engine.bindings.nameplate2.id
    local sounds = #state.sounds
    state.clock.Advance(6)
    addFilteredHunterAtCapacity(state)
    H.Equal(app.engine.contactCount, 32); H.Nil(app.engine.contacts[rogueID])
    H.Equal(app.engine.bindings.nameplate2.id, liveID); H.True(app.engine.bindings.nameplate33 ~= nil)
    H.Equal(#app.engine.pending, 0)
    state:Advance(0.3)
    H.Equal(#state.sounds, sounds)
end)

H.Test("old cast evidence expires from the live row and card while its player remains observed", function()
    local state, app = stealthFixture(false)
    local ui = app.ui
    state:Advance(0.5)
    ui.rows[1]:Click()
    local cast = ui:F("stealthCast", ui:T("spellVanish"))
    H.True(ui.rows[1].detailText:GetText():find(cast, 1, true) ~= nil)
    H.True(ui.detailsFrame.info:GetText():find(cast, 1, true) ~= nil)
    local lastSeen = ui.selected.lastSeen
    state.clock.Advance(7.3)
    app.sensors:Poll()
    ui:Refresh()
    H.True(app.engine:Snapshot()[1].visible)
    H.Equal(app.engine:Snapshot()[1].stealth, "confirmed")
    H.True(ui.selected.lastSeen > lastSeen)

    state.clock.Advance(0.4)
    app.sensors:Poll()
    ui:Refresh()
    local current = app.engine:Snapshot()[1]
    H.True(current.visible)
    H.Nil(current.stealth)
    H.Nil(current.stealthAt)
    H.Nil(current.stealthSpell)
    H.Nil(ui.rows[1].detailText:GetText():find(cast, 1, true))
    H.Nil(ui.detailsFrame.info:GetText():find(cast, 1, true))
    H.Equal(app.engine.counters.alerts, 1)
end)

H.Test("positive aura refreshes stealth recency while only a clean negative rearms the episode", function()
    local state, app, unit = stealthFixture(true, function(profile) profile.alerts.cooldown = 0 end)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    unit.aura = 1784
    state:Fire("UNIT_AURA", "nameplate1")
    local firstAura = app.engine:Snapshot()[1].stealthAt
    state.clock.Advance(6)
    state:Fire("UNIT_AURA", "nameplate1")
    local refreshed = app.engine:Snapshot()[1]
    H.Equal(refreshed.stealthEvidence, "aura")
    H.Equal(refreshed.stealthAt, state.clock.Now())
    H.True(refreshed.stealthAt > firstAura)
    state.clock.Advance(3)
    app.sensors:Poll()
    H.Equal(app.engine:Snapshot()[1].stealth, "confirmed")
    H.Equal(app.engine.counters.alerts, 1)

    unit.aura = H.Secret("restricted active stealth aura")
    state:Fire("UNIT_AURA", "nameplate1")
    H.Equal(app.engine:Snapshot()[1].stealthAt, refreshed.stealthAt)
    state.clock.Advance(5.2)
    app.sensors:Poll()
    H.Nil(app.engine:Snapshot()[1].stealth)
    unit.aura = 1784
    state:Fire("UNIT_AURA", "nameplate1")
    state:Advance(0.5)
    H.Equal(app.engine:Snapshot()[1].stealthEvidence, "aura")
    H.Equal(app.engine.counters.alerts, 1)

    unit.aura = nil
    state:Fire("UNIT_AURA", "nameplate1")
    H.Nil(app.engine:Snapshot()[1].stealth)
    unit.aura = 1784
    state:Fire("UNIT_AURA", "nameplate1")
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 2)
    H.Equal(app.ui.banner.title:GetText(), app.ui:T("stealthAura"))
end)

H.Test("resuming threat history does not record an expired cast as a new threat", function()
    local state, app = stealthFixture(false, function(profile) profile.retention.journalDays = 0 end)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(#app.db:GetJournal(), 0)
    state.clock.Advance(8.1)
    app.db:GetProfile().retention.journalDays = 7
    app:ProfileChanged()
    app.sensors:Poll()
    H.True(app.engine:Snapshot()[1].visible)
    H.Equal(#app.db:GetJournal(), 0)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-NewThreat", 1856)
    H.Equal(#app.db:GetJournal(), 1)
    H.Equal(app.db:GetJournal()[1].identity, "guid:Player-StealthLifecycle")
    H.Equal(app.db:GetJournal()[1].encounters, 1)
end)

local function camouflageFixture(interface)
    local auras = {}
    local state, _, app = setup(nil, function(fixture)
        fixture.api.GetBuildInfo = function() return "Fixture", "Fixture", "", interface end
        fixture.api.C_Secrets = { ShouldAurasBeSecret = function() return false end }
        fixture.api.C_UnitAuras = { GetAuraDataByIndex = function(token, index)
            if index == 1 and auras[token] then return { spellId = auras[token] } end
        end }
    end)
    local profile = app.db:GetProfile()
    profile.alerts.muteOrdinary = true
    profile.locale = "ruRU"
    app:ProfileChanged()
    local function add(token, guid, class)
        state:Unit(token, { guid = guid, name = "Rival", class = class, hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
    end
    return state, app, add, auras
end

H.Test("Retail Camouflage cast and aura share one alert with the localized cast name", function()
    local state, app, add, auras = camouflageFixture(120105)
    add("nameplate1", "Player-HunterCamouflage", "HUNTER")
    H.Nil(app.engine:Snapshot()[1].stealth)
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-Camouflage", 199483)
    local cast = app.engine:Snapshot()[1]
    H.Equal(cast.stealth, "confirmed")
    H.Equal(cast.stealthEvidence, "cast")
    H.Equal(cast.stealthSpell, "Camouflage")
    auras.nameplate1 = 199483
    state:Fire("UNIT_AURA", "nameplate1")
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.engine.history[1].kind, "stealth")
    H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellCamouflage")))
    state:Fire("UNIT_AURA", "nameplate1")
    state:Advance(1)
    H.Equal(app.engine.counters.alerts, 1)
end)

H.Test("Retail Camouflage aura alone confirms stealth without attributing a cast", function()
    local state, app, add, auras = camouflageFixture(120105)
    add("nameplate1", "Player-HunterAura", "HUNTER")
    auras.nameplate1 = 199483
    state:Fire("UNIT_AURA", "nameplate1")
    state:Advance(0.5)
    local contact = app.engine:Snapshot()[1]
    H.Equal(contact.stealth, "confirmed")
    H.Equal(contact.stealthEvidence, "aura")
    H.Nil(contact.stealthSpell)
    H.Equal(app.engine.counters.alerts, 1)
    H.Equal(app.ui.banner.title:GetText(), app.ui:T("stealthAura"))
end)

for _, interface in ipairs({ 120105, 16001 }) do
    H.Test("UNIT_AURA additions confirm readable stealth on interface " .. interface, function()
        local state, app, add = camouflageFixture(interface)
        local secret = H.Secret("restricted aura")
        local indexed, reads = nil, 0
        state.api.C_UnitAuras.GetAuraDataByIndex = function(_, index)
            reads = reads + 1
            if index == 1 then return indexed end
        end
        add("nameplate1", "Player-AuraDelta", "ROGUE")
        local function update(additions)
            state:Fire("UNIT_AURA", "nameplate1", { isFullUpdate = false, addedAuras = additions })
        end
        local stealth = { isHelpful = true, spellId = 1784 }
        indexed, reads = secret, 0
        update({ { isHelpful = false, spellId = 1784 }, { isHelpful = secret, spellId = 1784 },
            { isHelpful = true, spellId = secret } })
        H.Nil(app.engine:Snapshot()[1].stealth)
        H.Equal(reads, 1)
        state:Fire("UNIT_AURA", "nameplate1", { isFullUpdate = true, addedAuras = { stealth } })
        H.Nil(app.engine:Snapshot()[1].stealth)
        H.Equal(reads, 2)
        state:Unit("nameplate2", { guid = "Player-Unobserved", name = "Unobserved", hostile = true, isPlayer = true })
        state:Fire("UNIT_AURA", "nameplate2", { isFullUpdate = false, addedAuras = { stealth } })
        H.Equal(#app.engine:Snapshot(), 1)
        H.Equal(reads, 2)
        update({ secret, stealth })
        H.Equal(app.engine:Snapshot()[1].stealthEvidence, "aura")
        H.Equal(reads, 2, "a positive addition should avoid the indexed scan")
        state:Advance(0.5)
        H.Equal(app.engine.history[1].kind, "stealth")
        update(secret)
        H.Equal(app.engine:Snapshot()[1].stealthEvidence, "aura")
        update({ stealth })
        state:Advance(0.5)
        H.Equal(#app.engine.history, 1)

        indexed = nil
        state:Fire("UNIT_AURA", "nameplate1", { removedAuraInstanceIDs = { 42 } })
        H.Nil(app.engine:Snapshot()[1].stealth)
        state:Advance(31)
        state.api.C_UnitAuras = nil
        update({ stealth })
        state:Advance(0.5)
        H.Equal(#app.engine.history, 2)
        H.Equal(app.engine:Snapshot()[1].stealthEvidence, "aura")
    end)
end

H.Test("a recycled token cannot give its new owner a stale stealth addition", function()
    local state, app, add, auras = camouflageFixture(120105)
    add("nameplate1", "Player-AuraPrevious", "ROGUE")
    state:Unit("nameplate1", { guid = "Player-AuraReplacement", name = "Replacement", class = "ROGUE",
        hostile = true, isPlayer = true })
    state:Fire("UNIT_AURA", "nameplate1", { isFullUpdate = false, addedAuras = { { isHelpful = true, spellId = 1784 } } })
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 0)
    for _, contact in ipairs(app.engine:Snapshot()) do H.Nil(contact.stealth) end

    auras.nameplate1 = 1784
    state:Fire("UNIT_AURA", "nameplate1", { isFullUpdate = true })
    state:Advance(0.5)
    H.Equal(#app.engine.history, 1)
    H.Equal(app.ui.activeBanner.identity, "guid:Player-AuraReplacement")
end)

for _, fixture in ipairs({ { interface = 120105, spell = 199483, class = "HUNTER" },
    { interface = 16001, spell = 1784, class = "ROGUE" } }) do
    H.Test("first plate observation recovers a readable stealth aura on interface " .. fixture.interface, function()
        local state, app, add = camouflageFixture(fixture.interface)
        local secret = H.Secret("restricted aura")
        local mode, calls = "opaque", 0
        local api = state.api.C_UnitAuras
        api.GetAuraDataByIndex = function(_, index)
            if mode == "opaque" and fixture.interface == 16001 then return { spellId = 1126 } end
            if index > 1 or mode == "clear" then return nil end
            return secret
        end
        api.GetUnitAuraBySpellID = function(token, id)
            calls = calls + 1
            if token == "nameplate2" then
                if id == 66 then error("lookup denied") end
                if id == 1784 then return { isHelpful = true, spellId = secret } end
                return secret
            end
            if token == "nameplate3" then return { isHelpful = false, spellId = id } end
            if token == "nameplate4" then return { isHelpful = true, spellId = 8822 } end
            if token == "nameplate1" and id == fixture.spell then return { isHelpful = true, spellId = id } end
        end
        add("nameplate1", "Player-ActiveStealth", fixture.class)
        H.Equal(app.engine:Snapshot()[1].stealthEvidence, "aura")
        H.True(calls > 0 and calls <= 17)
        local afterAcquire = calls
        state:Fire("UNIT_AURA", "nameplate1")
        app.sensors:Poll()
        H.Equal(calls, afterAcquire)
        H.Equal(app.engine:Snapshot()[1].stealthEvidence, "aura")
        for index = 2, 4 do add("nameplate" .. index, "Player-Negative" .. index, "ROGUE") end
        state:Advance(0.5)
        H.Equal(#app.engine.history, 1)
        H.Equal(app.engine.history[1].kind, "stealth")
        H.Equal(app.ui.activeBanner.identity, "guid:Player-ActiveStealth")

        mode = "clear"
        local beforeClear = calls
        state:Fire("UNIT_AURA", "nameplate1")
        add("nameplate5", "Player-CleanScan", "ROGUE")
        H.Equal(calls, beforeClear)
        for _, contact in ipairs(app.engine:Snapshot()) do H.Nil(contact.stealth) end
    end)
end

H.Test("first confirmed hostility can recover an already active stealth aura", function()
    local state, app, add = camouflageFixture(120105)
    local secret = H.Secret("temporarily restricted hostility")
    local hostile, calls = secret, 0
    state.api.UnitIsEnemy = function() return hostile end
    state.api.UnitCanAttack = function() return hostile end
    state.api.C_UnitAuras.GetAuraDataByIndex = function() return secret end
    state.api.C_UnitAuras.GetUnitAuraBySpellID = function(_, id)
        calls = calls + 1
        if id == 1784 then return { isHelpful = true, spellId = id } end
    end
    add("nameplate1", "Player-FirstHostile", "ROGUE")
    H.Equal(calls, 0)
    hostile = true
    state:Fire("UNIT_FLAGS", "nameplate1")
    H.Equal(app.engine:Snapshot()[1].stealthEvidence, "aura")
    state:Advance(0.5)
    H.Equal(#app.engine.history, 1)
    local afterAcquire = calls
    hostile = secret
    state:Fire("UNIT_FLAGS", "nameplate1")
    hostile = true
    state:Fire("UNIT_FLAGS", "nameplate1")
    H.Equal(calls, afterAcquire)
end)

H.Test("Retail Camouflage rejects restricted spell IDs and casts without a proven current owner", function()
    local state, app, add, auras = camouflageFixture(120105)
    add("nameplate1", "Player-CamouflageOld", "HUNTER")
    local secret = H.Secret("unreadable Camouflage spell")
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-Restricted", secret)
    auras.nameplate1 = secret
    state:Fire("UNIT_AURA", "nameplate1")
    state:Advance(0.5)
    H.Nil(app.engine:Snapshot()[1].stealth)
    H.Equal(app.engine.counters.alerts, 0)

    state:Unit("nameplate2", { guid = "Player-CamouflageUntracked", name = "Untracked", class = "HUNTER", hostile = true, isPlayer = true })
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate2", "Cast-NoOwner", 199483)
    auras.nameplate1 = nil
    state:Unit("nameplate1", { guid = "Player-CamouflageReplacement", name = "Replacement", class = "HUNTER", hostile = true, isPlayer = true })
    state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-Recycled", 199483)
    state:Advance(0.5)
    H.Equal(app.engine.counters.alerts, 0)
    for _, contact in ipairs(app.engine:Snapshot()) do H.Nil(contact.stealth) end
end)

for _, client in ipairs({ { interface = 16001, label = "Forever" }, { label = "an unknown client" } }) do
    H.Test("Camouflage stays unavailable on " .. client.label .. " while Vanish still warns", function()
        local state, app, add, auras = camouflageFixture(client.interface)
        add("nameplate1", "Player-UnsupportedCamouflage", "HUNTER")
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "Cast-UnsupportedCamouflage", 199483)
        auras.nameplate1 = 199483
        state:Fire("UNIT_AURA", "nameplate1")
        state:Advance(0.5)
        H.Equal(app.engine.counters.alerts, 0)
        H.Nil(app.engine:Snapshot()[1].stealth)

        add("nameplate2", "Player-CommonVanish", "ROGUE")
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate2", "Cast-CommonVanish", 1856)
        state:Advance(0.5)
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(app.engine.history[1].kind, "stealth")
        H.Equal(app.ui.banner.title:GetText(), app.ui:F("stealthCast", app.ui:T("spellVanish")))
    end)
end

H.Test("journal entries expire online and refresh the open journal without new sightings", function()
    local state, _, app = setup()
    local now = state.api.time()
    app.db:GetProfile().retention.journalDays = 1
    app:ProfileChanged()
    assert(app.db:Record({ identity = "guid:Player-AgingFixture", name = "Old Encounter", class = "HUNTER" }, now - 86400 + 20))
    app.ui:OpenSettings("journal")
    H.True(app.ui.journalRows[1]:IsShown())
    state:Advance(90)
    H.Equal(#app.db:GetJournal(), 0)
    H.False(app.ui.journalRows[1]:IsShown())
    H.Equal(#app.engine:Snapshot(), 0)
end)

H.Test("Recent renders a detached journal page without cloning history and clamps after expiry", function()
    local state, RG, app = setup()
    local db, ui = app.db, app.ui
    app.db:GetProfile().retention.journalDays = 1
    app:ProfileChanged()
    local epoch = state.api.time()
    local function identity(index) return string.format("guid:Player-Recent-%04d", index) end
    local function name(index) return index == 14 and "Ёж Север" or string.format("Patrol %04d", index) end
    for index = 1, 500 do
        local seen = index <= 17 and epoch - index or epoch - 86400 + 10
        assert(db:Record({ identity = identity(index), name = name(index), class = "ROGUE" }, seen))
    end
    assert(db:SetList(identity(14), "watch", "Northern evac", { name = name(14) }))
    H.Equal(#db:GetJournal(), 500)
    ui:OpenSettings("journal")
    H.True(ui.journalRecent:IsShown())
    H.Equal(ui.journalRows[1].contact.identity, identity(1))
    H.Equal(ui.journalRows[12].contact.identity, identity(12))

    local fullCopies, recordCopies, persisted = 0, 0, {}
    for _, record in ipairs(db.root.journal) do persisted[record] = true end
    local getJournal, copy = db.GetJournal, RG.Util.Copy
    db.GetJournal = function(self)
        fullCopies = fullCopies + 1
        return getJournal(self)
    end
    RG.Util.Copy = function(value, seen)
        if persisted[value] then recordCopies = recordCopies + 1 end
        return copy(value, seen)
    end
    local initialLabel = ui.journalRows[1].label:GetText()
    state.clock.Advance(1.2)
    ui:Refresh()
    local measuredFull, measuredRecords = fullCopies, recordCopies
    H.True(ui.journalRows[1].label:GetText() ~= initialLabel)
    H.True(ui.journalRows[1].label:GetText():find(ui:F("lastSeen", ui:F("seconds", 2)), 1, true) ~= nil)
    local first = ui.journalRows[1].contact
    H.False(persisted[first] == true)
    first.name = "Locally changed"
    H.Equal(db.root.journal[1].name, name(1))
    H.Equal(db.root.journal[1].lastSeen, epoch - 1)

    for _ = 1, 41 do ui.journalNext:Click() end
    H.Equal(ui.journalOffset, 492)
    H.Equal(ui.journalRows[8].contact.identity, identity(500))
    H.False(ui.journalNext.enabled)
    state.clock.Advance(61)
    app:Update(61)
    H.Equal(ui.journalCount:GetText(), ui:F("filteredCount", 17))
    H.Equal(ui.journalOffset, 12)
    H.Equal(ui.journalRows[1].contact.identity, identity(13))
    H.Equal(ui.journalRows[5].contact.identity, identity(17))
    H.Nil(ui.journalRows[6].contact)
    H.True(ui.journalPrev.enabled)
    H.False(ui.journalNext.enabled)

    ui.journalSearch:SetText("  NORTHERN Evac  ")
    H.Equal(ui.journalOffset, 0)
    H.Equal(ui.journalCount:GetText(), ui:F("filteredCount", 1))
    H.Equal(ui.journalRows[1].contact.identity, identity(14))
    H.Equal(ui.journalRows[1].contact.note, "Northern evac")
    H.Nil(ui.journalRows[2].contact)
    ui.journalSearch:SetText("ЁЖ СЕВЕР")
    H.Equal(ui.journalRows[1].contact.identity, identity(14))
    ui.journalSearch:SetText("no results")
    H.True(ui.journalEmpty:IsShown())
    H.True(ui.journalClear.enabled)

    H.Equal(measuredFull, 0, string.format("Recent refresh cloned history %d time(s) and copied %d records", measuredFull, measuredRecords))
    H.Equal(measuredRecords, 12)
end)

for _, mode in ipairs({ "recent", "personal" }) do
    H.Test("journal navigation follows the visible " .. mode .. " results and resets scroll between pages", function()
        local state, _, app = setup()
        local db, ui = app.db, app.ui
        local retention = db:GetProfile().retention.journalDays
        local function identity(index) return "guid:Player-JournalNav" .. index end
        for index = 1, 14 do
            local name = string.format("Journal rival %02d", index)
            local note = index == 14 and "Unique last page note" or nil
            assert(db:Record({ identity = identity(index), name = name, class = "ROGUE" }, state.api.time() - index))
            assert(db:SetList(identity(index), "watch", note, { name = name, class = "ROGUE" }))
        end

        ui.scroll:SetHeight(260)
        ui:OpenSettings("journal")
        if mode == "personal" then ui.journalPersonal:Click() end
        H.Equal(ui.journalMode, mode)
        H.True(ui.journalPrev:IsShown()); H.True(ui.journalNext:IsShown())
        H.False(ui.journalPrev.enabled); H.True(ui.journalNext.enabled)
        H.Equal(ui.journalRows[1].contact.identity, identity(1))
        H.Equal(ui.journalRows[12].contact.identity, identity(12))
        local fullHeight = ui.pageHeight
        local _, max = ui.scrollbar:GetMinMaxValues()
        H.True(max > 0)
        ui.scrollbar:SetValue(max)
        H.True(ui.scroll:GetVerticalScroll() > 0)
        ui.journalNext:Click()
        H.Equal(ui.scroll:GetVerticalScroll(), 0)
        H.Equal(ui.journalRetention:IsShown(), mode == "recent")
        H.Equal(ui.journalRows[1].contact.identity, identity(13))
        H.Equal(ui.journalRows[2].contact.identity, identity(14))
        H.Nil(ui.journalRows[3].contact)
        H.True(ui.journalPrev.enabled); H.False(ui.journalNext.enabled)
        H.True(ui.journalPrev:IsShown()); H.True(ui.journalNext:IsShown())
        local lastHeight = ui.pageHeight
        H.True(lastHeight < fullHeight)

        local row = ui.journalRows[2]
        local _, parent, anchor, _, y = ui.journalPrev:GetPoint(1)
        local _, _, _, _, rowY = row:GetPoint(1)
        local gap = parent == row and anchor == "BOTTOMLEFT" and -y or rowY - row:GetHeight() - y
        H.True(gap >= 0 and gap <= 24, "pager should be next to the last visible row")
        _, max = ui.scrollbar:GetMinMaxValues()
        local pagerBottom = -rowY + row:GetHeight() + gap + ui.journalPrev:GetHeight()
        H.True(pagerBottom <= max + ui.scroll:GetHeight(), "pager should be reachable on the final page")
        ui.scrollbar:SetValue(max)
        ui.journalPrev:Click()
        H.Equal(ui.scroll:GetVerticalScroll(), 0)
        H.Equal(ui.journalRows[1].contact.identity, identity(1))
        H.Equal(ui.pageHeight, fullHeight)

        ui.journalNext:Click()
        ui.journalSearch:SetText("last page note")
        H.Equal(ui.journalOffset, 0)
        H.Equal(ui.journalRows[1].contact.identity, identity(14))
        H.Nil(ui.journalRows[2].contact)
        H.False(ui.journalPrev:IsShown()); H.False(ui.journalNext:IsShown())
        H.True(ui.pageHeight < lastHeight)
        H.Equal(ui.journalRetention:IsShown(), mode == "recent")
        if mode == "personal" then
            ui.journalRows[1]:Click()
            H.Equal(ui.detailsFrame.note:GetText(), "Unique last page note")
            ui.detailsFrame.note:SetText("Updated note")
            ui.detailsFrame.saveNote:Click()
            H.Equal(db:GetList()[identity(14)].note, "Updated note")
            ui.journalSearch:SetText("updated note")
            H.Equal(ui.journalRows[1].contact.identity, identity(14))
        end
        ui.journalSearch:SetText("no matching figure")
        H.True(ui.journalEmpty:IsShown())
        H.False(ui.journalPrev:IsShown()); H.False(ui.journalNext:IsShown())
        H.Equal(db:GetProfile().retention.journalDays, retention)
    end)
end

H.Test("loss of epoch clock never rewrites an earlier saved encounter with a fake timestamp", function()
    local state, _, app = setup()
    local clock, identity = state.api.time, "guid:Player-ClockFixture"
    local observedAt = clock() - 50
    assert(app.db:Record({ identity = identity, name = "Saved Known Name", class = "ROGUE" }, observedAt, "Known zone"))
    state.api.time = function() error("simulated unavailable epoch clock") end
    state:Unit("nameplate1", { guid = "Player-ClockFixture", name = "Current Name", class = "ROGUE", hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    state:Advance(1.5)
    H.Equal(#app.engine:Snapshot(), 1)
    local before = app.db:GetJournal()
    H.Equal(#before, 1)
    H.Equal(before[1].lastSeen, observedAt)
    H.Equal(before[1].name, "Saved Known Name")
    H.Equal(before[1].encounters, 1)
    app.ui:OpenSettings("journal")
    H.True(app.ui.journalRows[1]:IsShown())
    H.Nil(app.ui.journalRows[1].contact.lastSeen)
    H.True(app.ui.journalRows[1].label:GetText():find(app.ui:T("lastSeenUnknown"), 1, true) ~= nil)

    state.api.time = clock
    state:Advance(2)
    local recovered = app.db:GetJournal()
    H.Equal(#recovered, 1)
    H.Equal(recovered[1].identity, identity)
    H.True(recovered[1].lastSeen > 0)
end)

H.Test("switching to zero journal days suspends recording and preserves the previous expiry through reload", function()
    local state, _, app = setup()
    local now = state.api.time()
    app.db:GetProfile().retention.journalDays = 14
    assert(app.db:Record({ identity = "guid:Player-Existing", name = "Existing" }, now - 10 * 86400))
    local quiet = assert(app.db:CreateProfile("No recording"))
    quiet.retention.journalDays = 0
    assert(app.db:SetProfile("No recording"))
    app:ProfileChanged()
    H.Equal(#app.db:GetJournal(), 1)
    local recorded = app.db:Record({ identity = "guid:Player-New", name = "New" }, now)
    H.False(recorded)

    state:Fire("PLAYER_LOGOUT")
    local _, _, reloaded = setup(state.api.RivalGuardDB)
    H.Equal(reloaded.db:GetActiveProfileName(), "No recording")
    H.Equal(#reloaded.db:GetJournal(), 1)
    H.Equal(reloaded.db:GetJournal()[1].identity, "guid:Player-Existing")
    H.Equal(reloaded.db:Prune(now + 5 * 86400), 1)
    H.Equal(#reloaded.db:GetJournal(), 0)
end)

H.Test("status uses clean C_CVar evidence and falls back only when the reader is absent", function()
    local state, _, app = setup()
    local legacyReads, modernReads = {}, {}
    state.api.GetCVarBool = function(name) legacyReads[#legacyReads + 1] = name; return true end
    state.api.C_CVar = { GetCVarBool = function(name) modernReads[#modernReads + 1] = name; return false end }
    local status = app:Status()
    H.False(status.nameplates); H.False(status.alwaysNameplates); H.Equal(status.state, "limited"); H.Equal(#legacyReads, 0)
    H.Equal(table.concat(modernReads, ","), "nameplateShowEnemies,nameplateShowAll")
    state.api.C_CVar.GetCVarBool = function() return H.Secret("restricted CVar") end
    status = app:Status()
    H.Nil(status.nameplates); H.Nil(status.alwaysNameplates); H.Equal(#legacyReads, 0)
    state.api.C_CVar.GetCVarBool = function() error("blocked CVar") end
    status = app:Status()
    H.Nil(status.nameplates); H.Nil(status.alwaysNameplates); H.Equal(#legacyReads, 0)
    state.api.C_CVar.GetCVarBool = nil
    status = app:Status()
    H.True(status.nameplates); H.True(status.alwaysNameplates)
    H.Equal(table.concat(legacyReads, ","), "nameplateShowEnemies,nameplateShowAll")
end)
