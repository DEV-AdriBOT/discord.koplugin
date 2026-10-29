--[[--
Discord gateway connection and client state.

A module-level singleton: it survives switches between the file manager and
the reader, so the connection is not reopened every time a book is opened.
It is driven by UIManager timers, never by a blocking loop.

@module koplugin.discord.gateway
]]

local DataStorage = require("datastorage")
local DiscordAPI = require("discord_api")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WebSocket = require("discord_websocket")
local logger = require("logger")
local rapidjson = require("rapidjson")
local socket = require("socket")

local NULL = rapidjson.null
local idLess = DiscordAPI.idLess
local stripNulls = DiscordAPI.stripNulls

local GATEWAY_URL = "wss://gateway.discord.gg/?v=9&encoding=json"
-- DEDUPE_USER_OBJECTS: gives merged_members (our roles in every guild)
local CAPABILITIES = 16

local function v(x)
    if x == NULL then return nil end
    return x
end

local Gateway = {
    api = nil,
    ws = nil,
    state = "disconnected", -- disconnected, connecting, ready
    seq = nil,
    session_id = nil,
    resume_url = nil,
    listeners = {},
    want_connected = false,
    foreground = 0, -- number of open views needing fast updates
    retries = 0,

    -- state
    me = nil,
    guilds = {},        -- id -> guild { id, name, owner_id, roles, channels (list), threads (list), my_roles }
    guild_order = {},   -- list of guild ids
    channels = {},      -- id -> channel (guild channels, threads and private channels)
    private_channels = {}, -- list of DM channel ids
    read_states = {},   -- channel id -> { last_message_id, mention_count }
    muted_guilds = {},
    muted_channels = {},
    suppress_everyone = {}, -- guild id -> true
    users = {},         -- id -> user
    relationships = {}, -- user id -> { type = 1 friend / 3 incoming / 4 outgoing, user }
    status = nil,       -- presence to announce ("online", "idle", "dnd", "invisible"), nil = unchanged
    nicks = {},         -- guild id -> { user id -> nick }
    pending_members = {}, -- guild id -> { user id -> true }
}

-- Listeners

function Gateway:on(name, fn)
    self.listeners[name] = self.listeners[name] or {}
    table.insert(self.listeners[name], fn)
    return fn
end

function Gateway:off(name, fn)
    local list = self.listeners[name]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
end

function Gateway:emit(name, ...)
    local list = self.listeners[name]
    if not list then return end
    for _, fn in ipairs({ unpack(list) }) do
        local ok, err = pcall(fn, ...)
        if not ok then logger.warn("Discord: listener error", name, err) end
    end
end

function Gateway:isReady()
    return self.state == "ready"
end

--- True when lists can use our state: live, or loaded from the disk cache.
function Gateway:hasState()
    return self.state == "ready" or self.cached == true
end

-- Disk cache: lets lists open at once and the session be resumed after a restart

local function stateFile()
    return DataStorage:getDataDir() .. "/cache/discord/gateway.json"
end

function Gateway:saveState()
    if not self.me or not (self.state == "ready" or self.cached) then return end
    local private = {}
    for _, id in ipairs(self.private_channels) do
        if self.channels[id] then table.insert(private, self.channels[id]) end
    end
    local guilds = {}
    for _, id in ipairs(self.guild_order) do
        if self.guilds[id] then table.insert(guilds, self.guilds[id]) end
    end
    local ok, json = pcall(rapidjson.encode, {
        version = 1,
        saved_at = os.time(),
        me = { id = self.me.id, username = v(self.me.username), global_name = v(self.me.global_name) },
        session_id = self.session_id,
        seq = self.seq,
        resume_url = self.resume_url,
        guilds = guilds,
        private = private,
        read_states = self.read_states,
        muted_guilds = self.muted_guilds,
        muted_channels = self.muted_channels,
        suppress_everyone = self.suppress_everyone,
        users = self.users,
        relationships = self.relationships,
    })
    if not ok then
        logger.warn("Discord: could not encode gateway state", json)
        return
    end
    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir(DataStorage:getDataDir() .. "/cache")
    lfs.mkdir(DataStorage:getDataDir() .. "/cache/discord")
    local f = io.open(stateFile() .. ".tmp", "w")
    if not f then return end
    f:write(json)
    f:close()
    os.rename(stateFile() .. ".tmp", stateFile())
