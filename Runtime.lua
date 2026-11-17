local addonName, RG = ...
local App = RG.Register("App", {})
App.__index = App

local function readClock(api, name)
    if type(api[name]) == "function" then
        local ok, value = pcall(api[name])
        if not ok then return 0 end
        if type(api.issecretvalue) == "function" then
            local cleanOK, secret = pcall(api.issecretvalue, value)
            if not cleanOK or secret then return 0 end
        end
        if RG.Util.IsFinite(value) then return value end
    end
    return 0
end

local function alertConfig(profile)
    return RG.Codec.Encode({ enabled = profile.enabled, alerts = profile.alerts, context = profile.context,
        range = profile.range, rules = profile.rules, maxContacts = profile.retention.maxContacts })
end

function App.New(api)
    return setmetatable({ api = api or _G, dirty = true, elapsed = 0, journalElapsed = 0, initialized = false }, App)
end

function App:Notify(message)
    message = RG.Util.Text(message, 1024)
    if message and self.api.DEFAULT_CHAT_FRAME then
        self.api.DEFAULT_CHAT_FRAME:AddMessage("RivalGuard: " .. message)
    end
end

function App:OnSettingsChanged()
    self:ProfileChanged()
end

function App:ProfileChanged()
    local profile = self.db:GetProfile()
    local config = alertConfig(profile)
    local sameAlerts = config ~= nil and config == self.alertConfig and self.alertProfile == profile
    self.alertConfig, self.alertProfile = config, profile
    self.engine:SetProfile(profile, sameAlerts)
    self.engine.lists = self.db:GetList()
    self.db:Prune(readClock(self.api, "time"))
    if self.sensors then
        if profile.enabled then
            if not self.sensors:Start() then self.diagnostics:Error("sensor_start_failed") end
        else
            self.sensors:Stop()
            if self.ui and self.ui.ClearBanners then self.ui:ClearBanners() end
        end
    end
    self.dirty = true
    if self.ui then
        if self.ui.SettingsChanged then self.ui:SettingsChanged() else self.ui:Refresh() end
    end
end

function App:ToggleMute()
    local alerts = self.db:GetProfile().alerts
    alerts.sound = not alerts.sound
    self:OnSettingsChanged()
end

function App:PreviewSound(kind)
    return self.audio and self.audio:Play(kind or "sighting", true)
end

function App:AlertBlock()
    local profile = self.db:GetProfile()
    local alerts = profile.alerts
    if not profile.enabled or not alerts.enabled then return "disabled" end
    if self.engine.pausedUntil and self.engine.pausedUntil > self.engine:Now() then return "paused" end
    local allowed, reason = RG.Rules.ContextMatches(profile.context, self.engine.context)
    if not allowed then return reason end
    if alerts.banner then return nil end
    if alerts.sound then
        for kind, sound in pairs(alerts.sounds) do
            local eventEnabled = (kind ~= "stealth" or alerts.stealth) and (kind ~= "targeting" or alerts.targeting)
            local ordinary = kind == "sighting" or kind == "returning" or kind == "wave"
            if sound ~= "none" and eventEnabled and not (ordinary and (alerts.muteOrdinary or alerts.watchedOnly)) then
                return nil
            end
        end
    end
    return "outputs_disabled"
end

function App:Status()
    local profile = self.db:GetProfile()
    local cvars = self.api.C_CVar
    local read = type(cvars) == "table" and cvars.GetCVarBool
    if type(read) ~= "function" then read = self.api.GetCVarBool end
    local plates = self.client:Boolean(self.client:Safe(read, "nameplateShowEnemies"))
    local alwaysPlates = self.client:Boolean(self.client:Safe(read, "nameplateShowAll"))
    local capabilities = self.client:Capabilities()
    local detectionState = "active"
    if not profile.enabled then detectionState = "disabled"
    elseif plates == false or not capabilities.nameplates or (self.sensors and not self.sensors.running) then detectionState = "limited" end
    local state = detectionState
    if profile.enabled and self.engine.pausedUntil and self.engine.pausedUntil > self.engine:Now() then state = "paused" end
    return { state = state, detectionState = detectionState, nameplates = plates, alwaysNameplates = alwaysPlates,
        capabilities = capabilities, context = self.client:Context(),
        contacts = RG.Util.Count(self.engine.contacts), errors = self.diagnostics.counts.errors or 0,
        writable = self.db.writable }
