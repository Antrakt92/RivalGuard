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

function Diag:Export(capabilities, engine)
    local lines = { "RivalGuard " .. RG.version, "Report excludes player names, GUIDs, notes and watch lists.", "Capabilities:" }
    for _, key in ipairs(U.SortedKeys(capabilities or {})) do
        local value = capabilities[key]
        if type(value) == "boolean" or U.IsFinite(value) then lines[#lines + 1] = "  " .. code(key) .. "=" .. tostring(value) end
    end
    lines[#lines + 1] = "Counters:"
    for _, key in ipairs(U.SortedKeys(self.counts)) do lines[#lines + 1] = "  " .. key .. "=" .. self.counts[key] end
    if engine then
        lines[#lines + 1] = "Session:"
        for _, key in ipairs(U.SortedKeys(engine.counters)) do lines[#lines + 1] = "  " .. key .. "=" .. engine.counters[key] end
        lines[#lines + 1] = "  contacts=" .. U.Count(engine.contacts)
        lines[#lines + 1] = "  pending=" .. #engine.pending
    end
    lines[#lines + 1] = "Recent error codes:"
    for _, item in ipairs(self.errors) do lines[#lines + 1] = "  " .. item.code end
    return table.concat(lines, "\n")
end
