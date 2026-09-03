-- FarmHand Telemetry :: main
--
-- Companion mod for "Farming Simulator 25 FarmHand" (FlowKits).
-- Streams game state to the FarmHand Stream Deck plugin.
--
-- TIERED CADENCE. Reading everything at 4 Hz would be wasteful: the fleet,
-- fields, animals and production barely change second to second, while the
-- vehicle you are driving changes constantly.
--
--   FAST  (4 Hz)   active vehicle + world (money, clock, weather)
--   SLOW  (0.5 Hz) fleet, current field, contracts
--   IDLE  (0.1 Hz) animal pens, production points, best prices
--   EVENT (push)   AI job started/stopped, with the real stop reason
--
-- Every accessor is verified: see fs25-telemetry-api-verified.md.

Farmhand = {}

--- Single source of truth for the version, announced to the plugin on connect.
--- MUST match modDesc.xml. In MULTIPLAYER a client runs the HOST's copy of the
--- mod, so the plugin's disk-based version check can be satisfied while the
--- RUNNING mod is a different build entirely — only the mod itself can say.
-- Kept in step with modDesc.xml by a test, not by memory. It sat at 1.98.0 while
-- modDesc climbed to 2.9.0.0, so the plugin's version-mismatch warning fired on
-- EVERY session - the exact "alarm that fires when nothing is wrong" its own
-- comment warns about, which trains you to ignore the one real case it exists to
-- catch (4 Aug).
Farmhand.VERSION = "2.19.6"

local FAST_MS = 250      -- active vehicle
local SLOW_MS = 2000     -- fleet, field, contracts
local IDLE_MS = 10000    -- husbandry, production, prices
-- A hired worker that has not moved OR changed fill for this long is stuck.
-- 90s is deliberately conservative: headland turns and brief waits are normal,
-- and a false 'stuck' would erode trust in the alert key.
local STUCK_MS = 90000

Farmhand.transport = nil
Farmhand.fastTimer = 0
Farmhand.slowTimer = 0
Farmhand.idleTimer = 0
Farmhand.farmId = nil
Farmhand.ready = false
Farmhand.aiWatch = {}   -- vehicleKey -> stuck-detection state
Farmhand.clockMs = 0    -- monotonic, accumulated from dt

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[FarmHand] " .. (ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------- AI events

--- VERIFIED: on AI_JOB_STOPPED, arg2 is an AIMessage class instance. It
--- iterates empty because its identity lives on the metatable. getI18NText()
--- gives a localised template, and the CLASS NAME prefix carries severity:
--- AIMessageError* vs AIMessageSuccess*.
--- Identify the stop reason.
---
--- VERIFIED 22 Jul, the hard way: `pairs(_G)` does NOT enumerate these classes
--- (same metatable-backed lookup trap as InputAction), so scanning _G finds
--- nothing and every stop resolves to nil — meaning NO alert fires at all.
--- Index the known names DIRECTLY instead.
---
--- The messages are Giants class instances exposing isa()/getType()/class(), so
--- isa() is the correct membership test: it understands subclasses, unlike the
--- metatable-identity comparison this used to rely on.
---
--- Order matters: specific reasons first, generic Error/Success bases LAST, so a
--- precise cause wins and the bases only supply severity as a fallback.
local AI_MESSAGE_CLASSES = {
    "AIMessageErrorOutOfFill", "AIMessageErrorIsFull", "AIMessageErrorOutOfFuel",
    "AIMessageErrorVehicleBroken", "AIMessageErrorBlockedByObject",
    "AIMessageErrorNoFieldFound", "AIMessageErrorCannotFindPath",
    "AIMessageErrorVehicleDeleted", "AIMessageErrorWrongBaleType",
    "AIMessageSuccessStoppedByUser", "AIMessageSuccessFinishedJob",
    "AIMessageSuccessWorkFinished", "AIMessageErrorUnknown",
    -- bases last: they classify severity when the exact cause is unlisted
    "AIMessageError", "AIMessageSuccess",
}