end

function App:SupportedClasses() return self.client:SupportedClasses() end

function App:Explain(contact)
    if contact.preview == true then
        local result = { allowed = false, preview = true }
        local sample = self.demoContacts and self.demoContacts[contact.id]
        if not sample or not self.demoUntil or self.engine:Now() >= self.demoUntil then
            result.reason = "not_observed"
            return result
        end
        local entry = sample.watched and { kind = "watch" } or nil
        local decision, reason = RG.Rules.Evaluate(self.db:GetProfile(), sample, "sighting", { kind = "world" }, entry)
        if not decision then result.reason = reason; return result end
        if not decision.sound and not decision.banner then result.reason = "wave_only"; return result end
        result.allowed, result.reason = true, decision.reason
        result.sound, result.banner = decision.sound, decision.banner
        return result
    end
    return self.engine:ExplainView(contact.id, "sighting")
end

function App:HasTargetingEvidence(id)
    local contact = self.engine.contacts[id]
    return contact ~= nil and contact.targeting == true and contact.hostile == true
        and contact.isPlayer == true and contact.dead ~= true
end

function App:HighlightFrame(id, token)
    local contact = self.engine.contacts[id]
    local binding = self.engine.bindings[token]
    if not self.db:GetProfile().enabled or not contact or not contact.guid or not binding or binding.id ~= id
        or not contact.tokens[token] then return nil end
    local entry = self.engine:ListEntry(contact)
    if entry and entry.kind == "ignore" then return nil end
    return self.client:VisibleEnemyPlate(token, contact.guid)
end

function App:HighlightContact(selection)
    self.ui.badges:ClearHighlight()
    if not selection or selection.preview or selection.savedOnly
        or (selection.sources and selection.sources.journal) then return false end
    local contact = self.engine.contacts[selection.id]
    if not contact or not contact.guid or selection.identity ~= "guid:" .. contact.guid then return false end
    for _, token in ipairs(RG.Util.SortedKeys(contact.tokens)) do
        if token:match("^nameplate%d+$") then
            local frame = self:HighlightFrame(contact.id, token)
            if frame and self.ui.badges:Highlight(token, frame, contact.id, self.engine:Now()) then return true end
        end
    end
    return false
end

function App:Snooze(contact, seconds)
    if not contact or not contact.id then return nil, "not_observed" end
    local ok, untilTime = self.engine:ToggleContactSnooze(contact.id, seconds)
    if ok and self.ui and self.ui.SuppressContactBanners then self.ui:SuppressContactBanners(contact.id) end
    return ok, untilTime
end

function App:ExportDiagnostics()
    local status = self:Status()
    return self.diagnostics:Export(status.capabilities, self.engine, {
        context = self.engine.context.kind,
        detection = status.detectionState,
        alertBlock = self:AlertBlock(),
        nameplates = status.nameplates,
        alwaysNameplates = status.alwaysNameplates,
    })
end

function App:UIContactUpdated(token, observation, contact)
    if not self.ui or not self.ui.SetNameplate then return end
    if type(token) ~= "string" or not token:match("^nameplate%d+$") then return end
    if not contact then self.ui:RemoveNameplate(token) return end
    local highlight = self.ui.badges.highlight
    if highlight and highlight.unit == token then
        local owner = self.engine.contacts[highlight.id]
        if not owner or not observation or not observation.guid or observation.guid ~= owner.guid or observation.hostile ~= true
            or observation.isPlayer ~= true or observation.dead ~= false or observation.behindCamera == true then
            self.ui.badges:ClearHighlight()
        end
    end
    local frame = self.client:Nameplate(token)
    if frame then self.ui:SetNameplate(token, frame, contact)
    else self.ui:RemoveNameplate(token) end
end

function App:OnTokenRemoved(token)
    if self.ui and self.ui.RemoveNameplate then self.ui:RemoveNameplate(token) end
end

function App:OnWorldChanged()
    self.engine:Clear()
    if self.ui and self.ui.badges then self.ui.badges:ClearHighlight() end
    if self.ui and self.ui.ClearBanners then self.ui:ClearBanners() end
