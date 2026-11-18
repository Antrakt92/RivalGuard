local H = RGTest
local W = assert(loadfile(H.root .. "/tests/support/wow.lua"))()

local function setup()
    local state = W.New()
    state.api.GetBuildInfo = function() return "1.60.1", "", "", 16001 end
    state.api.RegisterStateDriver = function() end
    local RG = state:LoadTOC()
    state:Fire("ADDON_LOADED", "RivalGuard")
    local app = RG.instance
    H.True(app.initialized)
    local ui = app.ui
    app.db:GetProfile().display.maxRows = 3
    for index = 1, 4 do
        local token = "nameplate" .. index
        state:Unit(token, { guid = "Player-Nearby" .. index, name = "Rival" .. index, realm = "Realm", hostile = true })
        state:Fire("NAME_PLATE_UNIT_ADDED", token)
        ui.rows[index].left, ui.rows[index].top = 100, 500 - 30 * index
    end
    ui:Refresh()
    return state, ui, assert(ui.nearbyTarget.buttons[1]), app
end

local function press(button, mouseButton)
    -- Older builds lack this handler but still run PreClick and PostClick.
    local down = button.scripts.OnMouseDown
    if down then down(button, mouseButton) end
end

H.Test("secure Nearby rejects a button release after the row slot is reused", function()
    local _, ui, button = setup()
    local first = ui.rows[1].contact.id
    press(button, "LeftButton")
    button.scripts.PreClick(button, "LeftButton", true)
    H.True(button:GetAttribute("macrotext") ~= nil)
    button.scripts.PostClick(button, "LeftButton", true)

    ui.frame.scripts.OnMouseWheel(ui.frame, -1)
    H.True(ui.rows[1].contact.id ~= first)
    button.scripts.PreClick(button, "LeftButton", false)
    H.Nil(button:GetAttribute("macrotext"))
    button.scripts.PostClick(button, "LeftButton", false)

    press(button, "RightButton")
    ui.frame.scripts.OnMouseWheel(ui.frame, 1)
    button.scripts.PreClick(button, "RightButton", false)
    button.scripts.PostClick(button, "RightButton", false)
    H.Nil(ui.selected)

    press(button, "LeftButton")
    button.scripts.PreClick(button, "LeftButton", false)
    H.True(button:GetAttribute("macrotext") ~= nil)
    button.scripts.PostClick(button, "LeftButton", false)
    H.Nil(button:GetAttribute("macrotext"))
end)

H.Test("the secure row forwards scrolling to the same Nearby page handler", function()
    local _, ui, button = setup()
    H.Equal(ui.offset, 0)
    local scroll = assert(button.scripts.OnMouseWheel, "secure row captures clicks without forwarding the wheel")
    scroll(button, -1)
    H.Equal(ui.offset, 1)
    scroll(button, 1)
    H.Equal(ui.offset, 0)
end)

H.Test("a partial opponent name can show the arrow but cannot arm targeting", function()
    local state, ui, button, app = setup()
    local row, pointer = ui.rows[1], ui.nearbyTarget.pointer
    local unit = state.units.nameplate1
    state.plates.nameplate1.centerX, state.plates.nameplate1.centerY = 500, 460
    pointer.centerX, pointer.centerY = 160, 400
    state.api.RegionalUniqueNamesEnabled = function() return true end
    unit.realm = nil
    local name, _, complete = app.client:Names("nameplate1")
    H.Equal(name, unit.name)
    H.False(complete)
    H.Equal(row.contact.name, unit.name .. "-Realm")
    press(button, "LeftButton")
    button.scripts.PreClick(button, "LeftButton", false)
    H.Nil(button:GetAttribute("macrotext"))
    button.scripts.PostClick(button, "LeftButton", false)
    H.True(pointer:IsShown())
    local marked = {}
    state.api.GetRaidTargetIndex = function() end
    state.api.SetRaidTarget = function(token, marker) marked = { token, marker } end
    state:Unit("target", unit)
    press(button, "LeftButton")
    button.scripts.PreClick(button, "LeftButton", false)
    H.Nil(button:GetAttribute("macrotext"))
    button.scripts.PostClick(button, "LeftButton", false)
    H.Equal(marked[1], "target")
    H.Equal(marked[2], 8)
end)

H.Test("a clean Forever surname arms the full exact name", function()
    local state, _, button = setup()
    state.api.RegionalUniqueNamesEnabled = function() return true end
    state.api.Constants = { CharacterNameSeparatorConsts = { CHARACTERNAME_SURNAME_SEPARATOR = " " } }
    state.units.nameplate1.realm = "Surname"
    press(button, "LeftButton")
    button.scripts.PreClick(button, "LeftButton", false)
    H.Equal(button:GetAttribute("macrotext"), "/targetexact Rival1 Surname")
    button.scripts.PostClick(button, "LeftButton", false)
end)

H.Test("a moved or hidden Nearby row invalidates its pending secure click", function()
    local _, ui, button = setup()
    local row = ui.rows[1]
    press(button, "LeftButton")
    row.left = row.left + 50
    ui:Refresh()
    button.scripts.PreClick(button, "LeftButton", false)
    H.Nil(button:GetAttribute("macrotext"))
    button.scripts.PostClick(button, "LeftButton", false)

    press(button, "LeftButton")
    ui:Toggle()
    H.False(button:IsVisible())
    button.scripts.PreClick(button, "LeftButton", false)
    H.Nil(button:GetAttribute("macrotext"))
end)

H.Test("an in-flight valid click still marks its confirmed target after a Nearby repaint", function()
    local state, ui, button = setup()
    local first = ui.rows[1].contact
    local marked = {}
    state.api.GetRaidTargetIndex = function() end
    state.api.SetRaidTarget = function(token, marker) marked = { token, marker } end
    press(button, "LeftButton")
    button.scripts.PreClick(button, "LeftButton", false)
    H.True(button:GetAttribute("macrotext") ~= nil)
    state:Unit("target", state.units.nameplate1)
    ui.frame.scripts.OnMouseWheel(ui.frame, -1)
    H.True(ui.rows[1].contact.id ~= first.id)
    button.scripts.PostClick(button, "LeftButton", false)
    H.Equal(marked[1], "target")
    H.Equal(marked[2], 8)
end)