local function identifyAiMessage(msg)
    if type(msg) ~= "table" then return nil end
    local mt = getmetatable(msg)
    for _, name in ipairs(AI_MESSAGE_CLASSES) do
        local g = nil
        pcall(function() g = _G[name] end)
        if type(g) == "table" then
            local hit = false
            -- the engine's own class test first
            pcall(function()
                if type(msg.isa) == "function" and msg:isa(g) == true then hit = true end
            end)
            -- fall back to identity comparison for anything isa() cannot answer
            if not hit then
                pcall(function()
                    hit = (msg == g) or (mt == g) or (rawget(g, "__index") == mt)
                end)
            end
            if hit then return name end
        end
    end
    return nil
end

--- Severity, FAIL OPEN.
---
--- VERIFIED 22 Jul: FS has stop reasons outside any list we can enumerate — e.g.
--- "field not ready for this work or already worked!" resolved to no class at
--- all, not even a base (AIMessageError is not a global). Treating unknown as
--- "unknown" meant SILENCE on a genuine failure, which defeats the whole point
--- of the alert.
---
--- So: a stop is only benign when we POSITIVELY recognise a Success class (the
--- player dismissed it, or the job completed). Everything else stopped the job
--- for a reason the player did not choose, so it alerts. A spurious alert is
--- recoverable and the game's own text explains it; a missed one is not.
local function severityFor(kind, msg, className)
    if kind ~= "stopped" or msg == nil then return "unknown" end
    if className ~= nil and className:find("^AIMessageSuccess") then return "success" end
    return "error"
end

