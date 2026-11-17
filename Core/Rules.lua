local _, RG = ...
local U, D = RG.Util, RG.Defaults
local R = RG.Register("Rules", {})

function R.ClassMatches(classes, class, allowUnknown)
    if not class then return allowUnknown == true end
    if next(classes) == nil then return true end
    return classes[class] == true
end

function R.RangeMatches(config, contact, rangeFresh)
    if not config.enabled then return true end
    if rangeFresh == false then return config.unknown, "range_unknown" end
    local lower, upper = contact.rangeMin, contact.rangeMax
    if contact.rangeEvidence == "conflict" then return config.unknown, "range_conflict" end
    if not U.IsFinite(lower) and not U.IsFinite(upper) then return config.unknown, "range_unknown" end
    if U.IsFinite(lower) and (lower > config.yards or (lower == config.yards and contact.rangeMinExclusive)) then
        return false, "range_outside"
    end
    if config.policy == "confirmed" then
        if U.IsFinite(upper) and upper <= config.yards then return true, "range_confirmed" end
        return false, "range_unconfirmed"
    end
    return true, "range_possible"
end

function R.ExplanationScope(profile, matchedIndex, rangeChecked)
    local rule = profile.rules[matchedIndex]
    local ruleRange, globalRange
    if rule and rule.range and rule.range > 0 then
        ruleRange = { yards = rule.range, policy = rule.rangePolicy, unknown = rule.rangeUnknown }
    end
    local range = profile.range
    if rangeChecked and range.enabled then
        globalRange = { yards = range.yards, policy = range.policy, unknown = range.unknown }
    end
    return rule and rule.name, globalRange, ruleRange
end

function R.ContextMatches(config, context)
    local kind = context.kind or "world"
    if config[kind] ~= true then return false, "context_disabled" end
    for _, state in ipairs({ "sanctuary", "resting", "flight" }) do
        if context[state] == true and config[state] ~= true then return false, state end
    end
    return true
end

function R.Display(profile, contact, entry)
    if (entry and entry.kind or contact.listKind) == "ignore" then return false end
    return R.ClassMatches(profile.display.classes, contact.class, profile.display.showUnknown)
end

local PRIORITY = { sighting = 20, returning = 30, watch = 90, targeting = 70, stealth = 100 }
local THREAT_PRIORITY = { targeting = PRIORITY.targeting, stealth = PRIORITY.stealth }

function R.CompareAlertPriority(a, b, sameContact)
    local aThreat, bThreat = THREAT_PRIORITY[a.kind] or 0, THREAT_PRIORITY[b.kind] or 0
    -- A fresh threat carries more useful information than the same player's arrival.
    if sameContact and (aThreat == 0) ~= (bThreat == 0) then return aThreat - bThreat end
    if a.priority ~= b.priority then return a.priority - b.priority end
    return aThreat - bThreat
end

function R.ContactBlock(contact)
    if not contact or contact.hostile ~= true or contact.isPlayer ~= true then return "identity_unconfirmed" end
    if contact.dead == true then return "dead" end
end

function R.RuleEventMatches(rule, event)
    return rule.event == event or rule.event == "any"
        or (rule.event == "sighting" and rule.includeReturning == true and event == "returning")
end

function R.Evaluate(profile, contact, event, context, listEntry, rangeFresh)
    local identified = event == "identified"
    if identified then event = "sighting" end
    if not profile.enabled or not profile.alerts.enabled then return nil, "disabled" end
    if listEntry and listEntry.kind == "ignore" then return nil, "ignored" end
    local blocked = R.ContactBlock(contact)
    if blocked then return nil, blocked end
    local allowed, reason = R.ContextMatches(profile.context, context or {})
    if not allowed then return nil, reason end
    local inRange, rangeReason = R.RangeMatches(profile.range, contact, rangeFresh)
    if not inRange then return nil, rangeReason, nil, true end
    local watched = listEntry and (listEntry.kind == "watch" or listEntry.kind == "avoid")
    local kind = watched and (event == "sighting" or event == "returning") and "watch" or event
    if event == "stealth" and not profile.alerts.stealth then return nil, "event_disabled", nil, true end
    if event == "targeting" and not profile.alerts.targeting then return nil, "event_disabled", nil, true end
    if profile.alerts.watchedOnly and not watched then return nil, "watch_only", nil, true end
    if profile.alerts.muteOrdinary and (kind == "sighting" or kind == "returning") then return nil, "ordinary_muted", nil, true end
    local matched, matchedIndex
    for index, rule in ipairs(profile.rules) do
        if rule.enabled and R.RuleEventMatches(rule, event)
            and (not rule.context or rule.context == "any" or rule.context == ((context and context.kind) or "world"))
            and (not rule.list or rule.list == "any" or (rule.list == "listed" and watched) or (rule.list == "unlisted" and not watched))
            and R.ClassMatches(rule.classes, contact.class, profile.alerts.unknownClass and not rule.knownClassOnly) then
            local rangeMatches = not rule.range or rule.range == 0
                or R.RangeMatches({ enabled = true, yards = rule.range, policy = rule.rangePolicy, unknown = rule.rangeUnknown }, contact, rangeFresh)
            if rangeMatches and (not matched or rule.priority > matched.priority) then matched, matchedIndex = rule, index end
        end
    end
    if matched and matched.action == "suppress" then return nil, "custom_suppressed", matchedIndex, true end
    if not matched and not watched and not R.ClassMatches(profile.alerts.classes, contact.class, profile.alerts.unknownClass) then
        return nil, "class_filtered", nil, true
    end
    local decision = {
        kind = kind, priority = math.max(matched and matched.priority or PRIORITY[kind] or 20, THREAT_PRIORITY[kind] or 0),
        banner = profile.alerts.banner and (not matched or matched.banner),
        cooldown = matched and matched.cooldown or profile.alerts.cooldown,
        reason = matched and "custom_rule" or (watched and "watch_list" or "event_matched"),
        ruleName = matched and matched.name or nil,
        dedupKey = identified and "identified" or kind,
    }
    -- An unidentified class remains useful visually, without sounding like a
    -- confirmed match for one of the selected classes.
    local soundAllowed = profile.alerts.sound and (not matched or matched.sound) and (contact.class ~= nil or watched == true)
    local cue = (matched and matched.soundCue) or profile.alerts.sounds[kind]
    decision.sound = soundAllowed and cue ~= "none"
    decision.soundCue = decision.sound and cue or nil
    decision.waveSound = soundAllowed and profile.alerts.sounds.wave ~= "none"
        and decision.priority < 70 and (kind == "sighting" or kind == "returning")
    if not decision.sound and not decision.banner and not decision.waveSound then return nil, "outputs_disabled", matchedIndex, true end
    return decision, nil, matchedIndex, true
end
