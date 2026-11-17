local H = RGTest
local W = assert(loadfile(H.root .. "/tests/support/wow.lua"))()

H.Test("disabling RivalGuard stops world sensing and clears live output without touching saved lists", function()
    local state = W.New()
    local RG = state:LoadTOC()
    state:Fire("ADDON_LOADED", "RivalGuard")
    local app = RG.instance
    local unit = { guid = "Player-1", name = "Rival", class = "ROGUE", hostile = true, player = true }
    state:Unit("nameplate1", unit)
    state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.True(app.sensors.running)
    assert(app.db:SetList("guid:Player-1", "watch", "Keep note"))
    local get = state.api.UnitGUID
    local reads = 0
    state.api.UnitGUID = function(...)
        reads = reads + 1
        return get(...)
    end
    app.db:GetProfile().enabled = false
    app:ProfileChanged()
    H.False(app.sensors.running)
    H.Equal(#app.engine:Snapshot(), 0)
    state:Advance(2)
    H.Equal(reads, 0)
    H.Equal(app.db:GetList()["guid:Player-1"].note, "Keep note")
    app.db:GetProfile().enabled = true
    app:ProfileChanged()
    H.True(app.sensors.running)
    H.True(reads > 0)
end)
