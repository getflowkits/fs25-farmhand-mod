-- FarmHand Telemetry :: widget commands (2.20)
--
-- Commands the FlowKits Companion (Xeneon Edge widget) sends: show something on
-- the map, set the map target, stop a worker, accept a contract.
--
-- Each one returns true, or false and a short reason the widget shows on the
-- button ("Not found", "Host only", "Already accepted"). Registered through
-- FarmHandCommands.register, so they run on foot and their acks ride the
-- widget pipe like every other widget command (Transport.lua ack).
--
-- Every target is addressed by the id the widget frames carry
-- (EdgeCollectors.lua), resolved with the same walk that produced it, so the
-- name on the widget and the thing acted on can never disagree.
--
-- Nothing here skips a cost or touches another farm: each is a thing the player
-- can do in the menus, done the way the menus do it.

FarmHandEdgeCommands = {}

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[FarmHand] " .. (ok and msg or tostring(fmt)))
end

local function farmId() return Farmhand ~= nil and Farmhand.farmId or nil end

--- "kind:id" -> kind, id. The id keeps any further colons (a name may have one).
local function parseRef(arg)
    if type(arg) ~= "string" then return nil, nil end
    local kind, id = arg:match("^%s*([%a]+)%s*:%s*(.-)%s*$")
    if kind == nil or id == nil or id == "" then return nil, nil end
    return string.lower(kind), id
end

local function inGameMenu()
    local menu = nil
    pcall(function() menu = g_gui.guis["InGameMenu"].target end)
    if type(menu) ~= "table" then pcall(function() menu = g_inGameMenu end) end
    if type(menu) ~= "table" then return nil end
    return menu
end

-- ---------------------------------------------------------------- targets

--- The farm's animal pen or production point, by network id or by the name
--- the plugin's estate frame sends (case-insensitive, the openProduction rule).
local function findHusbandry(id)
    local want, wantId = string.upper(id), tonumber(id)
    local found = nil
    pcall(function()
        for _, pl in pairs(g_currentMission.placeableSystem.placeables) do
            if pl.spec_husbandryAnimals ~= nil and pl.ownerFarmId == farmId() then
                local n, nid = nil, nil
                pcall(function() n = pl:getName() end)
                pcall(function() nid = NetworkUtil.getObjectId(pl) end)
                if (wantId ~= nil and nid == wantId) or (type(n) == "string" and string.upper(n) == want) then
                    found = pl
                    return
                end
            end
        end
    end)
    return found
end

local function findProduction(id)
    local want, wantId = string.upper(id), tonumber(id)
    local found = nil
    pcall(function()
        for _, pp in pairs(g_currentMission.productionChainManager:getProductionPointsForFarmId(farmId())) do
            local pl = pp.owningPlaceable
            local n, nid = nil, nil
            pcall(function() n = pl:getName() end)
            pcall(function() nid = NetworkUtil.getObjectId(pl) end)
            if pl ~= nil and ((wantId ~= nil and nid == wantId) or (type(n) == "string" and string.upper(n) == want)) then
                found = pl
                return
            end
        end
    end)
    return found
end

--- A placeable's map hotspot. In-game 22 Oct: a selling station's
--- owningPlaceable has getHotspot, and getHotspot(1) returned a table.
--- spec_hotspots exists too; its mapHotspots list is FS22's name, UNPROVEN.
local function placeableHotspot(pl)
    if pl == nil then return nil end
    local h = nil
    pcall(function() h = pl:getHotspot(1) end)
    if h == nil then pcall(function() h = pl.spec_hotspots.mapHotspots[1] end) end
    return h
end

--- The hotspot for a widget reference, or nil and the reason.
---
--- vehicle   vehicle:getMapHotspot() (AIJobVehicle overrides it to the worker's
---           hotspot while hired; UNPROVEN in game), then
---           spec_aiJobVehicle.mapAIHotspot, then vehicle.mapHotspot
--- field     the field's farmland.mapHotspot (in-game 22 Oct: farmland carries
---           mapHotspot); field numbers are the game's own (f:getId())
--- contract  mission.mapHotspot, else the first of getMapHotspots() or
---           mapHotspots (in-game 22 Oct: both keys exist on a mission)
--- station   the selling station's placeable, getHotspot(1) (in-game 22 Oct)
--- husbandry, production   the placeable's getHotspot(1) (same call, UNPROVEN
---           on these placeable types)
local function resolveHotspot(kind, id)
    local fid = farmId()
    local h = nil
    if kind == "vehicle" then
        local v = FarmHandEdge.findVehicle(id, fid)
        if v == nil then return nil, "Not found" end
        pcall(function() h = v:getMapHotspot() end)
        if h == nil then pcall(function() h = v.spec_aiJobVehicle.mapAIHotspot end) end
        if h == nil then pcall(function() h = v.mapHotspot end) end
    elseif kind == "field" then
        local f = FarmHandEdge.findField(id)
        if f == nil then return nil, "Not found" end
        pcall(function() h = f.farmland.mapHotspot end)
        if h == nil then pcall(function() h = f.mapHotspot end) end
    elseif kind == "contract" then
        local m = FarmHandEdge.findMission(id)
        if m == nil then return nil, "Not found" end
        local owner = FarmHandEdge.missionFarm(m)
        if owner ~= nil and owner ~= fid then return nil, "Not found" end
        pcall(function() h = m.mapHotspot end)
        if h == nil then pcall(function() h = m:getMapHotspots()[1] end) end
        if h == nil then pcall(function() h = m.mapHotspots[1] end) end
    elseif kind == "station" then
        local st = FarmHandEdge.findStation(id)
        if st == nil then return nil, "Not found" end
        h = placeableHotspot(st.owningPlaceable)
    elseif kind == "husbandry" then
        local pl = findHusbandry(id)
        if pl == nil then return nil, "Not found" end
        h = placeableHotspot(pl)
    elseif kind == "production" then
        local pl = findProduction(id)
        if pl == nil then return nil, "Not found" end
        h = placeableHotspot(pl)
    else
        return nil, "Not supported"
    end
    if h == nil then return nil, "Not on the map" end
    return h
