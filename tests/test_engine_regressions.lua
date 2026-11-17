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
