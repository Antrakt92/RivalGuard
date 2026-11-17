local _, RG = ...
local B = RG.Register("Badges", {})

function B.New(getProfile)
    local self = { active = {}, pool = {}, count = 0 }
    local function locked()
        if not InCombatLockdown then return false end
        local ok, combat = pcall(InCombatLockdown)
        if not ok then return true end
        if issecretvalue then
            local cleanOK, secret = pcall(issecretvalue, combat)
            if not cleanOK or secret then return true end
        end
        return combat == true
    end

    local function available(frame)
        for _, method in ipairs({ "IsForbidden", "IsProtected" }) do
            if frame[method] then
                local ok, value = pcall(frame[method], frame)
                if not ok then return false end
                if issecretvalue then
                    local clean, secret = pcall(issecretvalue, value)
                    if not clean or secret then return false end
                end
                if value ~= false then return false end
            end
        end
        return true
    end

    local function acquire()
        local badge = table.remove(self.pool)
        if badge then return badge end
        if self.count >= 128 then return nil end
        self.count = self.count + 1
        badge = CreateFrame("Frame", nil, UIParent)
        badge:SetSize(24, 24)
        badge:EnableMouse(false)
        badge.bg = badge:CreateTexture(nil, "BACKGROUND")
        badge.bg:SetAllPoints()
        badge.bg:SetColorTexture(0.02, 0.03, 0.05, 0.95)
        badge.icon = badge:CreateTexture(nil, "ARTWORK")
        badge.icon:SetPoint("TOPLEFT", 2, -2)
        badge.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        badge.marker = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        badge.marker:SetPoint("TOPRIGHT", 5, 6)
        badge.marker:SetText("!")
        badge.marker:SetTextColor(1, 0.80, 0.25)
        badge.target = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        badge.target:SetPoint("BOTTOM", badge, "TOP", 0, 0)
        badge.target:SetText("▼"); badge.target:SetTextColor(0.36, 0.86, 0.98)
        badge.focus = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        badge.focus:SetPoint("TOP", badge, "BOTTOM", 0, 0)
        badge.focus:SetText("◆"); badge.focus:SetTextColor(0.91, 0.62, 1)
        return badge
    end

    local function paint(badge)
        local profile = getProfile()
        local contact = badge.contact
        local class = contact and RG.UIModel.Text(contact.class, "")
        if not profile.enabled or not profile.display.showBadges or not contact or contact.hostile ~= true or contact.isPlayer ~= true
            or contact.dead == true or contact.behindCamera == true or contact.listKind == "ignore" or not RG.Defaults.classSet[class] then
            badge:Hide()
            return
        end
        if not RG.UIModel.ClassEnabled(profile.display.classes, class) then badge:Hide() return end
        badge.icon:SetTexture("Interface\\Icons\\ClassIcon_" .. class)
        badge.marker:SetShown(contact.watched == true or contact.listKind == "avoid")
        badge.target:SetShown(profile.display.badgeTarget == true and contact.currentTarget == true)
        badge.focus:SetShown(profile.display.badgeFocus == true and contact.currentFocus == true)
        if not locked() then
            local size = RG.Util.Clamp(profile.display.badgeSize, 16, 40, 24)
            local offset = RG.Util.Clamp(profile.display.badgeOffset, 0, 30, 6)
            if badge.styleSize ~= size then badge:SetSize(size, size); badge.styleSize = size end
            if badge.styleOffset ~= offset and badge.parent then
                badge:ClearAllPoints(); badge:SetPoint("LEFT", badge.parent, "RIGHT", offset, 0); badge.styleOffset = offset
            end
        end
        badge:Show()
    end

    function self:Set(unit, frame, contact)
        if type(unit) ~= "string" or not unit:match("^nameplate%d+$") then return end
        if not frame or not frame.SetPoint or not available(frame) then self:Remove(unit); return end
        local badge = self.active[unit]
        if locked() and (not badge or badge.parent ~= frame) then return end
        if not badge then
            badge = acquire()
            if not badge then return end
            self.active[unit] = badge
        end
        badge.contact = contact
        if badge.parent ~= frame then
            badge:ClearAllPoints()
            badge:SetParent(frame)
            badge.parent = frame
            badge.styleOffset = nil
        end
        paint(badge)
    end

    function self:Remove(unit)
        local badge = self.active[unit]
        if not badge then return end
        self.active[unit] = nil
        badge:Hide()
        badge.contact = nil
        if not locked() then
            badge:ClearAllPoints()
            badge:SetParent(UIParent)
            badge.parent = nil
            badge.styleOffset = nil
        end
        self.pool[#self.pool + 1] = badge
    end

    function self:Refresh()
        for _, badge in pairs(self.active) do paint(badge) end
    end

    function self:Destroy()
        local units = {}
        for unit in pairs(self.active) do units[#units + 1] = unit end
        for _, unit in ipairs(units) do self:Remove(unit) end
    end

    return self
end