end

function App:ResolveList(contact)
    local identity = RG.UIModel.EditableIdentity(contact)
    if not identity then return nil end
    if contact.savedOnly or (contact.sources and contact.sources.journal) or not contact.id then
        return self.db:GetList()[identity], identity
    end
    local current = self.engine.contacts[contact.id]
    if not current or not current.identity then return nil end
    if current.identity ~= identity and (current.ambiguousIdentity or current.nameIdentity ~= identity) then return nil end
    local entry, key = self.engine:ListEntry(current)
    return entry, key or current.identity
end

function App:ToggleList(contact, kind)
    local entry, identity = self:ResolveList(contact)
    if not identity then return nil, "unknown_identity" end
    if entry and entry.kind == kind then kind = entry.note and "note" or nil end
    return self:SetList(contact, kind)
end

function App:Watch(contact) return self:ToggleList(contact, "watch") end
function App:Ignore(contact) return self:ToggleList(contact, "ignore") end

function App:SetNote(contact, note)
    local entry, identity = self:ResolveList(contact)
    if not identity then return nil, "unknown_identity" end
    if note == nil then note = "" end
    return self:SetList(contact, entry and entry.kind or "note", note)
end

function App:SetList(contact, kind, note)
    local entry, identity = self:ResolveList(contact)
    if not identity then return nil, "unknown_identity" end
    if note == nil then note = entry and entry.note end
    local ok, err = self.db:SetList(identity, kind, note, contact)
    if ok then
        if kind == "ignore" and self.ui and self.ui.SuppressContactBanners then
            self.ui:SuppressContactBanners(contact.id, contact.identity)
        end
        self:ProfileChanged()
    end
    return ok, err
end

function App:Demo()
    local now = self.engine:Now()
    local locale = self.db:GetProfile().locale
    self.demoSerial = (self.demoSerial or 0) + 1
    local prefix = "demo-" .. self.demoSerial .. "-"
    local function sample(class, label, low, high)
        return {
            id = prefix .. class, name = RG.Locale.Get(label, locale), class = class, level = 60,
            visible = true, firstSeen = now, lastSeen = now, hostile = true, isPlayer = true,
            rangeMin = low, rangeMax = high, sources = { preview = true },
        }
    end
    local contacts = {
        sample("ROGUE", "demoRogue", 8, 20),
        sample("HUNTER", "demoHunter", 20, 30),
        sample("MAGE", "demoMage", 10, 18),
    }
    contacts[2].targeting, contacts[3].watched = true, true
    local decision = { kind = "sighting", contact = contacts[1], banner = true, sound = false, preview = true, reason = "preview" }
    self.demoContacts, self.demoUntil = nil, nil
    if self.ui and self.ui.Preview then
        local registry = {}
        for _, contact in ipairs(contacts) do registry[contact.id] = contact end
        self.demoContacts = registry
        self.demoUntil = self.ui:Preview(contacts, decision)
    elseif self.ui then
        self.ui:Alert(decision)
    end
end

function App:Command(text)
    text = RG.Util.Text(text, 256) or ""
    local command, argument = text:match("^(%S+)%s*(.-)$")
    command = command and command:lower() or ""
    if command == "settings" or command == "config" then self.ui:OpenSettings()
    elseif command == "demo" or command == "test" then self:Demo()
    elseif command == "pause" then self.engine:Pause(RG.Util.Clamp(tonumber(argument), 1, 1440, 10) * 60)
    elseif command == "resume" then self.engine:Resume()
    elseif command == "mute" then self:ToggleMute()
    elseif command == "clear" then self.engine:ClearRecent()
    elseif command == "report" or command == "status" then self.ui:OpenSettings("support")
    elseif command == "watch" or command == "ignore" then
        local obs = self.client:ReadUnit("target", "target")
        local contact = obs and self.engine:Observe(obs)
        local ok
        if contact then
            if command == "watch" then ok = self:Watch(contact) else ok = self:Ignore(contact) end
        end
        if not ok then self:Notify(RG.Locale.Get("identityUnknown", self.db:GetProfile().locale)) end
    elseif command == "help" then
        self:Notify("/rg settings, demo, pause [minutes], resume, mute, clear, watch, ignore, report")
    else self.ui:Toggle() end
    self.dirty = true
