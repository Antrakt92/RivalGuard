local _, RG = ...
local T = RG.Register("NearbyTarget", {})

function T.New(app, panel, selectContact, hoverRow)
    local client, api = app.client, app.client.api
    local self = { buttons = {} }
    local pointer = CreateFrame("Frame", nil, panel)
    pointer:SetSize(24, 24)
    pointer:SetPoint("BOTTOM", panel, "TOP", 0, 3)
    pointer:EnableMouse(false)
    pointer.arrow = pointer:CreateTexture(nil, "ARTWORK")
    pointer.arrow:SetAllPoints()
    pointer.arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
    pointer.arrow:SetVertexColor(1, 0.85, 0.38)
    pointer:Hide()
    self.pointer = pointer

    local function point(frame, corner)
        local x, y
        if corner then
            x, y = client:Safe(frame.GetLeft, frame), client:Safe(frame.GetTop, frame)
        else
            x, y = client:Safe(frame.GetCenter, frame)
        end
        local scale = client:Number(client:Safe(frame.GetEffectiveScale, frame))
        x, y = client:Number(x), client:Number(y)
        if x and y and scale and scale > 0 then return x * scale, y * scale, scale end
    end

    function self:PointAt(contact)
        self.contact = contact
        self:UpdatePointer()
    end

    function self:UpdatePointer(elapsed)
        if elapsed then
            self.pointerElapsed = (self.pointerElapsed or 0) + elapsed
            if self.pointerElapsed < 0.05 then return end
        end
        self.pointerElapsed = 0
        local _, frame = app:NearbyTarget(self.contact)
        if frame and panel:IsVisible() then
            local x, y = point(pointer)
            local targetX, targetY = point(frame)
            if x and targetX and (x ~= targetX or y ~= targetY) then
                pointer.arrow:SetRotation(math.atan2(targetY - y, targetX - x) - math.pi / 2)
                pointer:Show()
                return
            end
        end
        pointer:Hide()
        self.contact = nil
    end

    -- Keep the protected buttons off the movable panel's parent and anchor chains.
    -- The secure visibility driver removes them synchronously on combat entry.
    if type(api.RegisterStateDriver) ~= "function" then return self end
    local layer
    local function locked()
        return client:Boolean(client:Safe(api.InCombatLockdown)) ~= false
    end

    function self:Sync(rows, moving)
        if locked() then return end
        local rootScale = client:Number(client:Safe(UIParent.GetEffectiveScale, UIParent))
        if not rootScale or rootScale <= 0 then return end
        for index, row in ipairs(rows) do
            local x, y, scale
            if not moving and row:IsVisible() and row.contact and row.contact.visible and not row.contact.preview then
                x, y, scale = point(row, true)
            end
            local button = self.buttons[index]
            if x and not button then
                if not layer then
                    layer = CreateFrame("Frame", nil, UIParent, "SecureHandlerStateTemplate")
                    layer:SetFrameStrata("MEDIUM")
                    layer:SetFrameLevel(panel:GetFrameLevel() + 8)
                    api.RegisterStateDriver(layer, "visibility", "[combat] hide; show")
                end
                button = CreateFrame("Button", nil, layer, "SecureActionButtonTemplate")
                self.buttons[index] = button
                button:RegisterForClicks("AnyDown", "AnyUp")
                button:SetAttribute("type", "macro")
                for i = 2, 31 do button:SetAttribute("*type" .. i, "none") end
                button:SetScript("PreClick", function(widget, mouseButton)
                    widget.selection, widget.guid = nil, nil
                    if locked() or mouseButton ~= "LeftButton" then return end
                    widget:SetAttribute("macrotext", nil)
                    local left, top = point(row, true)
                    if not row:IsVisible() or left ~= widget.left or top ~= widget.top then return end
                    local contact = row.contact
                    local token, _, guid = app:NearbyTarget(contact)
                    if not token then return end
                    local name = client:Names(token)
                    if not name or not name:match("^[%a%d\128-\255 '%.%-]+$") then return end
                    local command = client:Text(api.SLASH_TARGET_EXACT1, 32) or "/targetexact"
                    widget.selection, widget.guid = contact, guid
                    widget:SetAttribute("macrotext", command .. " " .. name)
                end)
                button:SetScript("PostClick", function(widget, mouseButton, down)
                    local left, top = point(row, true)
                    if mouseButton == "RightButton" and not down and row:IsVisible() and row.contact
                        and left == widget.left and top == widget.top then
                        selectContact(row.contact)
                    end
                    if mouseButton ~= "LeftButton" or not widget.selection then return end
                    if not locked() then widget:SetAttribute("macrotext", nil) end
                    self:PointAt(widget.selection)
                    if client:Text(client:Safe(api.UnitGUID, "target"), 128) ~= widget.guid then return end
                    app:HighlightContact(widget.selection)
                    if client.interface ~= 16001 then return end
                    local readable, marker = pcall(api.GetRaidTargetIndex, "target")
                    if readable and client:Readable(marker) and marker == nil then
                        client:Safe(api.SetRaidTarget, "target", 8)
                    end
                end)
                button:SetScript("OnEnter", function() hoverRow(row, true) end)
                button:SetScript("OnLeave", function() hoverRow(row, false) end)
            end
            if button then
                if x then
                    local width = (row:GetWidth() - 67) * scale / rootScale
                    local height = row:GetHeight() * scale / rootScale
                    if button.left ~= x or button.top ~= y or button.width ~= width or button.height ~= height then
                        button:SetSize(width, height)
                        button:ClearAllPoints()
                        button:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / rootScale, y / rootScale)
                        button.left, button.top, button.width, button.height = x, y, width, height
                    end
                end
                if button:IsShown() ~= (x ~= nil) then button:SetShown(x ~= nil) end
            end
        end
    end

    function self:Destroy()
        if layer and not locked() then
            if api.UnregisterStateDriver then api.UnregisterStateDriver(layer, "visibility") end
            layer:Hide()
        end
    end

    return self
end
