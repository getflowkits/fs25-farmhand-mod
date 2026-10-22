-- FarmHand Telemetry :: Collectors
--
-- Every accessor here was verified in-game against FS25 v1.20 on 20 Jul 2026.
-- See profile-specs/Farming Simulator 25/fs25-telemetry-api-verified.md.
-- Where a widely-cited API does NOT exist, the comment says so, because the
-- community docs are wrong on several of these.

FarmHandCollectors = {}

-- ---------------------------------------------------------------- helpers

-- VERIFIED 23 Jul: some fill units report an INFINITE capacity (a forage
-- harvester has no tank, it blows straight out the pipe; the Katana's discharge
-- and some tools do this). string.format("%.0f", inf) emits the literal "inf",
-- which is INVALID JSON, so the whole frame fails to parse on the plugin side
-- and is dropped - starving the connection into a stale-timeout. Every number
-- that reaches the JSON goes through here, so this is the one place to guarantee
-- finiteness. NaN fails the v == v test; +/-inf fail the huge tests.
local HUGE = math.huge
local function num(v, d)
    if type(v) == "number" and v == v and v ~= HUGE and v ~= -HUGE then return v end
    return d or 0
end

--- Say ONCE, at 4 Hz, whether an optional part of the frame made it in.
--
-- The collector runs inside pcall so a throw costs a field and no message. That
-- turns "the mod is too old", "the call threw" and "it worked" into the same
-- observable thing: a key that never updates. This makes them different, once
-- per distinct message, so a 4 Hz loop cannot flood the log.
local notedState = {}
function FarmHandCollectors.noteStateOnce(msg)
    if notedState[msg] then return end
    notedState[msg] = true
    print("[FarmHand] STATE " .. tostring(msg))
end