end

function App:Initialize()
    if self.initialized or self.initializing then return end
    self.initializing = true
    local timeNow = function() return readClock(self.api, "GetTime") end
    local epochNow = function() return readClock(self.api, "time") end
    self.diagnostics = RG.Diagnostics.New(timeNow)
    self.db = RG.Database.New(self.api.RivalGuardDB)
    self.client = RG.Client.New(self.api, self.diagnostics)
    self.audio = RG.Audio.New(self.api, function() return self.db:GetProfile() end, self.diagnostics)
    local function zoneName() return self.client:Text(self.client:Safe(self.api.GetRealZoneText), 160) end
    self.alertProfile = self.db:GetProfile()
    self.alertConfig = alertConfig(self.alertProfile)
    self.engine = RG.Engine.New({ clock = timeNow, epoch = epochNow, profile = self.db:GetProfile(), context = self.client:Context(), lists = self.db:GetList(),
        onChange = function() self.dirty = true end,
        onEncounter = function(contact, epoch)
            return self.db:Record(contact, epoch, zoneName)
        end,
        onAlert = function(decision)
            if decision.sound then self.audio:Play(decision.kind, false) end
            if self.ui then
                local ok = pcall(self.ui.Alert, self.ui, decision)
                if not ok then self.diagnostics:Error("ui_alert") end
            end
        end,
    })
    self.ui = RG.UI.New(self)
    self.sensors = RG.Sensors.New(self, self.client, self.api)
    if self.db:GetProfile().enabled and not self.sensors:Start() then error("sensor_start_failed", 0) end
    self.db:Prune(epochNow())
    if not self.db.writable then self:Notify("Saved settings belong to a newer version. Session defaults are in use; your saved data is preserved.") end
    self.ui:Refresh()
    local commands = self.api.SlashCmdList
    if type(commands) == "table" then
        commands.RIVALGUARD = function(message) self:Command(message) end
        self.api.SLASH_RIVALGUARD1, self.api.SLASH_RIVALGUARD2 = "/rivalguard", "/rg"
    else
        self.diagnostics:Count("slash_unavailable")
    end
    if self.db.writable then self.api.RivalGuardDB = self.db.root end
    self.initializing, self.initialized = false, true
    if self.ui.RegisterNativeSettings then
        local ok = pcall(self.ui.RegisterNativeSettings, self.ui)
        if not ok then self.diagnostics:Error("ui_native_settings") end
    end
    if self.db.writable and not self.db:HasSeenGuide() and self.ui.ShowGuide then
        local ok = pcall(self.ui.ShowGuide, self.ui, false)
        if not ok then self.diagnostics:Error("ui_guide") end
    end
end

function App:Update(elapsed)
    if not self.initialized then return end
    self.elapsed = self.elapsed + elapsed
    if self.elapsed < 0.2 then return end
    self.journalElapsed = self.journalElapsed + self.elapsed
    self.elapsed = 0
    if self.journalElapsed >= 60 then
        self.journalElapsed = 0
        if self.db:Prune(readClock(self.api, "time")) > 0 then self.dirty = true end
    end
    if self.dirty then
        self.dirty = false
        local ok = pcall(self.ui.Refresh, self.ui)
        if not ok then self.diagnostics:Error("ui_refresh") end
    end
end

if type(CreateFrame) == "function" then
    local app = App.New(_G)
    RG.instance = app
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ADDON_LOADED")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:SetScript("OnEvent", function(_, event, name)
        if event == "ADDON_LOADED" and name == addonName then
            local ok = pcall(app.Initialize, app)
            if not ok then
                if app.diagnostics then app.diagnostics:Error("initialization") end
                app.initializing = false
                if app.sensors then pcall(app.sensors.Stop, app.sensors) end
                if app.ui and app.ui.Destroy then pcall(app.ui.Destroy, app.ui) end
                app:Notify("Could not initialize. Your saved settings have not been reset.")
            end
        elseif event == "PLAYER_LOGOUT" and app.initialized then
            if app.db.writable then app.api.RivalGuardDB = app.db.root end
        end
    end)
    frame:SetScript("OnUpdate", function(_, elapsed) app:Update(elapsed) end)
end
