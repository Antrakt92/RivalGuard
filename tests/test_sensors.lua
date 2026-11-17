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
        function frame:RegisterEvent(event) self.events[event] = true end
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

H.Test("sensors keep ticker independent of UI visibility and stop old frames on restart", function()
    local sensors, units, observed, _, _, frames = fixture()
    units.target = player()
    sensors:Start()
    local first = frames[1]
    local before = #observed
    first.scripts.OnUpdate(first, 0.1)
    H.Equal(#observed, before)
    first.scripts.OnUpdate(first, 0.15)
    H.True(#observed > before)
    sensors:Stop()
    H.Nil(first.scripts.OnUpdate); H.Nil(first.scripts.OnEvent); H.Nil(next(first.events))
    H.Equal(sensors.count, 0)
    sensors:Start()
    H.Equal(#frames, 2); H.True(frames[2].scripts.OnUpdate ~= nil)
    H.Nil(first.scripts.OnUpdate)
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

H.Test("sensors bound active token tracking and reject excess slots", function()
    local sensors, units = fixture()
    sensors:Start()
    for index = 1, 140 do
        local token = "nameplate" .. index
        units[token] = player("Enemy" .. index, "Player-" .. index)
        sensors:OnEvent("NAME_PLATE_UNIT_ADDED", token)
    end
    H.Equal(sensors.count, 128); H.Nil(sensors.active.nameplate129)
    sensors:Remove("nameplate1")
    sensors:OnEvent("NAME_PLATE_UNIT_ADDED", "nameplate129")
    H.Equal(sensors.count, 128); H.True(sensors.active.nameplate129 ~= nil)
end)
