local H = RGTest
local modules = { "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua" }

local function random(seed)
    return function(maximum)
        seed = (seed * 16807) % 2147483647
        return seed % maximum + 1
    end
end

local function invariant(RG, engine, seed, step)
    local prefix = "seed " .. seed .. " step " .. step .. ": "
    local count, guidOwners, expectedNameOwners = 0, {}, {}
    for id, contact in pairs(engine.contacts) do
        count = count + 1
        assert(contact.id == id, prefix .. "contact key disagrees with identity")
        assert(contact.firstSeen <= contact.lastSeen, prefix .. "observation time reversed")
        if contact.guid then
            assert(not guidOwners[contact.guid], prefix .. "duplicate GUID contacts")
            guidOwners[contact.guid] = id
            assert(engine.identities["guid:" .. contact.guid] == id, prefix .. "GUID alias points elsewhere")
        end
        if contact.nameIdentity then
            local bucket = expectedNameOwners[contact.nameIdentity] or {}
            bucket[id] = true
            expectedNameOwners[contact.nameIdentity] = bucket
        end
        for token in pairs(contact.tokens) do
            assert(engine.bindings[token] and engine.bindings[token].id == id, prefix .. "contact has orphaned token")
        end
    end
    for token, binding in pairs(engine.bindings) do
        assert(engine.contacts[binding.id], prefix .. "binding points to evicted contact")
        assert(engine.contacts[binding.id].tokens[token], prefix .. "binding absent from contact")
    end
    for name, bucket in pairs(expectedNameOwners) do
        local current = engine.nameOwners[name]
        assert(current, prefix .. "name bucket missing")
        local sole = next(bucket)
        local ambiguous = next(bucket, sole) ~= nil
        local indexed = engine.identities[name]
        if ambiguous then assert(indexed == false, prefix .. "ambiguous name resolves to one owner")
        else assert(indexed == sole, prefix .. "unambiguous name alias points elsewhere") end
        for id in pairs(bucket) do
            assert((type(current) == "string" and current == id) or (type(current) == "table" and current[id]), prefix .. "name owner missing")
            assert((engine.contacts[id].ambiguousIdentity == true) == ambiguous, prefix .. "contact ambiguity disagrees with index")
        end
        if type(current) == "table" then
            for id in pairs(current) do assert(bucket[id], prefix .. "stale name owner retained") end
        end
    end
    for name in pairs(engine.nameOwners) do assert(expectedNameOwners[name], prefix .. "stale name bucket retained") end
    for name, id in pairs(engine.identities) do
        if id == false then assert(expectedNameOwners[name], prefix .. "ambiguous alias lacks owners")
        else assert(engine.contacts[id], prefix .. "identity points to evicted contact") end
    end
    assert(engine.contactCount == count, prefix .. "tracked contact count disagrees with map")
    assert(RG.Util.Count(engine.identities) <= count * 2, prefix .. "alias count exceeded two per contact")
    assert(count <= engine.profile.retention.maxContacts, prefix .. "contact bound exceeded")
    assert(#engine.pending <= engine.profile.retention.maxContacts, prefix .. "pending queue bound exceeded")
    assert(#engine.history <= engine.profile.retention.maxHistory, prefix .. "history bound exceeded")
    local snapshot = engine:Snapshot()
    for _, view in ipairs(snapshot) do
        assert(view.visible == (next(engine.contacts[view.id].tokens) ~= nil), prefix .. "visible state disagrees with bindings")
    end
    H.True(true, prefix .. "invariants")
end

for _, seed in ipairs({ 1, 17, 104729, 2147483646 }) do
    local replaySeed = seed
    H.Test("deterministic lifecycle replay preserves identity invariants seed " .. seed, function()
        local RG = H.Addon(modules)
        local clock, choose = H.Clock(100), random(replaySeed)
        local engine = RG.Engine.New({ clock = clock.Now, profile = RG.Defaults.NewProfile() })
        engine.profile.retention.maxContacts, engine.profile.retention.maxHistory = 32, 20
        for step = 1, 1500 do
            local action, token = choose(10), "nameplate" .. choose(48)
            if action <= 5 then
                local player = choose(80)
                local known = choose(5) ~= 1
                local obs = { token = token, source = "nameplate", guid = known and ("Player-" .. player) or nil,
                    name = known and ("Enemy " .. (player % 30)) or nil, realm = "Realm" .. (player % 3),
                    class = RG.Defaults.classes[choose(#RG.Defaults.classes)],
                    hostile = choose(7) ~= 1, isPlayer = choose(8) ~= 1, rangeMin = choose(30), rangeMax = 40 }
                if choose(5) == 1 then obs.hostile = nil end
                if choose(5) == 1 then obs.isPlayer = nil end
                engine:Observe(obs)
            elseif action == 6 then engine:Remove(token)
            elseif action == 7 then engine:Cast(token, choose(2) == 1 and 1784 or 999999)
            elseif action == 8 then
                engine:SetContext({ kind = choose(3) == 1 and "instance" or "world", resting = choose(5) == 1 })
            elseif action == 9 then
                if choose(3) == 1 then engine:Pause(2) else engine:Resume() end
            else
                if choose(20) == 1 then engine:Clear() else clock.Advance(choose(4) / 4); engine:Tick() end
            end
            invariant(RG, engine, replaySeed, step)
        end
        engine:Clear(); clock.Advance(2000); engine:Tick()
        H.Equal(RG.Util.Count(engine.contacts), 0)
        H.Equal(RG.Util.Count(engine.identities), 0)
        H.Equal(RG.Util.Count(engine.bindings), 0)
        H.Equal(RG.Util.Count(engine.nameOwners), 0)
        H.Equal(engine.contactCount, 0)
    end)
end

H.Test("temporary unknown hostility suppresses decisions without duplicating identity", function()
    local RG = H.Addon(modules)
    local clock, alerts = H.Clock(100), {}
    local engine = RG.Engine.New({ clock = clock.Now, profile = RG.Defaults.NewProfile(), onAlert = function(d) alerts[#alerts + 1] = d end })
    local observation = { token = "nameplate1", guid = "A", name = "Enemy", class = "ROGUE", hostile = true, isPlayer = true, source = "nameplate" }
    local first = engine:Observe(observation)
    observation.hostile = nil; engine:Observe(observation)
    clock.Advance(1); engine:Tick(); H.Equal(#alerts, 0)
    observation.hostile = true
    local returned = engine:Observe(observation)
    clock.Advance(1); engine:Tick()
    H.Equal(returned.id, first.id); H.Equal(#engine:Snapshot(), 1); H.Equal(#alerts, 1)
end)

H.Test("contact eviction removes every alias and pending record of the victim", function()
    local RG = H.Addon(modules)
    local clock = H.Clock(100)
    local profile = RG.Defaults.NewProfile(); profile.retention.maxContacts = 32
    local engine = RG.Engine.New({ clock = clock.Now, profile = profile })
    local victim = engine:Observe({ token = "nameplate1", guid = "Victim", name = "Old Name", realm = "Realm", class = "ROGUE", hostile = true, isPlayer = true, source = "nameplate" })
    engine:Remove("nameplate1")
    for index = 2, 33 do
        clock.Advance(0.1)
        engine:Observe({ token = "nameplate" .. index, guid = "A" .. index, name = "Enemy " .. index, class = "ROGUE", hostile = true, isPlayer = true, source = "nameplate" })
    end
    H.Nil(engine.contacts[victim.id])
    for _, id in pairs(engine.identities) do H.True(id ~= victim.id) end
    for _, pending in ipairs(engine.pending) do H.True(pending.id ~= victim.id) end
end)