end

--- Saves the state after `delay` seconds, then every 10 minutes while connected.
function Gateway:scheduleSave(delay)
    self._save = self._save or function()
        if self.state ~= "ready" then return end
        self:saveState()
        self:scheduleSave(600)
    end
    UIManager:unschedule(self._save)
    UIManager:scheduleIn(delay, self._save)
end

--- Loads the cached state of `user_id`. Returns true if something was loaded.
function Gateway:loadState(user_id)
    if self.state == "ready" or self.cached then return true end
    local f = io.open(stateFile(), "r")
    if not f then return false end
    local ok, d = pcall(rapidjson.decode, f:read("*a"))
    f:close()
    if not ok or type(d) ~= "table" or d.version ~= 1 or not d.me or d.me.id ~= user_id then
        return false
    end
    stripNulls(d)
    self.me = d.me
    self.session_id, self.seq, self.resume_url = d.session_id, d.seq, d.resume_url
    self.guilds, self.guild_order, self.channels, self.private_channels = {}, {}, {}, {}
    for _, g in ipairs(d.guilds or {}) do
        self.guilds[g.id] = g
        table.insert(self.guild_order, g.id)
        self.nicks[g.id] = self.nicks[g.id] or {}
        for _, list in ipairs({ g.channels or {}, g.threads or {} }) do
            for _, ch in ipairs(list) do self.channels[ch.id] = ch end
        end
        g.channels, g.threads, g.roles, g.my_roles = g.channels or {}, g.threads or {}, g.roles or {}, g.my_roles or {}
    end
    for _, ch in ipairs(d.private or {}) do
        self.channels[ch.id] = ch
        table.insert(self.private_channels, ch.id)
    end
    self.read_states = d.read_states or {}
    self.muted_guilds = d.muted_guilds or {}
    self.muted_channels = d.muted_channels or {}
    self.suppress_everyone = d.suppress_everyone or {}
    self.users = d.users or {}
    self.relationships = d.relationships or {}
    self.cached = true
    logger.info("Discord: loaded cached gateway state from", os.date("%c", d.saved_at or 0))
    return true
end

-- Connection

function Gateway:start(api)
    self.api = api or self.api
    self.want_connected = true
    if self.state ~= "disconnected" or not self.api or not self.api.token then return end
    if self.api.user then self:loadState(self.api.user.id) end
    if not NetworkMgr:isOnline() then return end
    self:connect()
end

function Gateway:stop(keep_session)
    self.want_connected = false
    self:disconnect(keep_session)
end

function Gateway:disconnect(keep_session)
    UIManager:unschedule(self._tick)
    UIManager:unschedule(self._reconnect)
    UIManager:unschedule(self._save)
    if not keep_session then
        self.session_id = nil
        self.seq = nil
    end
    self:saveState()
    if self.ws then
        self.ws:close(keep_session and 4000 or 1000)
        self.ws = nil
    end
    if self.state ~= "disconnected" then
        self.state = "disconnected"
        self:emit("state", self.state)
    end
end

function Gateway:connect()
    local url = GATEWAY_URL
    if self.session_id and self.resume_url then
        url = self.resume_url .. "/?v=9&encoding=json"
    end
    self.state = "connecting"
    self:emit("state", self.state)
    local ws, err = WebSocket.connect(url, {
        ["User-Agent"] = DiscordAPI.USER_AGENT,
        ["Origin"] = "https://discord.com",
    })
    if not ws then
        logger.warn("Discord: gateway connect failed", err)
        self.state = "disconnected"
        self:emit("state", self.state)
        self:scheduleReconnect()
        return
    end
    self.ws = ws
    self.heartbeat_interval = nil
    self.last_heartbeat = nil
    self.heartbeat_acked = true
    self:scheduleTick(0.2)
end

