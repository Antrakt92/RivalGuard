local _, RG = ...
local Audio = RG.Register("Audio", {})
Audio.__index = Audio

Audio.choices = { "none", "ping", "warning", "ready", "whisper", "quest" }
local SOUNDS = {
    ping = { kit = "MAP_PING", fallback = 3175 },
    warning = { kit = "RAID_WARNING", fallback = 8959 },
    ready = { kit = "READY_CHECK", fallback = 8960 },
    whisper = { kit = "TELL_MESSAGE", fallback = 3081 },
    quest = { kit = "IG_QUEST_LIST_COMPLETE", fallback = 878 },
}
local CHANNELS = { Master = true, SFX = true, Music = true, Ambience = true, Dialog = true }

function Audio.New(api, getProfile, diagnostics)
    return setmetatable({ api = api or _G, getProfile = getProfile, diagnostics = diagnostics }, Audio)
end

function Audio:Play(kind, preview)
    local profile = self.getProfile()
    if not preview and (not profile.enabled or not profile.alerts.enabled or not profile.alerts.sound) then return false end
    local choice = profile.alerts.sounds[kind] or "ping"
    if choice == "none" then return false end
    local spec = SOUNDS[choice]
    if not spec then
        if self.diagnostics then self.diagnostics:Count("invalid_sound") end
        return false
    end
    local kit = self.api.SOUNDKIT and self.api.SOUNDKIT[spec.kit] or spec.fallback
    if type(kit) ~= "number" or not RG.Util.IsFinite(kit) or kit <= 0 or type(self.api.PlaySound) ~= "function" then return false end
    local channel = CHANNELS[profile.alerts.channel] and profile.alerts.channel or "Master"
    local ok, played = pcall(self.api.PlaySound, kit, channel)
    if not ok or played == false then
        if self.diagnostics then self.diagnostics:Count("sound_unavailable") end
        return false
    end
    return true
end
