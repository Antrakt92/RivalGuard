local H = RGTest

local function fixture(entries)
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Adapters/Range.lua", "Adapters/Client.lua", "Adapters/Sensors.lua" })
    entries = entries or { { id = 20, min = 0, max = 20 }, { id = 40, min = 0, max = 40 }, { id = 30, min = 8, max = 30 } }
    local time, calls, answers, alternate, counts = 0, { scan = 0, checks = 0, info = 0 }, {}, {}, {}
    local secret = H.Secret("range")
    local api = { Enum = { SpellBookSpellBank = { Player = 0 }, SpellBookItemType = { Spell = 1 } },
        issecretvalue = function(value) return value == secret end,
        GetTime = function() return time end,
        C_SpellBook = {}, C_Spell = {},
    }
    api.C_SpellBook.GetNumSpellBookSkillLines = function() calls.scan = calls.scan + 1; return 1 end
    api.C_SpellBook.GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = #entries } end
    api.C_SpellBook.GetSpellBookItemInfo = function(slot, bank)
        assert(bank == 0, "spellbook metadata queried with wrong bank")
        local entry = entries[slot]
        return { spellID = entry.id, itemType = entry.future and 2 or 1, isPassive = entry.passive or false, isOffSpec = entry.offSpec or false }
    end
    api.C_SpellBook.IsSpellKnown = function(id) for _, entry in ipairs(entries) do if entry.id == id then return not entry.unknown end end end
    api.C_Spell.IsSpellHarmful = function(id) for _, entry in ipairs(entries) do if entry.id == id then return not entry.helpful end end end
    api.C_Spell.GetSpellInfo = function(id)
        calls.info = calls.info + 1
        for _, entry in ipairs(entries) do if entry.id == id then return { minRange = entry.min, maxRange = entry.max } end end
    end
    api.C_SpellBook.IsSpellBookItemInRange = function(slot, bank, token)
        calls.checks = calls.checks + 1
        assert(bank == 0 and token == "target", "range queried with wrong bank or token")
        return answers[entries[slot].id]
    end
    api.C_Spell.IsSpellInRange = function(id) calls.checks = calls.checks + 1; return alternate[id] end
    local client = RG.Client.New(api, { Count = function(_, key, amount) counts[key] = (counts[key] or 0) + (amount or 1) end })
    return client.range, client, api, answers, alternate, calls, function(value) time = value end, secret, counts
end

H.Test("range combines confirmed zero-minimum spell probes into a useful bracket", function()
    local range, _, _, answers = fixture()
    answers[20], answers[40] = false, true
    local low, high, exclusive = range:Measure("target", "Player-A")
    H.Equal(low, 20); H.Equal(high, 40); H.True(exclusive)
end)

H.Test("range invalid and restricted checks never imply out of range", function()
    local range, _, _, answers, _, _, _, secret = fixture()
    answers[20], answers[40], answers[30] = secret, nil, nil
    local low, high = range:Measure("target", "Player-A")
    H.Nil(low); H.Nil(high)
end)

H.Test("range false nonzero-minimum probes do not invent a far distance", function()
    local range, _, _, answers = fixture({ { id = 30, min = 8, max = 30 } })
    answers[30] = false
    local low, high = range:Measure("target", "Player-A")
    H.Nil(low); H.Nil(high)
    answers[30] = true; range:Forget("target")
    low, high = range:Measure("target", "Player-A")
    H.Equal(low, 8); H.Equal(high, 30)
end)

H.Test("range all valid zero-minimum failures provide only a lower bound", function()
    local range, _, _, answers = fixture()
    answers[20], answers[40] = false, false
    local low, high, exclusive = range:Measure("target", "Player-A")
    H.Equal(low, 40); H.Nil(high); H.True(exclusive)
end)

H.Test("range cached lower bounds retain strict boundary semantics", function()
    local range, _, _, answers = fixture({ { id = 35, min = 0, max = 35 } })
    answers[35] = false
    local low, high, exclusive = range:Measure("target", "Player-A")
    H.Equal(low, 35); H.Nil(high); H.True(exclusive)
    low, high, exclusive = range:Measure("target", "Player-A")
    H.Equal(low, 35); H.Nil(high); H.True(exclusive)
    answers[35] = true; range:Forget("target")
    low, high, exclusive = range:Measure("target", "Player-A")
    H.Equal(low, 0); H.Equal(high, 35); H.False(exclusive)
end)