function Gateway:scheduleReconnect()
    if not self.want_connected then return end
    self.retries = self.retries + 1
    local delay = math.min(300, 2 ^ math.min(self.retries, 8))
    self._reconnect = self._reconnect or function()
        if self.want_connected and self.state == "disconnected" then
            if NetworkMgr:isOnline() then
                self:connect()
            else
                self:scheduleReconnect()
            end
        end
    end
    UIManager:unschedule(self._reconnect)
    UIManager:scheduleIn(delay, self._reconnect)
end

--- How often to read the socket: fast while a chat is open or while loading.
function Gateway:tickInterval()
    if self.state ~= "ready" then return 0.3 end
    if self.foreground > 0 then return 1 end
    return 4
end

function Gateway:scheduleTick(delay)
    self._tick = self._tick or function() self:tick() end
    UIManager:unschedule(self._tick)
    UIManager:scheduleIn(delay or self:tickInterval(), self._tick)
end

function Gateway:setForeground(active)
    self.foreground = math.max(0, self.foreground + (active and 1 or -1))
    if self.ws and active then self:scheduleTick(0.1) end
end

function Gateway:sendOp(op, d)
    if not self.ws then return false end
    return self.ws:send(rapidjson.encode({ op = op, d = d }))
end

function Gateway:heartbeat()
    self.heartbeat_acked = false
    self.last_heartbeat = socket.gettime()
    self:sendOp(1, self.seq or NULL)
end

function Gateway:identify()
    self:sendOp(2, {
        token = self.api.token,
        capabilities = CAPABILITIES,
        compress = false,
        properties = {
            os = "Linux",
            browser = "Chrome",
            device = "",
            system_locale = "en-US",
            browser_user_agent = DiscordAPI.USER_AGENT,
            browser_version = "130.0.0.0",
            os_version = "",
            referrer = "",
            referring_domain = "",
            release_channel = "stable",
        },
        presence = self:presence(),
    })
end

function Gateway:presence()
    local status = self.status or (self.activity and "online") or "unknown"
    return {
        status = status,
        since = 0,
        activities = rapidjson.array(self.activity and { self.activity } or {}),
        afk = false,
    }
end

--- Changes our presence for this session.
function Gateway:setStatus(status)
    self.status = status
    if self:isReady() then self:sendOp(3, self:presence()) end
end

--- Sets (or clears, with nil) the activity shown on our profile, e.g. the book being read.
function Gateway:setActivity(activity)
    self.activity = activity
    if self:isReady() then self:sendOp(3, self:presence()) end
end

function Gateway:tick()
    local ws = self.ws
    if not ws then return end
    local ok, messages = pcall(ws.poll, ws)
    if not ok then
        logger.warn("Discord: gateway read error", messages)
        messages = {}
        ws.closed = true
    end
    for _, raw in ipairs(messages) do
        local dok, payload = pcall(rapidjson.decode, raw)
        if dok and type(payload) == "table" then
            local hok, err = pcall(self.handle, self, payload)
            if not hok then logger.warn("Discord: gateway handler error", err) end
        end
        if self.ws ~= ws then return end -- reconnected inside a handler
    end

    if ws.closed then
        logger.info("Discord: gateway closed", ws.close_code, ws.close_reason)
        local code = ws.close_code
        self.ws = nil
        self.state = "disconnected"
        self:emit("state", self.state)
        if code == 4004 then
            -- Authentication failed: do not retry with this token
            self.want_connected = false
            self:emit("auth_failed")
            return
        end
        if code == 4007 or code == 4009 then
            self.session_id = nil
        end
        self:scheduleReconnect()
        return
    end

    if self.heartbeat_interval then
        local now = socket.gettime()
        if now - (self.last_heartbeat or 0) >= self.heartbeat_interval then
            if not self.heartbeat_acked then
                -- Zombie connection: reconnect and resume
                self:disconnect(true)
                self:scheduleReconnect()
                return
            end
            self:heartbeat()
        end
    end
    self:scheduleTick()
end

