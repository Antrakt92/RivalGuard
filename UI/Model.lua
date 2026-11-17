local _, RG = ...
local M = RG.Register("UIModel", {})
local aliasState = setmetatable({}, { __mode = "k" })

local function clean(value)
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return nil end
    end
    return value
end

function M.Text(value, fallback, maximum)
    value = clean(value)
    if type(value) ~= "string" then return fallback or "" end
    return RG.Util.Text(value, maximum or 256) or fallback or ""
end

function M.Number(value, fallback)
    value = clean(value)
    if not RG.Util.IsFinite(value) then return fallback end
    return value
end

function M.ClassEnabled(classes, class)
    if type(classes) ~= "table" or next(classes) == nil then return true end
    return classes[class] == true
end

function M.ToggleClass(classes, class)
    local result = RG.Util.Copy(type(classes) == "table" and classes or {})
    if next(result) == nil then
        for _, token in ipairs(RG.Defaults.classes) do result[token] = true end
    end
    result[class] = not (result[class] == true)
    return result
end

function M.Age(seconds, locale)
    seconds = math.max(0, M.Number(seconds, 0))
    if seconds < 60 then return RG.Locale.Format("seconds", locale, math.floor(seconds)) end
    if seconds < 3600 then return RG.Locale.Format("minutes", locale, math.floor(seconds / 60)) end
    if seconds < 86400 then return RG.Locale.Format("hours", locale, math.floor(seconds / 3600)) end
    return RG.Locale.Format("days", locale, math.floor(seconds / 86400))
end

function M.Range(contact, locale)
    local low = M.Number(contact.rangeMin)
    local high = M.Number(contact.rangeMax)
    if low and low < 0 then low = nil end
    if high and high < 0 then high = nil end
    if low and high and low > high then return RG.Locale.Get("rangeUnknown", locale) end
    if low and high and low > 0 then
        return RG.Locale.Format("rangeBracket", locale, math.floor(low), math.ceil(high))
    end
    if high then return RG.Locale.Format("rangeWithin", locale, math.ceil(high)) end
    if low then return RG.Locale.Format("rangeBeyond", locale, math.floor(low)) end
    return RG.Locale.Get("rangeUnknown", locale)
end

function M.State(contact, now, locale)
    if clean(contact.visible) == true then
        if clean(contact.targeting) == true then return RG.Locale.Get("targeting", locale) end
        if clean(contact.stealth) == true or clean(contact.stealth) == "confirmed" then
            return RG.Locale.Get("stealth", locale)
        end
        return M.Range(contact, locale)
    end
    return RG.Locale.Format("lastSeen", locale, M.Age(now - M.Number(contact.lastSeen, now), locale))
end

function M.Rows(snapshot, profile, now, aliases)
    local rows = {}
    local display = profile.display
    local aliasCount = RG.Util.Count(aliases)
    if aliasCount >= 512 then
        local current = {}
        for _, contact in ipairs(snapshot or {}) do current[M.Text(contact.id, "anonymous")] = true end
        for id in pairs(aliases) do if not current[id] then aliases[id] = nil end end
        aliasCount = RG.Util.Count(aliases)
    end
    local state = aliasState[aliases]
    if not state then state = { serial = 0 }; aliasState[aliases] = state end
    for _, contact in ipairs(snapshot or {}) do
        local class = M.Text(contact.class, "")
        local known = RG.Defaults.classSet[class] == true
        if (known and M.ClassEnabled(display.classes, class)) or (not known and display.showUnknown) then
            local name = M.Text(contact.name, RG.Locale.Get("unknownPlayer", profile.locale))
            if display.streamer then
                local id = M.Text(contact.id, "anonymous")
                if not aliases[id] and aliasCount < 512 then
                    state.serial = state.serial + 1
                    aliases[id] = state.serial
                    aliasCount = aliasCount + 1
                end
                local className = known and RG.Locale.Class(class, profile.locale) or RG.Locale.Get("unknownClass", profile.locale)
                name = className .. " " .. (aliases[id] or (#rows + 1))
            end
            rows[#rows + 1] = {
                contact = contact, class = known and class or nil, name = name,
                detail = M.State(contact, now, profile.locale), visible = clean(contact.visible) == true,
            }
        end
    end
    return rows
end
