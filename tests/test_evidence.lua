local H = RGTest
local function fixture()
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua" })
    local engine = RG.Engine.New()
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
