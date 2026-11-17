local _, RG = ...
local D = RG.Register("UIDialogs", {})
local M = RG.UIModel

function D.Attach(ui, app, H)
    local self = { ruleOffset = 0 }
    local dialogs = {}
    local function t(key) return ui:T(key) end
    local function notify(key) H.notify(key) end

    local function dialog(name, titleKey, width, height)
        local frame = ui:Window(name, UIParent)
        frame:SetSize(width, height); frame:SetPoint("CENTER"); frame:SetFrameStrata("DIALOG")
        frame:SetClampedToScreen(true); frame:EnableMouse(true)
        H.fill(frame); H.outline(frame)
        dialogs[#dialogs + 1] = frame
        local title = H.label(frame, titleKey, 18, H.C.accent)
        title:SetPoint("TOPLEFT", 18, -17); title:SetWidth(width - 130)
        local close = H.localButton(frame, "close", 84, function() frame:Hide() end)
        close:SetPoint("TOPRIGHT", -12, -10)
        frame.close = close
        if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = name end
        return frame
    end

    local function showDialog(frame)
        ui:FitWindow(frame, frame:GetWidth(), frame:GetHeight(), 1)
        frame:Show()
    end

    function self:CurrentSoundPicker()
        local picker = ui.soundPicker
        local selection = self.soundSelection
        if not selection or not picker:IsShown() or ui.destroyed then return end
        if selection.source:IsVisible() and selection.current() ~= nil then return selection end
        picker:Hide()
    end

    function self:OpenSoundPicker(source, options, current, choose)
        local selected = current()
        if selected == nil or not source:IsVisible() then return end
        local picker = ui.soundPicker
        if not picker then
            picker = dialog("RivalGuardSoundPicker", "chooseSound", 392, 320)
            picker:SetFrameStrata("FULLSCREEN_DIALOG")
            picker.rows = {}
            picker:SetScript("OnHide", function() self.soundSelection = nil end)
            for i = 1, #RG.Defaults.soundOptions do
                local row = {}
                row.choice = H.button(picker, "", 232, function()
                    local selection = self:CurrentSoundPicker()
                    if not selection or not row.value then return end
                    picker:Hide()
                    selection.choose(row.value)
                end)
                row.choice:SetPoint("TOPLEFT", 18, -59 - (i - 1) * 40)
                row.listen = H.localButton(picker, "previewSound", 111, function()
                    if self:CurrentSoundPicker() and app.PreviewSound and row.value and row.value ~= "none" and row.value ~= "inherit" then
                        app:PreviewSound(nil, row.value)
                    end
                end)
                row.listen:SetPoint("LEFT", row.choice, "RIGHT", 12, 0)
                picker.rows[i] = row
            end
            ui.soundPicker = picker
        end
        self.soundSelection = { source = source, current = current, choose = choose }
        for index, row in ipairs(picker.rows) do
            local option = options[index]
            row.value = option and option[1]
            row.choice:SetShown(option ~= nil); row.listen:SetShown(option ~= nil)
            if option then
                row.choice.label:SetText(t(option[2]))
                row.choice.bg:SetColorTexture(unpack(row.value == selected and { 0.10, 0.22, 0.28, 1 } or H.C.panel))
                row.listen:SetEnabled(row.value ~= "none" and row.value ~= "inherit")
            end
        end
        showDialog(picker)
    end

    local function textInput(parent, width, maxBytes)
        local edit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        edit:SetSize(width, 28); edit:SetAutoFocus(false); edit:SetMaxLetters(maxBytes)
        if edit.SetMaxBytes then edit:SetMaxBytes(maxBytes) end
        edit:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
        return edit
    end

    function self:RuleDraft(index)
        local profile = ui:Profile()
        self.ruleIndex, self.ruleProfile = index, profile
        self.ruleAutoName = index == nil
        self.ruleOriginal = index and profile.rules[index] or nil
        self.ruleDraft = RG.Util.Copy(self.ruleOriginal or {
            name = t("ruleNewName"), enabled = true, priority = 50, classes = {},
            event = "sighting", action = "alert", sound = true, banner = true, cooldown = 30,
            context = "any", list = "any", range = 0, rangePolicy = "possible", rangeUnknown = false, knownClassOnly = true,
        })
        self.ruleDraft.context = self.ruleDraft.context or "any"
        self.ruleDraft.list = self.ruleDraft.list or "any"
        self.ruleDraft.range = self.ruleDraft.range or 0
        self.ruleDraft.rangePolicy = self.ruleDraft.rangePolicy or "possible"
        self.ruleDraft.rangeUnknown = self.ruleDraft.rangeUnknown == true
        self.ruleDraft.soundCue = self.ruleDraft.soundCue or "inherit"
        if self.rulesFrame then
            self.loadingRule = true
            self.rulesFrame.nameInput:SetText(self.ruleDraft.name)
            self.loadingRule = false
        end
        self:RefreshRules()
    end

    local function draftCheck(parent, key, field, x, y, labelWidth)
        local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", x, y); check:SetSize(26, 26)
        local label = H.label(check, key, 13)
        label:SetPoint("LEFT", check, "RIGHT", 2, 0); label:SetWidth(labelWidth or 360); label:SetJustifyV("MIDDLE")
        check:SetHitRectInsets(0, -(labelWidth or 350), 0, 0)
        check:SetScript("OnClick", function()
            if self.ruleDraft then self.ruleDraft[field] = check:GetChecked() and true or false; self:RefreshRules() end
        end)
        return check
    end

    local function draftChoice(parent, key, field, options, x, y, width, soundPicker)
        local label = H.label(parent, key, 12, H.C.muted)
        label:SetPoint("TOPLEFT", x, y); label:SetWidth(width)
        local b
        b = H.button(parent, "", width, function()
            local draft = self.ruleDraft
            if not draft then return end
            if soundPicker then
                self.rulesFrame.nameInput:ClearFocus()
                self:OpenSoundPicker(b, options, function()
                    if self.ruleDraft == draft and self.ruleProfile == ui:Profile() and draft.action == "alert" and draft.sound then
                        return draft[field]
                    end
                end, function(value)
                    draft[field] = value
                    self:RefreshRules()
                end)
                return
            end
            local found = 0
            for i, option in ipairs(options) do if option[1] == self.ruleDraft[field] then found = i break end end
            self.ruleDraft[field] = options[found % #options + 1][1]
            self:RefreshRules()
        end)
        b:SetPoint("TOPLEFT", x, y - 23)
        b.ruleField, b.ruleOptions = field, options
        return b
    end

    local function draftSlider(parent, key, field, x, y, low, high, step)
        local label = H.label(parent, key, 12, H.C.muted)
        label:SetPoint("TOPLEFT", x, y); label:SetWidth(290)
        local valueText = H.font(parent, 12, H.C.accent, "RIGHT")
        valueText:SetPoint("TOPLEFT", x + 290, y); valueText:SetWidth(100)
        local slider = CreateFrame("Slider", nil, parent)
        slider:SetPoint("TOPLEFT", x + 4, y - 27); slider:SetSize(380, 16)
        slider:SetOrientation("HORIZONTAL"); slider:SetMinMaxValues(low, high); slider:SetValueStep(step)
        if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
        H.fill(slider, H.C.panel); H.outline(slider)
        slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        slider:SetScript("OnValueChanged", function(_, value)
            if self.loadingRule or not self.ruleDraft then return end
            self.ruleDraft[field] = math.floor(value / step + 0.5) * step
            if field == "range" then self:RefreshRules()
            else valueText:SetText(tostring(self.ruleDraft[field])) end
        end)
        slider.ruleField, slider.valueText = field, valueText
        return slider
    end

    function self:BuildRules()
        local f = dialog("RivalGuardRules", "rules", 800, 675)
        self.rulesFrame, ui.rulesDialog = f, f
        local explanation = H.label(f, "rulesHelp", 12, H.C.muted)
        explanation:SetPoint("TOPLEFT", 18, -57); explanation:SetWidth(760)
        local new = H.localButton(f, "newRule", 184, function()
            if #ui:Profile().rules >= 32 then notify("ruleLimit") return end
            self:RuleDraft(nil)
        end)
        new:SetPoint("TOPLEFT", 18, -124)
        f.rows = {}
        for i = 1, 10 do
            local row = H.button(f, "", 205, function() end)
            row:SetPoint("TOPLEFT", 18, -166 - (i - 1) * 38)
            row:SetScript("OnClick", function() if row.index then self:RuleDraft(row.index) end end)
            f.rows[i] = row
        end
        f.previous = H.localButton(f, "previous", 97, function()
            self.ruleOffset = math.max(0, self.ruleOffset - 10); self:RefreshRules()
        end)
        f.previous:SetPoint("TOPLEFT", 18, -553)
        f.next = H.localButton(f, "next", 97, function() self.ruleOffset = self.ruleOffset + 10; self:RefreshRules() end)
        f.next:SetPoint("LEFT", f.previous, "RIGHT", 11, 0)
        f.empty = H.label(f, "emptyRules", 12, H.C.muted)
        f.empty:SetPoint("TOPLEFT", 18, -171); f.empty:SetWidth(200)
        local base = CreateFrame("Frame", nil, f); base:SetAllPoints(f)
        local predicates = CreateFrame("Frame", nil, f); predicates:SetAllPoints(f)
        f.basicPanel, f.conditionPanel = base, predicates
        f.basic = H.localButton(f, "basicRule", 167, function() self.ruleTab = "basic"; self:RefreshRules() end)
        f.basic:SetPoint("TOPLEFT", 253, -108)
        f.conditions = H.localButton(f, "ruleConditions", 167, function()
            self.ruleTab = "conditions"; f.nameInput:ClearFocus(); self:RefreshRules()
        end)
        f.conditions:SetPoint("LEFT", f.basic, "RIGHT", 12, 0)
        local nameLabel = H.label(base, "ruleName", 13)
        nameLabel:SetPoint("TOPLEFT", 253, -151)
        f.nameInput = textInput(base, 495, 80)
        f.nameInput:SetPoint("TOPLEFT", 260, -174)
        f.nameInput:SetScript("OnTextChanged", function(box)
            if not self.loadingRule and self.ruleDraft then
                self.ruleDraft.name = box:GetText()
                self.ruleAutoName = false
            end
        end)
        f:SetScript("OnHide", function() f.nameInput:ClearFocus() end)
        f.enabled = draftCheck(base, "ruleEnabled", "enabled", 250, -209)
        f.event = draftChoice(base, "ruleEvent", "event", {
            { "sighting", "sighting" }, { "returning", "returning" }, { "stealth", "eventStealth" },
            { "targeting", "eventTargeting" }, { "any", "anyEvent" },
        }, 253, -243, 495)
        local classesLabel = H.label(base, "ruleClasses", 12, H.C.muted)
        classesLabel:SetPoint("TOPLEFT", 253, -299)
        local soloHint = H.label(base, "classSoloHint", 12, H.C.muted)
        soloHint:SetPoint("TOPRIGHT", -52, -299); soloHint:SetWidth(240); soloHint:SetJustifyH("RIGHT")
        f.classes = {}
        for i, token in ipairs(RG.Defaults.classes) do
            local class = token
            local b = CreateFrame("Button", nil, base)
            b:SetSize(26, 26); b:SetPoint("TOPLEFT", 253 + (i - 1) * 35, -322)
            H.fill(b, H.C.panel); b.edges = H.outline(b)
            b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetPoint("TOPLEFT", 2, -2); b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
            b.icon:SetTexture("Interface\\Icons\\ClassIcon_" .. class)
            b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            b:SetScript("OnClick", function(_, mouseButton)
                local draft = self.ruleDraft
                if not draft then return end
                if mouseButton == "RightButton" then
                    draft.classes = { [class] = true }
                    if self.ruleAutoName then
                        draft.name = ui:F("classRuleName", RG.Locale.Class(class, ui:Profile().locale))
                        self.loadingRule = true
                        f.nameInput:SetText(draft.name)
                        self.loadingRule = false
                    end
                else
                    draft.classes = M.ToggleClass(draft.classes, class)
                end
                self:RefreshRules()
            end)
            b:SetScript("OnEnter", function() H.tooltip(b, RG.Locale.Class(class, ui:Profile().locale), t("ruleClassSoloTip")) end)
            b:SetScript("OnLeave", H.hideTooltip)
            f.classes[#f.classes + 1] = { class = class, frame = b }
        end
        f.allClasses = H.localButton(base, "all", 160, function() self.ruleDraft.classes = {}; self:RefreshRules() end)
        f.allClasses:SetPoint("TOPLEFT", 253, -357)
        f.clearClasses = H.localButton(base, "clearClassSelection", 140, function()
            self.ruleDraft.classes = M.ClearClasses()
            self:RefreshRules()
        end)
        f.clearClasses:SetPoint("LEFT", f.allClasses, "RIGHT", 12, 0)
        f.clearClasses:SetScript("OnEnter", function()
            H.tooltip(f.clearClasses, t("clearClassSelection"), t("clearRuleClassesTip"))
        end)
        f.clearClasses:SetScript("OnLeave", H.hideTooltip)
        f.knownClassOnly = draftCheck(base, "ruleKnownClass", "knownClassOnly", 573, -357, 145)
        f.knownClassOnly:SetScript("OnEnter", function() H.tooltip(f.knownClassOnly, t("ruleKnownClass"), t("ruleKnownClassTip")) end)
        f.knownClassOnly:SetScript("OnLeave", H.hideTooltip)
        f.action = draftChoice(base, "ruleAction", "action", { { "alert", "ruleAlert" }, { "suppress", "ruleSuppress" } }, 253, -395, 190)
        local cues = { { "inherit", "ruleSoundInherit" } }
        for _, option in ipairs(RG.Defaults.soundOptions) do
            if option[1] ~= "none" then cues[#cues + 1] = option end
        end
        f.soundCue = draftChoice(base, "ruleSoundCue", "soundCue", cues, 455, -395, 179, true)
        f.previewCue = H.localButton(base, "previewSound", 102, function()
            if app.PreviewSound and self.ruleDraft then app:PreviewSound(nil, self.ruleDraft.soundCue) end
        end)
        f.previewCue:SetPoint("LEFT", f.soundCue, "RIGHT", 12, 0)
        f.soundCue:SetScript("OnEnter", function() H.tooltip(f.soundCue, t("ruleSoundCue"), t("ruleSoundCueHelp")) end)
        f.soundCue:SetScript("OnLeave", H.hideTooltip)
        f.sound = draftCheck(base, "ruleSound", "sound", 250, -453)
        f.banner = draftCheck(base, "ruleBanner", "banner", 470, -453)
        -- Keep each checkbox's hit area in its own column.
        f.sound:SetHitRectInsets(0, -180, 0, 0)
        f.banner:SetHitRectInsets(0, -180, 0, 0)
        f.cooldown = draftSlider(base, "ruleCooldown", "cooldown", 253, -498, 0, 600, 5)
        f.priority = draftSlider(base, "rulePriority", "priority", 253, -557, 1, 100, 1)
        local conditionHelp = H.label(predicates, "ruleConditionsHelp", 12, H.C.muted)
        conditionHelp:SetPoint("TOPLEFT", 253, -156); conditionHelp:SetWidth(495)
        f.context = draftChoice(predicates, "ruleContext", "context", {
            { "any", "contextAny" }, { "world", "world" }, { "battleground", "battleground" }, { "arena", "arena" }, { "instance", "instance" },
        }, 253, -230, 495)
        f.list = draftChoice(predicates, "ruleListStatus", "list", {
            { "any", "listAny" }, { "listed", "listListed" }, { "unlisted", "listUnlisted" },
        }, 253, -296, 495)
        f.range = draftSlider(predicates, "ruleRange", "range", 253, -365, 0, 100, 5)
        local rangeHelp = H.label(predicates, "ruleRangeHelp", 11, H.C.muted)
        rangeHelp:SetPoint("TOPLEFT", 253, -414); rangeHelp:SetWidth(495)
        f.rangePolicy = draftChoice(predicates, "rangePolicy", "rangePolicy", {
            { "possible", "possible" }, { "confirmed", "confirmed" },
        }, 253, -472, 495)
        f.rangeUnknown = draftCheck(predicates, "unknownRange", "rangeUnknown", 250, -542)
        f.save = H.localButton(f, "saveRule", 160, function() self:SaveRule() end)
        f.save:SetPoint("TOPLEFT", 253, -625)
        f.delete = H.localButton(f, "deleteRule", 185, function() self:DeleteRule() end)
        f.delete:SetPoint("LEFT", f.save, "RIGHT", 12, 0)
        local hint = H.label(f, "ruleDraft", 11, H.C.muted)
        hint:SetPoint("TOPLEFT", 18, -612); hint:SetWidth(205)
        return f
    end

    function self:RefreshRules()
        local f = self.rulesFrame
        if not f or not self.ruleDraft then return end
        local rules = ui:Profile().rules
        self.ruleOffset = math.max(0, math.min(self.ruleOffset, math.max(0, math.floor((#rules - 1) / 10) * 10)))
        f.empty:SetShown(#rules == 0)
        for i, row in ipairs(f.rows) do
            local index = self.ruleOffset + i
            local rule = rules[index]
            row.index = rule and index or nil
            row:SetShown(rule ~= nil)
            if rule then
                row.label:SetText((rule.enabled and "" or "– ") .. M.Text(rule.name, ""))
                row.bg:SetColorTexture(unpack(index == self.ruleIndex and { 0.10, 0.22, 0.28, 1 } or H.C.panel))
            end
        end
        f.previous:SetEnabled(self.ruleOffset > 0); f.next:SetEnabled(self.ruleOffset + 10 < #rules)
        self.loadingRule = true
        local conditionTab = self.ruleTab == "conditions"
        f.basicPanel:SetShown(not conditionTab); f.conditionPanel:SetShown(conditionTab)
        f.basic.bg:SetColorTexture(unpack(not conditionTab and { 0.10, 0.22, 0.28, 1 } or H.C.panel))
        f.conditions.bg:SetColorTexture(unpack(conditionTab and { 0.10, 0.22, 0.28, 1 } or H.C.panel))
        for _, field in ipairs({ "enabled", "sound", "banner", "rangeUnknown", "knownClassOnly" }) do f[field]:SetChecked(self.ruleDraft[field] == true) end
        for _, key in ipairs({ "event", "action", "soundCue", "context", "list", "rangePolicy" }) do
            for _, option in ipairs(f[key].ruleOptions) do
                if self.ruleDraft[f[key].ruleField] == option[1] then f[key].label:SetText(t(option[2]) .. "  ›") end
            end
        end
        for _, key in ipairs({ "cooldown", "priority", "range" }) do
            f[key]:SetValue(self.ruleDraft[key])
            f[key].valueText:SetText(key == "range" and self.ruleDraft[key] == 0 and t("ruleRangeInherit") or tostring(self.ruleDraft[key]))
        end
        local visibleIndex = 0
        for _, chip in ipairs(f.classes) do
            local available = not ui.classAvailability or ui.classAvailability[chip.class] == true
            chip.frame:SetShown(available)
            if available then
                chip.frame:ClearAllPoints(); chip.frame:SetPoint("TOPLEFT", 253 + visibleIndex * 35, -322)
                visibleIndex = visibleIndex + 1
            end
            local selected = M.ClassEnabled(self.ruleDraft.classes, chip.class)
            chip.frame.icon:SetDesaturated(not selected); chip.frame.icon:SetAlpha(selected and 1 or 0.28)
            for _, edge in ipairs(chip.frame.edges) do edge:SetColorTexture(unpack(selected and H.C.accent or H.C.border)) end
        end
        local alert = self.ruleDraft.action == "alert"
        f.sound:SetEnabled(alert); f.banner:SetEnabled(alert)
        local sound = alert and self.ruleDraft.sound == true
        f.soundCue:SetEnabled(sound)
        f.previewCue:SetEnabled(sound and self.ruleDraft.soundCue ~= "inherit")
        f.rangePolicy:SetEnabled(self.ruleDraft.range > 0); f.rangeUnknown:SetEnabled(self.ruleDraft.range > 0)
        f.delete:SetEnabled(self.ruleIndex ~= nil)
        self.loadingRule = false
    end

    function self:SaveRule()
        if not self.ruleDraft then return end
        local profile = ui:Profile()
        if profile ~= self.ruleProfile or (self.ruleIndex and profile.rules[self.ruleIndex] ~= self.ruleOriginal) then
            notify("ruleInvalid"); self:RuleDraft(nil); return
        end
        local index = self.ruleIndex or (#profile.rules + 1)
        if index > 32 then notify("ruleLimit") return end
        local draft = RG.Util.Copy(self.ruleDraft)
        if draft.soundCue == "inherit" then draft.soundCue = nil end
        draft.name = RG.Util.Text(self.rulesFrame.nameInput:GetText(), 80)
        if not draft.name then notify("ruleNeedsName") return end
        local candidate = RG.Util.Copy(profile)
        candidate.rules[index] = draft
        local clean = RG.Database.ValidateProfile(candidate, true)
        if not clean then notify("ruleInvalid") return end
        profile.rules = clean.rules
        profile.preset = "custom"
        H.changed(); notify("ruleSaved"); self:RuleDraft(index)
    end

    function self:DeleteRule()
        local profile, index = ui:Profile(), self.ruleIndex
        if not index then return end
        if profile ~= self.ruleProfile or profile.rules[index] ~= self.ruleOriginal then notify("ruleInvalid"); self:RuleDraft(nil); return end
        local rules = RG.Util.Copy(profile.rules)
        table.remove(rules, index); profile.rules = rules
        H.changed(); notify("ruleDeleted"); self:RuleDraft(nil)
    end

    function self:OpenRules()
        if not self.rulesFrame then self:BuildRules() end
        self.ruleTab = "basic"
        self:RuleDraft(#ui:Profile().rules > 0 and 1 or nil)
        showDialog(self.rulesFrame)
    end

    function self:BuildTransfer()
        local f = dialog("RivalGuardTransfer", "transfer", 730, 650)
        self.transferFrame, ui.transferDialog = f, f
        f.help = H.font(f, 12, H.C.muted)
        f.help:SetPoint("TOPLEFT", 18, -58); f.help:SetWidth(686)
        f.nameLabel = H.label(f, "profileName", 13)
        f.nameLabel:SetPoint("TOPLEFT", 18, -119)
        f.nameInput = textInput(f, 510, 64)
        f.nameInput:SetPoint("TOPLEFT", 25, -145)
        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 18, -191); scroll:SetPoint("BOTTOMRIGHT", -40, 169)
        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true); edit:SetAutoFocus(false); edit:SetWidth(665); edit:SetHeight(280)
        edit:SetFontObject(ChatFontNormal or GameFontNormal)
        if edit.SetMaxBytes then edit:SetMaxBytes(65536) else edit:SetMaxLetters(65536) end
        edit:SetScript("OnEscapePressed", function(box) box:ClearFocus(); f:Hide() end)
        edit:SetScript("OnTextChanged", function(box)
            box:SetHeight(math.max(280, math.min(100000, M.Number(box:GetNumLines(), 1) * 16 + 24)))
            if self.loadingTransfer or self.transferMode ~= "import" then return end
            self.importText, self.importPreview = nil, nil
            f.summary:SetText(t("importChanged")); f.apply:SetEnabled(false)
        end)
        scroll:SetScrollChild(edit); f.edit, f.scroll = edit, scroll
        f.summary = H.font(f, 12, H.C.accent)
        f.summary:SetPoint("BOTTOMLEFT", 18, 83); f.summary:SetWidth(690); f.summary:SetHeight(68)
        f.preview = H.localButton(f, "validateImport", 190, function() self:PreviewImport() end)
        f.preview:SetPoint("BOTTOMLEFT", 18, 25)
        f.apply = H.localButton(f, "importNew", 310, function() self:ApplyImport() end)
        f.apply:SetPoint("LEFT", f.preview, "RIGHT", 12, 0)
        f:SetScript("OnHide", function()
            f.edit:ClearFocus(); f.nameInput:ClearFocus()
            self.importText, self.importPreview = nil, nil
        end)
        return f
    end

    function self:OpenTransfer(mode)
        if not self.transferFrame then self:BuildTransfer() end
        local f = self.transferFrame
        self.transferMode = mode == "export" and "export" or "import"
        self.importText, self.importPreview = nil, nil
        f.help:SetText(t(self.transferMode == "export" and "exportHelp" or "importHelp"))
        f.nameLabel:SetShown(self.transferMode == "import"); f.nameInput:SetShown(self.transferMode == "import")
        f.preview:SetShown(self.transferMode == "import"); f.apply:SetShown(self.transferMode == "import")
        f.apply:SetEnabled(false); f.nameInput:SetText("")
        self.loadingTransfer = true
        local text = ""
        if self.transferMode == "export" then
            text = (app.db.ExportProfile and app.db:ExportProfile()) or t("error")
        end
        f.edit:SetText(text)
        self.loadingTransfer = false
        f.summary:SetText(self.transferMode == "import" and t("importReady") or "")
        showDialog(f); f.edit:SetFocus()
        if self.transferMode == "export" then f.edit:HighlightText() end
    end

    function self:PreviewImport()
        local f = self.transferFrame
        if not f or self.transferMode ~= "import" then return end
        local text = f.edit:GetText()
        local clean = app.db.PreviewImport and app.db:PreviewImport(text)
        if not clean then
            self.importText, self.importPreview = nil, nil
            f.summary:SetText(t("importInvalid")); f.apply:SetEnabled(false); return
        end
        self.importText, self.importPreview = text, clean
        f.summary:SetText(ui:F("importPreview", #clean.rules, t(clean.enabled and "active" or "disabled")))
        f.apply:SetEnabled(true)
    end

    function self:ApplyImport()
        local f = self.transferFrame
        if not f or not self.importText or not self.importPreview then notify("importReady") return end
        if f.edit:GetText() ~= self.importText then self.importText = nil; f.apply:SetEnabled(false); notify("importChanged") return end
        local name = f.nameInput:GetText()
        local result = app.db.ImportProfile and app.db:ImportProfile(name, self.importText)
        if not result then notify("profileError") return end
        self.importText, self.importPreview = nil, nil
        f.apply:SetEnabled(false); f:Hide()
        H.changed(); notify("importSuccess")
    end

    function self:Refresh()
        self:CurrentSoundPicker()
        for _, frame in ipairs(dialogs) do
            if frame:IsShown() then ui:FitWindow(frame, frame:GetWidth(), frame:GetHeight(), 1) end
        end
        if self.rulesFrame and self.rulesFrame:IsShown() then self:RefreshRules() end
    end

    local GUIDE_STEPS = {
        { "guideWelcome", "guideWelcomeText" },
        { "guideRules", "guideRulesText" },
        { "guideTrust", "guideTrustText" },
    }

    function self:RenderGuide()
        local f = self.guideFrame
        local step = GUIDE_STEPS[self.guideStep]
        f.stepText:SetText(ui:F("guideStep", self.guideStep, #GUIDE_STEPS))
        f.heading:SetText(t(step[1])); f.body:SetText(t(step[2]))
        f.back:SetEnabled(self.guideStep > 1)
        f.openAlerts:SetShown(step[1] == "guideRules")
        f.next.label:SetText(t(self.guideStep == #GUIDE_STEPS and "guideDone" or "next"))
    end

    function self:FinishGuide()
        if self.guideFrame then self.guideFrame:Hide() end
    end

    function self:BuildGuide()
        local f = dialog("RivalGuardGuide", "guide", 600, 340)
        self.guideFrame, ui.guideDialog = f, f
        f.stepText = H.font(f, 12, H.C.muted)
        f.stepText:SetPoint("TOPLEFT", 20, -64); f.stepText:SetWidth(550)
        f.heading = H.font(f, 22, H.C.accent)
        f.heading:SetPoint("TOPLEFT", 20, -95); f.heading:SetWidth(550)
        f.body = H.font(f, 15, H.C.text)
        f.body:SetPoint("TOPLEFT", 20, -150); f.body:SetWidth(550)
        f.preview = H.localButton(f, "guidePreview", 210, function()
            self:FinishGuide()
            app:Demo()
        end)
        f.preview:SetPoint("BOTTOMLEFT", 20, 72)
        f.openAlerts = H.localButton(f, "guideOpenAlerts", 252, function()
            self:FinishGuide()
            ui:OpenSettings("alerts")
        end)
        f.openAlerts:SetPoint("LEFT", f.preview, "RIGHT", 12, 0)
        f.skip = H.localButton(f, "guideSkip", 150, function() self:FinishGuide() end)
        f.skip:SetPoint("BOTTOMLEFT", 20, 22)
        f.next = H.button(f, t("next"), 150, function()
            if self.guideStep >= #GUIDE_STEPS then self:FinishGuide() return end
            self.guideStep = self.guideStep + 1; self:RenderGuide()
        end)
        f.next:SetPoint("BOTTOMRIGHT", -20, 22)
        f.back = H.localButton(f, "back", 132, function()
            self.guideStep = math.max(1, self.guideStep - 1); self:RenderGuide()
        end)
        f.back:SetPoint("RIGHT", f.next, "LEFT", -12, 0)
        f:SetScript("OnHide", function()
            if not self.guidePresented then return end
            self.guidePresented = false
            if not ui.destroyed and app.db.MarkGuideSeen then app.db:MarkGuideSeen() end
        end)
        return f
    end

    function self:ShowGuide(replay)
        if not replay then
            if app.db.writable == false then return false end
            if app.db.HasSeenGuide and app.db:HasSeenGuide() then return false end
        end
        if not self.guideFrame then self:BuildGuide() end
        self.guideStep, self.guidePresented = 1, true
        self:RenderGuide()
        showDialog(self.guideFrame)
        return true
    end

    function ui:OpenRules() self.dialogs:OpenRules() end
    function ui:OpenSoundPicker(...) self.dialogs:OpenSoundPicker(...) end
    function ui:OpenTransfer(mode) self.dialogs:OpenTransfer(mode) end
    function ui:ShowGuide(replay) return self.dialogs:ShowGuide(replay) end
    return self
end