function Gateway:handle(p)
    local op = p.op
    if op == 10 then
        self.heartbeat_interval = p.d.heartbeat_interval / 1000
        -- First beat after a random fraction of the interval, as the docs ask
        self.last_heartbeat = socket.gettime() - self.heartbeat_interval * math.random()
        if self.session_id and self.seq then
            self:sendOp(6, { token = self.api.token, session_id = self.session_id, seq = self.seq })
        else
            self:identify()
        end
    elseif op == 11 then
        self.heartbeat_acked = true
    elseif op == 1 then
        self:heartbeat()
    elseif op == 7 then
        self:disconnect(true)
        self:scheduleReconnect()
    elseif op == 9 then
        if not v(p.d) then
            self.session_id = nil
            self.seq = nil
        end
        self:disconnect(v(p.d) and true or false)
        self.want_connected = true
        self:scheduleReconnect()
    elseif op == 0 then
        if v(p.s) then self.seq = p.s end
        self:dispatch(p.t, p.d)
    end
end

-- State handling

local function trimChannel(ch, guild_id)
    return {
        id = ch.id,
        type = ch.type,
        name = v(ch.name),
        guild_id = guild_id or v(ch.guild_id),
        parent_id = v(ch.parent_id),
        position = v(ch.position),
        last_message_id = v(ch.last_message_id),
        permission_overwrites = ch.permission_overwrites,
        thread_metadata = ch.thread_metadata,
        recipient_ids = ch.recipient_ids,
        recipients = ch.recipients,
        flags = v(ch.flags),
    }
end

function Gateway:addGuild(g, my_member)
    local props = g.properties or g
    local guild = {
        id = g.id,
        name = v(props.name) or v(g.name) or "?",
        owner_id = v(props.owner_id) or v(g.owner_id),
        roles = {},
        channels = {},
        threads = {},
        my_roles = my_member and my_member.roles or {},
    }
    for _, r in ipairs(g.roles or {}) do
        table.insert(guild.roles, { id = r.id, name = v(r.name), permissions = v(r.permissions) })
    end
    for _, ch in ipairs(g.channels or {}) do
        local c = trimChannel(ch, g.id)
        table.insert(guild.channels, c)
        self.channels[c.id] = c
    end
    for _, th in ipairs(g.threads or {}) do
        local c = trimChannel(th, g.id)
        table.insert(guild.threads, c)
        self.channels[c.id] = c
    end
    if not self.guilds[g.id] then
        table.insert(self.guild_order, g.id)
    end
    self.guilds[g.id] = guild
    self.nicks[g.id] = self.nicks[g.id] or {}
    if my_member and v(my_member.nick) then
        self.nicks[g.id][self.me.id] = my_member.nick
    end
end

function Gateway:loadReady(d)
    self.me = d.user
    self.session_id = d.session_id
    self.resume_url = v(d.resume_gateway_url)
    self.guilds, self.guild_order, self.channels = {}, {}, {}
    self.private_channels, self.read_states = {}, {}
    self.muted_guilds, self.muted_channels, self.suppress_everyone = {}, {}, {}
    self.users = {}

    for _, u in ipairs(d.users or {}) do
        self.users[u.id] = { id = u.id, username = v(u.username), global_name = v(u.global_name), bot = v(u.bot) }
    end
    for i, g in ipairs(d.guilds or {}) do
        local my_member
        for _, m in ipairs((d.merged_members or {})[i] or {}) do
            if m.user_id == self.me.id then my_member = m end
        end
        if not v(g.unavailable) then
            self:addGuild(g, my_member)
        end
    end
    for _, ch in ipairs(d.private_channels or {}) do
        local c = trimChannel(ch)
        if not c.recipients and c.recipient_ids then
            c.recipients = {}
            for _, uid in ipairs(c.recipient_ids) do
                table.insert(c.recipients, self.users[uid] or { id = uid, username = uid })
            end
        end
        self.channels[c.id] = c
        table.insert(self.private_channels, c.id)
    end
    self.relationships = {}
    for _, r in ipairs(d.relationships or {}) do
        local uid = v(r.user_id) or r.id
        local user = r.user or self.users[uid] or { id = uid, username = uid }
        self.relationships[uid] = { type = r.type, user = user, nickname = v(r.nickname) }
    end
    local rs = d.read_state and (d.read_state.entries or d.read_state) or {}
    for _, r in ipairs(rs) do
        if (v(r.read_state_type) or 0) == 0 then
            self.read_states[r.id] = {
                last_message_id = v(r.last_message_id),
                mention_count = v(r.mention_count) or 0,
            }
        end
    end
    local ugs = d.user_guild_settings and (d.user_guild_settings.entries or d.user_guild_settings) or {}
    local now = os.time()
    local function isMuted(entry)
        if not v(entry.muted) then return false end
        local cfg = v(entry.mute_config)
        local end_time = cfg and v(cfg.end_time)
        if end_time then
            local y, mo, dd, h, mi, s = end_time:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
            if y and os.time{ year = y, month = mo, day = dd, hour = h, min = mi, sec = s } < now then
                return false
            end
        end
        return true
    end
    for _, e in ipairs(ugs) do
        local gid = v(e.guild_id)
        if gid then
            if isMuted(e) then self.muted_guilds[gid] = true end
            if v(e.suppress_everyone) then self.suppress_everyone[gid] = true end
        end
        for _, co in ipairs(e.channel_overrides or {}) do
            if isMuted(co) then self.muted_channels[co.channel_id] = true end
        end
    end
