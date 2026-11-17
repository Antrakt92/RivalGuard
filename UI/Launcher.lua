local _, RG = ...
local L = RG.Register("Launcher", {})
local M = RG.UIModel
local TAU = math.pi * 2

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return a, b
end

local function cleanBoolean(value)
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return nil end
    end
    if type(value) == "boolean" then return value end
end

local function combatLocked()
    if not InCombatLockdown then return false end
    return cleanBoolean(call(InCombatLockdown)) ~= false
end

local function safeMinimap(map)
    if not map or not map.GetWidth or not map.GetHeight then return false end
    if map.IsForbidden and cleanBoolean(call(map.IsForbidden, map)) ~= false then return false end
    if map.IsProtected and cleanBoolean(call(map.IsProtected, map)) ~= false then return false end
    return true
end

function L.New(ui, tooltip, hideTooltip)
    if not safeMinimap(Minimap) then return nil end
    local map = Minimap
    local frame = CreateFrame("Button", nil, map)
    local self = { frame = frame }
    frame:SetSize(32, 32)
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    frame:RegisterForDrag("LeftButton")
    frame:EnableMouse(true)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0.035, 0.045, 0.065, 1)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2); icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture("Interface\\AddOns\\RivalGuard\\Media\\Icon")
    frame:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    local function geometry(angle)
        local width = M.Number(call(map.GetWidth, map), 140)
        local height = M.Number(call(map.GetHeight, map), 140)
        local radians = angle / 360 * TAU
        local x, y = math.cos(radians), math.sin(radians)
        -- Use the minimap's current aspect ratio without assuming its mask shape.
        return x * (width / 2 + 8), y * (height / 2 + 8), width, height
    end

    function self:Reposition(angle)
        if combatLocked() or not safeMinimap(map) then return false end
        angle = math.floor(RG.Util.Clamp(angle, 0, 360, 225)) % 360
        local x, y, width, height = geometry(angle)
        if self.angle == angle and self.width == width and self.height == height then return true end
        frame:ClearAllPoints(); frame:SetPoint("CENTER", map, "CENTER", x, y)
        self.angle, self.width, self.height = angle, width, height
        return true
    end

    function self:UpdateDrag()
        if not self.dragging or combatLocked() or not safeMinimap(map) then return end
        local cursorX, cursorY = call(GetCursorPosition)
        local centerX, centerY = call(map.GetCenter, map)
        local scale = M.Number(call(map.GetEffectiveScale, map))
        cursorX, cursorY = M.Number(cursorX), M.Number(cursorY)
        centerX, centerY = M.Number(centerX), M.Number(centerY)
        if not cursorX or not cursorY or not centerX or not centerY or not scale or scale <= 0 then return end
        local width = M.Number(call(map.GetWidth, map), 140)
        local height = M.Number(call(map.GetHeight, map), 140)
        if width <= 0 or height <= 0 then return end
        local x = (cursorX / scale - centerX) / width
        local y = (cursorY / scale - centerY) / height
        if x * x + y * y < 0.0001 then return end
        local angle = math.floor(math.atan2(y, x) / TAU * 360 + 360.5) % 360
        if self:Reposition(angle) then self.dragAngle = angle end
    end

    function self:EndDrag(save)
        if not self.dragging then return end
        self.dragging = false
        frame:SetScript("OnUpdate", nil)
        if save and self.dragProfile == ui:Profile() and self.dragAngle then
            self.dragProfile.display.minimapAngle = self.dragAngle
        end
        self.dragProfile, self.dragAngle = nil, nil
    end

    function self:Refresh()
        if self.destroyed then return end
        local profile = ui:Profile()
        if self.dragging and (self.dragProfile ~= profile or not profile.display.minimap or combatLocked()) then self:EndDrag(false) end
        if not safeMinimap(map) then frame:Hide(); return end
        if not self.dragging then self:Reposition(profile.display.minimapAngle) end
        frame:SetShown(profile.display.minimap == true and self.angle ~= nil)
    end

    frame:SetScript("OnDragStart", function()
        if combatLocked() or not safeMinimap(map) then return end
        self.ignoreClickUntil = nil
        self.dragging, self.dragProfile = true, ui:Profile()
        frame:SetScript("OnUpdate", function() self:UpdateDrag() end)
        self:UpdateDrag()
    end)
    frame:SetScript("OnDragStop", function()
        local wasDragging = self.dragging
        self:UpdateDrag(); self:EndDrag(not combatLocked()); self:Refresh()
        if wasDragging then self.ignoreClickUntil = ui:Now() + 0.15 end
    end)
    frame:SetScript("OnHide", function() self:EndDrag(false); hideTooltip() end)
    frame:SetScript("OnClick", function(_, mouseButton)
        if self.dragging or (self.ignoreClickUntil and self.ignoreClickUntil > ui:Now()) then return end
        if mouseButton == "RightButton" then ui:OpenSettings() else ui:Toggle() end
    end)
    frame:SetScript("OnEnter", function()
        local status = ui.statusCache
        local state = type(status) == "table" and status.state or "active"
        local key = ({ active = "active", limited = "limited", paused = "paused", disabled = "disabled" })[state] or "active"
        local count = M.Number(ui.visibleCount, 0)
        tooltip(frame, ui:T("addon") .. " · " .. ui:T(key), ui:F("inViewCount", count) .. "\n" .. ui:T("launcherTip"))
    end)
    frame:SetScript("OnLeave", hideTooltip)

    function self:Destroy()
        if self.destroyed then return end
        self.destroyed = true
        self:EndDrag(false); frame:Hide()
    end

    self:Refresh()
    return self
end