end

-- ---------------------------------------------------------------- showOnMap

-- The map page can lay itself out over the frames after it opens and drop a
-- selection made on the first one (the prices list did exactly that, in-game
-- 22 Oct), so the focus is made again a few frames later.
local pendingFocus = nil

--- Open the map page with a hotspot selected.
--- arg: vehicle:<id>, field:<n>, contract:<uniqueId>, station:<id>,
--- husbandry:<name or id>, production:<name or id>.
---
--- InGameMenuMapFrame.showMapHotspot exists (in-game 22 Oct), and it is what
--- other FS25 mods call after opening the map overview to centre and select a
--- vehicle; the page is pageMapOverview (in-game 22 Oct). Opening uses the
--- plugin's proven openMenuPage, which honours openOnly: a widget tap never
--- closes the map.
local function showOnMap(_, _, arg)
    local kind, id = parseRef(arg)
    if kind == nil then return false, "Not found" end
    local h, why = resolveHotspot(kind, id)
    if h == nil then return false, why end
    local menu = inGameMenu()
    local page = menu ~= nil and menu.pageMapOverview or nil
    if page == nil or type(page.showMapHotspot) ~= "function" then
        log("showOnMap: no pageMapOverview:showMapHotspot")
        return false, "Not available"
    end
    if not FarmHandCommands.openMenuPage("pageMapOverview") then return false, "Not available" end
    local ok, err = pcall(page.showMapHotspot, page, h)
    if not ok then
        log("showOnMap: showMapHotspot threw: %s", tostring(err))
        return false, "Not available"
    end
    pendingFocus = { page = page, hotspot = h, frames = 3 }
    log("showOnMap: %s %s", kind, tostring(id))
    return true
end

-- ---------------------------------------------------------------- mapTarget

--- Set the map flag (and the GPS route the game draws to it) on a hotspot.
--- arg: station:<id>, husbandry:<name or id>, production:<name or id>,
--- field:<n>, and also vehicle:<id> and contract:<uniqueId>.
---
--- g_currentMission:setMapTargetHotspot exists (in-game 22 Oct); it is the call
--- the game's own map and the prices screen use. A tap SETS the target, it never
--- toggles it off: the widget's tap means "take me there".
local function mapTarget(_, _, arg)
    local kind, id = parseRef(arg)
    if kind == nil then return false, "Not found" end
    local h, why = resolveHotspot(kind, id)
    if h == nil then return false, why end
    local M = g_currentMission
    if M == nil or type(M.setMapTargetHotspot) ~= "function" then return false, "Not available" end
    local ok, err = pcall(M.setMapTargetHotspot, M, h)
    if not ok then
        log("mapTarget: setMapTargetHotspot threw: %s", tostring(err))
        return false, "Not available"
    end
    log("mapTarget: %s %s", kind, tostring(id))
    return true
end

-- ---------------------------------------------------------------- stopWorker

