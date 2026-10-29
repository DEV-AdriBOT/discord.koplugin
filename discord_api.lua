--[[--
Minimal Discord REST client (API v9) for KOReader.

@module koplugin.discord.api
]]

local rapidjson = require("rapidjson")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local bit = require("bit")

local API_BASE = "https://discord.com/api/v9"
local USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

-- rapidjson decodes null as a truthy sentinel; turn those into plain nils
local function stripNulls(v)
    if type(v) ~= "table" then return v end
    for k, x in pairs(v) do
        if x == rapidjson.null then
            v[k] = nil
        elseif type(x) == "table" then
            stripNulls(x)
        end
    end
    return v
end

local DiscordAPI = {
    token = nil,
    user = nil,
}

function DiscordAPI:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- Performs a request. Returns ok, result_or_error, http_code.
function DiscordAPI:request(method, path, body, no_auth, retried)
    local sink = {}
    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Accept"] = "application/json",
        ["X-Discord-Locale"] = "en-US",
    }
    if not no_auth and self.token then
        headers["Authorization"] = self.token
    end
    local source
    if body ~= nil then
        local payload = rapidjson.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
        source = ltn12.source.string(payload)
    end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = API_BASE .. path,
        method = method,
        headers = headers,
        source = source,
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    if resp_headers == nil then
        logger.warn("Discord: network error", method, path, status or code)
        return false, "Network error", nil
    end

    local content = table.concat(sink)
    local data
    if content ~= "" then
        local ok, decoded = pcall(rapidjson.decode, content)
        if ok then data = stripNulls(decoded) end
    end

    if code == 429 and not retried then
        local wait = (type(data) == "table" and tonumber(data.retry_after)) or 1
        if wait <= 5 then
            logger.info("Discord: rate limited, waiting", wait)
            socket.sleep(wait + 0.1)
            return self:request(method, path, body, no_auth, true)
        end
    end

    if type(code) == "number" and code >= 200 and code < 300 then
        return true, data, code
    end

    local msg = type(data) == "table" and data.message or status or tostring(code)
    logger.warn("Discord: request failed", method, path, code, content)
    return false, msg, code, data
end

function DiscordAPI:get(path) return self:request("GET", path) end
function DiscordAPI:post(path, body) return self:request("POST", path, body or {}) end
function DiscordAPI:patch(path, body) return self:request("PATCH", path, body or {}) end
function DiscordAPI:delete(path) return self:request("DELETE", path) end

-- Authentication

--- Email/password login. Returns ok, token_or_error, mfa_ticket.
function DiscordAPI:login(email, password)
    local ok, data, code, err_data = self:request("POST", "/auth/login", {
        login = email,
        password = password,
        undelete = false,
    }, true)
    if not ok then
        err_data = err_data or {}
        if err_data.captcha_key or err_data.captcha_sitekey then
            return false, "Discord is asking for a captcha. Log in with a token instead."
        end
        if err_data.errors then
            local e = err_data.errors.login or err_data.errors.password
            if e and e._errors and e._errors[1] then
                return false, e._errors[1].message
            end
        end
        return false, data or ("Error " .. tostring(code))
    end
    if data.token then
        return true, data.token
    end
    if data.mfa and data.ticket then
        return true, nil, data.ticket
    end
    if data.suspended_user_token then
        return false, "This account is suspended."
    end
    return false, "Unexpected server response."
end

function DiscordAPI:loginMFA(ticket, code)
    local ok, data = self:request("POST", "/auth/mfa/totp", {
        code = code,
        ticket = ticket,
    }, true)
    if ok and data and data.token then
        return true, data.token
    end
    return false, data or "Invalid code"
end

function DiscordAPI:fetchMe()
    local ok, data, code = self:get("/users/@me")
    if ok then self.user = data end
    return ok, data, code
end

-- Data

function DiscordAPI:getGuilds()
    return self:get("/users/@me/guilds?with_counts=false")
end

function DiscordAPI:getGuild(guild_id)
    return self:get("/guilds/" .. guild_id)
end

function DiscordAPI:getGuildChannels(guild_id)
    return self:get("/guilds/" .. guild_id .. "/channels")
end

function DiscordAPI:getMyMember(guild_id)
    return self:get("/users/@me/guilds/" .. guild_id .. "/member")
end

function DiscordAPI:getDMChannels()
    return self:get("/users/@me/channels")
end

function DiscordAPI:getMessages(channel_id, opts)
    opts = opts or {}
    local q = "?limit=" .. (opts.limit or 50)
    if opts.before then q = q .. "&before=" .. opts.before end
    if opts.after then q = q .. "&after=" .. opts.after end
    return self:get("/channels/" .. channel_id .. "/messages" .. q)
end

--- Discord-style snowflake for the nonce, based on the current time.
local function makeNonce()
    local ms = math.floor(socket.gettime() * 1000) - 1420070400000
    -- ms * 2^22, written without losing precision
    return string.format("%.0f", ms * 4194304 + math.random(0, 4194303))
end

function DiscordAPI:sendMessage(channel_id, content, reply_to)
    local body = {
        content = content,
        nonce = makeNonce(),
        tts = false,
        flags = 0,
    }
    if reply_to then
        body.message_reference = {
            message_id = reply_to.id,
            channel_id = channel_id,
            guild_id = reply_to.guild_id,
        }
    end
    return self:post("/channels/" .. channel_id .. "/messages", body)
end

function DiscordAPI:editMessage(channel_id, message_id, content)
    return self:patch("/channels/" .. channel_id .. "/messages/" .. message_id, { content = content })
end

