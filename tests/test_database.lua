local H = RGTest
local function addon()
    return H.Addon({ "Core/Bootstrap.lua", "Core/Util.lua", "Core/Defaults.lua", "Core/Codec.lua", "Core/Database.lua" })
end

H.Test("profile create copy switch reset delete preserve unrelated settings", function()
    local RG = addon()
    local db = RG.Database.New()
    local original = db:GetProfile()
    original.alerts.cooldown = 77
    H.True(type(db:CreateProfile("Фарм", "farming")) == "table")
    H.True(type(db:CopyProfile("Copy", "Default")) == "table")
    db:SetProfile("Copy")
    H.Equal(db:GetProfile().alerts.cooldown, 77)
    db:GetProfile().alerts.cooldown = 22
    H.Equal(original.alerts.cooldown, 77)
    db:ResetProfile()
    H.Equal(db:GetProfile().alerts.cooldown, RG.Defaults.profile.alerts.cooldown)
    H.Equal(original.alerts.cooldown, 77)
    H.True(db:DeleteProfile("Copy")); H.Equal(db:GetActiveProfileName(), "Default")
    H.Nil(db:DeleteProfile("Default")); H.Nil(db:CopyProfile("Broken", "Missing"))
    H.Nil(db:CreateProfile("|bad")); H.Nil(db:CreateProfile("Default"))
end)

H.Test("profile export preview import are detached and never replace existing profile", function()
    local RG = addon()
    local db = RG.Database.New()
    db:GetProfile().alerts.classes.ROGUE = true
    local text = assert(db:ExportProfile())
    local preview = assert(db:PreviewImport(text))
    preview.alerts.classes.ROGUE = false
    H.True(db:GetProfile().alerts.classes.ROGUE)
    local imported = assert(db:ImportProfile("Imported", text))
    H.True(imported.alerts.classes.ROGUE)
    local again, reason = db:ImportProfile("Imported", text)
    H.Nil(again); H.Equal(reason, "profile_exists")
    H.Equal(db.root.profiles.Imported, imported)
    local before = assert(db:ExportProfile())
    H.Nil(db:ImportProfile("Bad", "not a profile"))
    H.Nil(db.root.profiles.Bad)
    H.Equal(db:ExportProfile(), before)
end)

H.Test("saved variables recovery detaches tables and keeps future schema untouched", function()
    local RG = addon()
    local profile = RG.Defaults.NewProfile()
    profile.alerts.cooldown = 91
    local raw = { schemaVersion = 1, activeProfile = "Saved", profiles = { Saved = profile }, lists = {}, journal = {} }
    local db = RG.Database.New(raw)
    H.Equal(db:GetActiveProfileName(), "Saved")
    db:GetProfile().alerts.cooldown = 12
    H.Equal(raw.profiles.Saved.alerts.cooldown, 91)
    local future = { schemaVersion = 999, marker = "preserve" }
    local readOnly = RG.Database.New(future)
    H.False(readOnly.writable); H.Equal(readOnly.recoveryReason, "future_schema")
    H.Equal(future.schemaVersion, 999); H.Equal(future.marker, "preserve")
    H.True(RG.Database.New("corrupt").recovered)
end)

H.Test("profile limits count restored Default and do not partially create extras", function()
    local RG = addon()
    local db = RG.Database.New()
    for index = 1, 19 do assert(db:CreateProfile("Profile " .. index)) end
    H.Equal(#db:ListProfiles(), 20)
    H.Nil(db:CreateProfile("Overflow")); H.Nil(db.root.profiles.Overflow)
    local raw = { schemaVersion = 1, profiles = {} }
    for index = 1, 20 do raw.profiles["Restored " .. index] = RG.Defaults.NewProfile() end
    local restored = RG.Database.New(raw)
    H.True(#restored:ListProfiles() <= 20, "restoration exceeded total profile limit")
    H.True(type(restored.root.profiles.Default) == "table")
end)

H.Test("strict profile imports reject unknown fields malformed rules and unsafe values", function()
    local RG = addon()
    local function rejected(change)
        local profile = RG.Defaults.NewProfile()
        change(profile)
        H.Nil(RG.Database.ValidateProfile(profile, true))
    end
    rejected(function(p) p.unrecognized = true end)
    rejected(function(p) p.alerts.cooldown = 0 / 0 end)
    rejected(function(p) p.alerts.classes.UNKNOWN = true end)
    rejected(function(p) p.alerts.classes.ROGUE = "true" end)
    rejected(function(p) p.positions.main = { point = "INVALID", x = 0, y = 0 } end)
    rejected(function(p) p.rules = { { name = "Rule", event = "execute", classes = {} } } end)
    rejected(function(p) p.rules = { { name = "Rule", action = "execute", classes = {} } } end)
    rejected(function(p) p.rules = { { name = "Rule", enabled = "yes", classes = {} } } end)
    rejected(function(p) p.rules = { { name = "Rule", priority = 0 / 0, classes = {} } } end)
    rejected(function(p) p.alerts.channel = "Invalid" end)
    rejected(function(p) p.range.policy = "Invalid" end)
    rejected(function(p) p.display.maxRows = 3.5 end)
end)

H.Test("watchlists validate durable identities and notes without partial updates", function()
    local RG = addon()
    local db = RG.Database.New()
    H.Nil(db:SetList("nameplate1", "watch", "Not persistent"))
    H.True(db:SetList("name:Somebody-Realm", "watch", "Careful"))
    H.Equal(db:GetList()["name:Somebody-Realm"].note, "Careful")
    H.Nil(db:SetList("name:Somebody-Realm", "execute", "New"))
    H.Equal(db:GetList()["name:Somebody-Realm"].kind, "watch")
    H.Nil(db:SetList("name:Somebody-Realm", "watch", "|cffff0000Bad"))
    H.Equal(db:GetList()["name:Somebody-Realm"].note, "Careful")
    H.True(db:SetList("name:Somebody-Realm", nil))
    H.Nil(db:GetList()["name:Somebody-Realm"])
end)

H.Test("journal is bounded expires old entries and never restores live sightings", function()
    local RG = addon()
    local db = RG.Database.New()
    db:GetProfile().retention.maxJournal = 50
    for index = 1, 60 do db:Record({ identity = "guid:" .. index, name = "Enemy " .. index, class = "ROGUE" }, 1000000 + index, "Zone") end
    local journal = db:GetJournal()
    H.Equal(#journal, 50); H.Equal(journal[1].identity, "guid:60")
    journal[1].name = "Changed"
    H.Equal(db:GetJournal()[1].name, "Enemy 60")
    db:Record({ identity = "guid:60", name = "Enemy 60", class = "ROGUE" }, 1000100, "Other Zone")
    H.Equal(db:GetJournal()[1].encounters, 2)
    db:Prune(2000000)
    H.Equal(#db:GetJournal(), 0)
    db:GetProfile().retention.journalDays = 0
    db:Record({ identity = "guid:ignored", name = "Ignored" }, 2000000, "Zone")
    H.Equal(#db:GetJournal(), 0)
end)
