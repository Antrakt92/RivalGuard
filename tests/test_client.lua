local H = RGTest

local function fixture()
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Adapters/Client.lua" })
    local secret = H.Secret("client field")
    local counts, unit = {}, { name = "Alpha", realm = "Realm", guid = "Player-A", class = "ROGUE" }
    local api = {
        issecretvalue = function(value) return value == secret end,
        UnitExists = function() return true end,
        UnitFullName = function() return unit.name, unit.realm end,
        UnitGUID = function() return unit.guid end,
        UnitClass = function() return "Rogue", unit.class end,
        UnitIsPlayer = function() return true end,
        UnitIsEnemy = function() return true end,
        UnitLevel = function() return 60 end,
        UnitIsUnit = function() return false end,
        IsInInstance = function() return false, "none" end,
        GetZonePVPInfo = function() return "contested" end,
    }
    local diagnostics = { Count = function(_, key) counts[key] = (counts[key] or 0) + 1 end }
    return RG.Client.New(api, diagnostics), api, unit, secret, counts
end

H.Test("client sanitizes each return independently without stringifying secrets", function()
    local client, _, _, secret, counts = fixture()
    local first, second = client:Safe(function() return secret, "clean" end)
    H.Nil(first); H.Equal(second, "clean")
    H.Nil(client:Text(secret)); H.Nil(client:Number(secret)); H.Nil(client:Boolean(secret))
    H.True(counts.restricted_values >= 4)
    H.Nil(client:ReadUnit(secret, "target"))
end)

H.Test("client retains anonymous players when individual identity fields are restricted", function()
    local client, api, unit, secret = fixture()
    unit.name, unit.guid, unit.class = secret, secret, secret
    api.UnitClass = function() return secret, "MAGE" end
    local obs = client:ReadUnit("nameplate1", "poll")
    H.True(obs ~= nil); H.Nil(obs.guid); H.Nil(obs.name)
    H.Equal(obs.class, "MAGE"); H.True(obs.isPlayer); H.True(obs.hostile)
    api.UnitExists = function() return secret end
    H.True(client:ReadUnit("nameplate1", "poll") ~= nil)
    api.UnitIsPlayer = function() return secret end
    H.Nil(client:ReadUnit("target", "poll"))
end)

H.Test("client API exceptions degrade to unknown while clean metadata survives", function()
    local client, api = fixture()
    api.UnitGUID = function() error("unavailable") end
    api.UnitIsEnemy = function() error("restricted") end
    api.UnitCanAttack = function() return true end
    api.UnitIsUnit = function() error("not comparable") end
    local obs = client:ReadUnit("target", "poll")
    H.Nil(obs.guid); H.True(obs.hostile); H.Nil(obs.targeting)
    H.Equal(obs.name, "Alpha-Realm")
    api.issecretvalue = function() error("checker unavailable") end
    H.Nil(client:Text("must not bypass failed checker"))
end)

H.Test("client distinguishes false from unknown in context and camera state", function()
    local client, api, _, secret = fixture()
    api.IsResting = function() return false end
    api.UnitOnTaxi = function() return secret end
    api.InCombatLockdown = function() return true end
    api.C_NamePlateManager = { IsNamePlateUnitBehindCamera = function() return false end }
    local context = client:Context()
    H.Equal(context.kind, "world"); H.False(context.sanctuary); H.False(context.resting)
    H.Nil(context.flight); H.True(context.combat)
    H.False(client:ReadUnit("nameplate1", "poll").behindCamera)
    for instance, expected in pairs({ pvp = "battleground", arena = "arena", party = "instance", raid = "instance" }) do
        api.IsInInstance = function() return true, instance end
        H.Equal(client:Context().kind, expected)
    end
end)

H.Test("client range requires successful finite evidence and preserves uncertainty", function()
    local client, api, _, secret = fixture()
    api.UnitDistanceSquared = function() return 0, false end
    H.Nil(client:ReadUnit("target", "poll").rangeMax)
    api.UnitDistanceSquared = function() return 400, true end
    local obs = client:ReadUnit("target", "poll")
    H.Equal(obs.rangeMin, 20); H.Equal(obs.rangeMax, 20)
    for _, bad in ipairs({ math.huge, -1, secret, 0 / 0 }) do
        api.UnitDistanceSquared = function() return bad, true end
        H.Nil(client:ReadUnit("target", "poll").rangeMax)
    end
    api.UnitDistanceSquared = function() error("unsupported") end
    api.CheckInteractDistance = function(_, index) return index == 4 end
    obs = client:ReadUnit("target", "poll")
    H.Equal(obs.rangeMin, 0); H.Equal(obs.rangeMax, 28)
    api.CheckInteractDistance = function() return false end
    obs = client:ReadUnit("target", "poll")
    H.Nil(obs.rangeMin); H.Nil(obs.rangeMax)
end)

