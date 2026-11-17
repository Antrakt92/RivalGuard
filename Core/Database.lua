local _, RG = ...
local U, D = RG.Util, RG.Defaults
local DB = RG.Register("Database", {})
DB.__index = DB

local MAX_PROFILES, MAX_LISTS = 20, 1000
local function profileName(name) return U.Text(name, 64) end
local RULE_CONTEXTS = { any = true, world = true, battleground = true, arena = true, instance = true }
local RULE_LISTS = { any = true, listed = true, unlisted = true }
local RULE_POLICIES = { possible = true, confirmed = true }

local function classMap(value)
    if type(value) ~= "table" or getmetatable(value) then return nil end
    local result = {}
    for key, enabled in pairs(value) do
        if not D.classSet[key] or type(enabled) ~= "boolean" then return nil end
        result[key] = enabled
    end
    return result
end

local function positions(value)
    if type(value) ~= "table" then return nil end
    local result, count = {}, 0
    local points = { TOP = true, TOPLEFT = true, TOPRIGHT = true, CENTER = true, LEFT = true, RIGHT = true, BOTTOM = true, BOTTOMLEFT = true, BOTTOMRIGHT = true }
    for key, pos in pairs(value) do
        count = count + 1
        if count > 8 or not U.Text(key, 32) or type(pos) ~= "table" then return nil end
        if not points[pos.point] or not U.IsFinite(pos.x) or not U.IsFinite(pos.y) or math.abs(pos.x) > 10000 or math.abs(pos.y) > 10000 then return nil end
        result[key] = { point = pos.point, relativePoint = points[pos.relativePoint] and pos.relativePoint or pos.point, x = pos.x, y = pos.y }
    end
    return result
end

local function ruleArray(value, strict)
    if type(value) ~= "table" then return nil end
    local result, count = {}, 0
    for index, rule in pairs(value) do
        count = count + 1
        if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > 32 or type(rule) ~= "table" then return nil end
        if strict then
            local allowed = { name = true, enabled = true, priority = true, classes = true, event = true, action = true, sound = true, banner = true, cooldown = true,
                context = true, list = true, range = true, rangePolicy = true, rangeUnknown = true }
            for key in pairs(rule) do if not allowed[key] then return nil end end
            for _, key in ipairs({ "enabled", "sound", "banner", "rangeUnknown" }) do
                if rule[key] ~= nil and type(rule[key]) ~= "boolean" then return nil end
            end
            if rule.priority ~= nil and (not U.IsFinite(rule.priority) or rule.priority < 1 or rule.priority > 100 or rule.priority % 1 ~= 0) then return nil end
            if rule.cooldown ~= nil and (not U.IsFinite(rule.cooldown) or rule.cooldown < 0 or rule.cooldown > 600) then return nil end
            if rule.range ~= nil and (not U.IsFinite(rule.range) or (rule.range ~= 0 and (rule.range < 5 or rule.range > 100))) then return nil end
            if rule.context ~= nil and not RULE_CONTEXTS[rule.context] then return nil end
            if rule.list ~= nil and not RULE_LISTS[rule.list] then return nil end
            if rule.rangePolicy ~= nil and not RULE_POLICIES[rule.rangePolicy] then return nil end
            if rule.classes ~= nil and type(rule.classes) ~= "table" then return nil end
            if rule.event ~= nil and type(rule.event) ~= "string" then return nil end
            if rule.action ~= nil and type(rule.action) ~= "string" then return nil end
        end
        local clean = {
            name = U.Text(rule.name, 80), enabled = rule.enabled ~= false,
            priority = U.Clamp(rule.priority, 1, 100, 50),
            classes = classMap(rule.classes or {}),
            event = rule.event or "sighting", action = rule.action or "alert",
            sound = rule.sound ~= false, banner = rule.banner ~= false,
            cooldown = U.Clamp(rule.cooldown, 0, 600, 30),
            context = RULE_CONTEXTS[rule.context] and rule.context or "any",
            list = RULE_LISTS[rule.list] and rule.list or "any",
            range = U.IsFinite(rule.range) and rule.range >= 5 and math.min(100, rule.range) or 0,
            rangePolicy = RULE_POLICIES[rule.rangePolicy] and rule.rangePolicy or "possible",
            rangeUnknown = rule.rangeUnknown == true,
        }
        if not clean.name or not clean.classes then return nil end
        if not ({ sighting = true, returning = true, stealth = true, targeting = true, any = true })[clean.event] then return nil end
        if clean.action ~= "alert" and clean.action ~= "suppress" then return nil end
        result[index] = clean
    end
    if count > 32 or #result ~= count then return nil end
    return result