function DiscordAPI:deleteMessage(channel_id, message_id)
    return self:delete("/channels/" .. channel_id .. "/messages/" .. message_id)
end

function DiscordAPI:ackMessage(channel_id, message_id)
    return self:post("/channels/" .. channel_id .. "/messages/" .. message_id .. "/ack", { token = rapidjson.null })
end

function DiscordAPI:openDM(user_id)
    return self:post("/users/@me/channels", { recipients = { user_id } })
end

-- Permissions (only the low 32 bits matter for what we check)

local PERM_ADMINISTRATOR = 0x8
local PERM_VIEW_CHANNEL = 0x400
local PERM_SEND_MESSAGES = 0x800
DiscordAPI.PERM_VIEW_CHANNEL = PERM_VIEW_CHANNEL
DiscordAPI.PERM_SEND_MESSAGES = PERM_SEND_MESSAGES

local function low32(v)
    v = tonumber(v) or 0
    return bit.tobit(v % 4294967296)
end

--- Builds a function(channel) -> permission bits for the current user.
function DiscordAPI:permissionResolver(guild, member)
    local user_id = self.user and self.user.id
    local guild_id = guild.id
    local roles_by_id = {}
    for _, role in ipairs(guild.roles or {}) do
        roles_by_id[role.id] = low32(role.permissions)
    end
    local member_roles = {}
    local base = roles_by_id[guild_id] or 0
    for _, rid in ipairs(member.roles or {}) do
        member_roles[rid] = true
        base = bit.bor(base, roles_by_id[rid] or 0)
    end
    local is_admin = guild.owner_id == user_id or bit.band(base, PERM_ADMINISTRATOR) ~= 0

    return function(channel)
        if is_admin then return bit.bnot(0) end
        local perms = base
        local ows = channel.permission_overwrites or {}
        for _, ow in ipairs(ows) do
            if ow.id == guild_id then
                perms = bit.band(perms, bit.bnot(low32(ow.deny)))
                perms = bit.bor(perms, low32(ow.allow))
            end
        end
        local allow, deny = 0, 0
        for _, ow in ipairs(ows) do
            if ow.type == 0 and member_roles[ow.id] then
                allow = bit.bor(allow, low32(ow.allow))
                deny = bit.bor(deny, low32(ow.deny))
            end
        end
        perms = bit.bor(bit.band(perms, bit.bnot(deny)), allow)
        for _, ow in ipairs(ows) do
            if ow.type == 1 and ow.id == user_id then
                perms = bit.band(perms, bit.bnot(low32(ow.deny)))
                perms = bit.bor(perms, low32(ow.allow))
            end
        end
        return perms
    end
end

function DiscordAPI.hasPerm(perms, flag)
    return bit.band(perms, flag) ~= 0
end

-- The Kindle fonts have no emoji glyphs: show the common ones as text
local EMOJI_TEXT = {
    ["😀"] = ":D", ["😃"] = ":D", ["😄"] = ":D", ["😁"] = ":D", ["😆"] = "xD", ["😂"] = "xD", ["🤣"] = "xD",
    ["😅"] = "^^'", ["😊"] = ":)", ["🙂"] = ":)", ["😉"] = ";)", ["😍"] = "*_*", ["🥰"] = "<3", ["😘"] = ":*",
    ["😋"] = ":P", ["😛"] = ":P", ["😜"] = ";P", ["😎"] = "B)", ["🤔"] = "(?)", ["😐"] = ":|", ["😑"] = "-_-",
    ["🙄"] = "¬¬", ["😏"] = ":>", ["😢"] = ":'(", ["😭"] = "T_T", ["😡"] = ">:(", ["😠"] = ">:(", ["😮"] = ":O",
    ["😱"] = "D:", ["😳"] = "O_O", ["🥺"] = ":c", ["😴"] = "zzz", ["🤡"] = ":clown:", ["💀"] = ":skull:",
    ["👍"] = "(y)", ["👎"] = "(n)", ["👌"] = "(ok)", ["👏"] = "*clap*", ["🙏"] = "*thanks*", ["👋"] = "o/",
    ["💪"] = "*strong*", ["🔥"] = "*fire*", ["💯"] = "100", ["🎉"] = "*party*", ["✨"] = "*", ["💔"] = "</3",
    ["💕"] = "<3", ["💖"] = "<3", ["💜"] = "<3", ["💙"] = "<3", ["💚"] = "<3", ["💛"] = "<3", ["🖤"] = "<3",
    ["❤"] = "<3", ["👀"] = "o.o", ["🤷"] = "¯\\_(ツ)_/¯", ["🤦"] = "*facepalm*", ["✅"] = "[v]", ["❌"] = "[x]",
    ["⭐"] = "*", ["♂"] = "", ["♀"] = "", ["📢"] = "", ["📌"] = "", ["🔊"] = "", ["💬"] = "", ["📜"] = "", ["🎮"] = "", ["🎵"] = "",
}

function DiscordAPI.cleanEmoji(text)
    if not text then return text end
    -- Variation selectors, zero width joiners and skin tones
    text = text:gsub("\239\184\143", ""):gsub("\226\128\141", ""):gsub("\240\159\143[\187-\191]", "")
    text = text:gsub("[\226\240][\128-\191]+", function(ch)
        local mapped = EMOJI_TEXT[ch]
        if mapped then return mapped end
        if ch:byte(1) == 240 and ch:byte(2) == 159 then return "[emoji]" end
        return nil
    end)
    return text
end

--- Compares two snowflake ids given as strings.
function DiscordAPI.idLess(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
end

return DiscordAPI
