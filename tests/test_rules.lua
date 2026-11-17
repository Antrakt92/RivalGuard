local H = RGTest
local function setup()
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua" })
    return RG, RG.Defaults.NewProfile(), { id = "fixture", name = "Enemy", class = "ROGUE", hostile = true, isPlayer = true }
end

H.Test("default rules alert in world and remain quiet in excluded contexts", function()
    local RG, p, contact = setup()
    H.Equal(RG.Rules.Evaluate(p, contact, "sighting", { kind = "world" }).kind, "sighting")
    for _, context in ipairs({ { kind = "arena" }, { kind = "instance" }, { kind = "world", sanctuary = true }, { kind = "world", resting = true }, { kind = "world", flight = true } }) do
        H.Nil(RG.Rules.Evaluate(p, contact, "sighting", context))
    end
    H.Equal(RG.Rules.Evaluate(p, contact, "sighting", { kind = "battleground" }).kind, "sighting")
end)

H.Test("unknown identity never creates a confirmed hostile alert", function()
    local RG, p, contact = setup()
    for _, field in ipairs({ "hostile", "isPlayer" }) do
        contact[field] = nil
        local decision, reason = RG.Rules.Evaluate(p, contact, "sighting", {})
        H.Nil(decision); H.Equal(reason, "identity_unconfirmed")
        contact[field] = true
    end
    contact.hostile = false
    H.Nil(RG.Rules.Evaluate(p, contact, "sighting", {}))
end)

H.Test("display and audible class filters are independent", function()
    local RG, p, contact = setup()
    p.alerts.classes = { HUNTER = true }
    H.True(RG.Rules.Display(p, contact))
    H.Nil(RG.Rules.Evaluate(p, contact, "sighting", {}))
    p.display.classes = { MAGE = true }
    p.alerts.classes = { ROGUE = true }
    H.False(RG.Rules.Display(p, contact))
    H.Equal(RG.Rules.Evaluate(p, contact, "sighting", {}).kind, "sighting")
    contact.class = nil
    local unknown = assert(RG.Rules.Evaluate(p, contact, "sighting", {}))
    H.False(unknown.sound); H.True(unknown.banner)
    p.alerts.unknownClass = false
    H.Nil(RG.Rules.Evaluate(p, contact, "sighting", {}))
end)

H.Test("range policies distinguish possible confirmed and unavailable evidence", function()
    local RG, p, contact = setup()
    p.range.enabled = true; p.range.yards = 25
    contact.rangeMin, contact.rangeMax = 20, 30
    H.True(RG.Rules.RangeMatches(p.range, contact))
    p.range.policy = "confirmed"
    H.False(RG.Rules.RangeMatches(p.range, contact))
    contact.rangeMin, contact.rangeMax = 8, 20
    H.True(RG.Rules.RangeMatches(p.range, contact))
    contact.rangeMin, contact.rangeMax = nil, nil
    H.True(RG.Rules.RangeMatches(p.range, contact))
    p.range.unknown = false
    H.False(RG.Rules.RangeMatches(p.range, contact))
    p.range.policy = "possible"; contact.rangeMin, contact.rangeMax = 30, nil
    H.False(RG.Rules.RangeMatches(p.range, contact))
end)

H.Test("strictly beyond a range threshold is never possibly within that threshold", function()
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua" })
    local config = { enabled = true, policy = "possible", yards = 40, unknown = true }
    H.False(RG.Rules.RangeMatches(config, { rangeMin = 40, rangeMinExclusive = true }))
    H.True(RG.Rules.RangeMatches(config, { rangeMin = 40, rangeMinExclusive = false }))
    H.True(RG.Rules.RangeMatches(config, { rangeMin = 39, rangeMinExclusive = true }))
end)

H.Test("advanced rules apply only within selected context list and range conditions", function()
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua" })
    local p = RG.Defaults.NewProfile()
    p.rules = { { name = "Quiet close duel", enabled = true, priority = 90, classes = {}, event = "sighting",
        action = "suppress", context = "world", list = "unlisted", range = 30, rangePolicy = "confirmed", rangeUnknown = false } }
    local player = { class = "ROGUE", hostile = true, isPlayer = true, rangeMin = 20, rangeMax = 30 }
    local decision, reason = RG.Rules.Evaluate(p, player, "sighting", { kind = "world" })
    H.Nil(decision); H.Equal(reason, "custom_suppressed")
    H.Equal(assert(RG.Rules.Evaluate(p, player, "sighting", { kind = "battleground" })).kind, "sighting")
    H.Equal(assert(RG.Rules.Evaluate(p, player, "sighting", { kind = "world" }, { kind = "watch" })).kind, "watch")
    player.rangeMax = 35
    H.Equal(assert(RG.Rules.Evaluate(p, player, "sighting", { kind = "world" })).kind, "sighting")
    player.rangeMin, player.rangeMax = nil, nil
    H.Equal(assert(RG.Rules.Evaluate(p, player, "sighting", { kind = "world" })).kind, "sighting")
end)

H.Test("watch entries bypass ordinary class whitelist but never ignores or context", function()
    local RG, p, contact = setup()
    p.alerts.classes = { MAGE = true }
    local decision = assert(RG.Rules.Evaluate(p, contact, "sighting", {}, { kind = "watch" }))
    H.Equal(decision.kind, "watch"); H.Equal(decision.reason, "watch_list")
    H.Nil(RG.Rules.Evaluate(p, contact, "sighting", {}, { kind = "ignore" }))
    H.Nil(RG.Rules.Evaluate(p, contact, "sighting", { kind = "instance" }, { kind = "watch" }))
    p.alerts.watchedOnly = true
    H.Nil(RG.Rules.Evaluate(p, contact, "sighting", {}, { kind = "note" }))
end)

H.Test("custom rules select highest priority with deterministic suppress behavior", function()
    local RG, p, contact = setup()
    p.rules = {
        { name = "Low alert", enabled = true, priority = 20, event = "any", classes = {}, action = "alert", sound = true, banner = true, cooldown = 10 },
        { name = "High suppress", enabled = true, priority = 80, event = "sighting", classes = { ROGUE = true }, action = "suppress", sound = true, banner = true, cooldown = 10 },
    }
    local decision, reason = RG.Rules.Evaluate(p, contact, "sighting", {})
    H.Nil(decision); H.Equal(reason, "custom_suppressed")
    p.rules[2].enabled = false
    decision = assert(RG.Rules.Evaluate(p, contact, "sighting", {}))
    H.Equal(decision.ruleName, "Low alert"); H.Equal(decision.cooldown, 10)
end)

H.Test("event switches mute only their events and master output disables all", function()
    local RG, p, contact = setup()
    p.alerts.stealth = false; p.alerts.targeting = false
    H.Nil(RG.Rules.Evaluate(p, contact, "stealth", {}))
    H.Nil(RG.Rules.Evaluate(p, contact, "targeting", {}))
    H.True(type(RG.Rules.Evaluate(p, contact, "sighting", {})) == "table")
    p.alerts.sound = false; p.alerts.banner = false
    local decision, reason = RG.Rules.Evaluate(p, contact, "sighting", {})
    H.Nil(decision); H.Equal(reason, "outputs_disabled")
end)
