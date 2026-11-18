local H = RGTest

local function fixture(profile, lists)
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua" })
    local clock, alerts, encounters = H.Clock(), {}, {}
    local engine = RG.Engine.New({
        profile = profile or RG.Defaults.NewProfile(), lists = lists,
        clock = clock.Now, epoch = clock.Now,
        onAlert = function(decision) alerts[#alerts + 1] = decision end,
        onEncounter = function(contact) encounters[#encounters + 1] = contact end,
    })
    local function observe(token, fields)
        local obs = { token = token, source = "test", hostile = true, isPlayer = true }
        for key, value in pairs(fields or {}) do obs[key] = value end
        return engine:Observe(obs)
    end
    return engine, observe, clock, alerts, encounters, RG
end

local function selectLikeSnapshot(engine, id, identity)
    local expected
    for _, view in ipairs(engine:Snapshot()) do
        if view.id == id or (identity and view.identity == identity) then
            expected = view
            break
        end
    end
    local selected = engine:SelectedContact(id, identity)
    H.Equal(selected and selected.id, expected and expected.id)
    return selected
end

H.Test("a returning rival can qualify on a later range sample without a second sighting", function()
    local engine, observe, clock, alerts, encounters = fixture()
    engine.profile.range = { enabled = true, unknown = false, yards = 20, policy = "confirmed" }
    local token = "nameplate1"
    local function at(distance)
        observe(token, { guid = "Player-RangeReturn", name = "Rival", class = "ROGUE",
            rangeMin = distance, rangeMax = distance, rangeEvidence = "exact" })
    end
    at(10)
    clock.Advance(1); engine:Tick()
    H.Equal(alerts[1].kind, "sighting")
    engine:Remove(token)
    clock.Advance(engine.profile.alerts.returnAfter + 1)
    at(40)
    clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 1)
    at(10)
    H.Equal(engine.pending[1].event, "returning")
    at(40)
    clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(#engine.pending, 0)
    at(10); at(10)
    H.Equal(#engine.pending, 1)
    H.Equal(engine.pending[1].event, "returning")
    clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 2); H.Equal(alerts[2].kind, "returning")
    clock.Advance(engine.profile.alerts.cooldown + 1)
    at(10)
    clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 2)
    H.Equal(#encounters, 2)
end)

H.Test("ordinary arrival classification survives eviction during a blocked return", function()
    local engine, observe, clock, alerts = fixture()
    engine.profile.retention.maxContacts = 1
    engine.profile.range = { enabled = true, unknown = false, yards = 20, policy = "confirmed" }
    local token = "nameplate1"
    local function at(distance)
        return observe(token, { guid = "Player-RangeReturn", name = "Rival", class = "ROGUE",
            rangeMin = distance, rangeMax = distance, rangeEvidence = "exact" })
    end
    at(10)
    clock.Advance(1); engine:Tick(); engine:Remove(token)
    clock.Advance(engine.profile.alerts.returnAfter + 1)
    local blocked = at(40)
    observe("nameplate2", { guid = "Player-Other", name = "Other", class = "ROGUE" })
    H.Nil(engine.contacts[blocked.id])
    local reacquired = at(10)
    H.True(reacquired.id ~= blocked.id)
    H.Equal(#engine.pending, 1)
    H.Equal(engine.pending[1].event, "returning")
    clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 2); H.Equal(alerts[2].kind, "returning")
end)

H.Test("only a complete verified name can replace contradictory life state without a GUID", function()
    local engine, observe = fixture()
    local initial = observe("nameplate1", { name = "Enemy", realm = "Realm", class = "ROGUE", dead = true })
    local focus = observe("focus", { name = "Enemy", realm = "Realm", class = "ROGUE", dead = true })
    H.Equal(focus.id, initial.id)
    local unverified = observe("focus", { name = "Enemy", nameComplete = false, class = "ROGUE", dead = false })
    H.True(unverified.dead)
    local verified = observe("focus", { name = "Enemy", realm = "Realm", class = "ROGUE", dead = false })
    H.False(verified.dead)
    engine:Remove("focus")
    H.Nil(engine:Snapshot()[1].dead)
    local refreshed = observe("nameplate1", { name = "Enemy", realm = "Realm", class = "ROGUE", dead = false })
    H.False(refreshed.dead)
end)

H.Test("selected contact follows identity promotion and reattachment by canonical identity", function()
    local engine, observe, clock = fixture()
    local anonymous = observe("target", { class = "ROGUE" })
    H.Nil(anonymous.identity)
    local known = observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
    H.Equal(known.id, anonymous.id)
    H.Equal(selectLikeSnapshot(engine, anonymous.id).identity, known.identity)

    engine:Drop(known.id)
    local returned = observe("nameplate1", {
        guid = "Player-A", name = "Alpha", class = "ROGUE", rangeMin = 12, rangeMax = 12, rangeEvidence = "exact",
    })
    H.True(returned.id ~= known.id)
    H.Nil(selectLikeSnapshot(engine, known.id))
    local selected = selectLikeSnapshot(engine, known.id, known.identity)
    H.Equal(selected.id, returned.id)
    H.Equal(selected.rangeMax, 12)
    selected.sources.test = nil
    clock.Advance(3)
    local refreshed = selectLikeSnapshot(engine, known.id, known.identity)
    H.True(refreshed.sources.test)
    H.Nil(refreshed.rangeMax)
    H.Equal(refreshed.rangeEvidence, "unknown")
end)

H.Test("selected contact excludes a former canonical name after it becomes an alias", function()
    local engine, observe = fixture()
    local known = observe("nameplate1", { guid = "Player-A", class = "ROGUE" })
    local nameOnly = observe("target", { name = "Alpha", realm = "Realm", class = "ROGUE" })
    H.True(nameOnly.id ~= known.id)
    H.Equal(selectLikeSnapshot(engine, nil, nameOnly.identity).id, nameOnly.id)

    local merged = observe("target", { guid = "Player-A", name = "Alpha", realm = "Realm", class = "ROGUE" })
    H.Equal(merged.id, known.id)
    H.Equal(engine.identities[nameOnly.identity], known.id)
    H.Nil(selectLikeSnapshot(engine, nameOnly.id, nameOnly.identity))
    H.Equal(selectLikeSnapshot(engine, nameOnly.id, known.identity).id, known.id)
end)

H.Test("selected contact preserves snapshot filter and competing match order", function()
    local engine, observe = fixture()
    local rogue = observe("nameplate1", { guid = "Player-A", class = "ROGUE" })
    local hunter = observe("nameplate2", { guid = "Player-B", class = "HUNTER" })
    H.True(rogue.id < hunter.id)
    H.Equal(rogue.lastSeen, hunter.lastSeen)
    H.Equal(selectLikeSnapshot(engine, hunter.id, rogue.identity).id, rogue.id)
    engine.lists[hunter.identity] = { kind = "watch" }
    H.Equal(selectLikeSnapshot(engine, hunter.id, rogue.identity).id, hunter.id)

    engine.profile.display.classes = { ROGUE = true }
    H.Nil(selectLikeSnapshot(engine, hunter.id, hunter.identity))
    H.Equal(selectLikeSnapshot(engine, hunter.id, rogue.identity).id, rogue.id)
    engine.lists[rogue.identity] = { kind = "ignore" }
    H.Nil(selectLikeSnapshot(engine, hunter.id, rogue.identity))
end)

H.Test("merging an anonymous contact retains its already known class and level", function()
    local engine, observe = fixture()
    observe("target", { class = "ROGUE", level = 60 })
    observe("nameplate1", { guid = "Player-A", name = "Alpha" })
    local contact = observe("target", { guid = "Player-A", name = "Alpha" })
    H.Equal(#engine:Snapshot(), 1)
    H.Equal(contact.class, "ROGUE"); H.Equal(contact.level, 60)
end)

H.Test("late identity records one encounter after an anonymous visual warning", function()
    local _, observe, clock, _, encounters = fixture()
    observe("target", { class = "ROGUE" })
    clock.Advance(1)
    observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
    H.Equal(#encounters, 1)
    observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
    H.Equal(#encounters, 1)
end)

H.Test("profile changes do not discard a queued first sighting permanently", function()
    local engine, observe, clock, alerts, _, RG = fixture()
    observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
    engine:SetProfile(RG.Defaults.NewProfile())
    observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
    clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 1); H.Equal(alerts[1].kind, "sighting")
end)

H.Test("a smaller profile keeps the strongest pending alerts in observation order", function()
    local engine, observe, clock, _, _, RG = fixture()
    for index = 1, 20 do
        observe("nameplate" .. index, { guid = "Player-QueueProfile-" .. index, class = "ROGUE" })
    end
    clock.Advance(engine.profile.alerts.waveWindow + 0.1)
    for index = 1, 20 do H.True(engine:Cast("nameplate" .. index, 1856)) end
    H.Equal(#engine.pending, 40)

    local replacement = RG.Defaults.NewProfile()
    replacement.retention.maxContacts = 32
    engine:SetProfile(replacement)
    H.Equal(#engine.pending, 32)
    for index, item in ipairs(engine.pending) do
        local sighting = index <= 12
        H.Equal(item.sequence, sighting and index or index + 8)
        H.Equal(item.event, sighting and "sighting" or "stealth")
        if sighting then H.True(engine.contacts[item.id].arrivalQueued) end
    end
    for index = 13, 20 do
        H.False(engine.contacts[engine.bindings["nameplate" .. index].id].arrivalQueued)
    end
end)

H.Test("class resolution can sound once after an unidentified visual first sighting", function()
    local engine, observe, clock, alerts = fixture()
    engine.profile.alerts.classes = { ROGUE = true }
    observe("target", { guid = "Player-A", name = "Alpha" })
    clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 1); H.False(alerts[1].sound)
    observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
    clock.Advance(1); engine:Tick()
    local sounds = 0
    for _, alert in ipairs(alerts) do if alert.sound then sounds = sounds + 1 end end
    H.Equal(sounds, 1)
    observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
    clock.Advance(1); engine:Tick()
    sounds = 0
    for _, alert in ipairs(alerts) do if alert.sound then sounds = sounds + 1 end end
    H.Equal(sounds, 1)
end)

H.Test("resolving an unselected class never adds a class-match sound", function()
    local engine, observe, clock, alerts = fixture()
    engine.profile.alerts.classes = { ROGUE = true }
    observe("target", { guid = "Player-A", name = "Alpha" })
    clock.Advance(1); engine:Tick()
    observe("target", { guid = "Player-A", name = "Alpha", class = "MAGE" })
    clock.Advance(1); engine:Tick()
    local sounds = 0
    for _, alert in ipairs(alerts) do if alert.sound then sounds = sounds + 1 end end
    H.Equal(sounds, 0)
end)

H.Test("confirmed stealth supersedes the redundant generic arrival in one burst", function()
    local engine, observe, clock, alerts = fixture()
    observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE", stealth = true, stealthReadable = true })
    engine:Tick(); clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 1); H.Equal(alerts[1].kind, "stealth")
end)

H.Test("targeting warning supersedes the redundant generic arrival in one burst", function()
    local engine, observe, clock, alerts = fixture()
    observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE", targeting = true })
    engine:Tick(); clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 1); H.Equal(alerts[1].kind, "targeting")
end)

H.Test("sound-only targeting retries after a different contact's sound gap", function()
    local engine, observe, clock, alerts = fixture()
    engine.profile.alerts.banner, engine.profile.alerts.muteOrdinary = false, true
    local first = observe("nameplate1", { guid = "Player-SoundFirst", class = "ROGUE", targeting = true })
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].contact.id, first.id)
    H.True(alerts[1].sound)

    local sample = { guid = "Player-SoundNext", class = "HUNTER", targeting = true }
    clock.Advance(0.2)
    local second = observe("nameplate2", sample)
    engine:Tick()
    H.Equal(#alerts, 1)
    clock.Advance(engine.profile.alerts.soundGap)
    observe("nameplate2", sample)
    engine:Tick()
    H.Equal(#alerts, 2)
    H.Equal(alerts[2].kind, "targeting")
    H.Equal(alerts[2].contact.id, second.id)
    H.True(alerts[2].sound)
    H.False(alerts[2].banner)
end)

local function playOrdinarySound(engine, observe, clock, alerts)
    observe("nameplate1", { guid = "Player-OrdinarySound", class = "ROGUE" })
    clock.Advance(1)
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].kind, "sighting")
    H.True(alerts[1].sound)
end

H.Test("last sound outcome records a silent gap and changes on a later playback attempt", function()
    local engine, observe, clock, alerts = fixture()
    local dispatch = engine.onAlert
    local accepted = true
    engine.onAlert = function(decision)
        dispatch(decision)
        return accepted
    end
    engine.profile.alerts.banner, engine.profile.alerts.muteOrdinary = false, true
    engine.profile.alerts.cooldown = 0
    observe("nameplate1", { guid = "Player-SoundFirst", class = "ROGUE", targeting = true })
    engine:Tick()
    H.Equal(#alerts, 1)

    local sample = { guid = "Player-SoundNext", class = "HUNTER", targeting = true }
    clock.Advance(0.2)
    local second = observe("nameplate2", sample)
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(#engine.history, 1)
    H.Equal(engine.counters.alerts, 1)
    local blocked = engine:LastSoundOutcome(second.id)
    H.Equal(blocked.kind, "targeting")
    H.Equal(blocked.status, "sound_gap")
    blocked.status = "mutated"
    H.Equal(engine:LastSoundOutcome(second.id).status, "sound_gap")

    accepted = false
    clock.Advance(engine.profile.alerts.soundGap)
    observe("nameplate2", sample)
    engine:Tick()
    H.Equal(#alerts, 2)
    H.True(alerts[2].sound)
    H.Equal(engine:LastSoundOutcome(second.id).status, "playback_unconfirmed")

    accepted = true
    clock.Advance(engine.profile.alerts.soundGap)
    sample.targeting = false
    observe("nameplate2", sample)
    sample.targeting = true
    observe("nameplate2", sample)
    engine:Tick()
    H.Equal(#alerts, 3)
    H.Equal(engine:LastSoundOutcome(second.id).status, "playback_requested")
end)

H.Test("last sound outcome follows alias merge and clears with recent sightings", function()
    local engine, observe, clock = fixture()
    engine.onAlert = function() return true end
    engine.profile.alerts.muteOrdinary, engine.profile.alerts.soundGap = true, 0
    local identity = { guid = "Player-SharedSound", class = "ROGUE" }
    local known = observe("nameplate1", identity)
    H.True(engine:Cast("nameplate1", 1856))
    engine:Tick()
    H.Equal(engine:LastSoundOutcome(known.id).kind, "stealth")

    clock.Advance(0.2)
    local anonymous = observe("target", { class = "ROGUE", targeting = true })
    H.True(anonymous.id ~= known.id)
    engine:Tick()
    H.Equal(engine:LastSoundOutcome(anonymous.id).kind, "targeting")

    local merged = observe("target", identity)
    H.Equal(merged.id, known.id)
    H.Nil(engine:LastSoundOutcome(anonymous.id))
    local outcome = engine:LastSoundOutcome(merged.id)
    H.Equal(outcome.kind, "targeting")
    H.Equal(outcome.status, "playback_requested")
    H.Equal(engine:ClearRecent(), 0)
    H.Equal(#engine:Snapshot(), 1)
    H.Nil(engine:LastSoundOutcome(merged.id))
    H.Nil(engine:LastSoundOutcome("missing"))
end)

H.Test("one urgent sound may interrupt an ordinary gap without escalating into a rapid third sound", function()
    local engine, observe, clock, alerts = fixture()
    playOrdinarySound(engine, observe, clock, alerts)

    clock.Advance(0.25)
    observe("nameplate2", { guid = "Player-UrgentTarget", class = "HUNTER", targeting = true })
    engine:Tick()
    H.Equal(#alerts, 2)
    H.Equal(alerts[2].kind, "targeting")
    H.True(alerts[2].sound)

    clock.Advance(0.3)
    observe("nameplate3", { guid = "Player-UrgentStealth", class = "ROGUE" })
    H.True(engine:Cast("nameplate3", 1856))
    engine:Tick()
    H.Equal(#alerts, 3)
    H.Equal(alerts[3].kind, "stealth")
    H.False(alerts[3].sound)
    H.True(alerts[3].banner)

    clock.Advance(1)
    observe("nameplate4", { guid = "Player-OriginalDeadline", class = "ROGUE", targeting = true })
    engine:Tick()
    H.Equal(#alerts, 4)
    H.False(alerts[4].sound)
    clock.Advance(0.25)
    observe("nameplate5", { guid = "Player-LatestDeadline", class = "MAGE", targeting = true })
    engine:Tick()
    H.Equal(#alerts, 5)
    H.True(alerts[5].sound)
end)

H.Test("urgent sounds respect the quarter-second floor and silent warnings leave the exception available", function()
    local engine, observe, clock, alerts = fixture(nil, { ["guid:Player-SilentWatch"] = { kind = "watch" } })
    engine.profile.alerts.sounds.watch = "none"
    playOrdinarySound(engine, observe, clock, alerts)

    clock.Advance(0.125)
    observe("nameplate2", { guid = "Player-BelowFloor", class = "HUNTER", targeting = true })
    engine:Tick()
    H.Equal(#alerts, 2)
    H.Equal(alerts[2].kind, "targeting")
    H.False(alerts[2].sound)
    H.True(alerts[2].banner)

    clock.Advance(0.125)
    observe("nameplate3", { guid = "Player-SilentWatch", class = "MAGE" })
    engine:Tick()
    H.Equal(#alerts, 3)
    H.Equal(alerts[3].kind, "watch")
    H.False(alerts[3].sound)
    observe("nameplate4", { guid = "Player-AudibleAtFloor", class = "ROGUE" })
    H.True(engine:Cast("nameplate4", 1856))
    engine:Tick()
    H.Equal(#alerts, 4)
    H.Equal(alerts[4].kind, "stealth")
    H.True(alerts[4].sound)
end)

H.Test("an emitted Vanish covers the same targeting episode through polls and restricted reads", function()
    local engine, observe, clock, alerts = fixture()
    engine.profile.alerts.muteOrdinary, engine.profile.alerts.cooldown = true, 0
    local sample = { guid = "Player-VanishTarget", class = "ROGUE", targeting = true }
    observe("nameplate1", sample)
    H.True(engine:Cast("nameplate1", 1856))
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].kind, "stealth")
    H.Equal(alerts[1].stealthSpell, "Vanish")
    H.True(alerts[1].sound)
    clock.Advance(engine.profile.alerts.soundGap + 0.1)
    observe("nameplate1", sample)
    engine:Tick()
    H.Equal(#alerts, 1)

    sample.targeting = nil
    observe("nameplate1", sample)
    engine:Tick()
    H.Equal(#alerts, 1)
    sample.targeting = true
    observe("nameplate1", sample)
    engine:Tick()
    H.Equal(#alerts, 1)
end)

H.Test("merging a delivered anonymous targeting episode into its GUID does not repeat the warning", function()
    local engine, observe, clock, alerts = fixture()
    engine.profile.alerts.muteOrdinary, engine.profile.alerts.cooldown = true, 0
    local known = observe("nameplate1", { guid = "Player-MergedTarget", name = "Rival", class = "ROGUE", targeting = false })
    clock.Advance(0.1)
    observe("target", { class = "ROGUE", targeting = true })
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].kind, "targeting")
    H.Nil(alerts[1].contact.identity)
    clock.Advance(engine.profile.alerts.soundGap + 0.1)
    local resolved = observe("target", { guid = "Player-MergedTarget", name = "Rival", class = "ROGUE", targeting = true })
    H.Equal(resolved.id, known.id)
    H.Equal(#engine:Snapshot(), 1)
    engine:Tick()
    H.Equal(#alerts, 1)
end)

H.Test("stealth is the strongest single warning for a watched targeting arrival", function()
    local engine, observe, clock, alerts = fixture(nil, { ["guid:Player-A"] = { kind = "watch" } })
    observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE", stealth = true, stealthReadable = true, targeting = true })
    engine:Tick(); clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 1); H.Equal(alerts[1].kind, "stealth")
end)

H.Test("a clean same-owner non-enemy observation cancels the queued threat", function()
    for _, field in ipairs({ "hostile", "isPlayer" }) do
        local engine, observe, clock, alerts = fixture()
        observe("nameplate1", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
        clock.Advance(0.05)
        local contact, reason = observe("nameplate1", { guid = "Player-A", name = "Alpha", [field] = false })
        H.Nil(contact); H.Equal(reason, "not_enemy_player")
        H.Equal(#engine.pending, 0)
        H.False(engine:Snapshot()[1][field])
        clock.Advance(1); engine:Tick()
        H.Equal(#alerts, 0)
        observe("nameplate1", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
        clock.Advance(1); engine:Tick()
        H.Equal(#alerts, 1); H.Equal(alerts[1].kind, "sighting")
    end
end)

H.Test("a complete unambiguous name can confirm the nonhostile owner without a GUID", function()
    local engine, observe, clock, alerts = fixture()
    observe("target", { name = "Alpha-Realm", nameComplete = true, class = "ROGUE" })
    observe("target", { name = "Alpha-Realm", nameComplete = true, hostile = false })
    H.Equal(#engine.pending, 0)
    clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 0)
end)

H.Test("a non-enemy replacement or an independent hostile alias preserves historical threat evidence", function()
    for _, otherAlias in ipairs({ false, true }) do
        local engine, observe, clock, alerts = fixture()
        observe("nameplate1", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
        if otherAlias then observe("target", { guid = "Player-A", name = "Alpha", class = "ROGUE" }) end
        observe("nameplate1", { guid = otherAlias and "Player-A" or "Player-B", name = "Alpha", hostile = false })
        clock.Advance(1); engine:Tick()
        H.Equal(#alerts, 1); H.Equal(alerts[1].contact.identity, "guid:Player-A")
        H.Equal(alerts[1].contact.visible, otherAlias)
    end
end)

H.Test("leaving without contradictory evidence preserves a recorded cast alert", function()
    local engine, observe, _, alerts = fixture()
    observe("nameplate1", { guid = "Player-A", name = "Alpha", class = "ROGUE" })
    H.True(engine:Cast("nameplate1", 1856))
    engine:Remove("nameplate1")
    engine:Tick()
    H.Equal(#alerts, 1); H.Equal(alerts[1].kind, "stealth")
    H.Equal(alerts[1].contact.stealthEvidence, "cast"); H.False(alerts[1].contact.visible)
end)

H.Test("a cast warning keeps the spell observed before a later absent aura", function()
    local engine, observe, clock, alerts = fixture()
    local first = observe("nameplate1", { guid = "Player-QuickVanish", name = "QuickVanish", class = "ROGUE" })
    H.True(engine:Cast("nameplate1", 1856))
    clock.Advance(0.05)
    observe("nameplate1", { guid = "Player-QuickVanish", stealth = false, stealthReadable = true })
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].kind, "stealth")
    H.Equal(alerts[1].contact.id, first.id)
    H.Equal(alerts[1].stealthEvidence, "cast")
    H.Equal(alerts[1].stealthSpell, "Vanish")
    H.Nil(engine:Snapshot()[1].stealth)
end)

H.Test("late identity on return does not merge old stealth into the new encounter", function()
    local engine, observe, clock = fixture()
    observe("nameplate1", { guid = "Player-LateReturn", name = "Rogue", class = "ROGUE" })
    H.True(engine:Cast("nameplate1", 1856))
    engine:Tick()
    engine:Remove("nameplate1")
    clock.Advance(engine.profile.alerts.returnAfter + 1)
    observe("nameplate2", { class = "ROGUE" })
    local returned = observe("nameplate2", { guid = "Player-LateReturn", name = "Rogue", class = "ROGUE" })
    H.Equal(returned.identity, "guid:Player-LateReturn")
    H.Nil(returned.stealth)
    H.Nil(returned.stealthEvidence)
    H.Equal(#engine:Snapshot(), 1)
end)

H.Test("a confirmed cast supplies the spell name even if the aura was queued first", function()
    local engine, observe, _, alerts = fixture()
    observe("nameplate1", {
        guid = "Player-AuraFirst", name = "Rogue", class = "ROGUE", stealth = true, stealthReadable = true,
    })
    H.True(engine:Cast("nameplate1", 1856))
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].stealthEvidence, "cast")
    H.Equal(alerts[1].stealthSpell, "Vanish")
end)

H.Test("the spell name survives duplicate stealth warnings merging across aliases", function()
    local engine, observe, clock, alerts = fixture()
    observe("nameplate1", { guid = "Player-MergeAura", class = "ROGUE", stealth = true, stealthReadable = true })
    clock.Advance(0.05)
    observe("target", { name = "Rogue-Realm", nameComplete = true, class = "ROGUE" })
    H.True(engine:Cast("target", 1856))
    observe("target", { guid = "Player-MergeAura", name = "Rogue-Realm", nameComplete = true, class = "ROGUE" })
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].stealthEvidence, "cast")
    H.Equal(alerts[1].stealthSpell, "Vanish")
end)

H.Test("a stealth event with no output cannot displace an audible sighting", function()
    local engine, observe, clock, alerts = fixture()
    engine.profile.alerts.banner = false
    engine.profile.alerts.sounds.stealth = "none"
    observe("nameplate1", {
        guid = "Player-SilentStealth", name = "Stealth", class = "ROGUE", stealth = true, stealthReadable = true,
    })
    clock.Advance(1)
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].kind, "sighting")
    H.True(alerts[1].sound)
end)

H.Test("sightings with no individual output can still play the configured group sound", function()
    for _, count in ipairs({ 1, 3 }) do
        local engine, observe, clock, alerts = fixture()
        engine.profile.alerts.banner = false
        engine.profile.alerts.sounds.sighting = "none"
        engine.profile.alerts.sounds.wave = "ready"
        local first
        for i = 1, count do
            local contact = observe("nameplate" .. i, { guid = "Player-Wave" .. i, name = "Wave" .. i, class = "ROGUE" })
            first = first or contact
        end
        local detail = engine:ExplainView(first.id, "sighting")
        H.False(detail.allowed)
        H.Equal(detail.reason, "wave_only")
        clock.Advance(1)
        engine:Tick()
        H.Equal(#alerts, count == 3 and 1 or 0)
        if count == 3 then H.Equal(alerts[1].kind, "wave"); H.True(alerts[1].sound) end
        H.Equal(engine:ExplainView(first.id, "sighting").reason, "wave_only")
    end
end)

H.Test("a stalled tick drops expired events without spending first-arrival or sound budget", function()
    for _, staleKind in ipairs({ "sighting", "stealth" }) do
        local engine, observe, clock, alerts = fixture()
        local fields = { guid = "Player-Stalled", name = "Fixture Rival", class = "ROGUE" }
        local original = observe("nameplate1", fields)
        if staleKind == "stealth" then H.True(engine:Cast("nameplate1", 1856)) end
        clock.Advance(11)
        engine:Tick()
        H.Equal(#alerts, 0)
        H.Equal(#engine.history, 0)
        H.True(engine:ExplainView(original.id, "sighting").allowed)

        fields.stealth, fields.stealthReadable = false, true
        H.Equal(observe("nameplate1", fields).id, original.id)
        clock.Advance(1)
        engine:Tick()
        H.Equal(#alerts, 1)
        H.Equal(alerts[1].kind, "sighting")
        H.True(alerts[1].sound)
    end
end)

H.Test("an expired pending cast cannot block a fresh cast of the same event before Tick", function()
    local engine, observe, clock, alerts = fixture()
    local contact = observe("nameplate1", { guid = "Player-Recast", class = "ROGUE" })
    H.True(engine:Cast("nameplate1", 1856))
    clock.Advance(5.1)
    H.True(engine:Cast("nameplate1", 1784))
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].contact.id, contact.id)
    H.Equal(alerts[1].stealthSpell, "Stealth")
    H.True(alerts[1].sound)
end)

H.Test("a delayed tick emits separate waves for observations from different windows", function()
    local engine, observe, clock, alerts = fixture()
    local function crowd(first, class)
        for index = first, first + 2 do
            observe("nameplate" .. index, { guid = "Player-Delayed-" .. index, class = class })
            clock.Advance(0.05)
        end
    end
    crowd(1, "ROGUE")
    clock.Advance(engine.profile.alerts.waveWindow + 0.2)
    crowd(4, "HUNTER")
    clock.Advance(1)
    engine:Tick()
    H.Equal(#alerts, 2)
    H.Equal(alerts[1].kind, "wave")
    H.Equal(alerts[1].count, 3)
    H.Equal(alerts[1].classes.ROGUE, 3)
    H.Nil(alerts[1].classes.HUNTER)
    H.True(alerts[1].sound)
    H.Equal(alerts[2].kind, "wave")
    H.Equal(alerts[2].count, 3)
    H.Equal(alerts[2].classes.HUNTER, 3)
    H.Nil(alerts[2].classes.ROGUE)
    H.False(alerts[2].sound)
end)

H.Test("a regular tick collects a burst when its first arrival's window closes", function()
    local engine, observe, clock, alerts = fixture()
    for index = 1, 3 do
        observe("nameplate" .. index, { guid = "Player-Regular-" .. index, class = "ROGUE" })
        engine:Tick()
        if index < 3 then clock.Advance(0.1) end
    end
    H.Equal(#alerts, 0)
    clock.Advance(engine.profile.alerts.waveWindow - 0.15)
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].kind, "wave")
    H.Equal(alerts[1].count, 3)
    clock.Advance(0.3)
    engine:Tick()
    H.Equal(#alerts, 1)
end)

H.Test("an expired crowd cannot turn a recent isolated sighting into a wave", function()
    local engine, observe, clock, alerts = fixture()
    for index = 1, 3 do
        observe("nameplate" .. index, { guid = "Player-Expired-" .. index, class = "ROGUE" })
    end
    clock.Advance(11)
    local fresh = observe("target", { guid = "Player-Fresh", class = "HUNTER" })
    clock.Advance(1)
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].kind, "sighting")
    H.Equal(alerts[1].contact.id, fresh.id)
    H.True(alerts[1].sound)
end)

local function queuePressureFixture()
    local engine, observe, clock, alerts = fixture()
    engine.profile.retention.maxContacts = 32
    local function arrival(index, event)
        local fields = { guid = "Player-Queue-" .. index, name = "Rival " .. index, class = "ROGUE" }
        if event == "stealth" then fields.stealth, fields.stealthReadable = true, true end
        if event == "targeting" then fields.targeting = true end
        return observe("nameplate" .. index, fields)
    end
    return engine, arrival, clock, alerts
end

H.Test("ordinary overflow retains pending stealth and keeps older equal-priority arrivals", function()
    local engine, arrival, clock, alerts = queuePressureFixture()
    local stealth = arrival(1, "stealth")
    for index = 2, 31 do arrival(index) end
    clock.Advance(0.9)
    arrival(2, "targeting")
    H.Equal(#engine.pending, 32)
    local newest = arrival(32)
    H.Equal(#engine.pending, 32)
    H.Equal(#engine:Snapshot(), 32)
    H.Equal(engine.counters.evicted, 0)
    H.Equal(engine.counters.queueOverflow, 1)

    engine:Tick()
    H.Equal(#alerts, 3)
    H.Equal(alerts[1].kind, "stealth")
    H.Equal(alerts[1].contact.id, stealth.id)
    H.True(alerts[1].sound)
    H.Equal(alerts[2].kind, "targeting")
    H.Equal(alerts[3].kind, "wave")
    H.Equal(alerts[3].count, 30)
    clock.Advance(1)
    engine:Tick()
    H.Equal(#alerts, 3)
    H.Equal(arrival(32).id, newest.id)
    clock.Advance(1)
    engine:Tick()
    H.Equal(#alerts, 4)
    H.Equal(alerts[4].kind, "sighting")
    H.Equal(alerts[4].contact.id, newest.id)
end)

H.Test("stronger overflow replaces the newest weakest arrival and lets it retry", function()
    local engine, arrival, clock, alerts = queuePressureFixture()
    local newest
    for index = 1, 32 do newest = arrival(index) end
    H.Equal(#engine.pending, 32)
    clock.Advance(0.9)
    local targeting = arrival(2, "targeting")
    H.Equal(#engine.pending, 32)
    H.Equal(engine.counters.evicted, 0)
    H.Equal(engine.counters.queueOverflow, 1)

    engine:Tick()
    H.Equal(#alerts, 2)
    H.Equal(alerts[1].kind, "targeting")
    H.Equal(alerts[1].contact.id, targeting.id)
    H.Equal(alerts[2].kind, "wave")
    H.Equal(alerts[2].count, 31)
    H.Equal(arrival(32).id, newest.id)
    clock.Advance(1)
    engine:Tick()
    H.Equal(#alerts, 3)
    H.Equal(alerts[3].kind, "sighting")
    H.Equal(alerts[3].contact.id, newest.id)
end)

local function highestSightingRule(engine)
    engine.profile.rules = { { name = "Immediate sighting", enabled = true, event = "sighting", classes = {},
        priority = 100, action = "alert", banner = true, sound = true, cooldown = 30 } }
end

H.Test("contact capacity retains a Vanish over equal numeric priority sightings", function()
    local engine, arrival, clock, alerts = queuePressureFixture()
    engine.profile.alerts.muteOrdinary = true
    local threat = arrival(1, "stealth")
    engine.profile.alerts.muteOrdinary = false
    highestSightingRule(engine)
    for index = 2, 33 do arrival(index) end
    H.True(engine.contacts[threat.id] ~= nil)
    H.Equal(engine.counters.evicted, 1)
    clock.Advance(0.25)
    engine:Tick()
    H.Equal(alerts[1].kind, "stealth")
    H.Equal(alerts[1].contact.id, threat.id)
    H.True(alerts[1].sound)
end)

H.Test("alias merge retains targeting over a higher numeric priority sighting of its owner", function()
    local engine, observe, clock, alerts = fixture()
    highestSightingRule(engine)
    local known = { guid = "Player-MergedThreat", class = "ROGUE" }
    local identified = observe("nameplate1", known)
    local anonymous = observe("target", { class = "ROGUE", targeting = true })
    H.True(identified.id ~= anonymous.id)
    local merged = observe("target", { guid = known.guid, class = "ROGUE", targeting = true })
    H.Equal(merged.id, identified.id)
    H.Equal(#engine.pending, 1)
    clock.Advance(0.25)
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].kind, "targeting")
    H.Equal(alerts[1].contact.id, identified.id)
end)

H.Test("capacity continuity stores at most 512 GUIDs and clears with recent sightings", function()
    local engine, observe = fixture()
    engine.profile.retention.maxContacts = 32
    for i = 1, 600 do
        observe("nameplate1", { guid = "Player-Continuity-" .. i, name = "Rival " .. i, class = "HUNTER" })
        engine:Remove("nameplate1")
    end
    local count = 0
    for _ in pairs(engine.evictedEncounters) do count = count + 1 end
    H.Equal(count, 512)
    H.Equal(#engine:Snapshot(), 32)
    engine:ClearRecent()
    H.Nil(next(engine.evictedEncounters))
    H.Nil(next(engine.evictionSlots))
    H.Equal(#engine:Snapshot(), 0)
end)

H.Test("capacity continuity preserves the repeat delay for a recent cast", function()
    local engine, observe, clock, alerts = fixture()
    engine.profile.retention.maxContacts = 32
    local owner = { guid = "Player-VanishOwner", name = "Owner", class = "ROGUE" }
    observe("target", owner)
    H.True(engine:Cast("target", 1856))
    engine:Tick()
    H.Equal(#alerts, 1)
    engine:Remove("target")
    for i = 1, 32 do observe("nameplate" .. i, { guid = "Player-Peer-" .. i, class = "HUNTER" }) end
    H.True(engine.evictedEncounters[owner.guid] ~= nil)

    clock.Advance(1.2)
    observe("target", owner)
    H.True(engine:Cast("target", 1856))
    engine:Tick()
    local casts = 0
    for _, alert in ipairs(alerts) do if alert.kind == "stealth" then casts = casts + 1 end end
    H.Equal(casts, 1)
end)

for _, alreadyAnnounced in ipairs({ false, true }) do
    local suffix = alreadyAnnounced and "after notification" or "before notification"
    H.Test("an expired row handles late GUID discovery " .. suffix, function()
        local engine, observe, clock, alerts = fixture()
        engine.profile.alerts.returnAfter = 180
        local known = { guid = "Player-ReturningAlias", class = "ROGUE" }
        observe("target", known)
        clock.Advance(1)
        engine:Tick()
        H.Equal(alerts[1].kind, "sighting")
        engine:Remove("target")
        clock.Advance(180)
        engine:Tick()
        H.Equal(engine.contactCount, 0)

        observe("nameplate1", { class = "ROGUE" })
        if alreadyAnnounced then clock.Advance(1); engine:Tick() end
        observe("nameplate1", known)
        clock.Advance(1)
        engine:Tick()
        H.Equal(#alerts, 2)
        H.Equal(alerts[2].kind, alreadyAnnounced and "sighting" or "returning")
    end)
end
