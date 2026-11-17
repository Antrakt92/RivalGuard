local _, RG = ...
local Client = RG.Register("Client", {})
Client.__index = Client

local CLASS = {}
for _, name in ipairs(RG.Defaults.classes) do CLASS[name] = true end
local STEALTH = {
    [1784] = true, [1785] = true, [1786] = true, [1787] = true,
    [5215] = true, [6783] = true, [9913] = true,
    [1856] = true, [1857] = true, [11327] = true, [11329] = true,
    [20580] = true, [58984] = true, [66] = true, [3680] = true, [11392] = true,
}

function Client.New(api, diagnostics)
    return setmetatable({ api = api or _G, diagnostics = diagnostics }, Client)
end

function Client:Count(key)
    if self.diagnostics and self.diagnostics.Count then self.diagnostics:Count(key) end
end

function Client:Clean(value)
    local checker = self.api.issecretvalue
    if type(checker) == "function" then
        local ok, secret = pcall(checker, value)
        if not ok or secret then self:Count("restricted_values"); return nil end
    end
    return value
end

-- Validate each return independently: one restricted field must not discard clean metadata.
function Client:Safe(reader, ...)
    if type(reader) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(reader, ...)
    if not ok then self:Count("api_errors"); return nil end
    return self:Clean(a), self:Clean(b), self:Clean(c), self:Clean(d)
end

function Client:Boolean(value)
    value = self:Clean(value)
    if type(value) ~= "boolean" then return nil end
    local ok, result = pcall(function() return value == true end)
    if ok then return result end
    return nil
end

function Client:Text(value, maximum)
    value = self:Clean(value)
    if type(value) ~= "string" then return nil end
    local ok, result = pcall(RG.Util.Text, value, maximum)
    if ok then return result end
    return nil
end

function Client:Number(value)
    value = self:Clean(value)
    local ok, finite = pcall(RG.Util.IsFinite, value)
    if ok and finite then return value end
    return nil
end

function Client:IsToken(value)
    value = self:Text(value, 40)
    if not value then return nil end
    if value == "target" or value == "focus" or value == "mouseover" or value == "softenemy" then return value end
    if value:match("^nameplate%d+$") then return value end
    return nil
end

function Client:Nameplate(token)
    token = self:IsToken(token)
    local ns = self.api.C_NamePlate
    if not token or type(ns) ~= "table" then return nil end
    local frame = self:Safe(ns.GetNamePlateForUnit, token, false)
    if not frame then return nil end
    if type(frame.IsForbidden) == "function" then
        local forbidden = self:Boolean(self:Safe(frame.IsForbidden, frame))
        if forbidden ~= false then return nil end
    end
    return frame
end

function Client:Names(token)
    local api = self.api
    local regional = self:Boolean(self:Safe(api.RegionalUniqueNamesEnabled))
    local first, second = self:Safe(api.UnitFullName, token)
    first, second = self:Text(first, 100), self:Text(second, 100)
    if not first then
        first, second = self:Safe(api.UnitName, token)
        first, second = self:Text(first, 100), self:Text(second, 100)
    end
    local unknown = self:Text(api.UNKNOWNOBJECT, 100)
    if first == "Unknown" or first == unknown then first, second = nil, nil end
    if regional then
        local full = self:Text(self:Safe(api.GetUnitName, token, true), 200)
        if full == "Unknown" or full == unknown then full = nil end
        if full and full:find(" ", 1, true) then return full end
        if first and second then return first .. " " .. second end
        return full or first
    end
    if first and second then return first .. "-" .. second, second end
    return first
end

function Client:Range(token)
    local squared, checked = self:Safe(self.api.UnitDistanceSquared, token)
    squared, checked = self:Number(squared), self:Boolean(checked)
    if squared and squared >= 0 and checked == true then
        local distance = math.sqrt(squared)
        return distance, distance
    end
    -- A failed interaction check does not establish an enemy's lower distance bound.
    if self:Boolean(self:Safe(self.api.CheckInteractDistance, token, 3)) == true then return 0, 10 end
    if self:Boolean(self:Safe(self.api.CheckInteractDistance, token, 4)) == true then return 0, 28 end
    return nil, nil
end

