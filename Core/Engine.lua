local _, RG = ...
local U, D, Rules = RG.Util, RG.Defaults, RG.Rules
local E = RG.Register("Engine", {})
E.__index = E

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
    }
    if clean.source == "poll" or clean.source == "cast" or clean.source == "aura" or clean.source == "unit" then
        clean.source = token:match("^nameplate%d+$") and "nameplate" or token
    end
    if U.IsFinite(obs.rangeMin) and obs.rangeMin >= 0 and obs.rangeMin <= 10000 then clean.rangeMin = obs.rangeMin end
    if U.IsFinite(obs.rangeMax) and obs.rangeMax >= 0 and obs.rangeMax <= 10000 then clean.rangeMax = obs.rangeMax end
    if clean.rangeMin and clean.rangeMax and clean.rangeMin > clean.rangeMax then clean.rangeMin, clean.rangeMax = nil, nil end
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
        counters = { observations = 0, alerts = 0, suppressed = 0, evicted = 0 },
        pausedUntil = nil, lastSound = -math.huge, revision = 0,
    }, E)
end

function E:Now() return self.clock() end

function E:ListEntry(contact)
    if contact.identity and self.lists[contact.identity] then return self.lists[contact.identity] end
    if contact.nameIdentity and not contact.ambiguousIdentity then return self.lists[contact.nameIdentity] end
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

function E:View(contact)
    local entry = self:ListEntry(contact)
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
        targeting = contact.targeting, rangeMin = contact.rangeMin, rangeMax = contact.rangeMax,
        rangeMinExclusive = contact.rangeMinExclusive,
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

function E:Reconcile(contact)
    local hostile, player, targeting, dead, behind, currentTarget, currentFocus
    local selectedRange
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
            if obs.rangeMin or obs.rangeMax then
                if not selectedRange or binding.at > selectedRange.at
                    or (binding.at == selectedRange.at and (obs.rangeMax or math.huge) < (selectedRange.observation.rangeMax or math.huge)) then selectedRange = binding end
            end
        end
    end
    contact.hostile, contact.isPlayer = hostile, player
    contact.targeting, contact.dead, contact.behindCamera = targeting, dead, behind
    contact.currentTarget, contact.currentFocus = currentTarget, currentFocus
    contact.rangeMin = selectedRange and selectedRange.observation.rangeMin
    contact.rangeMax = selectedRange and selectedRange.observation.rangeMax
    contact.rangeMinExclusive = selectedRange and selectedRange.observation.rangeMinExclusive or false
end

function E:Explain(contact, event)
    local view = contact.tokens and self:View(contact) or contact
    return Rules.Evaluate(self.profile, view, event or "sighting", self.context, self:ListEntry(contact))
end

function E:ExplainView(id, event)
    local contact = self.contacts[id]
    if not contact then return { allowed = false, reason = "not_observed" } end
    if next(contact.tokens) == nil then return { allowed = false, reason = "not_observed" } end
    if self:SnoozedUntil(contact) then return { allowed = false, reason = "contact_snoozed" } end
    local decision, reason = self:Explain(contact, event)
    if not decision then return { allowed = false, reason = reason } end
    if self.pausedUntil and self:Now() < self.pausedUntil then return { allowed = false, reason = "paused" } end
    local at = self.cooldowns[contact.id .. ":" .. (decision.dedupKey or decision.kind)]
    if at and self:Now() - at < decision.cooldown then return { allowed = false, reason = "cooldown", kind = decision.kind } end
    return { allowed = true, reason = decision.reason, priority = decision.priority, kind = decision.kind, ruleName = decision.ruleName }
end

function E:RecordEncounter(contact)
    if contact.encounterRecorded or not self.onEncounter or not self.profile.enabled or contact.ambiguousIdentity
        or not contact.identity or not contact.name or contact.hostile ~= true or contact.isPlayer ~= true
        or contact.dead or not Rules.ContextMatches(self.profile.context, self.context) then return end
    local entry = self:ListEntry(contact)
    if entry and entry.kind == "ignore" then return end
    -- A selective journal can decline the initial sighting. New evidence can
    -- qualify that encounter later without counting every poll as a meeting.
    if self.onEncounter(self:View(contact), self.epoch()) ~= false then contact.encounterRecorded = true end
end

