local H = { tests = {}, assertions = 0, root = "." }

function H.Test(name, fn)
    assert(type(name) == "string" and type(fn) == "function", "invalid test")
    H.tests[#H.tests + 1] = { name = name, fn = fn }
end

function H.Equal(actual, expected, message)
    H.assertions = H.assertions + 1
    if actual ~= expected then
        local function describe(value)
            local ok, text = pcall(tostring, value)
            if not ok then return "<restricted>" end
            if #text > 160 then return text:sub(1, 160) .. "..." end
            return text
        end
        error((message or "values differ") .. ": expected " .. describe(expected) .. ", got " .. describe(actual), 2)
    end
end

function H.True(value, message) H.Equal(value, true, message) end
function H.False(value, message) H.Equal(value, false, message) end
function H.Nil(value, message) H.Equal(value, nil, message) end

function H.Throws(fn, pattern)
    H.assertions = H.assertions + 1
    local ok, err = pcall(fn)
    if ok then error("expected an error", 2) end
    if pattern and not tostring(err):find(pattern) then error("unexpected error: " .. tostring(err), 2) end
end

function H.Load(namespace, path, environment)
    local chunk = assert(loadfile(H.root .. "/" .. path))
    if environment then setfenv(chunk, environment) end
    chunk("RivalGuard", namespace)
end

function H.Addon(modules, environment)
    local namespace = {}
    for _, path in ipairs(modules or { "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua" }) do
        H.Load(namespace, path, environment)
    end
    return namespace
end

function H.Clock(start)
    local now = start or 0
    local pending, serial = {}, 0
    local clock = {}
    function clock.Now() return now end
    function clock.After(delay, fn)
        assert(type(delay) == "number" and delay >= 0, "invalid delay")
        serial = serial + 1
        local timer = { at = now + delay, fn = fn, serial = serial }
        function timer:Cancel() self.cancelled = true end
        pending[#pending + 1] = timer
        return timer
    end
    function clock.Advance(seconds)
        assert(type(seconds) == "number" and seconds >= 0, "invalid advance")
        local target, runs = now + seconds, 0
        while true do
            local chosen, index
            for i, timer in ipairs(pending) do
                if not timer.cancelled and timer.at <= target and
                    (not chosen or timer.at < chosen.at or (timer.at == chosen.at and timer.serial < chosen.serial)) then
                    chosen, index = timer, i
                end
            end
            if not chosen then break end
            table.remove(pending, index)
            now = chosen.at
            runs = runs + 1
            assert(runs <= 10000, "scheduler did not settle")
            chosen.fn()
        end
        now = target
    end
    function clock.Pending()
        local count = 0
        for _, timer in ipairs(pending) do if not timer.cancelled then count = count + 1 end end
        return count
    end
    return clock
end

function H.Secret(label)
    local function forbidden() error("restricted value used: " .. (label or "secret"), 2) end
    return setmetatable({}, { __tostring = forbidden, __add = forbidden, __sub = forbidden,
        __mul = forbidden, __div = forbidden, __mod = forbidden, __pow = forbidden,
        __unm = forbidden, __lt = forbidden, __le = forbidden, __index = forbidden,
        __newindex = forbidden, __metatable = "restricted" })
end

return H
