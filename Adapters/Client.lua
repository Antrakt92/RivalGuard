local _, RG = ...
local Client = RG.Register("Client", {})
Client.__index = Client

local CLASS = {}
for _, name in ipairs(RG.Defaults.classes) do CLASS[name] = true end
function Client.New(api, diagnostics)
    local self = setmetatable({ api = api or _G, diagnostics = diagnostics }, Client)
    local _, _, _, interface = self:Safe(self.api.GetBuildInfo)
    interface = self:Number(interface)
    self.interface = interface
    self.retailStealth = interface ~= nil and interface >= 120000 and interface < 130000
    if RG.Range then self.range = RG.Range.New(self.api, self) end
    return self
end

function Client:ForgetToken(token) if self.range then self.range:Forget(token) end end
function Client:InvalidateRanges() if self.range then self.range:Invalidate() end end
function Client:InvalidateRangeSamples() if self.range then self.range:InvalidateSamples() end end

function Client:Count(key)
    if self.diagnostics and self.diagnostics.Count then self.diagnostics:Count(key) end
end

function Client:Readable(value)
    local checker = self.api.issecretvalue
    if type(checker) == "function" then
        local ok, secret = pcall(checker, value)
        if not ok or secret then self:Count("restricted_values"); return false end
    end
    return true
end

function Client:Clean(value)
    if self:Readable(value) then return value end
    return nil
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

function Client:UnitMatch(token, other)
    return self:Boolean(self:Safe(self.api.UnitIsUnit, token, other))
end

function Client:Hostile(token)
    local api = self.api
    local hostile = self:Boolean(self:Safe(api.UnitIsEnemy, "player", token))
    if hostile == nil then hostile = self:Boolean(self:Safe(api.UnitCanAttack, "player", token)) end
    return hostile
end

function Client:VisibleEnemyPlate(token, guid)
    token, guid = self:IsToken(token), self:Text(guid, 128)
    if not token or not token:match("^nameplate%d+$") or not guid then return nil end
    local api = self.api
    local manager = api.C_NamePlateManager
    if type(manager) == "table" and type(manager.IsNamePlateUnitBehindCamera) == "function"
        and self:Boolean(self:Safe(manager.IsNamePlateUnitBehindCamera, token)) ~= false then return nil end
    local frame = self:Nameplate(token)
    if not frame or self:Boolean(self:Safe(frame.IsVisible, frame)) ~= true
        or self:Boolean(self:Safe(frame.IsProtected, frame)) ~= false then return nil end
    if self:Boolean(self:Safe(api.UnitExists, token)) ~= true or self:Text(self:Safe(api.UnitGUID, token), 128) ~= guid
        or self:Boolean(self:Safe(api.UnitIsPlayer, token)) ~= true or self:Hostile(token) ~= true
        or self:Boolean(self:Safe(api.UnitIsDeadOrGhost, token)) ~= false then return nil end
    return frame
end