--- Dismiss the worker on one of the farm's machines. arg: the vehicle id the
--- workers frame sends (the same network id enterVehicle takes).
---
--- AISystem:stopJob(job, aiMessage) is the multiplayer-correct path (FS25
--- AISystem.lua): on the server it stops the job and broadcasts
--- AIJobStopEvent, on a client it sends AIJobStopEvent to the server. The
--- message is AIMessageSuccessStoppedByUser, the one the game's own hire key
--- sends (AIJobVehicle:toggleAIVehicle), so the stop reads as "dismissed",
--- never as a failure. vehicle:stopCurrentAIJob(msg) is the fallback; both
--- exist (in-game 22 Oct).
local function stopWorker(_, _, arg)
    local v = FarmHandEdge.findVehicle(arg, farmId())
    if v == nil then return false, "Not found" end
    -- an implement's id means the worker on the machine it is hitched to
    if not FarmHandCollectors.isWorkerVehicle(v) then
        local root = nil
        pcall(function() root = v:getRootVehicle() end)
        if root == nil then pcall(function() root = v.rootVehicle end) end
        if root ~= nil then v = root end
    end
    local active = false
    pcall(function() active = v:getIsAIActive() == true end)
    if not active then
        local ad = false
        pcall(function() ad = v.ad.stateModule:isActive() == true end)
        -- AutoDrive drives without a game AI job; it has its own stop
        if ad then return false, "Not available" end
        return false, "Not working"
    end
    local can = true
    pcall(function() if type(v.getCanStopAIVehicle) == "function" then can = v:getCanStopAIVehicle() ~= false end end)
    if not can then return false, "Not available" end
    local msg = nil
    pcall(function() msg = AIMessageSuccessStoppedByUser.new() end)
    if msg == nil then return false, "Not available" end

    local job = nil
    pcall(function() job = v:getJob() end)
    local ok = false
    if job ~= nil then
        ok = pcall(function() g_currentMission.aiSystem:stopJob(job, msg) end)
    end
    if not ok and type(v.stopCurrentAIJob) == "function" then
        ok = pcall(v.stopCurrentAIJob, v, msg)
    end
    if not ok then
        log("stopWorker: could not stop the job on %s", tostring(arg))
        return false, "Not available"
    end
    log("stopWorker: dismissed the worker on %s", tostring(arg))
    return true
end

-- ---------------------------------------------------------------- acceptContract

-- The game's answer comes back after the server has run the event, so it
-- cannot ride the command's ack, which therefore means "asked". There is no
-- separate answer frame: subscribing g_messageCenter to MissionStartEvent never
-- fired in game (22 Oct), and no other hook is proven. The missions frame is the
-- answer instead (in-game 22 Oct it showed the contract RUNNING and mine), and
-- it is asked for a second later rather than at its next 5 s tick.

--- Accept a contract on offer. arg: the mission uniqueId the missions frame
--- sends. value: 1 to lease the contract's machines, 0 to use your own.
---
--- Through MissionStartEvent, sent to the server connection, the way the
--- in-game contracts screen does it, so it works the same for the host and for
--- a client, and the server checks the player's rights again when it lands.
--- MissionStartEvent.new(mission, farmId, spawnVehicles) is the argument order
--- the game's MissionManager and FS25 contract mods use; MissionStartEvent is a
--- global with new (in-game 22 Oct).
local function acceptContract(_, value, arg)
    local m = FarmHandEdge.findMission(arg)
    if m == nil then return false, "Not found" end
    local fid = farmId()
    if fid == nil then return false, "Not available" end
    local owner = FarmHandEdge.missionFarm(m)
    if owner ~= nil and owner == fid then return false, "Already accepted" end
    local ready = false
    pcall(function() ready = m:getIsReadyToStart() == true end)
    if owner ~= nil or not ready then return false, "Not available" end
    if not FarmHandEdge.canManageContracts() then return false, "Host only" end
    local full = false
    pcall(function() full = g_missionManager:hasFarmReachedMissionLimit(fid) == true end)
    if full then return false, "Contract limit reached" end
    local lease = type(value) == "number" and value >= 0.5
    if lease then
        local hasSpace = true
        pcall(function() hasSpace = m:isSpawnSpaceAvailable() ~= false end)
        if not hasSpace then return false, "No space for the machines" end
    end
    if type(MissionStartEvent) ~= "table" or type(MissionStartEvent.new) ~= "function" then return false, "Not available" end

    local sent = false
    local ok, err = pcall(function()
        local event = MissionStartEvent.new(m, fid, lease)
        g_client:getServerConnection():sendEvent(event)
        sent = true
    end)
    if not ok or not sent then
        log("acceptContract: sending MissionStartEvent failed: %s", tostring(err))
        return false, "Not available"
    end
    -- the next missions frame shows the result: ask for it in a second rather
    -- than at its next 5 s tick
    if FarmHandEdge ~= nil and type(FarmHandEdge.soon) == "function" then FarmHandEdge.soon("missions", 1000) end
    log("acceptContract: asked to start %s (lease=%s)", tostring(m.uniqueId), tostring(lease))
    return true
end

-- ---------------------------------------------------------------- lifecycle

--- Per-frame: repeat a pending map focus once the page has laid itself out.
function FarmHandEdgeCommands.update(dt)
    local p = pendingFocus
    if p == nil then return end
    p.frames = p.frames - 1
    if p.frames > 0 then return end
    pendingFocus = nil
    pcall(function()
        if g_gui.currentGuiName == "InGameMenu" then p.page:showMapHotspot(p.hotspot) end
    end)
end

--- Mission end: drop a map focus still waiting for its frame.
function FarmHandEdgeCommands.reset()
    pendingFocus = nil
end

if FarmHandCommands ~= nil and type(FarmHandCommands.register) == "function" then
    FarmHandCommands.register("showOnMap", showOnMap)
    FarmHandCommands.register("mapTarget", mapTarget)
    FarmHandCommands.register("stopWorker", stopWorker)
    FarmHandCommands.register("acceptContract", acceptContract)
end
