local _, RG = ...
local U, D, Rules = RG.Util, RG.Defaults, RG.Rules
local E = RG.Register("Engine", {})
E.__index = E
local MAX_PENDING_AGE = 5
local EVICTED_ENCOUNTER_LIMIT = 512
local MAX_RANGE_AGE = 2
local RANGE_EVIDENCE = { exact = true, spell = true, interaction = true, combined = true, conflict = true, unknown = true }

local SPELLS = {
    [1784] = "Stealth", [1785] = "Stealth", [1786] = "Stealth", [1787] = "Stealth", [8822] = "Stealth",
    [5215] = "Prowl", [6783] = "Prowl", [9913] = "Prowl",
    [1856] = "Vanish", [1857] = "Vanish", [11327] = "Vanish", [11329] = "Vanish",
    [20580] = "Shadowmeld", [58984] = "Shadowmeld", [66] = "Invisibility", [3680] = "Invisibility", [11392] = "Invisibility",
}

local function boolean(value) if type(value) == "boolean" then return value end end
local function safeObservation(obs)
    if type(obs) ~= "table" then return nil end
    local token = U.Text(obs.token, 64)
    if not token or not token:match("^[%w_]+$") then return nil end
    local clean = {
        token = token, source = U.Text(obs.source, 32) or "unit", guid = U.Text(obs.guid, 128),
        name = U.Text(obs.name, 160), realm = U.Text(obs.realm, 96),
        nameComplete = obs.nameComplete ~= false,
        class = D.classSet[obs.class] and obs.class or nil,
        level = U.IsFinite(obs.level) and math.floor(U.Clamp(obs.level, 1, 999, 1)) or nil,
        hostile = boolean(obs.hostile), isPlayer = boolean(obs.isPlayer),
        targeting = boolean(obs.targeting), stealth = boolean(obs.stealth),
        currentTarget = boolean(obs.currentTarget), currentFocus = boolean(obs.currentFocus),
        dead = boolean(obs.dead),
        stealthReadable = obs.stealthReadable == true,
        behindCamera = boolean(obs.behindCamera),
        rangeMinExclusive = obs.rangeMinExclusive == true,
        rangeEvidence = RANGE_EVIDENCE[obs.rangeEvidence] and obs.rangeEvidence or nil,
        rangeAt = U.IsFinite(obs.rangeAt) and obs.rangeAt >= 0 and obs.rangeAt or nil,
    }
    if clean.source == "poll" or clean.source == "cast" or clean.source == "aura" or clean.source == "unit" then
        clean.source = token:match("^nameplate%d+$") and "nameplate" or token
    end
    if U.IsFinite(obs.rangeMin) and obs.rangeMin >= 0 and obs.rangeMin <= 10000 then clean.rangeMin = obs.rangeMin end
    if U.IsFinite(obs.rangeMax) and obs.rangeMax >= 0 and obs.rangeMax <= 10000 then clean.rangeMax = obs.rangeMax end
    if clean.rangeEvidence == "conflict" or (clean.rangeMin and clean.rangeMax
        and (clean.rangeMin > clean.rangeMax or (clean.rangeMin == clean.rangeMax and clean.rangeMinExclusive))) then
        clean.rangeMin, clean.rangeMax, clean.rangeMinExclusive, clean.rangeEvidence = nil, nil, false, "conflict"
    elseif not clean.rangeMin and not clean.rangeMax then
        clean.rangeEvidence = "unknown"
    end
    return clean
end

