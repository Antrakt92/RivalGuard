local _, RG = ...
local Sensors = RG.Register("Sensors", {})
Sensors.__index = Sensors

local EVENTS = {
    "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "NAME_PLATE_UNIT_BEHIND_CAMERA_CHANGED",
    "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_SOFT_ENEMY_CHANGED",
    "UNIT_SPELLCAST_SUCCEEDED", "UNIT_AURA", "UNIT_FLAGS", "UNIT_FACTION", "UNIT_NAME_UPDATE", "UNIT_TARGET",
    "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
    "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_UPDATE_RESTING", "PLAYER_FLAGS_CHANGED",
    "ADDON_RESTRICTION_STATE_CHANGED", "SHARD_TRANSFER", "SHARD_TRANSFER_IMMINENT", "SHARD_TRANSFER_CANCELLED",
    "SPELLS_CHANGED", "PLAYER_SPECIALIZATION_CHANGED", "SPELL_DATA_LOAD_RESULT", "SPELL_TEXT_UPDATE",
    "PLAYER_EQUIPMENT_CHANGED", "UPDATE_SHAPESHIFT_FORM", "TRAIT_CONFIG_UPDATED",
}
local DIRECT = { target = true, focus = true, mouseover = true, softenemy = true }
local MAX_ACTIVE = 128
local MAX_PLATES = MAX_ACTIVE - RG.Util.Count(DIRECT)
local POLL_SECONDS = 0.25
local PLATE_PHASES = 4
local PLATE_RETRY_POLLS = 3
local PLATE_EVENTS = { NAME_PLATE_UNIT_ADDED = true, NAME_PLATE_UNIT_REMOVED = true }
local SAMPLE_BOUNDARY = {
    ADDON_RESTRICTION_STATE_CHANGED = true,
    PLAYER_REGEN_ENABLED = true, PLAYER_REGEN_DISABLED = true,
    ZONE_CHANGED_NEW_AREA = true, ZONE_CHANGED = true, ZONE_CHANGED_INDOORS = true,
    SHARD_TRANSFER = true, SHARD_TRANSFER_IMMINENT = true, SHARD_TRANSFER_CANCELLED = true,
}

function Sensors.New(app, client, api)
    return setmetatable({ app = app, client = client, api = api or _G, active = {}, plateRetries = {}, deferredPlates = {}, count = 0, plateCount = 0,
        generation = 0, elapsed = 0, phase = 0, running = false, loading = false }, Sensors)
end

function Sensors:Error(code)
    local diagnostics = self.app.diagnostics
    if diagnostics and diagnostics.Error then diagnostics:Error(code) end
end

function Sensors:Call(method, ...)
    local engine = self.app.engine
    if not engine or type(engine[method]) ~= "function" then return nil end
    local ok, a, b = pcall(engine[method], engine, ...)
    if not ok then self:Error("sensor_" .. method); return nil end
    return a, b
end