H.Test("range contradictory metadata probes become unknown", function()
    local range, _, _, answers, _, _, _, _, counts = fixture()
    answers[20], answers[40] = true, false
    local low, high = range:Measure("target", "Player-A")
    H.Nil(low); H.Nil(high); H.Equal(counts.range_conflicts, 1)
end)

H.Test("range direct spell fallback runs only after an invalid book answer", function()
    local range, _, _, answers, alternate, calls = fixture({ { id = 40, min = 0, max = 40 } })
    alternate[40] = true
    local low, high = range:Measure("target", "Player-A")
    H.Equal(low, 0); H.Equal(high, 40); H.Equal(calls.checks, 2)
    answers[40] = false; range:Forget("target")
    low, high = range:Measure("target", "Player-A")
    H.Equal(low, 40); H.Nil(high); H.Equal(calls.checks, 3)
end)

H.Test("range caches briefly by token and identity and forgets removed owners", function()
    local range, _, _, answers, _, calls, setTime = fixture({ { id = 40, min = 0, max = 40 } })
    answers[40] = true; range:Measure("target", "Player-A")
    range:Measure("target", "Player-A"); H.Equal(calls.checks, 1)
    setTime(0.5); range:Measure("target", "Player-A"); H.Equal(calls.checks, 2)
    range:Measure("target", "Player-B"); H.Equal(calls.checks, 3)
    range:Forget("target"); range:Measure("target", "Player-B"); H.Equal(calls.checks, 4)
end)

H.Test("range never reuses an anonymous sample and drops a previously known owner's sample", function()
    local range, _, _, answers, _, calls = fixture({ { id = 40, min = 0, max = 40 } })
    answers[40] = true
    local _, high = range:Measure("target", "Player-A")
    H.Equal(high, 40)
    answers[40] = false
    local low = range:Measure("target")
    H.Equal(low, 40)
    answers[40] = true
    low, high = range:Measure("target")
    H.Equal(low, 0); H.Equal(high, 40)
    answers[40] = false
    low, high = range:Measure("target", "Player-A")
    H.Equal(low, 40); H.Nil(high); H.Equal(calls.checks, 4)
end)

H.Test("range sample invalidation preserves spellbook metadata", function()
    local range, client, _, answers, _, calls = fixture({ { id = 40, min = 0, max = 40 } })
    answers[40] = true; range:Measure("target", "Player-A")
    client:InvalidateRangeSamples()
    answers[40] = false
    local low, high, exclusive = range:Measure("target", "Player-A")
    H.Equal(low, 40); H.Nil(high); H.True(exclusive)
    H.Equal(calls.scan, 1); H.Equal(calls.checks, 2)
end)

H.Test("range metadata invalidation is coalesced and never rescans absent APIs per sample", function()
    local range, _, api, _, _, calls, setTime = fixture()
    H.True(range:Available())
    range:Measure("target"); H.Equal(calls.scan, 1)
    range:Invalidate(); range:Invalidate(); range:Measure("target"); H.Equal(calls.scan, 1)
    setTime(1); range:Measure("target"); H.Equal(calls.scan, 2)
    api.C_SpellBook.GetSpellBookItemInfo = nil
    H.False(range:Available())
    range:Invalidate(); setTime(2); range:Measure("target"); range:Measure("target")
    H.Equal(calls.scan, 2); H.False(range.dirty)
end)

H.Test("range skips unknown passive future offspec helpful and invalid spells", function()
    local range = fixture({
        { id = 1, min = 0, max = 40, unknown = true }, { id = 2, min = 0, max = 40, passive = true },
        { id = 3, min = 0, max = 40, future = true }, { id = 4, min = 0, max = 40, offSpec = true },
        { id = 5, min = 0, max = 40, helpful = true }, { id = 6, min = 0, max = math.huge },
    })
    range:Measure("target")
    H.Equal(#range.bands, 0)
end)

H.Test("range bounds candidate metadata bands and total probes", function()
    local entries = {}
    for index = 1, 200 do entries[index] = { id = index, min = 0, max = 10 + index % 80 } end
    local range, _, _, _, _, calls = fixture(entries)
    range:Measure("target")
    H.Equal(calls.info, 128); H.True(#range.bands <= 16); H.True(calls.checks <= 8)
    entries = {}; for index = 1, 1500 do entries[index] = { id = index, min = 0, max = 40, future = true } end
    range, _, _, _, _, calls = fixture(entries)
    range:Measure("target")
    H.Equal(range.slotCount, 1024); H.Equal(calls.info, 0)
end)
