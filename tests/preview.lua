local root, locale, view, page = arg[1] or ".", arg[2] or "enUS", arg[3] or "settings", arg[4] or "alerts"
local width, height, scale = tonumber(arg[5]) or 1920, tonumber(arg[6]) or 1080, tonumber(arg[7]) or 1
assert(width >= 640 and height >= 480 and scale >= 0.5 and scale <= 2, "invalid preview dimensions")
local H = assert(loadfile(root .. "/tests/support/harness.lua"))(); H.root = root; RGTest = H
local W = assert(loadfile(root .. "/tests/support/wow.lua"))()
local state = W.New(); state.locale = locale
state.api.RivalGuardDB = { schemaVersion = 1, onboardingSeen = true }
state.api.UIParent:SetSize(width / scale, height / scale); state.api.UIParent:SetScale(scale)
if view == "launcher" or view == "appearance" then
    local map = state.api.CreateFrame("Frame", "Minimap", state.api.UIParent)
    map:SetSize(150, 150)
    map:SetPoint("TOPRIGHT", state.api.UIParent, "TOPRIGHT", -22, -38)
    local background = map:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(); background:SetColorTexture(0.12, 0.2, 0.27, 1)
end
local RG = state:LoadTOC()
state:Fire("ADDON_LOADED", "RivalGuard")
local app = RG.instance
assert(app.initialized, "preview addon initialization failed")
app.db:GetProfile().locale = locale
app.db:GetProfile().display.highContrast = arg[8] == "contrast"
app.db:GetProfile().display.locked = false
local classes = { "ROGUE", "HUNTER", "MAGE", "DRUID", "PRIEST", "WARRIOR", "SHAMAN", "WARLOCK", "PALADIN", "MONK" }
for index, class in ipairs(classes) do
    local name = locale == "ruRU" and ("Длинноеимяперсонажа " .. index) or ("LongCharacterName " .. index)
    local contact = app.engine:Observe({ token = "nameplate" .. index, guid = "Player-Preview-" .. index,
        name = name, realm = "FixtureRealm", class = class, level = 60,
        hostile = true, isPlayer = true, source = "nameplate", rangeMin = index * 3, rangeMax = index * 3 + 10 })
    if index == 1 then app:Watch(contact) end
end
app.ui:Refresh()
if view == "settings" then
    if page == "alerts-context" or page == "alerts-muted" then
        local name = RG.Locale.Get("battleground", locale)
        local profile = assert(app.db:CreateProfile(name, "battleground"))
        profile.context.world = page == "alerts-muted"
        assert(app.db:SetProfile(name))
        app:ProfileChanged()
        app.ui:OpenSettings("alerts")
        app.ui.hunterRogueButton:Click()
    else
        app.ui:OpenSettings(page == "targeting" and "alerts" or page)
    end
    if page == "targeting" then
        for _, control in ipairs(app.ui.controls) do
            if control.path == "display.highlightTargeting" then
                local _, _, _, _, y = control.frame:GetPoint(1)
                app.ui.scrollbar:SetValue(-y - 160)
                break
            end
        end
    end
elseif view == "guide" then
    app.ui:ShowGuide(true)
    if page == "rules" then app.ui.guideDialog.next:Click() end
elseif view == "journal" then app.ui:OpenSettings("journal")
elseif view == "diagnostics" then app.ui:ShowDiagnostics()
elseif view == "personal" then app.ui:OpenSettings("journal"); app.ui.journalPersonal:Click()
elseif view == "rules" then app.ui:OpenRules()
elseif view == "conditions" then app.ui:OpenRules(); app.ui.rulesDialog.conditions:Click()
elseif view == "appearance" then app.ui:OpenSettings("appearance")
elseif view == "import" then app.ui:OpenTransfer("import")
elseif view == "export" then app.ui:OpenTransfer("export")
elseif view == "details" and page == "sample" then
    app:Demo()
    app.ui:Select(app.ui.previewContacts[2])