end

function Gateway:dispatch(t, d)
    if t == "READY" then
        logger.info("Discord: gateway READY (new session)")
        self:loadReady(d)
        self.cached = false
        self.state = "ready"
        self.retries = 0
        self:emit("state", self.state)
        self:emit("ready")
        self:scheduleSave(30)
        return
    end
    if t == "RESUMED" then
        logger.info("Discord: gateway session resumed")
        self.cached = false
        self.state = "ready"
        self.retries = 0
        self:emit("state", self.state)
        if self.activity then self:sendOp(3, self:presence()) end
        self:emit("resumed")
        self:scheduleSave(30)
        return
    end
    if type(d) == "table" then stripNulls(d) end

    if t == "MESSAGE_CREATE" then
        local ch = self.channels[d.channel_id]
        if ch then ch.last_message_id = d.id end
        if d.guild_id and d.member and d.author then
            self.nicks[d.guild_id] = self.nicks[d.guild_id] or {}
            self.nicks[d.guild_id][d.author.id] = d.member.nick
        end
        local rs = self.read_states[d.channel_id]
        if d.author and self.me and d.author.id == self.me.id then
            self.read_states[d.channel_id] = { last_message_id = d.id, mention_count = 0 }
        elseif self:mentionsMe(d) then
            rs = rs or { mention_count = 0 }
            rs.mention_count = (rs.mention_count or 0) + 1
            self.read_states[d.channel_id] = rs
        end
        if not ch and not d.guild_id then
            -- New DM channel we did not know about
            self.channels[d.channel_id] = { id = d.channel_id, type = 1, last_message_id = d.id,
                recipients = { d.author } }
            table.insert(self.private_channels, d.channel_id)
        end
    elseif t == "MESSAGE_ACK" then
        self.read_states[d.channel_id] = { last_message_id = d.message_id, mention_count = d.mention_count or 0 }
    elseif t == "CHANNEL_UNREAD_UPDATE" then
        for _, u in ipairs(d.channel_unread_updates or {}) do
            local ch = self.channels[u.id]
            if ch then ch.last_message_id = u.last_message_id end
        end
    elseif t == "CHANNEL_CREATE" or t == "CHANNEL_UPDATE" or t == "THREAD_CREATE" or t == "THREAD_UPDATE" then
        local c = trimChannel(d)
        if not c.recipients and c.recipient_ids then
            c.recipients = {}
            for _, uid in ipairs(c.recipient_ids) do
                table.insert(c.recipients, self.users[uid] or { id = uid, username = uid })
            end
        end
        local existed = self.channels[c.id]
        self.channels[c.id] = c
        local guild = c.guild_id and self.guilds[c.guild_id]
        if guild then
            local list = (c.type == 10 or c.type == 11 or c.type == 12) and guild.threads or guild.channels
            local replaced = false
            for i, old in ipairs(list) do
                if old.id == c.id then list[i] = c replaced = true end
            end
            if not replaced then table.insert(list, c) end
        elseif not existed and (c.type == 1 or c.type == 3) then
            table.insert(self.private_channels, c.id)
        end
    elseif t == "CHANNEL_DELETE" or t == "THREAD_DELETE" then
        self.channels[d.id] = nil
        local guild = d.guild_id and self.guilds[d.guild_id]
        if guild then
            for _, list in ipairs({ guild.channels, guild.threads }) do
                for i = #list, 1, -1 do
                    if list[i].id == d.id then table.remove(list, i) end
                end
            end
        end
    elseif t == "THREAD_LIST_SYNC" then
        local guild = self.guilds[d.guild_id]
        if guild then
            for _, th in ipairs(d.threads or {}) do
                local c = trimChannel(th, d.guild_id)
                self.channels[c.id] = c
                local found = false
                for i, old in ipairs(guild.threads) do
                    if old.id == c.id then guild.threads[i] = c found = true end
                end
                if not found then table.insert(guild.threads, c) end
            end
        end
    elseif t == "GUILD_CREATE" then
        self:addGuild(d, d.members and (function()
            for _, m in ipairs(d.members) do
                if m.user and m.user.id == self.me.id then return m end
            end
        end)())
    elseif t == "GUILD_DELETE" then
        if not d.unavailable then
            self.guilds[d.id] = nil
            for i = #self.guild_order, 1, -1 do
                if self.guild_order[i] == d.id then table.remove(self.guild_order, i) end
            end
        end
    elseif t == "GUILD_MEMBER_UPDATE" then
        if d.user and self.me and d.user.id == self.me.id and self.guilds[d.guild_id] then
            self.guilds[d.guild_id].my_roles = d.roles or {}
        end
        if d.user then
            self.nicks[d.guild_id] = self.nicks[d.guild_id] or {}
            self.nicks[d.guild_id][d.user.id] = d.nick
        end
    elseif t == "GUILD_MEMBERS_CHUNK" then
        local nicks = self.nicks[d.guild_id] or {}
        self.nicks[d.guild_id] = nicks
        local pending = self.pending_members[d.guild_id] or {}
        for _, m in ipairs(d.members or {}) do
            if m.user then
                nicks[m.user.id] = m.nick or false
                self.users[m.user.id] = self.users[m.user.id] or m.user
                pending[m.user.id] = nil
            end
        end
        for _, uid in ipairs(d.not_found or {}) do
            nicks[uid] = false
            pending[uid] = nil
        end
    elseif t == "RELATIONSHIP_ADD" or t == "RELATIONSHIP_UPDATE" then
        local uid = d.user_id or d.id
        local user = d.user or (self.relationships[uid] and self.relationships[uid].user) or self.users[uid]
        self.relationships[uid] = { type = d.type, user = user or { id = uid, username = uid }, nickname = d.nickname }
    elseif t == "RELATIONSHIP_REMOVE" then
        self.relationships[d.user_id or d.id] = nil
    elseif t == "USER_GUILD_SETTINGS_UPDATE" then
        if d.guild_id then
            self.muted_guilds[d.guild_id] = d.muted or nil
        end
        for _, co in ipairs(d.channel_overrides or {}) do
            self.muted_channels[co.channel_id] = co.muted or nil
        end
    end
    self:emit(t, d)