function Client:Stealth(token)
    local api, ns = self.api, self.api.C_UnitAuras
    if type(ns) ~= "table" or type(ns.GetAuraDataByIndex) ~= "function" then return nil, false end
    local secrecy = api.C_Secrets
    local unrestricted
    if type(secrecy) == "table" then unrestricted = self:Boolean(self:Safe(secrecy.ShouldAurasBeSecret)) == false end
    if type(api.issecretvalue) ~= "function" then unrestricted = true end
    local allReadable = unrestricted == true
    for index = 1, 40 do
        local ok, aura = pcall(ns.GetAuraDataByIndex, token, index, "HELPFUL")
        if not ok then self:Count("aura_errors"); return nil, false end
        local cleanAura = self:Clean(aura)
        if cleanAura == nil then
            local emptyOK, empty = pcall(function() return aura == nil end)
            if emptyOK and empty and allReadable then return false, true end
            return nil, false
        end
        aura = cleanAura
        if type(aura) ~= "table" then return nil, false end
        local id = self:Number(self:Safe(function() return aura.spellId end))
        if id and STEALTH[id] then return true, true end
        if not id then allReadable = false end
    end
    return nil, false
end

function Client:ReadUnit(token, source)
    token = self:IsToken(token)
    if not token then return nil end
    local api = self.api
    local exists = self:Boolean(self:Safe(api.UnitExists, token))
    if exists == false then return nil end
    local name, realm = self:Names(token)
    local guid = self:Text(self:Safe(api.UnitGUID, token), 128)
    local player = self:Boolean(self:Safe(api.UnitIsPlayer, token))
    if exists ~= true and not name and not guid and player ~= true then return nil end
    local _, class = self:Safe(api.UnitClass, token)
    class = self:Text(class, 20)
    if not class then class = self:Text(self:Safe(api.UnitClassBase, token), 20) end
    if not CLASS[class or ""] then class = nil end
    local hostile = self:Boolean(self:Safe(api.UnitIsEnemy, "player", token))
    if hostile == nil then hostile = self:Boolean(self:Safe(api.UnitCanAttack, "player", token)) end
    local level = self:Number(self:Safe(api.UnitLevel, token))
    if level and (level <= 0 or level > 1000) then level = nil end
    local rangeMin, rangeMax = self:Range(token)
    local manager = api.C_NamePlateManager
    local behind
    if type(manager) == "table" then behind = self:Boolean(self:Safe(manager.IsNamePlateUnitBehindCamera, token)) end
    local stealth, readable
    -- Aura scans are event-driven; the regular identity poll does not walk 40 buffs per unit.
    if source ~= "poll" then stealth, readable = self:Stealth(token) end
    return {
        token = token, guid = guid, name = name, realm = realm, class = class, level = level,
        hostile = hostile, isPlayer = player, source = source or "unit",
        dead = self:Boolean(self:Safe(api.UnitIsDeadOrGhost, token)),
        rangeMin = rangeMin, rangeMax = rangeMax,
        targeting = self:Boolean(self:Safe(api.UnitIsUnit, token .. "target", "player")),
        stealth = stealth, stealthReadable = readable == true, behindCamera = behind,
    }
end

function Client:Context()
    local api = self.api
    local _, instance = self:Safe(api.IsInInstance)
    instance = self:Text(instance, 30)
    local kind = "world"
    if instance == "pvp" then kind = "battleground"
    elseif instance == "arena" then kind = "arena"
    elseif instance and instance ~= "none" then kind = "instance" end
    local zone = self:Text(self:Safe(api.GetZonePVPInfo), 30)
    local sanctuary
    if zone then sanctuary = zone == "sanctuary" end
    return {
        kind = kind,
        sanctuary = sanctuary,
        resting = self:Boolean(self:Safe(api.IsResting)),
        flight = self:Boolean(self:Safe(api.UnitOnTaxi, "player")),
        combat = self:Boolean(self:Safe(api.InCombatLockdown)),
    }
end

function Client:Capabilities()
    local api = self.api
    local _, _, _, interface = self:Safe(api.GetBuildInfo)
    interface = self:Number(interface)
    return {
        interface = interface,
        nameplates = type(api.C_NamePlate) == "table" and type(api.C_NamePlate.GetNamePlates) == "function",
        secretValues = type(api.issecretvalue) == "function",
        auras = type(api.C_UnitAuras) == "table" and type(api.C_UnitAuras.GetAuraDataByIndex) == "function",
        distance = type(api.UnitDistanceSquared) == "function",
        behindCamera = type(api.C_NamePlateManager) == "table" and type(api.C_NamePlateManager.IsNamePlateUnitBehindCamera) == "function",
        combatLog = false,
    }
end