elseif view == "details" then app.ui:Select(app.engine:Snapshot()[1])
elseif view == "explanation" then
    if page == "sound" then
        app.engine:Clear()
        state.api.PlaySound = function() return false end
        local name = locale == "ruRU" and "Пример противника" or "Example opponent"
        state:Unit("nameplate80", { guid = "Player-SoundPreview", name = name, class = "ROGUE", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", "nameplate80")
        state:Advance(1.2)
    end
    app.ui:Select(app.engine:Snapshot()[1])
    app.ui:ShowExplanation()
elseif view == "banner" then
    if page == "camouflage" then
        app.engine:Clear()
        local token = "nameplate80"
        local name = locale == "ruRU" and "Пример охотника" or "Example hunter"
        state:Unit(token, { guid = "Player-CamouflagePreview", name = name, class = "HUNTER", hostile = true, isPlayer = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        state:Fire("UNIT_SPELLCAST_SUCCEEDED", token, "Cast-CamouflagePreview", 199483)
        state:Advance(0.45)
        assert(app.ui.activeBanner and app.ui.activeBanner.stealthSpell == "Camouflage", "camouflage preview did not alert")
    else
        app.ui:PreviewAlert()
    end
elseif view == "locator" then
    local token = "nameplate80"
    local name = locale == "ruRU" and "Пример противника" or "Example opponent"
    local automatic = page == "automatic" or page == "overlap"
    if automatic then
        app.engine:Clear()
        local display = app.db:GetProfile().display
        display.highlightTargeting, display.showBadges = true, false
        state:Unit("player", { guid = "Player-LocatorLocal" })
        state:Unit(token .. "target", { guid = "Player-LocatorLocal" })
    end
    state:Unit(token, { guid = "Player-LocatorPreview", name = name, class = "ROGUE", hostile = true, isPlayer = true })
    local plate = state.plates[token]
    plate:SetSize(155, 18); plate:SetPoint("CENTER", state.api.UIParent, "CENTER", 0, page == "automatic" and -40 or 60)
    local bar = plate:CreateTexture(nil, "BACKGROUND")
    bar:SetAllPoints(); bar:SetColorTexture(0.66, 0.14, 0.18, 1)
    local plateName = plate:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    plateName:SetPoint("CENTER"); plateName:SetText(name)
    state:Fire("NAME_PLATE_UNIT_ADDED", token)
    if automatic then
        state:Advance(0.45)
        assert(app.ui.badges.highlight and app.ui.badges.highlight.automatic, "automatic locator preview did not attach")
    else
        local id = assert(app.sensors.active[token].contactID)
        for _, contact in ipairs(app.engine:Snapshot()) do
            if contact.id == id then app.ui:Select(contact); break end
        end
        app.ui.detailsFrame.locate:Click()
        assert(app.ui.badges.highlight, "locator preview did not attach")
    end
elseif view == "wave" then
    app.ui:Alert({ kind = "wave", count = 38, classes = { ROGUE = 12, HUNTER = 10, MAGE = 8, WARRIOR = 8 }, banner = true })
elseif view ~= "main" and view ~= "launcher" then error("unknown preview view") end

local function json(value)
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "number" then assert(RG.Util.IsFinite(value)); return string.format("%.12g", value) end
    if type(value) == "string" then
        return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
            if char == '"' then return '\\"' end
            if char == "\\" then return "\\\\" end
            return string.format("\\u%04x", char:byte())
        end) .. '"'
    end
    assert(type(value) == "table", "unsupported preview value")
    local entries, array = {}, #value > 0
    if array then for _, item in ipairs(value) do entries[#entries + 1] = json(item) end
    else
        local keys = RG.Util.SortedKeys(value)
        for _, key in ipairs(keys) do entries[#entries + 1] = json(key) .. ":" .. json(value[key]) end
    end
    return (array and "[" or "{") .. table.concat(entries, ",") .. (array and "]" or "}")
end

local frames = {}
local windowNames = {}
for name, frame in pairs(app.ui.windows or {}) do windowNames[frame.serial] = name end
for _, frame in ipairs(state.frames) do
    local anchors, enabled = {}, frame.enabled
    if type(enabled) ~= "boolean" then enabled = nil end
    for _, point in ipairs(frame.points) do
        anchors[#anchors + 1] = { point = point[1], relative = point[2] and point[2].serial or state.api.UIParent.serial,
            relativePoint = point[3], x = point[4], y = point[5] }
    end
    frames[#frames + 1] = { id = frame.serial, name = windowNames[frame.serial] or frame.name, kind = frame.kind, template = frame.template,
        parent = frame.parent and frame.parent.serial, visible = frame:IsVisible(), shown = frame:IsShown(),
        width = frame.width, height = frame.height, scale = frame.scale, alpha = frame.alpha,
        text = frame.text, fontSize = frame.font and frame.font[2] or 13, textColor = frame.textColor,
        color = frame.color, texture = type(frame.texture) == "string" and frame.texture or nil,
        allPoints = type(frame.allPoints) == "table" and frame.allPoints.serial or nil,
        points = anchors, layer = frame.layer, strata = frame.strata,
        justifyH = frame.justifyH, justifyV = frame.justifyV, checked = frame.checked,
        enabled = enabled,
        value = frame.value, minimum = frame.minimum, maximum = frame.maximum,
        scrollChild = frame.scrollChild and frame.scrollChild.serial, scroll = type(frame.scroll) == "number" and frame.scroll or 0 }
end
io.write(json({ meta = { simulation = true, disclaimer = "Simulated addon frames; not an in-game screenshot. Font metrics and stock textures are approximated.",
    locale = locale, view = view, page = page, width = width, height = height, uiScale = scale, root = state.api.UIParent.serial }, frames = frames }), "\n")
