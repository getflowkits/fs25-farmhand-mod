-- FarmHand Telemetry :: Transport
--
-- Gets data OUT of the FS25 Lua sandbox, which has no sockets.
--
--   PRIMARY   Windows named pipe, io.open(path, "w"). The listener hosts the
--             server; we are the client. Verified 20 Jul 2026: sustained 4 Hz
--             for 9,500+ frames with no measurable perf cost.
--   FALLBACK  JSON file rewritten in modSettings, for the Stream Deck plugin
--             only. Used when its pipe is unavailable.
--
-- Also polls a commands file per listener so each can send commands back in.
--
-- TWO LISTENERS, NOTHING SHARED (2.20). The Stream Deck plugin and the FlowKits
-- Companion (Xeneon Edge widget) often run at the same time, so each owns its
-- own pipe, command file and session file:
--
--   plugin  \\.\pipe\flowkits_fs25       commands.xml       session.xml       + telemetry.json
--   edge    \\.\pipe\flowkits_fs25_edge  commands_edge.xml  session_edge.xml
--
-- A shared command file would let one listener overwrite the other's press; a
-- shared session file would make each restart knock the other off. The plugin's
-- channel is byte-for-byte what it was before 2.20, so an older plugin works
-- unchanged against this mod.

FarmHandTransport = {}
local Transport_mt = Class(FarmHandTransport)

local MOD_SETTINGS  = "modSettings/FS25_Farmhand/"
local STATE_FILE    = "telemetry.json"

-- XML, not JSON: the sandbox can only READ via the engine XML API.
--
-- How often each listener's command file is checked. The plugin's every game
-- frame, exactly as before 2.20, so a key press never waits. The widget's at
-- most every 100 ms of game-frame time, only while its pipe is connected, and
-- with the cheap existence check first: a player without the widget pays
-- nothing, and one with it pays 10 checks a second, not one per frame (at
-- 144 fps both files every frame was about 288 file checks a second).
local LISTENERS = {
    { name = "plugin", pipe = "\\\\.\\pipe\\flowkits_fs25",      commands = "commands.xml",      session = "session.xml",      fileFallback = true,
      label = "Stream Deck plugin", pollEveryMs = 0, pollNeedsPipe = false },
    { name = "edge",   pipe = "\\\\.\\pipe\\flowkits_fs25_edge", commands = "commands_edge.xml", session = "session_edge.xml", fileFallback = false,
      label = "FlowKits Companion", pollEveryMs = 100, pollNeedsPipe = true },
}
-- The widget's poll rate goes to the log once a minute's worth has been
-- counted, and again at most every 10 minutes, so 10 Hz can be confirmed in game.
local POLL_REPORT_WINDOW_MS = 60000
local POLL_REPORT_EVERY_MS = 600000

-- Reopening a dead pipe every frame would be wasteful; back off instead.
local PIPE_RETRY_MS = 5000
-- Cheap: one small XML read per listener every 2s, same cadence as the fleet tier.
local SESSION_CHECK_MS = 2000
-- The widget pipe's protocol level, sent in its hello (see PROTOCOL.md).
local EDGE_PROTOCOL = "2.20"