function E:Queue(contact, event)
    local now = self:Now()
    if self:SnoozedUntil(contact) then return false end
    local decision, reason = self:Explain(contact, event)
    contact.lastReason = reason or (decision and decision.reason)
    if not decision then self.counters.suppressed = self.counters.suppressed + 1 return false end
    if self.pausedUntil and now < self.pausedUntil then return false end
    local key = contact.id .. ":" .. (decision.dedupKey or decision.kind)
    local cooldown = self.cooldowns[key]
    if cooldown and now - cooldown < decision.cooldown then contact.lastReason = "cooldown" return false end
    for _, item in ipairs(self.pending) do
        if item.id == contact.id and (item.decision.dedupKey or item.decision.kind) == (decision.dedupKey or decision.kind) then return false end
        if item.id == contact.id and now - item.at <= self.profile.alerts.waveWindow and item.decision.priority >= decision.priority then return false end
    end
    for index = #self.pending, 1, -1 do
        local item = self.pending[index]
        if item.id == contact.id and now - item.at <= self.profile.alerts.waveWindow and item.decision.priority < decision.priority then
            if item.event == "sighting" then contact.arrivalQueued = false end
            table.remove(self.pending, index)
        end
    end
    self.sequence = self.sequence + 1
    self.pending[#self.pending + 1] = { id = contact.id, event = event, decision = decision, at = now, sequence = self.sequence, revision = self.revision }
    if #self.pending > self.profile.retention.maxContacts then
        local dropped = table.remove(self.pending, 1)
        local owner = self.contacts[dropped.id]
        if owner and dropped.event == "sighting" then owner.arrivalQueued = false end
    end
    return true
end

function E:Drop(id)
    local contact = self.contacts[id]
    if not contact then return end
    for token in pairs(contact.tokens) do self.bindings[token] = nil end
    self:UnindexContact(contact)
    self.contacts[id] = nil
    self.contactCount = self.contactCount - 1
    for index = #self.pending, 1, -1 do if self.pending[index].id == id then table.remove(self.pending, index) end end
    for key in pairs(self.cooldowns) do if key:sub(1, #id + 1) == id .. ":" then self.cooldowns[key] = nil end end
end

function E:MakeRoom()
    if self.contactCount < self.profile.retention.maxContacts then return end
    local candidate
    for _, contact in pairs(self.contacts) do
        if not candidate or (next(candidate.tokens) ~= nil and next(contact.tokens) == nil)
            or ((next(candidate.tokens) ~= nil) == (next(contact.tokens) ~= nil) and contact.lastSeen < candidate.lastSeen) then candidate = contact end
    end
    if candidate then self:Drop(candidate.id) self.counters.evicted = self.counters.evicted + 1 end
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
        table.sort(mergedPending, function(a, b)
            if a.decision.priority == b.decision.priority then return a.sequence < b.sequence end
            return a.decision.priority > b.decision.priority
        end)
        local kept, discard = {}, {}
        for _, item in ipairs(mergedPending) do
            for _, strongest in ipairs(kept) do
                if math.abs(item.at - strongest.at) <= self.profile.alerts.waveWindow then discard[item] = true break end
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

function E:Observe(raw)
    local obs = safeObservation(raw)
    if not obs then return nil, "invalid_observation" end
    if obs.isPlayer == false or obs.hostile == false then self:Remove(obs.token) return nil, "not_enemy_player" end
    local now = self:Now()
    self.counters.observations = self.counters.observations + 1
    if not self.profile.enabled then return nil, "disabled" end
    local identity = obs.guid and ("guid:" .. obs.guid) or nameIdentity(obs)
    local named = nameIdentity(obs)
    local binding = self.bindings[obs.token]
    local contact = binding and self.contacts[binding.id]
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
    if known and self.contacts[known] then
        if contact and contact.id ~= known then contact = self:Merge(self.contacts[known], contact)
        else contact = self.contacts[known] end
    end
    if not contact then
        self:MakeRoom()
        self.serial = self.serial + 1
        contact = { id = "c" .. self.serial, tokens = {}, firstSeen = now, lastSeen = now }
        self.contacts[contact.id] = contact
        self.contactCount = self.contactCount + 1
    end
    local wasVisible = next(contact.tokens) ~= nil
    local away = now - contact.lastSeen
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
    local oldClass = contact.class
    if obs.class then contact.class = obs.class end
    if obs.level then contact.level = obs.level end
    local wasTargeting = contact.targeting
    -- A restricted alias cannot erase another available source's clean evidence.
    -- Conversely, evidence vanishes when every active source becomes unreadable.
    self:Reconcile(contact)
    local oldStealth = contact.stealth
    if obs.stealthReadable then
        if obs.stealth == true then
            if not oldStealth then contact.stealthEvidence, contact.stealthSpell = "aura", nil end
            contact.stealth, contact.stealthAt = "confirmed", contact.stealthAt or now
        elseif obs.stealth == false then
            contact.stealth, contact.stealthAt, contact.stealthEvidence, contact.stealthSpell = nil, nil, nil, nil
        end
    end
    local returning = not wasVisible and away >= self.profile.alerts.returnAfter
    if returning then contact.encounterRecorded = false end
    self:RecordEncounter(contact)
    if not contact.arrivalNotified and not contact.arrivalQueued then
        contact.arrivalQueued = self:Queue(contact, "sighting")
    elseif returning then
        self:Queue(contact, "returning")
    end
    if not oldClass and contact.class and contact.arrivalNotified and not contact.notifiedClass then self:Queue(contact, "identified") end
    if contact.stealth and not oldStealth then self:Queue(contact, "stealth") end
    if contact.targeting and wasTargeting ~= true then self:Queue(contact, "targeting") end
    self:Changed()
    return self:View(contact)
end

function E:Remove(token)
    local binding = self.bindings[token]
    if not binding then return end
    local contact = self.contacts[binding.id]
    self.bindings[token] = nil
    if contact then
        contact.tokens[token] = nil
        if next(contact.tokens) == nil then
            contact.lastSeen = self:Now()
            contact.targeting, contact.currentTarget, contact.currentFocus = nil, nil, nil
        else self:Reconcile(contact) end
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
    self:RecordEncounter(contact)
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
    if not decision.sound and not decision.banner then return end
    self.counters.alerts = self.counters.alerts + 1
    U.ArrayPush(self.history, { at = now, kind = decision.kind, id = decision.contact and decision.contact.id, reason = decision.reason }, self.profile.retention.maxHistory)
    self.onAlert(decision)
end

function E:Tick()
    local now = self:Now()
    local resumed = self.pausedUntil and now >= self.pausedUntil
    if resumed then self.pausedUntil = nil end
    local ready, waiting = {}, {}
    for _, item in ipairs(self.pending) do
        if item.decision.priority >= 70 or now - item.at >= self.profile.alerts.waveWindow then ready[#ready + 1] = item
        else waiting[#waiting + 1] = item end
    end
    self.pending = waiting
    table.sort(ready, function(a, b)
        if a.decision.priority == b.decision.priority then return a.sequence < b.sequence end
        return a.decision.priority > b.decision.priority
    end)
    local ordinary, accepted = {}, {}
    for _, item in ipairs(ready) do
        local contact = self.contacts[item.id]
        local decision
        if contact and (item.event ~= "targeting" or contact.targeting == true) then
            decision = self:Explain(contact, item.event)
        end
        if decision and not (self.pausedUntil and now < self.pausedUntil) and not self:SnoozedUntil(contact) then
            local key = contact.id .. ":" .. (decision.dedupKey or decision.kind)
            if not accepted[key] and (not self.cooldowns[key] or now - self.cooldowns[key] >= decision.cooldown) then
                accepted[key] = true
                self.cooldowns[key] = now
                decision.contact = self:View(contact)
                contact.arrivalNotified, contact.arrivalQueued = true, false
                if contact.class then contact.notifiedClass = contact.class end
                if decision.priority < 70 and (decision.kind == "sighting" or decision.kind == "returning") then ordinary[#ordinary + 1] = decision
                else self:Emit(decision, now) end
            end
        elseif contact and item.event == "sighting" then
            contact.arrivalQueued = false
        end
    end
    if #ordinary >= self.profile.alerts.waveThreshold then
        local classes, sound, banner = {}, false, false
        for _, decision in ipairs(ordinary) do
            local class = decision.contact.class or "UNKNOWN"
            classes[class] = (classes[class] or 0) + 1
            sound, banner = sound or decision.sound, banner or decision.banner
        end
        self:Emit({ kind = "wave", count = #ordinary, classes = classes, priority = 35, sound = sound, banner = banner, reason = "multiple_sightings" }, now)
    else
        for _, decision in ipairs(ordinary) do self:Emit(decision, now) end
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

function E:Snapshot()
    local result = {}
    for _, contact in pairs(self.contacts) do
        local view = self:View(contact)
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
    self.history = {}
    self:Changed()
    return #discarded
end

function E:Clear()
    self.contacts, self.identities, self.bindings, self.pending, self.cooldowns = {}, {}, {}, {}, {}
    self.nameOwners, self.contactCount = {}, 0
    self.history = {}
    self:Changed()
end
