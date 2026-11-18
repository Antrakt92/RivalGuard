local H = RGTest

local function fixture(realEngine)
    local modules = { "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua", "Adapters/Client.lua", "Adapters/Sensors.lua" }
    local RG = H.Addon(modules)
    local units, observed, removed, casts, frames, errors, badges = {}, {}, {}, {}, {}, {}, {}
    local secret = H.Secret("sensor field")
    local api = {
        issecretvalue = function(value) return value == secret end,
        UnitExists = function(token) return units[token] ~= nil end,
        UnitFullName = function(token) local unit = units[token]; if unit then return unit.name, unit.realm end end,
        UnitGUID = function(token) return units[token] and units[token].guid end,
        UnitClass = function(token) return "Rogue", units[token] and units[token].class end,
        UnitIsPlayer = function() return true end,
        UnitIsEnemy = function() return true end,
        UnitLevel = function() return 60 end,
        IsInInstance = function() return false, "none" end,
        SetCVar = function() error("sensors must not mutate CVars") end,
    }
    api.CreateFrame = function()
        local frame = { scripts = {}, events = {} }
        function frame:RegisterEvent(event) self.events[event] = true; return true end
        function frame:UnregisterAllEvents() self.events = {} end
        function frame:SetScript(name, fn) self.scripts[name] = fn end
        frames[#frames + 1] = frame
        return frame
    end
    local engine = {
        Observe = function(_, obs) observed[#observed + 1] = obs; return obs end,
        Remove = function(_, token) removed[#removed + 1] = token end,
        Cast = function(_, token, id) casts[#casts + 1] = { token = token, id = id } end,
        SetContext = function() end, Tick = function() end,
    }
    if realEngine then engine = RG.Engine.New() end
    local app = {
        engine = engine,
        diagnostics = { Count = function() end, Error = function(_, code) errors[#errors + 1] = code end },
        UIContactUpdated = function(_, token, obs, contact) badges[token] = { obs = obs, contact = contact } end,
        OnTokenRemoved = function(_, token) badges[token] = nil end,
    }
    local client = RG.Client.New(api, app.diagnostics)
    return RG.Sensors.New(app, client, api), units, observed, removed, casts, frames, errors, api, badges, secret, engine
end

local function player(name, guid)
    return { name = name or "Alpha", guid = guid or "Player-A", class = "ROGUE" }
end

for _, signal in ipairs({ "poll", "UNIT_AURA" }) do
    H.Test("a recycled nameplate acquires its new owner's readable stealth on " .. signal, function()
        local W = assert(loadfile(H.root .. "/tests/support/wow.lua"))()
        local state = W.New()
        local secret = H.Secret("restricted indexed aura")
        local positive, exactReads = false, 0
        state.api.GetBuildInfo = function() return "Forever", "", "", 16001 end
        state.api.C_UnitAuras = {
            GetAuraDataByIndex = function() return secret end,
            GetUnitAuraBySpellID = function(token, spellID)
                if token == "nameplate1" then exactReads = exactReads + 1 end
                if token == "nameplate1" and positive and spellID == 1784 then
                    return { isHelpful = true, spellId = spellID }
                end
            end,
        }
        local RG = state:LoadTOC()
        state:Fire("ADDON_LOADED", "RivalGuard")
        local app = RG.instance
        state:Unit("nameplate1", player("Old owner", "Player-Previous"))
        state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        positive, exactReads = true, 0
        state:Unit("nameplate1", player("New owner", "Player-Replacement"))
        if signal == "poll" then
            app.sensors:Poll()
        else
            -- This addition is untrusted after the GUID change. Only exact
            -- evidence from the current unit may establish its own stealth.
            state:Fire("UNIT_AURA", "nameplate1", { addedAuras = { { isHelpful = true, spellId = 1856 } } })
        end
        local contact = app.engine:Snapshot()[1]
        H.Equal(contact.identity, "guid:Player-Replacement")
        H.Equal(contact.stealthEvidence, "aura")
        H.True(exactReads > 0)
        local acquiredReads = exactReads
        app.sensors:Poll()
        H.Equal(exactReads, acquiredReads)
    end)
end

H.Test("event observations sample context once while polls share one snapshot", function()
    local sensors, units, _, _, casts, _, _, api, _, _, engine = fixture()
    local reads = 0
    api.IsInInstance = function() reads = reads + 1; return false, "none" end
    api.UnitIsPlayer = function(token) return units[token].isPlayer ~= false end
    engine.TracksCast = function(_, id) return id == 1856 end
    sensors:Start()
    reads = 0
    for i = 1, 6 do
        local token = "nameplate" .. i
        units[token] = player("Rival " .. i, "Player-Context-" .. i)
        sensors:OnEvent("NAME_PLATE_UNIT_ADDED", token)
        H.Equal(reads, i)
    end
    local npc = player("NPC", "Creature-Context")
    npc.isPlayer = false
    units.nameplate7 = npc
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate7")
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "untracked", 123)
    sensors:OnEvent("UNIT_TARGET", "untracked")
    H.Equal(reads, 6)
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "tracked", 1856)
    H.Equal(reads, 7); H.Equal(#casts, 1)
    sensors:Poll()
    H.Equal(reads, 8)
end)

H.Test("an unavailable mapped plate gets three scheduled retries without enumeration", function()
    local sensors, units, _, _, _, _, _, api = fixture()
    local plate, lookups, reads, scans = {}, 0, 0, 0
    api.C_NamePlate = {
        GetNamePlateForUnit = function()
            lookups = lookups + 1
            return plate
        end,
        GetNamePlates = function() scans = scans + 1; return {} end,
    }
    api.UnitExists = function(token)
        if token == "nameplate1" then reads = reads + 1 end
        return units[token] ~= nil
    end
    sensors:Start()
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(reads, 1); H.Equal(lookups, 1)
    sensors:Poll()
    H.Equal(reads, 1); H.Equal(lookups, 1)
    for _ = 1, 5 do sensors:Poll(true) end
    H.Equal(reads, 4); H.Equal(lookups, 4)
    H.Equal(scans, 1)
    H.Nil(sensors.active.nameplate1)
    H.Nil(next(sensors.plateRetries))
end)

H.Test("retry capacity cannot increase the current poll plate-read budget", function()
    local sensors, units, _, _, _, _, _, api = fixture()
    local plate, recoveredReads, activeReads = {}, 0, 0
    api.C_NamePlate = { GetNamePlateForUnit = function() return plate end }
    api.UnitIsUnit = function(token, other) return token:match("target$") ~= nil and other == "player" end
    api.UnitExists = function(token)
        if token == "nameplate999" then recoveredReads = recoveredReads + 1
        elseif token:match("^nameplate") then activeReads = activeReads + 1 end
        return units[token] ~= nil
    end
    sensors:Start()
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate999")
    H.True(sensors.plateRetries.nameplate999 ~= nil)
    for index = 1, 124 do
        local token = "nameplate" .. index
        units[token] = player("Rival " .. index, "Player-Active-" .. index)
        sensors:OnEvent("NAME_PLATE_UNIT_ADDED", token)
    end
    H.Equal(sensors.plateCount, 124)
    activeReads = 0
    for _ = 1, 3 do sensors:Poll(true) end
    H.Equal(activeReads, 124 * 3)
    H.Equal(recoveredReads, 1)
    H.True(sensors.plateRetries.nameplate999 ~= nil)

    units.nameplate999 = player("Recovered rival", "Player-Recovered")
    units.nameplate1 = nil
    sensors:OnEvent("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    activeReads = 0
    sensors:Poll(true)
    H.Equal(activeReads, 123)
    H.Equal(recoveredReads, 2)
    H.Equal(sensors.plateCount, 124)
    H.True(sensors.active.nameplate999 ~= nil)
    H.Nil(sensors.plateRetries.nameplate999)
end)

H.Test("a crowded acquisition limits exact aura reads and promptly revisits current occupants", function()
    local sensors, units, observed, _, _, _, _, api, _, secret = fixture()
    local calls, indexed, searched = 0, 0, {}
    api.C_UnitAuras = {
        GetAuraDataByIndex = function() indexed = indexed + 1; return secret end,
        GetUnitAuraBySpellID = function(token, id)
            calls = calls + 1
            searched[token] = units[token].guid
            if (token == "nameplate123" or token == "target") and id == 1784 then
                return { isHelpful = true, spellId = id }
            end
        end,
    }
    sensors:Start()
    for index = 1, 124 do
        local token = "nameplate" .. index
        units[token] = player("Rival " .. index, "Player-Crowd-" .. index)
        sensors:OnEvent("NAME_PLATE_UNIT_ADDED", token)
    end
    units.target = player("Target", "Player-Crowd-Target")
    sensors:OnEvent("PLAYER_TARGET_CHANGED")
    H.Equal(sensors.plateCount, 124)
    H.Equal(searched.target, "Player-Crowd-Target")
    H.True(calls <= 20 * 17, "burst exceeded the acquisition budget")
    H.Nil(searched.nameplate123)
    sensors:OnEvent("UNIT_AURA", "nameplate122", { isFullUpdate = false,
        addedAuras = { { isHelpful = true, spellId = 1784 } } })
    H.True(observed[#observed].stealth)
    H.Nil(searched.nameplate122)
    units.nameplate124 = nil
    sensors:OnEvent("NAME_PLATE_UNIT_REMOVED", "nameplate124")
    units.nameplate123 = player("Replacement", "Player-Crowd-Replacement")
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate123")
    for _ = 1, 12 do
        local before, beforeIndexed = calls, indexed
        sensors:Poll(true)
        H.True(calls - before <= 20 * 17, "scheduled pass exceeded the acquisition budget")
        H.True(indexed - beforeIndexed <= 16, "waiting plates repeated indexed reads after exhausting the budget")
    end
    H.Equal(searched.nameplate123, "Player-Crowd-Replacement")
    H.Nil(searched.nameplate124)
    H.Nil(searched.nameplate122)
    for index = 1, 121 do
        H.Equal(searched["nameplate" .. index], "Player-Crowd-" .. index)
    end
    local confirmed
    for _, obs in ipairs(observed) do
        if obs.guid == "Player-Crowd-Replacement" and obs.stealth == true then confirmed = obs end
    end
    H.True(confirmed ~= nil)
    local settled = calls
    for _ = 1, 4 do sensors:Poll(true) end
    H.Equal(calls, settled)
end)

H.Test("sensors never correlate casts after removal or from mismatched current owners", function()
    local sensors, units, observed, _, casts = fixture()
    units.nameplate1 = player()
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local generation = observed[#observed].generation
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", 1856)
    H.Equal(#casts, 1)
    sensors:OnEvent("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "late", 1856)
    H.Equal(#casts, 1)
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.True(observed[#observed].generation > generation)
    units.nameplate1 = player("Beta", "Player-B")
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "old", 1856)
    H.Equal(#casts, 1)
    sensors:Poll()
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "current", 1856)
    H.Equal(#casts, 2)
end)

H.Test("sensors preserve generation ownership through temporarily unreadable identity", function()
    local sensors, units, observed, removed, _, _, _, _, _, secret = fixture()
    units.nameplate1 = player()
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local generation = observed[#observed].generation
    units.nameplate1.guid, units.nameplate1.name = secret, secret
    sensors:Poll()
    H.Equal(observed[#observed].generation, generation)
    units.nameplate1 = player("Beta", "Player-B")
    sensors:Poll()
    H.True(observed[#observed].generation > generation)
    H.Equal(removed[#removed], "nameplate1")
end)

H.Test("sensors replace an old GUID when a new complete name proves discontinuity", function()
    local sensors, units, _, _, _, _, _, _, _, secret, engine = fixture(true)
    units.nameplate1 = { name = "Alpha", realm = "Realm", guid = "Player-A", class = "ROGUE" }
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local generation = sensors.active.nameplate1.generation
    units.nameplate1 = { name = "Bravo", realm = "Realm", guid = secret, class = "ROGUE" }
    sensors:OnEvent("UNIT_NAME_UPDATE", "nameplate1")
    local current = engine.contacts[engine.bindings.nameplate1.id]
    H.Equal(current.identity, "name:Bravo-Realm")
    H.True(sensors.active.nameplate1.generation > generation)
    H.Nil(sensors.active.nameplate1.guid)
    units.nameplate1.guid = "Player-B"
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast-bravo", 1856)
    current = engine.contacts[engine.bindings.nameplate1.id]
    H.Equal(current.identity, "guid:Player-B")
    H.Equal(current.stealthEvidence, "cast"); H.Equal(current.stealthSpell, "Vanish")
end)

H.Test("sensors retain ownership when equal GUIDs accompany a changed complete name", function()
    local sensors, units, observed, removed, casts = fixture()
    units.nameplate1 = { name = "Alpha", realm = "Realm", guid = "Player-A", class = "ROGUE" }
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local generation = sensors.active.nameplate1.generation
    units.nameplate1.name = "Renamed"
    sensors:OnEvent("UNIT_NAME_UPDATE", "nameplate1")
    H.Equal(observed[#observed].name, "Renamed-Realm")
    H.Equal(observed[#observed].generation, generation); H.Equal(#removed, 0)
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast-renamed", 1856)
    H.Equal(#casts, 1)
end)

H.Test("fallback cannot rejoin an unreadable previous GUID through its old full name", function()
    local sensors, units, _, _, casts, _, _, api, _, secret, engine = fixture(true)
    local create = api.CreateFrame
    api.CreateFrame = function()
        local frame = create()
        local register = frame.RegisterEvent
        frame.RegisterEvent = function(self, event)
            if event == "NAME_PLATE_UNIT_REMOVED" then return false end
            return register(self, event)
        end
        return frame
    end
    units.nameplate1 = { name = "Named", realm = "Realm", guid = "Player-Original", class = "ROGUE" }
    sensors:Start()
    H.False(sensors.nameplateEvents)
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local original = engine.bindings.nameplate1.id
    units.nameplate1.guid, units.nameplate1.class = secret, "HUNTER"
    sensors:Poll()
    local anonymous = engine.bindings.nameplate1.id
    H.True(anonymous ~= original)
    H.Equal(engine.contacts[anonymous].name, "Named-Realm")
    H.Nil(engine.contacts[anonymous].identity)
    H.Nil(next(engine.contacts[original].tokens))
    sensors:Poll()
    H.Equal(engine.bindings.nameplate1.id, anonymous)
    H.Nil(engine.contacts[anonymous].identity)
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "no-owner", 1856)
    H.Nil(engine.contacts[anonymous].stealth)

    units.nameplate1.guid = "Player-Replacement"
    sensors:Poll()
    H.Equal(engine.bindings.nameplate1.id, anonymous)
    H.Equal(engine.contacts[anonymous].identity, "guid:Player-Replacement")
    H.Equal(engine.contacts[original].identity, "guid:Player-Original")
end)

H.Test("a proven name discontinuity excludes a non-player replacement without inheriting the old GUID", function()
    local sensors, units, _, _, _, _, _, api, _, secret, engine = fixture(true)
    api.UnitIsPlayer = function(token) return units[token] and units[token].isPlayer ~= false end
    units.nameplate1 = { name = "Alpha", realm = "Realm", guid = "Player-A", class = "ROGUE" }
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local generation = sensors.active.nameplate1.generation
    units.nameplate1 = { name = "NPC", realm = "Realm", guid = secret, isPlayer = false }
    sensors:OnEvent("UNIT_NAME_UPDATE", "nameplate1")
    H.True(sensors.active.nameplate1.generation > generation)
    H.Nil(sensors.active.nameplate1.guid); H.Nil(engine.bindings.nameplate1)
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast-npc", 1856)
    H.Nil(engine.bindings.nameplate1); H.Equal(#engine.pending, 1)
    H.Equal(engine.pending[1].event, "sighting")
end)

H.Test("sensors reject restricted tokens and spell identifiers", function()
    local sensors, units, _, _, casts, _, _, _, _, secret = fixture()
    units.nameplate1 = player()
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", secret, "cast", 1856)
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", secret)
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", math.huge)
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", 1.5)
    H.Equal(#casts, 0)
end)

H.Test("sensors filter untracked casts before reading units and reuse a single owner read", function()
    local sensors, units, _, _, casts, _, errors = fixture()
    units.nameplate1 = player()
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local reads, readUnit = 0, sensors.client.ReadUnit
    function sensors.client:ReadUnit(...)
        reads = reads + 1
        return readUnit(self, ...)
    end
    function sensors.app.engine:TracksCast(id) return id == 1856 end
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "ordinary", 100)
    H.Equal(reads, 0); H.Equal(#casts, 0)
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "stealth", 1856)
    H.Equal(reads, 1); H.Equal(#casts, 1)
    sensors.app.engine.TracksCast = function() error("unexpected classifier failure") end
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "stealth", 1856)
    H.Equal(reads, 1); H.Equal(#casts, 1); H.Equal(errors[#errors], "sensor_TracksCast")
end)

H.Test("sensors do not attribute casts using a partial name without a GUID", function()
    local sensors, units, _, _, casts = fixture()
    units.nameplate1 = { name = "Alpha", class = "ROGUE" }
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", 1856)
    H.Equal(#casts, 0)
    units.nameplate1.realm = "Realm"
    sensors:Poll()
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", 1856)
    H.Equal(#casts, 1)
end)

H.Test("sensors loading transitions clear tokens and suspend observations", function()
    local sensors, units, _, _, casts, _, _, _, badges = fixture()
    units.nameplate1 = player()
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.True(badges.nameplate1 ~= nil)
    sensors:OnEvent("PLAYER_LEAVING_WORLD")
    H.Equal(sensors.count, 0); H.True(sensors.loading); H.Nil(badges.nameplate1)
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "cast", 1856)
    H.Equal(sensors.count, 0); H.Equal(#casts, 0)
    sensors:OnEvent("PLAYER_ENTERING_WORLD")
    H.False(sensors.loading)
end)

H.Test("sensors reuse one independent ticker across repeated disable and enable cycles", function()
    local sensors, units, observed, _, _, frames = fixture()
    units.target = player()
    local invalidated = 0
    sensors.client.InvalidateRanges = function() invalidated = invalidated + 1 end
    sensors:Start()
    local first = frames[1]
    local before = #observed
    first.scripts.OnUpdate(first, 0.1)
    H.Equal(#observed, before)
    first.scripts.OnUpdate(first, 0.15)
    H.True(#observed > before)
    for cycle = 1, 32 do
        local update, onEvent = first.scripts.OnUpdate, first.scripts.OnEvent
        sensors:Stop(); sensors:Stop()
        H.Nil(first.scripts.OnUpdate); H.Nil(first.scripts.OnEvent); H.Nil(next(first.events))
        H.Equal(sensors.count, 0)
        before = #observed
        update(first, 1)
        onEvent(first, "PLAYER_TARGET_CHANGED")
        H.Equal(#observed, before)
        H.True(sensors:Start()); H.True(sensors:Start())
        H.Equal(#frames, 1); H.Equal(sensors.frame, first)
        H.True(first.scripts.OnUpdate ~= nil); H.True(first.events.PLAYER_TARGET_CHANGED)
        H.Equal(invalidated, cycle)
    end
end)

H.Test("sensors seed only nonforbidden nameplates and never change CVars", function()
    local sensors, units, observed, _, _, _, _, api = fixture()
    units.nameplate1, units.nameplate2, units.nameplate3 = player(), player("Beta", "Player-B"), player("Gamma", "Player-C")
    api.C_NamePlate = { GetNamePlates = function() return {
        { namePlateUnitToken = "nameplate1", IsForbidden = function() return true end },
        { namePlateUnitToken = "nameplate2", IsForbidden = function() error("forbidden") end },
        { namePlateUnitToken = "nameplate3", IsForbidden = function() return false end },
    } end }
    sensors:Start()
    H.Nil(sensors.active.nameplate1); H.Nil(sensors.active.nameplate2)
    H.True(sensors.active.nameplate3 ~= nil)
    H.True(#observed >= 1)
end)

H.Test("sensors registration failures and engine errors remain diagnostic", function()
    local sensors, units, _, _, _, _, errors, api = fixture()
    units.target = player()
    local original = api.CreateFrame
    api.CreateFrame = function()
        local frame = original()
        frame.RegisterEvent = function() error("unsupported event") end
        return frame
    end
    sensors.app.engine.Observe = function() error("bad observer") end
    H.True(sensors:Start())
    H.True(#errors >= 1)
    H.Equal(errors[1], "sensor_Observe")
    sensors:Stop()
end)

H.Test("sensors behind-camera events preserve clean false and true flags", function()
    local sensors, units, observed = fixture()
    units.nameplate1 = player()
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    sensors:OnEvent("NAME_PLATE_UNIT_BEHIND_CAMERA_CHANGED", "nameplate1", false)
    H.False(observed[#observed].behindCamera)
    sensors:OnEvent("NAME_PLATE_UNIT_BEHIND_CAMERA_CHANGED", "nameplate1", true)
    H.True(observed[#observed].behindCamera)
end)

H.Test("sensors check auras once when clean faction evidence qualifies a known token", function()
    local sensors, units, _, _, _, _, _, api, badges, secret, engine = fixture(true)
    local reads, hostility = 0, false
    api.UnitIsEnemy = function() return hostility end
    api.C_UnitAuras = { GetAuraDataByIndex = function()
        reads = reads + 1
        return { spellId = 1784 }
    end }
    units.nameplate1 = player()
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(reads, 0); H.True(sensors.active.nameplate1 ~= nil)
    H.Equal(#engine.pending, 0)
    hostility = secret
    sensors:OnEvent("UNIT_FACTION", "nameplate1")
    H.Equal(reads, 0); H.Equal(#engine.pending, 0)
    hostility = true
    sensors:OnEvent("UNIT_FACTION", "nameplate1")
    H.Equal(reads, 1); H.Equal(badges.nameplate1.contact.stealthEvidence, "aura")
    H.Equal(#engine.pending, 1); H.Equal(engine.pending[1].event, "stealth")
    sensors:Poll()
    H.Equal(reads, 1)
end)

H.Test("sensors preserve same-owner cancellation when a player becomes nonhostile", function()
    local sensors, units, _, _, _, _, _, api, badges, _, engine = fixture(true)
    local hostility = true
    api.UnitIsEnemy = function() return hostility end
    units.nameplate1 = player()
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(#engine.pending, 1)
    hostility = false
    sensors:OnEvent("UNIT_FACTION", "nameplate1")
    H.Equal(#engine.pending, 0)
    H.False(engine:Snapshot()[1].hostile); H.Nil(badges.nameplate1.contact)
end)

H.Test("one GUID on several tokens merges into a single engine contact", function()
    local sensors, units, _, _, _, _, _, _, _, _, engine = fixture(true)
    units.target, units.focus, units.nameplate1 = player(), player(), player()
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.Equal(#engine:Snapshot(), 1)
    H.True(engine:Snapshot()[1].visible)
    sensors:Remove("target"); sensors:Remove("focus")
    H.True(engine:Snapshot()[1].visible)
    sensors:Remove("nameplate1")
    H.False(engine:Snapshot()[1].visible)
end)

H.Test("sensors reserve direct token slots within the total capacity", function()
    local sensors, units = fixture()
    sensors:Start()
    for index = 1, 140 do
        local token = "nameplate" .. index
        units[token] = player("Enemy" .. index, "Player-" .. index)
        sensors:OnEvent("NAME_PLATE_UNIT_ADDED", token)
    end
    H.Equal(sensors.count, 124); H.Nil(sensors.active.nameplate125)
    units.target = player("Active Target", "Player-T")
    sensors:OnEvent("PLAYER_TARGET_CHANGED")
    H.True(sensors.active.target ~= nil)
    units.focus = player("Focus Target", "Player-F")
    units.mouseover = player("Mouseover Target", "Player-M")
    units.softenemy = player("Soft Enemy", "Player-S")
    sensors:Poll()
    H.True(sensors.active.focus ~= nil); H.True(sensors.active.mouseover ~= nil); H.True(sensors.active.softenemy ~= nil)
    H.Equal(sensors.count, 128)
    sensors:Remove("nameplate1")
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate129")
    H.Equal(sensors.count, 128); H.True(sensors.active.nameplate129 ~= nil)
end)

H.Test("capacity recovery admits queued plates inside the scheduled read budget", function()
    local sensors, units, _, _, _, _, _, api = fixture()
    local frame, scans, reads, mappings = {}, 0, 0, {}
    api.C_NamePlate = {
        GetNamePlates = function() scans = scans + 1; return {} end,
        GetNamePlateForUnit = function(token) mappings[#mappings + 1] = token; return frame end,
    }
    api.UnitIsUnit = function(token, other) return token:match("target$") ~= nil and other == "player" end
    api.UnitExists = function(token)
        if token:match("^nameplate") then reads = reads + 1 end
        return units[token] ~= nil
    end
    sensors:Start()
    for index = 1, 126 do
        local token = "nameplate" .. index
        units[token] = player("Rival " .. index, "Player-Deferred-" .. index)
        sensors:OnEvent("NAME_PLATE_UNIT_ADDED", token)
    end
    H.Equal(reads, 124)
    H.Equal(#sensors.deferredPlates, 2)
    sensors:Poll(true)
    H.Equal(reads, 248)
    H.Equal(#mappings, 0)
    sensors:OnEvent("NAME_PLATE_UNIT_REMOVED", "nameplate125")
    units.nameplate1 = nil
    sensors:OnEvent("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    reads = 0
    sensors:Poll(true)
    H.Equal(reads, 124)
    H.Equal(scans, 1)
    H.Equal(table.concat(mappings, ","), "nameplate126")
    H.Equal(sensors.plateCount, 124)
    H.True(sensors.active.nameplate126 ~= nil)
    H.Nil(sensors.active.nameplate125)
    H.Equal(#sensors.deferredPlates, 0)
end)

H.Test("sensors spread ordinary plate reads across four ticks and keep active threat responsive", function()
    local sensors, units, observed, _, _, frames, _, api = fixture()
    local calls, targeting = 0, false
    api.UnitGUID = function(token) calls = calls + 1; return units[token].guid end
    api.UnitIsUnit = function(token, other) return token == "nameplate1target" and other == "player" and targeting end
    sensors:Start()
    for index = 1, 124 do
        local token = "nameplate" .. index
        units[token] = player("Enemy" .. index, "Player-" .. index)
        sensors:OnEvent("NAME_PLATE_UNIT_ADDED", token)
    end
    calls = 0
    local update = frames[1].scripts.OnUpdate
    for tick = 1, 4 do
        update(frames[1], 0.25)
        H.Equal(calls, tick * 31)
    end
    targeting = true
    sensors:OnEvent("UNIT_TARGET", "nameplate1")
    H.True(observed[#observed].targeting)
    calls = 0
    for _ = 1, 4 do update(frames[1], 0.25) end
    H.Equal(calls, 127)
end)

H.Test("sensors refresh new and previous badge selections by the next tick", function()
    local sensors, units, _, _, _, frames, _, api, badges = fixture()
    local selected = "nameplate1"
    api.UnitIsUnit = function(token, other) return other == "target" and selected == token end
    units.target, units.nameplate1, units.nameplate2 = player(), player(), player("Other", "Player-B")
    sensors:Start()
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate2")
    H.True(badges.nameplate1.obs.currentTarget); H.False(badges.nameplate2.obs.currentTarget)
    selected = "nameplate2"
    units.target = units.nameplate2
    sensors:OnEvent("PLAYER_TARGET_CHANGED")
    frames[1].scripts.OnUpdate(frames[1], 0.25)
    H.False(badges.nameplate1.obs.currentTarget); H.True(badges.nameplate2.obs.currentTarget)
end)

H.Test("sensors refresh merged badge selections when direct unit comparisons are restricted", function()
    local sensors, units, _, _, _, frames, _, _, badges = fixture(true)
    units.target = player()
    units.nameplate1 = player("Other", "Player-B")
    units.nameplate2 = player()
    units.nameplate3 = player("Third", "Player-C")
    sensors:Start()
    for index = 1, 3 do sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate" .. index) end
    H.True(badges.nameplate2.contact.currentTarget)
    H.False(badges.nameplate3.contact.currentTarget == true)
    units.target = units.nameplate3
    sensors:OnEvent("PLAYER_TARGET_CHANGED")
    frames[1].scripts.OnUpdate(frames[1], 0.25)
    H.False(badges.nameplate2.contact.currentTarget == true)
    H.True(badges.nameplate3.contact.currentTarget)
end)

H.Test("sensors invalidate samples immediately and after synchronous restriction transitions", function()
    local sensors, units, observed, _, _, frames = fixture()
    local invalidated, metadata = 0, 0
    sensors.client.InvalidateRangeSamples = function() invalidated = invalidated + 1 end
    sensors.client.InvalidateRanges = function() metadata = metadata + 1 end
    units.nameplate1 = player()
    sensors:Start(); sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local before = #observed
    sensors:OnEvent("ADDON_RESTRICTION_STATE_CHANGED", 1, 1)
    sensors:OnEvent("PLAYER_REGEN_DISABLED")
    H.Equal(invalidated, 2); H.Equal(#observed, before)
    frames[1].scripts.OnUpdate(frames[1], 0.25)
    H.Equal(invalidated, 3); H.Equal(#observed, before + 1)
    sensors:OnEvent("ZONE_CHANGED_INDOORS")
    sensors:OnEvent("SHARD_TRANSFER_IMMINENT")
    sensors:OnEvent("SHARD_TRANSFER_CANCELLED")
    H.Equal(invalidated, 6); H.Equal(metadata, 0)
    sensors:OnEvent("PLAYER_EQUIPMENT_CHANGED")
    H.Equal(metadata, 1)
end)

H.Test("sensors discard old shard bindings before reacquiring current nameplates", function()
    local sensors, units, observed, _, casts, frames, _, api = fixture()
    api.C_NamePlate = { GetNamePlates = function() return { { namePlateUnitToken = "nameplate1" } } end }
    units.nameplate1 = player()
    sensors:Start()
    local generation = observed[#observed].generation
    sensors:OnEvent("SHARD_TRANSFER")
    sensors:OnEvent("UNIT_SPELLCAST_SUCCEEDED", "nameplate1", "late", 1856)
    H.Equal(sensors.count, 0); H.Equal(#casts, 0)
    units.nameplate1 = player("Other", "Player-B")
    frames[1].scripts.OnUpdate(frames[1], 0.25)
    H.Equal(sensors.count, 1); H.Equal(observed[#observed].guid, "Player-B")
    H.True(observed[#observed].generation > generation)
end)

H.Test("sensors signal world boundaries once while keeping ordinary zone changes local", function()
    local sensors, units, _, _, _, _, errors = fixture()
    local calls = 0
    function sensors.app:OnWorldChanged()
        calls = calls + 1
        H.Equal(self, sensors.app)
        H.Equal(sensors.count, 0)
    end
    units.target = player()
    sensors:Start()
    sensors:OnEvent("ZONE_CHANGED_NEW_AREA")
    H.Equal(calls, 0); H.Equal(sensors.count, 1)
    sensors:OnEvent("PLAYER_LEAVING_WORLD")
    H.Equal(calls, 1)
    sensors:OnEvent("SHARD_TRANSFER")
    H.Equal(calls, 1)
    sensors:OnEvent("PLAYER_ENTERING_WORLD")
    H.Equal(calls, 1); H.Equal(sensors.count, 1)
    sensors:OnEvent("SHARD_TRANSFER")
    H.Equal(calls, 2)
    sensors.app.OnWorldChanged = function() error("bad world listener") end
    sensors:OnEvent("PLAYER_LEAVING_WORLD")
    H.Equal(errors[#errors], "sensor_world_changed")
end)
