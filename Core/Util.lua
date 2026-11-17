local _, RG = ...
local U = RG.Register("Util", {})

function U.IsFinite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function U.Clamp(value, minimum, maximum, fallback)
    if not U.IsFinite(value) then return fallback end
    return math.max(minimum, math.min(maximum, value))
end

function U.Copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then error("cyclic data", 2) end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do result[key] = U.Copy(item, seen) end
    seen[value] = nil
    return result
end

function U.Count(value)
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

function U.Text(value, maximum)
    if type(value) ~= "string" or #value > (maximum or 160) then return nil end
    if value:find("[%z\1-\31\127]") or value:find("|", 1, true) then return nil end
    value = value:match("^%s*(.-)%s*$")
    if value == "" then return nil end
    return value
end

function U.ArrayPush(array, value, maximum)
    array[#array + 1] = value
    if #array > maximum then table.remove(array, 1) end
end

function U.SortedKeys(value)
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end
