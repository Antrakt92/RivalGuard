local H = RGTest
local function addon()
    return H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Codec.lua" })
end

local function envelope(body)
    local a, b = 1, 0
    for index = 1, #body do a = (a + body:byte(index)) % 65521; b = (b + a) % 65521 end
    return "RG1:" .. body:gsub(".", function(c) return string.format("%02x", c:byte()) end) .. ":" .. string.format("%08x", b * 65536 + a)
end

H.Test("codec round trips nested profile values and Unicode without executing text", function()
    local C = addon().Codec
    local value = { title = "Разбойник — 猎人", enabled = false, scale = 1.25, values = { 1, true, false }, text = "os.execute('never run')" }
    local text = assert(C.Encode(value))
    local decoded = assert(C.Decode(text))
    H.Equal(decoded.title, value.title)
    H.False(decoded.enabled)
    H.Equal(decoded.scale, 1.25)
    H.Equal(decoded.values[1], 1)
    H.True(decoded.values[2]); H.False(decoded.values[3])
    H.Equal(decoded.text, value.text)
    H.Equal(C.Encode(decoded), text)
    H.False(C.Decode(assert(C.Encode(false))))
end)

H.Test("codec has canonical ordering independent of insertion order", function()
    local C = addon().Codec
    local first = { z = 2, a = 1, [2] = "second", [1] = "first" }
    local second = {}; second[1] = "first"; second.a = 1; second[2] = "second"; second.z = 2
    H.Equal(C.Encode(first), C.Encode(second))
end)

H.Test("codec decimal format is independent of the process numeric locale", function()
    local C = addon().Codec
    local localeString = setmetatable({}, { __index = string })
    function localeString.format(format, ...)
        local text = string.format(format, ...)
        if format == "%.17g" or format == "%.1f" then return text:gsub("%.", ",") end
        return text
    end
    local env = setmetatable({ string = localeString, tonumber = function(text, base)
        if text:find(".", 1, true) then return nil end
        return tonumber((text:gsub(",", ".")), base)
    end }, { __index = _G })
    local localized = {}
    H.Load(localized, "Core/Bootstrap.lua", env)
    H.Load(localized, "Core/Util.lua", env)
    H.Load(localized, "Core/Codec.lua", env)
    local data = { scale = 1.25, range = 17.5, small = -1.25e-100 }
    local encoded = assert(C.Encode(data))
    H.Equal(localized.Codec.Encode(data), encoded)
    local decoded = assert(localized.Codec.Decode(encoded))
    H.Equal(decoded.scale, data.scale)
    H.Equal(decoded.range, data.range)
    H.Equal(decoded.small, data.small)
end)

H.Test("codec rejects corrupt, truncated, trailing and executable imports", function()
    local C = addon().Codec
    local good = assert(C.Encode({ enabled = true }))
    local bad = good:sub(1, #good - 1) .. (good:sub(-1) == "0" and "1" or "0")
    H.Nil(C.Decode(bad))
    for _, body in ipairs({ "{1:s1:at", "{1:s1:at}garbage", "s20:short", "{2:s1:ats1:af}", "n3:inf", "n3:nan", "n3:1e+", "n0:", "x", "{257:}" }) do
        H.Nil(C.Decode(envelope(body)), "malformed body accepted: " .. body)
    end
    H.Nil(C.Decode("return os.execute('never run')"))
    H.Nil(C.Decode(string.rep("a", 65537)))
end)

H.Test("codec rejects unsupported values, cyclic and metatable-bearing data", function()
    local C = addon().Codec
    local cycle = {}; cycle.self = cycle
    H.Nil(C.Encode(cycle))
    H.Nil(C.Encode(setmetatable({}, {})))
    H.Nil(C.Encode({ value = function() end }))
    H.Nil(C.Encode({ value = math.huge }))
    H.Nil(C.Encode({ value = 0 / 0 }))
    H.Nil(C.Encode({ [false] = "bad key" }))
    H.Nil(C.Encode({ [0] = "bad key" }))
    H.Nil(C.Encode({ [1.5] = "bad key" }))
    H.Nil(C.Encode({ value = string.rep("a", 2049) }))
    local deep = {}; local cursor = deep
    for _ = 1, 10 do cursor.child = {}; cursor = cursor.child end
    H.Nil(C.Encode(deep))
end)

H.Test("every successfully encoded table respects decoder entry and byte limits", function()
    local C = addon().Codec
    local many = {}
    for index = 1, 257 do many["key" .. index] = true end
    H.Nil(C.Encode(many), "encoder must reject tables its decoder cannot import")
    for width = 2000, 2048 do
        local value = {}
        for index = 1, 16 do value["key" .. index] = string.rep("x", width) end
        local text = C.Encode(value)
        if text then
            H.True(#text <= 65536, "encoded envelope exceeds import limit")
            H.Equal(type(C.Decode(text)), "table", "successful encoding must remain decodable")
        end
    end
end)

H.Test("codec reproducibly round trips varied ordinary values", function()
    local C = addon().Codec
    for index = 1, 100 do
        local value = { name = "Fixture " .. index, enabled = index % 2 == 0, count = index * 7, nested = { index / 8, "a:b{}", index % 3 == 0 } }
        local encoded = assert(C.Encode(value))
        local decoded = assert(C.Decode(encoded))
        H.Equal(decoded.name, value.name); H.Equal(decoded.count, value.count)
        H.Equal(decoded.enabled, value.enabled); H.Equal(decoded.nested[1], value.nested[1])
        H.Equal(decoded.nested[2], value.nested[2]); H.Equal(decoded.nested[3], value.nested[3])
    end
end)