function Client:Names(token)
    local api = self.api
    local regional = self:Boolean(self:Safe(api.RegionalUniqueNamesEnabled))
    local unknown = self:Text(api.UNKNOWNOBJECT, 100)
    local function parts(reader)
        local first, second = self:Safe(reader, token)
        first, second = self:Text(first, 160), self:Text(second, 96)
        if not first or first == "Unknown" or first == unknown then return nil end
        if second == "Unknown" or second == unknown then second = nil end
        return first, second
    end
    if regional then
        -- Camelot NameUtil splits the first UnitName result at the surname
        -- separator. The second result identifies the server.
        local constants = api.Constants and api.Constants.CharacterNameSeparatorConsts
        local separator = constants and self:Clean(constants.CHARACTERNAME_SURNAME_SEPARATOR)
        if type(separator) ~= "string" or #separator < 1 or #separator > 8 or separator:find("[%z\1-\31\127|]") then separator = " " end
        local partial
        for _, key in ipairs({ "UnitNameUnmodified", "UnitName" }) do
            local first = parts(api[key])
            if first then
                local split = first:find(separator, 1, true)
                if (split and split > 1 and split + #separator <= #first) or first:match("^%S+%s+%S") then
                    return first, nil, true
                end
                partial = partial or first
            end
        end
        local other = parts(api.UnitFullName)
        return partial or other, nil, false
    end

    local partial
    for _, key in ipairs({ "UnitFullName", "UnitNameUnmodified", "UnitName" }) do
        local first, realm = parts(api[key])
        if first then
            partial = partial or first
            if realm then
                local suffix = "-" .. realm
                local full = self:Text(first:sub(-#suffix) == suffix and first or (first .. suffix), 160)
                if full then return full, realm, true end
            end
        end
    end
    if partial then
        local relationship = self:Number(self:Safe(api.UnitRealmRelationship, token))
        local same = self:Number(api.LE_REALM_RELATION_SAME)
        if same and relationship == same then
            local realm = self:Text(self:Safe(api.GetNormalizedRealmName), 96)
            if realm then
                local full = self:Text(partial .. "-" .. realm, 160)
                if full then return full, realm, true end
            end
        end
    end
    return partial, nil, false
end

function Client:Range(token, identity)
    local squared, checked = self:Safe(self.api.UnitDistanceSquared, token)
    squared, checked = self:Number(squared), self:Boolean(checked)
    if squared and squared >= 0 and checked == true then
        local distance = math.sqrt(squared)
        return distance, distance, false, "exact"
    end
    -- A failed interaction check does not establish an enemy's lower distance bound.
    local lower, upper, exclusive, conflict, sampledAt
    if self.range then lower, upper, exclusive, conflict, sampledAt = self.range:Measure(token, identity) end
    if conflict then return nil, nil, false, "conflict", sampledAt end
    local evidence = (lower ~= nil or upper ~= nil) and "spell" or "unknown"
    local interaction
    if self:Boolean(self:Safe(self.api.CheckInteractDistance, token, 3)) == true then interaction = 10
    elseif self:Boolean(self:Safe(self.api.CheckInteractDistance, token, 4)) == true then interaction = 28 end
    if interaction then
        lower, upper = lower or 0, math.min(upper or math.huge, interaction)
        evidence = evidence == "spell" and "combined" or "interaction"
    end
    if lower and upper and (lower > upper or (lower == upper and exclusive)) then
        self:Count("range_conflicts")
        return nil, nil, false, "conflict", sampledAt
    end
    if evidence ~= "spell" and evidence ~= "combined" then sampledAt = nil end
    return lower, upper, exclusive == true, evidence, sampledAt
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
        if not self:Readable(aura) then return nil, false end
        if aura == nil then
            if allReadable then return false, true end
            return nil, false
        end
        if type(aura) ~= "table" then return nil, false end
        local id = self:Number(self:Safe(function() return aura.spellId end))
        if id and RG.Defaults.IsStealthAura(id, self.retailStealth) then return true, true end
        if not id then allReadable = false end
    end
    return nil, false
end

function Client:ReadUnit(token, source, checkRequalifiedAura)
    token = self:IsToken(token)
    if not token then return nil end
    local api = self.api
    local exists = self:Boolean(self:Safe(api.UnitExists, token))
    if exists == false then return nil end
    local name, realm, nameComplete = self:Names(token)
    local guid = self:Text(self:Safe(api.UnitGUID, token), 128)
    local player = self:Boolean(self:Safe(api.UnitIsPlayer, token))
    if exists ~= true and not name and not guid and player ~= true then return nil end
    local hostile = self:Hostile(token)
    local observation = {
        token = token, guid = guid, name = name, nameComplete = nameComplete, realm = realm,
        hostile = hostile, isPlayer = player, source = source or "unit", stealthReadable = false,
    }
    if player == false or hostile == false then
        -- Keep owner evidence for cancellations and future changes in eligibility.
        self:ForgetToken(token)
        return observation
    end
    local _, class = self:Safe(api.UnitClass, token)
    class = self:Text(class, 20)
    if not class then class = self:Text(self:Safe(api.UnitClassBase, token), 20) end
    if not CLASS[class or ""] then class = nil end
    local level = self:Number(self:Safe(api.UnitLevel, token))
    if level and (level <= 0 or level > 1000) then level = nil end
    local rangeOwner = guid and ("guid:" .. guid) or (nameComplete and ("name:" .. name))
    observation.class, observation.level = class, level
    observation.rangeMin, observation.rangeMax, observation.rangeMinExclusive, observation.rangeEvidence, observation.rangeAt =
        self:Range(token, rangeOwner)
    -- Acquisition, aura events and the first clean return to eligibility may
    -- reveal an aura that will not emit a separate update for this token.
    if (checkRequalifiedAura and player == true and hostile == true)
        or (source ~= "poll" and source ~= "unit" and source ~= "cast") then
        observation.stealth, observation.stealthReadable = self:Stealth(token)
    end
    if token:match("^nameplate%d+$") then
        local manager = api.C_NamePlateManager
        if type(manager) == "table" then
            observation.behindCamera = self:Boolean(self:Safe(manager.IsNamePlateUnitBehindCamera, token))
        end
        observation.currentTarget = self:UnitMatch(token, "target")
        observation.currentFocus = self:UnitMatch(token, "focus")
    end
    observation.dead = self:Boolean(self:Safe(api.UnitIsDeadOrGhost, token))
    observation.targeting = self:UnitMatch(token .. "target", "player")
    return observation
end

function Client:Context()
    local api = self.api
    local inside, instance = self:Safe(api.IsInInstance)
    inside, instance = self:Boolean(inside), self:Text(instance, 30)
    local kind = "unknown"
    if (inside == false and instance and instance ~= "none") or (inside == true and instance == "none") then
        self:Count("context_conflicts")
    elseif instance == "pvp" then kind = "battleground"
    elseif instance == "arena" then kind = "arena"
    elseif inside == true or (instance and instance ~= "none") then kind = "instance"
    elseif inside == false or instance == "none" then kind = "world" end
    local pvp = api.C_PvP
    local zoneReader = type(pvp) == "table" and pvp.GetZonePVPInfo
    if type(zoneReader) ~= "function" then zoneReader = api.GetZonePVPInfo end
    local zone = self:Text(self:Safe(zoneReader), 30)
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
    return {
        interface = self.interface,
        nameplates = type(api.C_NamePlate) == "table" and type(api.C_NamePlate.GetNamePlates) == "function",
        secretValues = type(api.issecretvalue) == "function",
        auras = type(api.C_UnitAuras) == "table" and type(api.C_UnitAuras.GetAuraDataByIndex) == "function",
        distance = type(api.UnitDistanceSquared) == "function",
        behindCamera = type(api.C_NamePlateManager) == "table" and type(api.C_NamePlateManager.IsNamePlateUnitBehindCamera) == "function",
        combatLog = false,
        spellRange = self.range ~= nil and self.range:Available(),
    }
end

function Client:SupportedClasses()
    if self.supportedClasses then return RG.Util.Copy(self.supportedClasses), true end
    local api, found, count = self.api, {}, 0
    local specialization = api.C_SpecializationInfo
    local ids = type(specialization) == "table" and self:Safe(specialization.GetAllClassIDs) or nil
    local creature = api.C_CreatureInfo
    local function remember(token)
        token = self:Text(token, 20)
        if not token or not CLASS[token] then return false end
        if not found[token] then found[token], count = true, count + 1 end
        return true
    end
    if type(ids) == "table" and #ids > 0 and #ids <= 64 then
        for _, rawID in ipairs(ids) do
            local id = self:Number(rawID)
            if not id or id <= 0 or id % 1 ~= 0 then return nil, false end
            local token
            if type(creature) == "table" and type(creature.GetClassInfo) == "function" then
                local info = self:Safe(creature.GetClassInfo, id)
                if type(info) == "table" then token = self:Safe(function() return info.classFile end) end
            elseif type(api.GetClassInfo) == "function" then
                local _
                _, token = self:Safe(api.GetClassInfo, id)
            end
            if not remember(token) then return nil, false end
        end
    else
        local total = self:Number(self:Safe(api.GetNumClasses))
        if not total or total < 1 or total > 64 or total % 1 ~= 0 or type(api.GetClassInfo) ~= "function" then return nil, false end
        for index = 1, total do
            local _, token = self:Safe(api.GetClassInfo, index)
            if not remember(token) then return nil, false end
        end
    end
    if count == 0 then return nil, false end
    local result = {}
    for _, token in ipairs(RG.Defaults.classes) do if found[token] then result[#result + 1] = token end end
    self.supportedClasses = result
    return RG.Util.Copy(result), true
end
