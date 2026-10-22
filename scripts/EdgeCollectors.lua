-- FarmHand Telemetry :: widget-only collectors (2.20)
--
-- Farm-wide frames for the FlowKits Companion (Xeneon Edge widget): every owned
-- field, every sell point, storage, worker detail, contracts, the forecast, the
-- players and the save's settings.
--
-- They go to the WIDGET pipe only (transport:sendTo("edge", ...)) and are
-- collected only while that pipe is connected, so a player with only the
-- Stream Deck plugin pays nothing for them. The plugin's frames (state, farm,
-- estate, ai) are untouched: nothing here is written to its pipe or its file.
--
-- Names marked "in-game 22 Oct" were read from the running game by
-- scripts/Probe.lua (probe-round1-at-load.txt and probe-round2.txt, single
-- player, Riverbend Springs). Everything else is guarded with pcall and says so
-- in its comment: a missing name costs one key, never a frame.
--
-- Every string goes through FarmHandCollectors.esc and every number through
-- FarmHandCollectors.num (no inf or NaN can reach the JSON).

FarmHandEdge = {}

local esc = FarmHandCollectors.esc
local num = FarmHandCollectors.num
local HUGE = math.huge

-- ---------------------------------------------------------------- JSON helpers

local function finite(v) return type(v) == "number" and v == v and v ~= HUGE and v ~= -HUGE end
local function jstr(s) if s == nil then return "null" end return '"' .. esc(s) .. '"' end
local function jbool(b) if b == nil then return "null" end return b == true and "true" or "false" end
local function jnum(v, fmt) if not finite(v) then return "null" end return string.format(fmt or "%.2f", v) end
local function jint(v) if not finite(v) then return "null" end return string.format("%d", math.floor(v + 0.5)) end
local function kv(k, v) return '"' .. k .. '":' .. v end
local function obj(parts) return "{" .. table.concat(parts, ",") .. "}" end
local function arr(parts) return "[" .. table.concat(parts, ",") .. "]" end

FarmHandEdge.jstr, FarmHandEdge.jbool, FarmHandEdge.jnum, FarmHandEdge.jint = jstr, jbool, jnum, jint

--- A wall clock in seconds, for the cost log and the slice budget: the
--- engine's getTimeSec (it answered in game, 22 Oct: the cost lines are read
--- with it), else netGetTime (milliseconds), else nil. g_time is not used: it
--- is the frame's time and does not move inside a frame.
local clockFn = nil
local function now()
    if clockFn == nil then
        if type(getTimeSec) == "function" then clockFn = getTimeSec
        elseif type(netGetTime) == "function" then clockFn = function() return netGetTime() / 1000 end
        else clockFn = false end
    end
    if clockFn == false then return nil end
    local ok, t = pcall(clockFn)
    if ok and type(t) == "number" then return t end
    return nil
end

-- Payload guards against a pathological save, never a selection: every real
-- farm fits well inside these, and the widget scrolls whatever it gets.
local MAX_FIELDS = 500
local MAX_STATIONS = 200
local MAX_STORAGES = 200
local MAX_WORKERS = 99
local MAX_MISSIONS = 200
local MAX_FORECAST = 16
local MAX_USERS = 64
local MAX_SITES = 100

local function mission() return g_currentMission end

local function missionInfo()
    local mi = nil
    pcall(function() mi = g_currentMission.missionInfo end)
    return mi
end

local function fillName(index)
    local n = FarmHandCollectors.fillTypeName(index)
    if n == "EMPTY" then return nil end
    return n
end

--- Where the player is: the controlled vehicle, else the player on foot.
--- Same two paths as FarmHandCollectors.currentField.
local function playerPosition()
    local x, z = nil, nil
    pcall(function()
        local v = g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil
        if v ~= nil and v.rootNode ~= nil then
            local wx, _, wz = getWorldTranslation(v.rootNode)
            x, z = wx, wz
        end
    end)
    if x == nil then
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
    return x, z
end

local function nodePosition(node)
    local x, z = nil, nil
    pcall(function()
        if node == nil then return end
        local wx, _, wz = getWorldTranslation(node)
        x, z = wx, wz
    end)
    return x, z
end

--- Game clock: in-game 22 Oct, environment carries currentDay, currentHour,
--- currentMinute, currentPeriod, currentDayInPeriod, daysPerPeriod,
--- currentMonotonicDay and dayTime. Every time the widget shows is GAME time.
local function clock()
    local c = {}
    pcall(function()
        local env = g_currentMission.environment
        c.day = env.currentDay
        c.monotonicDay = env.currentMonotonicDay
        c.hour = env.currentHour
        c.minute = env.currentMinute
        c.dayTime = env.dayTime
        c.period = env.currentPeriod
        c.dayInPeriod = env.currentDayInPeriod
        c.daysPerPeriod = env.daysPerPeriod
    end)
    return c
end

local function clockJson(c)
    return obj({
        kv("day", jint(c.day)), kv("monotonicDay", jint(c.monotonicDay)),
        kv("hour", jint(c.hour)), kv("minute", jint(c.minute)), kv("dayTime", jint(c.dayTime)),
    })
end

-- ---------------------------------------------------------------- settings

--- The needs this save has switched on. In-game 22 Oct: missionInfo carries
--- limeRequired, plowingRequiredEnabled, weedsEnabled and stonesEnabled. An
--- absent key (another game version) counts as ON: showing a need the save does
--- not have is a nuisance, hiding one it does have is wrong advice.
function FarmHandEdge.needsEnabled()
    local mi = missionInfo() or {}
    return {
        lime = mi.limeRequired ~= false,
        plow = mi.plowingRequiredEnabled ~= false,
        weeds = mi.weedsEnabled ~= false,
        stones = mi.stonesEnabled ~= false,
    }
end

-- The 12 growth periods. In FS25, as in FS22, period 1 is EARLY_SPRING and
-- period 12 is LATE_WINTER: economy.xml stores its 12-value price history in
-- that order (fs25-price-seasonality.md), and on Riverbend Springs (in-game
-- 22 Oct) currentPeriod 4 came with currentSeason 2, summer. On a northern map
-- the game's calendar labels period 1 March, which is why the widget's month
-- index 0 is MAR. `periodNames` below sends the game's own labels when it will
-- give them, so a map that labels them otherwise is not guessed at.
local PERIODS = 12

local function cropWindows(ft)
    local plant, harvest = {}, {}
    local gd = type(ft) == "table" and ft.growthDataSeasonal or nil
    local periods = type(gd) == "table" and gd.periods or nil
    for i = 1, PERIODS do
        local p = type(periods) == "table" and periods[i] or nil
        plant[i] = jbool(type(p) == "table" and p.plantingAllowed == true)
        harvest[i] = jbool(type(p) == "table" and p.isHarvestable == true)
    end
    return arr(plant), arr(harvest)
end

local function fruitTypes()
    local fts = nil
    pcall(function() fts = g_fruitTypeManager:getFruitTypes() end)
    if fts == nil then pcall(function() fts = g_fruitTypeManager.fruitTypes end) end
    if type(fts) ~= "table" then return {} end
    return fts
end

--- Crop name as the price list and the widget's icons know it (the fill type
--- the fruit yields), falling back to the fruit type's own name.
local function cropName(fruitIndex, ft)
    local n = nil
    pcall(function() n = g_fruitTypeManager:getFillTypeNameByFruitTypeIndex(fruitIndex) end)
    if type(n) == "string" and n ~= "" and n ~= "UNKNOWN" then return n end
    if type(ft) == "table" and type(ft.name) == "string" then return ft.name end
    return nil
end

--- The game's own label for a period, or nil. g_i18n:formatPeriod is the FS22
--- name; UNPROVEN on FS25, so it is optional.
local function periodNames()
    local names = {}
    for i = 1, PERIODS do
        local n = nil
        pcall(function() n = g_i18n:formatPeriod(i, true) end)
        if type(n) ~= "string" or n == "" then return nil end
        names[i] = jstr(n)
    end
    return arr(names)
end

-- ---------------------------------------------------------------- fields

local function allFields()
    local fields = nil
    pcall(function() fields = g_fieldManager:getFields() end)
    if type(fields) ~= "table" then return {} end
    return fields
end

local function fieldNumber(f)
    local n = nil
    pcall(function() n = f:getId() end)
    if finite(n) then return n end
    return nil
end

--- farmland id -> field number, for "which field is this worker on".
function FarmHandEdge.fieldsByFarmland()
    local map = {}
    for _, f in pairs(allFields()) do
        pcall(function()
            local fl = f.farmland
            local n = fieldNumber(f)
            if fl ~= nil and fl.id ~= nil and n ~= nil and map[fl.id] == nil then map[fl.id] = n end
        end)
    end
    return map
end

function FarmHandEdge.fieldAt(x, z, byFarmland)
    if x == nil or z == nil then return nil end
    local id = nil
    pcall(function() id = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z) end)
    if id == nil then return nil end
    return (byFarmland or FarmHandEdge.fieldsByFarmland())[id]
end

function FarmHandEdge.findField(n)
    n = tonumber(n)
    if n == nil then return nil end
    for _, f in pairs(allFields()) do
        if fieldNumber(f) == n then return f end
    end
    return nil
end

--- What the crop on a field is doing, from the crop's own numbers.
---
--- Same rules as FarmHandCollectors.fieldJson's cropStatus (verified 22 Jul
--- across all 26 crops: growth states are discrete IDs, not a timeline), in the
--- widget's words: fallow, sown, growing, ready, withered, harvested.
--- In-game 22 Oct: WHEAT numGrowthStates=8, min/maxHarvestingGrowthState=8,
--- witheredState=9, cutState=10; POTATO numGrowthStates=6, harvest 9,
--- preparedGrowthState=9, witheredState=7, cutState=8.
local function cropState(ft, gs)
    if ft == nil or gs == nil or gs <= 0 then return "fallow" end
    local minH, maxH = ft.minHarvestingGrowthState, ft.maxHarvestingGrowthState
    local wither, cut = ft.witheredState, ft.cutState
    -- OILSEEDRADISH: withered == harvest state. It is a cover crop you mulch,
    -- so that state is "ready" (with the mulch need), never a loss.
    local witheredIsHarvest = wither ~= nil and minH ~= nil and wither == minH
    if witheredIsHarvest and gs == wither then return "ready", true end
    if wither ~= nil and gs == wither then return "withered" end
    if cut ~= nil and gs == cut then return "harvested" end
    if minH ~= nil and maxH ~= nil and gs >= minH and gs <= maxH then return "ready" end
    -- root crops: fully grown, harvestable once the haulm is topped
    if ft.preparedGrowthState ~= nil and ft.preparedGrowthState > 0
        and ft.numGrowthStates ~= nil and gs >= ft.numGrowthStates then
        return "ready"
    end
    if gs == 1 then return "sown" end
    return "growing"
end

FarmHandEdge.cropState = cropState

