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
        return badge
    end

    local function paint(badge)
        local profile = getProfile()
        local contact = badge.contact
        local class = contact and RG.UIModel.Text(contact.class, "")
        if not profile.enabled or not profile.display.showBadges or not contact or contact.hostile ~= true or contact.isPlayer ~= true or not RG.Defaults.classSet[class] then
            badge:Hide()
            return
        end
        if not RG.UIModel.ClassEnabled(profile.display.classes, class) then badge:Hide() return end
        badge.icon:SetTexture("Interface\\Icons\\ClassIcon_" .. class)
        badge.marker:SetShown(contact.watched == true or contact.listKind == "avoid")
        local scale = profile.display.highContrast and 1.15 or 1
        if badge.styleScale ~= scale and not locked() then badge:SetScale(scale); badge.styleScale = scale end
        badge:Show()
    end

    function self:Set(unit, frame, contact)
        if type(unit) ~= "string" or not unit:match("^nameplate%d+$") or not frame or not frame.SetPoint or not available(frame) then return end
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
            badge:SetPoint("LEFT", frame, "RIGHT", 6, 0)
            badge.parent = frame
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
