local _, RG = ...
local M = RG.Register("UIModel", {})
local aliasState = setmetatable({}, { __mode = "k" })
local rangeEvidenceKeys = {
    exact = "rangeEvidenceExact", spell = "rangeEvidenceSpell", interaction = "rangeEvidenceInteraction",
    combined = "rangeEvidenceCombined", conflict = "rangeEvidenceConflict", unknown = "rangeEvidenceUnknown",
}
local stealthCastKeys = { Stealth = "spellStealth", Vanish = "spellVanish", Prowl = "spellProwl", Shadowmeld = "spellShadowmeld",
    Invisibility = "spellInvisibility", Camouflage = "spellCamouflage" }

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

function M.SearchText(value)
    local cleanText = M.Text(value, "", 512)
    -- Lua's lower handles Latin text only; fold Cyrillic for the Russian UI.
    return (cleanText:lower():gsub("[\208\209][\128-\191]", function(char)
        local lead, tail = char:byte(1, 2)
        if lead == 208 and tail == 129 then return string.char(209, 145) end
        if lead == 208 and tail >= 144 and tail <= 159 then return string.char(208, tail + 32) end
        if lead == 208 and tail >= 160 and tail <= 175 then return string.char(209, tail - 32) end
        return char
    end))
end

function M.Matches(query, name, note, searchName)
    if query == "" then return true end
    return (searchName or M.SearchText(name)):find(query, 1, true) ~= nil or M.SearchText(note):find(query, 1, true) ~= nil
end

function M.EditableIdentity(contact)
    if not contact or clean(contact.preview) == true then return nil end
    local identity = M.Text(contact.identity, "", 256)
    if not (identity:match("^guid:.+$") or identity:match("^name:.+$")) then return nil end
    if clean(contact.ambiguousIdentity) == true and not identity:match("^guid:.+$") then return nil end
    if clean(contact.savedOnly) == true and M.Text(contact.name, "") == "" then return nil end
    return identity
end

function M.Wave(classes, locale)
    if type(classes) ~= "table" then return "" end
    local items = {}
    for class, count in pairs(classes) do
        if RG.Defaults.classSet[class] or class == "UNKNOWN" then
            local number = M.Number(count)
            if number and number > 0 and number <= 512 and number % 1 == 0 then
                items[#items + 1] = { class = class, count = number }
            end
        end
    end
    table.sort(items, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.class < b.class
    end)
    local labels, extra = {}, 0
    for i, item in ipairs(items) do
        if i <= 2 then
            local name = RG.Locale.Class(item.class, locale)
            labels[#labels + 1] = RG.Locale.Format("waveClassCount", locale, item.count, name)
        else extra = extra + item.count end
    end
    if extra > 0 then labels[#labels + 1] = RG.Locale.Format("waveMore", locale, extra) end
    return table.concat(labels, " · ")
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

function M.ClearClasses()
    local classes = {}
    for _, class in ipairs(RG.Defaults.classes) do classes[class] = false end
    return classes
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
    local evidence = clean(contact.rangeEvidence)
    if evidence == "conflict" or evidence == "unknown" then return RG.Locale.Get("rangeUnknown", locale) end
    local low = M.Number(contact.rangeMin)
    local high = M.Number(contact.rangeMax)
    if low and (low < 0 or low > 10000) then low = nil end
    if high and (high < 0 or high > 10000) then high = nil end
    local exclusive = clean(contact.rangeMinExclusive) == true
    if low and high and (low > high or (low == high and exclusive)) then return RG.Locale.Get("rangeUnknown", locale) end
    if evidence == "exact" and low and low == high then
        local whole = math.floor(low)
        if low == whole then return RG.Locale.Format("rangeMeasured", locale, whole) end
        local hundredths = math.floor(low * 100 + 0.5)
        return RG.Locale.Format("rangeMeasuredApprox", locale, math.floor(hundredths / 100), hundredths % 100)
    end
    if low and high and (low > 0 or exclusive) then
        return RG.Locale.Format(exclusive and "rangeExclusiveBracket" or "rangeBracket", locale, math.floor(low), math.ceil(high))
    end
    if high then return RG.Locale.Format("rangeWithin", locale, math.ceil(high)) end
    if low then return RG.Locale.Format(exclusive and "rangeBeyond" or "rangeAtLeast", locale, math.floor(low)) end
    return RG.Locale.Get("rangeUnknown", locale)
end

function M.RangeProvenance(evidence, locale)
    local key = rangeEvidenceKeys[clean(evidence)]
    if key then return RG.Locale.Get(key, locale) end
end

function M.RangeDetails(contact, locale)
    if clean(contact.visible) ~= true or clean(contact.savedOnly) == true or clean(contact.preview) == true then return nil end
    local evidence = clean(contact.rangeEvidence)
    local provenance = M.RangeProvenance(evidence, locale)
    if not provenance then return nil end
    local range = M.Range(contact, locale)
    if evidence == "conflict" or evidence == "unknown" then return provenance, range end
    if range ~= RG.Locale.Get("rangeUnknown", locale) then return range .. " · " .. provenance, range end
end

function M.Stealth(contact, locale)
    local evidence = clean(contact.stealthEvidence)
    if evidence == "aura" then return RG.Locale.Get("stealthAura", locale) end
    if evidence == "cast" then
        local spell = clean(contact.stealthSpell)
        local key = stealthCastKeys[spell]
        if key then return RG.Locale.Format("stealthCast", locale, RG.Locale.Get(key, locale)) end
    end
    return RG.Locale.Get("stealth", locale)
end

function M.State(contact, now, locale)
    if clean(contact.visible) == true then
        if clean(contact.dead) == true then return RG.Locale.Get("dead", locale) end
        if clean(contact.hostile) == true and clean(contact.isPlayer) == true then
            if clean(contact.targeting) == true then return RG.Locale.Get("targeting", locale) end
            if clean(contact.stealth) == true or clean(contact.stealth) == "confirmed" then
                return M.Stealth(contact, locale)
            end
        end
        if clean(contact.behindCamera) == true then return RG.Locale.Get("behindCamera", locale) end
        return M.Range(contact, locale)
    end
    local lastSeen = M.Number(contact.lastSeen)
    if not lastSeen then return RG.Locale.Get("lastSeenUnknown", locale) end
    return RG.Locale.Format("lastSeen", locale, M.Age(now - lastSeen, locale))
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
        if clean(contact.preview) == true or (known and M.ClassEnabled(display.classes, class)) or (not known and display.showUnknown) then
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
