-- FarmHand Telemetry :: Transport
--
-- Gets data OUT of the FS25 Lua sandbox, which has no sockets.
--
--   PRIMARY   Windows named pipe, io.open(path, "w"). The Stream Deck plugin
--             hosts the server; we are the client. Verified 20 Jul 2026:
--             sustained 4 Hz for 9,500+ frames with no measurable perf cost.
--   FALLBACK  JSON file rewritten in modSettings. Used when the pipe is
--             unavailable (plugin not running, or a future non-Windows path).
--
-- Also polls a commands file so the plugin can send stateful commands back in.

FarmHandTransport = {}
local Transport_mt = Class(FarmHandTransport)

local PIPE_PATH     = "\\\\.\\pipe\\flowkits_fs25"
local MOD_SETTINGS  = "modSettings/FS25_Farmhand/"
local STATE_FILE    = "telemetry.json"
-- XML, not JSON: the sandbox can only READ via the engine XML API.
local COMMAND_FILE  = "commands.xml"
-- Plugin restart marker; see checkSession().
local SESSION_FILE  = "session.xml"

-- Reopening a dead pipe every frame would be wasteful; back off instead.
local PIPE_RETRY_MS = 5000
-- Cheap: one small XML read every 2s, same cadence as the fleet tier.
local SESSION_CHECK_MS = 2000

function FarmHandTransport.new(modVersion)
    local self = setmetatable({}, Transport_mt)
    self.modVersion = modVersion or "?"
    self.pipe = nil
    self.pipeHealthy = false
    self.retryTimer = 0
    self.baseDir = nil
    self.statePath = nil
    self.commandPath = nil
    self.sessionPath = nil
    self.sessionId = nil
    self.sessionTimer = 0
    self.lastCommandId = 0
    self.commandTimer = 0
    self.framesSent = 0
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
        self.commandPath = self.baseDir .. COMMAND_FILE
        self.sessionPath = self.baseDir .. SESSION_FILE
        -- Clear any stale command left from a previous session. Without this, an
        -- unconsumed command with a high id latches lastCommandId and makes every
        -- new command (with a fresh, possibly lower id) get discarded as "older".
        pcall(function()
            if fileExists ~= nil and fileExists(self.commandPath) then
                if deleteFile ~= nil then deleteFile(self.commandPath) end
            end
        end)
        self.lastCommandId = 0
    else
        self:log("WARN could not resolve user profile path; file fallback disabled")
    end
    self:openPipe()
end

function FarmHandTransport:openPipe()
    local ok, handle = pcall(io.open, PIPE_PATH, "w")
    if not ok or handle == nil then
        self.pipe = nil
        self.pipeHealthy = false
        return false
    end
    self.pipe = handle
    self.pipeHealthy = true
    self:log("connected to Stream Deck plugin")
    -- Identify ourselves immediately. This is the only reliable version signal
    -- in multiplayer, where the running mod came from the host rather than from
    -- whatever this plugin installed locally.
    self:send(string.format('{"event":"hello","modVersion":"%s"}', self.modVersion))
    return true
end

function FarmHandTransport:closePipe()
    if self.pipe ~= nil then
        pcall(function() self.pipe:close() end)
    end
    self.pipe = nil
    self.pipeHealthy = false
end

--- Send one newline-delimited JSON frame. Silently degrades to file-only.
function FarmHandTransport:send(line)
    if self.pipe ~= nil then
        local ok = pcall(function()
            self.pipe:write(line .. "\n")
            self.pipe:flush()
        end)
        if ok then
            self.framesSent = self.framesSent + 1
        else
            -- The plugin quitting mid-write is normal, not an error.
            self:closePipe()
        end
    end

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

--- Retry the pipe on a back-off. The plugin may start after the game.
---
--- Also watches the plugin's SESSION id. VERIFIED 22 Jul: when the plugin
--- restarts it rebuilds the named pipe, but we keep writing into the old handle
--- and never notice — a write to a dead pipe does not reliably fail on Windows,
--- so telemetry goes silently dead until the player reloads the save. Stream
--- Deck restarts plugins by itself (updates, crashes), so this would strand real
--- users with no symptom other than "it stopped working". A changed id means a
--- new plugin instance: drop the stale handle and reconnect.
function FarmHandTransport:update(dt)
    self.sessionTimer = (self.sessionTimer or 0) + dt
    if self.sessionTimer >= SESSION_CHECK_MS then
        self.sessionTimer = 0
        self:checkSession()
    end

    if self.pipe == nil then
        self.retryTimer = self.retryTimer + dt
        if self.retryTimer >= PIPE_RETRY_MS then
            self.retryTimer = 0
            self:openPipe()
        end
    end
end

--- Re-read the plugin's session id; a change means it restarted.
function FarmHandTransport:checkSession()
    if self.sessionPath == nil then return end
    local id = nil
    pcall(function()
        local xmlFile = XMLFile.loadIfExists("fhSession", self.sessionPath)
        if xmlFile == nil then return end
        id = xmlFile:getString("session#id")
        xmlFile:delete()
    end)
    if id == nil then return end
    if self.sessionId == nil then
        self.sessionId = id
    elseif id ~= self.sessionId then
        self:log("plugin restarted (session %s -> %s); reconnecting", tostring(self.sessionId), tostring(id))
        self.sessionId = id
        self:closePipe()
        self.retryTimer = PIPE_RETRY_MS   -- reconnect on the next update, not in 5s
    end
end

--- Read a command written by the plugin. Returns cmd table or nil.
--- Dedups on a monotonic id so re-reading the same file is harmless.
function FarmHandTransport:pollCommand()
    if self.commandPath == nil then return nil end

    local xmlFile = nil
    local ok = pcall(function()
        -- The sandbox only reads via the engine XML API, never io.open("r").
        -- The plugin writes JSON, so we read it as a raw string parameter.
        xmlFile = XMLFile.loadIfExists("fhCmd", self.commandPath)
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
            self:log("WARN command file had unreadable id (raw='%s' name='%s')", tostring(idStr), tostring(name))
        elseif id > self.lastCommandId then
            self.lastCommandId = id
            cmd = {
                id = id,
                name = name,
                value = xmlFile:getFloat("commands#value") or 0,
                -- optional string argument (e.g. which axis a dial drives)
                arg = xmlFile:getString("commands#arg"),
            }
        end
    end)
    pcall(function() xmlFile:delete() end)   -- release the in-memory XML handle first
    -- Then delete the file from DISK. xmlFile:delete() only frees the parsed
    -- object; the file itself lingers. Left in place, we re-parse it every frame
    -- AND hold it open every frame, which collides with the plugin's atomic
    -- rename -> libuv retries the rename for up to ~1s (the "delay"). Removing it
    -- means the file is absent between commands, so the next rename lands at once.
    if deleteFile ~= nil then pcall(deleteFile, self.commandPath) end
    return cmd
end
