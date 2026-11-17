local H = RGTest
local W = {}

-- This model checks calls and lifecycle contracts; it does not emulate native taint or render pixels.
function W.New()
    local state = { clock = H.Clock(100), frames = {}, named = {}, units = {}, plates = {}, sounds = {}, messages = {}, combat = false,
        cvars = { nameplateShowEnemies = true }, mutations = {}, blocked = {}, locale = "enUS", nextFrame = 0 }
    local api = setmetatable({}, { __index = _G })
    api._G = api
    state.api = api
    local methods = {}
    local points = { TOP = true, TOPLEFT = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true, BOTTOM = true, BOTTOMLEFT = true, BOTTOMRIGHT = true }

    local function finite(value)
        return type(value) == "number" and value == value and value > -math.huge and value < math.huge
    end
    local function protected(frame)
        local current = frame
        while current do
            if current.protected then return true end
            current = current.parent
        end
        return false
    end
    local function guard(frame, action)
        if state.combat and protected(frame) then
            state.blocked[#state.blocked + 1] = action
            error("protected mutation in combat: " .. action, 3)
        end
        state.mutations[#state.mutations + 1] = { frame = frame, action = action }
    end
    local function object(kind, name, parent, template)
        state.nextFrame = state.nextFrame + 1
        local frame = setmetatable({ kind = kind, name = name, parent = parent, template = template,
            protected = template and template:find("Secure", 1, true) ~= nil or false,
            shown = true, scripts = {}, events = {}, points = {}, children = {}, alpha = 1, scale = 1,
            width = 0, height = 0, text = "", value = 0, enabled = true, attributes = {}, serial = state.nextFrame }, { __index = methods })
        state.frames[#state.frames + 1] = frame
        if parent then parent.children[#parent.children + 1] = frame end
        if name then
            assert(not state.named[name], "duplicate frame name: " .. name)
            state.named[name], api[name] = frame, frame
        end
        return frame
    end
    function methods:GetName() return self.name end
    function methods:GetParent() return self.parent end
    function methods:IsForbidden() return self.forbidden or false end
    function methods:IsProtected() return protected(self) end
    function methods:SetParent(parent)
        guard(self, "SetParent")
        assert(parent == nil or (type(parent) == "table" and parent.scripts), "invalid frame parent")
        local current = parent
        while current do assert(current ~= self, "cyclic frame parent"); current = current.parent end
        self.parent = parent
    end
    function methods:ClearAllPoints() guard(self, "ClearAllPoints"); self.points = {} end
    function methods:SetPoint(point, relative, relativePoint, x, y)
        guard(self, "SetPoint")
        assert(points[point], "invalid anchor point")
        if type(relative) == "number" then x, y, relativePoint, relative = relative, relativePoint, point, self.parent
        elseif relative == nil then relative, relativePoint, x, y = self.parent, point, 0, 0
        elseif type(relativePoint) == "number" then x, y, relativePoint = relativePoint, x, point end
        if type(relative) == "string" then relative = assert(api[relative], "unknown relative frame") end
        assert(relative == nil or (type(relative) == "table" and relative.scripts), "invalid relative frame")
        relativePoint, x, y = relativePoint or point, x or 0, y or 0
        assert(points[relativePoint] and finite(x) and finite(y), "invalid anchor coordinates")
        self.points[#self.points + 1] = { point, relative, relativePoint, x, y }
    end
    function methods:GetPoint(index)
        local value = self.points[index or 1]
        if value then return unpack(value) end
    end
    function methods:SetAllPoints(parent)
        guard(self, "SetAllPoints")
        self.allPoints = parent or self.parent
    end
    function methods:SetWidth(value) guard(self, "SetWidth"); assert(finite(value) and value >= 0, "invalid width"); self.width = value end
    function methods:SetHeight(value) guard(self, "SetHeight"); assert(finite(value) and value >= 0, "invalid height"); self.height = value end
    function methods:SetSize(width, height) guard(self, "SetSize"); self:SetWidth(width); self:SetHeight(height) end
    function methods:GetWidth() return self.width > 0 and self.width or (self.parent and self.parent:GetWidth() or 1920) end
    function methods:GetHeight() return self.height > 0 and self.height or (self.parent and self.parent:GetHeight() or 1080) end
    function methods:SetScale(value) guard(self, "SetScale"); assert(finite(value) and value > 0, "invalid scale"); self.scale = value end
    function methods:GetScale() return self.scale end
    function methods:SetAlpha(value) assert(finite(value) and value >= 0 and value <= 1, "invalid alpha"); self.alpha = value end
    function methods:GetAlpha() return self.alpha end
    function methods:Show() guard(self, "Show"); self.shown = true end
    function methods:Hide() guard(self, "Hide"); self.shown = false end
    function methods:SetShown(value) assert(value == nil or type(value) == "boolean", "invalid visibility value"); if value then self:Show() else self:Hide() end end
    function methods:IsShown() return self.shown end
    function methods:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
    function methods:SetScript(event, callback) assert(callback == nil or type(callback) == "function", "invalid script"); self.scripts[event] = callback end
    function methods:GetScript(event) return self.scripts[event] end
    function methods:RegisterEvent(event) assert(type(event) == "string", "invalid event"); self.events[event] = true; return true end
    function methods:UnregisterEvent(event) self.events[event] = nil end
    function methods:UnregisterAllEvents() self.events = {} end
    function methods:SetAttribute(key, value) guard(self, "SetAttribute"); self.attributes[key] = value end
    function methods:GetAttribute(key) return self.attributes[key] end
    function methods:CreateTexture(name, layer) local child = object("Texture", name, self); child.layer = layer; return child end
    function methods:CreateFontString(name, layer, template) local child = object("FontString", name, self, template); child.layer = layer; return child end
    function methods:SetText(value)
        assert(type(value) == "string" or type(value) == "number", "invalid text")
        self.text = tostring(value)
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, false) end
    end
    function methods:GetText() return self.text end
    function methods:SetFormattedText(format, ...) self:SetText(string.format(format, ...)) end
    function methods:SetFont(path, size, flags) assert(type(path) == "string" and finite(size) and size > 0, "invalid font"); self.font = { path, size, flags }; return true end
    function methods:GetFont() return unpack(self.font or { "mock-font", 13, "" }) end
    function methods:GetStringHeight()
        local _, lines = self.text:gsub("\n", "")
        return (lines + 1) * ((self.font and self.font[2]) or 13)
    end
    function methods:GetNumLines() local _, lines = self.text:gsub("\n", ""); return lines + 1 end
    function methods:GetStringWidth() return #self.text * (((self.font and self.font[2]) or 13) / 2) end
    function methods:SetValue(value)
        assert(finite(value), "invalid slider value")
        if self.minimum then value = math.max(self.minimum, math.min(self.maximum, value)) end
        if value == self.value then return end
        self.value = value
        if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, value) end
    end
    function methods:GetValue() return self.value end
    function methods:SetMinMaxValues(low, high) assert(finite(low) and finite(high) and low <= high, "invalid slider bounds"); self.minimum, self.maximum = low, high end
    function methods:GetMinMaxValues() return self.minimum, self.maximum end
    function methods:SetValueStep(value) assert(finite(value) and value > 0, "invalid step"); self.step = value end
    function methods:SetChecked(value) assert(type(value) == "boolean", "invalid checked state"); self.checked = value end
    function methods:GetChecked() return self.checked or false end
    function methods:SetEnabled(value) assert(type(value) == "boolean", "invalid enabled state"); self.enabled = value end
    function methods:SetVerticalScroll(value) assert(finite(value) and value >= 0, "invalid scroll"); self.scroll = value end
    function methods:GetVerticalScroll() return self.scroll or 0 end
    function methods:GetVerticalScrollRange() return self.scrollChild and math.max(0, self.scrollChild:GetHeight() - self:GetHeight()) or 0 end
    function methods:SetScrollChild(child) assert(child and child.parent == self, "scroll child must belong to frame"); self.scrollChild = child end
    function methods:SetTexture(value) assert(type(value) == "string" or type(value) == "number", "invalid texture"); self.texture = value end
    function methods:SetColorTexture(...) self.color = { ... } end
    function methods:SetTextColor(...) self.textColor = { ... } end
    function methods:SetVertexColor(...) self.vertexColor = { ... } end
    function methods:SetDesaturated(value) self.desaturated = value end
    function methods:SetFrameStrata(value) assert(type(value) == "string", "invalid strata"); self.strata = value end
    function methods:SetClampedToScreen(value) self.clamped = value end
    function methods:SetMovable(value) self.movable = value end
    function methods:EnableMouse(value) self.mouse = value end
    function methods:EnableMouseWheel(value) self.mouseWheel = value end
    function methods:RegisterForDrag(...) self.dragButtons = { ... } end
    function methods:SetUserPlaced(value) self.userPlaced = value end
    function methods:SetJustifyH(value) self.justifyH = value end
    function methods:SetJustifyV(value) self.justifyV = value end
    function methods:SetHighlightTexture(value, blend) self.highlightTexture, self.highlightBlend = value, blend end
    function methods:SetThumbTexture(value) self.thumbTexture = value end
    function methods:SetOrientation(value) assert(value == "VERTICAL" or value == "HORIZONTAL", "invalid orientation"); self.orientation = value end
    function methods:SetObeyStepOnDrag(value) self.obeyStep = value end
    function methods:SetHitRectInsets(...) self.hitRect = { ... } end
    function methods:SetAutoFocus(value) self.autoFocus = value end
    function methods:SetMaxLetters(value) self.maxLetters = value end
    function methods:SetMultiLine(value) self.multiline = value end
    function methods:SetFontObject(value) self.fontObject = value end
    function methods:SetFocus() self.focus = true end
    function methods:ClearFocus() self.focus = false end
    function methods:HighlightText() self.highlighted = true end
    function methods:StartMoving() guard(self, "StartMoving"); assert(self.movable, "frame not movable"); self.moving = true end
    function methods:StopMovingOrSizing() self.moving = false end
    function methods:SetOwner(owner, anchor) self.owner, self.ownerAnchor = owner, anchor end
    function methods:AddLine(text) self.lines = self.lines or {}; self.lines[#self.lines + 1] = text end
    function methods:Click(button)
        if not self.enabled then return end
        if self.kind == "CheckButton" then self.checked = not self.checked end
        if self.scripts.OnClick then self.scripts.OnClick(self, button or "LeftButton") end
    end

    api.UIParent = object("Frame", "UIParent")
    api.UIParent:SetSize(1920, 1080)
    api.GameTooltip = object("GameTooltip", "GameTooltip", api.UIParent)
    api.GameFontNormal, api.GameFontHighlight, api.GameFontNormalLarge, api.ChatFontNormal = {}, {}, {}, {}
    api.STANDARD_TEXT_FONT = "Fonts\\ARIALN.TTF"
    api.UISpecialFrames, api.SlashCmdList, api.LOCALIZED_CLASS_NAMES_MALE, api.RAID_CLASS_COLORS = {}, {}, {}, {}
    api.DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) state.messages[#state.messages + 1] = message end }
    api.UNKNOWNOBJECT = "Unknown"
    function api.CreateFrame(kind, name, parent, template)
        assert(type(kind) == "string", "invalid frame kind")
        return object(kind, name, parent, template)
    end
    function api.GetTime() return state.clock.Now() end
    function api.time() return 1000000 + state.clock.Now() end
    function api.GetLocale() return state.locale end
    function api.GetBuildInfo() return "12.0.0", "fixture", "", 120000 end
    function api.GetCVarBool(name) return state.cvars[name] end
    function api.InCombatLockdown() return state.combat end
    function api.issecretvalue(value) return type(value) == "table" and getmetatable(value) == "restricted" end
    function api.IsInInstance() return state.instance and true or false, state.instance or "none" end
    function api.IsResting() return state.resting or false end
    function api.UnitOnTaxi() return state.flight or false end
    function api.GetZonePVPInfo() return state.zonePVP or "contested" end
    function api.GetRealZoneText() return "Fixture Zone" end
    function api.GetRealmName() return "FixtureRealm" end
    function api.GetNormalizedRealmName() return "FixtureRealm" end
    function api.UnitExists(token) return state.units[token] ~= nil end
    function api.UnitIsPlayer(token) local unit = state.units[token]; return unit and unit.isPlayer ~= false or false end
    function api.UnitIsEnemy(_, token) local unit = state.units[token]; return unit and unit.hostile ~= false or false end
    function api.UnitCanAttack(_, token) return api.UnitIsEnemy("player", token) end
    function api.UnitIsFriend(_, token) local unit = state.units[token]; return unit and unit.hostile == false or false end
    function api.UnitIsUnit(first, second)
        if first == second then return true end
        local a, b = state.units[first], state.units[second]
        return a and b and a.guid ~= nil and a.guid == b.guid or false
    end
    function api.UnitGUID(token) local unit = state.units[token]; return unit and unit.guid end
    function api.UnitName(token) local unit = state.units[token]; if unit then return unit.name, unit.realm end end
    api.UnitFullName = api.UnitName
    function api.UnitClass(token) local unit = state.units[token]; if unit then return unit.class, unit.class end end
    function api.UnitClassBase(token) return select(2, api.UnitClass(token)) end
    function api.UnitLevel(token) local unit = state.units[token]; return unit and unit.level or 60 end
    function api.UnitIsDeadOrGhost(token) local unit = state.units[token]; return unit and unit.dead or false end
    api.C_NamePlate = {
        GetNamePlates = function() local list = {}; for _, plate in pairs(state.plates) do list[#list + 1] = plate end; return list end,
        GetNamePlateForUnit = function(token) return state.plates[token] end,
    }
    api.C_Timer = { After = state.clock.After, NewTimer = state.clock.After }
    function api.PlaySound(id, channel) state.sounds[#state.sounds + 1] = { id = id, channel = channel }; return true, #state.sounds end
    function api.PlaySoundFile(id, channel) state.sounds[#state.sounds + 1] = { id = id, channel = channel }; return true, #state.sounds end

    function state:Fire(event, ...)
        local targets = {}
        for _, frame in ipairs(self.frames) do if frame.events[event] then targets[#targets + 1] = frame end end
        for _, frame in ipairs(targets) do if frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event, ...) end end
    end
    function state:Advance(seconds)
        local left = seconds
        while left > 0 do
            local step = math.min(left, 0.05)
            self.clock.Advance(step)
            local targets = {}
            for _, frame in ipairs(self.frames) do
                if frame:IsVisible() and frame.scripts.OnUpdate then targets[#targets + 1] = frame end
            end
            for _, frame in ipairs(targets) do if frame.scripts.OnUpdate then frame.scripts.OnUpdate(frame, step) end end
            left = left - step
        end
    end
    function state:Unit(token, data)
        self.units[token] = data
        if token:match("^nameplate%d+$") and not self.plates[token] then
            self.plates[token] = object("Frame", nil, api.UIParent)
            self.plates[token].namePlateUnitToken = token
            self.plates[token]:SetSize(120, 30)
        end
    end
    function state:Load(modules)
        local RG = H.Addon(modules, api)
        self.RG = RG
        return RG
    end
    function state:LoadTOC(path)
        local modules = {}
        local file = assert(io.open(H.root .. "/" .. (path or "RivalGuard.toc"), "r"))
        for line in file:lines() do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" and not line:find("^#") then modules[#modules + 1] = line:gsub("\\", "/") end
        end
        file:close()
        return self:Load(modules)
    end
    return state
end

return W