function Sensors:DeferPlate(token)
    local deferred = self.deferredPlates
    if #deferred >= MAX_PLATES then return end
    for _, queued in ipairs(deferred) do if queued == token then return end end
    deferred[#deferred + 1] = token
end

function Sensors:ForgetDeferredPlate(token)
    for index, queued in ipairs(self.deferredPlates) do
        if queued == token then table.remove(self.deferredPlates, index); return end
    end
end

function Sensors:Observe(token, source, behindCamera, event)
    token = self.client:IsToken(token)
    if not token then return end
    if not DIRECT[token] and not self.active[token] and self.plateCount >= MAX_PLATES then
        self.client:Count("sensor_capacity")
        self:DeferPlate(token)
        return
    end
    local state = self.active[token]
    local obs = self.client:ReadUnit(token, source, state and state.awaitingEligibility)
    if not obs then
        self:Remove(token)
        if not DIRECT[token] and RG.Util.Count(self.plateRetries) < MAX_PLATES then
            local frame = self.client:Nameplate(token)
            if frame then self.plateRetries[token] = { frame = frame, pollsLeft = PLATE_RETRY_POLLS } end
        end
        return
    end
    if event == "UNIT_TARGET" then obs.targetEvent = true
    elseif event == "UNIT_FACTION" then obs.factionEvent = true end
    self:Record(obs, behindCamera, event)
end

function Sensors:Record(obs, behindCamera, event)
    -- Unit events can arrive before the corresponding zone or resting event.
    -- Polling and seeding already share a snapshot for the whole batch.
    if event and obs.isPlayer ~= false and obs.hostile ~= false then
        self:Call("SetContext", self.client:Context())
    end
    local token = obs.token
    self.plateRetries[token] = nil
    local state = self.active[token]
    local name = obs.nameComplete and obs.name or nil
    local unverifiedName = state and state.unverifiedName
    if state then
        local guidChanged = state.guid and obs.guid and state.guid ~= obs.guid
        local nameChanged = (not state.guid or not obs.guid) and state.name and name and state.name ~= name
        -- Without plate lifecycle events, a token or pooled frame can silently change owners.
        local lostOwner = not DIRECT[token] and self.nameplateEvents == false
            and ((state.guid and not obs.guid) or (not state.guid and state.name and not name))
        if lostOwner and state.guid then unverifiedName = state.name end
        if guidChanged or nameChanged or lostOwner then
            self:Remove(token)
            state = nil
        end
    end
    if unverifiedName and (obs.guid or (name and name ~= unverifiedName)) then unverifiedName = nil end
    if unverifiedName and name == unverifiedName then
        -- Keep the readable label without rejoining the unverified previous GUID.
        name, obs.nameComplete = nil, false
    end
    if not state then
        if not DIRECT[token] then self:ForgetDeferredPlate(token) end
        self.generation = self.generation + 1
        state = { generation = self.generation }
        self.active[token], self.count = state, self.count + 1
        if not DIRECT[token] then self.plateCount = self.plateCount + 1 end
    end
    obs.generation = state.generation
    if behindCamera ~= nil then obs.behindCamera = behindCamera end
    state.guid, state.name = obs.guid or state.guid, name or state.name
    state.unverifiedName = unverifiedName
    state.awaitingEligibility = obs.isPlayer == false or obs.hostile == false
        or (state.awaitingEligibility and (obs.isPlayer ~= true or obs.hostile ~= true))
    local contact = self:Call("Observe", obs)
    local view = type(contact) == "table" and contact or nil
    state.contactID = view and view.id
    state.priority = obs.targeting == true or obs.currentTarget == true or obs.currentFocus == true
        or (view and (view.currentTarget == true or view.currentFocus == true))
    if type(self.app.UIContactUpdated) == "function" then
        local ok = pcall(self.app.UIContactUpdated, self.app, token, obs, contact)
        if not ok then self:Error("sensor_ui_contact") end
    end
end

function Sensors:Remove(token)
    token = self.client:IsToken(token)
    if not token then return end
    self.plateRetries[token] = nil
    if not DIRECT[token] then self:ForgetDeferredPlate(token) end
    self.client:ForgetToken(token)
    if not self.active[token] then return end
    self.active[token], self.count = nil, self.count - 1
    if not DIRECT[token] then self.plateCount = self.plateCount - 1 end
    self:Call("Remove", token)
    if type(self.app.OnTokenRemoved) == "function" then
        local ok = pcall(self.app.OnTokenRemoved, self.app, token)
        if not ok then self:Error("sensor_ui_remove") end
    end
end

function Sensors:Clear()
    self.plateRetries = {}
    self.deferredPlates = {}
    local tokens = {}
    for token in pairs(self.active) do tokens[#tokens + 1] = token end
    for _, token in ipairs(tokens) do self:Remove(token) end
end

function Sensors:WorldChanged()
    self:Clear()
    if type(self.app.OnWorldChanged) == "function" then
        local ok = pcall(self.app.OnWorldChanged, self.app)
        if not ok then self:Error("sensor_world_changed") end
    end
end

function Sensors:Seed(budget)
    if budget == 0 then return end
    local ns = self.api.C_NamePlate
    if type(ns) ~= "table" then return end
    local plates = self.client:Safe(ns.GetNamePlates)
    if type(plates) ~= "table" then return end
    local visited = 0
    for _, frame in ipairs(plates) do
        visited = visited + 1
        if visited > MAX_ACTIVE then break end
        local token = self.client:NameplateToken(frame)
        if token and not self.active[token] and not self.plateRetries[token] then
            self:Observe(token, "nameplate")
            if budget then
                budget = budget - 1
                if budget == 0 then break end
            end
        end
    end
end

function Sensors:RecoverPlates(budget)
    for token, retry in pairs(self.plateRetries) do
        retry.pollsLeft = retry.pollsLeft - 1
        if budget > 0 and self.plateCount < MAX_PLATES then
            budget = budget - 1
            if not rawequal(self.client:Nameplate(token), retry.frame) then
                self.plateRetries[token] = nil
            else
                local obs = self.client:ReadUnit(token, "nameplate")
                if obs then self:Record(obs) end
            end
        end
        if retry.pollsLeft == 0 then self.plateRetries[token] = nil end
    end
    return budget
end

function Sensors:RecoverDeferredPlates(budget)
    while budget > 0 and self.plateCount < MAX_PLATES and #self.deferredPlates > 0 do
        local token = table.remove(self.deferredPlates, 1)
        budget = budget - 1
        if not self.active[token] and not self.plateRetries[token] and self.client:Nameplate(token) then
            self:Observe(token, "nameplate")
        end
    end
    return budget
end

function Sensors:Poll(scheduled)
    if not self.running then return end
    self:Call("SetContext", self.client:Context())
    if not self.loading then
        local refresh = self.refreshSamples
        if refresh then
            -- The restriction event can precede activation. Discard any samples
            -- gathered by synchronous events before the transition completed.
            self.client:InvalidateRangeSamples()
            self.refreshSamples = nil
        end
        self.phase = (self.phase + 1) % PLATE_PHASES
        local targetChanged, focusChanged = self.targetChanged, self.focusChanged
        self.targetChanged, self.focusChanged = nil, nil
        local target = targetChanged and self.active.target
        local focus = focusChanged and self.active.focus
        local tokens = {}
        for token, state in pairs(self.active) do
            if not DIRECT[token] and (not scheduled or refresh or state.priority or state.generation % PLATE_PHASES == self.phase
                or (state.contactID and ((target and target.contactID == state.contactID) or (focus and focus.contactID == state.contactID)))
                or (targetChanged and self.client:UnitMatch(token, "target") == true)
                or (focusChanged and self.client:UnitMatch(token, "focus") == true)) then
                tokens[#tokens + 1] = token
            end
        end
        -- Retry last poll's unavailable plates using the same read budget.
        local budget = MAX_PLATES - #tokens
        if scheduled and next(self.plateRetries) then budget = self:RecoverPlates(budget) end
        if scheduled and #self.deferredPlates > 0 then budget = self:RecoverDeferredPlates(budget) end
        for _, token in ipairs(tokens) do self:Observe(token, "poll") end
        for token in pairs(DIRECT) do self:Observe(token, self.active[token] and "poll" or token) end
        -- Discovery still works at a bounded cadence when an event is denied.
        if (not scheduled or budget > 0) and (self.reseed or (scheduled and not self.nameplateEvents and self.phase == 0)) then
            self.reseed = nil
            self:Seed(scheduled and budget or nil)
        end
    end
    self:Call("Tick")
end

function Sensors:OnEvent(event, token, castGUID, spellID)
    if not self.running then return end
    if event == "SPELLS_CHANGED" or event == "PLAYER_SPECIALIZATION_CHANGED" or event == "SPELL_DATA_LOAD_RESULT"
        or event == "SPELL_TEXT_UPDATE" or event == "PLAYER_EQUIPMENT_CHANGED" or event == "UPDATE_SHAPESHIFT_FORM"
        or event == "TRAIT_CONFIG_UPDATED" then self.client:InvalidateRanges(); return end
    if event == "PLAYER_LEAVING_WORLD" then
        self.loading = true
        self.client:InvalidateRangeSamples()
        self:WorldChanged()
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        self.loading = false
        self.client:InvalidateRangeSamples()
        self.refreshSamples, self.reseed = nil, nil
        self:Clear()
        self:Call("SetContext", self.client:Context())
        self:Seed()
        self:Poll()
        return
    end
    if self.loading then return end
    if SAMPLE_BOUNDARY[event] then
        self.client:InvalidateRangeSamples()
        self.refreshSamples = true
        if event == "SHARD_TRANSFER" then self:WorldChanged(); self.reseed = true end
        self:Call("SetContext", self.client:Context())
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        token = self.client:IsToken(token)
        if token then self:Remove(token); self:Observe(token, "nameplate", nil, event) end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then self:Remove(token)
    elseif event == "PLAYER_TARGET_CHANGED" then self.targetChanged = true; self:Remove("target"); self:Observe("target", "target", nil, event)
    elseif event == "PLAYER_FOCUS_CHANGED" then self.focusChanged = true; self:Remove("focus"); self:Observe("focus", "focus", nil, event)
    elseif event == "UPDATE_MOUSEOVER_UNIT" then self:Remove("mouseover"); self:Observe("mouseover", "mouseover", nil, event)
    elseif event == "PLAYER_SOFT_ENEMY_CHANGED" then self:Remove("softenemy"); self:Observe("softenemy", "softenemy", nil, event)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        token = self.client:IsToken(token)
        spellID = self.client:Number(spellID)
        local state = token and self.active[token]
        if state and spellID and spellID > 0 and spellID == math.floor(spellID) then
            local engine = self.app.engine
            if engine and type(engine.TracksCast) == "function" and self:Call("TracksCast", spellID) ~= true then return end
            local obs = self.client:ReadUnit(token, "cast", state.awaitingEligibility)
            if obs and ((state.guid and obs.guid == state.guid) or (not state.guid and state.name and obs.nameComplete and obs.name == state.name)) then
                self:Record(obs, nil, event)
                if obs.isPlayer ~= false and obs.hostile ~= false then self:Call("Cast", token, spellID) end
            end
        end
    elseif event == "UNIT_AURA" or event == "UNIT_FLAGS" or event == "UNIT_FACTION" or event == "UNIT_NAME_UPDATE" or event == "UNIT_TARGET"
        or event == "NAME_PLATE_UNIT_BEHIND_CAMERA_CHANGED" then
        token = self.client:IsToken(token)
        if token and (self.active[token] or DIRECT[token]) then
            local behind
            if event == "NAME_PLATE_UNIT_BEHIND_CAMERA_CHANGED" then behind = self.client:Boolean(castGUID) end
            self:Observe(token, event == "UNIT_AURA" and "aura" or "unit", behind, event)
        end
    else self:Call("SetContext", self.client:Context()) end
end

function Sensors:Start()
    if self.running then return true end
    local frame = self.frame
    if not frame and type(self.api.CreateFrame) == "function" then
        local ok, created = pcall(self.api.CreateFrame, "Frame")
        if not ok or not created then self:Error("sensor_frame"); return false end
        frame, self.frame = created, created
    end
    self.running = true
    self.nameplateEvents = frame ~= nil
    if frame then
        for _, event in ipairs(EVENTS) do
            if self.client:Boolean(self.client:Safe(frame.RegisterEvent, frame, event)) ~= true then
                if PLATE_EVENTS[event] then self.nameplateEvents = false end
                self.client:Count("unsupported_events")
            end
        end
        frame:SetScript("OnEvent", function(_, ...) self:OnEvent(...) end)
        frame:SetScript("OnUpdate", function(_, elapsed)
            if not self.running then return end
            self.elapsed = self.elapsed + elapsed
            if self.elapsed >= POLL_SECONDS then self.elapsed = 0; self:Poll(true) end
        end)
    end
    self:Call("SetContext", self.client:Context())
    self:Seed()
    self:Poll()
    return true
end

function Sensors:Stop()
    if not self.running then return end
    self.running = false
    self.nameplateEvents = nil
    if self.frame then
        pcall(self.frame.UnregisterAllEvents, self.frame)
        self.frame:SetScript("OnEvent", nil)
        self.frame:SetScript("OnUpdate", nil)
    end
    self:Clear()
    -- Spellbook changes can occur while event handling is stopped.
    self.client:InvalidateRanges()
    self.elapsed, self.phase, self.loading = 0, 0, false
    self.refreshSamples, self.reseed, self.targetChanged, self.focusChanged = nil, nil, nil, nil
end
