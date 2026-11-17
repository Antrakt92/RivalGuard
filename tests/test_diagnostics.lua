local H = RGTest
local function addon()
    return H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Diagnostics.lua" })
end

H.Test("diagnostic report excludes names GUIDs notes and arbitrary strings", function()
    local RG = addon()
    local clock = H.Clock(100)
    local diagnostics = RG.Diagnostics.New(clock.Now)
    diagnostics:Count("observations", 2)
    diagnostics:Error("Private Player Name: secret failure")
    local report = diagnostics:Export({ nameplates = true, classReadable = false, private = "PrivatePlayer" }, {
        counters = { alerts = 3 }, contacts = { ["PrivateGUID"] = { name = "PrivatePlayer", note = "PrivateNote" } }, pending = {},
    })
    H.True(report:find("observations=2", 1, true) ~= nil)
    H.Nil(report:find("PrivatePlayer", 1, true))
    H.Nil(report:find("PrivateGUID", 1, true))
    H.Nil(report:find("PrivateNote", 1, true))
    H.Nil(report:find("secret failure", 1, true))
    H.True(report:find("other", 1, true) ~= nil)
end)

H.Test("diagnostic errors throttle duplicate codes and snapshots are detached", function()
    local RG = addon()
    local clock = H.Clock(100)
    local diagnostics = RG.Diagnostics.New(clock.Now)
    diagnostics:Error("sensor_error"); diagnostics:Error("sensor_error")
    H.Equal(#diagnostics.errors, 1); H.Equal(diagnostics.counts.errors, 2)
    clock.Advance(5); diagnostics:Error("sensor_error")
    H.Equal(#diagnostics.errors, 2)
    local snapshot = diagnostics:Snapshot()
    snapshot.errors[1].code = "changed"; snapshot.counts.errors = 900
    H.Equal(diagnostics.errors[1].code, "sensor_error")
    H.Equal(diagnostics.counts.errors, 3)
end)

H.Test("diagnostic key and ring bounds survive long sessions of distinct errors", function()
    local RG = addon()
    local clock = H.Clock(100)
    local diagnostics = RG.Diagnostics.New(clock.Now)
    for index = 1, 1000 do
        diagnostics:Count("count_" .. index)
        diagnostics:Error("error_" .. index)
        clock.Advance(0.1)
    end
    H.True(RG.Util.Count(diagnostics.counts) <= 64)
    H.True(RG.Util.Count(diagnostics.lastError) <= 64)
    H.True(#diagnostics.errors <= 40)
end)
