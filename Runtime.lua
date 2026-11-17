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

function App.New(api)
    return setmetatable({ api = api or _G, dirty = true, elapsed = 0, initialized = false }, App)
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
    self.engine:SetProfile(profile)
    self.engine.lists = self.db:GetList()
    self.db:Prune(readClock(self.api, "time"))
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

function App:Status()
    local profile = self.db:GetProfile()
    local plates = self.client:Boolean(self.client:Safe(self.api.GetCVarBool, "nameplateShowEnemies"))
    local state = "active"
    if not profile.enabled then state = "disabled"
    elseif self.engine.pausedUntil and self.engine.pausedUntil > self.engine:Now() then state = "paused"
    elseif plates == false or not self.client:Capabilities().nameplates then state = "limited" end
    return { state = state, nameplates = plates, capabilities = self.client:Capabilities(), context = self.client:Context(),
        contacts = RG.Util.Count(self.engine.contacts), errors = self.diagnostics.counts.errors or 0,
        writable = self.db.writable }
end

function App:SupportedClasses() return self.client:SupportedClasses() end

function App:Explain(contact)
    return self.engine:ExplainView(contact.id, "sighting")
end

function App:ExportDiagnostics()
    return self.diagnostics:Export(self.client:Capabilities(), self.engine)
end

function App:UIContactUpdated(token, _, contact)
    if not self.ui or not self.ui.SetNameplate then return end
    if type(token) ~= "string" or not token:match("^nameplate%d+$") then return end
    if not contact then self.ui:RemoveNameplate(token) return end
    local frame = self.client:Nameplate(token)
    if frame then self.ui:SetNameplate(token, frame, contact) end
end

function App:OnTokenRemoved(token)
    if self.ui and self.ui.RemoveNameplate then self.ui:RemoveNameplate(token) end
end

function App:Watch(contact)
    if not contact or not contact.identity then return nil, "unknown_identity" end
    local entry = self.db:GetList()[contact.identity]
    local kind = "watch"
    if entry and entry.kind == "watch" then kind = entry.note and "note" or nil end
    local ok, err = self.db:SetList(contact.identity, kind, entry and entry.note, contact)
    if ok then self:ProfileChanged() end
    return ok, err
end

function App:Ignore(contact)
    if not contact or not contact.identity then return nil, "unknown_identity" end
    local entry = self.db:GetList()[contact.identity]
    local kind = "ignore"
    if entry and entry.kind == "ignore" then kind = entry.note and "note" or nil end
    local ok, err = self.db:SetList(contact.identity, kind, entry and entry.note, contact)
    if ok then self:ProfileChanged() end
    return ok, err
end

function App:SetNote(contact, note)
    if not contact or not contact.identity then return nil, "unknown_identity" end
    local entry = self.db:GetList()[contact.identity]
    local ok, err = self.db:SetList(contact.identity, entry and entry.kind or "note", note, contact)
    if ok then self:ProfileChanged() end
    return ok, err
end

function App:Demo()
    local now = self.engine:Now()
    local locale = self.db:GetProfile().locale
    local function title(key) return RG.Locale.Get(key, locale) end
    local contacts = {
        { id = "demo1", name = title("demoRogue"), class = "ROGUE", level = 60, visible = true, firstSeen = now, lastSeen = now, hostile = true, isPlayer = true, rangeMin = 8, rangeMax = 20, sources = { preview = true } },
        { id = "demo2", name = title("demoHunter"), class = "HUNTER", level = 60, visible = true, firstSeen = now, lastSeen = now, hostile = true, isPlayer = true, rangeMin = 20, rangeMax = 30, targeting = true, sources = { preview = true } },
        { id = "demo3", name = title("demoWatch"), class = "MAGE", level = 60, visible = false, firstSeen = now - 60, lastSeen = now - 12, watched = true, sources = { preview = true } },
    }
    local decision = { kind = "sighting", contact = contacts[1], banner = true, sound = false, preview = true, reason = "preview" }
    if self.ui and self.ui.Preview then self.ui:Preview(contacts, decision)
    elseif self.ui then self.ui:Alert(decision) end
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
    elseif command == "clear" then self.engine:Clear()
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
    self.engine = RG.Engine.New({ clock = timeNow, epoch = epochNow, profile = self.db:GetProfile(), context = self.client:Context(), lists = self.db:GetList(),
        onChange = function() self.dirty = true end,
        onEncounter = function(contact, epoch)
            local zone = self.client:Text(self.client:Safe(self.api.GetRealZoneText), 160)
            self.db:Record(contact, epoch, zone)
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
    if not self.sensors:Start() then error("sensor_start_failed", 0) end
    self.api.SLASH_RIVALGUARD1, self.api.SLASH_RIVALGUARD2 = "/rivalguard", "/rg"
    self.api.SlashCmdList.RIVALGUARD = function(message) self:Command(message) end
    self.db:Prune(epochNow())
    if not self.db.writable then self:Notify("Saved settings belong to a newer version. Session defaults are in use; your saved data is preserved.") end
    self.ui:Refresh()
    if self.db.writable then self.api.RivalGuardDB = self.db.root end
    self.initializing, self.initialized = false, true
end

function App:Update(elapsed)
    if not self.initialized then return end
    self.elapsed = self.elapsed + elapsed
    if self.elapsed < 0.2 then return end
    self.elapsed = 0
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
