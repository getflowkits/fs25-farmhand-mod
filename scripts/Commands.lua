-- FarmHand Telemetry :: Commands
--
-- Executes a command from the plugin against the game, WITHOUT keystrokes, so it
-- is immune to the user's keybindings. Two mechanisms, verified 21 Jul 2026:
--   1. DIRECT function call on the controlled vehicle (startMotor, setCruiseControlMaxSpeed, ...)
--   2. Named INPUTACTION raised via the vehicle's registered action event (LOWER_IMPLEMENT, TOGGLE_AI, ...)
--
-- Direct is preferred where a function exists (exact state, e.g. cruise = exactly 15).
-- Named actions cover the rest and run the game's own bound callback regardless of key.
--
-- A command is { name = "cruiseSet", value = 15 }. The name maps to a handler here.

FarmHandCommands = {}

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[FarmHand] CMD " .. (ok and msg or tostring(fmt)))
end

local dumpedStructure = {}
local dumpedActions = {}

--- When a named action can't be found on the vehicle, dump EVERY action name the
--- vehicle actually has registered. Ground truth for the real InputAction names
--- (LOWER_IMPLEMENT vs IMPLEMENT_LOWER, etc.) instead of guessing.
---
--- Reads the name straight off each event entry (entry.actionName): FS25's
--- InputAction resolves names through a metatable, so pairs(InputAction) yields
--- nothing and reversing it would report zero. Dumps once PER missing name, so
--- the list is captured at the moment that specific action is pressed.
-- Resolve an actionEvents entry to the input action NAME it represents.
-- Shared by the dump and by raiseActionOn: they used to resolve differently,
-- which is how an action could be listed as registered and still not be found.
local function entryActionName(entry)
    local n = nil
    if type(entry) == "table" then
        n = entry.actionName
        if n == nil and g_inputBinding ~= nil and g_inputBinding.events ~= nil then
            local ev = g_inputBinding.events[entry.actionEventId or entry[1]]
            if type(ev) == "table" then n = ev.actionName end
        end
    elseif (type(entry) == "string" or type(entry) == "number")
        and g_inputBinding ~= nil and g_inputBinding.events ~= nil then
        local ev = g_inputBinding.events[entry]
        if type(ev) == "table" then n = ev.actionName end
    end
    return n
end

--- The human-readable text FS itself shows for an action event, if any.
---
--- Same shape as entryActionName above, reading contextDisplayText instead of
--- actionName. That is the string the game puts in its own F1 help bar, so where
--- it is filled in it is exactly what the player already reads in game.
---
--- DIAGNOSTIC ONLY for now (3 Sep 2026): the question is whether FS populates it
--- for IMPLEMENT_EXTRA / EXTRA2 / EXTRA3, whose deck keys are stuck reading
--- "Function 1/2/3" because what they do is entirely machine-defined. Registered
--- is not the same as populated, and this whole plugin has been bitten twice
--- this week by assuming an API answers - so it gets dumped and READ before
--- anything is built on it.
local function entryDisplayText(entry)
    local t = nil
    if type(entry) == "table" then
        t = entry.contextDisplayText
        if t == nil and g_inputBinding ~= nil and g_inputBinding.events ~= nil then
            local ev = g_inputBinding.events[entry.actionEventId or entry[1]]
            if type(ev) == "table" then t = ev.contextDisplayText end
        end
    elseif (type(entry) == "string" or type(entry) == "number")
        and g_inputBinding ~= nil and g_inputBinding.events ~= nil then
        local ev = g_inputBinding.events[entry]
        if type(ev) == "table" then t = ev.contextDisplayText end
    end
    if type(t) ~= "string" or t == "" then return nil end
    return t
end

