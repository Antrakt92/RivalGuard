local _, RG = ...
local Range = RG.Register("Range", {})
Range.__index = Range

local MAX_SLOTS, MAX_SPELLS, MAX_BANDS, MAX_CHECKS = 1024, 128, 16, 8

function Range.New(api, reader)
    return setmetatable({ api = api, reader = reader, bands = {}, cache = {}, cacheCount = 0, dirty = true }, Range)
end

function Range:Invalidate()
    self.dirty = true
    self:InvalidateSamples()
end

function Range:InvalidateSamples()
    self.cache, self.cacheCount = {}, 0
end

function Range:Forget(token)
    if self.cache[token] then self.cache[token], self.cacheCount = nil, self.cacheCount - 1 end
end

function Range:Field(record, key)
    if type(record) ~= "table" then return nil end
    return self.reader:Safe(function() return record[key] end)
end

function Range:Available()
    local api = self.api
    local book, spells, enum = api.C_SpellBook, api.C_Spell, api.Enum
    return type(book) == "table" and type(spells) == "table" and type(enum) == "table"
        and type(enum.SpellBookSpellBank) == "table" and type(enum.SpellBookItemType) == "table"
        and type(book.GetNumSpellBookSkillLines) == "function" and type(book.GetSpellBookSkillLineInfo) == "function"
        and type(book.GetSpellBookItemInfo) == "function" and type(book.IsSpellKnown) == "function"
        and type(spells.GetSpellInfo) == "function" and type(spells.IsSpellHarmful) == "function"
        and (type(book.IsSpellBookItemInRange) == "function" or type(spells.IsSpellInRange) == "function")
end