local function nameIdentity(obs)
    if not obs.name or not obs.nameComplete then return nil end
    local suffix = obs.realm and ("-" .. obs.realm)
    if suffix and obs.name:sub(-#suffix) ~= suffix then return "name:" .. obs.name .. suffix end
    return "name:" .. obs.name
end

function E.New(config)
    config = config or {}
    return setmetatable({
        clock = config.clock or function() return 0 end,
        epoch = config.epoch or function() return 0 end,
        profile = config.profile or D.NewProfile(), context = config.context or { kind = "world" },
        lists = config.lists or {}, onAlert = config.onAlert or function() end,
        onEncounter = config.onEncounter, onChange = config.onChange,
        contacts = {}, identities = {}, nameOwners = {}, bindings = {}, tokenSerial = 0, contactCount = 0,
        pending = {}, history = {}, cooldowns = {}, snoozes = {}, serial = 0, sequence = 0,
        evictedEncounters = {}, evictionSlots = {}, evictionCursor = 0,
        counters = { observations = 0, alerts = 0, suppressed = 0, evicted = 0, queueOverflow = 0, rangeAliasConflicts = 0 },
        pausedUntil = nil, lastSound = -math.huge, revision = 0,
    }, E)
end

function E:Now() return self.clock() end

function E:ListEntry(contact)
    if contact.identity and self.lists[contact.identity] then return self.lists[contact.identity], contact.identity end
    if contact.nameIdentity and not contact.ambiguousIdentity and self.lists[contact.nameIdentity] then
        return self.lists[contact.nameIdentity], contact.nameIdentity
    end
end

function E:IndexName(name, id, add)
    if not name then return end
    local owners = self.nameOwners[name]
    if not owners then
        if not add then return end
        owners = {}
        self.nameOwners[name] = owners
    end
    owners[id] = add and true or nil
    local first = next(owners)
    if not first then self.nameOwners[name], self.identities[name] = nil, nil return end
    local ambiguous = next(owners, first) ~= nil
    if ambiguous then self.identities[name] = false else self.identities[name] = first end
    for owner in pairs(owners) do
        local contact = self.contacts[owner]
        if contact then
            contact.ambiguousIdentity = ambiguous
            contact.identity = contact.guid and ("guid:" .. contact.guid) or (not ambiguous and name or nil)
        end
    end
end

function E:IndexContact(contact, oldGuid, oldName)
    if oldGuid and oldGuid ~= contact.guid and self.identities["guid:" .. oldGuid] == contact.id then self.identities["guid:" .. oldGuid] = nil end
    if oldName and oldName ~= contact.nameIdentity then self:IndexName(oldName, contact.id, false) end
    if contact.guid then self.identities["guid:" .. contact.guid] = contact.id end
    if contact.nameIdentity then self:IndexName(contact.nameIdentity, contact.id, true)
    else
        contact.ambiguousIdentity = false
        contact.identity = contact.guid and ("guid:" .. contact.guid) or nil
    end
end

function E:UnindexContact(contact)
    if contact.guid and self.identities["guid:" .. contact.guid] == contact.id then self.identities["guid:" .. contact.guid] = nil end
    self:IndexName(contact.nameIdentity, contact.id, false)
end

function E:SnoozedUntil(contact)
    local at = contact.identity and self.snoozes[contact.identity]
    if not at and contact.nameIdentity and not contact.ambiguousIdentity then at = self.snoozes[contact.nameIdentity] end
    if at and at > self:Now() then return at end
end

local function freshRange(contact, now)
    return contact.rangeAt ~= nil and now >= contact.rangeAt and now - contact.rangeAt <= MAX_RANGE_AGE
end

function E:View(contact, now)
    local entry = self:ListEntry(contact)
    local hasRange = contact.rangeAt ~= nil and freshRange(contact, now or self:Now())
    local sources = {}
    for token in pairs(contact.tokens) do
        local binding = self.bindings[token]
        if binding then sources[binding.source] = true end
    end
    return {
        id = contact.id, identity = contact.identity, name = contact.name, realm = contact.realm,
        class = contact.class, level = contact.level, hostile = contact.hostile, isPlayer = contact.isPlayer,
        visible = next(contact.tokens) ~= nil, firstSeen = contact.firstSeen, lastSeen = contact.lastSeen,
        sources = sources, stealth = contact.stealth, stealthAt = contact.stealthAt,
        stealthEvidence = contact.stealthEvidence, stealthSpell = contact.stealthSpell,
        targeting = contact.targeting, rangeMin = hasRange and contact.rangeMin or nil, rangeMax = hasRange and contact.rangeMax or nil,
        rangeMinExclusive = hasRange and contact.rangeMinExclusive or false,
        rangeEvidence = hasRange and contact.rangeEvidence or "unknown",
        watched = entry and (entry.kind == "watch" or entry.kind == "avoid") or false,
        listKind = entry and entry.kind, note = entry and entry.note,
        behindCamera = contact.behindCamera,
        dead = contact.dead,
        ambiguousIdentity = contact.ambiguousIdentity,
        currentTarget = contact.currentTarget, currentFocus = contact.currentFocus,
        snoozedUntil = self:SnoozedUntil(contact),
    }
end

function E:Changed()
    self.revision = self.revision + 1
    if self.onChange then self.onChange() end
end

function E:Reconcile(contact, now)
    local hostile, player, targeting, dead, behind, currentTarget, currentFocus
    local rangeAt, rangeMin, rangeMax, rangeExclusive, rangeEvidence, conflict
    for token in pairs(contact.tokens) do
        local binding = self.bindings[token]
        local obs = binding and binding.observation
        if obs then
            if obs.hostile == true then hostile = true end
            if obs.isPlayer == true then player = true end
            if obs.targeting == true then targeting = true
            elseif obs.targeting == false and targeting == nil then targeting = false end
            if obs.dead == true then dead = true
            elseif obs.dead == false and dead == nil then dead = false end
            if obs.behindCamera == true then behind = true
            elseif obs.behindCamera == false and behind == nil then behind = false end
            if obs.currentTarget == true or token == "target" then currentTarget = true
            elseif obs.currentTarget == false and currentTarget == nil then currentTarget = false end
            if obs.currentFocus == true or token == "focus" then currentFocus = true
            elseif obs.currentFocus == false and currentFocus == nil then currentFocus = false end
            local sampledAt = obs.rangeAt or binding.at
            if now >= sampledAt and now - sampledAt <= MAX_RANGE_AGE
                and (obs.rangeMin or obs.rangeMax or obs.rangeEvidence == "conflict") then
                if not rangeAt or sampledAt > rangeAt then
                    rangeAt, rangeMin, rangeMax = sampledAt, obs.rangeMin, obs.rangeMax
                    rangeExclusive, rangeEvidence = obs.rangeMinExclusive, obs.rangeEvidence
                    conflict = obs.rangeEvidence == "conflict"
                elseif sampledAt == rangeAt then
                    if obs.rangeMin and (not rangeMin or obs.rangeMin > rangeMin) then
                        rangeMin, rangeExclusive = obs.rangeMin, obs.rangeMinExclusive
                    elseif obs.rangeMin and obs.rangeMin == rangeMin then
                        rangeExclusive = rangeExclusive or obs.rangeMinExclusive
                    end
                    if obs.rangeMax then rangeMax = math.min(rangeMax or math.huge, obs.rangeMax) end
                    conflict = conflict or obs.rangeEvidence == "conflict"
                    if obs.rangeEvidence == "exact" then rangeEvidence = "exact"
                    elseif rangeEvidence ~= "exact" and obs.rangeEvidence and rangeEvidence and obs.rangeEvidence ~= rangeEvidence then
                        rangeEvidence = "combined"
                    else rangeEvidence = rangeEvidence or obs.rangeEvidence end
                end
            end
        end
    end
    contact.hostile, contact.isPlayer = hostile, player
    contact.targeting, contact.dead, contact.behindCamera = targeting, dead, behind
    if targeting == false and contact.targetingNotified ~= nil then
        contact.targetingNotified = nil
        self:CancelTargeting(contact)
    end
    contact.currentTarget, contact.currentFocus = currentTarget, currentFocus
    local incompatible = rangeMin and rangeMax and (rangeMin > rangeMax or (rangeMin == rangeMax and rangeExclusive))
    if incompatible and not conflict and (contact.rangeEvidence ~= "conflict" or contact.rangeAt ~= rangeAt) then
        self.counters.rangeAliasConflicts = self.counters.rangeAliasConflicts + 1
    end
    if conflict or incompatible then
        rangeMin, rangeMax, rangeExclusive, rangeEvidence = nil, nil, false, "conflict"
    end
    contact.rangeMin, contact.rangeMax, contact.rangeMinExclusive = rangeMin, rangeMax, rangeExclusive == true
    contact.rangeAt, contact.rangeEvidence = rangeAt, rangeEvidence or "unknown"
end

function E:Explain(contact, event, now)
    local view = contact.tokens and self:View(contact, now) or contact
    return Rules.Evaluate(self.profile, view, event or "sighting", self.context, self:ListEntry(contact))
end

function E:ExplainView(id, event)
    local contact = self.contacts[id]
    if not contact then return { allowed = false, reason = "not_observed" } end
    if next(contact.tokens) == nil then return { allowed = false, reason = "not_observed" } end
    local now = self:Now()
    local result = { allowed = false, rangeEvidence = freshRange(contact, now) and contact.rangeEvidence or "unknown" }
    if self:SnoozedUntil(contact) then result.reason = "contact_snoozed"; return result end
    local decision, reason = self:Explain(contact, event, now)
    if not decision then result.reason = reason; return result end
    if self.pausedUntil and now < self.pausedUntil then result.reason = "paused"; return result end
    result.kind = decision.kind
    if not decision.sound and not decision.banner then result.reason = "wave_only"; return result end
    local at = self.cooldowns[contact.id .. ":" .. (decision.dedupKey or decision.kind)]
    if at and now - at < decision.cooldown then result.reason = "cooldown"; return result end
    result.allowed, result.reason, result.priority = true, decision.reason, decision.priority
    result.ruleName, result.sound, result.banner = decision.ruleName, decision.sound, decision.banner
    return result
end

function E:RecordEncounter(contact, now)
    if contact.encounterRecorded or not self.onEncounter or not self.profile.enabled or contact.ambiguousIdentity
        or not contact.identity or not contact.name or contact.hostile ~= true or contact.isPlayer ~= true
        or contact.dead or not Rules.ContextMatches(self.profile.context, self.context) then return end
    local entry = self:ListEntry(contact)
    if entry and entry.kind == "ignore" then return end
    -- A selective journal can decline the initial sighting. New evidence can
    -- qualify that encounter later without counting every poll as a meeting.
    if self.onEncounter(self:View(contact, now), self.epoch()) ~= false then contact.encounterRecorded = true end
end

local function upgradeStealthEvidence(item, evidence, spell)
    if item.event == "stealth" and item.stealthEvidence == "aura" and evidence == "cast" then
        item.stealthEvidence, item.stealthSpell = evidence, spell
    end
end

local function strongerAlert(a, b)
    if a.decision.priority == b.decision.priority then return a.sequence < b.sequence end
    return a.decision.priority > b.decision.priority
end

local function ordinaryAlert(decision)
    return decision.priority < 70 and (decision.kind == "sighting" or decision.kind == "returning")
end

function E:CancelTargeting(contact)
    for index = #self.pending, 1, -1 do
        local item = self.pending[index]
        if item.id == contact.id then
            if item.event == "targeting" then table.remove(self.pending, index)
            else item.coversTargeting = nil end
        end
    end
end

function E:Queue(contact, event)
    local now = self:Now()
    if self:SnoozedUntil(contact) then return false end
    local decision, reason = self:Explain(contact, event, now)
    contact.lastReason = reason or (decision and decision.reason)
    if not decision then self.counters.suppressed = self.counters.suppressed + 1 return false end
    if self.pausedUntil and now < self.pausedUntil then return false end
    local key = contact.id .. ":" .. (decision.dedupKey or decision.kind)
    local cooldown = self.cooldowns[key]
    if cooldown and now - cooldown < decision.cooldown then contact.lastReason = "cooldown" return false end
    for _, item in ipairs(self.pending) do
        if item.id == contact.id then
            local age = now - item.at
            if age <= MAX_PENDING_AGE and (item.decision.dedupKey or item.decision.kind) == (decision.dedupKey or decision.kind) then
                if event == "stealth" then upgradeStealthEvidence(item, contact.stealthEvidence, contact.stealthSpell) end
                return false
            end
            if age <= self.profile.alerts.waveWindow and item.decision.priority >= decision.priority then
                if event == "targeting" then item.coversTargeting = true end
                return false
            end
        end
    end
    local coversTargeting
    for index = #self.pending, 1, -1 do
        local item = self.pending[index]
        if item.id == contact.id and now - item.at <= self.profile.alerts.waveWindow and item.decision.priority < decision.priority then
            if item.event == "sighting" then contact.arrivalQueued = false end
            coversTargeting = coversTargeting or item.event == "targeting" or item.coversTargeting
            table.remove(self.pending, index)
        end
    end
    self.sequence = self.sequence + 1
    local item = { id = contact.id, event = event, decision = decision, at = now, sequence = self.sequence,
        revision = self.revision, coversTargeting = coversTargeting }
    if event == "stealth" then
        item.stealthEvidence, item.stealthSpell = contact.stealthEvidence, contact.stealthSpell
    end
    self.pending[#self.pending + 1] = item
    if #self.pending > self.profile.retention.maxContacts then
        -- Prefer discarding expired entries, then the weakest, newest alert.
        local weakest = #self.pending
        for index = 1, #self.pending - 1 do
            local queued = self.pending[index]
            if now - queued.at > MAX_PENDING_AGE then
                weakest = index
                break
            end
            if strongerAlert(self.pending[weakest], queued) then weakest = index end
        end
        local dropped = table.remove(self.pending, weakest)
        self.counters.queueOverflow = self.counters.queueOverflow + 1
        local owner = self.contacts[dropped.id]
        if owner and dropped.event == "sighting" then owner.arrivalQueued = false end
        return dropped ~= item
    end
    return true
end

function E:RememberEvictedEncounter(contact, now)
    if not contact.guid or now - contact.lastSeen >= self.profile.alerts.returnAfter then return nil end
    if not (contact.encounterRecorded or contact.arrivalNotified or contact.lastStealthCast
        or contact.targetingNotified ~= nil or contact.stealth) then return nil end
    -- Capacity eviction cannot end an encounter on its own. Keep bounded
    -- session evidence keyed by GUID and leave live state to fresh unit reads.
    local cursor = self.evictionCursor % EVICTED_ENCOUNTER_LIMIT + 1
    local overwritten = self.evictionSlots[cursor]
    if overwritten and self.evictedEncounters[overwritten.guid] == overwritten then
        self.evictedEncounters[overwritten.guid] = nil
    end
    local record = {
        guid = contact.guid, slot = cursor, lastSeen = contact.lastSeen,
        encounterRecorded = contact.encounterRecorded, arrivalNotified = contact.arrivalNotified,
        notifiedClass = contact.notifiedClass, lastStealthCast = contact.lastStealthCast,
        targetingNotified = contact.targetingNotified, stealth = contact.stealth,
    }
    self.evictionSlots[cursor] = record
    self.evictionCursor = cursor
    self.evictedEncounters[contact.guid] = record
    return record
end

function E:RestoreEvictedEncounter(contact, now)
    local record = contact.guid and self.evictedEncounters[contact.guid]
    if not record then return nil end
    self.evictedEncounters[contact.guid], self.evictionSlots[record.slot] = nil, nil
    if now - record.lastSeen >= self.profile.alerts.returnAfter then return nil end
    contact.encounterRecorded = contact.encounterRecorded or record.encounterRecorded
    contact.arrivalNotified = contact.arrivalNotified or record.arrivalNotified
    contact.notifiedClass = contact.notifiedClass or record.notifiedClass
    contact.lastStealthCast = contact.lastStealthCast or record.lastStealthCast
    if contact.targetingNotified ~= true and record.targetingNotified ~= nil then
        contact.targetingNotified = record.targetingNotified
    end
    if record.arrivalNotified and contact.arrivalQueued then
        for index = #self.pending, 1, -1 do
            local item = self.pending[index]
            if item.id == contact.id and item.event == "sighting" then table.remove(self.pending, index) end
        end
        contact.arrivalQueued = false
    end
    if record.cooldowns then
        for kind, at in pairs(record.cooldowns) do
            local key = contact.id .. ":" .. kind
            self.cooldowns[key] = math.max(at, self.cooldowns[key] or -math.huge)
        end
    end
    return record
end

function E:Drop(id, evictionAt)
    local contact = self.contacts[id]
    if not contact then return end
    local record = evictionAt and self:RememberEvictedEncounter(contact, evictionAt)
    for token in pairs(contact.tokens) do self.bindings[token] = nil end
    self:UnindexContact(contact)
    self.contacts[id] = nil
    self.contactCount = self.contactCount - 1
    for index = #self.pending, 1, -1 do if self.pending[index].id == id then table.remove(self.pending, index) end end
    local prefix = id .. ":"
    for key, at in pairs(self.cooldowns) do
        if key:sub(1, #prefix) == prefix then
            if record then
                record.cooldowns = record.cooldowns or {}
                record.cooldowns[key:sub(#prefix + 1)] = at
            end
            self.cooldowns[key] = nil
        end
    end
end

function E:MakeRoom()
    if self.contactCount < self.profile.retention.maxContacts then return end
    local urgent, now = {}, self:Now()
    for _, item in ipairs(self.pending) do
        local contact = self.contacts[item.id]
        local priority = item.decision.priority
        if contact and priority >= 70 and now - item.at <= MAX_PENDING_AGE
            and (item.event ~= "targeting" or contact.targeting == true) then
            urgent[item.id] = math.max(urgent[item.id] or 0, priority)
        end
    end
    local candidate, candidatePriority, candidateVisible
    for _, contact in pairs(self.contacts) do
        local priority = urgent[contact.id] or 0
        local visible = next(contact.tokens) ~= nil
        local discard
        if not candidate then discard = true
        elseif priority ~= candidatePriority then discard = priority < candidatePriority
        elseif visible ~= candidateVisible then discard = not visible
        elseif contact.lastSeen ~= candidate.lastSeen then discard = contact.lastSeen < candidate.lastSeen
        else discard = contact.id < candidate.id end
        if discard then
            candidate, candidatePriority, candidateVisible = contact, priority, visible
        end
    end
    if candidate then self:Drop(candidate.id, now) self.counters.evicted = self.counters.evicted + 1 end
end

function E:Merge(target, other)
    if target.id == other.id then return target end
    local oldGuid, oldName = target.guid, target.nameIdentity
    self:UnindexContact(other)
    for token in pairs(other.tokens) do
        target.tokens[token] = true
        if self.bindings[token] then self.bindings[token].id = target.id end
    end
    target.firstSeen = math.min(target.firstSeen, other.firstSeen)
    target.lastSeen = math.max(target.lastSeen, other.lastSeen)
    target.arrivalNotified = target.arrivalNotified or other.arrivalNotified
    target.arrivalQueued = target.arrivalQueued or other.arrivalQueued
    target.encounterRecorded = target.encounterRecorded or other.encounterRecorded
    target.notifiedClass = target.notifiedClass or other.notifiedClass
    if target.targetingNotified ~= true and other.targetingNotified ~= nil then
        target.targetingNotified = other.targetingNotified
    end
    for _, field in ipairs({ "class", "level", "name", "realm", "guid", "identity", "nameIdentity", "rangeMin", "rangeMax", "targeting", "hostile", "isPlayer" }) do
        if target[field] == nil then target[field] = other[field] end
    end
    if other.stealth and (not target.stealth or (other.stealthAt or 0) > (target.stealthAt or 0)) then
        target.stealth, target.stealthAt = other.stealth, other.stealthAt
        target.stealthEvidence, target.stealthSpell = other.stealthEvidence, other.stealthSpell
    end
    local mergedPending = {}
    for _, item in ipairs(self.pending) do
        if item.id == other.id then item.id = target.id end
        if item.id == target.id then mergedPending[#mergedPending + 1] = item end
    end
    if #mergedPending > 1 then
        table.sort(mergedPending, strongerAlert)
        local kept, discard = {}, {}
        for _, item in ipairs(mergedPending) do
            for _, strongest in ipairs(kept) do
                if math.abs(item.at - strongest.at) <= self.profile.alerts.waveWindow then
                    upgradeStealthEvidence(strongest, item.stealthEvidence, item.stealthSpell)
                    strongest.coversTargeting = strongest.coversTargeting or item.event == "targeting" or item.coversTargeting
                    discard[item] = true
                    break
                end
            end
            if not discard[item] then kept[#kept + 1] = item end
        end
        for index = #self.pending, 1, -1 do
            if discard[self.pending[index]] then table.remove(self.pending, index) end
        end
        target.arrivalQueued = false
        for _, item in ipairs(kept) do if item.event == "sighting" then target.arrivalQueued = true break end end
    end
    for kind in pairs({ sighting = true, returning = true, watch = true, targeting = true, stealth = true, identified = true }) do
        local old = self.cooldowns[other.id .. ":" .. kind]
        if old then self.cooldowns[target.id .. ":" .. kind] = math.max(old, self.cooldowns[target.id .. ":" .. kind] or -math.huge) end
        self.cooldowns[other.id .. ":" .. kind] = nil
    end
    self.contacts[other.id] = nil
    self.contactCount = self.contactCount - 1
    self:IndexContact(target, oldGuid, oldName)
    return target
end

function E:ResetReturningEncounter(contact, now)
    if next(contact.tokens) ~= nil or now - contact.lastSeen < self.profile.alerts.returnAfter then return false end
    contact.encounterRecorded = false
    contact.targetingNotified = nil
    contact.stealth, contact.stealthAt, contact.stealthEvidence, contact.stealthSpell = nil, nil, nil, nil
    return true
end

function E:Observe(raw)
    local obs = safeObservation(raw)
    if not obs then return nil, "invalid_observation" end
    local named = nameIdentity(obs)
    local binding = self.bindings[obs.token]
    local contact = binding and self.contacts[binding.id]
    if obs.isPlayer == false or obs.hostile == false then
        local sameOwner = false
        if contact then
            if contact.guid and obs.guid then sameOwner = contact.guid == obs.guid
            else sameOwner = named ~= nil and named == contact.nameIdentity and not contact.ambiguousIdentity end
        end
        self:Remove(obs.token, sameOwner and obs or nil)
        return nil, "not_enemy_player"
    end
    local now = self:Now()
    self.counters.observations = self.counters.observations + 1
    if not self.profile.enabled then return nil, "disabled" end
    local identity = obs.guid and ("guid:" .. obs.guid) or named
    -- A token can be recycled. A new clean GUID never inherits its old owner.
    if contact and obs.guid and contact.guid and contact.guid ~= obs.guid then
        self:Remove(obs.token)
        contact, binding = nil, nil
    elseif contact and not obs.guid and named and contact.nameIdentity and contact.nameIdentity ~= named then
        self:Remove(obs.token)
        contact, binding = nil, nil
    end
    local known = identity and self.identities[identity]
    if not known and named then
        local nameOwner = self.identities[named]
        local namedContact = nameOwner and self.contacts[nameOwner]
        if namedContact and (not obs.guid or not namedContact.guid or namedContact.guid == obs.guid) then known = nameOwner end
    end
    local returning
    local matched = known and self.contacts[known]
    if matched then
        if contact and contact.id ~= known then
            -- The anonymous live alias is part of the new encounter. Clear
            -- stale evidence on the old identity before inheriting any of it.
            returning = self:ResetReturningEncounter(matched, now)
            contact = self:Merge(matched, contact)
        else
            contact = matched
        end
    end
    if not contact then
        self:MakeRoom()
        self.serial = self.serial + 1
        contact = { id = "c" .. self.serial, tokens = {}, firstSeen = now, lastSeen = now }
        self.contacts[contact.id] = contact
        self.contactCount = self.contactCount + 1
    end
    returning = returning or self:ResetReturningEncounter(contact, now)
    if not binding or binding.id ~= contact.id then
        self.tokenSerial = self.tokenSerial + 1
        self.bindings[obs.token] = { id = contact.id, generation = self.tokenSerial, source = obs.source }
    end
    contact.tokens[obs.token] = true
    local currentBinding = self.bindings[obs.token]
    currentBinding.observation, currentBinding.at = obs, now
    contact.lastSeen = now
    local oldGuid, oldNameIdentity = contact.guid, contact.nameIdentity
    if obs.guid then contact.guid, contact.identity = obs.guid, "guid:" .. obs.guid end
    if obs.name and (obs.nameComplete or not contact.name) then contact.name, contact.realm, contact.nameIdentity = obs.name, obs.realm, named end
    if not contact.identity then contact.identity = identity end
    if oldGuid ~= contact.guid or oldNameIdentity ~= contact.nameIdentity then self:IndexContact(contact, oldGuid, oldNameIdentity) end
    local previous = oldGuid ~= contact.guid and self:RestoreEvictedEncounter(contact, now)
    local oldClass = contact.class
    if obs.class then contact.class = obs.class end
    if obs.level then contact.level = obs.level end
    -- A restricted alias cannot erase another available source's clean evidence.
    -- Conversely, evidence vanishes when every active source becomes unreadable.
    self:Reconcile(contact, now)
    local oldStealth = contact.stealth or (previous and previous.stealth)
    if obs.stealthReadable then
        if obs.stealth == true then
            if contact.stealthEvidence ~= "aura" then contact.stealthAt = now end
            contact.stealth, contact.stealthEvidence, contact.stealthSpell = "confirmed", "aura", nil
        elseif obs.stealth == false then
            contact.stealth, contact.stealthAt, contact.stealthEvidence, contact.stealthSpell = nil, nil, nil, nil
        end
    end
    self:RecordEncounter(contact, now)
    if not contact.arrivalNotified and not contact.arrivalQueued then
        contact.arrivalQueued = self:Queue(contact, "sighting")
    elseif returning then
        self:Queue(contact, "returning")
    end
    if not oldClass and contact.class and contact.arrivalNotified and not contact.notifiedClass then self:Queue(contact, "identified") end
    if contact.stealth and not oldStealth then self:Queue(contact, "stealth") end
    -- An unreadable target does not end an episode. Retry from a fresh positive
    -- observation until the current target actually produces a warning.
    if obs.targeting == true and contact.targetingNotified ~= true then
        contact.targetingNotified = false
        if self.profile.alerts.targeting then self:Queue(contact, "targeting") end
    end
    self:Changed()
    return self:View(contact, now)
end

function E:Remove(token, contradiction)
    local binding = self.bindings[token]
    if not binding then return end
    local contact = self.contacts[binding.id]
    self.bindings[token] = nil
    if contact then
        contact.tokens[token] = nil
        local visible = next(contact.tokens) ~= nil
        if not visible then
            contact.lastSeen = self:Now()
            contact.targeting, contact.currentTarget, contact.currentFocus = nil, nil, nil
            if contact.targetingNotified ~= nil then self:CancelTargeting(contact) end
        else self:Reconcile(contact, self:Now()) end
        if contradiction and (not visible or contact.hostile ~= true or contact.isPlayer ~= true) then
            if contradiction.hostile == false then contact.hostile = false end
            if contradiction.isPlayer == false then contact.isPlayer = false end
            contact.targeting, contact.targetingNotified, contact.arrivalQueued = nil, nil, false
            for index = #self.pending, 1, -1 do
                if self.pending[index].id == contact.id then table.remove(self.pending, index) end
            end
        end
    end
    self:Changed()
end

function E:TracksCast(spellID)
    return U.IsFinite(spellID) and SPELLS[spellID] ~= nil
end

function E:Cast(token, spellID)
    if not self:TracksCast(spellID) then return false end
    local binding = self.bindings[token]
    local contact = binding and self.contacts[binding.id]
    if not contact then return false end
    local now = self:Now()
    if contact.lastStealthCast and now - contact.lastStealthCast < 1 then return false end
    contact.lastStealthCast, contact.stealth, contact.stealthAt = now, "confirmed", now
    contact.stealthEvidence, contact.stealthSpell = "cast", SPELLS[spellID]
    self:RecordEncounter(contact, now)
    self:Queue(contact, "stealth")
    self:Changed()
    return true
end

function E:Emit(decision, now)
    if decision.sound then
        if self.profile.alerts.sounds[decision.kind] == "none"
            or now - self.lastSound < self.profile.alerts.soundGap then decision.sound = false
        else self.lastSound = now end
    end
    if not decision.sound and not decision.banner then return false end
    self.counters.alerts = self.counters.alerts + 1
    U.ArrayPush(self.history, { at = now, kind = decision.kind, id = decision.contact and decision.contact.id, reason = decision.reason }, self.profile.retention.maxHistory)
    self.onAlert(decision)
    return true
end

function E:EmitOrdinary(group, now)
    if #group < self.profile.alerts.waveThreshold then
        if #group > 1 then table.sort(group, strongerAlert) end
        for _, item in ipairs(group) do self:Emit(item.decision, now) end
        return
    end
    local classes, sound, banner = {}, false, false
    for _, item in ipairs(group) do
        local decision = item.decision
        local class = decision.contact.class or "UNKNOWN"
        classes[class] = (classes[class] or 0) + 1
        sound, banner = sound or decision.waveSound, banner or decision.banner
    end
    self:Emit({ kind = "wave", count = #group, classes = classes, priority = 35, sound = sound, banner = banner, reason = "multiple_sightings" }, now)
end

function E:Tick()
    local now = self:Now()
    local resumed = self.pausedUntil and now >= self.pausedUntil
    if resumed then self.pausedUntil = nil end
    local ready, waiting = {}, {}
    local waveWindow = self.profile.alerts.waveWindow
    local firstOrdinaryAt
    -- Pending entries are appended in observation order. The first arrival
    -- sets the deadline for its group, including arrivals close to that deadline.
    for _, item in ipairs(self.pending) do
        local age = now - item.at
        if age > MAX_PENDING_AGE then
            local contact = self.contacts[item.id]
            if contact and item.event == "sighting" then contact.arrivalQueued = false end
        else
            if ordinaryAlert(item.decision) then
                if not firstOrdinaryAt or item.at - firstOrdinaryAt > waveWindow then firstOrdinaryAt = item.at end
                age = now - firstOrdinaryAt
            end
            local nextQueue = (item.decision.priority >= 70 or age >= waveWindow) and ready or waiting
            nextQueue[#nextQueue + 1] = item
        end
    end
    self.pending = waiting
    table.sort(ready, strongerAlert)
    local ordinary, accepted = {}, {}
    for _, item in ipairs(ready) do
        local contact = self.contacts[item.id]
        local decision
        if contact and (item.event ~= "targeting" or (contact.targeting == true and contact.targetingNotified ~= true)) then
            decision = self:Explain(contact, item.event, now)
        end
        if decision and not (self.pausedUntil and now < self.pausedUntil) and not self:SnoozedUntil(contact) then
            local key = contact.id .. ":" .. (decision.dedupKey or decision.kind)
            if not accepted[key] and (not self.cooldowns[key] or now - self.cooldowns[key] >= decision.cooldown) then
                accepted[key] = true
                decision.contact = self:View(contact, now)
                decision.stealthEvidence, decision.stealthSpell = item.stealthEvidence, item.stealthSpell
                local emitted
                if ordinaryAlert(decision) then
                    item.decision = decision
                    ordinary[#ordinary + 1] = item
                else
                    emitted = self:Emit(decision, now)
                end
                if emitted and contact.targeting == true and contact.targetingNotified ~= true then
                    -- A stronger warning counts only if it replaced an
                    -- eligible targeting warning from the same burst.
                    if item.event == "targeting" or (item.coversTargeting and self:Explain(contact, "targeting", now)) then
                        contact.targetingNotified = true
                    end
                end
                if item.event ~= "targeting" or emitted then
                    self.cooldowns[key] = now
                    contact.arrivalNotified, contact.arrivalQueued = true, false
                    if contact.class then contact.notifiedClass = contact.class end
                end
            end
        elseif contact and item.event == "sighting" then
            contact.arrivalQueued = false
        end
    end
    if #ordinary > 0 then
        if #ordinary > 1 then
            -- Priority delivery above can reorder sightings. Group by the
            -- original event times, even when a single tick drains several waves.
            table.sort(ordinary, function(a, b)
                if a.at == b.at then return a.sequence < b.sequence end
                return a.at < b.at
            end)
        end
        local group, firstAt = {}, ordinary[1].at
        for _, item in ipairs(ordinary) do
            if item.at - firstAt > waveWindow then
                self:EmitOrdinary(group, now)
                group, firstAt = {}, item.at
            end
            group[#group + 1] = item
        end
        self:EmitOrdinary(group, now)
    end
    local expired = {}
    for id, contact in pairs(self.contacts) do
        if next(contact.tokens) == nil and now - contact.lastSeen > self.profile.retention.contactSeconds then expired[#expired + 1] = id end
    end
    for _, id in ipairs(expired) do self:Drop(id) end
    for key, at in pairs(self.cooldowns) do if now - at > 1800 then self.cooldowns[key] = nil end end
    for identity, at in pairs(self.snoozes) do if at <= now then self.snoozes[identity] = nil end end
    if resumed or #expired > 0 then self:Changed() end
end

function E:CountVisible()
    local count = 0
    for _, contact in pairs(self.contacts) do
        if next(contact.tokens) ~= nil and contact.behindCamera ~= true
            and Rules.Display(self.profile, contact, self:ListEntry(contact)) then
            count = count + 1
        end
    end
    return count
end

function E:Snapshot()
    local result = {}
    local now = self:Now()
    for _, contact in pairs(self.contacts) do
        local view = self:View(contact, now)
        if Rules.Display(self.profile, view) then result[#result + 1] = view end
    end
    table.sort(result, function(a, b)
        if a.watched ~= b.watched then return a.watched end
        if a.visible ~= b.visible then return a.visible end
        if a.lastSeen ~= b.lastSeen then return a.lastSeen > b.lastSeen end
        return a.id < b.id
    end)
    return result
end

function E:SetProfile(profile, preservePending)
    self.profile = profile
    if not profile.enabled then self:Clear() return end
    if not preservePending then
        self.pending = {}
        for _, contact in pairs(self.contacts) do contact.arrivalQueued = false end
    end
    while self.contactCount > profile.retention.maxContacts do self:MakeRoom() end
    while #self.history > profile.retention.maxHistory do table.remove(self.history, 1) end
    self:Changed()
end

function E:SetContext(context)
    context = context or { kind = "world" }
    local previous = self.context
    self.context = context
    if previous.kind == context.kind and previous.sanctuary == context.sanctuary and previous.resting == context.resting
        and previous.flight == context.flight and previous.combat == context.combat then return end
    self:Changed()
end

function E:Pause(seconds)
    self.pausedUntil = self:Now() + U.Clamp(seconds, 1, 86400, 600)
    self.pending = {}
    for _, contact in pairs(self.contacts) do contact.arrivalQueued = false end
    self:Changed()
end

function E:Resume() self.pausedUntil = nil self:Changed() end

function E:ToggleContactSnooze(id, seconds)
    local contact = self.contacts[id]
    if not contact then return nil, "not_observed" end
    if not contact.identity then return nil, "unknown_identity" end
    local now = self:Now()
    local expiry
    if self:SnoozedUntil(contact) then
        self.snoozes[contact.identity] = nil
        if contact.nameIdentity and not contact.ambiguousIdentity then self.snoozes[contact.nameIdentity] = nil end
    else
        if U.Count(self.snoozes) >= 256 then
            for identity, at in pairs(self.snoozes) do if at <= now then self.snoozes[identity] = nil end end
            if U.Count(self.snoozes) >= 256 then return nil, "snooze_limit" end
        end
        expiry = now + U.Clamp(seconds, 1, 3600, 600)
        self.snoozes[contact.identity] = expiry
    end
    for index = #self.pending, 1, -1 do
        if self.pending[index].id == id then table.remove(self.pending, index) end
    end
    contact.arrivalQueued = false
    self:Changed()
    return true, expiry
end

function E:ClearRecent()
    local discarded = {}
    for id, contact in pairs(self.contacts) do
        if next(contact.tokens) == nil then discarded[#discarded + 1] = id end
    end
    for _, id in ipairs(discarded) do self:Drop(id) end
    self.evictedEncounters, self.evictionSlots, self.evictionCursor = {}, {}, 0
    self.history = {}
    self:Changed()
    return #discarded
end

function E:Clear()
    self.contacts, self.identities, self.bindings, self.pending, self.cooldowns = {}, {}, {}, {}, {}
    self.nameOwners, self.contactCount = {}, 0
    self.evictedEncounters, self.evictionSlots, self.evictionCursor = {}, {}, 0
    self.history = {}
    self:Changed()
end
