local _, RG = ...
local Sensors = RG.Register("Sensors", {})
Sensors.__index = Sensors

local EVENTS = {
    "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "NAME_PLATE_UNIT_BEHIND_CAMERA_CHANGED",
    "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_SOFT_ENEMY_CHANGED",
    "UNIT_SPELLCAST_SUCCEEDED", "UNIT_AURA", "UNIT_FLAGS", "UNIT_FACTION", "UNIT_NAME_UPDATE",
    "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED",
    "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_UPDATE_RESTING", "PLAYER_FLAGS_CHANGED",
}
local DIRECT = { target = true, focus = true, mouseover = true, softenemy = true }
local MAX_ACTIVE = 128

function Sensors.New(app, client, api)
    return setmetatable({ app = app, client = client, api = api or _G, active = {}, count = 0,
        generation = 0, elapsed = 0, running = false, loading = false }, Sensors)
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

function Sensors:Observe(token, source, behindCamera)
    token = self.client:IsToken(token)
    if not token then return end
    local obs = self.client:ReadUnit(token, source)
    if not obs then self:Remove(token); return end
    local state = self.active[token]
    if not state then
        if self.count >= MAX_ACTIVE then self.client:Count("sensor_capacity"); return end
        self.generation = self.generation + 1
        state = { generation = self.generation }
        self.active[token], self.count = state, self.count + 1
    end
    if (state.guid and obs.guid and state.guid ~= obs.guid)
        or (not state.guid and state.name and obs.name and state.name ~= obs.name) then
        self:Remove(token)
        self.generation = self.generation + 1
        state = { generation = self.generation }
        self.active[token], self.count = state, self.count + 1
    end
    obs.generation = state.generation
    if behindCamera ~= nil then obs.behindCamera = behindCamera end
    state.guid, state.name = obs.guid or state.guid, obs.name or state.name
    local contact = self:Call("Observe", obs)
    if type(self.app.UIContactUpdated) == "function" then
        local ok = pcall(self.app.UIContactUpdated, self.app, token, obs, contact)
        if not ok then self:Error("sensor_ui_contact") end
    end
end

function Sensors:Remove(token)
    token = self.client:IsToken(token)
    if not token or not self.active[token] then return end
    self.active[token], self.count = nil, self.count - 1
    self:Call("Remove", token)
    if type(self.app.OnTokenRemoved) == "function" then
        local ok = pcall(self.app.OnTokenRemoved, self.app, token)
        if not ok then self:Error("sensor_ui_remove") end
    end
end

function Sensors:Clear()
    local tokens = {}
    for token in pairs(self.active) do tokens[#tokens + 1] = token end
    for _, token in ipairs(tokens) do self:Remove(token) end
end

function Sensors:Seed()
    local ns = self.api.C_NamePlate
    if type(ns) ~= "table" then return end
    local plates = self.client:Safe(ns.GetNamePlates)
    if type(plates) ~= "table" then return end
    local visited = 0
    for _, frame in ipairs(plates) do
        visited = visited + 1
        if visited > MAX_ACTIVE then break end
        local forbidden = false
        if type(frame.IsForbidden) == "function" then forbidden = self.client:Boolean(self.client:Safe(frame.IsForbidden, frame)) ~= false end
        if not forbidden then
            local token = self.client:IsToken(frame.namePlateUnitToken)
            if token then self:Observe(token, "nameplate") end
        end
    end
end

function Sensors:Poll()
    if not self.running then return end
    self:Call("SetContext", self.client:Context())
    if not self.loading then
        local tokens = {}
        for token in pairs(self.active) do tokens[#tokens + 1] = token end
        for _, token in ipairs(tokens) do self:Observe(token, "poll") end
        for token in pairs(DIRECT) do if not self.active[token] then self:Observe(token, "poll") end end
    end
    self:Call("Tick")
end

function Sensors:OnEvent(event, token, castGUID, spellID)
    if not self.running then return end
    if event == "PLAYER_LEAVING_WORLD" then self.loading = true; self:Clear(); return end
    if event == "PLAYER_ENTERING_WORLD" then
        self.loading = false
        self:Clear()
        self:Call("SetContext", self.client:Context())
        self:Seed()
        self:Poll()
        return
    end
    if self.loading then return end
    if event == "NAME_PLATE_UNIT_ADDED" then
        token = self.client:IsToken(token)
        if token then self:Remove(token); self:Observe(token, "nameplate") end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then self:Remove(token)
    elseif event == "PLAYER_TARGET_CHANGED" then self:Remove("target"); self:Observe("target", "target")
    elseif event == "PLAYER_FOCUS_CHANGED" then self:Remove("focus"); self:Observe("focus", "focus")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then self:Remove("mouseover"); self:Observe("mouseover", "mouseover")
    elseif event == "PLAYER_SOFT_ENEMY_CHANGED" then self:Remove("softenemy"); self:Observe("softenemy", "softenemy")
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        token = self.client:IsToken(token)
        spellID = self.client:Number(spellID)
        local state = token and self.active[token]
        if state and spellID and spellID > 0 and spellID == math.floor(spellID) then
            local obs = self.client:ReadUnit(token, "cast")
            if obs and ((state.guid and obs.guid == state.guid) or (not state.guid and state.name and obs.name == state.name)) then
                self:Observe(token, "cast")
                self:Call("Cast", token, spellID)
            end
        end
    elseif event == "UNIT_AURA" or event == "UNIT_FLAGS" or event == "UNIT_FACTION" or event == "UNIT_NAME_UPDATE"
        or event == "NAME_PLATE_UNIT_BEHIND_CAMERA_CHANGED" then
        token = self.client:IsToken(token)
        if token and (self.active[token] or DIRECT[token]) then
            local behind
            if event == "NAME_PLATE_UNIT_BEHIND_CAMERA_CHANGED" then behind = self.client:Boolean(castGUID) end
            self:Observe(token, event == "UNIT_AURA" and "aura" or "unit", behind)
        end
    else self:Call("SetContext", self.client:Context()) end
end

function Sensors:Start()
    if self.running then return true end
    self.running = true
    if type(self.api.CreateFrame) == "function" then
        local ok, frame = pcall(self.api.CreateFrame, "Frame")
        if not ok or not frame then self.running = false; self:Error("sensor_frame"); return false end
        self.frame = frame
        for _, event in ipairs(EVENTS) do
            local registered = pcall(frame.RegisterEvent, frame, event)
            if not registered then self.client:Count("unsupported_events") end
        end
        frame:SetScript("OnEvent", function(_, ...) self:OnEvent(...) end)
        frame:SetScript("OnUpdate", function(_, elapsed)
            if not self.running then return end
            self.elapsed = self.elapsed + elapsed
            if self.elapsed >= 0.25 then self.elapsed = 0; self:Poll() end
        end)
    end
    self:Call("SetContext", self.client:Context())
    self:Seed()
    self:Poll()
    return true
end

function Sensors:Stop()
    self.running = false
    if self.frame then
        pcall(self.frame.UnregisterAllEvents, self.frame)
        self.frame:SetScript("OnEvent", nil)
        self.frame:SetScript("OnUpdate", nil)
        self.frame = nil
    end
    self:Clear()
    self.elapsed = 0
end
