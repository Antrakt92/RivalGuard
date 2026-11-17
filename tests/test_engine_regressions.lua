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
