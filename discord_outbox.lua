--[[--
Persistent queue of messages that could not be sent (no network, server
errors). They are kept on disk and sent again when the connection returns.
]]

local DataStorage = require("datastorage")
local DiscordAPI = require("discord_api")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")

local Outbox = {
    entries = nil, -- loaded lazily: { { id, channel_id, content, reply, nonce, time, error } }
}

local function path()
    return require("discord_account").cacheDir() .. "/outbox.json"
end

local function load()
    if Outbox.entries then return Outbox.entries end
    Outbox.entries = {}
    local f = io.open(path(), "r")
    if f then
        local ok, data = pcall(rapidjson.decode, f:read("*a"))
        f:close()
        if ok and type(data) == "table" then
            Outbox.entries = DiscordAPI.stripNulls(data)
        end
    end
    return Outbox.entries
end

local function save()
    local entries = load()
    if #entries == 0 then
        os.remove(path())
        return
    end
    local f = io.open(path() .. ".tmp", "w")
    if not f then return end
    f:write(rapidjson.encode(entries))
    f:close()
    os.rename(path() .. ".tmp", path())
end

--- Queues a message. reply: { id, guild_id, no_ping } or nil. due: Unix time before which it
-- must not be sent (scheduled messages). Returns the entry.
function Outbox.add(channel_id, content, reply, due)
    local entries = load()
    local entry = {
        id = string.format("%d-%d", os.time(), #entries + math.random(1000)),
        channel_id = channel_id,
        content = content,
        reply = reply and { id = reply.id, guild_id = reply.guild_id, no_ping = reply.no_ping } or nil,
        nonce = DiscordAPI.makeNonce(),
        time = os.time(),
        due = due,
    }
    table.insert(entries, entry)
    save()
    return entry
end

--- Pending entries, optionally only those of one channel.
function Outbox.list(channel_id)
    local out = {}
    for __, e in ipairs(load()) do
        if not channel_id or e.channel_id == channel_id then table.insert(out, e) end
    end
    return out
end

--- True if the entry is scheduled for later.
function Outbox.isScheduled(e)
    return e.due ~= nil and e.due > os.time()
end

--- Earliest scheduled time among the entries still waiting, or nil.
function Outbox.nextDue()
    local best
    for __, e in ipairs(load()) do
        if e.due and not e.error and (not best or e.due < best) then best = e.due end
    end
    return best
end

--- Forgets the loaded queue (after switching accounts).
function Outbox.reset()
    Outbox.entries = nil
end

function Outbox.count()
    return #load()
end

function Outbox.remove(id)
    local entries = load()
    for i, e in ipairs(entries) do
        if e.id == id then
            table.remove(entries, i)
            save()
            return true
        end
    end
    return false
end

--- Retries a failed entry the next time.
function Outbox.retry(id)
    for __, e in ipairs(load()) do
        if e.id == id then e.error = nil end
    end
    save()
end

--- True if an error is worth retrying later (no network, rate limit, server).
local function transient(code)
    return code == nil or code == 429 or code >= 500
end

Outbox.flushing = false

--- Sends the queued messages in order. Stops at the first network failure.
-- Returns the list of messages that were sent.
function Outbox.flush(api)
    if Outbox.flushing then return {} end
    local entries = load()
    if #entries == 0 then return {} end
    Outbox.flushing = true
    local sent = {}
    local changed = false
    local i = 1
    while i <= #entries do
        local e = entries[i]
        if e.error or Outbox.isScheduled(e) then
            i = i + 1 -- failed for good (waits for the user) or not due yet
        else
            local reply = e.reply and { id = e.reply.id, guild_id = e.reply.guild_id, no_ping = e.reply.no_ping } or nil
            local ok, data, code = api:sendMessage(e.channel_id, e.content, reply, e.nonce)
            if ok then
                table.remove(entries, i)
                changed = true
                table.insert(sent, data)
            elseif transient(code) then
                logger.info("Discord: outbox paused", tostring(data))
                break
            else
                e.error = tostring(data)
                changed = true
                i = i + 1
            end
        end
    end
    Outbox.flushing = false
    if changed then save() end
    return sent
end

return Outbox