end

-- Queries

function Gateway:mentionsMe(msg)
    if not self.me then return false end
    if msg.author and msg.author.id == self.me.id then return false end
    for _, u in ipairs(msg.mentions or {}) do
        if u.id == self.me.id then return true end
    end
    local guild = msg.guild_id and self.guilds[msg.guild_id]
    if msg.mention_everyone and not (msg.guild_id and self.suppress_everyone[msg.guild_id]) then
        return true
    end
    if guild and msg.mention_roles then
        local mine = {}
        for _, rid in ipairs(guild.my_roles or {}) do mine[rid] = true end
        for _, rid in ipairs(msg.mention_roles) do
            if mine[rid] then return true end
        end
    end
    return false
end

function Gateway:isDM(channel_id)
    local ch = self.channels[channel_id]
    return ch and (ch.type == 1 or ch.type == 3)
end

function Gateway:isMuted(channel)
    if not channel then return false end
    if self.muted_channels[channel.id] then return true end
    if channel.parent_id and self.muted_channels[channel.parent_id] then return true end
    if channel.guild_id and self.muted_guilds[channel.guild_id] then return true end
    return false
end

function Gateway:isUnread(channel)
    if not channel or not channel.last_message_id then return false end
    local rs = self.read_states[channel.id]
    if not rs then return false end
    return idLess(rs.last_message_id or "0", channel.last_message_id)
