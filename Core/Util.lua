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

local function validUTF8(text)
    local index = text:find("[\128-\255]")
    if not index then return true end
    while index <= #text do
        local first = text:byte(index)
        if first < 128 then index = index + 1
        else
            local length, point
            if first >= 194 and first <= 223 then length, point = 2, first - 192
            elseif first >= 224 and first <= 239 then length, point = 3, first - 224
            elseif first >= 240 and first <= 244 then length, point = 4, first - 240
            else return false end
            for offset = 1, length - 1 do
                local byte = text:byte(index + offset)
                if not byte or byte < 128 or byte > 191 then return false end
                point = point * 64 + byte - 128
            end
            if (length == 3 and point < 2048) or (length == 4 and point < 65536)
                or (point >= 55296 and point <= 57343) or point > 1114111
                or point <= 159 or (point >= 8234 and point <= 8238)
                or (point >= 8294 and point <= 8297) then return false end
            index = index + length
        end
    end
    return true
end

function U.Text(value, maximum)
    if type(value) ~= "string" or #value > (maximum or 160) then return nil end
    if value:find("[%z\1-\31\127]") or value:find("|", 1, true) then return nil end
    if not validUTF8(value) then return nil end
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