function FarmHandTransport.new(modVersion)
    local self = setmetatable({}, Transport_mt)
    self.modVersion = modVersion or "?"
    self.baseDir = nil
    self.statePath = nil
    self.sessionTimer = 0
    self.framesSent = 0
    self.order = {}
    self.byName = {}
    for _, d in ipairs(LISTENERS) do
        local l = { name = d.name, label = d.label, pipePath = d.pipe, commandFile = d.commands, sessionFile = d.session,
                    fileFallback = d.fileFallback, pipe = nil, retryTimer = 0, sessionId = nil, lastCommandId = 0,
                    commandPath = nil, sessionPath = nil,
                    pollEveryMs = d.pollEveryMs, pollNeedsPipe = d.pollNeedsPipe, pollTimer = 0,
                    everConnected = false, polls = 0, pollWindowMs = 0, pollReportedAt = nil }
        self.order[#self.order + 1] = l
        self.byName[d.name] = l
    end
    -- kept for callers and logs that predate 2.20 (the plugin's listener)
    self.pipe = nil
    self.pipeHealthy = false
    return self
end

function FarmHandTransport:log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[FarmHand] " .. (ok and msg or tostring(fmt)))
end

function FarmHandTransport:init()
    local ok, base = pcall(getUserProfileAppPath)
    if ok and base ~= nil then
        self.baseDir = base .. MOD_SETTINGS
        pcall(createFolder, base .. "modSettings/")
        pcall(createFolder, self.baseDir)
        self.statePath = self.baseDir .. STATE_FILE
        for _, l in ipairs(self.order) do
            l.commandPath = self.baseDir .. l.commandFile
            l.sessionPath = self.baseDir .. l.sessionFile
            -- Clear any stale command left from a previous session. Without this, an
            -- unconsumed command with a high id latches lastCommandId and makes every
            -- new command (with a fresh, possibly lower id) get discarded as "older".
            pcall(function()
                if fileExists ~= nil and fileExists(l.commandPath) then
                    if deleteFile ~= nil then deleteFile(l.commandPath) end
                end
            end)
            l.lastCommandId = 0
        end
    else
        self:log("WARN could not resolve user profile path; file fallback disabled")
    end
    for _, l in ipairs(self.order) do self:openPipe(l) end
end

function FarmHandTransport:syncLegacy()
    local p = self.byName.plugin
    self.pipe = p.pipe
    self.pipeHealthy = p.pipe ~= nil
end

function FarmHandTransport:openPipe(l)
    local ok, handle = pcall(io.open, l.pipePath, "w")
    if not ok or handle == nil then
        l.pipe = nil
        self:syncLegacy()
        return false
    end
    l.pipe = handle
    l.everConnected = true
    self:syncLegacy()
    self:log("connected to %s", l.label)
    -- Identify ourselves immediately. This is the only reliable version signal
    -- in multiplayer, where the running mod came from the host rather than from
    -- whatever was installed locally.
    if l.name == "edge" then
        self:writeTo(l, string.format('{"event":"hello","modVersion":"%s","protocol":"%s"}', self.modVersion, EDGE_PROTOCOL))
    else
        self:writeTo(l, string.format('{"event":"hello","modVersion":"%s"}', self.modVersion))
    end
    return true
end

function FarmHandTransport:closePipe(l)
    if l == nil then   -- no listener named: close them all (mission end)
        for _, x in ipairs(self.order) do self:closePipe(x) end
        return
    end
    if l.pipe ~= nil then
        pcall(function() l.pipe:close() end)
    end
    l.pipe = nil
    self:syncLegacy()
end

function FarmHandTransport:writeTo(l, line)
    if l.pipe == nil then return false end
    local ok = pcall(function()
        l.pipe:write(line .. "\n")
        l.pipe:flush()
    end)
    if ok then
        self.framesSent = self.framesSent + 1
    else
        -- The listener quitting mid-write is normal, not an error.
        self:closePipe(l)
    end
    return ok
end

--- Is this listener's pipe open right now? Expensive farm-wide collectors run
--- only while the widget is listening, so a plugin-only player pays nothing.
function FarmHandTransport:connected(name)
    local l = self.byName[name]
    return l ~= nil and l.pipe ~= nil
end

--- Send one newline-delimited JSON frame to every listener. Silently degrades
--- to file-only for the plugin. The frame is built once and written to each.
function FarmHandTransport:send(line)
    for _, l in ipairs(self.order) do self:writeTo(l, line) end

    -- Rewritten with every frame sent, even while the plugin's pipe is up, on
    -- purpose: PROTOCOL.md tells any second program running beside the plugin
    -- to read this file (the pipe name is the plugin's alone), so skipping the
    -- write while the pipe is up would break that documented path.
    if self.statePath ~= nil then
        pcall(function()
            local f = io.open(self.statePath, "w")
            if f ~= nil then
                f:write(line)
                f:close()
            end
        end)
    end
end

--- Send a frame to one listener only (widget-only frames, acks).
function FarmHandTransport:sendTo(name, line)
    local l = self.byName[name]
    if l ~= nil then self:writeTo(l, line) end
end

--- Answer a widget command by its request id, so the widget can show done,
--- refused (with the reason) or no answer. The plugin's commands are not acked:
--- its protocol never had acks and must not change.
function FarmHandTransport:ack(cmd, ok, reason)
    if cmd == nil or cmd.source ~= "edge" or cmd.req == nil then return end
    local function q(s) return (tostring(s):gsub('[%c"\\]', "")) end
    local line = string.format('{"event":"ack","req":"%s","ok":%s%s}', q(cmd.req), ok and "true" or "false",
        (not ok and reason ~= nil) and (',"reason":"' .. q(reason) .. '"') or "")
    self:sendTo("edge", line)
end

--- Retry each pipe on a back-off; a listener may start after the game.
---
--- Also watches each listener's SESSION id. VERIFIED 22 Jul: when a listener
--- restarts it rebuilds its named pipe, but we keep writing into the old handle
--- and never notice - a write to a dead pipe does not reliably fail on Windows,
--- so telemetry goes silently dead until the player reloads the save. A changed
--- id means a new instance: drop that listener's stale handle and reconnect it.
--- The other listener is never touched.
function FarmHandTransport:update(dt)
    self.clockMs = (self.clockMs or 0) + dt
    for _, l in ipairs(self.order) do
        if l.pollEveryMs > 0 then l.pollTimer = l.pollTimer + dt end
        if l.pollNeedsPipe and l.pipe ~= nil then self:countPollWindow(l, dt) end
    end
    self.sessionTimer = (self.sessionTimer or 0) + dt
    if self.sessionTimer >= SESSION_CHECK_MS then
        self.sessionTimer = 0
        for _, l in ipairs(self.order) do self:checkSession(l) end
    end

    for _, l in ipairs(self.order) do
        if l.pipe == nil then
            l.retryTimer = l.retryTimer + dt
            if l.retryTimer >= PIPE_RETRY_MS then
                l.retryTimer = 0
                self:openPipe(l)
            end
        end
    end
end

--- Log a gated listener's poll count once a minute's worth is in, then at
--- most every 10 minutes ("EDGE poll: 600 checks in the last minute").
function FarmHandTransport:countPollWindow(l, dt)
    l.pollWindowMs = l.pollWindowMs + dt
    if l.pollWindowMs < POLL_REPORT_WINDOW_MS then return end
    local due = l.pollReportedAt == nil or (self.clockMs - l.pollReportedAt) >= POLL_REPORT_EVERY_MS
    if due then
        l.pollReportedAt = self.clockMs
        self:log("%s poll: %d checks in the last minute", l.name == "edge" and "EDGE" or l.name, l.polls)
    end
    l.polls = 0
    l.pollWindowMs = 0
end

--- Re-read one listener's session id; a change means it restarted.
--- A gated listener (the widget's) is skipped until its pipe has connected once
--- this session: until then there is nothing to reconnect.
function FarmHandTransport:checkSession(l)
    if l.sessionPath == nil then return end
    if l.pollNeedsPipe and not l.everConnected then return end
    local id = nil
    pcall(function()
        local xmlFile = XMLFile.loadIfExists("fhSession", l.sessionPath)
        if xmlFile == nil then return end
        id = xmlFile:getString("session#id")
        xmlFile:delete()
    end)
    if id == nil then return end
    if l.sessionId == nil then
        l.sessionId = id
    elseif id ~= l.sessionId then
        self:log("%s restarted (session %s -> %s); reconnecting", l.label, tostring(l.sessionId), tostring(id))
        l.sessionId = id
        self:closePipe(l)
        l.retryTimer = PIPE_RETRY_MS   -- reconnect on the next update, not in 5s
    end
end

--- Read one listener's pending command. Returns a cmd table or nil.
--- Dedups on the id so re-reading the same file is harmless. DIFFERENT, not
--- greater: the file is deleted once consumed, so the only repeat is the same
--- file read twice. A listener that restarts mid-session may number from below
--- what we last took (the shipped plugin seeds from the clock, and a burst of
--- dial ticks runs its counter ahead of it); "greater" silently dropped every
--- press after such a restart until the clock caught up.
function FarmHandTransport:pollOne(l)
    if l.commandPath == nil then return nil end
    -- Existence first, for both listeners: XMLFile.loadIfExists makes that same
    -- check before it parses, so on the usual "no command waiting" check this
    -- is the one engine call without the XML API around it. The plugin's file
    -- is still checked every frame, so a key press lands no later than before.
    if l.pollNeedsPipe then l.polls = l.polls + 1 end
    if fileExists ~= nil then
        local okE, there = pcall(fileExists, l.commandPath)
        if okE and not there then return nil end
    end

    local xmlFile = nil
    local ok = pcall(function()
        -- The sandbox only reads via the engine XML API, never io.open("r").
        xmlFile = XMLFile.loadIfExists("fhCmd", l.commandPath)
    end)
    if not ok or xmlFile == nil then return nil end

    local cmd = nil
    pcall(function()
        -- read id as a STRING then tonumber it, so a large id can never overflow
        -- getInt's 32-bit range and silently drop the command.
        local idStr = xmlFile:getString("commands#id")
        local id = tonumber(idStr)
        local name = xmlFile:getString("commands#cmd")
        if id == nil then
            self:log("WARN %s command file had unreadable id (raw='%s' name='%s')", l.name, tostring(idStr), tostring(name))
        elseif id ~= l.lastCommandId then
            l.lastCommandId = id
            cmd = {
                id = id,
                name = name,
                value = xmlFile:getFloat("commands#value") or 0,
                -- optional string argument (e.g. which axis a dial drives)
                arg = xmlFile:getString("commands#arg"),
                source = l.name,
                -- the widget's request id, echoed in the ack (widget listener only)
                req = l.name == "edge" and xmlFile:getString("commands#req") or nil,
            }
        end
    end)
    pcall(function() xmlFile:delete() end)   -- release the in-memory XML handle first
    -- Then delete the file from DISK. xmlFile:delete() only frees the parsed
    -- object; the file itself lingers. Left in place, we re-parse it every frame
    -- AND hold it open every frame, which collides with the writer's atomic
    -- rename -> libuv retries the rename for up to ~1s (the "delay"). Removing it
    -- means the file is absent between commands, so the next rename lands at once.
    if deleteFile ~= nil then pcall(deleteFile, l.commandPath) end
    return cmd
end

--- Pending commands from every listener this frame, plugin first. Each listener
--- has its own file, so a press from one can never displace a press from the other.
function FarmHandTransport:pollCommands()
    local out = {}
    for _, l in ipairs(self.order) do
        local due = true
        if l.pollNeedsPipe and l.pipe == nil then
            due = false
        elseif l.pollEveryMs > 0 then
            due = l.pollTimer >= l.pollEveryMs
            -- carry the remainder so the rate holds at 10 Hz whatever the frame
            -- rate, but never let a long gap (a load, a hitch) bank extra checks
            if due then
                l.pollTimer = l.pollTimer - l.pollEveryMs
                if l.pollTimer >= l.pollEveryMs then l.pollTimer = 0 end
            end
        end
        if due then
            local c = self:pollOne(l)
            if c ~= nil then out[#out + 1] = c end
        end
    end
    return out
end

--- Kept for anything that still calls the pre-2.20 single-listener API.
function FarmHandTransport:pollCommand()
    return self:pollOne(self.byName.plugin)
end
