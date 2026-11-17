local _, RG = ...
local U = RG.Util
local Diag = RG.Register("Diagnostics", {})
Diag.__index = Diag

function Diag.New(clock)
    return setmetatable({ clock = clock or function() return 0 end, counts = {}, errors = {}, lastError = {}, started = 0 }, Diag)
end

local function code(value)
    if type(value) ~= "string" or #value > 64 or not value:match("^[%w_]+$") then return "other" end
    return value
end

function Diag:Count(key, amount)
    key = code(key)
    if self.counts[key] == nil and U.Count(self.counts) >= 63 then key = "other" end
    self.counts[key] = math.min(1000000000, (self.counts[key] or 0) + U.Clamp(amount, 0, 1000000, 1))
end

function Diag:Error(key)
    key = code(key)
    self:Count("errors")
    if self.lastError[key] == nil and U.Count(self.lastError) >= 63 then key = "other" end
    local now = self.clock()
    if self.lastError[key] and now - self.lastError[key] < 5 then return end
    self.lastError[key] = now
    U.ArrayPush(self.errors, { at = now, code = key }, 40)
end

function Diag:Snapshot()
    return { counts = U.Copy(self.counts), errors = U.Copy(self.errors) }
end

local contextKinds = { world = true, battleground = true, arena = true, instance = true }
local detectionStates = { active = true, limited = true, disabled = true }
local alertBlocks = { disabled = true, paused = true, context_disabled = true, sanctuary = true,
    resting = true, flight = true, outputs_disabled = true }
local queueBlocks = { "class_filtered", "contact_snoozed", "context_disabled", "cooldown", "custom_suppressed", "dead",
    "disabled", "event_disabled", "flight", "identity_unconfirmed", "ignored", "ordinary_muted", "outputs_disabled", "paused",
    "range_conflict", "range_outside", "range_unconfirmed", "range_unknown", "resting", "sanctuary", "unknown", "watch_only" }

local function knownValue(value, choices)
    return type(value) == "string" and choices[value] and value or "unknown"
end

local function booleanValue(value)
    return type(value) == "boolean" and tostring(value) or "unknown"
end

function Diag:Export(capabilities, engine, state)
    local lines = { "RivalGuard " .. RG.version, "Report excludes player names, GUIDs, notes and watch lists.", "Capabilities:" }
    for _, key in ipairs(U.SortedKeys(capabilities or {})) do
        local value = capabilities[key]
        if type(value) == "boolean" or U.IsFinite(value) then lines[#lines + 1] = "  " .. code(key) .. "=" .. tostring(value) end
    end
    if state then
        lines[#lines + 1] = "Current state:"
        lines[#lines + 1] = "  context=" .. knownValue(state.context, contextKinds)
        lines[#lines + 1] = "  detection=" .. knownValue(state.detection, detectionStates)
        lines[#lines + 1] = "  alertBlock=" .. (state.alertBlock == nil and "none" or knownValue(state.alertBlock, alertBlocks))
        lines[#lines + 1] = "  nameplates=" .. booleanValue(state.nameplates)
        lines[#lines + 1] = "  alwaysNameplates=" .. booleanValue(state.alwaysNameplates)
        for _, key in ipairs({ "deferredNameplates", "unconfirmedEnemyContacts" }) do
            local count = state[key]
            if U.IsFinite(count) and count >= 0 and count % 1 == 0 then lines[#lines + 1] = "  " .. key .. "=" .. count end
        end
    end
    lines[#lines + 1] = "Counters:"
    for _, key in ipairs(U.SortedKeys(self.counts)) do lines[#lines + 1] = "  " .. key .. "=" .. self.counts[key] end
    if engine then
        lines[#lines + 1] = "Session:"
        for _, key in ipairs(U.SortedKeys(engine.counters)) do lines[#lines + 1] = "  " .. key .. "=" .. engine.counters[key] end
        lines[#lines + 1] = "  contacts=" .. U.Count(engine.contacts)
        lines[#lines + 1] = "  pending=" .. #engine.pending
        if engine.queueBlocks then
            local heading = "Alert attempts blocked before queueing:"
            for _, reason in ipairs(queueBlocks) do
                local count = engine.queueBlocks[reason]
                if U.IsFinite(count) and count > 0 and count % 1 == 0 then
                    if heading then lines[#lines + 1] = heading; heading = nil end
                    lines[#lines + 1] = "  " .. reason .. "=" .. count
                end
            end
        end
    end
    lines[#lines + 1] = "Recent error codes:"
    for _, item in ipairs(self.errors) do lines[#lines + 1] = "  " .. item.code end
    return table.concat(lines, "\n")
end
