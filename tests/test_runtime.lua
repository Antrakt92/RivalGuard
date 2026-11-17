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
    bind("nearby"); bind("pause"); bind("mute")
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

H.Test("advanced rule cue preview is detached and saving makes the cue survive reload", function()
    local state, app, profile, soundKits = ruleSoundFixture()
    profile.alerts.sound, profile.alerts.banner = false, false
    app:OnSettingsChanged()
    local ui = app.ui
    ui:OpenRules()
    local dialog = ui.rulesDialog
    H.False(dialog.previewCue.enabled)
    dialog.soundCue:Click()
    dialog.soundCue:Click()
    H.True(dialog.previewCue.enabled)
    dialog.previewCue:Click()
    H.Equal(#state.sounds, 1)
    H.Equal(state.sounds[1].id, RULE_SOUND_KITS.RAID_WARNING)
    H.Equal(state.sounds[1].channel, "Dialog")
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
    H.True(snapshotCalls > 0)
    H.True(rowCalls > previewRowCalls)
    H.Equal(ui.rows[1].contact.identity, "guid:Player-Count-1")
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

H.Test("Why leaves per-contact sound outcome absent on waves previews and saved journal selections", function()
    local state, _, app = setup()
    local ui = app.ui
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
    for _, view in ipairs(app.engine:Snapshot()) do H.Nil(app:Explain(view).lastSound) end
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

for _, locale in ipairs({ "enUS", "ruRU" }) do
    H.Test("Alerts explains ordinary sighting eligibility for the selected profile in " .. locale, function()
        local state, RG, app = setup(nil, function(mock) mock.locale = locale end)
        local db, ui = app.db, app.ui
        local function clickSetting(path)
            for _, control in ipairs(ui.controls) do
                if control.path == path then control.frame:Click(); return end
            end
            error("missing settings control " .. path)
        end
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
        for _ = 1, 3 do ui.presetButton:Click() end
        ui.profileInput:SetText("Matches")
        ui.profileInput.scripts.OnEnterPressed(ui.profileInput)
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
        for _ = 1, 5 do clickSetting("alerts.sounds.sighting") end
        H.Equal(matchProfile.alerts.sounds.sighting, "none")
        status("Matches", nil)
        for _ = 1, 3 do clickSetting("alerts.sounds.wave") end
        H.Equal(matchProfile.alerts.sounds.wave, "none")
        status("Matches", "outputs_disabled")
        H.Nil(app:AlertBlock(), "other event sounds are still eligible")
        clickSetting("alerts.sounds.sighting")
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
    H.Equal(detail.title:GetText(), ui:T("unknownPlayer"))
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
    H.Nil(app.db:GetList()[contact.identity].note)
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
    ui.journalFilterButton:Click()
    ui.journalRows[1]:Click()
    ui.detailsFrame.listActions.avoid:Click()
    H.True(ui.journalEmpty:IsShown())
    H.Nil(ui.journalRows[1].contact)
    ui.journalFilterButton:Click()
    H.Equal(ui.journalRows[1].contact.identity, noteOnly)
    H.Equal(ui.journalRows[1].contact.note, "New route")

    H.Equal(unchangedReads, 0, string.format("Personal refresh copied journal %d time(s) and folded %d names", unchangedReads, unchangedFolds))
    H.True(unchangedFolds <= 1000, string.format("Personal refresh folded %d names for 1000 entries", unchangedFolds))
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

local function queuedSettingsVanish()
    local state, app = stealthFixture(false, function(profile) profile.alerts.muteOrdinary = true end)
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
        local state, app = queuedSettingsVanish()
        local ui = app.ui
        local requestedKit = 214748
        if setting == "sound choice" then
            state.api.SOUNDKIT = { READY_CHECK = requestedKit }
            ui:OpenSettings("alerts")
            local choice
            for _, control in ipairs(ui.controls) do
                if control.path == "alerts.sounds.stealth" then choice = control.frame break end
            end
            assert(choice):Click()
            H.Equal(app.db:GetProfile().alerts.sounds.stealth, "ready")
        else
            state.api.RivalGuard_Binding("mute")
            H.False(app.db:GetProfile().alerts.sound)
        end
        H.Equal(app.engine.counters.alerts, 0)
        H.Equal(#state.sounds, 0)
        state:Advance(0.5)
        H.Equal(app.engine.counters.alerts, 1)
        H.Equal(ui.banner.title:GetText(), ui:F("stealthCast", ui:T("spellVanish")))
        H.Equal(#state.sounds, setting == "mute" and 0 or 1)
        if setting == "sound choice" then H.Equal(state.sounds[1].id, requestedKit) end
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