end

local function sanitize(value, defaults, strict, path)
    if type(value) ~= "table" or getmetatable(value) then return nil, "invalid_" .. path end
    local result = U.Copy(defaults)
    for key, item in pairs(value) do
        local expected = defaults[key]
        local field = path .. "." .. tostring(key)
        if expected == nil then
            if strict then return nil, "unknown_field" end
        elseif key == "classes" then
            local clean = classMap(item)
            if not clean and strict then return nil, "invalid_classes" end
            result[key] = clean or U.Copy(expected)
        elseif key == "positions" then
            local clean = positions(item)
            if not clean and strict then return nil, "invalid_positions" end
            result[key] = clean or {}
        elseif key == "rules" then
            local clean = ruleArray(item, strict)
            if not clean and strict then return nil, "invalid_rules" end
            result[key] = clean or {}
        elseif type(expected) == "table" then
            local clean, err = sanitize(item, expected, strict, field)
            if not clean and strict then return nil, err end
            result[key] = clean or U.Copy(expected)
        elseif type(item) ~= type(expected) or (type(item) == "number" and not U.IsFinite(item)) then
            if strict then return nil, "invalid_type" end
        else
            result[key] = item
        end
    end
    return result
end

function DB.ValidateProfile(value, strict)
    local p, err = sanitize(value, D.profile, strict, "profile")
    if not p then return nil, err end
    local checks = {
        { p.display, "maxRows", 3, 20 }, { p.display, "scale", 0.65, 2 }, { p.display, "textSize", 10, 24 },
        { p.display, "badgeSize", 16, 40 }, { p.display, "badgeOffset", 0, 30 },
        { p.display, "minimapAngle", 0, 360 },
        { p.alerts, "cooldown", 0, 600 }, { p.alerts, "returnAfter", 5, 600 }, { p.alerts, "soundGap", 0.5, 10 },
        { p.alerts, "waveWindow", 0.1, 3 }, { p.alerts, "waveThreshold", 2, 20 },
        { p.range, "yards", 5, 100 }, { p.retention, "contactSeconds", 15, 1800 },
        { p.retention, "maxContacts", 32, 512 }, { p.retention, "journalDays", 0, 90 },
        { p.retention, "maxJournal", 50, 1000 }, { p.retention, "maxHistory", 20, 500 },
    }
    for _, check in ipairs(checks) do
        local value = check[1][check[2]]
        if value < check[3] or value > check[4] then
            if strict then return nil, "out_of_range" end
            check[1][check[2]] = math.max(check[3], math.min(check[4], value))
        end
    end
    local integers = { { p.display, "maxRows" }, { p.display, "textSize" }, { p.display, "minimapAngle" }, { p.alerts, "waveThreshold" }, { p.retention, "maxContacts" }, { p.retention, "journalDays" }, { p.retention, "maxJournal" }, { p.retention, "maxHistory" } }
    for _, entry in ipairs(integers) do
        if entry[1][entry[2]] % 1 ~= 0 then
            if strict then return nil, "invalid_integer" end
            entry[1][entry[2]] = math.floor(entry[1][entry[2]])
        end
    end
    local enums = {
        { p.alerts, "channel", { Master = true, SFX = true, Music = true, Ambience = true, Dialog = true }, "Master" },
        { p.range, "policy", { possible = true, confirmed = true }, "possible" },
        { p, "locale", { auto = true, enUS = true, ruRU = true }, "auto" },
        { p, "preset", { balanced = true, farming = true, quiet = true, battleground = true, custom = true }, "custom" },
        { p.retention, "journalMode", { all = true, watched = true, threats = true }, "all" },
    }
    for _, entry in ipairs(enums) do
        if not entry[3][entry[1][entry[2]]] then
            if strict then return nil, "invalid_option" end
            entry[1][entry[2]] = entry[4]
        end
    end
    local sounds = { none = true, ping = true, warning = true, ready = true, whisper = true, quest = true }
    for event, choice in pairs(p.alerts.sounds) do
        if not sounds[choice] then
            if strict then return nil, "invalid_sound" end
            p.alerts.sounds[event] = D.profile.alerts.sounds[event]
        end
    end
    return p