--- Append `"<key>":<json>` from FarmHandCommands.<fn>(v), isolated and audible.
--
-- Commands.lua loads AFTER this file, so the function is looked up at call time
-- rather than captured. Each field gets its own pcall so one failure cannot take
-- the others down with it, and each outcome - missing, threw, ok - is logged
-- once so they stop being indistinguishable from each other.
local function addOptional(p, key, v, fnName)
    local fn = FarmHandCommands ~= nil and FarmHandCommands[fnName] or nil
    if type(fn) ~= "function" then
        FarmHandCollectors.noteStateOnce(fnName .. " MISSING - stale Commands.lua?")
        return
    end
    local ok, js = pcall(fn, v)
    if not ok then
        FarmHandCollectors.noteStateOnce(fnName .. " THREW: " .. tostring(js))
        return
    end
    p[#p + 1] = '"' .. key .. '":' .. js
    -- 160 is plenty for a state blob and useless for capabilities: a machine
    -- registers dozens of actions and the interesting ones are never in the
    -- first 160 characters, so every capabilities line in the log was cut off
    -- before it said anything (3 Sep 2026). Deduped per distinct message, so a
    -- longer line still costs ONE line per distinct machine.
    local cap = fnName == "capabilitiesJson" and 1200 or 160
    FarmHandCollectors.noteStateOnce(fnName .. " ok -> " .. string.sub(tostring(js), 1, cap))
end

--- JSON string escape. Vehicle and field names are user/mod supplied.
--- Any other control character (a tab in a mod's store name, a stray byte in a
--- localised mission description) is not legal inside a JSON string either, so
--- it becomes a space: one bad name must not fail the parse for the whole frame.
local function esc(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " "):gsub("\r", ""):gsub("%c", " ")
    return s
end

FarmHandCollectors.esc = esc
FarmHandCollectors.num = num




--- Resolve a fillType index to its name.
--- VERIFIED: "UNKNOWN" means the container is EMPTY, not a lookup failure.
function FarmHandCollectors.fillTypeName(index)
    local name = "EMPTY"
    pcall(function()
        local ft = g_fillTypeManager:getFillTypeByIndex(index)
        if ft ~= nil and ft.name ~= nil and ft.name ~= "UNKNOWN" then name = ft.name end
    end)
    return name
end

--- VERIFIED: getFullName() appends "(AI worker H)" when a worker is hired.
--- Strip for identity; the letter is a useful worker label.
function FarmHandCollectors.splitWorkerName(fullName)
    local base, worker = tostring(fullName):match("^(.-)%s*%(AI worker ([A-Z])%)%s*$")
    if base ~= nil then return base, worker end
    return fullName, nil
end

--- VERIFIED: store categoryName is the ONLY reliable class signal.
--- typeName reports wheel loaders as "tractor"; spec_cylindered matches
--- literally every vehicle. Do not use either for class detection.
---
--- Cached per vehicle: a machine's store entry never changes, and the fleet
--- (2 s), the active vehicle (4 Hz) and the widget's frames all ask, so the
--- store manager was searched for every vehicle on every fleet tick. An entry
--- holds the config file it was read for, so a vehicle object reused for
--- another config re-reads; the keys are weak, so a removed vehicle drops out;
--- and resetCaches empties it when the save or the farm changes. A lookup made
--- before the store manager is up is not cached.
local categoryCache = setmetatable({}, { __mode = "k" })

function FarmHandCollectors.storeCategory(vehicle)
    if type(vehicle) ~= "table" then return nil end
    local hit = categoryCache[vehicle]
    if hit ~= nil and hit.config == vehicle.configFileName then return hit.cat or nil end
    local cat, looked = nil, false
    pcall(function()
        if vehicle.configFileName == nil or g_storeManager == nil then return end
        local item = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
        looked = true
        if item ~= nil and item.categoryName ~= nil then cat = tostring(item.categoryName) end
    end)
    if looked then categoryCache[vehicle] = { config = vehicle.configFileName, cat = cat or false } end
    return cat
end

--- Empty the per-vehicle caches (mission end, farm change).
function FarmHandCollectors.resetCaches()
    categoryCache = setmetatable({}, { __mode = "k" })
end

local LOADER_CATEGORIES = {
    FRONTLOADERVEHICLES = true,
    WHEELLOADERVEHICLES = true,
    TELELOADERVEHICLES = true,
    FORKLIFTS = true,
    SKIDSTEERVEHICLES = true,
}

--- Store categories that are CARGO, not fleet. Pallets and big bags are
--- Vehicle instances in FS25 and otherwise pass every "is it a machine" test.
local CARGO_CATEGORIES = {
    PALLETS = true,
    BIGBAGS = true,
    BALES = true,
    BIGBAGPALLETS = true,
}

function FarmHandCollectors.isLoader(categoryName)
    return categoryName ~= nil and LOADER_CATEGORIES[categoryName] == true
end

-- ---------------------------------------------------------------- vehicle

--- Fill units for a vehicle or implement, resolved by TYPE NAME.
--- VERIFIED: indices are NOT consistent across vehicles (combine grain tank is
--- index 1, tractor fuel is index 1). Never key off index.
--- What an EMPTY unit is FOR. An empty tank reports fill type UNKNOWN, so
--- without this a drained sprayer is indistinguishable from no tank at all -
--- exactly the state the driver most needs to see before leaving the yard.
--- Only sent for empty units (the name alone identifies a filled one), capped
--- so a combine's all-crops grain tank cannot bloat the payload.
local function supportedTypesJson(obj, i)
    local names = {}
    pcall(function()
        local sup = obj:getFillUnitSupportedFillTypes(i)
        if sup == nil then return end
        for idx, on in pairs(sup) do
            if on then
                local n = FarmHandCollectors.fillTypeName(idx)
                if n ~= "EMPTY" then names[#names + 1] = n end
                if #names >= 12 then break end
            end
        end
    end)
    table.sort(names)
    for k = 1, #names do names[k] = '"' .. esc(names[k]) .. '"' end
    return "[" .. table.concat(names, ",") .. "]"
end

local function fillsJson(obj)
    if type(obj.getFillUnits) ~= "function" then return "[]" end
    local out = {}
    pcall(function()
        local units = obj:getFillUnits()
        if units == nil then return end
        for i = 1, #units do
            local cap = num(obj:getFillUnitCapacity(i))
            if cap > 0 then
                local tname = FarmHandCollectors.fillTypeName(obj:getFillUnitFillType(i))
                local types = tname == "EMPTY" and (',"types":' .. supportedTypesJson(obj, i)) or ""
                out[#out + 1] = string.format('{"type":"%s","lvl":%.0f,"cap":%.0f%s}',
                    esc(tname), num(obj:getFillUnitFillLevel(i)), cap, types)
            end
        end
    end)
    return "[" .. table.concat(out, ",") .. "]"
end

FarmHandCollectors.fillsJson = fillsJson

--- The vehicle the player is currently controlling, in detail. High frequency.
function FarmHandCollectors.activeVehicle()
    local v = nil
    pcall(function() v = g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil end)
    if v == nil then pcall(function() v = g_currentMission.controlledVehicle end) end
    if v == nil then return nil end

    local p = {}
    local function add(k, val) p[#p + 1] = string.format('"%s":%s', k, val) end
    local function addS(k, val) p[#p + 1] = string.format('"%s":"%s"', k, esc(val)) end

    local rawName = "?"
    pcall(function() rawName = v:getFullName() end)
    local baseName, worker = FarmHandCollectors.splitWorkerName(rawName)
    addS("name", baseName)
    if worker ~= nil then addS("worker", worker) end

    local cat = FarmHandCollectors.storeCategory(v)
    if cat ~= nil then
        addS("category", cat)
        add("isLoader", tostring(FarmHandCollectors.isLoader(cat)))
    end
    pcall(function() if v.typeName ~= nil then addS("typeName", v.typeName) end end)

    pcall(function() add("speed", string.format("%.1f", num(v:getLastSpeed()))) end)
    pcall(function() add("motorOn", tostring(v:getIsMotorStarted() == true)) end)
    pcall(function() add("aiActive", tostring(v:getIsAIActive() == true)) end)

    -- VERIFIED: cruiseControl.speed holds a STALE target when state == 0.
    pcall(function()
        local cc = v.spec_drivable ~= nil and v.spec_drivable.cruiseControl or nil
        if cc ~= nil then
            local state = num(cc.state)
            add("cruiseState", state)
            if state > 0 then add("cruiseSpeed", string.format("%.0f", num(cc.speed))) end
        end
    end)

    -- VERIFIED: getLastRealMotorRpm() DOES NOT EXIST in FS25.
    -- getMotorRpmPercentage() does, but is unclamped (-0.36 idle, 1.02 load).
    pcall(function()
        if type(v.getMotorRpmPercentage) == "function" then
            local r = num(v:getMotorRpmPercentage())
            if r < 0 then r = 0 elseif r > 1 then r = 1 end
            add("rpmPct", string.format("%.3f", r))
        end
    end)

    pcall(function()
        local sm = v.spec_motorized
        if sm ~= nil then
            if sm.motorTemperature ~= nil then
                add("motorTemp", string.format("%.1f", num(sm.motorTemperature.value)))
            end
            if sm.actualLoadPercentage ~= nil then
                add("loadPct", string.format("%.3f", num(sm.actualLoadPercentage)))
            end
        end
    end)

    pcall(function()
        if type(v.getDamageAmount) == "function" then add("damage", string.format("%.3f", num(v:getDamageAmount()))) end
        if type(v.getDirtAmount) == "function" then add("dirt", string.format("%.3f", num(v:getDirtAmount()))) end
        if type(v.getIsOnField) == "function" then add("onField", tostring(v:getIsOnField() == true)) end
    end)

    p[#p + 1] = '"fills":' .. fillsJson(v)

    -- Which joint slots this machine actually has, so the Joint dial can say
    -- "not on this machine" instead of moving nothing, and can name the slot in
    -- the game's own words. Commands.lua loads after this file, so the function
    -- is looked up at call time.
    -- ONE pcall EACH, and each one says what happened.
    --
    -- These three used to share a single pcall. That made a throw in the FIRST
    -- of them silently delete the other two from the frame, with no message
    -- anywhere - so "the mod is too old", "the call threw" and "it worked" all
    -- looked identical from the deck: a key that never changes. Three separate
    -- bugs this build hid behind exactly that, so the shared pcall is gone and
    -- every optional field reports itself once (3 Aug).
    addOptional(p, "joints", v, "jointsJson")
    -- what this machine can actually do, so the deck can dim what it cannot
    addOptional(p, "caps", v, "capabilitiesJson")
    -- what it is doing RIGHT NOW, so a key can name the action it will perform
    -- ("Raise" when the tool is down) instead of a both-ways label
    addOptional(p, "state", v, "stateJson")

    -- attached implements drive FIELD-page auto-targeting and tank readouts
    pcall(function()
        if type(v.getAttachedImplements) ~= "function" then return end
        local imps = v:getAttachedImplements()
        if imps == nil then return end
        local out = {}
        for _, imp in ipairs(imps) do
            local o = imp.object
            if o ~= nil then
                local iName, iType, lowered, on = "?", "?", "null", "null"
                pcall(function() iName = o:getFullName() end)
                pcall(function() if o.typeName ~= nil then iType = o.typeName end end)
                pcall(function() if type(o.getIsLowered) == "function" then lowered = tostring(o:getIsLowered() == true) end end)
                pcall(function() if type(o.getIsTurnedOn) == "function" then on = tostring(o:getIsTurnedOn() == true) end end)
                -- Store category as well as typeName: the profile decides FIELD
                -- vs DRIVE from what is hitched, and typeName is not trustworthy
                -- for class (it calls wheel loaders "tractor").
                local iCat = FarmHandCollectors.storeCategory(o) or ""
                out[#out + 1] = string.format('{"name":"%s","type":"%s","category":"%s","lowered":%s,"on":%s,"fills":%s}',
                    esc(iName), esc(iType), esc(iCat), lowered, on, fillsJson(o))
            end
        end
        p[#p + 1] = '"implements":[' .. table.concat(out, ",") .. "]"
    end)

    pcall(function()
        add("isCombine", tostring(v.spec_combine ~= nil))
        add("isWoodHarvester", tostring(v.spec_woodHarvester ~= nil))
        add("hasPipe", tostring(v.spec_pipe ~= nil))
    end)

    return "{" .. table.concat(p, ",") .. "}"
end

-- ---------------------------------------------------------------- fleet

--- Everything the farm owns that is worth checking on. Powers the Galleon fleet
--- strip and the fleet browser dial.
--- VERIFIED: implements enumerate in the same collection as vehicles, and so do
--- PALLETS and BALES, which are Vehicle instances in FS25. We keep anything
--- DRIVABLE (has getIsMotorStarted) or ATTACHABLE (trailers, tankers, tools),
--- minus anything whose store category says it is cargo. A "has a fill unit"
--- test alone put seed pallets in the fleet list; spec_attachable alone did not
--- fix it, because a pallet can be hitched to pallet forks.
--- Returns an OBJECT, not a bare array: `total` lets the UI say "+N more"
--- instead of silently hiding vehicles past the cap.

--- Full name without throwing on half-initialised vehicles.
local function rawFullName(v)
    local n = "?"
    pcall(function() n = v:getFullName() end)
    return n
end

function FarmHandCollectors.fleet(farmId, limit)
    local vehicles = nil
    pcall(function() vehicles = g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles end)
    if vehicles == nil then pcall(function() vehicles = g_currentMission.vehicles end) end
    if vehicles == nil then return '{"items":[],"total":0}' end

    local cap = limit or 32
    local out, total = {}, 0
    local cargoSkipped = 0
    for _, v in pairs(vehicles) do
        local owned = false
        pcall(function() owned = (v.ownerFarmId == farmId) end)
        if owned then
            local drivable = (type(v.getIsMotorStarted) == "function")

            -- VERIFIED 22 Jul: pallets are Vehicle instances in FS25, so a
            -- "has a fill unit" test alone lets seed/fertiliser pallets into the
            -- fleet list (observed: "Lizard Seeds, seeds 100%"). With the list
            -- capped, pallets can push REAL machines out and inflate the total.
            local attachable = false
            pcall(function() attachable = (v.spec_attachable ~= nil) end)

            -- ...and spec_attachable alone was NOT enough: pallets kept showing
            -- after that filter shipped, because a pallet can be attached to
            -- pallet forks and therefore carries the spec too.
            --
            -- Per the verified note at the top of this file, STORE CATEGORY is the
            -- only trustworthy class signal (typeName reports wheel loaders as
            -- "tractor"). Category leads; the type-name substring is a backstop
            -- for mod pallets that ship without a store entry.
            local typeName = ""
            pcall(function() typeName = tostring(v.typeName or "") end)
            local category = FarmHandCollectors.storeCategory(v) or ""
            local isCargo = CARGO_CATEGORIES[category:upper()] == true
            if not isCargo then
                local tn = typeName:lower()
                isCargo = (tn:find("pallet") ~= nil) or (tn:find("bigbag") ~= nil) or (tn:find("bale") ~= nil)
            end

            local carries = false
            pcall(function()
                if type(v.getFillUnits) == "function" then
                    local units = v:getFillUnits()
                    if units ~= nil then
                        for i = 1, #units do
                            if num(v:getFillUnitCapacity(i)) > 0 then carries = true; break end
                        end
                    end
                end
            end)

            -- Support diagnostic: log what we DROPPED and why, once per session.
            -- Only exclusions are printed, and only the first few: a working farm
            -- can own hundreds of pallets, and dumping every candidate would bury
            -- the player's log in our noise. "Why is my machine missing?" is the
            -- question this has to answer, and an exclusion line answers it.
            if isCargo then
                cargoSkipped = cargoSkipped + 1
                if not FarmHandCollectors.fleetDumped and cargoSkipped <= 8 then
                    print(string.format("[FlowKits] fleet: skipped %s (type=%s category=%s) as cargo, not a machine",
                        tostring(rawFullName(v)), typeName, category))
                end
            end

            -- A machine is something you drive or something you hitch. Anything
            -- else with a fill level is cargo, not fleet.
            if (drivable or attachable) and not isCargo then
                total = total + 1
                if #out < cap then
                    local rawName = "?"
                    pcall(function() rawName = v:getFullName() end)
                    local baseName, worker = FarmHandCollectors.splitWorkerName(rawName)
                    local bits = { string.format('"name":"%s"', esc(baseName)) }
                    if worker ~= nil then bits[#bits + 1] = string.format('"worker":"%s"', esc(worker)) end
                    -- Network object id, so the plugin can ask us to ENTER this
                    -- exact vehicle later (press the fleet dial -> jump into it).
                    -- The same id resolves back via NetworkUtil.getObject, the
                    -- pattern already used for AI-worker vehicle names.
                    pcall(function()
                        local id = NetworkUtil.getObjectId(v)
                        if id ~= nil then bits[#bits + 1] = string.format('"id":%d', num(id)) end
                    end)
                    -- tool = attachable with no capacity (plough, mower). It has
                    -- no fuel and no load, so only its WEAR is worth reporting.
                    local kind = drivable and "drivable" or (carries and "carrier" or "tool")
                    bits[#bits + 1] = string.format('"kind":"%s"', kind)
                    -- Category travels with the row so the plugin can tell a
                    -- seeder's empty tank ("no seed") from a trailer's, and can
                    -- recognise combine accessories.
                    if category ~= "" then bits[#bits + 1] = string.format('"category":"%s"', esc(category)) end
                    pcall(function() bits[#bits + 1] = string.format('"motorOn":%s', tostring(v:getIsMotorStarted() == true)) end)
                    pcall(function() bits[#bits + 1] = string.format('"aiActive":%s', tostring(v:getIsAIActive() == true)) end)
                    -- damage feeds the PROACTIVE warning: catch a machine before it
                    -- strands an AI worker mid-job, which is the real pain point
                    pcall(function()
                        if type(v.getDamageAmount) == "function" then
                            bits[#bits + 1] = string.format('"damage":%.3f', num(v:getDamageAmount()))
                        end
                    end)
                    bits[#bits + 1] = '"fills":' .. fillsJson(v)
                    out[#out + 1] = "{" .. table.concat(bits, ",") .. "}"
                end
            end
        end
    end
    if not FarmHandCollectors.fleetDumped then
        print(string.format("[FlowKits] fleet: %d machines, %d cargo items skipped", total, cargoSkipped))
        FarmHandCollectors.fleetDumped = true
    end
    return string.format('{"items":[%s],"total":%d}', table.concat(out, ","), total)
end

--- Is this the machine a worker drives, rather than something hitched to it?
---
--- In-game 22 Oct: a hitched cultivator (John Deere 980) answered
--- getIsAIActive() true alongside its tractor, so it was listed as a second
--- worker and raised its own stuck alert. Only the root of a vehicle train
--- carries the job. getRootVehicle() is the game's own answer (rootVehicle is
--- the field behind it); a vehicle that answers neither falls back to "does it
--- hold a job itself".
function FarmHandCollectors.isWorkerVehicle(v)
    local root = nil
    pcall(function() root = v:getRootVehicle() end)
    if root == nil then pcall(function() root = v.rootVehicle end) end
    if root ~= nil then return root == v end
    local job = nil
    pcall(function() job = v:getJob() end)
    return job ~= nil
end

--- Detect AI workers that are hired but making NO progress.
---
--- VERIFIED 22 Jul: FS fires no event whatsoever for a blocked or stuck worker.
--- It stays aiActive indefinitely while the player assumes work is happening —
--- the single most annoying AI failure, and the one the game tells you nothing
--- about. So we derive it: aiActive, but neither POSITION nor FILL LEVEL has
--- changed for `stuckMs`.
---
--- Fill is part of the test on purpose: a harvester can sit almost still while
--- genuinely working, but its tank keeps rising. Requiring BOTH to be static
--- avoids calling slow work "stuck".
---
--- `watch` is caller-owned state: vehicleKey -> {x, z, fill, since, alerted}.
--- Fires ONCE per stuck episode and re-arms only after the vehicle moves again.
function FarmHandCollectors.checkStuck(farmId, watch, nowMs, stuckMs)
    local out = {}
    local vehicles = nil
    pcall(function() vehicles = g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles end)
    if vehicles == nil then return out end

    local seen = {}
    for _, v in pairs(vehicles) do
        local owned, ai = false, false
        pcall(function() owned = (v.ownerFarmId == farmId) end)
        pcall(function() ai = (type(v.getIsAIActive) == "function") and v:getIsAIActive() == true end)

        if owned and ai and FarmHandCollectors.isWorkerVehicle(v) then
            local key = tostring(v.rootNode or v)
            seen[key] = true

            local x, z, fill = 0, 0, 0
            pcall(function()
                local wx, _, wz = getWorldTranslation(v.rootNode)
                x, z = wx, wz
            end)
            pcall(function()
                if type(v.getFillUnits) == "function" then
                    local units = v:getFillUnits()
                    if units ~= nil then
                        for i = 1, #units do fill = fill + num(v:getFillUnitFillLevel(i)) end
                    end
                end
            end)

            local w = watch[key]
            local moved = (w == nil)
                or math.abs(x - w.x) > 1.0
                or math.abs(z - w.z) > 1.0
                or math.abs(fill - w.fill) > 1.0

            if moved then
                watch[key] = { x = x, z = z, fill = fill, since = nowMs, alerted = false }
            else
                if not w.alerted and (nowMs - w.since) >= stuckMs then
                    w.alerted = true
                    local name = "?"
                    pcall(function() name = FarmHandCollectors.splitWorkerName(v:getFullName()) end)
                    out[#out + 1] = { name = name, secs = math.floor((nowMs - w.since) / 1000) }
                end
            end
        end
    end

    -- forget vehicles that are no longer working, so re-hiring starts clean
    for key in pairs(watch) do
        if not seen[key] then watch[key] = nil end
    end
    return out
end

-- ---------------------------------------------------------------- fields

--- Field the vehicle is standing on, with full soil state.
--- VERIFIED: getId() is a METHOD (f.fieldId does not exist). fieldState carries
--- far more than crop/growth: spray, lime, plough, weeds, stones, roller.
local function fieldJson(f)
    local bits = {}
    pcall(function() bits[#bits + 1] = string.format('"id":%d', num(f:getId())) end)
    pcall(function() bits[#bits + 1] = string.format('"areaHa":%.2f', num(f:getAreaHa())) end)
    pcall(function()
        local fl = f:getFarmland()
        if fl ~= nil then bits[#bits + 1] = string.format('"owned":%s', tostring(fl.isOwned == true)) end
    end)
    pcall(function()
        local st = f:getFieldState()
        if st == nil then return end
        if st.fruitTypeIndex ~= nil then
            local nm = g_fruitTypeManager:getFillTypeNameByFruitTypeIndex(st.fruitTypeIndex)
            if nm ~= nil then bits[#bits + 1] = string.format('"crop":"%s"', esc(nm)) end
            -- Crop status from the crop's OWN numbers, never a guessed threshold.
            -- VERIFIED 22 Jul across all 26 crops: these are discrete state IDs,
            -- not a timeline (POTATO harvest=9 sits ABOVE withered=7), so compare
            -- by equality/range and never infer decay from "growth > numStates".
            -- 21 of 26 crops have min==max, so READY is exact; the 5 with a range
            -- (GRAPE/OLIVE/SPINACH/GRASS/MEADOW) are harvestable across both.
            -- GRASS/MEADOW/POPLAR have witheredState=nil: they never wither.
            pcall(function()
                local ft = g_fruitTypeManager:getFruitTypeByIndex(st.fruitTypeIndex)
                local gs = st.growthState
                if ft == nil or gs == nil then return end
                local status = "GROWING"
                local minH, maxH = ft.minHarvestingGrowthState, ft.maxHarvestingGrowthState
                -- ANOMALY (verified): OILSEEDRADISH has witheredState == harvest
                -- state (both 2) and cutState 0. It is a cover crop you mulch
                -- rather than harvest, so the states genuinely overlap. Checking
                -- withered first would brand it WITHERED forever, so when the two
                -- collide treat it as MULCH: accurate, and not a false loss alarm.
                local witheredIsHarvest = ft.witheredState ~= nil and minH ~= nil
                    and ft.witheredState == minH
                if witheredIsHarvest and gs == ft.witheredState then
                    status = "MULCH"
                elseif ft.witheredState ~= nil and gs == ft.witheredState then
                    status = "WITHERED"
                elseif ft.cutState ~= nil and gs == ft.cutState then
                    status = "CUT"
                elseif minH ~= nil and maxH ~= nil and gs >= minH and gs <= maxH then
                    status = "READY"
                elseif ft.preparedGrowthState ~= nil and ft.preparedGrowthState > 0
                    and ft.numGrowthStates ~= nil and gs >= ft.numGrowthStates then
                    -- root crops (potato/beet/cane): fully grown, harvestable once
                    -- topped, so it is genuinely ready to work rather than growing
                    status = "READY"
                end
                bits[#bits + 1] = string.format('"cropStatus":"%s"', status)
                if minH ~= nil then bits[#bits + 1] = string.format('"harvestAt":%d', num(minH)) end
            end)
        end
        -- the soil-state block: this is the "what does this field need?" data
        for _, k in ipairs({ "growthState", "sprayLevel", "sprayType", "limeLevel",
                             "plowLevel", "weedState", "stoneLevel", "rollerLevel",
                             "stubbleShredLevel", "groundType" }) do
            if st[k] ~= nil then
                bits[#bits + 1] = string.format('"%s":%s', k, tostring(num(st[k])))
            end
        end
    end)
    return "{" .. table.concat(bits, ",") .. "}"
end

FarmHandCollectors.fieldJson = fieldJson

--- Works whether DRIVING or ON FOOT. A vehicle gives us getIsOnField() as a
--- cheap gate; the player has no such method, so on foot we resolve purely by
--- world position (you still want to know what a field needs while standing in
--- it). Slight looseness on foot: farmland covers a bit more than the crop area.
function FarmHandCollectors.currentField(vehicle)
    if g_fieldManager == nil then return nil end

    local x, z = nil, nil
    if vehicle ~= nil then
        local onField = false
        pcall(function() onField = (type(vehicle.getIsOnField) == "function") and vehicle:getIsOnField() end)
        if not onField then return nil end
        pcall(function()
            local wx, _, wz = getWorldTranslation(vehicle.rootNode)
            x, z = wx, wz
        end)
    else
        pcall(function()
            local p = g_localPlayer
            if p == nil then return end
            if type(p.getPosition) == "function" then
                local px, _, pz = p:getPosition()
                x, z = px, pz
            elseif p.rootNode ~= nil then
                local px, _, pz = getWorldTranslation(p.rootNode)
                x, z = px, pz
            end
        end)
    end
    if x == nil or z == nil then return nil end

    local found = nil
    pcall(function()
        -- getFieldAtWorldPosition does NOT exist; match by farmland instead.
        -- VERIFIED on foot 21 Jul: farmland resolves at the player position and
        -- matches a field (yard farmland simply has no field, which reads blank).
        local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
        if farmlandId == nil then return end
        for _, f in pairs(g_fieldManager:getFields()) do
            local fl = f:getFarmland()
            if fl ~= nil and fl.id == farmlandId then found = f; break end
        end
    end)
    if found == nil then return nil end
    return fieldJson(found)
end

-- ---------------------------------------------------------------- farm state

--- The farm's animal pens, in the placeable system's order. One walk for the
--- plugin's estate frame and the widget's sites frame (EdgeCollectors.lua), so
--- both always name the same pens.
function FarmHandCollectors.farmHusbandries(farmId)
    local list = {}
    local placeables = nil
    pcall(function() placeables = g_currentMission.placeableSystem.placeables end)
    if placeables == nil then return list end
    for _, pl in pairs(placeables) do
        if pl.spec_husbandryAnimals ~= nil then
            local owned = false
            pcall(function() owned = (pl.ownerFarmId == farmId) end)
            if owned then list[#list + 1] = pl end
        end
    end
    return list
end

--- The farm's production points (productionChainManager), shared the same way.
function FarmHandCollectors.farmProductionPoints(farmId)
    local list = {}
    local pcm = g_currentMission ~= nil and g_currentMission.productionChainManager or nil
    if pcm == nil then return list end
    local points = nil
    pcall(function() points = pcm:getProductionPointsForFarmId(farmId) end)
    if points == nil then return list end
    for _, pp in pairs(points) do list[#list + 1] = pp end
    return list
end

--- Animal pens. VERIFIED: litersPerHour is LIVE and scales with herd size,
--- so level/rate gives an accurate "empty in Xh" rather than an estimate.
function FarmHandCollectors.husbandries(farmId, limit)
    local out = {}
    for _, pl in ipairs(FarmHandCollectors.farmHusbandries(farmId)) do
        if #out >= (limit or 8) then break end
        local bits = {}
        pcall(function() bits[#bits + 1] = string.format('"name":"%s"', esc(pl:getName())) end)
        pcall(function() bits[#bits + 1] = string.format('"animals":%d', num(pl:getNumOfAnimals())) end)
        pcall(function() bits[#bits + 1] = string.format('"maxAnimals":%d', num(pl:getMaxNumOfAnimals())) end)
        pcall(function() bits[#bits + 1] = string.format('"productivity":%.3f', num(pl:getGlobalProductionFactor())) end)
        -- food: sum levels across supported types, plus the live rate
        pcall(function()
            local sf = pl.spec_husbandryFood
            if sf == nil then return end
            local total = 0
            if type(sf.fillLevels) == "table" then
                for _, lvl in pairs(sf.fillLevels) do total = total + num(lvl) end
            end
            bits[#bits + 1] = string.format('"food":%.0f', total)
            bits[#bits + 1] = string.format('"foodCap":%.0f', num(sf.capacity))
            bits[#bits + 1] = string.format('"foodPerHour":%.3f', num(sf.litersPerHour))
        end)
        pcall(function()
            local sw = pl.spec_husbandryWater
            if sw == nil then return end
            bits[#bits + 1] = string.format('"waterPerHour":%.3f', num(sw.litersPerHour))
            bits[#bits + 1] = string.format('"waterAuto":%s', tostring(sw.automaticWaterSupply == true))
        end)
        out[#out + 1] = "{" .. table.concat(bits, ",") .. "}"
    end
    return "[" .. table.concat(out, ",") .. "]"
end

--- Owned production points. VERIFIED: read levels via storage:getFillLevel,
--- NOT pp.inputFillLevels (that table reads empty even after a successful write).
function FarmHandCollectors.productions(farmId, limit)
    local out = {}
    for _, pp in ipairs(FarmHandCollectors.farmProductionPoints(farmId)) do
        if #out >= (limit or 8) then break end
        local bits = {}
        pcall(function()
            if pp.owningPlaceable ~= nil then
                bits[#bits + 1] = string.format('"name":"%s"', esc(pp.owningPlaceable:getName()))
            end
        end)
        pcall(function() bits[#bits + 1] = string.format('"palletFull":%s', tostring(pp.palletLimitReached == true)) end)

        -- inputs with levels, for the "runs dry in Xh" alert
        pcall(function()
            local ins = {}
            local ids = pp.inputFillTypeIdsArray
            if type(ids) == "table" then
                for _, idx in ipairs(ids) do
                    local lvl = 0
                    pcall(function()
                        if pp.storage ~= nil and type(pp.storage.getFillLevel) == "function" then
                            lvl = num(pp.storage:getFillLevel(idx))
                        end
                    end)
                    ins[#ins + 1] = string.format('{"type":"%s","lvl":%.0f}',
                        esc(FarmHandCollectors.fillTypeName(idx)), lvl)
                end
            end
            bits[#bits + 1] = '"inputs":[' .. table.concat(ins, ",") .. "]"
        end)

        -- active production lines carry cyclesPerHour, the consumption rate
        pcall(function()
            local lines = {}
            if type(pp.productions) == "table" then
                for _, prod in pairs(pp.productions) do
                    if #lines >= 4 then break end
                    lines[#lines + 1] = string.format('{"name":"%s","status":%d,"cyclesPerHour":%.2f}',
                        esc(prod.name or "?"), num(prod.status), num(prod.cyclesPerHour))
                end
            end
            bits[#bits + 1] = '"lines":[' .. table.concat(lines, ",") .. "]"
        end)

        out[#out + 1] = "{" .. table.concat(bits, ",") .. "}"
    end
    return "[" .. table.concat(out, ",") .. "]"
end

--- Contracts, BOTH yours-in-progress and still-on-offer.
--- VERIFIED: the accessor is getMissions() (getActiveMissions does not exist)
--- and it returns ALL missions, so ownerFarmId decides which is which. The old
--- version kept only owned ones, which left "best available contract" with
--- nothing to read at all.
--- Yours sort first (you care about finishing them), then offers by reward
--- descending, so the top of the list is the one worth taking.
function FarmHandCollectors.contracts(farmId, limit)
    local mm = g_missionManager
    if mm == nil then return '{"items":[],"total":0}' end
    local missions = nil
    pcall(function() missions = mm:getMissions() end)
    if missions == nil then return '{"items":[],"total":0}' end

    local rows = {}
    for _, m in pairs(missions) do
        local owner = nil
        pcall(function() owner = m.ownerFarmId end)
        local mine = (owner ~= nil and owner == farmId)
        -- unowned == on offer. Guard against another farm's contracts in MP by
        -- only treating nil/0 as available rather than "anything not mine".
        local available = (not mine) and (owner == nil or owner == 0)
        if mine or available then
            local title, reward, completion = "?", 0, nil
            pcall(function() title = tostring(m.progressTitle or m.title or (m.type ~= nil and m.type.name) or "?") end)
            pcall(function() reward = num(m.reward) end)
            if mine then pcall(function() completion = num(m:getCompletion()) end) end
            rows[#rows + 1] = { title = title, reward = reward, completion = completion, mine = mine }
        end
    end

    table.sort(rows, function(a, b)
        if a.mine ~= b.mine then return a.mine end   -- yours first
        return a.reward > b.reward                    -- then best-paying offer
    end)

    local cap = limit or 8
    local out = {}
    for i = 1, math.min(#rows, cap) do
        local r = rows[i]
        local bits = {
            string.format('"title":"%s"', esc(r.title)),
            string.format('"reward":%.0f', num(r.reward)),
            string.format('"mine":%s', tostring(r.mine)),
        }
        if r.completion ~= nil then bits[#bits + 1] = string.format('"completion":%.3f', num(r.completion)) end
        out[#out + 1] = "{" .. table.concat(bits, ",") .. "}"
    end
    return string.format('{"items":[%s],"total":%d}', table.concat(out, ","), #rows)
end

--- Best sell price per fill type across all stations.
--- VERIFIED: getEffectiveFillTypePrice works. NOTE the scale does not match
--- economy.xml's seasonal curve, so the plugin uses live prices for "where to
--- sell" and the curve's relative SHAPE for "when to sell".
function FarmHandCollectors.bestPrices(wanted, limit)
    local stations = nil
    pcall(function() stations = g_currentMission.storageSystem:getUnloadingStations() end)
    if stations == nil then return "[]" end

    local best = {}
    for _, st in pairs(stations) do
        pcall(function()
            if type(st.getEffectiveFillTypePrice) ~= "function" then return end
            local name = "?"
            pcall(function() name = st:getName() end)
            local supported = st.getSupportedFillTypes and st:getSupportedFillTypes() or st.supportedFillTypes
            if type(supported) ~= "table" then return end
            for ftIdx, on in pairs(supported) do
                if on then
                    local ftName = FarmHandCollectors.fillTypeName(ftIdx)
                    if wanted == nil or wanted[ftName] then
                        local price = st:getEffectiveFillTypePrice(ftIdx)
                        if type(price) == "number" and price > 0 then
                            local cur = best[ftName]
                            if cur == nil or price > cur.price then
                                best[ftName] = { price = price, station = name, index = ftIdx }
                            end
                        end
                    end
                end
            end
        end)
    end

    -- Crops first, then everything else, each ALPHABETICAL, and only THEN cap.
    -- The old loop capped a pairs() walk, which has no order, so the deck's
    -- "Best prices" showed an arbitrary set in no order (fixed 21 Oct 2026).
    -- Alphabetical, not by price: the list answers "where do I sell my wheat",
    -- and a price per litre is not comparable across crops whose yields differ.
    -- Crops lead because they are what a farm sells, and the cap must never
    -- push one off in favour of a factory good.
    -- A crop is a fill type the game maps to a fruit type (FruitTypeManager.lua:360).
    local rows = {}
    for ftName, rec in pairs(best) do
        local crop = false
        pcall(function()
            crop = g_fruitTypeManager:getFruitTypeIndexByFillTypeIndex(rec.index) ~= nil
        end)
        rows[#rows + 1] = { name = ftName, price = rec.price, station = rec.station, crop = crop }
    end
    table.sort(rows, function(a, b)
        if a.crop ~= b.crop then return a.crop end
        return a.name < b.name
    end)

    local out = {}
    -- The cap is a payload guard, not a selection: an alphabetical list cut at
    -- row 32 stopped at "B" and hid milk, eggs and wool (seen live 21 Oct 2026).
    for i = 1, math.min(#rows, limit or 200) do
        local r = rows[i]
        out[#out + 1] = string.format('{"type":"%s","price":%.2f,"station":"%s"}',
            esc(r.name), num(r.price), esc(r.station))
    end
    return "[" .. table.concat(out, ",") .. "]"
end

--- Seasonal crop calendar: what can be PLANTED / HARVESTED this period.
--- VERIFIED 21 Jul: the rules are STATIC per fruit type, in
--- growthDataSeasonal.periods[1..12], each entry carrying plain
--- `plantingAllowed` / `isHarvestable` booleans. The live half is
--- environment.currentPeriod. No growth-system helper exists; read the fruit
--- types directly.
--- missionInfo.growthMode == 1 means seasonal growth is ON. If it is OFF every
--- crop is plantable year-round, so the display must say so rather than mislead.
--- Also returns the NEXT period's windows, which is the actually-useful bit:
--- it gives the player lead time to prepare ("canola opens next month").
function FarmHandCollectors.season()
    local env = nil
    pcall(function() env = g_currentMission.environment end)
    if env == nil then return nil end

    local period = num(env.currentPeriod, 1)
    local nextPeriod = (period % 12) + 1

    local p = {}
    local function add(k, v) p[#p + 1] = string.format('"%s":%s', k, v) end

    add("period", period)
    add("periodNext", nextPeriod)
    pcall(function() if env.currentSeason ~= nil then add("season", num(env.currentSeason)) end end)
    pcall(function() if env.currentDayInPeriod ~= nil then add("dayInPeriod", num(env.currentDayInPeriod)) end end)
    pcall(function() if env.daysPerPeriod ~= nil then add("daysPerPeriod", num(env.daysPerPeriod)) end end)

    -- FAIL SAFE: only claim "growth is OFF" (everything plantable year-round)
    -- when we positively recognise the disabled mode. We have only ever observed
    -- growthMode == 1 (seasonal); an unknown value must NOT make us tell the
    -- player every crop is sowable, which would be confidently wrong advice.
    -- Treat anything we don't recognise as seasonal, i.e. keep showing windows.
    local seasonalOn = true
    pcall(function()
        local mi = g_currentMission.missionInfo
        if mi ~= nil and mi.growthMode ~= nil then
            local gm = num(mi.growthMode)
            add("growthMode", gm)
            if gm == 0 then seasonalOn = false end
        end
    end)
    add("seasonalGrowth", tostring(seasonalOn))

    local plant, harvest, plantNext, harvestNext = {}, {}, {}, {}
    pcall(function()
        local ftm = g_fruitTypeManager
        if ftm == nil then return end
        local fts = nil
        if type(ftm.getFruitTypes) == "function" then pcall(function() fts = ftm:getFruitTypes() end) end
        if fts == nil then fts = ftm.fruitTypes end
        if type(fts) ~= "table" then return end
        for _, ft in pairs(fts) do
            if type(ft) == "table" and ft.name ~= nil then
                local gd = ft.growthDataSeasonal
                local periods = (type(gd) == "table") and gd.periods or nil
                if type(periods) == "table" then
                    local cur, nxt = periods[period], periods[nextPeriod]
                    -- compare to true explicitly: a false flag must not read as nil
                    if type(cur) == "table" then
                        if cur.plantingAllowed == true then plant[#plant + 1] = ft.name end
                        if cur.isHarvestable == true then harvest[#harvest + 1] = ft.name end
                    end
                    if type(nxt) == "table" then
                        if nxt.plantingAllowed == true then plantNext[#plantNext + 1] = ft.name end
                        if nxt.isHarvestable == true then harvestNext[#harvestNext + 1] = ft.name end
                    end
                end
            end
        end
    end)

    -- sort so the display order is stable frame to frame
    table.sort(plant); table.sort(harvest); table.sort(plantNext); table.sort(harvestNext)

    local function arr(t)
        local q = {}
        for i = 1, #t do q[i] = string.format('"%s"', esc(t[i])) end
        return "[" .. table.concat(q, ",") .. "]"
    end
    p[#p + 1] = '"plant":' .. arr(plant)
    p[#p + 1] = '"harvest":' .. arr(harvest)
    p[#p + 1] = '"plantNext":' .. arr(plantNext)
    p[#p + 1] = '"harvestNext":' .. arr(harvestNext)

    return "{" .. table.concat(p, ",") .. "}"
end

--- The WeatherType index (1 SUN .. 8 THUNDER, in-game 22 Oct) of one forecast
--- item, or nil.
---
--- In-game 22 Oct: weather.forecastItems[i] carries startDay, startDayTime,
--- duration, objectIndex, variationIndex and season, and weather.weatherObjects
--- exists. An item names its weather object by (season, objectIndex), and the
--- object carries the type, which is how the game's own getCurrentWeatherType
--- reads item 1. The method is tried first, the table it reads second.
function FarmHandCollectors.forecastItemType(w, item)
    if type(w) ~= "table" or type(item) ~= "table" then return nil end
    local obj = nil
    pcall(function()
        if type(w.getWeatherObjectByIndex) == "function" then obj = w:getWeatherObjectByIndex(item.season, item.objectIndex) end
    end)
    if obj == nil then
        pcall(function() obj = w.weatherObjects[item.season][item.objectIndex] end)
    end
    local t = nil
    pcall(function()
        local wt = obj.weatherType
        if type(wt) == "table" then t = wt.index elseif type(wt) == "number" then t = wt end
    end)
    if type(t) == "number" then return t end
    return nil
end

--- The weather after the current one: forecast item 2, the item the game's own
--- getNextWeatherType answers with for any time past its start.
---
--- Not getNextWeatherType itself. In-game 21 Oct it threw inside Weather.lua:912
--- ("attempt to compare nil < number") when called with no arguments, because it
--- takes a day and a time, and two FS25 mods that call it pass them in opposite
--- orders. Reading the forecast list needs neither.
function FarmHandCollectors.nextWeatherType(w)
    local items = nil
    pcall(function() items = w.forecastItems end)
    if type(items) ~= "table" or items[2] == nil then return nil end
    return FarmHandCollectors.forecastItemType(w, items[2])
end

--- Farm-level and world state. Cheap, so sent on every frame.
function FarmHandCollectors.world(farmId)
    local p = {}
    local function add(k, v) p[#p + 1] = string.format('"%s":%s', k, v) end

    pcall(function()
        local farm = g_farmManager:getFarmById(farmId)
        if farm ~= nil then
            add("money", string.format("%.0f", num(farm:getBalance())))
            if type(farm.getLoan) == "function" then add("loan", string.format("%.0f", num(farm:getLoan()))) end
        end
    end)
    -- What the player can do RIGHT NOW, from the input system's own answer.
    --
    -- An action is registered only while it is usable: a hand tool brings
    -- ACTIVATE_HANDTOOL while it is held (the chainsaw's "Throttle chainsaw";
    -- marking spray, horse brush and pressure washer share it), and construction
    -- is an out-of-cab action, so TOGGLE_CONSTRUCTION disappears in a vehicle.
    -- Asking the game beats keeping a table of which tool does what.
    --
    -- Sent so the deck can DIM those keys instead of offering a live key that
    -- cannot do anything - the complaint that started this ("Use doesnt do
    -- anything"). A key that is absent from the dump simply does not dim: an
    -- unknown must never grey out something that works.
    --
    -- Lives in WORLD, not vehicle state, because the player has hands whether or
    -- not they are in a cab, and vehicle state is null on foot.
    pcall(function()
        local want = { ACTIVATE_HANDTOOL = "handtoolUse", TOGGLE_CONSTRUCTION = "buildAvailable" }
        local found = {}
        if g_inputBinding ~= nil and g_inputBinding.events ~= nil then
            for _, ev in pairs(g_inputBinding.events) do
                if type(ev) == "table" and want[ev.actionName] ~= nil then found[ev.actionName] = true end
            end
        end
        for action, field in pairs(want) do add(field, tostring(found[action] == true)) end
    end)

    -- The player's chosen currency, so the deck says what the game says.
    -- VERIFIED from the FS25/FS22 I18N source: the money unit is SYMBOL-ONLY -
    -- getCurrencyFactor() exists but nothing in the game calls it, and the HUD
    -- formats the raw balance. So never scale an amount; only send the glyph.
    -- Asking the function (not a 3-entry table) keeps currency-adding mods working.
    pcall(function()
        local sym = nil
        pcall(function() sym = g_i18n:getCurrencySymbol(true) end)
        if sym == nil or sym == "" then
            local unit = nil
            pcall(function() unit = g_gameSettings:getValue(GameSettings.SETTING.MONEY_UNIT) end)
            local key = ({ [1] = "unit_euroShort", [2] = "unit_dollarShort", [3] = "unit_poundShort" })[unit]
            pcall(function() sym = g_i18n:getText(key or "unit_dollarShort") end)
        end
        if type(sym) == "string" and sym ~= "" then add("currency", string.format('"%s"', esc(sym))) end
    end)
    -- Time scale feeds the Time dial's LCD, so the readout tracks the value the
    -- dial is changing. Read exactly where the timeUp/timeDown handlers write
    -- (missionInfo.timeScale, falling back to g_currentMission.timeScale).
    pcall(function()
        local ts = nil
        pcall(function() ts = tonumber(g_currentMission.missionInfo.timeScale) end)
        if ts == nil then pcall(function() ts = tonumber(g_currentMission.timeScale) end) end
        if ts ~= nil then add("timeScale", string.format("%.0f", num(ts))) end
    end)
    pcall(function()
        local env = g_currentMission.environment
        if env == nil then return end
        add("hour", num(env.currentHour))
        add("minute", num(env.currentMinute))
        if env.currentDay ~= nil then add("day", num(env.currentDay)) end
        -- currentPeriod (1-12) indexes the seasonal price curve
        if env.currentPeriod ~= nil then add("period", num(env.currentPeriod)) end
    end)
    -- One pcall per reading. They used to share the one above, so when the
    -- next-weather call threw, temperature went with it and the log said nothing
    -- (live telemetry carried `weather` and never `weatherNext` or `temp`).
    -- A throw is noted once with the game's own error text, so one in-game
    -- session says why rather than a key that never updates.
    local w = nil
    pcall(function() w = g_currentMission.environment.weather end)
    if w ~= nil then
        local function reading(key, method, fmt)
            if type(w[method]) ~= "function" then return end
            local ok, v = pcall(w[method], w)
            if not ok then
                FarmHandCollectors.noteStateOnce(key .. " THREW: " .. tostring(v))
                return
            end
            add(key, fmt(v))
        end
        reading("weather", "getCurrentWeatherType", num)
        local okNext, nextType = pcall(FarmHandCollectors.nextWeatherType, w)
        if okNext and nextType ~= nil then
            add("weatherNext", num(nextType))
        else
            FarmHandCollectors.noteStateOnce("weatherNext unreadable: " .. tostring(okNext and "no forecast item 2" or nextType))
        end
        reading("temp", "getCurrentTemperature", function(v) return string.format("%.1f", num(v)) end)
    end
    return "{" .. table.concat(p, ",") .. "}"
end
