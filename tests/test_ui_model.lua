local H = RGTest
local function addon()
    return H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Locale/Strings.lua", "UI/Model.lua" })
end

H.Test("range labels convey intervals and reject invalid numbers", function()
    local RG = addon()
    local M = RG.UIModel
    H.Equal(M.Range({ rangeMin = 8, rangeMax = 20 }, "enUS"), RG.Locale.Format("rangeBracket", "enUS", 8, 20))
    H.Equal(M.Range({ rangeMin = 20, rangeMax = 8 }, "enUS"), RG.Locale.Get("rangeUnknown", "enUS"))
    H.Equal(M.Range({ rangeMin = 0 / 0, rangeMax = math.huge }, "enUS"), RG.Locale.Get("rangeUnknown", "enUS"))
    H.Equal(M.Range({ rangeMin = 0, rangeMax = 10 }, "enUS"), RG.Locale.Format("rangeWithin", "enUS", 10))
end)

H.Test("range provenance requires live compatible evidence", function()
    local RG = addon()
    local M, L = RG.UIModel, RG.Locale
    H.Nil(M.RangeDetails({ visible = true, rangeEvidence = "exact" }, "enUS"))
    H.Nil(M.RangeDetails({ visible = true, rangeEvidence = "spell", rangeMin = 20, rangeMax = 8 }, "enUS"))
    H.Nil(M.RangeDetails({ visible = true, rangeEvidence = "combined", rangeMax = 20, preview = true }, "enUS"))
    H.Nil(M.RangeDetails({ visible = true, rangeEvidence = "interaction", rangeMax = 20, savedOnly = true }, "enUS"))
    H.Nil(M.RangeProvenance("unsupported", "enUS"))
    H.Equal(M.RangeDetails({ visible = true, rangeEvidence = "unknown" }, "enUS"), L.Get("rangeEvidenceUnknown", "enUS"))
    H.Equal(M.Range({ rangeEvidence = "conflict", rangeMax = 20 }, "enUS"), L.Get("rangeUnknown", "enUS"))
end)

H.Test("range labels retain inclusive and exclusive bounds and localize measured decimals", function()
    local RG = addon()
    local format = RG.UIModel.Range
    H.Equal(format({ rangeEvidence = "exact", rangeMin = 0, rangeMax = 0 }, "enUS"), "0 yd")
    H.Equal(format({ rangeEvidence = "exact", rangeMin = 20.04, rangeMax = 20.04 }, "ruRU"), "≈20,04 ярд.")
    H.Equal(format({ rangeMin = 20, rangeMinExclusive = true, rangeMax = 28 }, "enUS"), ">20 · ≤28 yd")
    H.Equal(format({ rangeMin = 20, rangeMinExclusive = true }, "enUS"), "Over 20 yd")
    H.Equal(format({ rangeMin = 20 }, "enUS"), "At least 20 yd")
    H.Equal(format({ rangeMin = 20, rangeMinExclusive = true, rangeMax = 20 }, "enUS"), "Range unknown")
end)

H.Test("class toggle starts from all classes and never mutates saved table", function()
    local RG = addon()
    local original = {}
    local changed = RG.UIModel.ToggleClass(original, "ROGUE")
    H.Equal(RG.Util.Count(original), 0)
    H.False(changed.ROGUE); H.True(changed.HUNTER)
    H.True(RG.UIModel.ClassEnabled(original, "ROGUE"))
    H.False(RG.UIModel.ClassEnabled(changed, "ROGUE"))
end)

H.Test("unseen contact displays observation age instead of current position", function()
    local RG = addon()
    local state = RG.UIModel.State({ visible = false, lastSeen = 90, rangeMin = 8, rangeMax = 20 }, 100, "enUS")
    H.Equal(state, RG.Locale.Format("lastSeen", "enUS", RG.UIModel.Age(10, "enUS")))
    H.True(state ~= RG.UIModel.Range({ rangeMin = 8, rangeMax = 20 }, "enUS"))
end)

H.Test("streamer rows hide names preserve alias stability and bound churn", function()
    local RG = addon()
    local profile, aliases = RG.Defaults.NewProfile(), {}
    profile.display.streamer = true
    local snapshot = { { id = "first", name = "PrivatePlayer", class = "ROGUE", visible = true, lastSeen = 100 } }
    local rows = RG.UIModel.Rows(snapshot, profile, 100, aliases)
    H.Nil(rows[1].name:find("PrivatePlayer", 1, true))
    local first = rows[1].name
    H.Equal(RG.UIModel.Rows(snapshot, profile, 100, aliases)[1].name, first)
    for index = 1, 1000 do
        RG.UIModel.Rows({ { id = "contact_" .. index, class = "HUNTER", visible = true, lastSeen = 100 } }, profile, 100, aliases)
    end
    H.True(RG.Util.Count(aliases) <= 513, "streamer aliases grow without a bound")
end)

H.Test("unknown stealth string does not become confirmed stealth label", function()
    local RG = addon()
    local contact = { visible = true, stealth = "suspected", rangeMax = 20, hostile = true, isPlayer = true }
    H.Equal(RG.UIModel.State(contact, 100, "enUS"), RG.UIModel.Range(contact, "enUS"))
    contact.stealth = "confirmed"
    H.Equal(RG.UIModel.State(contact, 100, "enUS"), RG.Locale.Get("stealth", "enUS"))
    contact.hostile = nil
    contact.targeting = true
    H.Equal(RG.UIModel.State(contact, 100, "enUS"), RG.UIModel.Range(contact, "enUS"))
end)