local function fieldRow(f, needsOn, fm, period, nextPeriod)
    local st = f.fieldState
    if st == nil then pcall(function() st = f:getFieldState() end) end
    local p = {}
    local n = fieldNumber(f)
    p[#p + 1] = kv("n", jint(n))
    pcall(function() p[#p + 1] = kv("farmland", jint(f.farmland.id)) end)
    -- in-game 22 Oct: areaHa is a plain field; getAreaHa is the plugin's path
    local ha = f.areaHa
    if not finite(ha) then pcall(function() ha = f:getAreaHa() end) end
    p[#p + 1] = kv("ha", jnum(ha))
    p[#p + 1] = kv("x", jnum(f.posX, "%.1f"))
    p[#p + 1] = kv("z", jnum(f.posZ, "%.1f"))

    local ft, crop, state, mulchCrop = nil, nil, "fallow", false
    local gs = type(st) == "table" and st.growthState or nil
    if type(st) == "table" and st.fruitTypeIndex ~= nil and st.fruitTypeIndex ~= 0 then
        pcall(function() ft = g_fruitTypeManager:getFruitTypeByIndex(st.fruitTypeIndex) end)
        crop = cropName(st.fruitTypeIndex, ft)
    end
    state, mulchCrop = cropState(ft, gs)
    p[#p + 1] = kv("crop", jstr(crop))
    p[#p + 1] = kv("state", jstr(state))

    -- growth against the state the crop is ready at (numGrowthStates), for the
    -- growth bar. Only while it grows: a cut or withered state is past the bar.
    local gmax = ft ~= nil and ft.numGrowthStates or nil
    local growth = nil
    if gmax ~= nil and gs ~= nil then
        if state == "sown" or state == "growing" then growth = math.min(gs, gmax)
        elseif state == "ready" then growth = gmax end
    end
    p[#p + 1] = kv("growth", jint(growth))
    p[#p + 1] = kv("growthMax", jint(gmax))

    -- Needs, only those this save has switched on, in a fixed order.
    -- In-game 22 Oct: fieldState carries limeLevel, plowLevel, rollerLevel,
    -- sprayLevel, sprayType, stoneLevel, stubbleShredLevel, weedState,
    -- weedFactor and waterLevel. The thresholds are derived, not probed:
    --   lime    limeLevel 0 (max 3; the game asks for lime at 0)
    --   weed    weedState above 0 while a crop is in the ground
    --   stones  stoneLevel above 0
    --   plow    plowLevel 0 (max 1)
    --   fert    sprayLevel below max while the crop is sown or growing
    --   roll    a crop that needsRolling, not yet rolled, sown or just up
    --   mulch   harvested stubble of a crop the mulcher works, not yet mulched;
    --           or a cover crop at its mulch state
    local needs = {}
    if type(st) == "table" then
        local inGround = state == "sown" or state == "growing" or state == "ready"
        if needsOn.lime and num(st.limeLevel, 1) <= 0 then needs[#needs + 1] = '"lime"' end
        if needsOn.weeds and inGround and num(st.weedState) > 0 and (ft == nil or ft.plantsWeed ~= false) then
            needs[#needs + 1] = '"weed"'
        end
        if needsOn.stones and num(st.stoneLevel) > 0 then needs[#needs + 1] = '"stones"' end
        if needsOn.plow and num(st.plowLevel, 1) <= 0 then needs[#needs + 1] = '"plow"' end
        local sprayMax = num(fm.sprayLevelMaxValue, 2)
        if (state == "sown" or state == "growing") and num(st.sprayLevel) < sprayMax then needs[#needs + 1] = '"fert"' end
        if ft ~= nil and ft.needsRolling == true and num(st.rollerLevel) <= 0
            and (state == "sown" or (state == "growing" and num(gs) <= 2)) then
            needs[#needs + 1] = '"roll"'
        end
        if mulchCrop or (state == "harvested" and ft ~= nil and ft.mulcherChopperType ~= nil and num(st.stubbleShredLevel) <= 0) then
            needs[#needs + 1] = '"mulch"'
        end
    end
    p[#p + 1] = kv("needs", arr(needs))

    -- Ready, and this is the crop's last harvestable period: the window closes
    -- when the period ends. Whether a ready crop then withers is not readable
    -- from the save (no withering key exists, in-game 22 Oct), so this says only
    -- that the window closes; the widget decides what that means.
    local closing = false
    if state == "ready" and ft ~= nil then
        pcall(function()
            local periods = ft.growthDataSeasonal.periods
            closing = periods[period].isHarvestable == true and periods[nextPeriod].isHarvestable ~= true
        end)
    end
    p[#p + 1] = kv("closing", jbool(closing))

    -- the raw soil block, so the widget can show the game's own levels
    if type(st) == "table" then
        p[#p + 1] = kv("soil", obj({
            kv("growthState", jint(st.growthState)), kv("lastGrowthState", jint(st.lastGrowthState)),
            kv("lime", jint(st.limeLevel)), kv("plow", jint(st.plowLevel)), kv("roller", jint(st.rollerLevel)),
            kv("spray", jint(st.sprayLevel)), kv("sprayType", jint(st.sprayType)), kv("stones", jint(st.stoneLevel)),
            kv("stubbleShred", jint(st.stubbleShredLevel)), kv("weed", jint(st.weedState)),
            kv("weedFactor", jnum(st.weedFactor, "%.3f")), kv("water", jnum(st.waterLevel, "%.3f")),
            kv("ground", jint(st.groundType)),
        }))
    end
    return { n = n or 0, json = obj(p) }
end

--- Every field this farm owns. Ownership is the farmland's farmId (in-game
--- 22 Oct: fieldState.ownerFarmId read 15 on owned fields, so it is ignored).
function FarmHandEdge.fields(farmId)
    local needsOn = FarmHandEdge.needsEnabled()
    local fm = g_fieldManager or {}
    local c = clock()
    local period = num(c.period, 1)
    local nextPeriod = (period % PERIODS) + 1
    local rows, total = {}, 0
    for _, f in pairs(allFields()) do
        total = total + 1
        local owned = false
        pcall(function() owned = f.farmland ~= nil and f.farmland.farmId == farmId end)
        if owned then
            local ok, row = pcall(fieldRow, f, needsOn, fm, period, nextPeriod)
            if ok and row ~= nil then rows[#rows + 1] = row end
        end
    end
    table.sort(rows, function(a, b) return a.n < b.n end)
    local out = {}
    for i = 1, math.min(#rows, MAX_FIELDS) do out[i] = rows[i].json end
    return obj({
        '"event":"fields"', kv("owned", jint(#rows)), kv("total", jint(total)),
        kv("period", jint(c.period)), kv("dayInPeriod", jint(c.dayInPeriod)), kv("daysPerPeriod", jint(c.daysPerPeriod)),
        kv("rows", arr(out)),
    })
end

-- ---------------------------------------------------------------- selling points

--- The sell points the game's own price screen lists. In-game 22 Oct:
--- storageSystem:getUnloadingStations() returned 67, of which 30 are
--- isSellingPoint and not hideFromPricesMenu.
function FarmHandEdge.sellingPoints()
    local out = {}
    local stations = nil
    pcall(function() stations = g_currentMission.storageSystem:getUnloadingStations() end)
    if type(stations) ~= "table" then return out end
    for _, st in pairs(stations) do
        local visible = false
        pcall(function() visible = st.isSellingPoint == true and st.hideFromPricesMenu ~= true end)
        if visible then out[#out + 1] = st end
    end
    return out
end

function FarmHandEdge.findStation(id)
    local want = tostring(id)
    for _, st in ipairs(FarmHandEdge.sellingPoints()) do
        if tostring(st.id) == want then return st end
    end
    return nil
end

local function stationName(st)
    local n = nil
    pcall(function() n = st:getName() end)
    if type(n) ~= "string" then pcall(function() n = st.owningPlaceable:getName() end) end
    return n
end

--- Fill types this station will pay for.
---
--- getEffectiveFillTypePrice THROWS for a type the station does not take
--- (in-game 22 Oct: "SellingStation.lua:534 attempt to perform arithmetic (mul)
--- on nil and number" for WHEAT at the biogas plant), so a type must be both
--- accepted (acceptedFillTypes, else the supported set the plugin's bestPrices
--- uses) AND priced (fillTypePrices), and each call still has its own pcall.
local function stationFillTypes(st)
    local set = nil
    pcall(function() if type(st.acceptedFillTypes) == "table" and next(st.acceptedFillTypes) ~= nil then set = st.acceptedFillTypes end end)
    if set == nil then
        pcall(function() set = st.getSupportedFillTypes and st:getSupportedFillTypes() or st.supportedFillTypes end)
    end
    local out = {}
    if type(set) ~= "table" then return out end
    local prices = type(st.fillTypePrices) == "table" and st.fillTypePrices or nil
    for ftIdx, on in pairs(set) do
        if on and (prices == nil or prices[ftIdx] ~= nil) then out[#out + 1] = ftIdx end
    end
    return out
end

--- Great demands running now, keyed station -> fill type index.
--- economyManager.greatDemands exists (in-game 22 Oct); the entry fields
--- (sellStation, fillTypeIndex, demandMultiplier, isRunning) are FS22's,
--- UNPROVEN on FS25.
local function greatDemands()
    local byStation = {}
    pcall(function()
        for _, d in pairs(g_currentMission.economyManager.greatDemands) do
            pcall(function()
                if d.isRunning == true and d.sellStation ~= nil and d.fillTypeIndex ~= nil then
                    byStation[d.sellStation] = byStation[d.sellStation] or {}
                    byStation[d.sellStation][d.fillTypeIndex] = num(d.demandMultiplier, 1)
                end
            end)
        end
    end)
    return byStation
end

--- The season's price history for a fill type, as economy.xml stores it (12
--- values, period 1 first). fillType.economy.history is FS22's runtime home for
--- it, UNPROVEN on FS25: absent, the key is simply left out.
local function priceCurve(ftIdx)
    local out = nil
    pcall(function()
        local ft = g_fillTypeManager:getFillTypeByIndex(ftIdx)
        local h = ft.economy.history
        if type(h) ~= "table" then return end
        local vals = {}
        for i = 1, PERIODS do
            if not finite(h[i]) then return end
            vals[i] = jnum(h[i], "%.4f")
        end
        out = arr(vals)
    end)
    return out
end

-- ---------------------------------------------------------------- sliced builds
--
-- The big frames are built in small units spread over game frames, into a
-- buffer, and sent once complete. In game (22 Oct) stations cost 4.20 ms in one
-- frame unsliced and 1.68 ms in its worst slice cold, and storage 2.70 ms, at
-- 144 fps most of a frame. A unit is one station's static read, one station's
-- prices, a batch of placeables or vehicles, or one storage: each well under
-- the budget. A slice runs units until UNIT_BUDGET_S has passed (always at
-- least one), at most MAX_UNITS_PER_SLICE, so the worst frame is the budget
-- plus one unit. The summary gets a frame of its own.
-- In game (22 Oct, at 7f56b3c) the cold stations build still hit 1.71 ms in one
-- frame with 8 units and 0.4 ms, so the caps are tighter, every unit is timed,
-- and the slowest unit of each kind goes to the log: the next session says
-- whether a slice overran its budget or one unit was simply that heavy.
local MAX_UNITS_PER_SLICE = 4
local UNIT_BUDGET_S = 0.0003        -- 0.3 ms
local STATIC_CYCLES = 6             -- builds between re-reads of what does not change (6 x 10 s)
local BATCH = 20                    -- placeables or vehicles per unit

local function newJob(finish)
    return { units = {}, i = 0, finish = finish }
end

local function addUnit(job, fn, a, b, kind)
    job.units[#job.units + 1] = { fn = fn, a = a, b = b, kind = kind or "unit" }
end

--- Queue a unit to run next, for a unit that splits its own work in two.
local function addNext(job, fn, a, b, kind)
    table.insert(job.units, job.i + 1, { fn = fn, a = a, b = b, kind = kind or "unit" })
end

--- Run one slice. Returns the finished line, or nil while there is more to do.
function FarmHandEdge.stepJob(job, maxUnits, deadline)
    local n = 0
    while job.i < #job.units do
        if n >= (maxUnits or MAX_UNITS_PER_SLICE) then return nil end
        if n > 0 and deadline ~= nil then
            local t = now()
            if t ~= nil and t > deadline then return nil end
        end
        job.i = job.i + 1
        local u = job.units[job.i]
        -- a unit that throws (a station sold mid-build) costs its own part only
        local t0 = now()
        pcall(u.fn, job, u.a, u.b)
        local t1 = t0 ~= nil and now() or nil
        if t1 ~= nil then
            job.unitMax = job.unitMax or {}
            local ms = (t1 - t0) * 1000
            if ms > (job.unitMax[u.kind] or 0) then job.unitMax[u.kind] = ms end
        end
        n = n + 1
    end
    if n > 0 then return nil end
    local t0 = now()
    local line = job.finish(job)
    local t1 = t0 ~= nil and now() or nil
    if t1 ~= nil then
        job.unitMax = job.unitMax or {}
        job.unitMax.summary = (t1 - t0) * 1000
    end
    return line
end

--- Run a sliced build to the end in one go (tests, and any caller that does
--- not need it spread).
local function runJob(job)
    local line = nil
    while line == nil do line = FarmHandEdge.stepJob(job, math.huge, nil) end
    return line
end

-- ---------------------------------------------------------------- settings, sliced

-- One crop's windows and flags as JSON, cached per fruit type for six builds:
-- the windows are static for the save, and 26 crops of 24 flags each came to
-- 0.73 ms in one frame (in-game 22 Oct).
local CROPS_PER_UNIT = 6
local cropJsonCache = setmetatable({}, { __mode = "k" })
FarmHandEdge.settingsCycle = 0

local function cropJson(job, r)
    local c = cropJsonCache[r.ft]
    if c ~= nil and c.name == r.name and job.cycle - c.cycle < STATIC_CYCLES then return c.json end
    local plant, harvest = cropWindows(r.ft)
    local json = '"' .. esc(r.name) .. '":' .. obj({
        kv("plant", plant), kv("harvest", harvest),
        kv("needsRolling", jbool(r.ft.needsRolling == true)),
        kv("growthRequiresLime", jbool(r.ft.growthRequiresLime == true)),
        kv("plantsWeed", jbool(r.ft.plantsWeed == true)),
    })
    cropJsonCache[r.ft] = { cycle = job.cycle, name = r.name, json = json }
    return json
end

local function settingsCrops(job, from)
    for k = from, math.min(#job.rows, from + CROPS_PER_UNIT - 1) do
        job.crops[#job.crops + 1] = cropJson(job, job.rows[k])
    end
end

local function finishSettings(job)
    local mi = missionInfo() or {}
    local needs = FarmHandEdge.needsEnabled()
    local c = clock()
    local fm = g_fieldManager or {}

    local p = { '"event":"settings"' }
    p[#p + 1] = kv("needs", obj({
        kv("lime", jbool(needs.lime)), kv("plow", jbool(needs.plow)),
        kv("weeds", jbool(needs.weeds)), kv("stones", jbool(needs.stones)),
    }))
    -- In-game 22 Oct: helperBuyFuel, helperBuySeeds, helperBuyFertilizer,
    -- helperManureSource and helperSlurrySource. With refill on, an empty tank
    -- is not an alert: the helper buys more.
    p[#p + 1] = kv("helper", obj({
        kv("fuel", jbool(mi.helperBuyFuel)), kv("seeds", jbool(mi.helperBuySeeds)),
        kv("fertilizer", jbool(mi.helperBuyFertilizer)),
        kv("manureSource", jint(mi.helperManureSource)), kv("slurrySource", jint(mi.helperSlurrySource)),
    }))
    p[#p + 1] = kv("daysPerPeriod", jint(c.daysPerPeriod))
    p[#p + 1] = kv("growthMode", jint(mi.growthMode))
    p[#p + 1] = kv("fuelUsage", jint(mi.fuelUsage))
    p[#p + 1] = kv("economicDifficulty", jint(mi.economicDifficulty))
    p[#p + 1] = kv("snow", jbool(mi.isSnowEnabled))
    -- In-game 22 Oct: g_fieldManager.limeLevelMaxValue=3, plowLevelMaxValue=1,
    -- sprayLevelMaxValue=2.
    p[#p + 1] = kv("max", obj({
        kv("lime", jint(fm.limeLevelMaxValue)), kv("plow", jint(fm.plowLevelMaxValue)),
        kv("spray", jint(fm.sprayLevelMaxValue)),
    }))
    local names = periodNames()
    if names ~= nil then p[#p + 1] = kv("periodNames", names) end
    -- Planting and harvest windows per crop, 12 flags each, index 1 = period 1.
    -- Static for the save, so they ride here rather than on every field row.
    p[#p + 1] = kv("crops", "{" .. table.concat(job.crops, ",") .. "}")
    return obj(p)
end

--- Start a settings build: the crops, sorted and de-duplicated by name, then
--- a few crops per unit; the rest of the frame is the summary.
function FarmHandEdge.settingsBegin()
    FarmHandEdge.settingsCycle = FarmHandEdge.settingsCycle + 1
    local job = newJob(finishSettings)
    job.cycle, job.crops = FarmHandEdge.settingsCycle, {}
    local rows = {}
    for idx, ft in pairs(fruitTypes()) do
        if type(ft) == "table" then
            local i = ft.index or idx
            local name = cropName(i, ft)
            if name ~= nil then rows[#rows + 1] = { name = name, ft = ft } end
        end
    end
    table.sort(rows, function(x, y) return x.name < y.name end)
    local seen, unique = {}, {}
    for _, r in ipairs(rows) do
        if not seen[r.name] then
            seen[r.name] = true
            unique[#unique + 1] = r
        end
    end
    job.rows = unique
    for from = 1, #unique, CROPS_PER_UNIT do addUnit(job, settingsCrops, from, nil, "crops") end
    return job
end

function FarmHandEdge.settings()
    return runJob(FarmHandEdge.settingsBegin())
end

-- ---------------------------------------------------------------- stations, sliced

-- What does not change from one build to the next (name, position, the fill
-- types a station takes) is read once a minute; prices, trends and demands are
-- re-read every build.
local stationCache = setmetatable({}, { __mode = "k" })
local curveCache = {}               -- fill type index -> { period, json or false }
FarmHandEdge.stationCycle = 0

local function readStationStatic(job, st)
    local c = { cycle = job.cycle, name = stationName(st), fills = {} }
    pcall(function() c.x, c.z = nodePosition(st.owningPlaceable.rootNode) end)
    if c.x == nil then c.x, c.z = nodePosition(st.rootNode) end
    for _, ftIdx in ipairs(stationFillTypes(st)) do
        local fname = fillName(ftIdx)
        if fname ~= nil then c.fills[#c.fills + 1] = { idx = ftIdx, name = fname } end
    end
    table.sort(c.fills, function(a, b) return a.name < b.name end)
    -- getCurrentPricingTrend is FS22's, UNPROVEN on FS25. Asked only when the
    -- method exists: a pcall that throws builds an error string every time.
    c.hasTrend = type(st.getCurrentPricingTrend) == "function"
    stationCache[st] = c
end

local function staticStale(c, cycle)
    return c == nil or cycle - c.cycle >= STATIC_CYCLES
end

--- The season curve changes at most once a period, so it is cached per period.
local function cachedCurve(ftIdx, period)
    local c = curveCache[ftIdx]
    if c == nil or c.period ~= period then
        c = { period = period, json = priceCurve(ftIdx) or false }
        curveCache[ftIdx] = c
    end
    return c.json or nil
end

-- fill types priced per unit: a big sell point takes 30 or more
local PRICES_PER_UNIT = 8

local function readStationPrices(job, st, from)
    from = from or 1
    local c = stationCache[st]
    if c == nil then readStationStatic(job, st); c = stationCache[st] end
    local dem = job.demands[st] or {}
    job.partial = job.partial or {}
    local pj = job.partial[st] or {}
    job.partial[st] = pj
    local last = math.min(#c.fills, from + PRICES_PER_UNIT - 1)
    for k = from, last do
        local f = c.fills[k]
        local ok, price = pcall(st.getEffectiveFillTypePrice, st, f.idx)
        if ok and finite(price) and price > 0 then
            local bits = { kv("fill", jstr(f.name)), kv("price", jnum(price, "%.4f")) }
            if c.hasTrend then
                local okT, trend = pcall(st.getCurrentPricingTrend, st, f.idx)
                if okT and finite(trend) then bits[#bits + 1] = kv("trend", jint(trend)) end
            end
            if dem[f.idx] ~= nil then bits[#bits + 1] = kv("demand", jnum(dem[f.idx], "%.2f")) end
            pj[#pj + 1] = obj(bits)
            local b = job.best[f.name]
            if b == nil or price > b.price then job.best[f.name] = { price = price, station = st.id, index = f.idx } end
        end
    end
    if last < #c.fills then
        addNext(job, readStationPrices, st, last + 1, "prices")
        return
    end
    job.partial[st] = nil
    job.items[#job.items + 1] = obj({
        kv("id", jint(tonumber(st.id))), kv("name", jstr(c.name)),
        kv("x", jnum(c.x, "%.1f")), kv("z", jnum(c.z, "%.1f")),
        kv("prices", arr(pj)),
    })
end

-- The summary (in game 1.75 ms in one unit, 22 Oct) is units too: the best
-- price rows' crop flags, a sort, then the rows with their season curves.
local SUMMARY_PER_UNIT = 20
local CURVES_PER_UNIT = 10
local cropFlagCache = {}            -- fill type index -> is it a crop (static for the save)

local function summaryRows(job, from)
    local rows = job.rows
    for k = from, math.min(#rows, from + SUMMARY_PER_UNIT - 1) do
        local r = rows[k]
        local crop = cropFlagCache[r.b.index]
        if crop == nil then
            crop = false
            pcall(function() crop = g_fruitTypeManager:getFruitTypeIndexByFillTypeIndex(r.b.index) ~= nil end)
            cropFlagCache[r.b.index] = crop
        end
        r.crop = crop
    end
end

local function summaryFills(job, from)
    local rows = job.rows
    for k = from, math.min(#rows, from + CURVES_PER_UNIT - 1) do
        local r = rows[k]
        local bits = {
            kv("fill", jstr(r.name)), kv("crop", jbool(r.crop)),
            kv("best", jnum(r.b.price, "%.4f")), kv("station", jint(tonumber(r.b.station))),
        }
        local curve = cachedCurve(r.b.index, job.period)
        if curve ~= nil then bits[#bits + 1] = kv("curve", curve) end
        job.fills[k] = obj(bits)
    end
end

local function summarySort(job)
    -- crops first, then the rest, each alphabetical (the plugin's bestPrices order)
    table.sort(job.rows, function(a, b)
        if a.crop ~= b.crop then return a.crop end
        return a.name < b.name
    end)
    job.fills = {}
    for from = 1, #job.rows, CURVES_PER_UNIT do addNext(job, summaryFills, from, nil, "curves") end
end

--- Runs once every station is priced: queue the summary's units next.
local function summaryStart(job)
    job.period = num(clock().period, 1)
    job.rows = {}
    for fname, b in pairs(job.best) do job.rows[#job.rows + 1] = { name = fname, b = b } end
    -- queued in reverse, each straight after this unit, so they run in order
    addNext(job, summarySort, nil, nil, "sort")
    for from = #job.rows - ((#job.rows - 1) % SUMMARY_PER_UNIT), 1, -SUMMARY_PER_UNIT do
        addNext(job, summaryRows, from, nil, "best")
    end
end

local function finishStations(job)
    local px, pz = playerPosition()
    local from = (px ~= nil and pz ~= nil) and obj({ kv("x", jnum(px, "%.1f")), kv("z", jnum(pz, "%.1f")) }) or "null"
    return obj({
        '"event":"stations"', kv("total", jint(job.total)), kv("from", from),
        kv("items", arr(job.items)), kv("fills", arr(job.fills or {})),
    })
end

--- Start a stations build. Cheap: one walk of the unloading stations.
--- A station whose static data is stale gets its own unit to read it, so a
--- cold build never reads a station's fill list and its prices in one unit.
function FarmHandEdge.stationsBegin()
    FarmHandEdge.stationCycle = FarmHandEdge.stationCycle + 1
    local job = newJob(finishStations)
    job.cycle, job.items, job.best, job.demands = FarmHandEdge.stationCycle, {}, {}, greatDemands()
    local points = FarmHandEdge.sellingPoints()
    job.total = #points
    for i = 1, math.min(#points, MAX_STATIONS) do
        local st = points[i]
        if staticStale(stationCache[st], job.cycle) then addUnit(job, readStationStatic, st, nil, "static") end
        addUnit(job, readStationPrices, st, 1, "prices")
    end
    addUnit(job, summaryStart, nil, nil, "best")
    return job
end

function FarmHandEdge.stations()
    return runJob(FarmHandEdge.stationsBegin())
end

-- ---------------------------------------------------------------- storage

local CARGO = { PALLETS = true, BIGBAGS = true, BALES = true, BIGBAGPALLETS = true }

local function ownerOf(o)
    local id = nil
    pcall(function() id = o:getOwnerFarmId() end)
    if id == nil then pcall(function() id = o.ownerFarmId end) end
    return id
end

--- storage -> the name of the building that holds it, rebuilt once a minute.
---
--- In-game 22 Oct: owningPlaceable was nil on every storage, and names went out
--- null, so walk the placeables the other way. EVERY placeable, not only the
--- farm's: a map silo with storages per farm (PlaceableSilo storagePerFarm)
--- belongs to nobody while each of its storages belongs to one farm (FS25
--- PlaceableSilo.lua sets storage.ownerFarmId per farm). The fields are FS25's:
--- spec_silo.storages, spec_siloExtension.storage, spec_husbandry.storage, and
--- a production point's storage (spec_productionPoint.productionPoint.storage).
--- Read with type checks, not pcalls that throw: the first version walked every
--- placeable with four of those and cost 2.70 ms (in-game 22 Oct).
local storageNameCache = setmetatable({}, { __mode = "k" })
local storageNamesCycle = nil
local cargoCache = setmetatable({}, { __mode = "k" })   -- vehicle -> is it cargo (store category never changes)
FarmHandEdge.storageCycle = 0

local function nameStorages(job, list, from)
    for k = from, math.min(#list, from + BATCH - 1) do
        local pl = list[k]
        local n = nil
        if type(pl) == "table" and type(pl.getName) == "function" then
            local ok, v = pcall(pl.getName, pl)
            if ok then n = v end
        end
        if type(n) == "string" and n ~= "" then
            local names = job.names
            local silo = pl.spec_silo
            if type(silo) == "table" and type(silo.storages) == "table" then
                for _, s in pairs(silo.storages) do names[s] = n end
            end
            local ext = pl.spec_siloExtension
            if type(ext) == "table" and ext.storage ~= nil then names[ext.storage] = n end
            local hus = pl.spec_husbandry
            if type(hus) == "table" and hus.storage ~= nil then names[hus.storage] = n end
            local prod = pl.spec_productionPoint
            if type(prod) == "table" and type(prod.productionPoint) == "table" and prod.productionPoint.storage ~= nil then
                names[prod.productionPoint.storage] = n
            end
        end
    end
end

local function readStorage(job, s)
    if #job.items >= MAX_STORAGES then return end
    local fills = {}
    local caps = type(s.capacities) == "table" and s.capacities or nil
    if type(s.fillLevels) == "table" then
        for ftIdx, lvl in pairs(s.fillLevels) do
            local fname = fillName(ftIdx)
            if fname ~= nil and finite(lvl) then
                local cap = caps ~= nil and caps[ftIdx] or nil
                if not finite(cap) then cap = s.capacity end
                fills[#fills + 1] = { name = fname, json = obj({
                    kv("fill", jstr(fname)), kv("lvl", jnum(lvl, "%.0f")), kv("cap", jnum(cap, "%.0f")) }) }
                if lvl > 0 then job.totals[fname] = (job.totals[fname] or 0) + lvl end
            end
        end
    end
    table.sort(fills, function(a, b) return a.name < b.name end)
    local fj = {}
    for i, r in ipairs(fills) do fj[i] = r.json end
    job.items[#job.items + 1] = obj({
        kv("id", jint(tonumber(s.id))), kv("name", jstr(storageNameCache[s])),
        kv("capacity", jnum(s.capacity, "%.0f")), kv("fills", arr(fj)),
    })
end

local function isCargo(v)
    local c = cargoCache[v]
    if c ~= nil then return c end
    local cat = (FarmHandCollectors.storeCategory(v) or ""):upper()
    local tn = type(v.typeName) == "string" and v.typeName:lower() or ""
    c = CARGO[cat] == true or tn:find("pallet") ~= nil or tn:find("bigbag") ~= nil or tn:find("bale") ~= nil
    cargoCache[v] = c
    return c
end

--- Pallets, big bags and bales the farm owns, summed per fill type. They are
--- Vehicle instances in FS25 (Collectors.lua fleet), with a fill unit.
local function readPallets(job, list, from)
    for k = from, math.min(#list, from + BATCH - 1) do
        local v = list[k]
        if ownerOf(v) == job.farmId and type(v.getFillUnits) == "function" and isCargo(v) then
            pcall(function()
                for i = 1, #v:getFillUnits() do
                    local fname = fillName(v:getFillUnitFillType(i))
                    local lvl = num(v:getFillUnitFillLevel(i))
                    if fname ~= nil and lvl > 0 then
                        local rec = job.pallets[fname] or { lvl = 0, count = 0 }
                        rec.lvl = rec.lvl + lvl
                        rec.count = rec.count + 1
                        job.pallets[fname] = rec
                    end
                end
            end)
        end
    end
end

local function sortedList(t, extra)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for i, k in ipairs(keys) do out[i] = extra(k, t[k]) end
    return arr(out)
end

local function finishStorage(job)
    return obj({
        '"event":"storage"', kv("items", arr(job.items)),
        kv("totals", sortedList(job.totals, function(k, v) return obj({ kv("fill", jstr(k)), kv("lvl", jnum(v, "%.0f")) }) end)),
        kv("pallets", sortedList(job.pallets, function(k, v)
            return obj({ kv("fill", jstr(k)), kv("lvl", jnum(v.lvl, "%.0f")), kv("count", jint(v.count)) })
        end)),
    })
end

local function listOf(t)
    local out = {}
    if type(t) == "table" then for _, x in pairs(t) do out[#out + 1] = x end end
    return out
end

--- Start a storage build: the name walk only when the cache is a minute old,
--- then one unit per storage of this farm, then the pallets in batches.
function FarmHandEdge.storageBegin(farmId)
    FarmHandEdge.storageCycle = FarmHandEdge.storageCycle + 1
    local job = newJob(finishStorage)
    job.farmId, job.items, job.totals, job.pallets = farmId, {}, {}, {}
    if storageNamesCycle == nil or FarmHandEdge.storageCycle - storageNamesCycle >= STATIC_CYCLES then
        storageNamesCycle = FarmHandEdge.storageCycle
        -- names land in a fresh table that replaces the cache when the walk is
        -- done, so a half-walked cache is never read
        job.names = setmetatable({}, { __mode = "k" })
        local placeables = nil
        pcall(function() placeables = listOf(g_currentMission.placeableSystem.placeables) end)
        placeables = placeables or {}
        for from = 1, #placeables, BATCH do addUnit(job, nameStorages, placeables, from, "names") end
        addUnit(job, function(j) storageNameCache = j.names end, nil, nil, "names")
    end
    local storages = nil
    pcall(function() storages = g_currentMission.storageSystem:getStorages() end)
    for _, s in pairs(type(storages) == "table" and storages or {}) do
        if ownerOf(s) == farmId then addUnit(job, readStorage, s, nil, "storage") end
    end
    local vehicles = nil
    pcall(function() vehicles = listOf(g_currentMission.vehicleSystem.vehicles) end)
    vehicles = vehicles or {}
    for from = 1, #vehicles, BATCH do addUnit(job, readPallets, vehicles, from, "pallets") end
    return job
end

function FarmHandEdge.storage(farmId)
    return runJob(FarmHandEdge.storageBegin(farmId))
end

--- Forget what the slices cache between builds (a new save, a new farm).
function FarmHandEdge.resetCaches()
    storageNamesCycle = nil
end

-- ---------------------------------------------------------------- workers

--- The job's kind, from its class. AIJobFieldWork is a global (in-game 22 Oct);
--- the others are FS22/FS25 names, UNPROVEN. Courseplay's jobs come first,
--- because they may extend the game's own classes.
local JOB_CLASSES = {
    { "CpAIJobFieldWork", "courseplay" }, { "CpAIJobBaleFinder", "courseplay" },
    { "CpAIJobCombineUnloader", "courseplay" }, { "CpAIJobSiloLoader", "courseplay" },
    { "CpAIJobBunkerSilo", "courseplay" }, { "CpAIJobStreet", "courseplay" }, { "CpAIJob", "courseplay" },
    { "AIJobFieldWork", "fieldWork" }, { "AIJobGoTo", "goTo" }, { "AIJobDeliver", "deliver" },
    { "AIJobLoadAndDeliver", "deliver" }, { "AIJobBaleFinder", "baleFinder" }, { "AIJobConveyor", "conveyor" },
}

local function jobType(job)
    if type(job) ~= "table" then return nil end
    for _, pair in ipairs(JOB_CLASSES) do
        local g = nil
        pcall(function() g = _G[pair[1]] end)
        if type(g) == "table" then
            local hit = false
            pcall(function() hit = job:isa(g) == true end)
            if hit then return pair[2] end
        end
    end
    return nil
end

--- AutoDrive keeps its own driver state on the vehicle (vehicle.ad.stateModule,
--- FS25_AutoDrive). UNPROVEN in game; absent, the vehicle is not an AutoDrive one.
local function autoDriveActive(v)
    local active = false
    pcall(function()
        local sm = v.ad ~= nil and v.ad.stateModule or nil
        if sm ~= nil and type(sm.isActive) == "function" then active = sm:isActive() == true end
    end)
    return active
end

local function fuelPct(v)
    local pct = nil
    pcall(function()
        for i = 1, #v:getFillUnits() do
            local fname = fillName(v:getFillUnitFillType(i))
            if fname == "DIESEL" or fname == "ELECTRICCHARGE" or fname == "METHANE" then
                local cap = num(v:getFillUnitCapacity(i))
                if cap > 0 then pct = num(v:getFillUnitFillLevel(i)) / cap * 100 end
                return
            end
        end
    end)
    return pct
end

local function netId(v)
    local id = nil
    pcall(function() id = NetworkUtil.getObjectId(v) end)
    return id
end

FarmHandEdge.netId = netId

--- Owned vehicle by its network id (the id the fleet and workers frames send,
--- and enterVehicle resolves). nil for anything else, so a stale id from the
--- widget can never land on another farm's machine.
function FarmHandEdge.findVehicle(id, farmId)
    id = tonumber(id)
    if id == nil then return nil end
    local v = nil
    pcall(function() v = NetworkUtil.getObject(id) end)
    if type(v) ~= "table" then return nil end
    if farmId ~= nil and ownerOf(v) ~= farmId then return nil end
    return v
end

local function stopKind(class)
    if type(class) ~= "string" then return "stopped" end
    if class == "AIMessageSuccessFinishedJob" or class == "AIMessageSuccessWorkFinished" then return "finished" end
    return "stopped"
end

--- `watch` is Farmhand.aiWatch (the stuck detector's state, keyed by rootNode);
--- `stops` is Farmhand.aiStops (network id -> the last stop the game reported).
function FarmHandEdge.workers(farmId, watch, stops)
    local vehicles = nil
    pcall(function() vehicles = g_currentMission.vehicleSystem.vehicles end)
    local byFarmland = FarmHandEdge.fieldsByFarmland()
    local controlled = nil
    pcall(function() controlled = g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil end)
    local rows, wages = {}, 0
    for _, v in pairs(type(vehicles) == "table" and vehicles or {}) do
        if #rows >= MAX_WORKERS then break end
        if ownerOf(v) == farmId then
            local id = netId(v)
            local ai = false
            pcall(function() ai = v:getIsAIActive() == true end)
            -- an implement hitched to a hired tractor answers getIsAIActive too;
            -- the tractor is the worker, and its `implements` names the tool
            if ai and not FarmHandCollectors.isWorkerVehicle(v) then ai = false end
            local ad = (not ai) and autoDriveActive(v)
            local stop = id ~= nil and stops ~= nil and stops[id] or nil
            -- the player took the machine over: the stop has been seen to
            if stop ~= nil and v == controlled then stops[id] = nil; stop = nil end
            if ai or ad or stop ~= nil then
                local p = {}
                p[#p + 1] = kv("id", jint(id))
                local base, letter = "?", nil
                pcall(function() base, letter = FarmHandCollectors.splitWorkerName(v:getFullName()) end)
                -- in-game 22 Oct: spec_aiJobVehicle.currentHelper has name and title ("H")
                pcall(function()
                    local h = v.spec_aiJobVehicle.currentHelper
                    if type(h) == "table" and type(h.name) == "string" and h.name ~= "" then letter = h.name end
                end)
                p[#p + 1] = kv("name", jstr(base))
                p[#p + 1] = kv("letter", jstr(letter))
                local cat = FarmHandCollectors.storeCategory(v)
                p[#p + 1] = kv("category", jstr(cat))

                local job = nil
                if ai then pcall(function() job = v:getJob() end) end
                local jt = jobType(job)
                local kind = ad and "autodrive" or (jt == "courseplay" and "courseplay" or "ai")
                -- Courseplay registers its own spec; a CP vehicle whose job did
                -- not match a class above is still tagged (names UNPROVEN)
                if kind == "ai" and job ~= nil and (v.spec_cpAIWorker ~= nil or v.spec_cpAIFieldWorker ~= nil) then kind = "courseplay" end
                p[#p + 1] = kv("kind", jstr(kind))
                p[#p + 1] = kv("jobType", jstr(jt ~= "courseplay" and jt or nil))
                local desc = nil
                pcall(function() desc = job:getDescription() end)
                p[#p + 1] = kv("job", jstr(type(desc) == "string" and desc ~= "" and desc or nil))

                local x, z = nodePosition(v.rootNode)
                p[#p + 1] = kv("x", jnum(x, "%.1f"))
                p[#p + 1] = kv("z", jnum(z, "%.1f"))
                -- the field: the field-work target (in-game 22 Oct: job:getTarget
                -- returns x, z, angle), else wherever the machine is standing
                local tx, tz = nil, nil
                if jt == "fieldWork" or jt == "courseplay" then pcall(function() tx, tz = job:getTarget() end) end
                local field = FarmHandEdge.fieldAt(tx or x, tz or z, byFarmland)
                if field == nil and tx ~= nil then field = FarmHandEdge.fieldAt(x, z, byFarmland) end
                p[#p + 1] = kv("field", jint(field))

                -- state: working, stuck (the mod's no-progress detector),
                -- stopped (the game stopped it, with its reason) or finished
                local state = "working"
                if ai or ad then
                    local w = watch ~= nil and watch[tostring(v.rootNode or v)] or nil
                    if w ~= nil and w.alerted then state = "stuck" end
                else
                    state = stopKind(stop.class)
                end
                p[#p + 1] = kv("state", jstr(state))
                -- in-game 22 Oct: spec_aiFieldWorker has isBlocked, isTurning, didNotMoveTimer
                pcall(function()
                    local fw = v.spec_aiFieldWorker
                    if fw ~= nil and ai then
                        p[#p + 1] = kv("blocked", jbool(fw.isBlocked == true))
                        p[#p + 1] = kv("turning", jbool(fw.isTurning == true))
                        -- In-game 22 Oct: didNotMoveTimer counts DOWN from
                        -- didNotMoveTimeout (5000) while the machine moves, so
                        -- the time spent still is the difference. Without the
                        -- timeout there is no honest reading, so no key.
                        local timeout, timer = fw.didNotMoveTimeout, fw.didNotMoveTimer
                        if finite(timeout) and finite(timer) then
                            p[#p + 1] = kv("stillMs", jint(math.max(0, math.min(timeout, timeout - timer))))
                        end
                    end
                end)
                if stop ~= nil and not (ai or ad) then
                    p[#p + 1] = kv("stop", obj({
                        kv("class", jstr(stop.class)), kv("severity", jstr(stop.severity)), kv("text", jstr(stop.text)),
                        kv("day", jint(stop.day)), kv("hour", jint(stop.hour)), kv("minute", jint(stop.minute)),
                    }))
                end

                p[#p + 1] = kv("fuel", jnum(fuelPct(v), "%.0f"))
                local damage = nil
                pcall(function() damage = v:getDamageAmount() end)
                p[#p + 1] = kv("damage", jnum(damage, "%.3f"))
                p[#p + 1] = kv("fills", FarmHandCollectors.fillsJson(v))
                local imps, first = {}, nil
                pcall(function()
                    for _, imp in ipairs(v:getAttachedImplements()) do
                        local o = imp.object
                        if o ~= nil then
                            local n = "?"
                            pcall(function() n = o:getFullName() end)
                            first = first or n
                            local bits = { kv("name", jstr(n)), kv("fills", FarmHandCollectors.fillsJson(o)) }
                            -- wear, for the widget's worn-machine alert; left out
                            -- when the implement does not report it
                            local okD, d = false, nil
                            if type(o.getDamageAmount) == "function" then okD, d = pcall(o.getDamageAmount, o) end
                            if okD and finite(d) then bits[#bits + 1] = kv("damage", jnum(d, "%.3f")) end
                            imps[#imps + 1] = obj(bits)
                        end
                    end
                end)
                p[#p + 1] = kv("implement", jstr(first))
                p[#p + 1] = kv("implements", arr(imps))

                -- in-game 22 Oct: job:getPricePerMs() read 0.0005; x 3,600,000 is
                -- the wage per hour of game time (UNPROVEN that the ms is game time)
                local wage = nil
                pcall(function() wage = job:getPricePerMs() * 3600000 end)
                if finite(wage) then wages = wages + wage end
                p[#p + 1] = kv("wagePerHour", jnum(wage, "%.0f"))
                rows[#rows + 1] = { name = base or "", json = obj(p) }
            end
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    local out = {}
    for i, r in ipairs(rows) do out[i] = r.json end
    return obj({ '"event":"workers"', kv("wagesPerHour", jnum(wages, "%.0f")), kv("now", clockJson(clock())), kv("items", arr(out)) })
end

-- ---------------------------------------------------------------- pens and production

-- Every rate below is PER GAME HOUR, so the widget can say "empty in 5 h" in
-- the game's own time (design-proposal.md, "Alert rules": under 24 game hours
-- is soon, under 6 is now). None is measured: the game keeps each one itself.
-- Its husbandry specs hold litersPerHour (litersPerDay / 24 summed over the
-- herd, recomputed whenever the herd changes; in-game 20 Jul it scaled live with
-- herd size), and each hour it uses litersPerHour x environment.timeAdjustment
-- (FS25 PlaceableHusbandryFood:updateFeeding, PlaceableHusbandryWater, Straw).
-- timeAdjustment is the days-per-month factor (in-game 22 Oct: 1 at 1 day per
-- month), so the rate sent is litersPerHour x timeAdjustment, what really goes.

local function timeAdjustment()
    local t = nil
    pcall(function() t = g_currentMission.environment.timeAdjustment end)
    if finite(t) and t > 0 then return t end
    return 1
end

local function fillIndex(name)
    local idx = nil
    pcall(function() idx = FillType[name] end)
    if idx == nil then pcall(function() idx = g_fillTypeManager:getFillTypeIndexByName(name) end) end
    return idx
end

--- level and capacity of one fill type in a pen's own storage, the game's
--- PlaceableHusbandry:getHusbandryFillLevel / getHusbandryCapacity
local function penLevel(pl, ftIdx)
    local lvl, cap = nil, nil
    if ftIdx == nil then return nil, nil end
    if type(pl.getHusbandryFillLevel) == "function" then
        local ok, v = pcall(pl.getHusbandryFillLevel, pl, ftIdx)
        if ok then lvl = v end
    end
    if type(pl.getHusbandryCapacity) == "function" then
        local ok, v = pcall(pl.getHusbandryCapacity, pl, ftIdx)
        if ok then cap = v end
    end
    return lvl, cap
end

local function levelJson(lvl, cap, perHour, extra)
    local p = { kv("lvl", jnum(lvl, "%.0f")), kv("cap", jnum(cap, "%.0f")), kv("perHour", jnum(perHour, "%.2f")) }
    for _, e in ipairs(extra or {}) do p[#p + 1] = e end
    return obj(p)
end

-- What does not change about a pen between builds (its name, animal type and
-- food group definitions), read once a minute like the stations' static data.
local penCache = setmetatable({}, { __mode = "k" })
FarmHandEdge.sitesCycle = 0

local function penStatic(pl, cycle)
    local c = penCache[pl]
    if c ~= nil and cycle - c.cycle < STATIC_CYCLES then return c end
    c = { cycle = cycle, groups = {} }
    if type(pl.getName) == "function" then
        local ok, v = pcall(pl.getName, pl)
        if ok then c.name = v end
    end
    local typeIndex = nil
    local sf = type(pl.spec_husbandryFood) == "table" and pl.spec_husbandryFood or nil
    if sf ~= nil then typeIndex = sf.animalTypeIndex end
    if typeIndex == nil and type(pl.getAnimalTypeIndex) == "function" then
        local ok, v = pcall(pl.getAnimalTypeIndex, pl)
        if ok then typeIndex = v end
    end
    local M = g_currentMission
    local as = M ~= nil and M.animalSystem or nil
    if typeIndex ~= nil and type(as) == "table" and type(as.getTypeByIndex) == "function" then
        local ok, t = pcall(as.getTypeByIndex, as, typeIndex)
        if ok and type(t) == "table" then c.typeName = t.name end
    end
    -- food groups: the animals screen's own split, from
    -- animalFoodSystem:getAnimalFood(type).groups (title, fillTypes, productionWeight)
    local afs = M ~= nil and M.animalFoodSystem or nil
    if typeIndex ~= nil and type(afs) == "table" and type(afs.getAnimalFood) == "function" then
        local ok, food = pcall(afs.getAnimalFood, afs, typeIndex)
        if ok and type(food) == "table" and type(food.groups) == "table" then
            for _, g in pairs(food.groups) do
                if type(g) == "table" and type(g.fillTypes) == "table" then
                    local fills, idxs = {}, {}
                    for _, ftIdx in pairs(g.fillTypes) do
                        idxs[#idxs + 1] = ftIdx
                        local n = fillName(ftIdx)
                        if n ~= nil then fills[#fills + 1] = jstr(n) end
                    end
                    c.groups[#c.groups + 1] = { head = kv("name", jstr(g.title)) .. "," .. kv("weight", jnum(g.productionWeight, "%.2f")),
                        fills = arr(fills), idxs = idxs }
                end
            end
        end
    end
    penCache[pl] = c
    return c
end

--- The pen's food, per food group. All groups share the trough's one capacity.
local function penFood(pl, adj, c)
    local sf = pl.spec_husbandryFood
    if type(sf) ~= "table" then return "null" end
    local levels = type(sf.fillLevels) == "table" and sf.fillLevels or {}
    local total = 0
    for _, lvl in pairs(levels) do total = total + num(lvl) end
    local groups = {}
    for _, g in ipairs(c.groups) do
        local lvl = 0
        for _, ftIdx in ipairs(g.idxs) do lvl = lvl + num(levels[ftIdx]) end
        groups[#groups + 1] = "{" .. g.head .. "," .. kv("lvl", jnum(lvl, "%.0f")) .. "," .. kv("fills", g.fills) .. "}"
    end
    return levelJson(total, sf.capacity, num(sf.litersPerHour) * adj, { kv("groups", arr(groups)) })
end

local function penOutputs(pl, adj)
    local out = {}
    local function add(kind, ftIdx, lvl, cap, perHour)
        local n = fillName(ftIdx)
        if n == nil then return end
        out[#out + 1] = obj({
            kv("fill", jstr(n)), kv("kind", jstr(kind)),
            kv("lvl", jnum(lvl, "%.0f")), kv("cap", jnum(cap, "%.0f")), kv("perHour", jnum(perHour, "%.2f")),
        })
    end
    local function tbl(t) return type(t) == "table" and t or nil end
    -- milk (and goat milk): the pen's storage, spec_husbandryMilk.litersPerHour[fill]
    local sm = tbl(pl.spec_husbandryMilk)
    if sm ~= nil and tbl(sm.fillTypes) ~= nil then
        local rate = tbl(sm.litersPerHour) or {}
        for _, ftIdx in ipairs(sm.fillTypes) do
            local lvl, cap = penLevel(pl, ftIdx)
            add("storage", ftIdx, lvl, cap, num(rate[ftIdx]) * adj)
        end
    end
    -- slurry: spec_husbandryLiquidManure.fillType and litersPerHour
    local sl = tbl(pl.spec_husbandryLiquidManure)
    if sl ~= nil and sl.fillType ~= nil then
        local lvl, cap = penLevel(pl, sl.fillType)
        add("storage", sl.fillType, lvl, cap, num(sl.litersPerHour) * adj)
    end
    -- manure: the straw spec's output, when the pen makes it
    local ss = tbl(pl.spec_husbandryStraw)
    if ss ~= nil and ss.isManureActive ~= false and ss.outputFillType ~= nil then
        local lvl, cap = penLevel(pl, ss.outputFillType)
        add("storage", ss.outputFillType, lvl, cap, num(ss.outputLitersPerHour) * adj)
    end
    -- wool, eggs and the like go out on pallets: fillLevels and capacities are
    -- what stands on the pen's pallets now (PlaceableHusbandryPallets)
    local sp = tbl(pl.spec_husbandryPallets)
    if sp ~= nil and tbl(sp.fillTypes) ~= nil then
        local lv, cp, rate = tbl(sp.fillLevels) or {}, tbl(sp.capacities) or {}, tbl(sp.litersPerHour) or {}
        for _, ftIdx in ipairs(sp.fillTypes) do
            add("pallets", ftIdx, lv[ftIdx], cp[ftIdx], num(rate[ftIdx]) * adj)
        end
    end
    return arr(out)
end

local function clustersOf(pl)
    if type(pl.getClusters) ~= "function" then return {} end
    local ok, cl = pcall(pl.getClusters, pl)
    if ok and type(cl) == "table" then return cl end
    return {}
end

local function penHealth(clusters)
    local sum, n = 0, 0
    for _, c in pairs(clusters) do
        local count = num(c.numAnimals)
        if finite(c.health) and count > 0 then
            sum = sum + c.health * count
            n = n + count
        end
    end
    if n == 0 then return nil end
    return sum / n
end

--- The breeds in a pen, from each herd cluster's subtype, counted.
---
--- The name is the one the Animals screen shows ("ANGUS", in-game 22 Oct): the
--- subtype's `breed` when it has one, else the title of its fill type, else its
--- own title, else its name without the animal-type prefix ("COW_ANGUS" ->
--- "ANGUS"). `subType` is the raw name. The subtype fields are FS25 source
--- names, UNPROVEN in game; nil when nothing can be read, so the key is left out.
local function breedName(st)
    if type(st) ~= "table" then return nil end
    if type(st.breed) == "string" and st.breed ~= "" then return st.breed end
    local t = nil
    if st.fillTypeIndex ~= nil then pcall(function() t = g_fillTypeManager:getFillTypeTitleByIndex(st.fillTypeIndex) end) end
    if type(t) == "string" and t ~= "" then return t end
    if type(st.title) == "string" and st.title ~= "" then return st.title end
    if type(st.name) == "string" and st.name ~= "" then return (st.name:gsub("^[%u]+_", "")) end
    return nil
end

local function penBreeds(clusters)
    local counts, order = {}, {}
    local as = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if type(as) ~= "table" or type(as.getSubTypeByIndex) ~= "function" then return nil end
    pcall(function()
        for _, c in pairs(clusters) do
            local st = nil
            local okS, v = pcall(as.getSubTypeByIndex, as, c.subTypeIndex)
            if okS then st = v end
            local name = breedName(st)
            local count = num(c.numAnimals)
            if name ~= nil and count > 0 then
                if counts[name] == nil then
                    counts[name] = { n = 0, sub = type(st.name) == "string" and st.name or nil }
                    order[#order + 1] = name
                end
                counts[name].n = counts[name].n + count
            end
        end
    end)
    if #order == 0 then return nil end
    table.sort(order)
    local out = {}
    for i, name in ipairs(order) do
        out[i] = obj({ kv("name", jstr(name)), kv("subType", jstr(counts[name].sub)), kv("count", jint(counts[name].n)) })
    end
    return arr(out)
end

local function call0(o, name)
    local f = o[name]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o)
    if ok then return v end
    return nil
end

local function penJson(pl, adj, cycle)
    local c = penStatic(pl, cycle or 0)
    local p = {}
    p[#p + 1] = kv("id", jint(netId(pl)))
    p[#p + 1] = kv("name", jstr(c.name))
    p[#p + 1] = kv("type", jstr(c.typeName))
    p[#p + 1] = kv("count", jint(call0(pl, "getNumOfAnimals")))
    p[#p + 1] = kv("max", jint(call0(pl, "getMaxNumOfAnimals")))
    p[#p + 1] = kv("productivity", jnum(call0(pl, "getGlobalProductionFactor"), "%.3f"))
    local clusters = clustersOf(pl)
    -- the herd's health, 0 to 100, averaged over its animals
    p[#p + 1] = kv("health", jnum(penHealth(clusters), "%.0f"))
    local breeds = penBreeds(clusters)
    if breeds ~= nil then p[#p + 1] = kv("breeds", breeds) end
    p[#p + 1] = kv("food", penFood(pl, adj, c))
    local water = "null"
    local sw = pl.spec_husbandryWater
    if type(sw) == "table" then
        local lvl, cap = penLevel(pl, sw.fillType or fillIndex("WATER"))
        water = levelJson(lvl, cap, num(sw.litersPerHour) * adj, { kv("auto", jbool(sw.automaticWaterSupply == true)) })
    end
    p[#p + 1] = kv("water", water)
    local straw = "null"
    local ss = pl.spec_husbandryStraw
    if type(ss) == "table" then
        local lvl, cap = penLevel(pl, ss.inputFillType or fillIndex("STRAW"))
        straw = levelJson(lvl, cap, num(ss.inputLitersPerHour) * adj)
    end
    p[#p + 1] = kv("straw", straw)
    p[#p + 1] = kv("outputs", penOutputs(pl, adj))
    local full = nil
    if type(pl.spec_husbandryPallets) == "table" then full = pl.spec_husbandryPallets.palletLimitReached end
    p[#p + 1] = kv("palletFull", jbool(full))
    return obj(p)
end

--- production status number -> the game's own name (ProductionPoint.PROD_STATUS:
--- in FS22 INACTIVE, RUNNING, MISSING_INPUTS, NO_OUTPUT_SPACE; UNPROVEN on FS25)
local statusNames = nil
local function prodStatusName(v)
    if statusNames == nil then
        statusNames = {}
        pcall(function()
            for k, n in pairs(ProductionPoint.PROD_STATUS) do
                if type(k) == "string" and type(n) == "number" then statusNames[n] = k end
            end
        end)
    end
    if v == nil then return nil end
    return statusNames[v] or tostring(v)
end

--- One production point. Use and yield per game hour follow the game's own
--- cycle data (FS25 ProductionPoint.lua): a line's amount per cycle x its
--- cyclesPerHour x timeAdjustment, shared between the lines that are on
--- unless the point sets sharedThroughputCapacity to false.
local function productionJson(pp, adj)
    local p = {}
    local pl = pp.owningPlaceable
    p[#p + 1] = kv("id", jint(pl ~= nil and netId(pl) or nil))
    local name = nil
    pcall(function() name = pl:getName() end)
    p[#p + 1] = kv("name", jstr(name))

    local active = {}
    pcall(function() for _, prod in ipairs(pp.activeProductions) do active[prod] = true end end)
    local numActive = 0
    for _ in pairs(active) do numActive = numActive + 1 end
    local share = (pp.sharedThroughputCapacity ~= false and numActive > 1) and numActive or 1

    local use, make = {}, {}
    local lines = {}
    pcall(function()
        for _, prod in ipairs(pp.productions) do
            local on = active[prod] == true
            local cycles = num(prod.cyclesPerHour) * adj / share
            if on then
                pcall(function() for _, i in ipairs(prod.inputs) do use[i.type] = (use[i.type] or 0) + num(i.amount) * cycles end end)
                pcall(function() for _, o in ipairs(prod.outputs) do make[o.type] = (make[o.type] or 0) + num(o.amount) * cycles end end)
            end
            lines[#lines + 1] = obj({
                kv("name", jstr(prod.name)), kv("on", jbool(on)),
                kv("status", jstr(prodStatusName(prod.status))), kv("cyclesPerHour", jnum(prod.cyclesPerHour, "%.2f")),
            })
        end
    end)
    p[#p + 1] = kv("on", jbool(numActive > 0))
    p[#p + 1] = kv("lines", arr(lines))

    local function level(ftIdx)
        local lvl, cap = nil, nil
        pcall(function() lvl = pp.storage:getFillLevel(ftIdx) end)
        pcall(function() cap = pp.storage:getCapacity(ftIdx) end)
        return lvl, cap
    end
    local inputs, anyDry = {}, false
    pcall(function()
        for _, ftIdx in ipairs(pp.inputFillTypeIdsArray) do
            local n = fillName(ftIdx)
            if n ~= nil then
                local lvl, cap = level(ftIdx)
                if use[ftIdx] ~= nil and num(lvl) <= 0 then anyDry = true end
                inputs[#inputs + 1] = { name = n, json = obj({ kv("fill", jstr(n)),
                    kv("lvl", jnum(lvl, "%.0f")), kv("cap", jnum(cap, "%.0f")), kv("perHour", jnum(use[ftIdx] or 0, "%.2f")) }) }
            end
        end
    end)
    local outputs, anyFull = {}, false
    pcall(function()
        for _, ftIdx in ipairs(pp.outputFillTypeIdsArray) do
            local n = fillName(ftIdx)
            if n ~= nil then
                local lvl, cap = level(ftIdx)
                -- output mode: sold directly, delivered to your storage, or kept
                -- here (outputFillTypeIdsDirectSell / AutoDeliver, FS25 source)
                local mode = "store"
                local sell, deliver = pp.outputFillTypeIdsDirectSell, pp.outputFillTypeIdsAutoDeliver
                if type(sell) == "table" and sell[ftIdx] then mode = "sell" end
                if type(deliver) == "table" and deliver[ftIdx] then mode = "distribute" end
                if mode == "store" and finite(cap) and cap > 0 and num(lvl) >= cap then anyFull = true end
                outputs[#outputs + 1] = { name = n, json = obj({ kv("fill", jstr(n)), kv("mode", jstr(mode)),
                    kv("lvl", jnum(lvl, "%.0f")), kv("cap", jnum(cap, "%.0f")), kv("perHour", jnum(make[ftIdx] or 0, "%.2f")) }) }
            end
        end
    end)
    local function list(rows)
        table.sort(rows, function(a, b) return a.name < b.name end)
        local out = {}
        for i, r in ipairs(rows) do out[i] = r.json end
        return arr(out)
    end
    p[#p + 1] = kv("inputs", list(inputs))
    p[#p + 1] = kv("outputs", list(outputs))
    p[#p + 1] = kv("palletFull", jbool(pp.palletLimitReached == true))
    -- why it is not producing, plainly: off, inputEmpty or outputFull; null
    -- while it runs. The lines' own game statuses are in `lines`.
    local stopped = nil
    if numActive == 0 then stopped = "off"
    elseif anyDry then stopped = "inputEmpty"
    elseif anyFull or pp.palletLimitReached == true then stopped = "outputFull" end
    p[#p + 1] = kv("stopped", jstr(stopped))
    return obj(p)
end

--- The farm's pens and production points, the same ones (and in the same
--- order) as the plugin's estate frame: FarmHandCollectors.farmHusbandries and
--- farmProductionPoints are the one walk both use.
local function sitePen(job, pl)
    job.pens[#job.pens + 1] = penJson(pl, job.adj, job.cycle)
end

local function siteProduction(job, pp)
    job.prods[#job.prods + 1] = productionJson(pp, job.adj)
end

local function finishSites(job)
    return obj({
        '"event":"sites"', kv("timeAdjustment", jnum(job.adj, "%.3f")),
        kv("pens", arr(job.pens)), kv("productions", arr(job.prods)),
    })
end

--- Start a sites build: one unit per pen and one per production point (1.94 ms
--- unsliced in game, 22 Oct).
function FarmHandEdge.sitesBegin(farmId)
    FarmHandEdge.sitesCycle = FarmHandEdge.sitesCycle + 1
    local job = newJob(finishSites)
    job.adj, job.cycle, job.pens, job.prods = timeAdjustment(), FarmHandEdge.sitesCycle, {}, {}
    for i, pl in ipairs(FarmHandCollectors.farmHusbandries(farmId)) do
        if i > MAX_SITES then break end
        addUnit(job, sitePen, pl, nil, "pen")
    end
    for i, pp in ipairs(FarmHandCollectors.farmProductionPoints(farmId)) do
        if i > MAX_SITES then break end
        addUnit(job, siteProduction, pp, nil, "production")
    end
    return job
end

--- The farm's pens and production points, the same ones (and in the same
--- order) as the plugin's estate frame: FarmHandCollectors.farmHusbandries and
--- farmProductionPoints are the one walk both use.
function FarmHandEdge.sites(farmId)
    return runJob(FarmHandEdge.sitesBegin(farmId))
end

-- ---------------------------------------------------------------- contracts

-- in-game 22 Oct: MissionStatus CREATED=1, PREPARING=2, RUNNING=3, FINISHED=4, DISMISSED=5
local STATUS = { [1] = "CREATED", [2] = "PREPARING", [3] = "RUNNING", [4] = "FINISHED", [5] = "DISMISSED" }

local function missionList()
    local list = nil
    pcall(function() list = g_missionManager.missions end)
    if type(list) ~= "table" then pcall(function() list = g_missionManager:getMissions() end) end
    if type(list) ~= "table" then return {} end
    return list
end

--- The farm a contract belongs to: mission.farmId once started (the game's
--- own field, MissionManager:startMission), else ownerFarmId (0 on an offer,
--- in-game 22 Oct).
function FarmHandEdge.missionFarm(m)
    local f = nil
    pcall(function() f = m.farmId end)
    if f == nil then pcall(function() f = m.ownerFarmId end) end
    if f == 0 then return nil end
    return f
end

function FarmHandEdge.findMission(uniqueId)
    if uniqueId == nil or uniqueId == "" then return nil end
    for _, m in pairs(missionList()) do
        if tostring(m.uniqueId) == uniqueId then return m end
    end
    return nil
end

--- May this player accept and cancel contracts? The game's manageContracts
--- right (getHasPlayerPermission), UNPROVEN in game; the host always may.
function FarmHandEdge.canManageContracts()
    local M = mission()
    if M == nil then return false end
    local server = false
    pcall(function() server = M:getIsServer() == true end)
    if server then return true end
    local allowed = false
    pcall(function()
        local perm = (Farm ~= nil and Farm.PERMISSION ~= nil and Farm.PERMISSION.MANAGE_CONTRACTS) or "manageContracts"
        allowed = M:getHasPlayerPermission(perm) == true
    end)
    return allowed
end

function FarmHandEdge.missionLimit(farmId)
    local active = 0
    for _, m in pairs(missionList()) do
        if FarmHandEdge.missionFarm(m) == farmId and num(m.status) ~= 1 then active = active + 1 end
    end
    local max = nil
    pcall(function() max = MissionManager.MAX_MISSIONS_PER_FARM end)
    return active, max
end

--- o:fn() when o has that method, else nil. A type check rather than a pcall
--- that throws: point contracts have no getFarmlandId, and a throw builds an
--- error string every time.
local function call(o, fn)
    local f = type(o) == "table" and o[fn] or nil
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o)
    if ok then return v end
    return nil
end

-- missions per unit: 19 on offer came to 1.09 ms in one frame (in-game 22 Oct)
local MISSIONS_PER_UNIT = 4

local function missionRow(job, m)
    local farmId = job.farmId
    local owner = FarmHandEdge.missionFarm(m)
    local status = STATUS[num(m.status)] or tostring(m.status)
    local mine = owner ~= nil and owner == farmId
    -- an offer is a contract nobody has started; another farm's is not shown
    local offer = owner == nil and status == "CREATED"
    if not (mine or offer) then return end
    local p = {}
    p[#p + 1] = kv("id", jstr(m.uniqueId))
    p[#p + 1] = kv("type", jstr(call(m, "getMissionTypeName")))
    p[#p + 1] = kv("title", jstr(m.title))
    p[#p + 1] = kv("progressTitle", jstr(m.progressTitle))
    p[#p + 1] = kv("desc", jstr(m.description))
    p[#p + 1] = kv("location", jstr(call(m, "getLocation")))
    p[#p + 1] = kv("farmland", jint(call(m, "getFarmlandId")))
    local field = type(m.field) == "table" and m.field or nil
    local fieldN, ha = nil, nil
    if field ~= nil then
        fieldN = call(field, "getId")
        ha = field.areaHa
        if not finite(ha) then ha = call(field, "getAreaHa") end
    end
    p[#p + 1] = kv("field", jint(fieldN))
    p[#p + 1] = kv("ha", jnum(ha))
    p[#p + 1] = kv("status", jstr(status))
    p[#p + 1] = kv("mine", jbool(mine))
    local reward = call(m, "getReward")
    p[#p + 1] = kv("reward", jnum(reward, "%.0f"))
    p[#p + 1] = kv("reimbursement", jnum(m.reimbursement, "%.0f"))
    -- what leasing the contract's machines costs, taken from the payout
    -- (AbstractMission:getVehicleCosts; hasLeasableVehicles guards it)
    local lease = nil
    if call(m, "hasLeasableVehicles") == true then lease = call(m, "getVehicleCosts") end
    p[#p + 1] = kv("leaseCost", jnum(lease, "%.0f"))
    p[#p + 1] = kv("leased", jbool(m.spawnedVehicles == true))
    p[#p + 1] = kv("completion", jnum(m.completion, "%.3f"))
    p[#p + 1] = kv("fieldPercentageDone", jnum(m.fieldPercentageDone, "%.3f"))
    -- the deadline, game day (monotonic) and time of day, and the game's
    -- own minutes-left reading of it (AbstractMission:getMinutesLeft)
    local endDay, endTime = nil, nil
    if type(m.endDate) == "table" then endDay, endTime = m.endDate.endDay, m.endDate.endDayTime end
    p[#p + 1] = kv("endDay", jint(endDay))
    p[#p + 1] = kv("endDayTime", jint(endTime))
    p[#p + 1] = kv("minutesLeft", jint(call(m, "getMinutesLeft")))
    p[#p + 1] = kv("fill", jstr(m.fillTypeIndex ~= nil and fillName(m.fillTypeIndex) or nil))
    local x, z = nil, nil
    if type(m.getWorldPosition) == "function" then
        local ok, wx, wz = pcall(m.getWorldPosition, m)
        if ok then x, z = wx, wz end
    end
    if not finite(x) and field ~= nil then x, z = field.posX, field.posZ end
    p[#p + 1] = kv("x", jnum(x, "%.1f"))
    p[#p + 1] = kv("z", jnum(z, "%.1f"))
    job.rows[#job.rows + 1] = { mine = mine, reward = num(reward), id = tostring(m.uniqueId), json = obj(p) }
end

local function missionRows(job, list, from)
    for k = from, math.min(#list, from + MISSIONS_PER_UNIT - 1) do missionRow(job, list[k]) end
end

local function finishMissions(job)
    local rows = job.rows
    -- yours first, then the best-paying offer (the plugin's contracts order)
    table.sort(rows, function(a, b)
        if a.mine ~= b.mine then return a.mine end
        if a.reward ~= b.reward then return a.reward > b.reward end
        return a.id < b.id
    end)
    local out = {}
    for i = 1, math.min(#rows, MAX_MISSIONS) do out[i] = rows[i].json end
    local active, max = FarmHandEdge.missionLimit(job.farmId)
    return obj({
        '"event":"missions"', kv("now", clockJson(clock())),
        kv("limit", obj({ kv("active", jint(active)), kv("max", jint(max)) })),
        kv("canManage", jbool(FarmHandEdge.canManageContracts())),
        kv("total", jint(job.total)), kv("items", arr(out)),
    })
end

--- Start a missions build: a few contracts per unit, then the sort and the
--- frame in a unit of their own.
function FarmHandEdge.missionsBegin(farmId)
    local job = newJob(finishMissions)
    job.farmId, job.rows = farmId, {}
    local list = {}
    for _, m in pairs(missionList()) do list[#list + 1] = m end
    job.total = #list
    for from = 1, #list, MISSIONS_PER_UNIT do addUnit(job, missionRows, list, from, "missions") end
    return job
end

function FarmHandEdge.missions(farmId)
    return runJob(FarmHandEdge.missionsBegin(farmId))
end

-- ---------------------------------------------------------------- weather

local MS_PER_MIN = 60000
local MS_PER_DAY = 86400000

local function itemTime(item)
    local t = num(item.startDayTime)
    return math.floor(t / 3600000) % 24, math.floor(t / MS_PER_MIN) % 60
end

function FarmHandEdge.weather()
    local env, w = nil, nil
    pcall(function() env = g_currentMission.environment; w = env.weather end)
    if w == nil then return nil end
    local C = FarmHandCollectors
    local p = { '"event":"weather"' }
    local nowType = nil
    pcall(function() nowType = w:getCurrentWeatherType() end)
    p[#p + 1] = kv("now", jint(nowType))
    local temp = nil
    pcall(function() temp = w:getCurrentTemperature() end)
    p[#p + 1] = kv("temp", jnum(temp, "%.1f"))
    -- in-game 22 Oct: getCurrentMinMaxTemperatures() returned 24, 34
    local lo, hi = nil, nil
    pcall(function() lo, hi = w:getCurrentMinMaxTemperatures() end)
    p[#p + 1] = kv("min", jnum(lo, "%.0f"))
    p[#p + 1] = kv("max", jnum(hi, "%.0f"))
    local raining = nil
    pcall(function() raining = w:getIsRaining() end)
    p[#p + 1] = kv("raining", jbool(raining))
    -- getTimeUntilRain: ms of game time, math.huge when no rain is due today
    local untilRain = nil
    pcall(function() untilRain = w:getTimeUntilRain() end)
    p[#p + 1] = kv("rainInMin", finite(untilRain) and jint(untilRain / MS_PER_MIN) or "null")

    -- The forecast list (in-game 22 Oct: 33 items, each startDay, startDayTime,
    -- duration, objectIndex, variationIndex, season). Item 1 is the weather now.
    local items, change, nextItem = {}, nil, nil
    local cur = nowType
    pcall(function()
        for i, item in ipairs(w.forecastItems) do
            if i > MAX_FORECAST then break end
            local t = C.forecastItemType(w, item)
            local hh, mm = itemTime(item)
            local j = obj({
                kv("type", jint(t)), kv("day", jint(item.startDay)), kv("hour", jint(hh)), kv("minute", jint(mm)),
                kv("durationMin", jint(num(item.duration) / MS_PER_MIN)),
            })
            items[#items + 1] = j
            if i == 1 and cur == nil then cur = t end
            if i == 2 then nextItem = j end
            if i > 1 and change == nil and t ~= nil and t ~= cur then change = j end
        end
    end)
    -- next: the forecast block after this one; change: the first block whose
    -- weather differs from now ("sun until 15:00, then rain")
    p[#p + 1] = kv("next", nextItem or "null")
    p[#p + 1] = kv("change", change or "null")
    p[#p + 1] = kv("items", arr(items))

    -- Daily outlook from the game's own forecast object. getDailyForecast exists
    -- (in-game 22 Oct); its argument (days ahead) and result fields (day,
    -- forecastType, highTemperature, lowTemperature) are UNPROVEN.
    local daily = {}
    pcall(function()
        local fc = w.forecast
        for d = 1, 5 do
            local ok, info = pcall(fc.getDailyForecast, fc, d)
            if ok and type(info) == "table" then
                daily[#daily + 1] = obj({
                    kv("day", jint(info.day)), kv("type", jint(info.forecastType)),
                    kv("high", jnum(info.highTemperature, "%.0f")), kv("low", jnum(info.lowTemperature, "%.0f")),
                })
            end
        end
    end)
    p[#p + 1] = kv("daily", arr(daily))
    return obj(p)
end

-- ---------------------------------------------------------------- players

--- Who is on the server, and what this player may do.
--- In-game 22 Oct: getIsServer, missionDynamicInfo.isMultiplayer,
--- userManager:getUsers with getNickname and getId, and
--- getUserByUserId(playerUserId):getIsMasterUser all answered in single player.
--- A user's farm (g_farmManager:getFarmByUserId) is FS22's, UNPROVEN.
function FarmHandEdge.players()
    local M = mission()
    local server, mp, master = nil, nil, nil
    pcall(function() server = M:getIsServer() == true end)
    pcall(function() mp = M.missionDynamicInfo.isMultiplayer == true end)
    pcall(function() master = M.userManager:getUserByUserId(M.playerUserId):getIsMasterUser() == true end)
    local users = {}
    pcall(function()
        for _, u in pairs(M.userManager:getUsers()) do
            if #users >= MAX_USERS then break end
            local id, nick, isMaster, farm = nil, nil, nil, nil
            pcall(function() id = u:getId() end)
            pcall(function() nick = u:getNickname() end)
            pcall(function() isMaster = u:getIsMasterUser() == true end)
            pcall(function() farm = g_farmManager:getFarmByUserId(id).farmId end)
            users[#users + 1] = { name = tostring(nick or ""), json = obj({
                kv("id", jint(id)), kv("name", jstr(nick)), kv("farm", jint(farm)), kv("master", jbool(isMaster)),
            }) }
        end
    end)
    table.sort(users, function(a, b) return a.name < b.name end)
    local uj = {}
    for i, u in ipairs(users) do uj[i] = u.json end
    return obj({
        '"event":"players"', kv("multiplayer", jbool(mp)), kv("server", jbool(server)), kv("master", jbool(master)),
        kv("me", jint(M ~= nil and M.playerUserId or nil)),
        -- what the widget can offer this player: speed is the host's alone
        kv("canSetSpeed", jbool(server)), kv("canManageContracts", jbool(FarmHandEdge.canManageContracts())),
        kv("users", arr(uj)),
    })
end

-- ---------------------------------------------------------------- scheduling

-- Cadence per frame, ms of real time. `onChange` frames are built on their
-- cadence but only SENT when they differ from the last one sent, or once a
-- minute so a reconnecting widget is never left without them. A frame with
-- `begin` is built in slices over several game frames (see stations above).
local FRAMES = {
    { name = "settings", every = 10000, onChange = true, begin = FarmHandEdge.settingsBegin, step = FarmHandEdge.stepJob },
    { name = "players",  every = 10000, onChange = true },
    { name = "workers",  every = 2000 },
    { name = "missions", every = 5000, begin = FarmHandEdge.missionsBegin, step = FarmHandEdge.stepJob },
    { name = "fields",   every = 6000 },
    { name = "stations", every = 10000, begin = FarmHandEdge.stationsBegin, step = FarmHandEdge.stepJob },
    { name = "storage",  every = 10000, begin = FarmHandEdge.storageBegin, step = FarmHandEdge.stepJob },
    { name = "sites",    every = 10000, begin = FarmHandEdge.sitesBegin, step = FarmHandEdge.stepJob },
    { name = "weather",  every = 30000 },
}
local HEARTBEAT_MS = 60000

FarmHandEdge.timers = {}
FarmHandEdge.lastSent = {}
FarmHandEdge.lastSentAt = {}
FarmHandEdge.wasConnected = false
FarmHandEdge.clockMs = 0
FarmHandEdge.reported = {}
FarmHandEdge.measured = {}
FarmHandEdge.job = nil

local function reportOnce(key, msg)
    if FarmHandEdge.reported[key] then return end
    FarmHandEdge.reported[key] = true
    print("[FarmHand] EDGE " .. tostring(msg))
end

local function build(name, farmId, watch, stops)
    if name == "players" then return FarmHandEdge.players() end
    if name == "workers" then return FarmHandEdge.workers(farmId, watch, stops) end
    if name == "fields" then return FarmHandEdge.fields(farmId) end
    if name == "weather" then return FarmHandEdge.weather() end
    return nil
end

local function deliver(f, line, transport)
    local due = not f.onChange or line ~= FarmHandEdge.lastSent[f.name]
        or (FarmHandEdge.clockMs - (FarmHandEdge.lastSentAt[f.name] or 0)) >= HEARTBEAT_MS
    if due then
        transport:sendTo("edge", line)
        FarmHandEdge.lastSent[f.name] = line
        FarmHandEdge.lastSentAt[f.name] = FarmHandEdge.clockMs
    end
end

--- The cost, once per frame type, for the frame-time check: the bytes, and
--- the most any single game frame spent on it; for a sliced frame also its
--- slowest unit of each kind.
local function measure(name, bytes, maxMs, frames, unitMax)
    if FarmHandEdge.measured[name] then return end
    FarmHandEdge.measured[name] = true
    local ms = maxMs ~= nil and string.format("%.2f ms", maxMs) or "time n/a"
    local units = ""
    if type(unitMax) == "table" then
        local kinds = {}
        for k in pairs(unitMax) do kinds[#kinds + 1] = k end
        table.sort(kinds)
        local parts = {}
        for _, k in ipairs(kinds) do parts[#parts + 1] = string.format("%s %.2f ms", k, unitMax[k]) end
        if #parts > 0 then units = "; slowest unit: " .. table.concat(parts, ", ") end
    end
    if frames ~= nil and frames > 1 then
        print(string.format("[FarmHand] EDGE %s: %d bytes over %d game frames, at most %s in one%s", name, bytes, frames, ms, units))
    else
        print(string.format("[FarmHand] EDGE %s: %d bytes, %s%s", name, bytes, ms, units))
    end
end

-- Steady state: the worst single game frame each frame type cost over the last
-- 10 minutes, logged once every 10 minutes, so warm builds are seen as well as
-- the first one.
local WORST_WINDOW_MS = 600000
FarmHandEdge.worst = {}
FarmHandEdge.worstSince = nil

local function noteWorst(name, ms)
    if ms == nil then return end
    if ms > (FarmHandEdge.worst[name] or -1) then FarmHandEdge.worst[name] = ms end
end

local function reportWorst()
    if FarmHandEdge.worstSince == nil then FarmHandEdge.worstSince = FarmHandEdge.clockMs return end
    if FarmHandEdge.clockMs - FarmHandEdge.worstSince < WORST_WINDOW_MS then return end
    local names = {}
    for k in pairs(FarmHandEdge.worst) do names[#names + 1] = k end
    table.sort(names)
    if #names > 0 then
        local parts = {}
        for _, k in ipairs(names) do parts[#parts + 1] = string.format("%s %.2f ms", k, FarmHandEdge.worst[k]) end
        print("[FarmHand] EDGE worst single frame, last 10 min: " .. table.concat(parts, ", "))
    end
    FarmHandEdge.worst = {}
    FarmHandEdge.worstSince = FarmHandEdge.clockMs
end

local function elapsedMs(t0)
    local t1 = now()
    if t0 == nil or t1 == nil then return nil end
    return (t1 - t0) * 1000
end

--- Ask for a frame on the next game frames rather than at its next cadence
--- (after a command whose result it shows, such as an accepted contract).
function FarmHandEdge.soon(name, inMs)
    for _, f in ipairs(FRAMES) do
        if f.name == name then
            FarmHandEdge.timers[name] = math.max(FarmHandEdge.timers[name] or 0, f.every - (inMs or 0))
        end
    end
end

--- Build what is due and send it to the widget pipe. Does nothing at all while
--- the widget is not connected. At most one frame type, or one slice of a
--- sliced frame, per game frame: the rest wait for the next.
function FarmHandEdge.update(dt, transport, farmId, watch, stops)
    if transport == nil or not transport:connected("edge") then
        FarmHandEdge.wasConnected = false
        FarmHandEdge.job = nil
        return
    end
    FarmHandEdge.clockMs = FarmHandEdge.clockMs + dt
    if not FarmHandEdge.wasConnected then
        -- A fresh connection gets everything at once, spread one frame type per
        -- game frame so no single frame pays for all of them.
        FarmHandEdge.wasConnected = true
        for i, f in ipairs(FRAMES) do FarmHandEdge.timers[f.name] = f.every - (i - 1) * 50 end
        FarmHandEdge.lastSent = {}
    end
    for _, f in ipairs(FRAMES) do FarmHandEdge.timers[f.name] = (FarmHandEdge.timers[f.name] or 0) + dt end
    reportWorst()

    -- a sliced frame in progress takes this game frame
    local job = FarmHandEdge.job
    if job ~= nil then
        local t0 = now()
        local ok, line = pcall(job.frame.step, job.state, MAX_UNITS_PER_SLICE, t0 ~= nil and (t0 + UNIT_BUDGET_S) or nil)
        local ms = elapsedMs(t0)
        job.frames = job.frames + 1
        if ms ~= nil and (job.maxMs == nil or ms > job.maxMs) then job.maxMs = ms end
        noteWorst(job.frame.name, ms)
        if not ok then
            FarmHandEdge.job = nil
            reportOnce(job.frame.name .. ":" .. tostring(line), job.frame.name .. " dropped a frame: " .. tostring(line))
        elseif line ~= nil then
            FarmHandEdge.job = nil
            deliver(job.frame, line, transport)
            measure(job.frame.name, #line, job.maxMs, job.frames, job.state.unitMax)
        end
        return
    end

    for _, f in ipairs(FRAMES) do
        if FarmHandEdge.timers[f.name] >= f.every then
            FarmHandEdge.timers[f.name] = 0
            local t0 = now()
            if f.begin ~= nil then
                local ok, state = pcall(f.begin, farmId)
                if ok then
                    local ms = elapsedMs(t0)
                    noteWorst(f.name, ms)
                    FarmHandEdge.job = { frame = f, state = state, frames = 1, maxMs = ms }
                else
                    reportOnce(f.name .. ":" .. tostring(state), f.name .. " could not start: " .. tostring(state))
                end
                return
            end
            local ok, line = pcall(build, f.name, farmId, watch, stops)
            if not ok then
                reportOnce(f.name .. ":" .. tostring(line), f.name .. " dropped a frame: " .. tostring(line))
            elseif line ~= nil then
                local ms = elapsedMs(t0)
                deliver(f, line, transport)
                noteWorst(f.name, ms)
                measure(f.name, #line, ms, 1)
            end
            return
        end
    end
end

--- Forget per-connection and per-save state (mission end, farm change).
function FarmHandEdge.reset()
    FarmHandEdge.timers = {}
    FarmHandEdge.lastSent = {}
    FarmHandEdge.lastSentAt = {}
    FarmHandEdge.wasConnected = false
    FarmHandEdge.measured = {}
    FarmHandEdge.job = nil
    FarmHandEdge.worst = {}
    FarmHandEdge.worstSince = nil
    FarmHandEdge.resetCaches()
end
