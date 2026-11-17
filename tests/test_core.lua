local H = RGTest

H.Test("module registry rejects duplicate ownership", function()
    local RG = H.Addon()
    H.Equal(RG.name, "RivalGuard")
    H.Equal(RG.modules[1], "Util")
    H.Throws(function() RG.Register("Util", {}) end, "duplicate module")
end)

H.Test("finite validation and clamping handle malformed numeric input", function()
    local U = H.Addon().Util
    for _, value in ipairs({ math.huge, -math.huge, "12", {}, false }) do
        H.False(U.IsFinite(value))
        H.Equal(U.Clamp(value, 1, 10, 4), 4)
    end
    H.False(U.IsFinite(0 / 0))
    H.True(U.IsFinite(0))
    H.Equal(U.Clamp(-1, 1, 10, 4), 1)
    H.Equal(U.Clamp(11, 1, 10, 4), 10)
    H.Equal(U.Clamp(5, 1, 10, 4), 5)
end)

H.Test("copies detach nested profile tables and reject cycles", function()
    local U = H.Addon().Util
    local source = { nested = { enabled = true } }
    local copy = U.Copy(source)
    copy.nested.enabled = false
    H.True(source.nested.enabled)
    local cycle = {}; cycle.self = cycle
    H.Throws(function() U.Copy(cycle) end, "cyclic data")
end)

H.Test("text fields preserve Unicode and reject markup or control characters", function()
    local U = H.Addon().Util
    H.Equal(U.Text("  Разбойник  "), "Разбойник")
    H.Nil(U.Text("|cffff0000Fake"))
    H.Nil(U.Text("line\nline"))
    H.Nil(U.Text("bad\0name"))
    H.Nil(U.Text("   "))
    H.Nil(U.Text("12345", 4))
    H.Nil(U.Text({}))
end)

H.Test("new profiles are independent and presets have meaningful defaults", function()
    local D = H.Addon().Defaults
    local first, second = D.NewProfile(), D.NewProfile()
    first.alerts.classes.ROGUE = false
    H.Nil(second.alerts.classes.ROGUE)
    H.Nil(D.profile.alerts.classes.ROGUE)
    local farming = D.NewProfile("farming")
    H.True(farming.alerts.classes.ROGUE)
    H.True(farming.alerts.classes.HUNTER)
    H.Nil(farming.alerts.classes.MAGE)
    H.False(D.NewProfile("quiet").alerts.sound)
    H.False(D.NewProfile("battleground").context.world)
    local invalid, reason = D.NewProfile("invalid")
    H.Nil(invalid); H.Equal(reason, "unknown_preset")
end)

H.Test("bounded queue retains newest entries in arrival order", function()
    local U = H.Addon().Util
    local queue = {}
    for index = 1, 10 do U.ArrayPush(queue, index, 3) end
    H.Equal(#queue, 3); H.Equal(queue[1], 8); H.Equal(queue[3], 10)
end)

H.Test("deterministic scheduler orders ties and cancels stale timers", function()
    local clock, events = H.Clock(), {}
    clock.After(1, function() events[#events + 1] = "first" end)
    local cancel = clock.After(1, function() events[#events + 1] = "cancelled" end)
    clock.After(1, function() events[#events + 1] = "second" end)
    cancel:Cancel()
    clock.Advance(0.5); H.Equal(#events, 0)
    clock.Advance(0.5)
    H.Equal(table.concat(events, ","), "first,second")
    H.Equal(clock.Now(), 1); H.Equal(clock.Pending(), 0)
end)
