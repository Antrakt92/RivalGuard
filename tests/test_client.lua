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

H.Test("client reads sanctuary state from the supported PvP namespace", function()
    local client, api, _, secret = fixture()
    api.C_PvP = { GetZonePVPInfo = function() return "sanctuary", false end }
    H.True(client:Context().sanctuary)
    api.C_PvP.GetZonePVPInfo = function() return "contested", false end
    H.False(client:Context().sanctuary)
    api.C_PvP.GetZonePVPInfo = function() return secret, false end
    H.Nil(client:Context().sanctuary)
    api.C_PvP.GetZonePVPInfo = function() return nil end
    H.Nil(client:Context().sanctuary)
    api.C_PvP = nil
    H.False(client:Context().sanctuary)
end)

H.Test("client requests behind-camera geometry only for nameplate tokens", function()
    local client, api = fixture()
    local calls = 0
    api.C_NamePlateManager = { IsNamePlateUnitBehindCamera = function(token)
        calls = calls + 1
        assert(token == "nameplate1", "geometry requires a nameplate token")
        return false
    end }
    H.Nil(client:ReadUnit("target", "poll").behindCamera)
    H.Nil(client:ReadUnit("focus", "poll").behindCamera)
    H.Equal(calls, 0)
    H.False(client:ReadUnit("nameplate1", "poll").behindCamera)
    H.Equal(calls, 1)
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
    unit.name, unit.realm = "Альфа Фамилия", "BackendRealm"
    api.UnitName = function() return unit.name, unit.realm end
    local obs = client:ReadUnit("target", "poll")
    H.Equal(obs.name, "Альфа Фамилия"); H.Nil(obs.realm); H.True(obs.nameComplete)
    api.UnitNameUnmodified = function() return "Альфа Полная Фамилия", "Фамилия" end
    obs = client:ReadUnit("target", "poll")
    H.Equal(obs.name, "Альфа Полная Фамилия"); H.True(obs.nameComplete)
    unit.name, unit.realm = "Unknown", nil
    api.UnitNameUnmodified = nil
    H.Nil(client:ReadUnit("target", "poll").name)
end)

H.Test("client does not promote partial regional names or realm-like unknown suffixes to identity", function()
    local client, api, _, secret = fixture()
    api.RegionalUniqueNamesEnabled = function() return true end
    api.UnitNameUnmodified = function() return "Alpha", secret end
    api.UnitName = function() return "Alpha" end
    api.GetUnitName = function() return "Alpha-BogusBackend" end
    local obs = client:ReadUnit("target", "poll")
    H.Equal(obs.name, "Alpha"); H.False(obs.nameComplete); H.Nil(obs.realm)
    H.Equal(obs.guid, "Player-A")
    api.UnitNameUnmodified = function() return "Alpha", "BackendRealm" end
    api.UnitName = api.UnitNameUnmodified
    obs = client:ReadUnit("target", "poll")
    H.Equal(obs.name, "Alpha"); H.False(obs.nameComplete); H.Nil(obs.realm)
end)

H.Test("client retail names require readable realm evidence for durable fallback identity", function()
    local client, api, unit, secret = fixture()
    local obs = client:ReadUnit("target", "poll")
    H.Equal(obs.name, "Alpha-Realm"); H.Equal(obs.realm, "Realm"); H.True(obs.nameComplete)
    unit.name = "Alpha-Realm"
    H.Equal(client:ReadUnit("target", "poll").name, "Alpha-Realm")
    unit.name, unit.realm = "Alpha", secret
    obs = client:ReadUnit("target", "poll")
    H.Equal(obs.name, "Alpha"); H.False(obs.nameComplete); H.Nil(obs.realm)
    api.LE_REALM_RELATION_SAME = 1
    api.UnitRealmRelationship = function() return 1 end
    api.GetNormalizedRealmName = function() return "LocalRealm" end
    obs = client:ReadUnit("target", "poll")
    H.Equal(obs.name, "Alpha-LocalRealm"); H.Equal(obs.realm, "LocalRealm"); H.True(obs.nameComplete)
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

H.Test("client marks selected nameplates only using clean unit comparisons", function()
    local client, api, _, secret = fixture()
    api.UnitIsUnit = function(token, other)
        if token == "nameplate1" and other == "target" then return true end
        if token == "nameplate1" and other == "focus" then return false end
        if token == "nameplate1target" and other == "player" then return secret end
        error("unexpected comparison")
    end
    local obs = client:ReadUnit("nameplate1", "poll")
    H.True(obs.currentTarget); H.False(obs.currentFocus); H.Nil(obs.targeting)
    api.UnitIsUnit = function(_, other)
        if other == "focus" then error("comparison unavailable") end
        return secret
    end
    obs = client:ReadUnit("nameplate1", "poll")
    H.Nil(obs.currentTarget); H.Nil(obs.currentFocus)
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

H.Test("client class enumeration follows sparse runtime class IDs without build guesses", function()
    local client, api = fixture()
    local calls = 0
    api.C_SpecializationInfo = { GetAllClassIDs = function() return { 1, 8, 11 } end }
    api.C_CreatureInfo = { GetClassInfo = function(id)
        calls = calls + 1
        return { classFile = ({ [1] = "WARRIOR", [8] = "MAGE", [11] = "DRUID" })[id] }
    end }
    local classes, complete = client:SupportedClasses()
    H.True(complete); H.Equal(table.concat(classes, ","), "WARRIOR,MAGE,DRUID")
    classes[1] = "BROKEN"
    H.Equal(client:SupportedClasses()[1], "WARRIOR"); H.Equal(calls, 3)
end)

H.Test("client partial class enumeration remains unknown and can recover", function()
    local client, api, _, secret = fixture()
    api.C_SpecializationInfo = { GetAllClassIDs = function() return { 1 } end }
    api.C_CreatureInfo = { GetClassInfo = function() return { classFile = secret } end }
    local classes, complete = client:SupportedClasses()
    H.Nil(classes); H.False(complete)
    api.C_CreatureInfo.GetClassInfo = function() return { classFile = "WARRIOR" } end
    classes, complete = client:SupportedClasses()
    H.True(complete); H.Equal(classes[1], "WARRIOR")
end)

H.Test("client legacy class enumeration uses returned tokens and reports absent APIs unknown", function()
    local client, api = fixture()
    H.Nil(client:SupportedClasses())
    api.GetNumClasses = function() return 2 end
    api.GetClassInfo = function(index) return "Localized", index == 1 and "ROGUE" or "DRUID", index == 1 and 4 or 11 end
    local classes, complete = client:SupportedClasses()
    H.True(complete); H.Equal(table.concat(classes, ","), "ROGUE,DRUID")
end)