local function sendAiEvent(kind, job, msg)
    local t = Farmhand.transport
    if t == nil then return end
    local esc = FarmHandCollectors.esc
    local num = FarmHandCollectors.num

    local bits = { '"event":"ai"', string.format('"kind":"%s"', kind) }
    if type(job) == "table" then
        pcall(function()
            if job.helperIndex ~= nil then bits[#bits + 1] = string.format('"helperIndex":%d', num(job.helperIndex)) end
            if job.currentTaskIndex ~= nil then bits[#bits + 1] = string.format('"taskIndex":%d', num(job.currentTaskIndex)) end
            if type(job.tasks) == "table" then bits[#bits + 1] = string.format('"taskCount":%d', #job.tasks) end
            if type(job.vehicleParameter) == "table" and job.vehicleParameter.vehicleId ~= nil then
                local vid = job.vehicleParameter.vehicleId
                bits[#bits + 1] = string.format('"vehicleId":%d', num(vid))
                -- VERIFIED 22 Jul: vehicleParameter carries {isValid, type, vehicleId}.
                -- The id is a NETWORK object id, so resolve it to the machine and
                -- send its name: "Patriot 4430 - tank is empty" tells you which
                -- machine to walk to; "Worker 9 stopped" does not.
                pcall(function()
                    local veh = NetworkUtil.getObject(vid)
                    if veh ~= nil and type(veh.getFullName) == "function" then
                        local base = FarmHandCollectors.splitWorkerName(veh:getFullName())
                        if base ~= nil then
                            bits[#bits + 1] = string.format('"vehicleName":"%s"', esc(base))
                        end
                    end
                end)
            end
        end)
    end

    local className = identifyAiMessage(msg)
    if className ~= nil then
        bits[#bits + 1] = string.format('"messageClass":"%s"', esc(className))
    end
    local severity = severityFor(kind, msg, className)
    bits[#bits + 1] = string.format('"severity":"%s"', severity)

    pcall(function()
        if type(msg) == "table" and type(msg.getI18NText) == "function" then
            local text = msg:getI18NText()
            if text ~= nil then bits[#bits + 1] = string.format('"text":"%s"', esc(text)) end
        end
    end)

    -- Log as well as send. The stop REASON is the whole feature, and
    -- identifyAiMessage resolves it by metatable comparison — a technique built
    -- from a dump and never yet seen to execute. If it returns nil we degrade to
    -- severity "unknown" and lose the reason, so make that visible rather than
    -- silent.
    local vname = nil
    pcall(function()
        if type(job) == "table" and type(job.vehicleParameter) == "table" then
            local veh = NetworkUtil.getObject(job.vehicleParameter.vehicleId)
            if veh ~= nil and type(veh.getFullName) == "function" then vname = veh:getFullName() end
        end
    end)
    log("AI %s class=%s severity=%s vehicle=%s", kind, tostring(className),
        severity, tostring(vname))

    -- If a message arrived but matched nothing, we lose both the reason AND the
    -- severity (so no alert fires for what may be a real failure). Dump what it
    -- actually is, once, so the matcher can be taught about it.
    if className == nil and type(msg) == "table" then
        pcall(function()
            -- ask the object what it is, and show the text we WOULD display, so
            -- an unlisted reason is identifiable from one line
            local t, c, txt = nil, nil, nil
            pcall(function() if type(msg.getType) == "function" then t = tostring(msg:getType()) end end)
            pcall(function() if type(msg.class) == "function" then c = tostring(msg:class()) end end)
            pcall(function() if type(msg.getI18NText) == "function" then txt = tostring(msg:getI18NText()) end end)
            local cname, ckeys = nil, ""
            pcall(function()
                local cls = msg:class()
                if type(cls) == "table" then
                    cname = tostring(cls.name or cls.className)
                    local ks = {}
                    for k, v in pairs(cls) do ks[#ks + 1] = string.format("%s:%s", tostring(k), type(v)) end
                    table.sort(ks); ckeys = table.concat(ks, ", ")
                end
            end)
            log("AI UNMATCHED getType=%s className=%s classKeys=[%s] text=%s",
                tostring(t), tostring(cname), ckeys, tostring(txt))
        end)
    end

    t:send("{" .. table.concat(bits, ",") .. "}")
end

--- A stuck worker rides the same alert channel as a stop, because to the player
--- it is the same problem: a machine that needs attention.
local function sendStuckEvent(name, secs)
    local t = Farmhand.transport
    if t == nil then return end
    local esc = FarmHandCollectors.esc
    local mins = math.max(1, math.floor(secs / 60))
    local bits = {
        '"event":"ai"', '"kind":"stuck"', '"severity":"error"',
        string.format('"vehicleName":"%s"', esc(name)),
        string.format('"text":"%s has made no progress for %dm"', esc(name), mins),
    }
    log("AI stuck vehicle=%s for %ds", tostring(name), secs)
    t:send("{" .. table.concat(bits, ",") .. "}")
end

local function onAiJobStarted(self, job) sendAiEvent("started", job, nil) end
local function onAiJobStopped(self, job, msg) sendAiEvent("stopped", job, msg) end

-- ---------------------------------------------------------------- lifecycle

function Farmhand:loadMap(name)
    log("FarmHand Telemetry %s starting", Farmhand.VERSION)

    self.transport = FarmHandTransport.new(Farmhand.VERSION)
    self.transport:init()

    pcall(function() self.farmId = g_currentMission:getFarmId() end)

    pcall(function()
        if MessageType.AI_JOB_STARTED ~= nil then
            g_messageCenter:subscribe(MessageType.AI_JOB_STARTED, onAiJobStarted, self)
        end
        if MessageType.AI_JOB_STOPPED ~= nil then
            g_messageCenter:subscribe(MessageType.AI_JOB_STOPPED, onAiJobStopped, self)
        end
    end)

    self.ready = true
end

function Farmhand:update(dt)
    if not self.ready or self.transport == nil then return end
    self.transport:update(dt)
    self.clockMs = self.clockMs + dt

    -- poll for a command from the plugin and execute it directly (no keystrokes).
    -- checked every frame; the file only exists briefly when a command is pending.
    local cmd = self.transport:pollCommand()
    if cmd ~= nil then
        pcall(FarmHandCommands.execute, cmd)
    end

    -- Analog axis holds (loader/crane dials) are time-based: the engine
    -- integrates the axis value per frame, so a pulse has to be fed every frame
    -- until it expires. Runs before the farmId guard so a boom in motion still
    -- stops cleanly during the frames where farm state is not ready yet.
    pcall(FarmHandCommands.updatePulses, dt)


    -- farmId can be nil for a frame or two during load
    if self.farmId == nil then
        pcall(function() self.farmId = g_currentMission:getFarmId() end)
        if self.farmId == nil then return end
    end

    local C = FarmHandCollectors

    -- FAST: active vehicle + world
    self.fastTimer = self.fastTimer + dt
    if self.fastTimer >= FAST_MS then
        self.fastTimer = 0
        local ok, payload = pcall(function()
            local bits = { '"event":"state"' }
            local world = C.world(self.farmId)
            if world ~= nil then bits[#bits + 1] = '"world":' .. world end
            local veh = C.activeVehicle()
            if veh ~= nil then
                bits[#bits + 1] = '"ctx":"vehicle"'
                bits[#bits + 1] = '"vehicle":' .. veh
            else
                bits[#bits + 1] = '"ctx":"onFoot"'
            end
            return "{" .. table.concat(bits, ",") .. "}"
        end)
        -- DIAGNOSTIC: a throw here silently drops the whole frame, which reads on
        -- the plugin side as stale telemetry (vehicle never updates) and, if it
        -- keeps failing, a stale-timeout disconnect. Log it once per distinct
        -- error so a specific vehicle (e.g. the Katana) that breaks a collector
        -- is named rather than guessed at.
        if not ok then self:reportTierFail("FAST", payload) end
        if ok and payload ~= nil then self.transport:send(payload) end
    end

    -- SLOW: fleet, current field, contracts
    self.slowTimer = self.slowTimer + dt
    if self.slowTimer >= SLOW_MS then
        self.slowTimer = 0
        local ok, payload = pcall(function()
            local bits = { '"event":"farm"' }
            -- stuck check rides the same 2s cadence as the fleet read
            for _, st in ipairs(C.checkStuck(self.farmId, self.aiWatch, self.clockMs, STUCK_MS)) do
                sendStuckEvent(st.name, st.secs)
            end
            -- Cap at 99: the plugin filters the fleet to machines-plus-warnings,
            -- so it must SEE every item to filter accurately, and a truncated
            -- list could hide a machine. 99 covers any real farm; it exists only
            -- to bound a pathological save. ~20KB every 2s over a local pipe.
            bits[#bits + 1] = '"fleet":' .. C.fleet(self.farmId, 99)
            bits[#bits + 1] = '"contracts":' .. C.contracts(self.farmId, 6)
            local v = nil
            pcall(function() v = g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil end)
            local field = C.currentField(v)
            if field ~= nil then bits[#bits + 1] = '"field":' .. field end
            return "{" .. table.concat(bits, ",") .. "}"
        end)
        if not ok then self:reportTierFail("SLOW", payload) end
        if ok and payload ~= nil then self.transport:send(payload) end
    end

    -- IDLE: husbandry, production, prices
    self.idleTimer = self.idleTimer + dt
    if self.idleTimer >= IDLE_MS then
        self.idleTimer = 0
        local ok, payload = pcall(function()
            local bits = { '"event":"estate"' }
            -- seasonal calendar: static rules, so IDLE tier is plenty (a period
            -- lasts at least a full in-game day)
            local season = C.season()
            if season ~= nil then bits[#bits + 1] = '"season":' .. season end
            bits[#bits + 1] = '"husbandries":' .. C.husbandries(self.farmId, 8)
            bits[#bits + 1] = '"productions":' .. C.productions(self.farmId, 8)
            bits[#bits + 1] = '"prices":' .. C.bestPrices(nil, 12)
            return "{" .. table.concat(bits, ",") .. "}"
        end)
        if not ok then self:reportTierFail("IDLE", payload) end
        if ok and payload ~= nil then self.transport:send(payload) end
    end
end

--- Log a tier collector failure ONCE per distinct error, so a repeatedly-failing
--- collector names the cause rather than flooding the log.
Farmhand.reportedFails = {}
function Farmhand:reportTierFail(tier, err)
    local key = tier .. ":" .. tostring(err)
    if self.reportedFails[key] then return end
    self.reportedFails[key] = true
    log("TIER %s dropped a frame: %s", tier, tostring(err))
end

function Farmhand:deleteMap()
    if self.transport ~= nil then
        log("stopping after %d frames", self.transport.framesSent)
        self.transport:closePipe()
        self.transport = nil
    end
    -- MUST unsubscribe: g_messageCenter outlives the mission, so returning to
    -- the menu and reloading a save would subscribe a SECOND time and fire every
    -- AI event twice (three times after two reloads). Invisible in a normal
    -- play session, but the moment you use menu-reload as a dev loop it produces
    -- duplicate alerts and phantom "double stop" readings.
    pcall(function() g_messageCenter:unsubscribeAll(self) end)
    self.ready = false
end

addModEventListener(Farmhand)
