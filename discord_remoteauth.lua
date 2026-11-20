--[[--
QR code login (Discord's "remote auth"): the e-reader shows a QR code, you
scan it with the Discord app on your phone (Settings → Scan QR Code) and
approve. No password, captcha or token typing on the e-reader.

Protocol (remote-auth-gateway v2):
  S hello{heartbeat_interval, timeout_ms}  -> C init{encoded_public_key}
  S nonce_proof{encrypted_nonce}           -> C nonce_proof{proof = b64url(sha256(nonce))}
  S pending_remote_init{fingerprint}       => QR code: https://discord.com/ra/<fingerprint>
  S pending_ticket{encrypted_user_payload} => "id:discriminator:avatar:username" (scanned)
  S pending_login{ticket}                  => POST /users/@me/remote-auth/login -> encrypted_token
  S cancel                                 => declined on the phone

@module koplugin.discord.remoteauth
]]

local WebSocket = require("discord_websocket")
local logger = require("logger")
local rapidjson = require("rapidjson")
local sha2 = require("ffi/sha2")
local socket = require("socket")

local GATEWAY_URL = "wss://remote-auth-gateway.discord.gg/?v=2"
local QR_PREFIX = "https://discord.com/ra/"

local RemoteAuth = {}
RemoteAuth.__index = RemoteAuth

local function b64url(bin)
    return (sha2.bin2base64(bin):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

--[[--
Creates a session. `api` is a DiscordAPI instance (used without a token).
Callbacks: on_qr(url), on_user({ id, username, discriminator, avatar }),
on_token(token), on_error(message), on_cancel().
]]
function RemoteAuth.new(api, callbacks)
    return setmetatable({ api = api, cb = callbacks or {}, done = false }, RemoteAuth)
end

function RemoteAuth:emit(name, ...)
    local fn = self.cb[name]
    if fn then fn(...) end
end

function RemoteAuth:fail(message)
    if self.done then return end
    self.done = true
    if self.ws then self.ws:close() end
    self:emit("on_error", message)
end

function RemoteAuth:send(t)
    return self.ws:send(rapidjson.encode(t))
end

--- Generates the key pair and connects (blocks for a second or two).
-- Returns true, or nil and an error.
function RemoteAuth:start()
    local ok, key = pcall(function() return require("discord_crypto").generate() end)
    if not ok then return nil, "RSA key generation failed: " .. tostring(key) end
    self.key = key
    local ws, err = WebSocket.connect(GATEWAY_URL, { ["Origin"] = "https://discord.com" })
    if not ws then return nil, err end
    self.ws = ws
    self.started = socket.gettime()
    return true
end

function RemoteAuth:decrypt(b64)
    return self.key:decrypt(sha2.base642bin(b64 or ""))
end

function RemoteAuth:finishLogin(ticket)
    local ok, data, code = self.api:request("POST", "/users/@me/remote-auth/login", { ticket = ticket }, true)
    if not ok or type(data) ~= "table" or not data.encrypted_token then
        return self:fail("refused:" .. tostring(code) .. ":" .. tostring(data))
    end
    local token = self:decrypt(data.encrypted_token)
    if not token then return self:fail("could not decrypt the token") end
    self.done = true
    self.ws:close()
    self:emit("on_token", token)
end

function RemoteAuth:handle(p)
    local op = p.op
    if op == "hello" then
        self.heartbeat_interval = (tonumber(p.heartbeat_interval) or 41250) / 1000
        self.next_heartbeat = socket.gettime() + self.heartbeat_interval
        self.expires = self.started + (tonumber(p.timeout_ms) or 150000) / 1000
        self:send({ op = "init", encoded_public_key = sha2.bin2base64(self.key:publicKeyDER()) })
    elseif op == "nonce_proof" then
        local nonce = self:decrypt(p.encrypted_nonce)
        if not nonce then return self:fail("could not decrypt the nonce") end
        self:send({ op = "nonce_proof", proof = b64url(sha2.hex2bin(sha2.sha256(nonce))) })
    elseif op == "pending_remote_init" then
        self:emit("on_qr", QR_PREFIX .. p.fingerprint)
    elseif op == "pending_ticket" then
        local payload = self:decrypt(p.encrypted_user_payload)
        if payload then
            local id, discriminator, avatar, username = payload:match("^([^:]*):([^:]*):([^:]*):(.*)$")
            self:emit("on_user", { id = id, discriminator = discriminator, avatar = avatar, username = username or payload })
        end
    elseif op == "pending_login" then
        self:finishLogin(p.ticket)
    elseif op == "cancel" then
        self.done = true
        self.ws:close()
        self:emit("on_cancel")
    end
end

--- Call regularly. Returns false once finished (logged in, failed or cancelled).
function RemoteAuth:poll()
    if self.done then return false end
    for _, raw in ipairs(self.ws:poll()) do
        local ok, p = pcall(rapidjson.decode, raw)
        if ok and type(p) == "table" then
            local hok, err = pcall(self.handle, self, p)
            if not hok then
                logger.warn("Discord: remote auth error", err)
                self:fail(tostring(err))
            end
        end
        if self.done then return false end
    end
    if self.ws.closed then
        self:fail(self.ws.close_code == 4003 and "expired" or ("closed:" .. tostring(self.ws.close_code or self.ws.close_reason)))
        return false
    end
    local now = socket.gettime()
    if self.next_heartbeat and now >= self.next_heartbeat then
        self:send({ op = "heartbeat" })
        self.next_heartbeat = now + self.heartbeat_interval
    end
    if self.expires and now > self.expires then
        self:fail("expired")
        return false
    end
    return true
end

function RemoteAuth:stop()
    self.done = true
    if self.ws then self.ws:close() end
end

return RemoteAuth