H.Test("client names preserve regional surnames and reject placeholder identity", function()
    local client, api, unit = fixture()
    api.RegionalUniqueNamesEnabled = function() return true end
    unit.name, unit.realm = "Альфа", "Фамилия"
    local obs = client:ReadUnit("target", "poll")
    H.Equal(obs.name, "Альфа Фамилия"); H.Nil(obs.realm)
    api.GetUnitName = function() return "Альфа Полная Фамилия" end
    H.Equal(client:ReadUnit("target", "poll").name, "Альфа Полная Фамилия")
    unit.name, unit.realm = "Unknown", nil
    api.GetUnitName = function() return "Unknown" end
    H.Nil(client:ReadUnit("target", "poll").name)
end)

H.Test("client aura evidence distinguishes positive absent restricted and failed reads", function()
    local client, api, _, secret = fixture()
    api.C_UnitAuras = { GetAuraDataByIndex = function() return { spellId = 1784 } end }
    local stealth, readable = client:Stealth("target")
    H.True(stealth); H.True(readable)
    api.C_UnitAuras.GetAuraDataByIndex = function() return nil end
    stealth, readable = client:Stealth("target")
    H.Nil(stealth); H.False(readable)
    api.C_Secrets = { ShouldAurasBeSecret = function() return false end }
    stealth, readable = client:Stealth("target")
    H.False(stealth); H.True(readable)
    api.C_UnitAuras.GetAuraDataByIndex = function() return secret end
    stealth, readable = client:Stealth("target")
    H.Nil(stealth); H.False(readable)
    api.C_UnitAuras.GetAuraDataByIndex = function(_, index) if index == 1 then return { spellId = secret } end end
    stealth, readable = client:Stealth("target")
    H.Nil(stealth); H.False(readable)
    api.C_UnitAuras.GetAuraDataByIndex = function() error("restricted aura") end
    stealth, readable = client:Stealth("target")
    H.Nil(stealth); H.False(readable)
end)

H.Test("client regular polling does not walk aura lists", function()
    local client, api = fixture()
    local queried = 0
    api.C_UnitAuras = { GetAuraDataByIndex = function() queried = queried + 1; return { spellId = 1784 } end }
    local obs = client:ReadUnit("target", "poll")
    H.Equal(queried, 0); H.Nil(obs.stealth); H.False(obs.stealthReadable)
    obs = client:ReadUnit("target", "aura")
    H.Equal(queried, 1); H.True(obs.stealth); H.True(obs.stealthReadable)
end)

H.Test("client never returns forbidden nameplate frames", function()
    local client, api = fixture()
    local includeForbidden
    local frame = { IsForbidden = function() return true end }
    api.C_NamePlate = { GetNamePlateForUnit = function(_, include) includeForbidden = include; return frame end }
    H.Nil(client:Nameplate("nameplate1")); H.False(includeForbidden)
    frame.IsForbidden = function() error("cannot inspect") end
    H.Nil(client:Nameplate("nameplate1"))
    frame.IsForbidden = function() return false end
    H.Equal(client:Nameplate("nameplate1"), frame)
    H.Nil(client:Nameplate("not_a_token"))
end)

H.Test("client rejects invalid class values and nonpositive levels", function()
    local client, api, unit = fixture()
    unit.class = "NOTACLASS"
    api.UnitLevel = function() return -1 end
    local obs = client:ReadUnit("target", "poll")
    H.Nil(obs.class); H.Nil(obs.level)
    api.UnitExists = function() return false end
    H.Nil(client:ReadUnit("target", "poll"))
end)

H.Test("client death evidence preserves confirmed alive dead and unknown states", function()
    local client, api, _, secret = fixture()
    api.UnitIsDeadOrGhost = function() return false end
    H.False(client:ReadUnit("target", "poll").dead)
    api.UnitIsDeadOrGhost = function() return true end
    H.True(client:ReadUnit("target", "poll").dead)
    api.UnitIsDeadOrGhost = function() return secret end
    H.Nil(client:ReadUnit("target", "poll").dead)
    api.UnitIsDeadOrGhost = function() error("restricted death state") end
    H.Nil(client:ReadUnit("target", "poll").dead)
end)
