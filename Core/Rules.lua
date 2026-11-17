local _, RG = ...
local U, D = RG.Util, RG.Defaults
local R = RG.Register("Rules", {})

function R.ClassMatches(classes, class, allowUnknown)
    if not class then return allowUnknown == true end
    if next(classes) == nil then return true end
    return classes[class] == true
end

function R.RangeMatches(config, contact)
    if not config.enabled then return true end
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

function R.Evaluate(profile, contact, event, context, listEntry)
    local identified = event == "identified"
    if identified then event = "sighting" end
    if not profile.enabled or not profile.alerts.enabled then return nil, "disabled" end
    if listEntry and listEntry.kind == "ignore" then return nil, "ignored" end
    if contact.hostile ~= true or contact.isPlayer ~= true then return nil, "identity_unconfirmed" end
    if contact.dead == true then return nil, "dead" end
    local allowed, reason = R.ContextMatches(profile.context, context or {})
    if not allowed then return nil, reason end
    local inRange, rangeReason = R.RangeMatches(profile.range, contact)
    if not inRange then return nil, rangeReason end
    local watched = listEntry and (listEntry.kind == "watch" or listEntry.kind == "avoid")
    local kind = watched and (event == "sighting" or event == "returning") and "watch" or event
    if event == "stealth" and not profile.alerts.stealth then return nil, "event_disabled" end
    if event == "targeting" and not profile.alerts.targeting then return nil, "event_disabled" end
    if profile.alerts.watchedOnly and not watched then return nil, "watch_only" end
    if profile.alerts.muteOrdinary and (kind == "sighting" or kind == "returning") then return nil, "ordinary_muted" end
    local matched
    for _, rule in ipairs(profile.rules) do
        if rule.enabled and (rule.event == event or rule.event == "any")
            and (not rule.context or rule.context == "any" or rule.context == ((context and context.kind) or "world"))
            and (not rule.list or rule.list == "any" or (rule.list == "listed" and watched) or (rule.list == "unlisted" and not watched))
            and R.ClassMatches(rule.classes, contact.class, profile.alerts.unknownClass) then
            local rangeMatches = not rule.range or rule.range == 0 or R.RangeMatches({ enabled = true, yards = rule.range, policy = rule.rangePolicy, unknown = rule.rangeUnknown }, contact)
            if rangeMatches and (not matched or rule.priority > matched.priority) then matched = rule end
        end
    end
    if matched and matched.action == "suppress" then return nil, "custom_suppressed" end
    if not matched and not watched and not R.ClassMatches(profile.alerts.classes, contact.class, profile.alerts.unknownClass) then return nil, "class_filtered" end
    local decision = {
        kind = kind, priority = matched and matched.priority or PRIORITY[kind] or 20,
        banner = profile.alerts.banner and (not matched or matched.banner),
        cooldown = matched and matched.cooldown or profile.alerts.cooldown,
        reason = matched and "custom_rule" or (watched and "watch_list" or "event_matched"),
        ruleName = matched and matched.name or nil,
        dedupKey = identified and "identified" or kind,
    }
    -- An unidentified class remains useful visually, without sounding like a
    -- confirmed match for one of the selected classes.
    local soundAllowed = profile.alerts.sound and (not matched or matched.sound) and (contact.class ~= nil or watched == true)
    decision.sound = soundAllowed and profile.alerts.sounds[kind] ~= "none"
    decision.waveSound = soundAllowed and profile.alerts.sounds.wave ~= "none"
        and decision.priority < 70 and (kind == "sighting" or kind == "returning")
    if not decision.sound and not decision.banner and not decision.waveSound then return nil, "outputs_disabled" end
    return decision
end
