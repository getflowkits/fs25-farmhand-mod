-- FarmHand Telemetry :: Probe
--
-- Discovery for the FS25 Farmhand (Edge) widget. Writes what the running game
-- actually exposes to modSettings/FS25_Farmhand/probe.txt, so the widget's
-- farm-wide collectors and commands are built on names the game really has,
-- not on FS22 memory or a partial script dump.
--
-- It only READS, with one exception that is undone at once (probeTimeScale).
-- Runs once per savegame load when modSettings/FS25_Farmhand/probe.on exists,
-- and on demand through the `probeReport` command. Every step is pcall-guarded:
-- a missing name is a finding, never an error.

FarmHandProbe = {}

local out = nil
local function w(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    out[#out + 1] = ok and s or tostring(fmt)
end

local function scalar(v)
    local t = type(v)
    return t == "number" or t == "boolean" or t == "string"
end

--- Every key on a table and up its class chain (metatable __index), with its
--- type and, for scalars, its value. Capped so a huge table cannot flood.
local function keys(label, obj, cap, filter)
    cap = cap or 120
    if type(obj) ~= "table" then w("%s: <%s>", label, type(obj)) return end
    local seen, rows, n, depth, cur = {}, {}, 0, 0, obj
    while type(cur) == "table" and depth < 6 do
        for k, v in pairs(cur) do
            if type(k) == "string" and not seen[k] and (filter == nil or string.find(string.lower(k), filter, 1, true)) then
                seen[k] = true
                n = n + 1
                if n <= cap then
                    rows[#rows + 1] = scalar(v) and string.format("%s=%s", k, tostring(v)) or string.format("%s:%s", k, type(v))
                end
            end
        end
        local mt = getmetatable(cur)
        cur = mt ~= nil and type(mt.__index) == "table" and mt.__index or nil
        depth = depth + 1
    end
    table.sort(rows)
    w("%s (%d keys%s): %s", label, n, n > cap and (", first " .. cap) or "", table.concat(rows, "  "))
end

local function section(name) w("") w("=== %s ===", name) end
local function try(label, fn) local ok, err = pcall(fn) if not ok then w("%s FAILED: %s", label, tostring(err)) end end

function FarmHandProbe.report(farmId)
    out = {}
    w("FS25 Farmhand probe, mod %s, farm %s", tostring(Farmhand ~= nil and Farmhand.VERSION or "?"), tostring(farmId))
    local M = g_currentMission

    section("settings (missionInfo)")
    try("missionInfo", function() keys("missionInfo", M.missionInfo, 400) end)
    try("gameSettings", function() keys("g_gameSettings", g_gameSettings, 200) end)

    section("time and speed")
    try("time", function()
        w("timeScale=%s  isPaused=%s  manualPaused=%s", tostring(M.missionInfo.timeScale), tostring(M.paused), tostring(M.manualPaused))
        keys("mission functions with time/pause/scale", M, 80, "time")
        keys("mission functions with pause", M, 40, "pause")
    end)

    section("fields")
    try("fields", function()
        local fields = g_fieldManager:getFields()
        w("fields total=%d", #fields)
        local owned = 0
        for i, f in ipairs(fields) do
            local fl = nil
            pcall(function() fl = f:getFarmland() end)
            local owner = nil
            pcall(function() owner = g_farmlandManager:getFarmlandOwner(fl.id) end)
            if owner == farmId then
                owned = owned + 1
                if owned <= 2 then
                    keys("field[" .. i .. "]", f, 160)
                    try("fieldState", function() keys("field[" .. i .. "].fieldState", f.fieldState or (f.getFieldState and f:getFieldState()), 120) end)
                    keys("farmland", fl, 60)
                end
            end
        end
        w("owned by this farm=%d", owned)
        keys("g_fieldManager", g_fieldManager, 120)
        keys("g_farmlandManager", g_farmlandManager, 80)
    end)
    try("fruitTypes", function()
        local ft = g_fruitTypeManager:getFruitTypes()
        w("fruit types=%d", #ft)
        keys("fruitType[1]", ft[1], 200)
        for _, f in ipairs(ft) do
            if f.name == "POTATO" or f.name == "WHEAT" then keys("fruitType " .. f.name, f, 200) end
        end
    end)

    section("sell stations and storage")
    try("storageSystem", function()
        local ss = M.storageSystem
        keys("storageSystem", ss, 120)
        local stations = nil
        pcall(function() stations = ss:getUnloadingStations() end)
        if type(stations) == "table" then
            local n, shown = 0, 0
            for _, st in pairs(stations) do
                n = n + 1
                local sell = st.isSellingPoint
                if sell and shown < 2 then
                    shown = shown + 1
                    keys("sellingStation", st, 200)
                    try("station name", function() w("getName=%s", tostring(st:getName())) end)
                    try("station hotspot", function() keys("station.owningPlaceable", st.owningPlaceable, 120, "hotspot") end)
                end
            end
            w("unloading stations=%d", n)
        else
            w("getUnloadingStations: <%s>", type(stations))
        end
        local storages = nil
        pcall(function() storages = ss:getStorages() end)
        if type(storages) == "table" then
            for _, s in pairs(storages) do
                local own = nil
                pcall(function() own = s:getOwnerFarmId() end)
                if own == farmId then keys("farm storage", s, 160) break end
            end
        end
    end)

    section("AI workers")
    try("ai", function()
        keys("g_currentMission.aiSystem", M.aiSystem, 120)
        local found = 0
        for _, v in ipairs(M.vehicleSystem.vehicles) do
            local active = false
            pcall(function() active = v:getIsAIActive() end)
            if active and found < 2 then
                found = found + 1
                keys("vehicle(ai) functions: ai", v, 120, "ai")
                keys("vehicle(ai) functions: stop", v, 60, "stop")
                try("spec_aiJobVehicle", function() keys("spec_aiJobVehicle", v.spec_aiJobVehicle, 120) end)
                try("job", function()
                    local job = v:getJob()
                    keys("job", job, 160)
                    try("job title", function() w("job:getTitle=%s", tostring(job:getTitle())) end)
                    try("task", function() keys("job.currentTask", job.currentTask or (job.tasks and job.tasks[job.currentTaskIndex or 1]), 120) end)
                end)
                try("spec_aiFieldWorker", function() keys("spec_aiFieldWorker", v.spec_aiFieldWorker, 120) end)
            end
        end
        w("AI-active vehicles inspected=%d", found)
        for _, name in ipairs({ "AIMessageErrorOutOfFuel", "AIMessageErrorOutOfFill", "AIMessageErrorBlockedByObject",
                                "AIMessageErrorUnloadingStationFull", "AIMessageErrorFieldNotReady", "AIMessageSuccessFinishedJob",
                                "AIMessageSuccessStoppedByUser", "AIMessageErrorVehicleBroken", "AIMessageErrorNoFieldFound" }) do
            w("%s: %s", name, type(_G[name]))
        end
    end)

    section("contracts")
    try("missions", function()
        keys("g_missionManager", g_missionManager, 160)
        local list = g_missionManager.missions or (g_missionManager.getMissions and g_missionManager:getMissions())
        local n = 0
        for _, m in pairs(list or {}) do
            n = n + 1
            if n <= 2 then keys("mission", m, 200) end
        end
        w("missions=%d", n)
    end)

    section("weather")
    try("weather", function()
        local env = M.environment
        keys("environment", env, 120)
        keys("weather", env.weather, 160)
        try("forecast", function() keys("weather.forecast", env.weather.forecast, 120) end)
    end)

    section("players (multiplayer)")
    try("users", function()
        keys("userManager", M.userManager, 80)
        local users = M.userManager:getUsers()
        local names = {}
        for _, u in pairs(users or {}) do
            local nick, uid = "?", "?"
            pcall(function() nick = u:getNickname() end)
            pcall(function() uid = u:getId() end)
            names[#names + 1] = string.format("%s(id %s)", tostring(nick), tostring(uid))
        end
        w("users: %s", table.concat(names, ", "))
        keys("playerSystem", M.playerSystem, 80)
    end)

    section("map, hotspots, menu")
    try("map", function()
        keys("mission functions with hotspot", M, 60, "hotspot")
        keys("mission functions with target", M, 40, "target")
        keys("ingameMap", M.hud ~= nil and M.hud.getIngameMap and M.hud:getIngameMap() or nil, 120)
        local menu = g_gui ~= nil and g_gui.screenControllers ~= nil and g_gui.screenControllers[InGameMenu] or g_inGameMenu
        keys("InGameMenu pages", menu, 80, "page")
        try("pageMapOverview", function() keys("pageMapOverview", menu.pageMapOverview, 160) end)
    end)

    section("helper and economy names")
    for _, name in ipairs({ "MissionStartEvent", "AIJobStartRequestEvent", "AIJobStopEvent", "AIJobFieldWork", "InGameMenuMapFrame",
                            "MapHotspot", "PlaceableHotspot", "FieldHotspot", "AIHotspot", "MissionManager" }) do
        w("%s: %s", name, type(_G[name]))
    end

    local path = nil
    pcall(function() path = getUserProfileAppPath() .. "modSettings/FS25_Farmhand/probe.txt" end)
    if path ~= nil then
        pcall(function()
            local f = io.open(path, "w")
            if f ~= nil then f:write(table.concat(out, "\n")) f:close() end
        end)
    end
    print(string.format("[FarmHand] probe report written (%d lines) to %s", #out, tostring(path)))
    out = nil
    return true
end

--- Functions on an object whose class hides behind a metatable that keys()
--- cannot walk (an __index FUNCTION, as weather.forecast has): ask for each
--- candidate name directly.
local function has(label, obj, names)
    local found = {}
    for _, n in ipairs(names) do
        local t = nil
        pcall(function() t = type(obj[n]) end)
        if t ~= nil and t ~= "nil" then found[#found + 1] = n .. ":" .. t end
    end
    w("%s has: %s", label, #found > 0 and table.concat(found, "  ") or "(none of the candidates)")
end

local function call(label, fn)
    local ok, a, b, c = pcall(fn)
    w("%s -> ok=%s  %s  %s  %s", label, tostring(ok), tostring(a), tostring(b), tostring(c))
    return ok and a or nil
end

--- Round two (22 Oct): the gaps the first report left open.
function FarmHandProbe.report2(farmId)
    out = {}
    w("FS25 Farmhand probe round 2, farm %s", tostring(farmId))
    local M = g_currentMission

    section("AI stop reason classes")
    local names = {}
    for _, n in ipairs({ "AIMessageErrorFieldNotReady", "AIMessageErrorWrongSeason", "AIMessageErrorNotReachable",
                         "AIMessageErrorOutOfMoney", "AIMessageErrorNoValidFillTypeLoaded", "AIMessageErrorLoadingStationDeleted",
                         "AIMessageErrorUnloadingStationDeleted", "AIMessageErrorPlaceableDeleted", "AIMessageErrorIsFull",
                         "AIMessageErrorGroundUnloadNotSupported", "AIMessageErrorNoPathFound", "AIMessageErrorCannotFindPath",
                         "AIMessageErrorUnknown", "AIMessageErrorThreshingNotAllowed", "AIMessageErrorWrongBaleType",
                         "AIMessageErrorVehicleDeleted", "AIMessageSuccessWorkFinished", "AIMessageErrorFieldNotOwned",
                         "AIMessageErrorNoFillType", "AIMessageErrorOutOfSeeds", "AIMessageErrorOutOfFertilizer" }) do
        local t = nil
        pcall(function() t = type(_G[n]) end)
        names[#names + 1] = n .. "=" .. tostring(t)
    end
    w("%s", table.concat(names, "  "))

    section("weather forecast")
    try("forecast", function()
        local wx = M.environment.weather
        local f = wx.forecast
        local mt = getmetatable(f)
        w("forecast metatable=%s __index=%s", type(mt), mt and type(mt.__index) or "-")
        has("forecast", f, { "getForecast", "getHourlyForecast", "getDailyForecast", "getCurrentWeather", "dataByDay",
                             "getForecastForTime", "update", "items", "forecastItems", "getWeatherTypeAtTime" })
        has("weather", wx, { "getCurrentWeatherType", "getNextWeatherType", "getWeatherTypeAtTime", "getCurrentTemperature",
                             "getCurrentMinMaxTemperatures", "getForecast", "getTimeUntilRain", "getIsRaining", "getRainFallScale",
                             "getSnowFallScale", "getCurrentWeatherObject", "getTemperature", "getTimeUntilNextWeatherType" })
        call("weather:getCurrentWeatherType()", function() return wx:getCurrentWeatherType() end)
        call("weather:getCurrentTemperature()", function() return wx:getCurrentTemperature() end)
        call("weather:getCurrentMinMaxTemperatures()", function() return wx:getCurrentMinMaxTemperatures() end)
        local n = 0
        for i, item in ipairs(wx.forecastItems or {}) do
            n = n + 1
            if i <= 3 then keys("forecastItems[" .. i .. "]", item, 40) end
        end
        w("forecastItems=%d", n)
        keys("WeatherType", _G["WeatherType"], 30)
    end)

    section("map target and show on map")
    try("player", function()
        local p = g_localPlayer
        if p == nil then pcall(function() p = M.playerSystem:getLocalPlayer() end) end
        keys("localPlayer target/hotspot/flag", p, 40, "target")
        keys("localPlayer hotspot", p, 40, "hotspot")
        has("mission", M, { "setMapTargetHotspot", "getMapTargetHotspot", "setMapTarget", "removeMapTarget", "addMapHotspot",
                            "removeMapHotspot", "mapTargetHotspot" })
        local map = M.hud:getIngameMap()
        keys("ingameMap target", map, 40, "target")
        keys("ingameMap select", map, 40, "select")
        has("ingameMap", map, { "setSelectedHotspot", "setTargetHotspot", "toggleMapTarget", "setMapTarget", "getHotspotIndex" })
        has("InGameMenuMapFrame", InGameMenuMapFrame, { "setMapTargetHotspot", "onClickSetTarget", "onClickHotspot",
                                                        "showContextBox", "setMapSelectionItem", "selectHotspot",
                                                        "onClickGotoHotspot", "centerMapOnHotspot", "setTargetHotspot" })
        keys("InGameMenuMapFrame target", InGameMenuMapFrame, 40, "target")
        keys("InGameMenuMapFrame hotspot", InGameMenuMapFrame, 60, "hotspot")
    end)

    section("AI job progress")
    try("job", function()
        keys("AIJobFieldWork functions", AIJobFieldWork, 120)
        for _, v in ipairs(M.vehicleSystem.vehicles) do
            local active = false
            pcall(function() active = v:getIsAIActive() end)
            if active then
                local job = v:getJob()
                keys("job.tasks[1]", job.tasks and job.tasks[1], 60)
                keys("job.tasks[2]", job.tasks and job.tasks[2], 60)
                keys("spec_aiFieldWorker.fieldJob", v.spec_aiFieldWorker and v.spec_aiFieldWorker.fieldJob, 60)
                keys("spec_aiJobVehicle.currentHelper", v.spec_aiJobVehicle and v.spec_aiJobVehicle.currentHelper, 40)
                call("job:getPricePerMs()", function() return job:getPricePerMs() end)
                call("job:getProgress()", function() return job:getProgress() end)
                call("job:getTarget()", function() return job:getTarget() end)
                break
            end
        end
    end)

    section("contracts detail")
    try("missions", function()
        local n = 0
        for _, m in pairs(g_missionManager.missions or {}) do
            n = n + 1
            if n <= 2 then
                keys("mission.endDate", m.endDate, 20)
                keys("mission.info", m.info, 30)
                keys("mission.type", m.type, 30)
                keys("mission get", m, 80, "get")
                call("mission:getReward()", function() return m:getReward() end)
                call("mission:getTotalReward()", function() return m:getTotalReward() end)
                call("mission:getLocation()", function() return m:getLocation() end)
                call("mission:getFarmlandId()", function() return m:getFarmlandId() end)
                call("mission:getMissionTypeName()", function() return m:getMissionTypeName() end)
            end
        end
        keys("MissionStatus", _G["MissionStatus"], 20)
        keys("g_missionManager start/accept", g_missionManager, 40, "start")
        keys("MissionStartEvent", MissionStartEvent, 30)
    end)

    section("selling points and prices")
    try("stations", function()
        local shown, total = 0, 0
        local wheat = g_fillTypeManager:getFillTypeIndexByName("WHEAT")
        for _, st in pairs(M.storageSystem:getUnloadingStations()) do
            if st.isSellingPoint and not st.hideFromPricesMenu then
                total = total + 1
                if shown < 3 then
                    shown = shown + 1
                    local name = nil
                    pcall(function() name = st:getName() end)
                    w("station %s id=%s", tostring(name), tostring(st.id))
                    call("  getEffectiveFillTypePrice(WHEAT)", function() return st:getEffectiveFillTypePrice(wheat) end)
                    call("  fillTypePrices[WHEAT]", function() return st.fillTypePrices[wheat] end)
                    call("  getSupportsGreatDemand(WHEAT)", function() return st:getSupportsGreatDemand(wheat) end)
                    keys("  station price fns", st, 30, "price")
                    local pl = st.owningPlaceable
                    call("  placeable:getHotspot(1)", function() return pl:getHotspot(1) end)
                    call("  placeable rootNode world pos", function() return getWorldTranslation(pl.rootNode) end)
                    call("  placeable:getName()", function() return pl:getName() end)
                end
            end
        end
        w("visible selling points=%d", total)
        keys("g_currentMission.economyManager", M.economyManager, 60)
    end)

    section("storage contents")
    try("storage", function()
        for _, s in pairs(M.storageSystem:getStorages()) do
            local own = nil
            pcall(function() own = s:getOwnerFarmId() end)
            if own == farmId then
                local parts = {}
                for ft, lvl in pairs(s.fillLevels or {}) do
                    local nm = nil
                    pcall(function() nm = g_fillTypeManager:getFillTypeNameByIndex(ft) end)
                    if lvl ~= nil and lvl > 0 then parts[#parts + 1] = string.format("%s=%d", tostring(nm), lvl) end
                end
                local placeName = nil
                pcall(function() placeName = s.owningPlaceable and s.owningPlaceable:getName() end)
                w("storage id=%s place=%s capacity=%s levels: %s", tostring(s.id), tostring(placeName), tostring(s.capacity),
                    #parts > 0 and table.concat(parts, " ") or "(empty)")
            end
        end
    end)

    section("fields: number, needs, windows")
    try("fields", function()
        local shown = 0
        for _, f in ipairs(g_fieldManager:getFields()) do
            local fl = f.farmland
            if fl ~= nil and fl.farmId == farmId and shown < 2 then
                shown = shown + 1
                keys("field get", f, 60, "get")
                call("field:getId()", function() return f:getId() end)
                call("field:getName()", function() return f:getName() end)
                call("field.farmland.id", function() return fl.id end)
                keys("fieldState fns", f.fieldState, 40, "get")
            end
        end
        local wheat = g_fruitTypeManager:getFruitTypeByName("WHEAT")
        keys("WHEAT growthStateToName", wheat.growthStateToName, 20)
        keys("WHEAT growthDataSeasonal", wheat.growthDataSeasonal, 30)
        try("growthDataSeasonal periods", function()
            local g = wheat.growthDataSeasonal
            keys("  .plantingPeriods", g.plantingPeriods or g.plantingAllowed, 20)
            keys("  .harvestPeriods", g.harvestPeriods or g.harvestReady, 20)
            keys("  .periods[1]", g.periods and g.periods[1], 30)
        end)
        keys("growthSystem", M.growthSystem, 60)
        keys("missionInfo wither", M.missionInfo, 20, "wither")
        keys("growthSystem wither", M.growthSystem, 20, "wither")
        keys("g_currentMission wither", M, 20, "wither")
    end)

    section("multiplayer host check")
    call("mission:getIsServer()", function() return M:getIsServer() end)
    call("mission:getIsClient()", function() return M:getIsClient() end)
    call("missionDynamicInfo.isMultiplayer", function() return M.missionDynamicInfo.isMultiplayer end)
    call("isMasterUserConnected", function() return M.isMasterUserConnected end)
    try("master user", function()
        local u = M.userManager:getUserByUserId(M.playerUserId)
        call("user:getIsMasterUser()", function() return u:getIsMasterUser() end)
        keys("user fns", u, 40, "get")
    end)

    section("prices list scrolling")
    try("productList", function()
        local menu = g_gui.guis["InGameMenu"].target
        local list = menu.pageStatistics.productList
        has("productList", list, { "makeCellVisible", "scrollToItemInSection", "scrollTo", "setSelectedItem",
                                   "smoothScrollTo", "scrollToIndex", "updateView" })
    end)

    local path = nil
    pcall(function() path = getUserProfileAppPath() .. "modSettings/FS25_Farmhand/probe2.txt" end)
    if path ~= nil then
        pcall(function()
            local fh = io.open(path, "w")
            if fh ~= nil then fh:write(table.concat(out, "\n")) fh:close() end
        end)
    end
    print(string.format("[FarmHand] probe round 2 written (%d lines) to %s", #out, tostring(path)))
    out = nil
    return true
end

--- Does setting the time scale from a mod work? Sets it, reads it back, puts it
--- back exactly as it was, and logs all three values.
function FarmHandProbe.timeScale(value)
    local M = g_currentMission
    local before = M.missionInfo.timeScale
    local ok, err = pcall(function() M:setTimeScale(value) end)
    local after = M.missionInfo.timeScale
    pcall(function() M:setTimeScale(before) end)
    print(string.format("[FarmHand] probeTimeScale: set %s ok=%s err=%s read-back %s, restored to %s",
        tostring(value), tostring(ok), tostring(err), tostring(after), tostring(M.missionInfo.timeScale)))
    return ok
end

--- Runs the report once per load when the probe.on marker file exists.
function FarmHandProbe.autoRun(farmId)
    local path = nil
    pcall(function() path = getUserProfileAppPath() .. "modSettings/FS25_Farmhand/probe.on" end)
    if path == nil or fileExists == nil or not fileExists(path) then return end
    pcall(FarmHandProbe.report, farmId)
end