end

local function newRoot()
    return { schemaVersion = RG.schemaVersion, activeProfile = "Default", profiles = { Default = D.NewProfile() }, lists = {}, journal = {}, onboardingSeen = false }
end

function DB.New(raw)
    local self = setmetatable({ root = newRoot(), writable = true, recovered = false }, DB)
    if raw == nil then return self end
    if type(raw) ~= "table" then self.recovered = true return self end
    if U.IsFinite(raw.schemaVersion) and raw.schemaVersion > RG.schemaVersion then
        self.writable, self.recoveryReason = false, "future_schema"
        return self
    end
    self.root.onboardingSeen = raw.onboardingSeen == true
    local count = 1
    if type(raw.profiles) == "table" then
        local function restore(name)
            local clean = DB.ValidateProfile(raw.profiles[name], false)
            if not clean then return end
            if not self.root.profiles[name] then count = count + 1 end
            self.root.profiles[name] = clean
        end
        if raw.profiles.Default ~= nil then restore("Default") end
        local active = profileName(raw.activeProfile)
        if active and active ~= "Default" and active == raw.activeProfile and raw.profiles[active] ~= nil then restore(active) end
        for name, value in pairs(raw.profiles) do
            if count >= MAX_PROFILES then break end
            if type(value) == "table" and profileName(name) == name and not self.root.profiles[name] then restore(name) end
        end
    end
    if self.root.profiles[raw.activeProfile] then self.root.activeProfile = raw.activeProfile end
    if type(raw.lists) == "table" then
        for identity, entry in pairs(raw.lists) do
            if U.Count(self.root.lists) >= MAX_LISTS then break end
            if type(entry) == "table" then self:SetList(identity, entry.kind, entry.note, entry) end
        end
    end
    -- Session sightings are deliberately not restored as live contacts.
    if type(raw.journal) == "table" then
        for _, item in ipairs(raw.journal) do
            if #self.root.journal >= 1000 then break end
            if type(item) == "table" and U.Text(item.identity, 256) and U.Text(item.name, 160) and U.IsFinite(item.lastSeen) then
                self.root.journal[#self.root.journal + 1] = {
                    identity = item.identity, name = item.name, class = D.classSet[item.class] and item.class or nil,
                    lastSeen = item.lastSeen, encounters = U.Clamp(item.encounters, 1, 1000000, 1), zone = U.Text(item.zone, 160),
                }
            end
        end
    end
    return self
end

function DB:GetProfile() return self.root.profiles[self.root.activeProfile] end
function DB:GetActiveProfileName() return self.root.activeProfile end
function DB:ListProfiles() return U.SortedKeys(self.root.profiles) end
function DB:GetList() return self.root.lists end
function DB:GetJournal() return U.Copy(self.root.journal) end
function DB:HasSeenGuide() return self.root.onboardingSeen end
function DB:MarkGuideSeen() self.root.onboardingSeen = true end

function DB:ClearJournal()
    local count = #self.root.journal
    self.root.journal = {}
    return count
end

function DB:CreateProfile(name, preset)
    name = profileName(name)
    if not name then return nil, "invalid_name" end
    if self.root.profiles[name] then return nil, "profile_exists" end
    if U.Count(self.root.profiles) >= MAX_PROFILES then return nil, "profile_limit" end
    local profile, err = D.NewProfile(preset)
    if not profile then return nil, err end
    self.root.profiles[name] = profile
    return profile
end

function DB:SetProfile(name)
    if not self.root.profiles[name] then return nil, "profile_missing" end
    self.root.activeProfile = name
    return self:GetProfile()
end
DB.UseProfile = DB.SetProfile

