local root, iterations, seed = arg[1] or ".", tonumber(arg[2]) or 20000, tonumber(arg[3]) or 17
assert(iterations >= 100 and iterations <= 1000000 and iterations == math.floor(iterations), "invalid iteration count")
local H = assert(loadfile(root .. "/tests/support/harness.lua"))()
H.root = root
local RG = H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Rules.lua", "Core/Engine.lua" })
local now, emitted = 100, 0
local profile = RG.Defaults.NewProfile()
profile.retention.maxContacts, profile.retention.maxHistory = 128, 50
local engine = RG.Engine.New({ clock = function() return now end, profile = profile, onAlert = function() emitted = emitted + 1 end })
local function choose(maximum)
    seed = (seed * 16807) % 2147483647
    return seed % maximum + 1
end
collectgarbage("collect")
local baseline, peak = collectgarbage("count"), collectgarbage("count")
local started = os.clock()
for index = 1, iterations do
    local token, player = "nameplate" .. choose(64), choose(512)
    engine:Observe({ token = token, guid = "Player-" .. player, name = "Enemy " .. player,
        class = RG.Defaults.classes[choose(#RG.Defaults.classes)], hostile = true, isPlayer = true,
        source = "nameplate", rangeMin = choose(20), rangeMax = 40 })
    if index % 3 == 0 then engine:Remove(token) end
    if index % 40 == 0 then engine:Snapshot() end
    now = now + 0.05
    engine:Tick()
    if index % 250 == 0 then peak = math.max(peak, collectgarbage("count")) end
end
local elapsed = os.clock() - started
peak = math.max(peak, collectgarbage("count"))
collectgarbage("collect")
local retained = collectgarbage("count") - baseline
local contacts, identities, pending, history = RG.Util.Count(engine.contacts), RG.Util.Count(engine.identities), #engine.pending, #engine.history
assert(contacts <= profile.retention.maxContacts and pending <= profile.retention.maxContacts and history <= profile.retention.maxHistory, "workload exceeded configured state bounds")
engine:Clear()
collectgarbage("collect")
local cleared = collectgarbage("count") - baseline
io.write(string.format('{"iterations":%d,"luaClockSeconds":%.6f,"luaClockMicrosecondsPerIteration":%.3f,"peakSampledKiBAboveBaseline":%.3f,"retainedKiBAboveBaseline":%.3f,"clearedKiBAboveBaseline":%.3f,"contacts":%d,"identities":%d,"pending":%d,"history":%d,"emitted":%d}\n',
    iterations, elapsed, elapsed * 1000000 / iterations, peak - baseline, retained, cleared, contacts, identities, pending, history, emitted))