local function selectBands(catalog)
    local size = math.min(#catalog, MAX_BANDS)
    if size < 2 then return catalog end
    table.sort(catalog, function(a, b)
        if a.maximum == b.maximum then return a.minimum < b.minimum end
        return a.maximum > b.maximum
    end)

    local retained = {}
    for index = 1, size do
        local fraction = (index - 1) / (size - 1)
        retained[index] = catalog[math.floor(fraction * (#catalog - 1) + 0.5) + 1]
    end

    -- Sample both endpoints first, then subdivide gaps from broad to narrow.
    local ordered, gaps, cursor = { retained[1], retained[size] }, { { 1, size } }, 1
    while cursor <= #gaps do
        local gap = gaps[cursor]
        local first, last = gap[1], gap[2]
        if last - first > 1 then
            local middle = math.floor((first + last) / 2)
            ordered[#ordered + 1] = retained[middle]
            gaps[#gaps + 1] = { first, middle }
            gaps[#gaps + 1] = { middle, last }
        end
        cursor = cursor + 1
    end
    return ordered
end

function Range:Rebuild(now)
    if not self.dirty then return true end
    if self.waitingForClock and not now then return false end
    if self.lastBuild and (not now or (now >= self.lastBuild and now - self.lastBuild < 1)) then return false end
    self.dirty, self.lastBuild, self.bands = false, now, {}
    self.waitingForClock = nil
    self.reader:Count("range_rebuilds")
    if not self:Available() then return true end
    local api, read = self.api, self.reader
    local book, spells = api.C_SpellBook, api.C_Spell
    local bank, spellType = read:Number(api.Enum.SpellBookSpellBank.Player), read:Number(api.Enum.SpellBookItemType.Spell)
    if not bank or not spellType then return true end
    self.bank = bank
    local lines = read:Number(read:Safe(book.GetNumSpellBookSkillLines))
    if not lines or lines < 0 or lines > 128 or lines % 1 ~= 0 then
        -- A present API can be temporarily unreadable. Retry when a clean
        -- clock can bound rescans, without using the invalidated spellbook.
        self.dirty, self.waitingForClock = true, now == nil
        return false
    end
    local visited, candidates, seen = 0, 0, {}
    local catalog, byMaximum = {}, {}
    for lineIndex = 1, lines do
        local line = read:Safe(book.GetSpellBookSkillLineInfo, lineIndex)
        local offset = read:Number(self:Field(line, "itemIndexOffset"))
        local count = read:Number(self:Field(line, "numSpellBookItems"))
        local offSpec = self:Field(line, "offSpecID")
        if offset and count and offset >= 0 and offset % 1 == 0 and count >= 0 and count % 1 == 0 and offSpec == nil then
            for itemIndex = 1, math.min(count, MAX_SLOTS - visited) do
                visited = visited + 1
                local slot = offset + itemIndex
                local item = read:Safe(book.GetSpellBookItemInfo, slot, bank)
                local id = read:Number(self:Field(item, "spellID"))
                if id and id > 0 and id % 1 == 0 and not seen[id]
                    and read:Number(self:Field(item, "itemType")) == spellType
                    and read:Boolean(self:Field(item, "isPassive")) == false
                    and read:Boolean(self:Field(item, "isOffSpec")) == false
                    and read:Boolean(read:Safe(book.IsSpellKnown, id, bank)) == true
                    and read:Boolean(read:Safe(spells.IsSpellHarmful, id)) == true then
                    seen[id], candidates = true, candidates + 1
                    local info = read:Safe(spells.GetSpellInfo, id)
                    local minimum = read:Number(self:Field(info, "minRange"))
                    local maximum = read:Number(self:Field(info, "maxRange"))
                    if minimum and maximum and minimum >= 0 and maximum > minimum and maximum <= 100 then
                        local byMinimum = byMaximum[maximum]
                        if not byMinimum then byMinimum = {}; byMaximum[maximum] = byMinimum end
                        local band = byMinimum[minimum]
                        if not band then
                            band = { minimum = minimum, maximum = maximum, spells = {} }
                            byMinimum[minimum] = band
                            catalog[#catalog + 1] = band
                        end
                        if #band.spells < 2 then band.spells[#band.spells + 1] = { id = id, slot = slot } end
                    end
                    if candidates >= MAX_SPELLS then break end
                end
            end
        end
        if visited >= MAX_SLOTS or candidates >= MAX_SPELLS then break end
    end
    self.bands = selectBands(catalog)
    self.slotCount = visited
    return true
end

function Range:Measure(token, identity)
    local read, api = self.reader, self.api
    token = read:IsToken(token)
    if not token then return nil, nil, false, false end
    identity = read:Text(identity, 200)
    if not identity then self:Forget(token) end
    local now = read:Number(read:Safe(api.GetTime))
    if not self:Rebuild(now) then return nil, nil, false, false end
    local cached = self.cache[token]
    if now and cached and cached.identity == identity and now >= cached.at and now - cached.at < 0.5 then
        return cached.minimum, cached.maximum, cached.minimumExclusive, cached.conflict, cached.sampledAt
    end
    local book, spells = api.C_SpellBook, api.C_Spell
    local lower, upper, lowerExclusive, checks = nil, nil, false, 0
    local resolved = {}
    for spellIndex = 1, 2 do
        for bandIndex, band in ipairs(self.bands) do
            local spell = band.spells[spellIndex]
            if spell and not resolved[bandIndex] then
                local result
                if type(book.IsSpellBookItemInRange) == "function" and checks < MAX_CHECKS then
                    checks = checks + 1
                    result = read:Boolean(read:Safe(book.IsSpellBookItemInRange, spell.slot, self.bank, token))
                end
                if result == nil and type(spells.IsSpellInRange) == "function" and checks < MAX_CHECKS then
                    checks = checks + 1
                    result = read:Boolean(read:Safe(spells.IsSpellInRange, spell.id, token))
                end
                if result ~= nil then
                    resolved[bandIndex] = true
                    if result then
                        if not lower or band.minimum > lower then lower, lowerExclusive = band.minimum, false end
                        upper = math.min(upper or math.huge, band.maximum)
                    elseif band.minimum == 0 and (not lower or band.maximum >= lower) then
                        lower, lowerExclusive = band.maximum, true
                    end
                end
            end
            if checks >= MAX_CHECKS then break end
        end
        if checks >= MAX_CHECKS then break end
    end
    read:Count("range_samples")
    if read.diagnostics and read.diagnostics.Count then read.diagnostics:Count("range_checks", checks) end
    local conflict = lower ~= nil and upper ~= nil and (lower > upper or (lower == upper and lowerExclusive))
    if conflict then
        lower, upper, lowerExclusive = nil, nil, false
        read:Count("range_conflicts")
    end
    local sampledAt
    if lower ~= nil or upper ~= nil or conflict then sampledAt = now end
    if now and identity then
        if not self.cache[token] then
            if self.cacheCount >= 128 then self.cache, self.cacheCount = {}, 0 end
            self.cacheCount = self.cacheCount + 1
        end
        self.cache[token] = { identity = identity, at = now, minimum = lower, maximum = upper,
            minimumExclusive = lowerExclusive, conflict = conflict, sampledAt = sampledAt }
    end
    return lower, upper, lowerExclusive, conflict, sampledAt
end