function DB:CopyProfile(name, source)
    name = profileName(name)
    if not name then return nil, "invalid_name" end
    if not self.root.profiles[source or self.root.activeProfile] then return nil, "profile_missing" end
    local created, err = self:CreateProfile(name)
    if not created then return nil, err end
    self.root.profiles[name] = U.Copy(self.root.profiles[source or self.root.activeProfile])
    return self.root.profiles[name]
end

function DB:DeleteProfile(name)
    if not self.root.profiles[name] then return nil, "profile_missing" end
    if name == "Default" then return nil, "default_profile" end
    self.root.profiles[name] = nil
    if self.root.activeProfile == name then self.root.activeProfile = "Default" end
    return true
end

function DB:ResetProfile()
    self.root.profiles[self.root.activeProfile] = D.NewProfile()
    return self:GetProfile()
end

function DB:SetList(identity, kind, note, metadata)
    identity = U.Text(identity, 256)
    if not identity or not (identity:match("^guid:") or identity:match("^name:")) then return nil, "unknown_identity" end
    if kind == nil then self.root.lists[identity] = nil return true end
    if kind ~= "watch" and kind ~= "avoid" and kind ~= "ignore" and kind ~= "note" then return nil, "invalid_list" end
    if not self.root.lists[identity] and U.Count(self.root.lists) >= MAX_LISTS then return nil, "list_limit" end
    if note ~= nil and note ~= "" and not U.Text(note, 512) then return nil, "invalid_note" end
    local existing = self.root.lists[identity]
    metadata = type(metadata) == "table" and metadata or {}
    self.root.lists[identity] = {
        kind = kind, note = U.Text(note, 512), name = U.Text(metadata.name, 160) or (existing and existing.name),
        class = D.classSet[metadata.class] and metadata.class or (existing and existing.class),
    }
    return true
end

function DB:ExportProfile()
    local clean, err = DB.ValidateProfile(self:GetProfile(), true)
    if not clean then return nil, err end
    return RG.Codec.Encode({ format = "RivalGuardProfile", schemaVersion = RG.schemaVersion, profile = clean })
end

function DB:PreviewImport(text)
    local value, err = RG.Codec.Decode(text)
    if not value then return nil, err end
    if type(value) ~= "table" or value.format ~= "RivalGuardProfile" or value.schemaVersion ~= RG.schemaVersion then return nil, "unsupported_import" end
    return DB.ValidateProfile(value.profile, true)
end

function DB:ImportProfile(name, text)
    name = profileName(name)
    if not name then return nil, "invalid_name" end
    local profile, err = self:PreviewImport(text)
    if not profile then return nil, err end
    local created, why = self:CreateProfile(name)
    if not created then return nil, why end
    self.root.profiles[name] = profile
    return profile
end

function DB:Record(contact, epoch, zone)
    if not contact.identity or not contact.name or not U.IsFinite(epoch) then return false end
    local profile = self:GetProfile()
    if profile.retention.journalDays == 0 then return false end
    local mode = profile.retention.journalMode
    if mode == "watched" and not contact.watched then return false end
    if mode == "threats" and not contact.watched and not contact.targeting and contact.stealth ~= "confirmed" then return false end
    if type(zone) == "function" then zone = zone() end
    local record
    for _, item in ipairs(self.root.journal) do if item.identity == contact.identity then record = item break end end
    if not record then
        record = { identity = contact.identity, name = contact.name, encounters = 0 }
        self.root.journal[#self.root.journal + 1] = record
    end
    record.name, record.class, record.lastSeen = contact.name, contact.class, epoch
    record.zone = U.Text(zone, 160)
    record.encounters = math.min(1000000, record.encounters + 1)
    self:Prune(epoch)
    return true
end

function DB:Prune(epoch)
    local profile = self:GetProfile()
    local journal = self.root.journal
    if profile.retention.journalDays == 0 then
        for index = #journal, 1, -1 do journal[index] = nil end
        return
    end
    table.sort(journal, function(a, b) return a.lastSeen > b.lastSeen end)
    for index = #journal, 1, -1 do
        if index > profile.retention.maxJournal or epoch - journal[index].lastSeen > profile.retention.journalDays * 86400 then table.remove(journal, index) end
    end
end
