local H = RGTest
local modules = { "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Codec.lua", "Core/Database.lua" }

H.Test("UTF-8 validator rejects malformed sequences and unsafe directional controls", function()
    local RG = H.Addon(modules)
    local function bytes(...) return string.char(...) end
    for _, valid in ipairs({ "Ёж", "Épée", "火", "𐐀", "Player-Я", bytes(194, 160) }) do
        H.Equal(RG.Util.Text(valid), valid)
    end
    local malformed = {
        bytes(128), bytes(255), bytes(194), bytes(194, 65), bytes(192, 175),
        bytes(224, 128, 128), bytes(237, 160, 128), bytes(240, 143, 191, 191),
        bytes(244, 144, 128, 128), bytes(245, 128, 128, 128), bytes(194, 159),
        bytes(226, 128, 174), bytes(226, 129, 166),
    }
    for _, value in ipairs(malformed) do
        H.Nil(RG.Util.Text("Name" .. value))
    end
    local starterSeed = 271828
    for _ = 1, 256 do
        starterSeed = starterSeed * 16807 % 2147483647
        local outOfRangeStart = 128 + starterSeed % 64
        H.Nil(RG.Util.Text("Fixture " .. bytes(outOfRangeStart, 128)))
    end
end)

H.Test("advanced rule validation rejects malformed inputs atomically", function()
    local RG = H.Addon(modules)
    local db = RG.Database.New()
    local function check(path, value)
        local profile = RG.Defaults.NewProfile()
        local rule = { name = "Rule", classes = { ROGUE = true } }
        rule[path] = value
        profile.rules[1] = rule
        local text = assert(RG.Codec.Encode({ format = "RivalGuardProfile", schemaVersion = RG.schemaVersion, profile = profile }))
        local before = #db:ListProfiles()
        local imported = db:ImportProfile("Invalid " .. path, text)
        H.Nil(imported, "accepted invalid " .. path)
        H.Equal(#db:ListProfiles(), before)
    end
    local inputs = {
        { "context", "unexpected" }, { "context", 25 }, { "list", "watch" },
        { "range", -5 }, { "range", 4 }, { "range", 105 }, { "range", "30" },
        { "rangePolicy", "guaranteed" }, { "rangeUnknown", 1 }, { "priority", 2.5 },
        { "classes", { ["ROGUE "] = true } }, { "classes", { [1] = true } },
        { "classes", { ROGUE = 1 } }, { "classes", "ROGUE" }, { "classes", false },
        { "event", false }, { "action", false },
        { "name", "Broken" .. string.char(224, 128, 128) }, { "name", "|invalid" },
        { "name", "" }, { "enabled", 0 }, { "forced", true },
    }
    local rng = 73
    for _ = 1, #inputs do
        rng = rng * 16807 % 2147483647
        local index = rng % #inputs + 1
        local entry = table.remove(inputs, index)
        check(entry[1], entry[2])
    end
end)