end

function Gateway:mentionCount(channel_id)
    local rs = self.read_states[channel_id]
    return rs and rs.mention_count or 0
end

function Gateway:markRead(channel_id, message_id)
    self.read_states[channel_id] = { last_message_id = message_id, mention_count = 0 }
    local ch = self.channels[channel_id]
    if ch and (not ch.last_message_id or idLess(ch.last_message_id, message_id)) then
        ch.last_message_id = message_id
    end
end

function Gateway:permissionResolver(guild)
    return self.api:permissionResolver(guild, { roles = guild.my_roles or {} })
end

--- Unread state of a guild: unread (bool), mentions (number).
function Gateway:guildUnread(guild_id)
    local guild = self.guilds[guild_id]
    if not guild then return false, 0 end
    local perms_of = self:permissionResolver(guild)
    local unread, mentions = false, 0
    for _, list in ipairs({ guild.channels, guild.threads }) do
        for _, ch in ipairs(list) do
            if ch.type == 0 or ch.type == 5 or ch.type == 10 or ch.type == 11 or ch.type == 12 then
                local parent = ch.parent_id and self.channels[ch.parent_id]
                local check = (ch.type >= 10 and parent) or ch
                if DiscordAPI.hasPerm(perms_of(check), DiscordAPI.PERM_VIEW_CHANNEL) then
                    mentions = mentions + self:mentionCount(ch.id)
                    if not unread and not self:isMuted(ch) and self:isUnread(ch) then
                        unread = true
                    end
                end
            end
        end
    end
    if self.muted_guilds[guild_id] then unread = false end
    return unread, mentions
end

function Gateway:dmUnread()
    local count, mentions = 0, 0
    for _, id in ipairs(self.private_channels) do
        local ch = self.channels[id]
        if ch and self:isUnread(ch) and not self:isMuted(ch) then
            count = count + 1
        end
        mentions = mentions + self:mentionCount(id)
    end
    return count, mentions
end

-- Guild subscriptions and members

function Gateway:subscribeGuild(guild_id)
    self.subscribed = self.subscribed or {}
    if self.subscribed[guild_id] or not self:isReady() then return end
    self.subscribed[guild_id] = true
    self:sendOp(14, { guild_id = guild_id, typing = true, threads = true, activities = false })
end

--- Asks for the nicknames of users we have not seen yet in this guild.
function Gateway:requestMembers(guild_id, user_ids)
    if not self:isReady() then return end
    local nicks = self.nicks[guild_id] or {}
    local pending = self.pending_members[guild_id] or {}
    self.pending_members[guild_id] = pending
    local wanted = {}
    for _, uid in ipairs(user_ids) do
        if nicks[uid] == nil and not pending[uid] and #wanted < 100 then
            pending[uid] = true
            table.insert(wanted, uid)
        end
    end
    if #wanted > 0 then
        self:sendOp(8, { guild_id = { guild_id }, user_ids = wanted, presences = false })
    end
end

--- Member search for the mention picker; results come in a GUILD_MEMBERS_CHUNK with this nonce.
function Gateway:searchMembers(guild_id, query, nonce)
    if not self:isReady() then return false end
    self:sendOp(8, { guild_id = { guild_id }, query = query, limit = 10, presences = false, nonce = nonce })
    return true
end

function Gateway:nick(guild_id, user_id)
    local nicks = guild_id and self.nicks[guild_id]
    local n = nicks and nicks[user_id]
    if n then return n end
    return nil
end

return Gateway
