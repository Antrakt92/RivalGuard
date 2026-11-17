local _, RG = ...
local B = RG.Register("Badges", {})
local SECURITY_METHODS = { "IsForbidden", "IsProtected" }

local function show(badge, region, shown)
    if badge.shownState[region] == shown then return end
    local frame = region == "root" and badge or badge[region]
    frame:SetShown(shown)
    badge.shownState[region] = shown
end

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
        for _, method in ipairs(SECURITY_METHODS) do
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
        badge.shownState = {}
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
        badge.locator = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        badge.locator:SetFont(STANDARD_TEXT_FONT or "Fonts\\ARIALN.TTF", 26, "OUTLINE")
        badge.locator:SetText("▼"); badge.locator:SetTextColor(1, 0.85, 0.38)
        show(badge, "locator", false)
        return badge
    end

    local function paint(badge)
        local profile = getProfile()
        local contact = badge.contact
        local class = contact and RG.UIModel.Text(contact.class, "")
        local observed = profile.enabled == true and contact ~= nil and contact.hostile == true and contact.isPlayer == true
            and contact.dead ~= true and contact.behindCamera ~= true and contact.listKind ~= "ignore"
        local highlight = self.highlight
        local showLocator = observed and highlight ~= nil and highlight.badge == badge and highlight.id == contact.id
        local showClass = observed and profile.display.showBadges == true and RG.Defaults.classSet[class] == true
            and RG.UIModel.ClassEnabled(profile.display.classes, class)
        show(badge, "locator", showLocator)
        if not showClass and not showLocator then
            show(badge, "root", false)
            return false
        end
        show(badge, "bg", showClass)
        show(badge, "icon", showClass)
        if showClass and badge.textureClass ~= class then
            badge.icon:SetTexture("Interface\\Icons\\ClassIcon_" .. class)
            badge.textureClass = class
        end
        show(badge, "marker", showClass and (contact.watched == true or contact.listKind == "avoid"))
        show(badge, "target", showClass and profile.display.badgeTarget == true and contact.currentTarget == true)
        show(badge, "focus", showClass and profile.display.badgeFocus == true and contact.currentFocus == true)
        local size = RG.Util.Clamp(profile.display.badgeSize, 16, 40, 24)
        local offset = RG.Util.Clamp(profile.display.badgeOffset, 0, 30, 6)
        local resize, reposition = badge.styleSize ~= size, badge.styleOffset ~= offset and badge.parent ~= nil
        if (resize or reposition) and not locked() then
            if resize then badge:SetSize(size, size); badge.styleSize = size end
            if reposition then
                badge:ClearAllPoints(); badge:SetPoint("LEFT", badge.parent, "RIGHT", offset, 0); badge.styleOffset = offset
            end
        end
        show(badge, "root", true)
        return showLocator
    end

    function self:ClearHighlight()
        local highlight = self.highlight
        if not highlight then return end
        self.highlight = nil
        show(highlight.badge, "locator", false)
        if available(highlight.frame) then paint(highlight.badge) else show(highlight.badge, "root", false) end
    end

    function self:Highlight(unit, frame, id, now)
        local badge = self.active[unit]
        if not badge or badge.parent ~= frame or not badge.contact or badge.contact.id ~= id then return false end
        self:ClearHighlight()
        self.highlight = { unit = unit, frame = frame, badge = badge, id = id, expires = now + 3, checkAt = now }
        if paint(badge) then return true end
        self.highlight = nil
        return false
    end

    function self:Set(unit, frame, contact)
        if type(unit) ~= "string" or not unit:match("^nameplate%d+$") then return end
        if not frame or not frame.SetPoint or not available(frame) then self:Remove(unit); return end
        local badge = self.active[unit]
        if (not badge or badge.parent ~= frame) and locked() then
            if badge then self:Remove(unit) end
            return
        end
        if not badge then
            badge = acquire()
            if not badge then return end
            self.active[unit] = badge
        end
        if self.highlight and self.highlight.unit == unit and (self.highlight.id ~= contact.id or self.highlight.frame ~= frame
            or contact.behindCamera == true) then self:ClearHighlight() end
        badge.contact = contact
        if badge.parent ~= frame then
            badge:ClearAllPoints()
            badge:SetParent(frame)
            badge.locator:ClearAllPoints()
            badge.locator:SetPoint("BOTTOM", frame, "TOP", 0, 5)
            badge.parent = frame
            badge.styleOffset = nil
        end
        paint(badge)
    end

    function self:Remove(unit)
        local badge = self.active[unit]
        if not badge then return end
        if self.highlight and self.highlight.unit == unit then
            self.highlight = nil
        end
        self.active[unit] = nil
        show(badge, "locator", false)
        show(badge, "root", false)
        badge.contact = nil
        if not locked() then
            badge:ClearAllPoints()
            badge.locator:ClearAllPoints()
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
