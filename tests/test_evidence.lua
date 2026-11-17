local H = RGTest
local function fixture(config)
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua" })
    local engine = RG.Engine.New(config)
    local function observe(token, data)
        local obs = { token = token, guid = "Player-A", name = "Alpha", source = token }
        for key, value in pairs(data or {}) do obs[key] = value end
        return engine:Observe(obs)
    end
    return engine, observe
end

H.Test("unknown alias does not overwrite independently confirmed player and enemy evidence", function()
    local engine, observe = fixture()
    observe("nameplate1", { hostile = true, isPlayer = true })
    local contact = observe("target", {})
    H.True(contact.hostile); H.True(contact.isPlayer)
    engine:Remove("nameplate1")
    local remaining = engine:Snapshot()[1]
    H.Nil(remaining.hostile); H.Nil(remaining.isPlayer)
end)

local function rangeFixture()
    local clock, alerts = H.Clock(), {}
    local engine, observe = fixture({ clock = clock.Now, onAlert = function(decision) alerts[#alerts + 1] = decision end })
    local range = engine.profile.range
    range.enabled, range.yards, range.policy, range.unknown = true, 25, "confirmed", false
    local function sample(token, lower, upper, exclusive)
        return observe(token, { hostile = true, isPlayer = true, class = "ROGUE",
            rangeMin = lower, rangeMax = upper, rangeMinExclusive = exclusive })
    end
    return engine, sample, clock, alerts
end

H.Test("simultaneous compatible aliases intersect their bounds and keep an exclusive minimum", function()
    local engine, sample = rangeFixture()
    sample("nameplate1", 0, 25)
    local combined = sample("target", 15, nil, true)
    H.Equal(combined.rangeMin, 15)
    H.True(combined.rangeMinExclusive)
    H.Equal(combined.rangeMax, 25)
    H.True(engine:ExplainView(combined.id).allowed)
end)

H.Test("a new conflicting range cohort cannot authorize an alert using older clean evidence", function()
    local engine, sample, clock, alerts = rangeFixture()
    local original = sample("nameplate1", 8, 8)
    clock.Advance(0.1)
    sample("target", 10, 10)
    local conflicting = sample("focus", 45, 45)
    H.Equal(conflicting.id, original.id)
    H.Nil(conflicting.rangeMin)
    H.Nil(conflicting.rangeMax)
    H.False(engine:ExplainView(original.id).allowed)
    H.Equal(engine:ExplainView(original.id).reason, "range_conflict")
    clock.Advance(1)
    engine:Tick()
    H.Equal(#alerts, 0)

    local far = sample("focus", 43, 43)
    H.Equal(far.rangeMax, 43)
    H.Equal(engine:ExplainView(original.id).reason, "range_outside")
    clock.Advance(0.1)
    local near = sample("target", 14, 14)
    H.Equal(near.rangeMin, 14)
    H.Equal(near.rangeMax, 14)
    clock.Advance(1)
    engine:Tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].contact.id, original.id)
end)

H.Test("unknown aliases retain a recent range sample but cannot keep it alive past its age limit", function()
    local engine, sample, clock, alerts = rangeFixture()
    local original = sample("nameplate1", 10, 10)
    clock.Advance(1.9)
    local recent = sample("target")
    H.Equal(recent.rangeMax, 10)
    H.True(engine:ExplainView(original.id).allowed)
    clock.Advance(0.2)
    H.Nil(engine:Snapshot()[1].rangeMax)
    H.Equal(engine:ExplainView(original.id).reason, "range_unknown")
    engine:Tick()
    H.Equal(#alerts, 0)
end)

H.Test("an exclusive lower bound equal to its upper bound is not a valid range sample", function()
    local engine, sample, clock, alerts = rangeFixture()
    local invalid = sample("nameplate1", 20, 20, true)
    H.Nil(invalid.rangeMin)
    H.Nil(invalid.rangeMax)
    H.Equal(engine:ExplainView(invalid.id).reason, "range_conflict")
    clock.Advance(1)
    engine:Tick()
    H.Equal(#alerts, 0)
end)

H.Test("unknown range on another source preserves a currently readable interval", function()
    local engine, observe = fixture()
    observe("nameplate1", { hostile = true, isPlayer = true, rangeMin = 20, rangeMax = 30 })
    local contact = observe("focus", {})
    H.Equal(contact.rangeMin, 20); H.Equal(contact.rangeMax, 30)
    engine:Remove("nameplate1")
    H.Nil(engine:Snapshot()[1].rangeMin); H.Nil(engine:Snapshot()[1].rangeMax)
end)

H.Test("behind camera state belongs to available nameplate rather than latest alias", function()
    local engine, observe = fixture()
    observe("nameplate1", { hostile = true, isPlayer = true, behindCamera = true })
    local contact = observe("mouseover", {})
    H.True(contact.behindCamera)
    observe("nameplate1", { hostile = true, isPlayer = true, behindCamera = false })
    H.False(engine:Snapshot()[1].behindCamera)
end)

H.Test("targeting evidence expires when its source no longer provides a clean answer", function()
    local engine, observe = fixture()
    observe("nameplate1", { hostile = true, isPlayer = true, targeting = true })
    local contact = observe("nameplate1", { hostile = true, isPlayer = true })
    H.Nil(contact.targeting)
    H.Nil(engine:Snapshot()[1].targeting)
end)

H.Test("same GUID metadata changes cannot accumulate permanent name aliases", function()
    local engine, observe = fixture()
    for index = 1, 1000 do observe("nameplate1", { name = "Renamed " .. index, hostile = true, isPlayer = true }) end
    local count = 0
    for _ in pairs(engine.identities) do count = count + 1 end
    H.True(count <= 2)
    H.Nil(engine.identities["name:Renamed 1"])
end)

H.Test("conflicting full names never merge a third identity with an arbitrary GUID", function()
    local engine, observe = fixture()
    observe("nameplate1", { guid = "Player-A", name = "Same", hostile = true, isPlayer = true })
    observe("nameplate2", { guid = "Player-B", name = "Same", hostile = true, isPlayer = true })
    local third = engine:Observe({ token = "focus", name = "Same", hostile = true, isPlayer = true })
    H.Equal(#engine:Snapshot(), 3)
    H.Nil(third.identity)
    H.True(third.ambiguousIdentity)
end)

H.Test("partial names remain displayable without becoming a durable identity", function()
    local engine = fixture()
    local contact = engine:Observe({ token = "target", name = "Shared", nameComplete = false, hostile = true, isPlayer = true })
    H.Equal(contact.name, "Shared"); H.Nil(contact.identity)
    local named = engine:Observe({ token = "target", name = "Shared Surname", nameComplete = true, hostile = true, isPlayer = true })
    H.Equal(named.id, contact.id); H.Equal(named.identity, "name:Shared Surname")
end)

H.Test("clear recent drops departed sightings without rearming currently observed players", function()
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua" })
    local clock, count = H.Clock(), 0
    local engine = RG.Engine.New({ clock = clock.Now, onAlert = function() count = count + 1 end })
    local active = { token = "target", guid = "A", name = "Active", class = "ROGUE", hostile = true, isPlayer = true }
    engine:Observe(active)
    engine:Observe({ token = "focus", guid = "B", name = "Departed", class = "HUNTER", hostile = true, isPlayer = true })
    clock.Advance(1); engine:Tick()
    H.Equal(count, 2)
    engine:Remove("focus")
    H.Equal(engine:ClearRecent(), 1)
    H.Equal(#engine:Snapshot(), 1)
    engine:Observe(active)
    clock.Advance(2); engine:Tick()
    H.Equal(count, 2)
end)

H.Test("temporary contact snooze cancels queued output, preserves tracking and expires", function()
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua" })
    local clock, alerts = H.Clock(), {}
    local engine = RG.Engine.New({ clock = clock.Now, onAlert = function(event) alerts[#alerts + 1] = event end })
    local observation = { token = "nameplate1", guid = "A", name = "Quiet", class = "ROGUE", hostile = true, isPlayer = true }
    local contact = engine:Observe(observation)
    local ok, untilTime = engine:ToggleContactSnooze(contact.id, 5)
    H.True(ok); H.Equal(untilTime, 5)
    clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 0); H.True(engine:Snapshot()[1].visible)
    H.Equal(engine:ExplainView(contact.id).reason, "contact_snoozed")
    clock.Advance(5); engine:Observe(observation); clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 1)
    H.Nil(engine:ToggleContactSnooze("missing", 5))
end)

H.Test("merged evidence emits only the strongest notification for the same sighting burst", function()
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua" })
    local clock, alerts = H.Clock(), {}
    local engine = RG.Engine.New({ clock = clock.Now, onAlert = function(event) alerts[#alerts + 1] = event end })
    engine:Observe({ token = "target", class = "ROGUE", hostile = true, isPlayer = true })
    engine:Observe({ token = "nameplate1", guid = "A", name = "Rogue", class = "ROGUE", stealth = true, stealthReadable = true, hostile = true, isPlayer = true })
    engine:Observe({ token = "target", guid = "A", name = "Rogue", class = "ROGUE", hostile = true, isPlayer = true })
    engine:Tick(); clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 1); H.Equal(alerts[1].kind, "stealth")
end)

H.Test("discarding a stale targeting alert can still allow the initial ordinary sighting", function()
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua" })
    local clock, alerts = H.Clock(), {}
    local engine = RG.Engine.New({ clock = clock.Now, onAlert = function(event) alerts[#alerts + 1] = event end })
    local observation = { token = "nameplate1", guid = "A", name = "Quiet", class = "ROGUE", hostile = true, isPlayer = true, targeting = true }
    engine:Observe(observation)
    observation.targeting = false
    engine:Observe(observation)
    engine:Tick()
    H.Equal(#alerts, 0)
    engine:Observe(observation)
    clock.Advance(1); engine:Tick()
    H.Equal(#alerts, 1); H.Equal(alerts[1].kind, "sighting")
end)
