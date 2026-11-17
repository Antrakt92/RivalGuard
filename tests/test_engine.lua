local H = RGTest
local function setup(change)
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua" })
    local clock, profile, alerts, encounters = H.Clock(100), RG.Defaults.NewProfile(), {}, {}
    if change then change(profile) end
    local engine = RG.Engine.New({ clock = clock.Now, epoch = function() return 1000000 + clock.Now() end, profile = profile,
        onAlert = function(decision) alerts[#alerts + 1] = decision end,
        onEncounter = function(contact, at) encounters[#encounters + 1] = { contact = contact, at = at } end })
    local function observe(token, guid, extra)
        local obs = { token = token, guid = guid, name = guid and ("Enemy " .. guid) or nil, class = "ROGUE", hostile = true, isPlayer = true, source = "nameplate" }
        for key, value in pairs(extra or {}) do obs[key] = value end
        return engine:Observe(obs)
    end
    local function tick(seconds) clock.Advance(seconds or 1); engine:Tick() end
    return engine, clock, alerts, observe, tick, profile, RG, encounters
end

H.Test("one identity across several sources yields one detached record and arrival", function()
    local engine, _, alerts, observe, tick, _, _, encounters = setup()
    observe("nameplate1", "A")
    observe("target", "A", { source = "target" })
    observe("mouseover", "A", { source = "mouseover" })
    H.Equal(#engine:Snapshot(), 1); H.Equal(#alerts, 0)
    tick()
    H.Equal(#alerts, 1); H.Equal(#encounters, 1)
    H.True(alerts[1].contact.sources.nameplate); H.True(alerts[1].contact.sources.target)
    alerts[1].contact.name = "Mutated"
    H.Equal(engine:Snapshot()[1].name, "Enemy A")
end)

H.Test("anonymous same class contacts remain separate and token reuse makes new generation", function()
    local engine, _, _, observe = setup()
    local a = observe("nameplate1", nil)
    local b = observe("nameplate2", nil)
    H.True(a.id ~= b.id); H.Equal(#engine:Snapshot(), 2)
    engine:Remove("nameplate1")
    local c = observe("nameplate1", nil)
    H.True(c.id ~= a.id)
    H.Nil(c.identity)
end)

H.Test("same display name on different realms or GUIDs is never conflated", function()
    local engine, _, _, observe = setup()
    observe("nameplate1", "A", { name = "Shared", realm = "One" })
    observe("nameplate2", "B", { name = "Shared", realm = "Two" })
    observe("nameplate3", "C", { name = "Shared", realm = "One" })
    H.Equal(#engine:Snapshot(), 3)
end)

H.Test("anonymous identity promotion merges sources without duplicate arrival", function()
    local engine, _, alerts, observe, tick = setup()
    local unknown = observe("nameplate1", nil)
    observe("target", "A", { source = "target" })
    observe("nameplate1", "A")
    H.Equal(#engine:Snapshot(), 1)
    tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].contact.identity, "guid:A")
    H.True(type(unknown.id) == "string")
end)

H.Test("nameplate departure while target remains never marks contact unseen", function()
    local engine, _, _, observe = setup()
    observe("nameplate1", "A"); observe("target", "A", { source = "target" })
    engine:Remove("nameplate1")
    H.True(engine:Snapshot()[1].visible)
    engine:Remove("target")
    H.False(engine:Snapshot()[1].visible)
end)

H.Test("late class creates one eligible alert when unknown class is excluded", function()
    local engine, _, alerts, observe, tick = setup(function(p) p.alerts.classes = { ROGUE = true }; p.alerts.unknownClass = false end)
    observe("nameplate1", "A", { class = "INVALID" }); tick()
    H.Equal(#alerts, 0)
    observe("nameplate1", "A", { class = "ROGUE" }); tick()
    H.Equal(#alerts, 1); H.True(alerts[1].sound)
    observe("nameplate1", "A"); tick()
    H.Equal(#alerts, 1)
end)

H.Test("unknown player and hostility evidence stays silent until clean confirmation", function()
    local engine, _, alerts, _, tick = setup()
    local unknown = { token = "nameplate1", guid = "A", name = "Enemy", class = "ROGUE", source = "nameplate" }
    engine:Observe(unknown); tick(); H.Equal(#alerts, 0)
    unknown.hostile, unknown.isPlayer = true, true
    engine:Observe(unknown); tick(); H.Equal(#alerts, 1)
end)

H.Test("queued targeting is canceled if clean target evidence ends before delivery", function()
    local _, _, alerts, observe, tick = setup(function(profile)
        profile.alerts.targeting = true
        profile.alerts.soundGap = 0
    end)
    observe("nameplate1", "A", { targeting = false })
    tick()
    H.Equal(#alerts, 1)
    observe("nameplate1", "A", { targeting = true })
    observe("nameplate1", "A", { targeting = false })
    tick()
    H.Equal(#alerts, 1)
    observe("nameplate1", "A", { targeting = true })
    tick()
    H.Equal(#alerts, 2)
    H.Equal(alerts[2].kind, "targeting")
    H.True(alerts[2].contact.targeting)
end)

H.Test("a session contact snooze survives contact eviction and world changes until expiry", function()
    local engine, _, alerts, observe, tick = setup(function(profile)
        profile.retention.maxContacts = 32
        profile.alerts.waveThreshold = 2
    end)
    local first = observe("nameplate1", "Snoozed")
    engine:Remove("nameplate1")
    H.True(engine:ToggleContactSnooze(first.id, 60))
    for index = 2, 33 do observe("nameplate" .. index, "Other" .. index) end
    H.Equal(engine:ExplainView(first.id).reason, "not_observed")
    local returned = observe("target", "Snoozed")
    H.True(returned.id ~= first.id)
    H.Equal(engine:ExplainView(returned.id).reason, "contact_snoozed")

    engine:Clear()
    local changedWorld = observe("nameplate1", "Snoozed")
    tick()
    H.Equal(#alerts, 0)
    H.Equal(engine:ExplainView(changedWorld.id).reason, "contact_snoozed")
    tick(61)
    observe("nameplate1", "Snoozed")
    tick()
    H.Equal(#alerts, 1)
    H.Equal(alerts[1].contact.id, changedWorld.id)
end)

H.Test("restricted observation fields do not leak to identity history or alerts", function()
    local engine, _, alerts, _, tick = setup()
    local secret = H.Secret("observation")
    local contact = assert(engine:Observe({ token = "nameplate1", guid = secret, name = secret, class = secret,
        hostile = secret, isPlayer = secret, rangeMin = secret, rangeMax = secret, source = "nameplate" }))
    H.Nil(contact.identity); H.Nil(contact.name); H.Nil(contact.class); H.Nil(contact.hostile)
    tick(); H.Equal(#alerts, 0)
end)

H.Test("brief disappearance has no return alert while long absence does", function()
    local engine, clock, alerts, observe, tick = setup()
    observe("nameplate1", "A"); tick()
    engine:Remove("nameplate1"); clock.Advance(2); observe("nameplate1", "A"); tick()
    H.Equal(#alerts, 1)
    engine:Remove("nameplate1"); clock.Advance(46); observe("nameplate1", "A"); tick()
    H.Equal(#alerts, 2); H.Equal(alerts[2].kind, "returning")
end)

H.Test("an anonymous sighting cannot override the returning rule when its owner is recognized", function()
    local engine, clock, alerts, observe, tick, profile = setup(function(p)
        p.alerts.returnAfter = 5
        p.alerts.sound, p.alerts.banner = false, false
        p.rules = { { enabled = true, event = "returning", classes = {}, action = "suppress" } }
    end)
    local first = observe("nameplate1", "Owner")
    engine:Remove("nameplate1")
    clock.Advance(5)
    profile.alerts.banner = true
    observe("nameplate2", nil)
    H.Equal(#engine.pending, 1)
    H.Equal(engine.pending[1].event, "sighting")
    H.Equal(observe("nameplate2", "Owner").id, first.id)
    tick()
    H.Equal(#alerts, 0)
    H.Equal(#engine.pending, 0)
end)

H.Test("eviction cannot turn a suppressed return into a first sighting", function()
    local engine, clock, alerts, observe, tick, profile = setup(function(p)
        p.alerts.returnAfter = 5
        p.retention.maxContacts = 1
        p.alerts.sound, p.alerts.banner = false, false
        p.rules = { { enabled = true, event = "returning", classes = {}, action = "suppress" } }
    end)
    engine.onEncounter = nil
    local first = observe("nameplate1", "Owner")
    engine:Remove("nameplate1")
    clock.Advance(5)
    H.Equal(observe("nameplate1", "Owner").id, first.id)
    H.True(observe("nameplate2", "Other").id ~= first.id)
    H.Nil(engine.contacts[first.id])
    profile.alerts.banner = true
    H.True(observe("nameplate1", "Owner").id ~= first.id)
    tick()
    H.Equal(#alerts, 0)
end)

H.Test("disappearance never fabricates confirmed stealth and stale casts are dropped", function()
    local engine, _, alerts, observe, tick = setup()
    observe("nameplate1", "A"); tick()
    engine:Remove("nameplate1"); tick(3)
    H.Nil(engine:Snapshot()[1].stealth)
    H.False(engine:Cast("nameplate1", 1784)); tick()
    H.Equal(#alerts, 1)
end)

H.Test("confirmed stealth duplicate events coalesce and unreadable aura never clears it", function()
    local engine, _, alerts, observe, tick = setup()
    observe("nameplate1", "A"); tick()
    H.True(engine:Cast("nameplate1", 1784))
    H.False(engine:Cast("nameplate1", 1784))
    tick(0)
    H.Equal(#alerts, 2); H.Equal(alerts[2].kind, "stealth")
    observe("nameplate1", "A", { stealthReadable = false }); tick(2)
    H.Equal(engine:Snapshot()[1].stealth, "confirmed")
    observe("nameplate1", "A", { stealthReadable = true, stealth = false })
    H.Nil(engine:Snapshot()[1].stealth)
end)

H.Test("crowd arrivals summarize ordinary threats without swallowing watched enemy", function()
    local engine, _, alerts, observe, tick = setup()
    engine.lists["guid:W"] = { kind = "watch" }
    for index = 1, 5 do observe("nameplate" .. index, tostring(index)) end
    observe("nameplate6", "W")
    tick()
    H.Equal(#alerts, 2)
    H.Equal(alerts[1].kind, "watch"); H.Equal(alerts[2].kind, "wave")
    H.Equal(alerts[2].count, 5); H.Equal(alerts[2].classes.ROGUE, 5)
    H.True(alerts[1].sound); H.False(alerts[2].sound)
end)

H.Test("high-priority custom sightings keep their individual priority in a crowd", function()
    local _, _, alerts, observe, tick = setup(function(profile)
        profile.alerts.waveThreshold = 3
        profile.rules = {{
            name = "Urgent rogue", enabled = true, event = "sighting", priority = 95,
            classes = { ROGUE = true }, action = "alert", sound = false, banner = true, cooldown = 20,
        }}
    end)
    for index = 1, 3 do
        observe("nameplate" .. index, "Rogue" .. index)
        observe("nameplate" .. (index + 3), "Hunter" .. index, { class = "HUNTER" })
    end
    tick()
    H.Equal(#alerts, 4)
    for index = 1, 3 do
        H.Equal(alerts[index].priority, 95)
        H.Equal(alerts[index].contact.class, "ROGUE")
        H.Equal(alerts[index].ruleName, "Urgent rogue")
    end
    H.Equal(alerts[4].kind, "wave")
    H.Equal(alerts[4].count, 3)
    H.Equal(alerts[4].classes.HUNTER, 3)
    H.Nil(alerts[4].classes.ROGUE)
end)

H.Test("queued alerts recheck current context instead of emitting stale eligibility", function()
    local engine, _, alerts, observe, tick = setup()
    observe("nameplate1", "A")
    engine:SetContext({ kind = "instance" }); tick()
    H.Equal(#alerts, 0)
    engine:SetContext({ kind = "world" })
    observe("nameplate2", "B"); tick()
    H.Equal(#alerts, 1); H.Equal(alerts[1].contact.identity, "guid:B")
end)

H.Test("profile switches cancel newly ineligible alerts and apply new rules to future enemies", function()
    local engine, _, alerts, observe, tick, _, RG = setup()
    observe("nameplate1", "A")
    local replacement = RG.Defaults.NewProfile(); replacement.alerts.classes = { MAGE = true }
    engine:SetProfile(replacement); tick()
    H.Equal(#alerts, 0)
    observe("nameplate2", "B", { class = "MAGE" }); tick()
    H.Equal(#alerts, 1); H.Equal(alerts[1].contact.class, "MAGE")
end)

H.Test("pause drops pending output without stopping contact updates and resume works", function()
    local engine, _, alerts, observe, tick = setup()
    observe("nameplate1", "A"); engine:Pause(10); tick()
    observe("nameplate2", "B"); tick()
    H.Equal(#alerts, 0); H.Equal(#engine:Snapshot(), 2)
    engine:Resume(); observe("nameplate3", "C"); tick()
    H.Equal(#alerts, 1); H.Equal(alerts[1].contact.identity, "guid:C")
end)

H.Test("clear invalidates pending output and previous token associations", function()
    local engine, _, alerts, observe, tick = setup()
    local first = observe("nameplate1", "A")
    engine:Clear(); tick()
    H.Equal(#alerts, 0); H.Equal(#engine:Snapshot(), 0)
    local nextContact = observe("nameplate1", "B")
    H.True(first.id ~= nextContact.id)
    H.Equal(nextContact.identity, "guid:B")
end)

H.Test("contact history and notification queues remain bounded in long replays", function()
    local engine, _, _, observe, tick, profile = setup(function(p) p.retention.maxContacts = 32; p.retention.maxHistory = 20 end)
    for index = 1, 150 do
        observe("nameplate" .. index, tostring(index))
        if index % 5 == 0 then tick() end
        H.True(#engine:Snapshot() <= profile.retention.maxContacts)
        H.True(#engine.pending <= profile.retention.maxContacts)
        H.True(#engine.history <= profile.retention.maxHistory)
    end
    for token in pairs(engine.bindings) do engine:Remove(token) end
    tick(profile.retention.contactSeconds + 1)
    H.Equal(#engine:Snapshot(), 0)
end)
