local packageRoot, testsRoot, manifest, interface = arg[1], arg[2], arg[3], tonumber(arg[4])
assert(packageRoot and testsRoot and manifest and interface and interface > 0, "invalid package smoke inputs")
local H = assert(loadfile(testsRoot .. "/tests/support/harness.lua"))()
RGTest = H
H.root = packageRoot
local W = assert(loadfile(testsRoot .. "/tests/support/wow.lua"))()
local state = W.New()
state.api.GetBuildInfo = function() return "fixture", "archive", "", interface end
state.api.RivalGuardDB = { schemaVersion = 1, onboardingSeen = true }
local RG = state:LoadTOC(manifest)
state:Fire("ADDON_LOADED", "RivalGuard")
local app = assert(RG.instance, "runtime did not start")
assert(app.initialized, "packaged addon did not initialize")
assert(app:Status().capabilities.interface == interface, "reported interface does not match simulated client")
assert(type(state.api.SlashCmdList.RIVALGUARD) == "function", "packaged slash command unavailable")
state:Unit("nameplate1", { guid = "Player-Archive", name = "Archive Rival", class = "ROGUE", hostile = true, isPlayer = true })
state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
state:Advance(2)
assert(#app.engine:Snapshot() == 1, "packaged sensor did not report the fixture")
assert(app.engine:Snapshot()[1].identity == "guid:Player-Archive", "packaged identity did not survive")
assert(app.ui.rows[1]:IsShown(), "packaged list did not render fixture")

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
print(string.format("Packaged TOC %s / Interface %d observed one fixture and exercised three binding bodies", manifest, interface))
