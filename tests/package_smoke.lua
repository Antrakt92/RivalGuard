local packageRoot, testsRoot, manifest, interface = arg[1], arg[2], arg[3], tonumber(arg[4])
assert(packageRoot and testsRoot and manifest and interface and interface > 0, "invalid package smoke inputs")
local H = assert(loadfile(testsRoot .. "/tests/support/harness.lua"))()
RGTest = H
H.root = packageRoot
local W = assert(loadfile(testsRoot .. "/tests/support/wow.lua"))()
local function start(saved)
    local state = W.New()
    state.locale = interface == 16001 and "ruRU" or "enUS"
    state.api.GetBuildInfo = function() return "fixture", "archive", "", interface end
    state.api.RivalGuardDB = saved
    local RG = state:LoadTOC(manifest)
    state:Fire("ADDON_LOADED", "RivalGuard")
    local app = assert(RG.instance, "runtime did not start")
    assert(app.initialized, "packaged addon did not initialize")
    assert(app:Status().capabilities.interface == interface, "reported interface does not match simulated client")
    return state, RG, app
end

local function seeRival(state, unit, class, name)
    local guid = "Player-" .. class
    state:Unit(unit, { guid = guid, name = name, class = class, hostile = true, isPlayer = true })
    state:Fire("NAME_PLATE_UNIT_ADDED", unit)
    return "guid:" .. guid
end

local function assertPair(app, RG)
    local alerts = app.db:GetProfile().alerts
    assert(RG.Util.Count(alerts.classes) == 2 and alerts.classes.HUNTER and alerts.classes.ROGUE
        and not alerts.unknownClass, "packaged guide class selection did not apply or persist")
end

local function assertSighting(state, app, identity)
    assert(#app.engine:Snapshot() == 2, "packaged sensor did not report both fixtures")
    assert(#app.engine.history == 1 and #state.sounds == 1, "packaged class filter did not produce one alert")
    assert(app.ui.activeBanner and app.ui.activeBanner.identity == identity,
        "packaged class filter alerted for the wrong player")
end

local state, RG, app = start()
assert(type(state.api.SlashCmdList.RIVALGUARD) == "function", "packaged slash command unavailable")
local guide = assert(app.ui.guideDialog, "packaged first-run guide unavailable")
assert(guide:IsShown(), "packaged first-run guide did not open")
guide.next:Click()
guide.hunterRogue:Click()
assertPair(app, RG)
guide.openAlerts:Click()
assert(not guide:IsShown() and app.db:HasSeenGuide() and app.ui.currentPage == "alerts",
    "packaged first-run guide did not complete")

local rogue = seeRival(state, "nameplate1", "ROGUE", "Archive Rogue")
seeRival(state, "nameplate2", "MAGE", "Archive Mage")
state:Advance(2)
assertSighting(state, app, rogue)
assert(app.ui.rows[1]:IsShown() and app.ui.rows[2]:IsShown(), "packaged list did not render both fixtures")

-- The Python archive verifier supplies these validated bodies from the extracted XML.
local bindings = {}
for index = 5, #arg do
    local body = arg[index]
    local action = assert(body:match('^RivalGuard_Binding%("([a-z]+)"%)$'), "invalid packaged binding")
    bindings[action] = setfenv(assert(loadstring(body, "@Bindings.xml")), state.api)
end
local profile = app.db:GetProfile()
assert(profile.display.showList and profile.alerts.sound and not app.engine.pausedUntil, "unusable binding fixture state")
bindings.nearby()
assert(not profile.display.showList and not app.ui.frame:IsShown(), "packaged Nearby binding did not hide Nearby")
bindings.highlight()
local highlight = app.ui.badges.highlight
assert(highlight and highlight.unit == "nameplate1", "packaged alert highlight did not locate the fixture")
assert(not app.ui.frame:IsShown(), "packaged alert highlight opened Nearby")
bindings.nearby()
assert(profile.display.showList and app.ui.frame:IsShown(), "packaged Nearby binding did not restore Nearby")
bindings.pause()
assert(app.engine.pausedUntil and app.engine.pausedUntil > state.clock.Now(), "packaged pause binding did not pause alerts")
bindings.pause()
assert(not app.engine.pausedUntil, "packaged pause binding did not resume alerts")
bindings.mute()
assert(not profile.alerts.sound, "packaged mute binding did not mute sounds")
bindings.mute()
assert(profile.alerts.sound, "packaged mute binding did not restore sounds")

assert(app.diagnostics.counts.errors == nil or app.diagnostics.counts.errors == 0, "packaged addon recorded fixture errors")
state:Fire("PLAYER_LOGOUT")
assert(state.api.RivalGuardDB == app.db.root, "packaged addon did not preserve saved state")
local fresh, freshRG, reloaded = start(RG.Util.Copy(state.api.RivalGuardDB))
assert(reloaded.db:HasSeenGuide() and not reloaded.ui.guideDialog, "packaged first-run guide reopened after login")
assertPair(reloaded, freshRG)
seeRival(fresh, "nameplate1", "MAGE", "Archive Mage")
local hunter = seeRival(fresh, "nameplate2", "HUNTER", "Archive Hunter")
fresh:Advance(2)
assertSighting(fresh, reloaded, hunter)
assert(reloaded.diagnostics.counts.errors == nil or reloaded.diagnostics.counts.errors == 0,
    "packaged addon recorded fixture errors after login")
print(string.format("Packaged TOC %s / Interface %d completed setup, filtered alerts after login and exercised four bindings", manifest, interface))
