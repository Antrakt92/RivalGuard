local H = RGTest
local function fixture()
    local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Diagnostics.lua", "Core/Audio.lua" })
    local profile = RG.Defaults.NewProfile()
    local calls = {}
    local api = { PlaySound = function(id, channel) calls[#calls + 1] = { id = id, channel = channel } return true end }
    local diag = RG.Diagnostics.New()
    return RG.Audio.New(api, function() return profile end, diag), profile, calls, api, diag
end

H.Test("audio respects master switches while explicit preview remains usable", function()
    local audio, profile, calls = fixture()
    H.True(audio:Play("sighting")); H.Equal(#calls, 1)
    profile.alerts.sound = false
    H.False(audio:Play("sighting")); H.Equal(#calls, 1)
    H.True(audio:Play("sighting", true)); H.Equal(#calls, 2)
    profile.enabled = false
    H.False(audio:Play("stealth")); H.Equal(#calls, 2)
end)

H.Test("audio event choices and channel apply without changing game volume", function()
    local audio, profile, calls, api = fixture()
    api.SetCVar = function() error("must not modify settings") end
    profile.alerts.sounds.stealth = "whisper"
    profile.alerts.channel = "Dialog"
    H.True(audio:Play("stealth")); H.Equal(calls[1].id, 3081); H.Equal(calls[1].channel, "Dialog")
    profile.alerts.sounds.stealth = "none"
    H.False(audio:Play("stealth")); H.Equal(#calls, 1)
end)

H.Test("audio handles missing failing and rejected playback without exception storms", function()
    local audio, _, _, api, diag = fixture()
    api.PlaySound = nil
    H.False(audio:Play("watch"))
    api.PlaySound = function() error("missing sound") end
    H.False(audio:Play("watch")); H.Equal(diag.counts.sound_unavailable, 1)
    api.PlaySound = function() return false end
    H.False(audio:Play("watch")); H.Equal(diag.counts.sound_unavailable, 2)
end)
