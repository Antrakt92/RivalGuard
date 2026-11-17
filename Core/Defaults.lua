local _, RG = ...
local D = RG.Register("Defaults", {})

D.classes = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "MONK", "DRUID", "DEMONHUNTER", "EVOKER" }
D.classSet = {}
for _, class in ipairs(D.classes) do D.classSet[class] = true end

D.soundOptions = { { "none", "soundNone" }, { "ping", "soundPing" }, { "warning", "soundWarning" },
    { "ready", "soundReady" }, { "whisper", "soundWhisper" }, { "quest", "soundQuest" } }
D.soundLabels = {}
for _, option in ipairs(D.soundOptions) do D.soundLabels[option[1]] = option[2] end

local STEALTH_SPELLS = {
    [1784] = "Stealth", [1785] = "Stealth", [1786] = "Stealth", [1787] = "Stealth", [8822] = "Stealth",
    [5215] = "Prowl", [6783] = "Prowl", [9913] = "Prowl",
    [1856] = "Vanish", [1857] = "Vanish", [11327] = "Vanish", [11329] = "Vanish",
    [20580] = "Shadowmeld", [58984] = "Shadowmeld", [66] = "Invisibility", [3680] = "Invisibility", [11392] = "Invisibility",
}
local CAMOUFLAGE = 199483

function D.StealthSpell(spellID, retailStealth)
    if retailStealth and spellID == CAMOUFLAGE then return "Camouflage" end
    return STEALTH_SPELLS[spellID]
end

function D.IsStealthAura(spellID, retailStealth)
    -- This legacy rank is tracked as a cast only.
    return spellID ~= 8822 and D.StealthSpell(spellID, retailStealth) ~= nil
end

function D.StealthAuraIDs(retailStealth)
    local ids = {}
    for id in pairs(STEALTH_SPELLS) do
        if D.IsStealthAura(id, retailStealth) then ids[#ids + 1] = id end
    end
    if retailStealth then ids[#ids + 1] = CAMOUFLAGE end
    table.sort(ids)
    return ids
end

D.profile = {
    enabled = true,
    preset = "balanced",
    locale = "auto",
    display = { classes = {}, showUnknown = true, maxRows = 8, scale = 1, textSize = 13, locked = false, showList = true, showEmpty = false, nearbyCollapsed = false, minimap = true, minimapAngle = 135, showBadges = true, badgeSize = 24, badgeOffset = 6, badgeTarget = true, badgeFocus = true, highlightTargeting = false, highContrast = false, reducedMotion = false, streamer = false },
    alerts = { enabled = true, sound = true, banner = true, channel = "Master", sounds = { sighting = "ping", returning = "ping", watch = "warning", targeting = "ready", stealth = "warning", wave = "ready" }, classes = {}, unknownClass = true, cooldown = 30, returnAfter = 45, soundGap = 1.5, waveWindow = 0.8, waveThreshold = 3, stealth = true, targeting = true, watchedOnly = false, muteOrdinary = false },
    context = { world = true, battleground = true, arena = false, instance = false, sanctuary = false, resting = false, flight = false },
    range = { enabled = false, yards = 40, policy = "possible", unknown = true },
    retention = { contactSeconds = 120, maxContacts = 256, journalDays = 7, journalMode = "all", maxJournal = 500, maxHistory = 200 },
    positions = {},
    rules = {},
}

function D.NewProfile(preset)
    local profile = RG.Util.Copy(D.profile)
    if preset == "quiet" then
        profile.alerts.sound = false
        profile.alerts.targeting = false
    elseif preset == "farming" then
        profile.alerts.classes = { ROGUE = true, HUNTER = true, DRUID = true }
        profile.alerts.cooldown = 60
    elseif preset == "battleground" then
        profile.context.world = false
        profile.context.battleground = true
        profile.alerts.muteOrdinary = true
        profile.alerts.targeting = false
    elseif preset ~= nil and preset ~= "balanced" then
        return nil, "unknown_preset"
    end
    profile.preset = preset or "balanced"
    return profile
end