--- JSON-escape a string. Local rather than borrowed from Collectors: this is
--- localised GAME text on a machine that may be modded, so it can contain a
--- quote or a backslash, and one unescaped character corrupts the whole frame
--- for every key on the deck. Cross-file load order is not worth risking for it.
local function jsonEsc(str)
    str = tostring(str)
    str = str:gsub("%\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " "):gsub("\r", "")
    return str
end

local dumpedDisplayText = {}

--- Log actionName -> contextDisplayText once per distinct pair, for the actions
--- whose deck label is generic. Once per pair, so driving around does not flood
--- the log the way a per-frame dump would.
local function noteDisplayText(name, text)
    local key = tostring(name) .. "=" .. tostring(text)
    if dumpedDisplayText[key] then return end
    dumpedDisplayText[key] = true
    log("LABEL %s -> %s", tostring(name), text == nil and "(none)" or ('"' .. text .. '"'))
end

local function dumpRegisteredActions(vehicle, missingName)
    if dumpedActions[missingName] then return end
    dumpedActions[missingName] = true
    local names, seen = {}, {}
    pcall(function()
        for specName, spec in pairs(vehicle) do
            if type(specName) == "string" and specName:sub(1, 5) == "spec_" and type(spec) == "table" then
                local ae = spec.actionEvents
                if type(ae) == "table" then
                    for id, entry in pairs(ae) do
                        local n = nil
                        if type(entry) == "table" then
                            n = entry.actionName
                            -- indirect form: entry points into g_inputBinding.events
                            if n == nil and g_inputBinding ~= nil and g_inputBinding.events ~= nil then
                                local ev = g_inputBinding.events[entry.actionEventId or entry[1]]
                                if type(ev) == "table" then n = ev.actionName end
                            end
                        elseif (type(entry) == "string" or type(entry) == "number")
                            and g_inputBinding ~= nil and g_inputBinding.events ~= nil then
                            local ev = g_inputBinding.events[entry]
                            if type(ev) == "table" then n = ev.actionName end
                        end
                        n = n or ("id#" .. tostring(id))
                        if not seen[n] then seen[n] = true; names[#names + 1] = n end
                    end
                end
            end
        end
    end)
    table.sort(names)
    log("ACTIONS missing '%s' -- vehicle has %d registered: %s", tostring(missingName), #names, table.concat(names, ", "))
end

--- Dump the actual shape of one action-event entry, once, so we stop guessing.
-- Keyed by ACTION NAME. It used to be one global boolean, so the first action
-- to reach it printed and every later one stayed invisible - which is why cut
-- length's own entry shape was never once logged across four attempts to fix it
-- (3 Aug).
local function dumpActionEventStructure(entry, eventId, resolved, actionName)
    local key = actionName or "?"
    if dumpedStructure[key] then return end
    dumpedStructure[key] = true
    log("STRUCT for %s", key)
    log("STRUCT entry type=%s value=%s", type(entry), tostring(entry))
    if type(entry) == "table" then
        local ek = {}
        for k, v in pairs(entry) do ek[#ek+1] = string.format("%s:%s", tostring(k), type(v)) end
        log("STRUCT entry keys: %s", table.concat(ek, ", "))
    end
    if type(resolved) == "table" then
        local keys = {}
        for k, v in pairs(resolved) do keys[#keys+1] = string.format("%s:%s", tostring(k), type(v)) end
        log("STRUCT resolved-event keys: %s", table.concat(keys, ", "))
    end
    log("STRUCT g_inputBinding.events present=%s  resolved=%s",
        tostring(g_inputBinding ~= nil and g_inputBinding.events ~= nil), type(resolved))
end

--- Last resort: fire straight from the game's own dispatch table.
--
-- spec.actionEvents entries come in several shapes and a Volvo EC250DL uses one
-- we could not reach a callback through, even after finding the right entry by
-- name (in-game, 3 Aug). g_inputBinding.events is the table the game ITSELF walks
-- when a key is pressed, so an event living there is by definition callable.
local function raiseFromInputBinding(actionName, targetObj, tapRelease)
    local raised = false
    pcall(function()
        if g_inputBinding == nil or g_inputBinding.events == nil then return end
        -- Fire it on ITS OWN target, whatever that is.
        --
        -- The first version required ev.targetObject to be the vehicle, and that
        -- is exactly why cut length still did nothing on a Volvo EC250DL: the
        -- action belongs to the HARVESTER HEAD, not the machine carrying it, so
        -- the one callable event was skipped every time (in-game, 3 Aug).
        --
        -- An event sitting in g_inputBinding.events with a callback is one the
        -- game would run for a key press right now. Its own targetObject is by
        -- definition the right receiver.
        local matches = 0
        for _, ev in pairs(g_inputBinding.events) do
            if type(ev) == "table" and ev.actionName == actionName then
                matches = matches + 1
                if type(ev.callback) == "function" then
                    local target = ev.targetObject or targetObj
                    ev.callback(target, actionName, 1, nil, false)
                    if tapRelease then ev.callback(target, actionName, 0, nil, false) end
                    log("CMD raised '%s' via g_inputBinding.events", actionName)
                    raised = true
                    return
                end
            end
        end
        if matches > 0 then
            log("CMD '%s': %d event(s) in g_inputBinding.events but none callable", actionName, matches)
        end
    end)
    return raised
end

-- Raise a named InputAction on the vehicle OR one of its attached implements.
--- Rebind-proof: invokes the same callback the game would run for that action,
--- whatever key is bound to it. The action can be registered on the IMPLEMENT
--- (e.g. a trailer's TOGGLE_TIPSTATE) rather than the tractor, so search both.
---
--- FS25 stores spec.actionEvents[actionId] as an event ID (string), and the real
--- event table (with .callback / .targetObject) lives in g_inputBinding.events.
---
--- Digital actions differ in how they treat the release, VERIFIED in-game:
---   - Simple toggles (TOGGLE_WORK_LIGHT_*, LOWER_*, beacon, fold): the callback
---     flips state on EVERY call, so press+release = two flips = nothing. These
---     need press ONLY -> one call, one toggle.
---   - Tap/hold (TOGGLE_AI): must send press(1)+release(0) or the held input trips
---     the hold branch and opens the AI menu. Hence the tapRelease flag.
---   - One-shot (ATTACH/DETACH/HONK): act on press, ignore release; press-only fine.

--- Fire the action on ONE object if registered there. Returns raised, found.
-- Every callbackState registered under this action name, once per name.
-- Direction-carrying actions register the same name twice; this says so.
local dumpedStates = {}
local function dumpActionStates(obj, actionName)
    if dumpedStates[actionName] then return end
    dumpedStates[actionName] = true
    local found = {}
    pcall(function()
        for specName, spec in pairs(obj) do
            if type(specName) == "string" and specName:sub(1, 5) == "spec_" and type(spec) == "table" then
                for _, entry in pairs(spec.actionEvents or {}) do
                    local ok, n = pcall(entryActionName, entry)
                    if ok and n == actionName then
                        local ev = nil
                        if type(entry) == "table" and g_inputBinding ~= nil and g_inputBinding.events ~= nil then
                            ev = g_inputBinding.events[entry.actionEventId or entry[1]]
                        end
                        if type(ev) == "table" then
                            found[#found + 1] = string.format("%s(state=%s)", specName, tostring(ev.callbackState))
                        end
                    end
                end
            end
        end
    end)
    log("CMD '%s' registered %d time(s): %s", actionName, #found, table.concat(found, ", "))
end

local function raiseActionOn(obj, actionName, actionId, tapRelease, stateOverride)
    local raised, found = false, false
    pcall(function()
        for specName, spec in pairs(obj) do
            if type(specName) == "string" and specName:sub(1, 5) == "spec_" and type(spec) == "table" then
                local ae = spec.actionEvents
                -- The table is keyed by the action id MOST of the time, but not
                -- always: a Volvo EC250DL registers TOGGLE_CUT_LENGTH_BACK under
                -- a key that is not InputAction.TOGGLE_CUT_LENGTH_BACK, so the
                -- direct lookup missed while the diagnostic dump - which scans
                -- and resolves NAMES - listed it plainly (in-game, 3 Aug: "cut
                -- length doesn't appear to do anything").
                --
                -- So: try the id, then fall back to finding the entry whose
                -- resolved name matches. Name is the thing we actually mean.
                local entry = nil
                if type(ae) == "table" then
                    entry = ae[actionId]
                    if entry == nil then
                        for _, candidate in pairs(ae) do
                            -- per-candidate pcall: the scan used to sit inside ONE
                            -- pcall, so a single odd entry aborted the search for
                            -- every remaining spec, silently.
                            local okName, name = pcall(entryActionName, candidate)
                            if okName and name == actionName then
                                entry = candidate
                                break
                            end
                        end
                    end
                end
                if entry ~= nil then
                    found = true
                    log("CMD '%s': entry located in %s", actionName, specName)
                    local event = nil
                    if type(entry) == "table" then
                        if type(entry.callback) == "function" then
                            event = entry
                        elseif entry.actionEventId ~= nil and g_inputBinding.events ~= nil then
                            event = g_inputBinding.events[entry.actionEventId]
                        elseif entry[1] ~= nil and g_inputBinding.events ~= nil then
                            event = g_inputBinding.events[entry[1]]
                        end
                    elseif (type(entry) == "string" or type(entry) == "number") and g_inputBinding.events ~= nil then
                        event = g_inputBinding.events[entry]
                    end
                    dumpActionEventStructure(entry, entry, event, actionName)
                    if type(event) == "table" and type(event.callback) == "function" then
                        local target = event.targetObject or obj
                        -- callback(self, actionName, inputValue, callbackState, isAnalog)
                        --
                        -- callbackState is NOT optional. The event carries one
                        -- (TOGGLE_CUT_LENGTH_BACK's is how the game tells the
                        -- single handler which DIRECTION to step), and passing
                        -- nil made the handler throw. The throw then vanished
                        -- into the pcall wrapping this whole loop, so a callback
                        -- that errored looked exactly like an action that was
                        -- never found - four rounds of chasing the wrong thing
                        -- (in-game, 3 Aug).
                        -- One action, two directions. FS25 has no forward
                        -- counterpart to TOGGLE_CUT_LENGTH_BACK - the game's own
                        -- key steps UP while ours stepped DOWN - so direction has
                        -- to live in callbackState, and the machine may register
                        -- the same action name more than once. List what exists
                        -- before choosing (in-game, 3 Aug).
                        dumpActionStates(obj, actionName)
                        local state = stateOverride
                        if state == nil then state = event.callbackState end
                        local okCall, err = pcall(function()
                            event.callback(target, actionName, 1, state, false)
                            if tapRelease then event.callback(target, actionName, 0, state, false) end
                        end)
                        if okCall then
                            raised = true
                            return
                        end
                        -- Never silent: a handler that rejects our arguments is a
                        -- different problem from an action we cannot find.
                        log("CMD '%s' callback ERRORED: %s", actionName, tostring(err))
                    end
                end
            end
        end
    end)
    return raised, found
end

local function raiseAction(vehicle, actionName, tapRelease, stateOverride)
    if vehicle == nil or g_inputBinding == nil or InputAction == nil then return false end

    -- vehicle first, then each attached implement (the action can live on the
    -- implement -- e.g. a trailer's tip action -- not the tractor root).
    local objs = { vehicle }
    pcall(function()
        if vehicle.getAttachedImplements then
            for _, imp in ipairs(vehicle:getAttachedImplements()) do
                if type(imp.object) == "table" then objs[#objs + 1] = imp.object end
            end
        end
    end)

    -- actionId may be nil (a name InputAction does not know); raiseActionOn now
    -- falls back to matching by NAME, so run it regardless.
    local actionId = InputAction[actionName]
    for _, obj in ipairs(objs) do
        if raiseActionOn(obj, actionName, actionId, tapRelease, stateOverride) then return true end
    end
    -- Nothing callable in the specs: try the game's own dispatch table before
    -- giving up.
    if raiseFromInputBinding(actionName, vehicle, tapRelease) then return true end

    -- Not fired (unknown name OR not registered on any object): dump each
    -- candidate's real registered action names so we can see the true name and
    -- which object owns it. Once per (name, object-index).
    for i, obj in ipairs(objs) do
        dumpRegisteredActions(obj, actionName .. "@" .. i)
    end
    return false
end

-- ------------------------------------------------------------------ axes
--
-- Loader and crane joints are ANALOG inputs, not toggles. VERIFIED 22 Jul from
-- an in-game dump: every driven joint in spec_cylindered.movingTools carries its
-- own axis action name (AXIS_FRONTLOADER_ARM, AXIS_CRANE_ARM2, ...), and those
-- are registered action events like any other.
--
-- So we drive the game's OWN axis callback rather than writing joint angles
-- directly. Writing curRot would be instant and precise, but a loader has slave
-- joints that follow the driven one (the Schäffer's tools 2 and 4 have no axis
-- of their own), plus sound and network sync hang off the normal path. Feeding
-- the real input keeps all of that working for free.
--
-- Movement is time-based: the engine integrates the axis value each frame. A
-- dial tick therefore becomes a short HOLD, and spinning the dial holds longer,
-- which is what makes a dial feel proportional instead of steppy.

local activePulses = {}
local loggedSlots = {}   -- slot -> already reported, so a dial does not spam the log

--- Joint slots, resolved to whichever axis action the machine actually
--- registers.
---
--- VERIFIED 22 Jul, from a registered-action dump on a Schäffer 23E wheel
--- loader: its moving tools DECLARE AXIS_FRONTLOADER_ARM / _TOOL, but the
--- actions it registers are AXIS_CRANE_ARM, ARM2, ARM3, TOOL, TOOL2. The
--- declared name in the vehicle XML is not the bound input action, so driving
--- the declared name hits nothing.
---
--- Hence slots rather than names: a profile says "arm" and works on a wheel
--- loader, a tractor with a front loader, and an excavator alike. Shipping raw
--- axis names would mean a profile that only fits the machine it was built on.
--- Each slot lists the LOADER name before the CRANE one so a machine that
--- registers both resolves to its own family first. Widened 30 Jul from the
--- game's own binding text (l10n input_AXIS_* keys): the old table reached only
--- AXIS_CRANE_ARM2/3 and CRANE_TOOL2/3, so a telehandler's extend
--- (FRONTLOADER_ARM2), a loader's grab (FRONTLOADER_TOOL2) and a knuckle
--- crane's telescope (CRANE_ARM4) could not be driven at all.
local AXIS_SLOTS = {
    arm   = { names = { "AXIS_FRONTLOADER_ARM", "AXIS_CRANE_ARM" },     kind = "ARM",  ord = 1 },
    arm2  = { names = { "AXIS_FRONTLOADER_ARM2", "AXIS_CRANE_ARM2" },   kind = "ARM",  ord = 2 },
    arm3  = { names = { "AXIS_CRANE_ARM3" },                            kind = "ARM",  ord = 3 },
    arm4  = { names = { "AXIS_CRANE_ARM4" },                            kind = "ARM",  ord = 4 },
    tool  = { names = { "AXIS_FRONTLOADER_TOOL", "AXIS_CRANE_TOOL" },   kind = "TOOL", ord = 1 },
    tool2 = { names = { "AXIS_FRONTLOADER_TOOL2", "AXIS_CRANE_TOOL2" }, kind = "TOOL", ord = 2 },
    tool3 = { names = { "AXIS_FRONTLOADER_TOOL3", "AXIS_CRANE_TOOL3" }, kind = "TOOL", ord = 3 },
}

--- Slot order for reporting, so the plugin sees arms then tools in machine order.
local AXIS_SLOT_ORDER = { "arm", "arm2", "arm3", "arm4", "tool", "tool2", "tool3" }

--- Turn one actionEvents entry into the live event table (with .callback).
local function resolveEvent(entry)
    local ev = nil
    pcall(function()
        if type(entry) == "table" then
            if type(entry.callback) == "function" then
                ev = entry
            elseif g_inputBinding ~= nil and g_inputBinding.events ~= nil then
                ev = g_inputBinding.events[entry.actionEventId or entry[1]]
            end
        elseif g_inputBinding ~= nil and g_inputBinding.events ~= nil then
            ev = g_inputBinding.events[entry]
        end
    end)
    return ev
end

--- Resolve a named action's live event table on one object.
---
--- Looks up by action id FIRST, then falls back to matching each registered
--- event's own actionName. The fallback exists because keying is not guaranteed:
--- an axis registered by Cylindered need not sit at actionEvents[actionId], and
--- a lookup that only tries one shape fails silently on the other.
local function findEvent(obj, actionId, actionName)
    local found = nil
    pcall(function()
        for specName, spec in pairs(obj) do
            if type(specName) == "string" and specName:sub(1, 5) == "spec_" and type(spec) == "table" then
                local ae = spec.actionEvents
                if type(ae) == "table" and actionId ~= nil and ae[actionId] ~= nil then
                    found = resolveEvent(ae[actionId])
                    if found ~= nil then return end
                end
            end
        end
    end)
    if found ~= nil then return found end

    -- Fallback: scan every registered event and match on its NAME.
    pcall(function()
        for specName, spec in pairs(obj) do
            if type(specName) == "string" and specName:sub(1, 5) == "spec_" and type(spec) == "table" then
                local ae = spec.actionEvents
                if type(ae) == "table" then
                    for _, entry in pairs(ae) do
                        local ev = resolveEvent(entry)
                        local n = nil
                        if type(entry) == "table" then n = entry.actionName end
                        if n == nil and type(ev) == "table" then n = ev.actionName end
                        if n == actionName and ev ~= nil then
                            found = ev
                            return
                        end
                    end
                end
            end
        end
    end)
    return found
end

--- Which joint slots the machine in the cab ACTUALLY has, and the axis action
--- each one resolved to.
---
--- The plugin needs this for two reasons. A profile is one layout across every
--- machine, so an ARM 3 dial lands on plenty of machines that have no third
--- joint - without this it moved nothing and said nothing, which reads as a
--- broken dial. And because a slot's meaning is the MACHINE's business (slot
--- `arm` is a crane's slew but a loader's lift), the resolved action name is the
--- only honest way to label the dial.
---
--- Cached per vehicle: findEvent walks every spec_ table, which is fine on a
--- vehicle change and wasteful at 4 Hz.
local jointCacheVehicle = nil
local jointCacheJson = "[]"


function FarmHandCommands.jointsJson(v)
    if v == nil then return "[]" end
    if v == jointCacheVehicle then return jointCacheJson end
    local out = {}
    pcall(function()
        for _, slotName in ipairs(AXIS_SLOT_ORDER) do
            local slot = AXIS_SLOTS[slotName]
            for _, actionName in ipairs(slot.names) do
                local id = nil
                pcall(function() id = InputAction[actionName] end)
                if findEvent(v, id, actionName) ~= nil then
                    out[#out + 1] = string.format('{"slot":"%s","axis":"%s"}', slotName, actionName)
                    break -- first family that answers owns the slot
                end
            end
        end
    end)
    jointCacheVehicle = v
    jointCacheJson = "[" .. table.concat(out, ",") .. "]"
    return jointCacheJson
end

local dumpedAxisEvent = false

--- Feed one analog sample to an axis.
---
--- isAnalog = true matters: the digital path treats any non-zero as a button.
---
--- callbackState matters MORE. FS stores it on the event at registration and
--- hands it back to the callback, and Cylindered uses it to know WHICH moving
--- tool an axis drives. Passing nil (as the digital actions do harmlessly) left
--- the handler with no tool to move: the callback ran, reported success, and
--- nothing happened. Take it from the event rather than inventing one.
local function fireAxis(obj, event, actionName, value)
    local ok = false
    pcall(function()
        if type(event) ~= "table" or type(event.callback) ~= "function" then return end
        local target = event.targetObject or obj

        if not dumpedAxisEvent then
            dumpedAxisEvent = true
            local keys = {}
            for k, val in pairs(event) do keys[#keys + 1] = string.format("%s:%s", tostring(k), type(val)) end
            table.sort(keys)
            log("AXIS EVENT '%s' fields: %s", actionName, table.concat(keys, ", "))
            log("AXIS EVENT callbackState=%s targetObject=%s",
                tostring(event.callbackState), tostring(event.targetObject ~= nil))
        end

        -- callback(self, actionName, inputValue, callbackState, isAnalog, isMouse)
        event.callback(target, actionName, value, event.callbackState, true, false)
        ok = true
    end)
    return ok
end

--- Find the moving tool a slot refers to, by the axis name the TOOL declares.
---
--- This is the second route to the same joint, and the more dependable one: the
--- declared name lives on the tool itself, so it does not depend on how the
--- machine happened to register its inputs (a wheel loader declares
--- FRONTLOADER and registers CRANE).
--- @param names exact axis names to try first
--- @param kind  "ARM" or "TOOL" — the joint family
--- @param ord   which joint of that family (1 = first)
local function findMovingTool(obj, names, kind, ord)
    local hit = nil
    pcall(function()
        local sc = obj.spec_cylindered
        if sc == nil or type(sc.movingTools) ~= "table" then return end

        -- 1. exact match on the axis the tool declares
        for _, t in ipairs(sc.movingTools) do
            local declared = tostring(t.axisActionIndex or t.axis or "")
            for _, n in ipairs(names) do
                if declared == n then hit = t return end
            end
        end

        -- 2. STRUCTURAL fallback: match on the family in the name and the order
        --    the joints are declared. FS names axes <PREFIX>_ARM / _TOOL, and
        --    only the prefix varies by machine (FRONTLOADER, CRANE, or whatever
        --    a mod invents). Matching the suffix and position means an unknown
        --    machine still works instead of failing silently, which is how the
        --    exact-name approach failed on the very first loader we tried.
        if kind == nil then return end
        local lowest, lowestN = nil, nil
        for _, t in ipairs(sc.movingTools) do
            local declared = tostring(t.axisActionIndex or t.axis or ""):upper()
            -- The ordinal is IN the name (ARM, ARM2, ARM3), so read it rather
            -- than counting declaration order: a machine that declares ARM2 but
            -- no ARM would otherwise hand its second arm to the first slot.
            local tail = declared:match(kind .. "(%d*)$")
            if tail ~= nil then
                local n = tonumber(tail) or 1
                if n == ord then hit = t return end
                if lowestN == nil or n < lowestN then lowest, lowestN = t, n end
            end
        end

        -- VERIFIED 22 Jul on a Volvo EC250DL: its bucket is TOOL2 and it has no
        -- TOOL1 at all. A shipped profile cannot know that per machine, so the
        -- FIRST slot of a family falls back to the lowest joint that exists.
        -- Only slot 1 does this: letting slot 2 fall back as well would point
        -- two dials at the same joint, which is worse than one dead dial.
        if ord == 1 then hit = lowest end
    end)
    return hit
end

local dumpedMove = false

--- Apply an input value to a moving tool the way the engine's own update does:
--- `move` is what updateMovingTools integrates each frame.
local function driveTool(obj, tool, value)
    local ok = false
    pcall(function()
        -- Respect the tool's invertAxis flag. The game's INPUT system applies it
        -- so that "rotate right" always goes right; we set `move` directly, which
        -- is downstream of that, so without this the dial is backwards on every
        -- joint the game marks inverted (typically the horizontal slew of an
        -- excavator or crane). VERIFIED 23 Jul: EC250DL arm rotation was reversed.
        if tool.invertAxis == true then value = -value end
        tool.move = value
        if not dumpedMove then
            dumpedMove = true
            log("MOVE tool set move=%.2f invertAxis=%s (rotMin=%s rotMax=%s)",
                value, tostring(tool.invertAxis), tostring(tool.rotMin), tostring(tool.rotMax))
        end
        -- Keep the visual/network side in step; both are guarded because a
        -- machine without the trans/rot pair may not define every helper.
        if Cylindered ~= nil and type(Cylindered.setDirty) == "function" then
            Cylindered.setDirty(obj, tool)
        end
        if type(obj.raiseDirtyFlags) == "function" and obj.spec_cylindered ~= nil then
            obj:raiseDirtyFlags(obj.spec_cylindered.cylinderedDirtyFlag)
        end
        ok = true
    end)
    return ok
end

--- Called every frame from the telemetry update so a pulse can span frames.
function FarmHandCommands.updatePulses(dtMs)
    for i = #activePulses, 1, -1 do
        local p = activePulses[i]
        p.remain = p.remain - (dtMs or 0)
        local value = p.remain > 0 and p.value or 0

        -- Drive the tool directly when we found one; otherwise fall back to the
        -- registered input callback.
        if p.tool ~= nil then
            driveTool(p.obj, p.tool, value)
        else
            fireAxis(p.obj, p.event, p.action, value)
        end

        -- Zero on the way out, or the joint keeps travelling forever.
        if p.remain <= 0 then table.remove(activePulses, i) end
    end
end

--- Select the first camera that is inside (or outside) the cab.
--- Falls back to cycling when a vehicle has no camera of that kind, so the key
--- still does something rather than dying silently.
local function setCameraWhere(vehicle, wantInside)
    local ok = false
    pcall(function()
        local se = vehicle.spec_enterable
        local cams = se ~= nil and se.cameras or nil
        if cams == nil or #cams == 0 then return end
        for i, cam in ipairs(cams) do
            if (cam.isInside == true) == wantInside then
                if type(vehicle.setActiveCameraIndex) == "function" then
                    vehicle:setActiveCameraIndex(i)
                    ok = true
                end
                return
            end
        end
    end)
    return ok
end

--- Raise an action that is NOT owned by a vehicle.
---
--- On-foot and session actions (build mode, hand tools, time scale, pause) are
--- registered globally rather than on a vehicle spec, so the vehicle-first
--- search cannot see them. Match by name against the live event table.
---
--- VERIFIED 22 Jul from a full action dump: the player's own actions exist only
--- while out of the cab, which is why this looks at what is registered NOW
--- rather than at a fixed list.
-- Say what the global table ACTUALLY holds when a lookup misses.
--
-- raiseGlobal returning false is indistinguishable from the action not existing,
-- the callback being absent, and ev.actionName simply not being the field that
-- carries the name - three very different problems, one silent false (in-game,
-- 3 Aug: "on drive page, the 'prev' button does nothing", while the mod logged
-- only "no direct fn or action"). The vehicle-side dump has earned its keep
-- twice today; this is the same idea for the global table.
--- The action name behind a global input event, however it is stored.
--
-- ONE resolver, shared by the lookup and the dump, because when they disagreed
-- the dump was right and the lookup silently found nothing: SWITCH_VEHICLE and
-- SWITCH_VEHICLE_BACK were both in g_inputBinding.events, both with callbacks,
-- while raiseGlobal - which trusted ev.actionName alone - reported them missing
-- and Prev/Next did nothing (in-game, 3 Aug). ev.actionName is not the field.
--
-- This is the second time today a lookup and its own diagnostic used different
-- name resolution and the diagnostic was the honest one; entryActionName exists
-- for exactly this reason on the vehicle side.
local function globalEventName(ev)
    if type(ev) ~= "table" then return nil end
    if type(ev.actionName) == "string" then return ev.actionName end
    local idx = ev.actionIndex or ev.actionEventId
    if idx == nil or InputAction == nil then return nil end
    for k, v in pairs(InputAction) do
        if v == idx and type(k) == "string" then return k end
    end
    return nil
end

local dumpedGlobals = {}
local function dumpGlobalActions(missingName)
    if dumpedGlobals[missingName] then return end
    dumpedGlobals[missingName] = true
    local names, n, noCallback = {}, 0, 0
    pcall(function()
        if g_inputBinding == nil or g_inputBinding.events == nil then return end
        for _, ev in pairs(g_inputBinding.events) do
            if type(ev) == "table" then
                n = n + 1
                local nm = globalEventName(ev)
                if type(nm) == "string" then
                    if type(ev.callback) ~= "function" then
                        noCallback = noCallback + 1
                        nm = nm .. "(no cb)"
                    end
                    names[#names + 1] = nm
                end
            end
        end
    end)
    table.sort(names)
    log("GLOBAL missing '%s' -- %d event(s), %d named, %d without a callback: %s",
        missingName, n, #names, noCallback, table.concat(names, ", "))
end

local function raiseGlobal(actionName, tapRelease, inputValue)
    local found, raised = false, false
    pcall(function()
        if g_inputBinding == nil or g_inputBinding.events == nil then return end
        for _, ev in pairs(g_inputBinding.events) do
            if type(ev) == "table" and globalEventName(ev) == actionName and type(ev.callback) == "function" then
                found = true
                -- callbackState, NOT nil. The vehicle side learned this the hard
                -- way on cut length: FS handlers read the state as their argument
                -- (direction, index, which of a pair fired), and a nil there makes
                -- a handler either no-op or error. Passing what the event was
                -- REGISTERED with is the only defensible default.
                local st = ev.callbackState
                local target = ev.targetObject
                -- INNER pcall so a throwing callback is not mistaken for a missing
                -- action. Without it `raised` stayed false and the outer pcall ate
                -- the error, so "found it and it errored" printed the same
                -- "missing" dump as "never found it" - and the dump listed the
                -- action plainly, which is how prev/next stayed broken through two
                -- rounds of fixes (in-game, 3 Aug).
                -- inputValue is the PRESS/RELEASE half of the input, not a
                -- direction: FS hold-actions run while it is 1 and stop when it
                -- goes 0. Defaults to 1 so every existing caller is unchanged.
                local v = inputValue or 1
                local ok, err = pcall(function()
                    if target ~= nil then
                        ev.callback(target, actionName, v, st, false)
                        if tapRelease then ev.callback(target, actionName, 0, st, false) end
                    else
                        ev.callback(actionName, v, st, false)
                    end
                end)
                if ok then raised = true return end
                log("GLOBAL '%s' callback ERRORED (state=%s, target=%s): %s",
                    actionName, tostring(st), tostring(target ~= nil), tostring(err))
            end
        end
    end)
    if not raised then
        if found then
            log("GLOBAL '%s' was FOUND but every callback failed - see the errors above", actionName)
        else
            dumpGlobalActions(actionName)
        end
    end
    return raised
end

--- Try the vehicle first, then the global table. Covers actions that live in
--- either place depending on whether the player is in a cab.
local function raiseAny(vehicle, actionName, tapRelease, inputValue)
    -- A non-default inputValue only makes sense for the global path: the vehicle
    -- raiser has no hold-actions among our commands.
    if inputValue == nil and vehicle ~= nil and raiseAction(vehicle, actionName, tapRelease) then return true end
    return raiseGlobal(actionName, tapRelease, inputValue)
end

--- FS25's time-scale steps, matching the ones the game itself cycles through.
local TIME_STEPS = { 1, 2, 5, 15, 30, 60, 120 }

--- Step the time scale.
---
--- VERIFIED 22 Jul: INCREASE_TIMESCALE is registered as an input action but its
--- event carries NO callback (the game handles it internally), so raising it by
--- name does nothing at all. Set the value directly instead.
---
--- Reports which path worked the first time, because the setter's shape differs
--- between FS versions and a silent no-op here looks identical to a dead key.
local timeScaleReported = false

--- Read the current time scale, or nil.
local function readTimeScale()
    local cur = nil
    pcall(function() cur = tonumber(g_currentMission.missionInfo.timeScale) end)
    if cur == nil then pcall(function() cur = tonumber(g_currentMission.timeScale) end) end
    return cur
end

--- Nearest TIME_STEPS index to a value, so a scale another mod set cannot strand us.
local function nearestTimeStep(cur)
    local idx = 1
    for i, v in ipairs(TIME_STEPS) do
        if math.abs(v - cur) < math.abs(TIME_STEPS[idx] - cur) then idx = i end
    end
    return idx
end

--- Apply a time scale. ONE setter, shared by the step keys and the cycle key:
--- two copies of this would be two things to keep in step, and today has been a
--- long lesson in what happens when a duplicate drifts from its original.
local function setTimeScaleTo(target)
    local cur = readTimeScale()
    if cur ~= nil and target == cur then return true end
    local how = nil
    pcall(function()
        if type(g_currentMission.setTimeScale) == "function" then
            g_currentMission:setTimeScale(target)
            how = "setTimeScale"
        end
    end)
    if how == nil then
        pcall(function()
            g_currentMission.missionInfo.timeScale = target
            how = "missionInfo"
        end)
    end
    -- Confirm it actually took: writing a field the game ignores is the failure
    -- mode this whole command exists to avoid.
    local now = nil
    pcall(function() now = tonumber(g_currentMission.missionInfo.timeScale) end)
    if not timeScaleReported then
        timeScaleReported = true
        log("time scale: %s -> %s via %s (now reads %s)",
            tostring(cur), tostring(target), tostring(how), tostring(now))
    end
    return how ~= nil
end

--- Cycle the time scale, wrapping at the top.
--
-- This is what the Pause key became. Pause could not work from inside the mod at
-- all: pausing halts the mission update, so the mod stops ticking and the pipe
-- closes - the second press is never HEARD, and telemetry dies for the whole deck
-- until you unpause in-game (verified 3 Aug, the log goes silent and then
-- "stopping after 338 frames"). In-game note: "if it cant be resolved, im okay with
-- removing it and replacing it with a time-speed cycle that work just like the
-- dial for devices with no dials."
--
-- One key, one direction, wrapping - the press-only equivalent of the time dial,
-- for the decks that have no dials.
local function cycleTimeScale()
    local cur = readTimeScale()
    if cur == nil then
        log("time scale: could not read the current value")
        return false
    end
    -- wrap, rather than clamp: a single key must be able to get back to 1x
    local nextIdx = nearestTimeStep(cur) + 1
    if nextIdx > #TIME_STEPS then nextIdx = 1 end
    return setTimeScaleTo(TIME_STEPS[nextIdx])
end

local function stepTimeScale(dir)
    local cur = readTimeScale()
    if cur == nil then
        log("time scale: could not read the current value")
        return false
    end
    -- the step keys CLAMP; only the single cycle key wraps
    local idx = nearestTimeStep(cur)
    local nextIdx = math.max(1, math.min(#TIME_STEPS, idx + dir))
    return setTimeScaleTo(TIME_STEPS[nextIdx])
end

local function getControlled()
    local v = nil
    pcall(function() v = g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil end)
    if v == nil then pcall(function() v = g_currentMission.controlledVehicle end) end
    return v
end

--- The controlled vehicle plus its directly-attached implements. Implement-
--- mediated actions (turn-on, pipe, discharge, fold) live on one of these, not
--- always the vehicle itself -- the lesson from lower/raise.
local function candidates(vehicle)
    local list = { vehicle }
    pcall(function()
        if vehicle.getAttachedImplements then
            for _, imp in ipairs(vehicle:getAttachedImplements()) do
                if type(imp.object) == "table" then list[#list + 1] = imp.object end
            end
        end
    end)
    return list
end


--- Open the in-game menu on a SPECIFIC page, so a telemetry key can drill into
--- the screen behind it (season -> crop calendar, herd -> animals).
--- VERIFIED 21 Jul: FS25 has no g_currentMission.inGameMenu. The menu is
--- g_gui.guis["InGameMenu"]; its `target` holds pageCalendar / pageAnimals /
--- pageContracts / pageProduction / pageMapOverview / pageStatistics, and
--- `goToPage` switches. Show the GUI first, then navigate, or the page resets.
--- (There is no pagePrices — prices are not their own screen.)
--- Toggling: pressing the SAME menu key again closes it, while a DIFFERENT menu
--- key switches page instead of closing. If we can't tell whether the menu is
--- open, this degrades to plain "open", which is the safe direction.
local lastMenuPage = nil

local function openMenuPage(pageField)
    local ok = false
    pcall(function()
        local gui = g_gui and g_gui.guis and g_gui.guis["InGameMenu"] or nil
        if gui == nil then return end
        local menu = gui.target
        if type(menu) ~= "table" then return end
        local page = menu[pageField]
        if page == nil then return end

        local isOpen = false
        pcall(function()
            if g_gui.currentGuiName ~= nil then
                isOpen = (g_gui.currentGuiName == "InGameMenu")
            elseif type(g_gui.getIsGuiVisible) == "function" then
                isOpen = g_gui:getIsGuiVisible()
            end
        end)

        if isOpen and lastMenuPage == pageField then
            g_gui:showGui("")   -- same key again: close
            lastMenuPage = nil
            ok = true
            return
        end

        if not isOpen then g_gui:showGui("InGameMenu") end
        if type(menu.goToPage) == "function" then menu:goToPage(page) end
        lastMenuPage = pageField
        ok = true
    end)
    return ok
end

--- Open the in-game PRICES view, optionally with a fill type preselected.
---
--- FS25 has NO pagePrices (confirmed by our 21 Jul dump AND by the FS25 script
--- source): FS22's separate Prices / Finances / Weather / Statistics pages were
--- collapsed into ONE page - pageStatistics (InGameMenuStatisticsFrame) - with
--- sub-tabs driven by a MultiTextOptionElement, `subCategoryPaging`.
--- So "open prices" = go to pageStatistics, then set that sub-tab.
---
--- The sub-tab's index lives in InGameMenuStatisticsFrame.SUB_CATEGORY, whose key
--- names are undocumented (stripped from the shipped source), so resolve it
--- defensively: the PRICES key, else any key mentioning price, else a header
--- title mentioning price. Returns nil rather than guessing an index, because a
--- wrong index silently lands the player on the wrong tab.
local function pricesSubCategory()
    local F = _G["InGameMenuStatisticsFrame"]
    if type(F) ~= "table" then return nil end
    local sub = F.SUB_CATEGORY
    if type(sub) == "table" then
        if type(sub.PRICES) == "number" then return sub.PRICES end
        for k, v in pairs(sub) do
            if type(k) == "string" and type(v) == "number" and string.find(string.upper(k), "PRICE", 1, true) then
                return v
            end
        end
    end
    if type(F.HEADER_TITLES) == "table" then
        for i, t in ipairs(F.HEADER_TITLES) do
            if type(t) == "string" and string.find(string.lower(t), "price", 1, true) then return i end
        end
    end
    return nil
end

--- Select the row for a fill type in the prices table.
--- The list is SECTIONED in FS25 (fillTypes[section][index], each entry carrying
--- name/pricePerLiter), unlike FS22's flat list.
local function selectPriceRow(page, wanted)
    if wanted == nil or wanted == "" then return false end
    local want = string.upper(wanted)
    local list = page.productList
    if type(page.fillTypes) ~= "table" or list == nil then return false end
    for s, section in ipairs(page.fillTypes) do
        if type(section) == "table" then
            for i, ft in ipairs(section) do
                local n = type(ft) == "table" and ft.name or nil
                if type(n) == "string" and string.upper(n) == want then
                    pcall(function() list:setSelectedItem(s, i) end)
                    -- the station panel only repopulates from the selection
                    -- callback, which setSelectedItem may not raise
                    pcall(function() page:onListSelectionChanged(list, s, i) end)
                    log("openPrices: selected %s at section %d row %d", n, s, i)
                    return true
                end
            end
        end
    end
    log("openPrices: fill type '%s' not in the prices table", tostring(wanted))
    return false
end

--- The crop the prices view was last opened on, so a press can tell "close me"
--- from "show me this other one".
local lastPriceFill = nil

local function openPricesPage(fillTypeName)
    local ok = false
    pcall(function()
        local gui = g_gui and g_gui.guis and g_gui.guis["InGameMenu"] or nil
        local menu = gui ~= nil and gui.target or nil
        if type(menu) ~= "table" then return end
        local page = menu.pageStatistics
        if page == nil then log("openPrices: no pageStatistics") return end

        local isOpen = false
        pcall(function()
            if g_gui.currentGuiName ~= nil then isOpen = (g_gui.currentGuiName == "InGameMenu") end
        end)
        if isOpen and lastMenuPage == "pagePrices" then
            -- Already looking at prices. Pressing on a DIFFERENT crop means "show
            -- me that one", not "close" - the user scrubbed the dial to get here.
            -- Only a press on the SAME crop is the close half of the toggle.
            local same = (fillTypeName == nil and lastPriceFill == nil)
                or (fillTypeName ~= nil and lastPriceFill ~= nil
                    and string.upper(fillTypeName) == string.upper(lastPriceFill))
            if not same then
                pcall(function() if type(page.rebuildTable) == "function" then page:rebuildTable() end end)
                selectPriceRow(page, fillTypeName)
                lastPriceFill = fillTypeName
                ok = true
                return
            end
            g_gui:showGui("")
            lastMenuPage = nil
            lastPriceFill = nil
            ok = true
            return
        end
        if not isOpen then g_gui:showGui("InGameMenu") end

        -- Set the sub-tab BEFORE the page switch: goToPage calls onFrameOpen
        -- synchronously, and the frame builds its view from the current sub-tab.
        local sub = pricesSubCategory()
        if sub ~= nil and page.subCategoryPaging ~= nil then
            pcall(function() page.subCategoryPaging:setState(sub, true) end)
        else
            log("openPrices: could not resolve the PRICES sub-tab; opening statistics as-is")
        end
        if type(menu.goToPage) == "function" then menu:goToPage(page) end
        -- and again after, in case onFrameOpen restored its own last state
        if sub ~= nil and page.subCategoryPaging ~= nil then
            pcall(function() page.subCategoryPaging:setState(sub, true) end)
        end

        pcall(function() if type(page.rebuildTable) == "function" then page:rebuildTable() end end)
        pcall(function() selectPriceRow(page, fillTypeName) end)

        lastMenuPage = "pagePrices"
        lastPriceFill = fillTypeName
        ok = true
    end)
    return ok
end

--- Open the production screen ON a specific production point.
---
--- This is GIANTS' own pattern, not a hack: ProductionPoint:openMenu() does
--- exactly `showGui("InGameMenu")` + publish(GUI_INGAME_OPEN_PRODUCTION_SCREEN,
--- self), and the menu's handler does the page switch AND the selection. So we
--- only have to resolve the name the dial is showing back to its point, using
--- the SAME enumeration the telemetry collector uses (productionChainManager ->
--- getProductionPointsForFarmId -> owningPlaceable:getName), which is why the
--- names always match.
local lastProductionName = nil

local function findProductionPoint(name)
    if name == nil or name == "" then return nil end
    local want = string.upper(name)
    local pcm = g_currentMission ~= nil and g_currentMission.productionChainManager or nil
    if pcm == nil then return nil end
    local farmId = Farmhand ~= nil and Farmhand.farmId or nil
    local points = nil
    pcall(function() points = pcm:getProductionPointsForFarmId(farmId) end)
    if points == nil then return nil end
    for _, pp in pairs(points) do
        local n = nil
        pcall(function() if pp.owningPlaceable ~= nil then n = pp.owningPlaceable:getName() end end)
        if type(n) == "string" and string.upper(n) == want then return pp end
    end
    return nil
end

local function openProductionPage(name)
    -- No name (or an unresolvable one): fall back to the plain page open, which
    -- is still the right screen, just not focused.
    local pp = findProductionPoint(name)
    if pp == nil then
        if name ~= nil and name ~= "" then log("openProduction: '%s' is not one of our production points", tostring(name)) end
        lastProductionName = nil
        return openMenuPage("pageProduction")
    end

    local isOpen = false
    pcall(function()
        if g_gui.currentGuiName ~= nil then isOpen = (g_gui.currentGuiName == "InGameMenu") end
    end)
    -- Same rule as prices: while the screen is open, pressing a DIFFERENT item
    -- switches to it; only the same item again closes.
    if isOpen and lastMenuPage == "pageProduction" then
        if lastProductionName ~= nil and string.upper(lastProductionName) == string.upper(name) then
            g_gui:showGui("")
            lastMenuPage = nil
            lastProductionName = nil
            return true
        end
    elseif not isOpen then
        g_gui:showGui("InGameMenu")
    end

    local ok = false
    pcall(function()
        g_messageCenter:publish(MessageType.GUI_INGAME_OPEN_PRODUCTION_SCREEN, pp)
        ok = true
    end)
    if ok then
        lastMenuPage = "pageProduction"
        lastProductionName = name
        log("openProduction: focused '%s'", tostring(name))
    end
    return ok
end

--- Focus a row on a page whose frame keeps its own item array.
---
--- Unlike production (which has a published GUI_INGAME_OPEN_*_SCREEN message
--- that does the selecting for us), the animals and contracts frames only expose
--- a list element - so we have to find the array behind it and match by name.
--- The frames' internals are stripped from the shipped source, so this tries the
--- likely field names first and then falls back to scanning for ANY array whose
--- entries yield a name, logging whichever worked so the guessing can be
--- replaced with the real field once it is known.
local NAME_KEYS = { "name", "title", "progressTitle" }

local function itemName(it)
    if type(it) ~= "table" then return nil end
    for _, k in ipairs(NAME_KEYS) do
        local v = rawget(it, k)
        if type(v) == "string" and v ~= "" then return v end
    end
    local n = nil
    pcall(function() if type(it.getName) == "function" then n = it:getName() end end)
    if type(n) == "string" and n ~= "" then return n end
    -- husbandry rows wrap the placeable; contract rows wrap the mission
    for _, k in ipairs({ "placeable", "husbandry", "mission", "contract" }) do
        local sub = rawget(it, k)
        if type(sub) == "table" then
            local sn = itemName(sub)
            if sn ~= nil then return sn end
        end
    end
    return nil
end

--- Every candidate {array, fieldName} on a page, best guesses first.
local function itemArrays(page, preferred)
    local out = {}
    for _, k in ipairs(preferred) do
        local v = rawget(page, k)
        if type(v) == "table" and #v > 0 and itemName(v[1]) ~= nil then out[#out + 1] = { v, k } end
    end
    if #out == 0 then
        for k, v in pairs(page) do
            if type(k) == "string" and type(v) == "table" and #v > 0 and itemName(v[1]) ~= nil then
                out[#out + 1] = { v, k }
            end
        end
    end
    return out
end

local function focusListRow(page, listNames, preferredArrays, wanted, label)
    if wanted == nil or wanted == "" then return false end
    local want = string.upper(wanted)
    local list = nil
    for _, ln in ipairs(listNames) do
        local l = rawget(page, ln)
        if type(l) == "table" then list = l break end
    end
    if list == nil then log("%s: no list element on the page", label) return false end

    for _, pair in ipairs(itemArrays(page, preferredArrays)) do
        local arr, field = pair[1], pair[2]
        for i, it in ipairs(arr) do
            local n = itemName(it)
            if n ~= nil and string.upper(n) == want then
                pcall(function() list:setSelectedItem(1, i) end)
                pcall(function() if type(page.onListSelectionChanged) == "function" then page:onListSelectionChanged(list, 1, i) end end)
                log("%s: selected '%s' at row %d (from %s)", label, n, i, field)
                return true
            end
        end
    end
    log("%s: '%s' not found in any item array", label, tostring(wanted))
    return false
end

local lastListPageItem = nil

--- Shared opener for the pages that select by name: animals and contracts.
--- Open or close the in-game menu, whichever it is not.
--
-- The MENU input action opens it, but once it is up the menu owns the input
-- context and that action is no longer live, so a second press goes nowhere.
-- g_gui is the same thing the menu itself drives, and it answers in both
-- directions.
local function toggleInGameMenu()
    local ok = false
    pcall(function()
        if g_gui == nil or g_gui.guis == nil or g_gui.guis["InGameMenu"] == nil then return end
        local isOpen = false
        pcall(function() isOpen = (g_gui.currentGuiName == "InGameMenu") end)
        if isOpen then
            g_gui:showGui("")
            lastMenuPage = nil
        else
            g_gui:showGui("InGameMenu")
        end
        ok = true
    end)
    if not ok then log("menu: could not reach g_gui.guis.InGameMenu") end
    return ok
end

--- Toggle the game's pause state.
--
-- The setter's name has moved between FS versions and the community docs are not
-- reliable here, so try each candidate and SAY which one answered - the same
-- approach that settled the time-scale setter. Reporting the shape once means the
-- next FS update shows up as a log line rather than a dead key.
-- Pause needs the CURRENT state to toggle, and reading it is the hard half:
-- setManualPause(true) paused the game first press, then every later press asked
-- for `true` again because nothing we read reflected it (in-game, 3 Aug: "pause
-- only pauses, doesnt unpause"). So we probe every candidate, log what each one
-- actually held the first time, and fall back to remembering our own intent when
-- none of them answers - a toggle that alternates beats a toggle stuck on.
local pauseReported = false
local pauseIntent = false

local function readPaused(m)
    local seen = {}
    local found = nil
    local function note(name, v)
        seen[#seen + 1] = name .. "=" .. tostring(v)
        if found == nil and type(v) == "boolean" then found = v end
    end
    note("paused", m.paused)
    note("isPaused", m.isPaused)
    note("manualPause", m.manualPause)
    note("isManualPaused", m.isManualPaused)
    pcall(function() if type(m.getIsPaused) == "function" then note("getIsPaused()", m:getIsPaused()) end end)
    pcall(function() if type(m.getIsManualPaused) == "function" then note("getIsManualPaused()", m:getIsManualPaused()) end end)
    pcall(function() if g_time ~= nil and type(g_time.getIsPaused) == "function" then note("g_time:getIsPaused()", g_time:getIsPaused()) end end)
    return found, table.concat(seen, ", ")
end

local function togglePause()
    local ok = false
    pcall(function()
        local m = g_currentMission
        if m == nil then return end

        local paused, seen = readPaused(m)
        -- nothing readable: alternate on our own, so the key still toggles.
        -- Long-hand deliberately: `a and b or c` returns c whenever b is false,
        -- which here would ask to PAUSE every time we were already intending to,
        -- the same and/or trap that bit the fold state this morning.
        local want
        if paused == nil then want = not pauseIntent else want = not paused end

        if type(m.setManualPause) == "function" then
            m:setManualPause(want); ok = true
        elseif type(m.setPaused) == "function" then
            m:setPaused(want); ok = true
        elseif type(m.onToggleGamePaused) == "function" then
            m:onToggleGamePaused(); ok = true
        end

        if ok then pauseIntent = want end

        if not pauseReported then
            pauseReported = true
            log("PAUSE read [%s] -> paused=%s, asking for %s (ok=%s)",
                seen, tostring(paused), tostring(want), tostring(ok))
            if not ok then
                local names = {}
                for k, v in pairs(m) do
                    if type(k) == "string" and type(v) == "function" and string.find(string.lower(k), "pause") then
                        names[#names + 1] = k
                    end
                end
                table.sort(names)
                log("PAUSE no known setter. pause-ish functions: %s",
                    (#names > 0) and table.concat(names, ", ") or "(none)")
            end
        end
    end)
    -- last resort: the input action, which at least works while unpaused
    if not ok then return raiseGlobal("PAUSE", false) end
    return ok
end

local function openFocusedPage(pageField, listNames, preferredArrays, wanted, label)
    local ok = false
    pcall(function()
        local gui = g_gui and g_gui.guis and g_gui.guis["InGameMenu"] or nil
        local menu = gui ~= nil and gui.target or nil
        if type(menu) ~= "table" then return end
        local page = menu[pageField]
        if page == nil then log("%s: no %s", label, pageField) return end

        local isOpen = false
        pcall(function()
            if g_gui.currentGuiName ~= nil then isOpen = (g_gui.currentGuiName == "InGameMenu") end
        end)
        -- Same press rule as prices/production: a different item switches to it,
        -- the same item again closes.
        if isOpen and lastMenuPage == pageField then
            -- A key with NO item ("Jobs", "Animals") is a plain open/close, so a
            -- second press must close it - the same rule Shop and Map already
            -- follow. Requiring a matching item meant `same` was never true for
            -- those keys and the page just reopened forever (in-game, 3 Aug: "jobs
            -- should be the same style, but it doesnt. it gets stuck in jobs").
            local same = wanted == nil
                or (lastListPageItem ~= nil and string.upper(wanted) == string.upper(lastListPageItem))
            if same then
                g_gui:showGui("")
                lastMenuPage = nil
                lastListPageItem = nil
                ok = true
                return
            end
        elseif not isOpen then
            g_gui:showGui("InGameMenu")
        end

        if type(menu.goToPage) == "function" then menu:goToPage(page) end
        focusListRow(page, listNames, preferredArrays, wanted, label)
        lastMenuPage = pageField
        lastListPageItem = wanted
        ok = true
    end)
    return ok
end

--- Put the player straight into a specific owned vehicle, wherever it is.
---
--- VERIFIED 23 Jul: g_localPlayer:requestToEnterVehicle(vehicle) is the call.
--- It teleports the player in from anywhere, which is exactly the intent (skip
--- the walk). Found by trying the plausible APIs and logging which took.
local function enterVehicle(_, _, arg)
    local id = tonumber(arg)
    if id == nil then log("enterVehicle: no vehicle id") return false end

    local veh = nil
    pcall(function() veh = NetworkUtil.getObject(id) end)
    if veh == nil then log("enterVehicle: id %s did not resolve to a vehicle", tostring(id)) return false end

    -- Only ENTERABLE things have a cab. A plough or header resolves fine but is
    -- not something you sit in, so refuse rather than fire an enter request at
    -- an object the game never expects one for. (The plugin guards this too; the
    -- mod refuses regardless of who calls it.)
    if veh.spec_enterable == nil then
        log("enterVehicle: id %s is not enterable (no cab), ignoring", tostring(id))
        return false
    end
    if g_localPlayer == nil or type(g_localPlayer.requestToEnterVehicle) ~= "function" then
        log("enterVehicle: requestToEnterVehicle unavailable")
        return false
    end

    local name = "?"
    pcall(function() name = veh:getFullName() end)
    g_localPlayer:requestToEnterVehicle(veh)
    log("enterVehicle: entering '%s'", name)
    return true
end

-- Handlers: each returns true on success. Direct-first, action fallback.
local HANDLERS = {
    -- ENGINE (mouse-only in vanilla; direct call makes it possible)
    engineOn = function(v) if v.startMotor then v:startMotor(); return true end return raiseAction(v, "MOTOR_STATE_ON") end,
    engineOff = function(v) if v.stopMotor then v:stopMotor(); return true end return raiseAction(v, "MOTOR_STATE_OFF") end,
    engineToggle = function(v)
        if v.getIsMotorStarted and v.startMotor and v.stopMotor then
            if v:getIsMotorStarted() then v:stopMotor() else v:startMotor() end
            return true
        end
        return raiseAction(v, "TOGGLE_MOTOR_STATE")
    end,

    -- CRUISE (exact-speed set = true analog dial). Pure SET: always set the exact
    -- speed and engage. Used by the dial rotate, where every tick must set (never
    -- cancel), so this must NOT toggle.
    -- Adjust the target speed WITHOUT engaging: the cruise dial's rotation.
    -- The game keeps max speed across engage/disengage, so a later cruiseToggle
    -- (dial press) engages at exactly the speed dialed in.
    cruiseSpeed = function(v, val)
        if v.setCruiseControlMaxSpeed and val and val > 0 then
            v:setCruiseControlMaxSpeed(val)
            return true
        end
        return false
    end,

    -- Cycle steering mode on crab-capable machines (Xerion, SP sprayers).
    -- Verified on CLAAS XERION 12.590 (27 Jul): spec_crabSteering, states are
    -- 1-BASED (1..stateMax = #steeringModes; steeringModes[0] is nil and
    -- setCrabSteering does NO validation, so passing 0 crashes in its
    -- animation code AND poisons spec.state for every later call).
    -- setNextCrabSteeringMode(1) is the exact path the in-game keybind uses
    -- (wraps stateMax->1 and skips unavailable modes); fall back to a manual
    -- 1-based wrap only if that function is missing.
    crabSteer = function(v)
        local cs = v.spec_crabSteering
        if cs == nil or (cs.stateMax or 0) < 1 then return false end
        if type(v.getCanToggleCrabSteering) == "function" then
            local ok, allowed = pcall(v.getCanToggleCrabSteering, v)
            if ok and allowed == false then
                log("crabSteer: blocked by getCanToggleCrabSteering")
                return false
            end
        end
        if type(v.setNextCrabSteeringMode) == "function" then
            v:setNextCrabSteeringMode(1)
            log("crabSteer -> state %d (setNextCrabSteeringMode)", cs.state or -1)
            return true
        end
        local nextState = (cs.state or 1) + 1
        if nextState > cs.stateMax then nextState = 1 end
        v:setCrabSteering(nextState)
        log("crabSteer -> state %d (setCrabSteering)", nextState)
        return true
    end,

    cruiseSet = function(v, val)
        if v.setCruiseControlMaxSpeed and val and val > 0 then
            v:setCruiseControlMaxSpeed(val)
            if v.setCruiseControlState then v:setCruiseControlState(1) end -- engage
            return true
        end
        return false
    end,
    -- TOGGLE variant for a single cruise-set KEY: off -> set exact speed + engage,
    -- on -> disengage. So one key both starts cruise at its speed and cancels it.
    cruiseSetToggle = function(v, val)
        if not (v.setCruiseControlMaxSpeed and val and val > 0) then return false end
        local on = false
        if v.getCruiseControlState then pcall(function() on = (v:getCruiseControlState() or 0) > 0 end) end
        if on then
            if v.setCruiseControlState then v:setCruiseControlState(0) end
        else
            v:setCruiseControlMaxSpeed(val)
            if v.setCruiseControlState then v:setCruiseControlState(1) end
        end
        return true
    end,
    -- ⚠️ THE READ-BACK BELOW IS LOAD-BEARING, here and in the three handlers that
    -- follow the same shape (lightsToggle, beaconToggle, steeringToggle) plus
    -- toolToggle and lowerImplement.
    --
    -- Calling a setter is not evidence it did anything. A machine can carry the
    -- spec, answer the getter, accept the setter and still not move, and an
    -- unverified `return true` then makes the raiseAction fallback below
    -- UNREACHABLE - so the deck key does nothing while the player's own keyboard
    -- binding works, because that binding IS the action we skipped.
    --
    -- Not hypothetical: it shipped that way in lowerImplement and broke Lower /
    -- Raise for a customer on every implement whose XML declares
    -- needsLowering="false" (3 Sep 2026, reproduced on a Fendt 700 Vario with an
    -- Amazone ZA-TS 3200). Verify the effect, never the call.
    cruiseToggle = function(v)
        if v.getCruiseControlState and v.setCruiseControlState then
            local before = v:getCruiseControlState()
            v:setCruiseControlState(before > 0 and 0 or 1)
            if v:getCruiseControlState() ~= before then return true end
        end
        return raiseAction(v, "TOGGLE_CRUISE_CONTROL")
    end,

    -- LIGHTS
    -- setNextLightsState CYCLES, so there is no matching getter. The mask that
    -- stateJson reads is the observable effect, so that is what gets checked.
    -- A machine with no mask to read falls back to trusting the call: without a
    -- way to prove nothing happened, firing the action on top would risk undoing
    -- a lights change that DID work, which is the failure being fixed, inverted.
    lightsToggle = function(v)
        if v.setNextLightsState then
            local sp = v.spec_lights
            local before = (type(sp) == "table" and type(sp.lightsTypesMask) == "number") and sp.lightsTypesMask or nil
            v:setNextLightsState(1)
            if before == nil or sp.lightsTypesMask ~= before then return true end
        end
        return raiseAction(v, "TOGGLE_LIGHTS")
    end,
    -- The likeliest of the four to bite: plenty of machines carry spec_lights and
    -- answer getBeaconLightsVisibility without a beacon actually fitted.
    beaconToggle = function(v)
        if v.getBeaconLightsVisibility and v.setBeaconLightsVisibility then
            local before = v:getBeaconLightsVisibility()
            v:setBeaconLightsVisibility(not before)
            if v:getBeaconLightsVisibility() ~= before then return true end
        end
        return raiseAction(v, "TOGGLE_BEACON_LIGHTS")
    end,
    highBeamToggle = function(v) return raiseAction(v, "TOGGLE_HIGH_BEAM_LIGHT") end,
    -- WORK lights = the bright field floods (distinct from the road lights above).
    workFrontToggle = function(v) return raiseAction(v, "TOGGLE_WORK_LIGHT_FRONT") end,
    workBackToggle = function(v) return raiseAction(v, "TOGGLE_WORK_LIGHT_BACK") end,

    -- IMPLEMENT / TOOL
    -- TOOL on/off (sprayer, mower, spreader, baler). setIsTurnedOn lives on the
    -- IMPLEMENT (or a self-propelled tool = the vehicle), so try every candidate
    -- and confirm the state actually flipped before claiming success (the logical
    -- on/off flag is synchronous, so this check is reliable, unlike lower's anim).
    toolToggle = function(v)
        for _, obj in ipairs(candidates(v)) do
            if type(obj.setIsTurnedOn) == "function" and type(obj.getIsTurnedOn) == "function" then
                local before = obj:getIsTurnedOn()
                obj:setIsTurnedOn(not before)
                if obj:getIsTurnedOn() ~= before then return true end
            end
        end
        return raiseAction(v, "IMPLEMENT_EXTRA")
    end,
    -- LOWER: set the IMPLEMENT's working state directly (setLoweredAll on the
    -- attached implement object). This is what AI/Courseplay call -- instant, real
    -- lower, no input-path hold-timeout. (setJointMoveDown on the TRACTOR was the
    -- earlier mistake: it moves only the hitch arms.) Action fallback below.
    lowerImplement = function(v)
        if v.getAttachedImplements then
            local ok, any = pcall(function()
                local did = false
                for _, imp in ipairs(v:getAttachedImplements()) do
                    local obj = imp.object
                    -- setLoweredAll drives normal implements instantly, VERIFIED. But
                    -- a combine header (spec_cutter) ignores it -- getIsLowered never
                    -- flips -- because its working state is combine-driven. Leave
                    -- headers to the action path below (which does move them).
                    if type(obj) == "table" and obj.spec_cutter == nil
                        and type(obj.setLoweredAll) == "function"
                        and type(obj.getIsLowered) == "function" then
                        local lowered = obj:getIsLowered()
                        obj:setLoweredAll(not lowered)
                        -- CONFIRM THE FLIP. Calling the setter is not evidence it
                        -- did anything, and claiming success here is what broke
                        -- Lower/Raise for a customer on 3 Sep 2026.
                        --
                        -- An implement whose XML declares needsLowering="false" has
                        -- setLoweredAll AND getIsLowered, so every guard above
                        -- passes, and the call is still a no-op: the game treats it
                        -- as a machine with nothing to lower. 40 base-game
                        -- implements declare it, including the Amazone ZA-TS 3200,
                        -- the Bredal SG, every front weight, the balers and the
                        -- tank trailers.
                        --
                        -- Unverified, this returned true and the LOWER_IMPLEMENT
                        -- action below was never reached, so the deck key did
                        -- nothing while the player's own V key worked -- because V
                        -- IS that action. Reproduced in-game on a Fendt 700 Vario
                        -- with a ZA-TS 3200 attached.
                        --
                        -- Same shape as toolToggle above. The flag is set
                        -- synchronously and the animation follows it, so this
                        -- read-back is reliable; it is the visible movement that
                        -- lags, not the flag.
                        if obj:getIsLowered() ~= lowered then did = true end
                    end
                end
                return did
            end)
            if ok and any then return true end
        end
        -- action path: combine headers + anything setLoweredAll didn't handle.
        if raiseAction(v, "LOWER_IMPLEMENT") then return true end
        return raiseAction(v, "LOWER_ALL_IMPLEMENTS")
    end,
    lowerAll = function(v) return raiseAction(v, "LOWER_ALL_IMPLEMENTS") end,
    foldToggle = function(v) return raiseAction(v, "FOLD_ALL_IMPLEMENTS") end,

    -- ATTACH / DETACH
    attach = function(v) return raiseAction(v, "ATTACH") end,
    detach = function(v) return raiseAction(v, "DETACH") end,

    -- COMBINE / DISCHARGE (raiseAction now searches attached implements too, so a
    -- trailer's TOGGLE_TIPSTATE fires even though it is not on the tractor root)
    pipeToggle = function(v) return raiseAction(v, "TOGGLE_PIPE") end,
    -- UNLOAD/tip: the trailer's TOGGLE_TIPSTATE callback fires but does not move
    -- the tipper (state-machine, like the cutter). Drive the tip DIRECTLY instead:
    -- startTipping(preferredSide) when closed, stopTipping otherwise.
    unloadToggle = function(v)
        for _, obj in ipairs(candidates(v)) do
            if type(obj.getTipState) == "function" and type(obj.startTipping) == "function" then
                -- Trailer.TIPSTATE_CLOSED is 0 (verified); the `or 0` only guards
                -- the Trailer-global-missing case.
                local closed = (Trailer ~= nil and Trailer.TIPSTATE_CLOSED) or 0
                if obj:getTipState() == closed then
                    local side = 1
                    local spec = obj.spec_trailer
                    if type(spec) == "table" and spec.preferredTipSideIndex then side = spec.preferredTipSideIndex end
                    obj:startTipping(side)
                elseif type(obj.stopTipping) == "function" then
                    obj:stopTipping()
                end
                return true
            end
        end
        -- No trailer to tip. A HARVESTER empties itself instead: a combine or
        -- beet harvester discharges through the pipe, and its "empty here" is
        -- TOGGLE_TIPSTATE_GROUND - a Dewulf ZKIVSE registers that and no
        -- TOGGLE_TIPSTATE at all, which is why unload did nothing on one
        -- (in-game, 3 Aug). Try the trailer name first, then the harvester's.
        if raiseAction(v, "TOGGLE_TIPSTATE") then return true end
        return raiseAction(v, "TOGGLE_TIPSTATE_GROUND")
    end,

    -- AI / GPS  (TOGGLE_AI is tap/hold -> needs the release, or it opens the menu)
    aiToggle = function(v) return raiseAction(v, "TOGGLE_AI", true) end,
    steeringToggle = function(v)
        if v.setAIAutomaticSteeringEnabled and v.getAIAutomaticSteeringEnabled then
            local before = v:getAIAutomaticSteeringEnabled()
            v:setAIAutomaticSteeringEnabled(not before)
            if v:getAIAutomaticSteeringEnabled() ~= before then return true end
        end
        return raiseAction(v, "TOGGLE_AI_STEERING")
    end,
    steeringLines = function(v) return raiseAction(v, "TOGGLE_AI_STEERING_LINES") end,
    -- Flip between AI Worker and Steering Assist.
    --
    -- FS exposes getAIModeSelection / setAIModeSelection and AIModeSelection
    -- reports NUM_MODES = 2, with the selection observed as 1 and 2 (4 Aug). With
    -- exactly two modes a FLIP needs no knowledge of which number is which, so
    -- there is nothing here to guess wrong - the one thing that could have put a
    -- player in the wrong mode is simply not part of the logic.
    --
    -- Guarded to the observed range: if a future FS adds a third mode, wrapping
    -- through NUM_MODES keeps working rather than sticking at 2.
    aiModeToggle = function(v)
        local ok = false
        pcall(function()
            if type(v.getAIModeSelection) ~= "function" or type(v.setAIModeSelection) ~= "function" then return end
            local cur = tonumber(v:getAIModeSelection()) or 1
            local n = 2
            pcall(function()
                if type(AIModeSelection) == "table" and tonumber(AIModeSelection.NUM_MODES) then
                    n = tonumber(AIModeSelection.NUM_MODES)
                end
            end)
            if n < 2 then n = 2 end
            local nextMode = cur % n + 1
            v:setAIModeSelection(nextMode)
            -- No action fallback exists for this one, so the read-back only makes
            -- the log honest rather than unlocking a second path. Still worth it:
            -- "command ok" on a mode that never changed is how the other five hid.
            local after = tonumber(v:getAIModeSelection())
            log("AIMODE %s -> %s (of %s), now %s", tostring(cur), tostring(nextMode), tostring(n), tostring(after))
            ok = (after ~= cur)
        end)
        return ok
    end,

    -- MISC
    honk = function(v) return raiseAction(v, "HONK") end,
    camSwitch = function(v) return raiseAction(v, "CAMERA_SWITCH") end,

    --- Jump straight to camera N instead of cycling to it. Cycling is fine with
    --- three cameras and useless with seven, and a Stream Deck key's whole appeal
    --- is going directly to the view you want.
    --- Indices are 1-based, matching the order the vehicle declares them.
    camIndex = function(v, value)
        local idx = math.floor(tonumber(value) or 1)
        if idx < 1 then idx = 1 end
        local ok = false
        pcall(function()
            local se = v.spec_enterable
            local cams = se ~= nil and se.cameras or nil
            if cams == nil or #cams == 0 then return end
            -- Clamp rather than fail: a profile shipped for a 4-camera tractor
            -- should still do something sensible on a 2-camera one.
            if idx > #cams then idx = #cams end
            if type(v.setActiveCameraIndex) == "function" then
                v:setActiveCameraIndex(idx)
                ok = true
            end
        end)
        return ok
    end,

    --- Analog joint control for loaders, cranes and excavators.
    --- value = signed dial ticks, arg = the axis action name.
    axis = function(v, value, arg)
        local actionName = tostring(arg or "")
        -- Say WHY, always. A silent false here cost a test cycle: the plugin was
        -- dropping the arg on the floor and the log only said "no effect".
        if actionName == "" then
            log("axis: no joint given (plugin sent value=%s arg=%s)", tostring(value), tostring(arg))
            return false
        end
        if InputAction == nil then log("axis: InputAction unavailable") return false end
        local ticks = tonumber(value) or 0
        if ticks == 0 then log("axis '%s': zero ticks, nothing to do", actionName) return false end

        -- A slot name ("arm") expands to the candidates that could drive it; a
        -- raw AXIS_* name is honoured as-is so an unusual machine can still be
        -- targeted exactly.
        local slot = AXIS_SLOTS[actionName:lower()]
        local names = slot ~= nil and slot.names or { actionName }
        local kind = slot ~= nil and slot.kind or nil
        local ord = slot ~= nil and slot.ord or 1

        -- The joint can live on the ATTACHED loader rather than the tractor, so
        -- search the implements too (the lesson from lower/raise).
        --
        -- Prefer the moving tool: it is matched on what the tool itself
        -- declares, so it works the same on every machine. The registered input
        -- event is the fallback.
        local obj, event, tool, resolved = nil, nil, nil, nil
        for _, cand in ipairs(candidates(v)) do
            local t = findMovingTool(cand, names, kind, ord)
            if t ~= nil then obj, tool, resolved = cand, t, "tool" break end
        end

        if tool == nil then
            for _, name in ipairs(names) do
                for _, cand in ipairs(candidates(v)) do
                    local e = findEvent(cand, InputAction[name], name)
                    if e ~= nil then obj, event, resolved = cand, e, name break end
                end
                if event ~= nil then break end
            end
        end

        if event == nil and tool == nil then
            log("axis '%s' matched none of [%s]; dumping what IS registered:",
                actionName, table.concat(names, ", "))
            for i, cand in ipairs(candidates(v)) do
                dumpRegisteredActions(cand, actionName .. "@" .. i)
            end
            return false
        end
        -- From here on, use the axis that actually resolved, not the slot name:
        -- the pulse feeds this straight back into the game's own callback.
        actionName = resolved

        local dir = ticks > 0 and 1 or -1
        local steps = math.min(math.abs(ticks), 6)
        -- One tick is a nudge; a spin is a sweep. Capped so a wild flick cannot
        -- send the boom to its end stop and leave it there.
        local ms = math.min(110 * steps, 700)

        -- Re-pulsing the same axis EXTENDS the current hold instead of stacking a
        -- second one, so a continuous turn is continuous movement.
        for _, p in ipairs(activePulses) do
            if p.action == actionName and p.obj == obj and p.tool == tool then
                p.value = dir
                p.remain = math.max(p.remain, ms)
                return true
            end
        end
        activePulses[#activePulses + 1] = {
            obj = obj, event = event, tool = tool,
            action = actionName, value = dir, remain = ms,
        }
        -- Once per slot only. A dial emits a command per TICK, so logging every
        -- one buries the player's log in our chatter during normal use, and the
        -- interesting fact (which joint a slot resolved to) never changes.
        local slotKey = tostring(arg)
        if not loggedSlots[slotKey] then
            loggedSlots[slotKey] = true
            log("axis '%s' -> %s", slotKey, tool ~= nil and "moving tool" or actionName)
        end
        return true
    end,

    --- Stop every axis immediately. Cheap insurance: if a pulse is ever left
    --- running by a disconnect mid-move, one key puts the boom back under control.
    axisStop = function()
        for i = #activePulses, 1, -1 do
            local p = activePulses[i]
            fireAxis(p.obj, p.event, p.action, 0)
            table.remove(activePulses, i)
        end
        return true
    end,

    --- Go to the cab view / the outside view by MEANING rather than by index.
    --- VERIFIED 22 Jul: vehicles carry 2-3 cameras and each knows isInside, so a
    --- profile can say "cab" and be right on every machine, which an index
    --- cannot (camera 2 is inside on a tractor, outside on an excavator).
    camInside = function(v) return setCameraWhere(v, true) end,
    camOutside = function(v) return setCameraWhere(v, false) end,

    --- DIAGNOSTIC: list every input action currently registered.
    ---
    --- Same reasoning as dumpCategories: the profile needs about twenty more
    --- actions (vehicle switch, indicators, cover, time scale, build mode...)
    --- and inventing their names has failed every time it was tried. What is
    --- registered depends on CONTEXT, so run it once on foot and once in a
    --- vehicle: the player's own actions only exist while out of the cab.
    dumpActions = function(v)
        local names, seen = {}, {}
        local function add(n)
            n = tostring(n)
            if n ~= "" and not seen[n] then seen[n] = true names[#names + 1] = n end
        end

        -- Everything the input system currently has bound, whatever owns it.
        pcall(function()
            if g_inputBinding == nil or g_inputBinding.events == nil then return end
            for _, ev in pairs(g_inputBinding.events) do
                if type(ev) == "table" and ev.actionName ~= nil then add(ev.actionName) end
            end
        end)

        -- Plus anything registered on the vehicle or its implements, which can
        -- differ from the global set.
        if v ~= nil then
            for _, obj in ipairs(candidates(v)) do
                pcall(function()
                    for specName, spec in pairs(obj) do
                        if type(specName) == "string" and specName:sub(1, 5) == "spec_" and type(spec) == "table" then
                            local ae = spec.actionEvents
                            if type(ae) == "table" then
                                for _, entry in pairs(ae) do
                                    local ev = resolveEvent(entry)
                                    if type(entry) == "table" and entry.actionName ~= nil then add(entry.actionName)
                                    elseif type(ev) == "table" and ev.actionName ~= nil then add(ev.actionName) end
                                end
                            end
                        end
                    end
                end)
            end
        end

        table.sort(names)
        local where = (v ~= nil) and "in a vehicle" or "on foot"
        log("actions (%s): %d registered", where, #names)
        local line = {}
        for i = 1, #names do
            line[#line + 1] = names[i]
            if #line == 10 or i == #names then
                log("actions: %s", table.concat(line, ", "))
                line = {}
            end
        end
        return true
    end,

    --- DIAGNOSTIC: list every CROP and every FILL TYPE the game defines.
    ---
    --- These decide the icon set: a crop icon is needed for every fruit the
    --- field status can report, and a fill icon for everything a tank or
    --- trailer can hold. The existing inventory guessed "about 14 crops, more
    --- if DLCs add some", which is not something to commission artwork from.
    ---
    --- Fruit types are the growable crops; fill types are the superset (crops
    --- plus diesel, water, milk, fertiliser, wool, eggs and the rest).
    --- Everything openPrices has to guess at, printed once. The page list and the
    --- statistics frame's sub-tab constants are stripped from the shipped source,
    --- so this is the only way to know them.
    dumpMenu = function()
        log("--- dumpMenu ---")
        pcall(function()
            local gui = g_gui and g_gui.guis and g_gui.guis["InGameMenu"] or nil
            local menu = gui ~= nil and gui.target or nil
            if type(menu) ~= "table" then log("no InGameMenu target") return end
            local pages = {}
            for k, _ in pairs(menu) do
                if type(k) == "string" and string.sub(k, 1, 4) == "page" then pages[#pages + 1] = k end
            end
            table.sort(pages)
            log("pages: %s", table.concat(pages, " "))
            if type(menu.pageFrames) == "table" then
                for i, p in ipairs(menu.pageFrames) do
                    local nm = "?"
                    pcall(function() nm = tostring(p.name or p.title or i) end)
                    log("  pageFrames[%d]: %s", i, nm)
                end
            end
            local F = _G["InGameMenuStatisticsFrame"]
            if type(F) == "table" then
                if type(F.SUB_CATEGORY) == "table" then
                    for k, v in pairs(F.SUB_CATEGORY) do log("  SUB_CATEGORY.%s = %s", tostring(k), tostring(v)) end
                else
                    log("  SUB_CATEGORY: absent")
                end
                if type(F.HEADER_TITLES) == "table" then
                    for i, t in ipairs(F.HEADER_TITLES) do log("  HEADER_TITLES[%d] = %s", i, tostring(t)) end
                end
            else
                log("  InGameMenuStatisticsFrame: not a global")
            end
            local page = menu.pageStatistics
            if type(page) == "table" then
                log("  pageStatistics: subCategoryPaging=%s productList=%s fillTypes=%s",
                    tostring(page.subCategoryPaging ~= nil), tostring(page.productList ~= nil), type(page.fillTypes))
                if type(page.fillTypes) == "table" then
                    for s, section in ipairs(page.fillTypes) do
                        local n = type(section) == "table" and #section or 0
                        local first = "?"
                        pcall(function() first = tostring(section[1] and section[1].name) end)
                        log("    fillTypes[%d]: %d rows, first=%s", s, n, first)
                    end
                end
            end
            -- a message type would collapse the whole sequence to one publish
            pcall(function()
                for k, v in pairs(MessageType) do
                    if type(k) == "string" and string.sub(k, 1, 11) == "GUI_INGAME_" then
                        log("  MessageType.%s = %s", k, tostring(v))
                    end
                end
            end)

            -- The animals and contracts pages have no published "open focused on
            -- X" message (unlike production), so per-item selection there needs
            -- their list elements by name. Print what each page actually holds.
            for _, pf in ipairs({ "pageAnimals", "pageContracts" }) do
                local p = menu[pf]
                if type(p) ~= "table" then
                    log("  %s: absent", pf)
                else
                    local lists, others = {}, {}
                    for k, v in pairs(p) do
                        if type(k) == "string" then
                            if type(v) == "table" and (v.setSelectedItem ~= nil or v.reloadData ~= nil) then
                                lists[#lists + 1] = k
                            elseif type(v) == "table" and #v > 0 then
                                others[#others + 1] = string.format("%s[%d]", k, #v)
                            end
                        end
                    end
                    table.sort(lists); table.sort(others)
                    log("  %s: lists={%s} arrays={%s}", pf, table.concat(lists, " "), table.concat(others, " "))
                end
            end
        end)
        log("--- end dumpMenu ---")
        return true
    end,

    dumpFillTypes = function()
        local function report(label, list)
            table.sort(list)
            log("%s: %d", label, #list)
            local line = {}
            for i = 1, #list do
                line[#line + 1] = list[i]
                if #line == 10 or i == #list then
                    log("%s: %s", label, table.concat(line, ", "))
                    line = {}
                end
            end
        end

        local fruits = {}
        pcall(function()
            local m = g_fruitTypeManager
            local types = m and (m.fruitTypes or m:getFruitTypes()) or nil
            if type(types) ~= "table" then return end
            for _, ft in pairs(types) do
                if type(ft) == "table" and ft.name ~= nil then fruits[#fruits + 1] = tostring(ft.name):upper() end
            end
        end)
        report("crops", fruits)

        local fills = {}
        pcall(function()
            local m = g_fillTypeManager
            local types = m and (m.fillTypes or m:getFillTypes()) or nil
            if type(types) ~= "table" then return end
            for _, ft in pairs(types) do
                if type(ft) == "table" and ft.name ~= nil then
                    local n = tostring(ft.name):upper()
                    if n ~= "UNKNOWN" then fills[#fills + 1] = n end
                end
            end
        end)
        report("fills", fills)
        return (#fruits + #fills) > 0
    end,

    --- DIAGNOSTIC: list every store category the game defines.
    ---
    --- Store category is what decides which page a machine belongs to, and
    --- guessing the names has already cost us twice (EXCAVATORS is really
    --- FORESTRYEXCAVATORS). The game holds the authoritative list, so ask it
    --- once rather than discovering each name by driving the machine.
    dumpCategories = function()
        local names = {}
        pcall(function()
            if g_storeManager == nil then return end
            -- Two shapes depending on FS version: a keyed table or an array.
            local cats = g_storeManager.categories or g_storeManager:getCategories()
            if type(cats) ~= "table" then return end
            for key, cat in pairs(cats) do
                local n = nil
                if type(cat) == "table" then n = cat.name or cat.title end
                if n == nil and type(key) == "string" then n = key end
                if n ~= nil then names[#names + 1] = tostring(n):upper() end
            end
        end)
        table.sort(names)

        if #names == 0 then
            log("categories: none readable from g_storeManager")
            return false
        end
        -- Chunked: one enormous line gets truncated in the log viewer.
        local line = {}
        for i = 1, #names do
            line[#line + 1] = names[i]
            if #line == 12 or i == #names then
                log("categories: %s", table.concat(line, ", "))
                line = {}
            end
        end
        log("categories: %d total", #names)
        return true
    end,

    --- DIAGNOSTIC: report this vehicle's cameras and moving tools to the log.
    --- Deliberately prints RAW field names and values rather than the ones we
    --- expect, because the whole point is to find out what the API actually
    --- offers before writing control code against it.
    dumpVehicle = function(v)
        local name = "?"
        pcall(function() name = v:getFullName() end)
        log("--- dumpVehicle: %s ---", name)

        pcall(function()
            local se = v.spec_enterable
            local cams = se ~= nil and se.cameras or nil
            if cams == nil then log("cameras: none") return end
            log("cameras: %d (active=%s)", #cams, tostring(se.camIndex))
            for i, cam in ipairs(cams) do
                local inside, rotY, fov = "?", 0, 0
                pcall(function() inside = tostring(cam.isInside == true) end)
                pcall(function() rotY = tonumber(cam.rotY) or 0 end)
                pcall(function() fov = tonumber(cam.fovY) or 0 end)
                log("  cam %d: inside=%s rotY=%.2f fovY=%.2f", i, inside, rotY, fov)
            end
        end)

        for ci, obj in ipairs(candidates(v)) do
            pcall(function()
                local oName = "?"
                pcall(function() oName = obj:getFullName() end)
                local sc = obj.spec_cylindered
                local tools = sc ~= nil and sc.movingTools or nil
                if tools == nil or #tools == 0 then return end
                log("[%d] %s: movingTools=%d", ci, oName, #tools)
                for ti, t in ipairs(tools) do
                    if ti > 8 then log("  ...more tools omitted") break end
                    -- Print every scalar field. Field NAMES are what we are here
                    -- to learn, so enumerate instead of asking for known keys.
                    local parts = {}
                    for k, val in pairs(t) do
                        local tv = type(val)
                        if tv == "number" then
                            parts[#parts + 1] = string.format("%s=%.3f", tostring(k), val)
                        elseif tv == "string" or tv == "boolean" then
                            parts[#parts + 1] = string.format("%s=%s", tostring(k), tostring(val))
                        end
                    end
                    table.sort(parts)
                    log("  tool %d: %s", ti, table.concat(parts, " "))
                end
            end)
        end
        -- Enumerate every spec_ the vehicle carries: field NAMES are what we
        -- are here to learn (crab steering has no input action, so a direct
        -- spec call is the only route - find the spec first).
        pcall(function()
            local specs = {}
            for k, _ in pairs(v) do
                if type(k) == "string" and k:sub(1, 5) == "spec_" then specs[#specs + 1] = k:sub(6) end
            end
            table.sort(specs)
            log("specs (%d): %s", #specs, table.concat(specs, " "))
        end)

        -- Crab steering deep dump: every scalar field, plus one level into any
        -- sub-tables that look like mode/state carriers.
        pcall(function()
            local cs = v.spec_crabSteering
            if cs == nil then log("crabSteering: not on this vehicle") return end
            local parts = {}
            for k, val in pairs(cs) do
                local tv = type(val)
                if tv == "number" or tv == "string" or tv == "boolean" then
                    parts[#parts + 1] = string.format("%s=%s", tostring(k), tostring(val))
                end
            end
            table.sort(parts)
            log("crabSteering: %s", table.concat(parts, " "))
            local modes = cs.crabSteeringModes or cs.steeringModes
            if type(modes) == "table" then
                for mi, m in ipairs(modes) do
                    local nameV = "?"
                    pcall(function() nameV = tostring(m.name or m.text or mi) end)
                    log("  mode %d: %s", mi, nameV)
                end
            end
        end)

        log("--- end dumpVehicle ---")
        return true
    end,

    -- ---------------------------------------------------------------------
    -- Actions below use names VERIFIED from a full in-game action dump on
    -- 22 Jul 2026 (130 registered across on-foot and every vehicle class).
    -- See fs25-direct-control-verified.md. Do not add a name here that has not
    -- been seen in that dump: an unregistered name fails silently.
    -- ---------------------------------------------------------------------

    -- SWITCHING
    switchVehicle     = function(v) return raiseAny(v, "SWITCH_VEHICLE") end,
    -- Jump straight into a specific owned vehicle by its network id (fleet dial press).
    enterVehicle      = enterVehicle,
    switchVehicleBack = function(v) return raiseAny(v, "SWITCH_VEHICLE_BACK") end,
    switchImplement   = function(v) return raiseAction(v, "SWITCH_IMPLEMENT") end,
    -- Entering a vehicle stows the hand tool, so the Use latch goes with it.
    enterExit         = function(v) return raiseAny(v, "ENTER") end,

    -- SIGNALS
    indicatorLeft  = function(v) return raiseAction(v, "TOGGLE_TURNLIGHT_LEFT") end,
    indicatorRight = function(v) return raiseAction(v, "TOGGLE_TURNLIGHT_RIGHT") end,
    hazards        = function(v) return raiseAction(v, "TOGGLE_TURNLIGHT_HAZARD") end,

    -- TRAILER / LOAD
    coverToggle  = function(v) return raiseAction(v, "TOGGLE_COVER") end,
    tipToggle    = function(v) return raiseAction(v, "TOGGLE_TIPSTATE") end,
    -- Deliberately separate from tipToggle: dumping on the ground makes a mess
    -- that has to be cleaned up, so it should never be one mis-press away.
    tipGround    = function(v) return raiseAction(v, "TOGGLE_TIPSTATE_GROUND") end,
    tensionBelts = function(v) return raiseAction(v, "TOGGLE_TENSION_BELTS") end,
    -- OBSERVED on a tipper: this is the spec's "tip direction A/B", which the
    -- first action sweep missed because it only appears on tipping implements.
    tipSide      = function(v) return raiseAction(v, "TOGGLE_TIPSIDE") end,

    -- IMPLEMENTS (the "all" variants act on the whole train, not just one tool)
    turnOnAll = function(v) return raiseAction(v, "TURN_ON_ALL_IMPLEMENTS") end,
    foldAll   = function(v) return raiseAction(v, "FOLD_ALL_IMPLEMENTS") end,
    lowerAll  = function(v) return raiseAction(v, "LOWER_ALL_IMPLEMENTS") end,
    -- IMPLEMENT_EXTRA is how FS exposes machine-specific extras: support legs,
    -- second hitches, grabs. What it does depends on the implement, which is
    -- why the profile labels it generically.
    implementExtra  = function(v) return raiseAction(v, "IMPLEMENT_EXTRA") end,
    implementExtra2 = function(v) return raiseAction(v, "IMPLEMENT_EXTRA2") end,
    implementExtra3 = function(v) return raiseAction(v, "IMPLEMENT_EXTRA3") end,
    seedsNext       = function(v) return raiseAction(v, "TOGGLE_SEEDS") end,
    seedsPrev       = function(v) return raiseAction(v, "TOGGLE_SEEDS_BACK") end,
    doubleSpray     = function(v) return raiseAction(v, "DOUBLED_SPRAY_AMOUNT") end,

    -- HARVEST
    chopperToggle = function(v) return raiseAction(v, "TOGGLE_CHOPPER") end,
    unload        = function(v) return raiseAction(v, "UNLOAD") end,

    -- FORESTRY
    treeAlign  = function(v) return raiseAction(v, "TREE_AUTOMATIC_ALIGN") end,
    treeDrop   = function(v) return raiseAction(v, "WOOD_HARVESTER_DROP") end,
    -- The callbackState IS the direction, and the harvester registers only the
    -- BACK half of the pair - state -1, verified on a Volvo EC250DL (3 Aug):
    --   CMD 'TOGGLE_CUT_LENGTH_BACK' registered 1 time(s): spec_woodHarvester(state=-1)
    -- So firing it as registered steps DOWN, while the game's own key (Y) steps
    -- up (in-game: "it's cycling down through the cut length ... its key press
    -- goes up"). There is no forward action to switch to - TOGGLE_CUT_LENGTH is
    -- not registered on the machine at all - but the callback reads the state as
    -- its direction, so overriding it to +1 drives the same handler upward.
    cutLength  = function(v) return raiseAction(v, "TOGGLE_CUT_LENGTH_BACK", false, 1) end,
    headTilt   = function(v) return raiseAction(v, "TOGGLE_WOOD_HARVESTER_TILT") end,

    -- ON FOOT (registered globally, and only while out of a cab)
    -- Cycling moves off whatever is running, so the Use latch cannot still be
    -- valid. See handtoolToggle.
    handtoolCycle  = function(v) return raiseAny(v, "CYCLE_HANDTOOL") end,
    -- ACTIVATE, not TOGGLE. The key is called "Use" and TOGGLE_HANDTOOL only
    -- equips or puts away the tool - the game's own strings are explicit:
    --   input_TOGGLE_HANDTOOL   = Toggle hand tool
    --   input_ACTIVATE_HANDTOOL = Activate hand tool   ("Use chainsaw")
    -- Pressing it repeatedly equipped and unequipped, which reads as a dead key
    -- (in-game, 4 Aug: "the On Foot Use button didnt appear to do anything").
    --
    -- ACTIVATE_HANDTOOL is registered by the TOOL, not globally, so it only
    -- exists while one is in hand. That is correct - there is nothing to use
    -- otherwise - and raiseGlobal now dumps the table when it misses, so a
    -- failure says which of the two it was.
    --
    -- No equip/put-away key is needed: CYCLE_HANDTOOL wraps through EMPTY HANDS
    -- (verified in-game, 4 Aug), so the Tool key both draws a tool and
    -- puts it away. TOGGLE_HANDTOOL would be a third key doing what Tool already
    -- does.
    -- USE IS HELD, NOT TOGGLED.
    --
    -- Every hand tool in the game drives the same action button, and they split
    -- on how: the marking spray is a TAP ("press to permanently paint the
    -- symbol") while the horse brush, pressure washer and chainsaw are HOLDS
    -- ("keep holding until the bar fills"). One latch cannot serve both - it
    -- acted on every second press of a tap tool, so the spray would have painted,
    -- then done nothing, then painted.
    --
    -- So the deck key's own press and release drive the game's button directly:
    -- tap the key for a tap, hold the key for a hold. That is exactly what the
    -- game's help tells players to do with a mouse, it needs no state on either
    -- side, and there is no latch left to drift out of step with the game.
    --
    -- The plugin sends these; it maps its `handtoolToggle` command onto the pair
    -- so no shipped profile has to change.
    handtoolPress   = function(v) return raiseAny(v, "ACTIVATE_HANDTOOL", false, 1) end,
    handtoolRelease = function(v) return raiseAny(v, "ACTIVATE_HANDTOOL", false, 0) end,

    --- Kept for a key configured by hand against an older plugin: a plain click,
    --- which is right for the tap tools and gives a brief cut on the saw.
    handtoolToggle = function(v)
        local ok = raiseAny(v, "ACTIVATE_HANDTOOL", false, 1)
        if ok then raiseAny(v, "ACTIVATE_HANDTOOL", false, 0) end
        return ok
    end,
    buildMode      = function(v) return raiseAny(v, "TOGGLE_CONSTRUCTION") end,
    flashlight     = function(v) return raiseAny(v, "TOGGLE_LIGHTS_FPS") end,

    -- SESSION (work in and out of a vehicle)
    timeUp     = function() return stepTimeScale(1) end,
    timeDown   = function() return stepTimeScale(-1) end,
    -- NOT raiseAny. Raising MENU/PAUSE opens the thing, and then the input
    -- context changes - the in-game action is no longer the live one - so the
    -- second press raises an action nobody is listening to and the menu stays up
    -- (in-game, 3 Aug: "on foot, menu buttons still does nothing", "pause wont
    -- unpause"). Drive the GUI and the mission directly instead, the way the
    -- shop key already does, so open and close are the same key.
    -- PAUSE IS GONE, and could not have worked. Pausing halts the mission update,
    -- so the mod stops ticking and the pipe closes: the unpause press is never
    -- heard, and telemetry dies for the whole deck until you unpause in-game.
    -- Kept as an alias to the cycle so an old profile does not have a dead key.
    pause      = function() return cycleTimeScale() end,
    timeCycle  = function() return cycleTimeScale() end,
    menu       = function() return toggleInGameMenu() end,
    screenshot = function(v) return raiseAny(v, "TAKE_SCREENSHOT") end,
    mapToggle  = function(v) return raiseAny(v, "TOGGLE_MAP") end,
    mapSize    = function(v) return raiseAny(v, "TOGGLE_MAP_SIZE") end,
    helpToggle = function(v) return raiseAny(v, "TOGGLE_HELP_TEXT") end,

    -- RADIO
    radioToggle = function(v) return raiseAny(v, "RADIO_TOGGLE") end,
    radioNext   = function(v) return raiseAny(v, "RADIO_NEXT_ITEM") end,
    radioPrev   = function(v) return raiseAny(v, "RADIO_PREVIOUS_ITEM") end,
    radioChannel= function(v) return raiseAny(v, "RADIO_NEXT_CHANNEL") end,

    -- MENU drill-downs (no vehicle needed; see NO_VEHICLE below)
    openCalendar = function() return openMenuPage("pageCalendar") end,
    openAnimals = function(_, _, arg)
        return openFocusedPage("pageAnimals", { "list" },
            { "husbandries", "clusters", "animalItems", "items" }, arg, "openAnimals")
    end,
    openContracts = function(_, _, arg)
        return openFocusedPage("pageContracts", { "contractsList" },
            { "contracts", "missions", "sortedContracts", "contractsToShow", "items" }, arg, "openContracts")
    end,
    openProduction = function(_, _, arg) return openProductionPage(arg) end,
    openMap = function() return openMenuPage("pageMapOverview") end,
    openStats = function() return openMenuPage("pageStatistics") end,
    openPrices = function(_, _, arg) return openPricesPage(arg) end,
    -- The shop is its own top-level GUI, not a page of InGameMenu (VERIFIED:
    -- g_gui.guis holds both "InGameMenu" and "ShopMenu"), so it needs its own
    -- open rather than goToPage.
    openShop = function()
        local ok = false
        pcall(function()
            if g_gui == nil or g_gui.guis == nil or g_gui.guis["ShopMenu"] == nil then return end
            local isOpen = false
            pcall(function() isOpen = (g_gui.currentGuiName == "ShopMenu") end)
            if isOpen then g_gui:showGui("") else g_gui:showGui("ShopMenu") end
            ok = true
        end)
        return ok
    end,
}

--- Commands a dial can emit many times per second.
local HIGH_RATE = { axis = true, cruiseSet = true, cruiseSpeed = true }

--- Commands that act on the game/UI rather than a vehicle, so they must still
--- work on foot (otherwise a telemetry key would be dead outside a cab).
local NO_VEHICLE = {
    openCalendar = true, openAnimals = true, openContracts = true,
    openProduction = true, openMap = true, openStats = true, openShop = true,
    -- reads the store manager, not the player, so it must not need a cab
    dumpCategories = true,
    -- entering a vehicle is exactly a thing you do while on foot
    enterVehicle = true,
    -- must run on foot too: the player's own actions exist only out of the cab
    dumpActions = true,
    dumpFillTypes = true,
    -- menu commands are UI, not vehicle actions
    dumpMenu = true, openPrices = true,
    -- On-foot and session actions. These are registered globally, so requiring a
    -- vehicle would make the whole ON-FOOT page dead the moment you step out.
    handtoolCycle = true, handtoolToggle = true, handtoolPress = true, handtoolRelease = true, buildMode = true, flashlight = true,
    timeUp = true, timeDown = true, timeCycle = true, pause = true, menu = true, screenshot = true,
    mapToggle = true, mapSize = true, helpToggle = true,
    radioToggle = true, radioNext = true, radioPrev = true, radioChannel = true,
    switchVehicle = true, switchVehicleBack = true, enterExit = true,
}

--- Execute a command table { name, value }. Logs the outcome once.
function FarmHandCommands.execute(cmd)
    if cmd == nil or cmd.name == nil then return end
    local handler = HANDLERS[cmd.name]
    if handler == nil then
        log("unknown command '%s'", tostring(cmd.name))
        return
    end
    local v = getControlled()
    if v == nil and not NO_VEHICLE[cmd.name] then
        log("command '%s' ignored: not in a vehicle", cmd.name)
        return
    end
    local ok, result = pcall(handler, v, cmd.value, cmd.arg)
    if not ok then
        log("command '%s' errored: %s", cmd.name, tostring(result))
    elseif result == false then
        log("command '%s' had no effect (no direct fn or action)", cmd.name)
    elseif not HIGH_RATE[cmd.name] then
        -- Success is logged for one-shot commands only. A dial sends a command
        -- per tick, so "ok" on every one would flood the player's log during
        -- ordinary use. Failures always log, at any rate.
        log("command '%s' ok", cmd.name)
    end
end

-- ---------------------------------------------------------------- capability
--
-- What this machine can ACTUALLY do, as JSON for the frame.
--
-- The deck was offering keys the machine cannot perform - cut length on a
-- grapple excavator, unload on a forage harvester that has no tank to empty -
-- and the player has no way to tell "unsupported" from "broken" (in-game,
-- 3 Aug: "would it not make sense to check the current vehicle and what its
-- capabilities are before presenting actions for it?").
--
-- Two kinds of answer, because commands come in two kinds:
--   actions  every input action name registered on the machine or its
--            implements. Covers every command that raises an action.
--   canTip   commands that call game FUNCTIONS rather than raise actions need
--            their own probe; unload is the one that matters.
--
-- Cached per vehicle: the walk touches every spec_ table, which is why the
-- joints lookup is cached the same way.
--
-- But NOT cached forever, which is what it used to do, and which was wrong in
-- the most misleading possible way. FS registers a spec's action events as you
-- enter the machine and as implements attach - not at load - so the first frame
-- after entering sees a PARTIAL list. Caching that snapshot for the life of the
-- vehicle meant the deck dimmed keys that work: the log said
--   dimmed "cutLength" - Volvo EC250DL has no TOGGLE_CUT_LENGTH_BACK
-- while the very same machine's own log said
--   CMD 'TOGGLE_CUT_LENGTH_BACK': entry located in spec_woodHarvester ... ok
-- Both true, half a second apart (in-game, 3 Aug: "nothing is dimming" - the
-- wrong things were).
--
-- So the cache is keyed on how many action events are registered right now.
-- Counting is a fraction of the cost of resolving every name, sorting and
-- building the string, and it catches both causes of change: late spec
-- registration, and attaching or dropping an implement.
local capsCache = setmetatable({}, { __mode = "k" })

local function actionEventCount(v)
    local n = 0
    pcall(function()
        for _, obj in ipairs(candidates(v)) do
            for specName, spec in pairs(obj) do
                if type(specName) == "string" and specName:sub(1, 5) == "spec_" and type(spec) == "table" then
                    for _ in pairs(spec.actionEvents or {}) do n = n + 1 end
                end
            end
        end
    end)
    return n
end

function FarmHandCommands.capabilitiesJson(v)
    if v == nil then return "null" end
    local sig = actionEventCount(v)
    local cached = capsCache[v]
    if cached ~= nil and cached.sig == sig then return cached.json end
    if cached ~= nil then
        log("CAPS recount %d -> %d action events, rebuilding", cached.sig, sig)
    end

    local names, seen, labels = {}, {}, {}
    pcall(function()
        for _, obj in ipairs(candidates(v)) do
            for specName, spec in pairs(obj) do
                if type(specName) == "string" and specName:sub(1, 5) == "spec_" and type(spec) == "table" then
                    for _, entry in pairs(spec.actionEvents or {}) do
                        local ok, n = pcall(entryActionName, entry)
                        if ok and type(n) == "string" and not seen[n] then
                            seen[n] = true
                            names[#names + 1] = n
                            -- DIAGNOSTIC: is there a real name behind the generic
                            -- "Function 1/2/3" keys? Logged for the extras only,
                            -- plus a couple of knowns as a CONTROL - if DETACH
                            -- also reports "(none)" then the field is simply not
                            -- populated here and the answer is no, rather than
                            -- the extras being special. A null result needs a
                            -- control test.
                            -- The generic "Function 1/2/3" keys are the reason
                            -- this is here: what an extra DOES is entirely
                            -- machine-defined, and FS knows the answer - it is
                            -- the text in its own F1 help bar. Verified 3 Sep
                            -- 2026 on a John Deere 1270G: "Turn on tree
                            -- harvester", "Fold tree harvester", "Change cut
                            -- length (5.0m)". Only the extras: every other key
                            -- has a name that is true on every machine.
                            if n:sub(1, 15) == "IMPLEMENT_EXTRA" then
                                local ok2, t = pcall(entryDisplayText, entry)
                                if ok2 and t ~= nil then labels[n] = t end
                                noteDisplayText(n, ok2 and t or nil)
                            end
                        end
                    end
                end
            end
        end
    end)
    table.sort(names)

    local canTip = false
    pcall(function()
        for _, obj in ipairs(candidates(v)) do
            if type(obj.getTipState) == "function" and type(obj.startTipping) == "function" then
                canTip = true
                break
            end
        end
    end)

    local quoted = {}
    for i, n in ipairs(names) do quoted[i] = '"' .. n .. '"' end
    -- What the game itself calls each extra, so the deck can stop saying
    -- "Function 1". Absent on a machine with no extras, and absent entirely from
    -- an older mod - the plugin must treat a missing map as "no idea", not as
    -- "no label", or every extra key goes blank on a multiplayer host running
    -- an older copy.
    local lbl = {}
    for n, t in pairs(labels) do
        lbl[#lbl + 1] = string.format('"%s":"%s"', n, jsonEsc(t))
    end
    table.sort(lbl)
    local json = string.format('{"actions":[%s],"canTip":%s,"labels":{%s}}',
        table.concat(quoted, ","), tostring(canTip), table.concat(lbl, ","))
    capsCache[v] = { sig = sig, json = json }
    return json
end

-- ---------------------------------------------------------------------------
-- LIVE STATE, for keys that should name the action they will PERFORM.
--
-- In-game, 3 Aug: "for 'lower' action, is it possible to detect its status and
-- switch to 'raise'? same logic with pipe in/out. Start/Stop Tool would be good.
-- Lights on/off if possible."
--
-- Deliberately NOT cached, unlike capabilitiesJson: capabilities are a property
-- of the machine and never change, state is the whole point and changes every
-- frame. Runs at the 4 Hz frame rate over the vehicle plus its direct
-- implements, which is a handful of field reads.
--
-- Every field is TRISTATE: true, false, or null meaning "this machine has no
-- such thing". The deck must render null as the neutral name ("Lower/Raise"),
-- never as false, or a machine with no pipe would sit there advertising "Pipe
-- out" forever.
--
-- Each probe is logged ONCE per session with the raw values behind it. Five API
-- guesses shipped blind is how the last three rounds of this went; the log means
-- one glance at a real machine settles which paths are actually there.
-- ---------------------------------------------------------------------------

-- tostring(nil) is "nil", which is not JSON and would land in the plugin as a
-- parse failure for the WHOLE frame - one machine with no pipe killing every
-- readout on the deck.
local function jbool(b)
    if b == nil then return "null" end
    return tostring(b == true)
end

local steeringSpecDumped = false
local aiModeDumped = false
local lastAiMode = nil
local statePathLogged = {}
local function noteStatePath(what, detail)
    if statePathLogged[what] then return end
    statePathLogged[what] = true
    log("STATE '%s' resolved via %s", what, detail)
end

--- OR across the machine and its implements; nil unless at least one HAS the thing.
local function anyTrue(v, probe)
    local result = nil
    for _, obj in ipairs(candidates(v)) do
        pcall(function()
            local got = probe(obj)
            if got ~= nil then
                if result == nil then result = false end
                if got == true then result = true end
            end
        end)
    end
    return result
end

function FarmHandCommands.stateJson(v)
    if v == nil then return "null" end

    -- LOWERED: implements answer this, the tractor does not.
    local lowered = anyTrue(v, function(o)
        if type(o.getIsLowered) ~= "function" then return nil end
        noteStatePath("lowered", "getIsLowered()")
        return o:getIsLowered() == true
    end)

    -- TOOL RUNNING.
    local on = anyTrue(v, function(o)
        if type(o.getIsTurnedOn) ~= "function" then return nil end
        noteStatePath("on", "getIsTurnedOn()")
        return o:getIsTurnedOn() == true
    end)

    -- FOLDED. True only when EVERY foldable is folded in, because that is when
    -- the key will unfold: FS folds all of them together.
    local anyFoldable, allFolded = false, true
    for _, obj in ipairs(candidates(v)) do
        pcall(function()
            if obj.spec_foldable == nil then return end
            anyFoldable = true
            local isUnfolded = nil
            if type(obj.getIsUnfolded) == "function" then
                isUnfolded = obj:getIsUnfolded() == true
                noteStatePath("folded", "getIsUnfolded()")
            else
                -- Fallback: the anim sits at one end of its travel. Which end is
                -- "in" depends on foldMoveDirection, so read the direction too
                -- rather than assuming 0 == folded.
                local sp = obj.spec_foldable
                local t, dir = sp.foldAnimTime, sp.foldMoveDirection
                if type(t) == "number" then
                    isUnfolded = (type(dir) == "number" and dir < 0) and (t < 0.5) or (t > 0.5)
                    noteStatePath("folded", string.format("spec_foldable.foldAnimTime=%.2f dir=%s", t, tostring(dir)))
                end
            end
            if isUnfolded == true then allFolded = false end
        end)
    end
    -- written long-hand: `anyFoldable and allFolded or nil` silently collapses
    -- the false case back to nil, which reads as "no fold on this machine".
    local folded = nil
    if anyFoldable then folded = allFolded end

    -- PIPE. State 1 is stowed; anything above it is on the way out or out.
    local pipe = nil
    for _, obj in ipairs(candidates(v)) do
        pcall(function()
            local sp = obj.spec_pipe
            if sp == nil or type(sp.currentState) ~= "number" then return end
            pipe = sp.currentState > 1
            noteStatePath("pipe", string.format("spec_pipe.currentState=%d target=%s",
                sp.currentState, tostring(sp.targetState)))
        end)
        if pipe ~= nil then break end
    end

    -- STEERING ASSIST: dump the spec ONCE so we stop guessing at its shape.
    --
    -- getAIAutomaticSteeringEnabled does not exist - stateJson reported
    -- "steering":null and the resolver never fired (verified 4 Aug), which is
    -- also why steeringToggle falls through to raising TOGGLE_AI_STEERING. The
    -- spec itself IS present (spec_aiAutomaticSteering appears in the game log),
    -- so the state is in there under a name we have not guessed yet.
    --
    -- In-game testing also found the reason a guess would have misled us: FS25 has a MODE
    -- choice, AI Worker vs Steering Assist. In AI Worker mode the assist audibly
    -- turns on and straight back off, so ANY field we picked would have read
    -- false in that mode and true in the other - and a wrong field would look
    -- exactly like a correct one until someone switched modes.
    pcall(function()
        if steeringSpecDumped then return end
        for _, obj in ipairs(candidates(v)) do
            local sp = obj.spec_aiAutomaticSteering
            if type(sp) == "table" then
                steeringSpecDumped = true
                local bits = {}
                for k, val in pairs(sp) do
                    local t = type(val)
                    if t == "boolean" or t == "number" or t == "string" then
                        bits[#bits + 1] = string.format("%s=%s(%s)", tostring(k), tostring(val), t)
                    elseif t == "function" then
                        bits[#bits + 1] = tostring(k) .. "()"
                    end
                end
                table.sort(bits)
                log("STEERING spec_aiAutomaticSteering: %s", table.concat(bits, ", "))
                -- and any steering-ish function on the vehicle itself
                local fns = {}
                for k, val in pairs(obj) do
                    if type(k) == "string" and type(val) == "function"
                       and string.find(string.lower(k), "steering") then
                        fns[#fns + 1] = k
                    end
                end
                table.sort(fns)
                log("STEERING vehicle functions: %s", (#fns > 0) and table.concat(fns, ", ") or "(none)")
                break
            end
        end
    end)

    -- AI MODE: log the VALUE every time it changes.
    --
    -- getAIModeSelection / setAIModeSelection both exist (4 Aug dump), so a mode
    -- key is possible - but the enum they use is unknown, and guessing it is how
    -- you ship a key that puts the player in the wrong mode. Logging on CHANGE
    -- rather than once means a single session where the mode is flipped yields
    -- both values, instead of one value per reload.
    pcall(function()
        if type(v.getAIModeSelection) ~= "function" then return end
        local cur = v:getAIModeSelection()
        if cur ~= lastAiMode then
            log("AIMODE getAIModeSelection() = %s (%s)", tostring(cur), type(cur))
            lastAiMode = cur
        end
    end)

    -- ONE-TIME HUNT for the AI MODE selector.
    --
    -- FS25 makes the player choose AI Worker vs Steering Assist (l10n has
    -- ai_modeWorker and ai_modeSteeringAssist), and the profile wants a key for it -
    -- reasonable, since the mode decides whether the Steer key can work at all.
    -- But NO global input action switches it: the only AI actions registered are
    -- TOGGLE_AI, TOGGLE_AI_STEERING and TOGGLE_AI_STEERING_LINES, so it is not a
    -- bindable command and there is nothing to raise.
    --
    -- So look for it as state. Dumps anything mode-ish on the vehicle and on
    -- g_currentMission, once, rather than shipping a guess at a setter - the
    -- lesson from steeringEnabled, which took one dump and no guesses.
    pcall(function()
        if aiModeDumped then return end
        aiModeDumped = true
        local hits = {}
        local function scan(tbl, label)
            if type(tbl) ~= "table" then return end
            for k, val in pairs(tbl) do
                if type(k) == "string" and string.find(string.lower(k), "mode") then
                    local t = type(val)
                    if t == "function" then hits[#hits + 1] = label .. "." .. k .. "()"
                    elseif t == "boolean" or t == "number" or t == "string" then
                        hits[#hits + 1] = string.format("%s.%s=%s", label, k, tostring(val))
                    end
                end
            end
        end
        scan(v, "vehicle")
        pcall(function() scan(g_currentMission, "mission") end)
        pcall(function() scan(v.spec_aiJobVehicle, "spec_aiJobVehicle") end)
        pcall(function() scan(v.spec_aiFieldWorker, "spec_aiFieldWorker") end)
        table.sort(hits)
        log("AIMODE candidates: %s", (#hits > 0) and table.concat(hits, ", ") or "(nothing named *mode*)")
        -- the enum itself, if FS exposes one as a global
        for _, name in ipairs({ "AIModeSelection", "AIMode", "AIModeType" }) do
            local g = _G[name]
            if type(g) == "table" then
                local kv = {}
                for k, val in pairs(g) do
                    if type(k) == "string" then kv[#kv + 1] = k .. "=" .. tostring(val) end
                end
                table.sort(kv)
                log("AIMODE enum %s: %s", name, table.concat(kv, ", "))
                -- the two sub-tables carry the numbers and the display strings;
                -- with those the key can label itself in the game's own words
                for _, sub in ipairs({ "MODE", "MODE_TEXTS" }) do
                    if type(g[sub]) == "table" then
                        local parts = {}
                        for k2, v2 in pairs(g[sub]) do
                            parts[#parts + 1] = tostring(k2) .. "=" .. tostring(v2)
                        end
                        table.sort(parts)
                        log("AIMODE %s.%s: %s", name, sub, table.concat(parts, ", "))
                    end
                end
            end
        end
    end)

    -- STEERING ASSIST: state AND whether it is even allowed right now.
    --
    -- Both names come from the 4 Aug spec dump, not from guesswork:
    --   spec_aiAutomaticSteering.steeringEnabled  - boolean, the actual state
    --   getIsAIAutomaticSteeringAllowed()         - can it engage at all
    --
    -- The getter I originally assumed - getAIAutomaticSteeringEnabled - simply
    -- does not exist. The SETTER does, which is why the old code tested for both
    -- and silently fell through to raising the input action.
    --
    -- `allowed` is the more valuable half. FS25 makes the player choose between
    -- AI Worker mode and Steering Assist mode, and in AI Worker mode the assist
    -- turns on and immediately off again (in-game, 4 Aug) - a key that beeps and
    -- does nothing, with no way to know why. Reporting it lets the deck dim the
    -- key in the mode where it cannot work, which explains the situation instead
    -- of leaving the player to discover it.
    local aiMode = nil
    pcall(function()
        if type(v.getAIModeSelection) == "function" then
            local m = tonumber(v:getAIModeSelection())
            if m ~= nil then aiMode = m end
        end
    end)

    local steering, steeringAllowed = nil, nil
    for _, obj in ipairs(candidates(v)) do
        pcall(function()
            local sp = obj.spec_aiAutomaticSteering
            if type(sp) == "table" and type(sp.steeringEnabled) == "boolean" then
                steering = sp.steeringEnabled
                noteStatePath("steering", "spec_aiAutomaticSteering.steeringEnabled")
            end
            if type(obj.getIsAIAutomaticSteeringAllowed) == "function" then
                steeringAllowed = obj:getIsAIAutomaticSteeringAllowed() == true
                noteStatePath("steeringAllowed", "getIsAIAutomaticSteeringAllowed()")
            end
        end)
        if steering ~= nil then break end
    end

    -- LIGHTS: the mask is non-zero when any light type is lit.
    local lights = nil
    for _, obj in ipairs(candidates(v)) do
        pcall(function()
            local sp = obj.spec_lights
            if sp == nil or type(sp.lightsTypesMask) ~= "number" then return end
            lights = sp.lightsTypesMask ~= 0
            noteStatePath("lights", string.format("spec_lights.lightsTypesMask=%d", sp.lightsTypesMask))
        end)
        if lights ~= nil then break end
    end

    return string.format(
        '{"lowered":%s,"on":%s,"folded":%s,"pipe":%s,"lights":%s,"steering":%s,' ..
        '"steeringAllowed":%s,"aiMode":%s}',
        jbool(lowered), jbool(on), jbool(folded), jbool(pipe), jbool(lights),
        jbool(steering), jbool(steeringAllowed),
        (aiMode ~= nil) and string.format("%d", aiMode) or "null")
end
