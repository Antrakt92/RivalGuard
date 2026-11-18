local _, RG = ...
local C = RG.Register("Codec", {})
local LIMIT_BYTES, LIMIT_NODES, LIMIT_DEPTH = 65536, 4096, 8

local function decimalMark()
    return string.format("%.1f", 1.5):match("^1(.+)5$") or "."
end

local function replaceDecimal(text, from, to)
    if from == to then return text end
    local first, last = text:find(from, 1, true)
    if not first then return text end
    return text:sub(1, first - 1) .. to .. text:sub(last + 1)
end

local function checksum(text)
    local a, b = 1, 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%08x", b * 65536 + a)
end

function C.Encode(value)
    local nodes, active = 0, {}
    local decimal = decimalMark()
    local function encode(item, depth)
        nodes = nodes + 1
        if nodes > LIMIT_NODES or depth > LIMIT_DEPTH then error("data_too_complex", 0) end
        local kind = type(item)
        if kind == "boolean" then return item and "t" or "f" end
        if kind == "number" then
            if not RG.Util.IsFinite(item) then error("invalid_number", 0) end
            local text = replaceDecimal(string.format("%.17g", item), decimal, ".")
            return "n" .. #text .. ":" .. text
        end
        if kind == "string" then
            if #item > 2048 then error("string_too_long", 0) end
            return "s" .. #item .. ":" .. item
        end
        if kind ~= "table" or getmetatable(item) ~= nil or active[item] then error("invalid_table", 0) end
        active[item] = true
        local keys = {}
        for key in pairs(item) do
            if type(key) ~= "string" and type(key) ~= "number" then error("invalid_key", 0) end
            if type(key) == "number" and (not RG.Util.IsFinite(key) or key % 1 ~= 0 or key < 1 or key > 256) then error("invalid_key", 0) end
            keys[#keys + 1] = key
            if #keys > 256 then error("too_many_entries", 0) end
        end
        table.sort(keys, function(a, b)
            if type(a) ~= type(b) then return type(a) < type(b) end
            return a < b
        end)
        local parts = { "{", tostring(#keys), ":" }
        for _, key in ipairs(keys) do
            parts[#parts + 1] = encode(key, depth + 1)
            parts[#parts + 1] = encode(item[key], depth + 1)
        end
        parts[#parts + 1] = "}"
        active[item] = nil
        local text = table.concat(parts)
        if #text > math.floor((LIMIT_BYTES - 13) / 2) then error("data_too_large", 0) end
        return text
    end
    local ok, body = pcall(encode, value, 0)
    if not ok then return nil, body end
    if #body > math.floor((LIMIT_BYTES - 13) / 2) then return nil, "data_too_large" end
    local hex = body:gsub(".", function(char) return string.format("%02x", char:byte()) end)
    return "RG1:" .. hex .. ":" .. checksum(body)
end

function C.Decode(text)
    if type(text) ~= "string" or #text > LIMIT_BYTES then return nil, "data_too_large" end
    local hex, digest = text:match("^RG1:([0-9a-fA-F]+):([0-9a-fA-F]+)$")
    if not hex or #hex % 2 ~= 0 or #digest ~= 8 then return nil, "invalid_format" end
    local body = hex:gsub("..", function(byte) return string.char(tonumber(byte, 16)) end)
    if checksum(body) ~= digest:lower() then return nil, "checksum_mismatch" end
    local position, nodes = 1, 0
    local decimal = decimalMark()
    local function length()
        local start, stop, digits = body:find("^(%d+):", position)
        if not start or #digits > 5 then error("invalid_length", 0) end
        local count = tonumber(digits)
        position = stop + 1
        if count > LIMIT_BYTES then error("invalid_length", 0) end
        return count
    end
    ---@return boolean|string|number|table
    local function decode(depth)
        nodes = nodes + 1
        if nodes > LIMIT_NODES or depth > LIMIT_DEPTH then error("data_too_complex", 0) end
        local tag = body:sub(position, position)
        position = position + 1
        if tag == "t" then return true end
        if tag == "f" then return false end
        if tag == "s" or tag == "n" then
            local count = length()
            if count > 2048 or position + count - 1 > #body then error("invalid_length", 0) end
            local value = body:sub(position, position + count - 1)
            position = position + count
            if tag == "s" then return value end
            if not value:match("^[%+%-]?%d*%.?%d+[eE]?[%+%-]?%d*$") then error("invalid_number", 0) end
            local number = tonumber(replaceDecimal(value, ".", decimal))
            if not number or not RG.Util.IsFinite(number) then error("invalid_number", 0) end
            return number
        end
        if tag ~= "{" then error("invalid_tag", 0) end
        local count = length()
        if count > 256 then error("too_many_entries", 0) end
        local value = {}
        for _ = 1, count do
            local key = decode(depth + 1)
            if type(key) ~= "string" and type(key) ~= "number" then error("invalid_key", 0) end
            if type(key) == "number" and (key < 1 or key > 256 or key % 1 ~= 0) then error("invalid_key", 0) end
            if value[key] ~= nil then error("duplicate_key", 0) end
            value[key] = decode(depth + 1)
        end
        if body:sub(position, position) ~= "}" then error("invalid_table", 0) end
        position = position + 1
        return value
    end
    local ok, value = pcall(decode, 0)
    if not ok then return nil, value end
    if position ~= #body + 1 then return nil, "trailing_data" end
    return value
end
