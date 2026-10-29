--[[--
Minimal non-blocking WebSocket client (RFC 6455) over luasocket + luasec.

Only what the Discord gateway needs: TLS, text frames, ping/pong, close.
Call `poll()` regularly to read incoming frames.

@module koplugin.discord.websocket
]]

local bit = require("bit")
local mime = require("mime")
local socket = require("socket")
local ssl = require("ssl")

local WebSocket = {}
WebSocket.__index = WebSocket

local OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA

local function randomBytes(n)
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

local function parseUrl(url)
    local scheme, host, port, path = url:match("^(wss?)://([^/:]+):?(%d*)(.*)$")
    if not scheme then return nil end
    if path == "" then path = "/" end
    port = tonumber(port) or (scheme == "wss" and 443 or 80)
    return scheme, host, port, path
end

--- Opens a connection. Returns a WebSocket object, or nil and an error.
function WebSocket.connect(url, headers, timeout)
    local scheme, host, port, path = parseUrl(url)
    if not scheme then return nil, "invalid url" end
    local tcp = socket.tcp()
    tcp:settimeout(timeout or 15)
    local ok, err = tcp:connect(host, port)
    if not ok then return nil, err end
    local conn = tcp
    if scheme == "wss" then
        conn, err = ssl.wrap(tcp, {
            mode = "client",
            protocol = "any",
            verify = "none",
            options = { "all", "no_sslv2", "no_sslv3" },
        })
        if not conn then tcp:close() return nil, err end
        conn:sni(host)
        ok, err = conn:dohandshake()
        if not ok then conn:close() return nil, err end
    end

    local key = mime.b64(randomBytes(16))
    local req = {
        "GET " .. path .. " HTTP/1.1",
        "Host: " .. host,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. key,
        "Sec-WebSocket-Version: 13",
    }
    for k, v in pairs(headers or {}) do
        table.insert(req, k .. ": " .. v)
    end
    ok, err = conn:send(table.concat(req, "\r\n") .. "\r\n\r\n")
    if not ok then conn:close() return nil, err end

    local status = conn:receive("*l")
    if not status or not status:match("^HTTP/1%.1 101") then
        conn:close()
        return nil, "handshake failed: " .. tostring(status)
    end
    repeat
        local line = conn:receive("*l")
        if not line then conn:close() return nil, "handshake failed" end
    until line == ""

    conn:settimeout(0)
    return setmetatable({
        conn = conn,
        buffer = "",
        fragments = nil,
        closed = false,
    }, WebSocket)
end

function WebSocket:sendFrame(opcode, payload)
    if self.closed then return nil, "closed" end
    payload = payload or ""
    local len = #payload
    local header = { string.char(bit.bor(0x80, opcode)) }
    if len < 126 then
        header[2] = string.char(bit.bor(0x80, len))
    elseif len < 65536 then
        header[2] = string.char(0x80 + 126, bit.rshift(len, 8), bit.band(len, 0xFF))
    else
        local b = {}
        for i = 7, 0, -1 do
            b[#b + 1] = string.char(math.floor(len / 2 ^ (8 * i)) % 256)
        end
        header[2] = string.char(0x80 + 127) .. table.concat(b)
    end
    local mask = randomBytes(4)
    local m = { mask:byte(1, 4) }
    local out = {}
    for i = 1, len do
        out[i] = string.char(bit.bxor(payload:byte(i), m[(i - 1) % 4 + 1]))
    end
    local frame = table.concat(header) .. mask .. table.concat(out)
    self.conn:settimeout(10)
    local ok, err = self.conn:send(frame)
    self.conn:settimeout(0)
    if not ok then
        self:close()
        return nil, err
    end
    return true
end

function WebSocket:send(text)
    return self:sendFrame(OP_TEXT, text)
end

function WebSocket:close(code)
    if self.closed then return end
    pcall(function()
        local payload = code and string.char(bit.rshift(code, 8), bit.band(code, 0xFF)) or ""
        self:sendFrame(OP_CLOSE, payload)
    end)
    self.closed = true
    pcall(function() self.conn:close() end)
end

-- Reads whatever is available without blocking.
function WebSocket:fill()
    local chunks = {}
    while true do
        local data, err, partial = self.conn:receive(65536)
        local got = data or partial
        if got and #got > 0 then
            table.insert(chunks, got)
        end
        if not data then
            if err ~= "timeout" and err ~= "wantread" and err ~= "wantwrite" then
                self.closed = true
                self.close_reason = err
            end
            break
        end
    end
    if #chunks > 0 then
        self.buffer = self.buffer .. table.concat(chunks)
    end
end

--- Extracts one complete frame from the buffer, or nil.
function WebSocket:nextFrame()
    local buf = self.buffer
    if #buf < 2 then return nil end
    local b1, b2 = buf:byte(1, 2)
    local fin = bit.band(b1, 0x80) ~= 0
    local opcode = bit.band(b1, 0x0F)
    local masked = bit.band(b2, 0x80) ~= 0
    local len = bit.band(b2, 0x7F)
    local pos = 3
    if len == 126 then
        if #buf < 4 then return nil end
        local h, l = buf:byte(3, 4)
        len = h * 256 + l
        pos = 5
    elseif len == 127 then
        if #buf < 10 then return nil end
        len = 0
        for i = 3, 10 do len = len * 256 + buf:byte(i) end
        pos = 11
    end
    local mask
    if masked then
        if #buf < pos + 3 then return nil end
        mask = { buf:byte(pos, pos + 3) }
        pos = pos + 4
    end
    if #buf < pos + len - 1 then return nil end
    local payload = buf:sub(pos, pos + len - 1)
    self.buffer = buf:sub(pos + len)
    if mask then
        local out = {}
        for i = 1, #payload do
            out[i] = string.char(bit.bxor(payload:byte(i), mask[(i - 1) % 4 + 1]))
        end
        payload = table.concat(out)
    end
    return fin, opcode, payload
end

--- Reads pending data and returns a list of complete text/binary messages.
function WebSocket:poll()
    local messages = {}
    if self.closed then return messages end
    self:fill()
    while true do
        local fin, opcode, payload = self:nextFrame()
        if fin == nil then break end
        if opcode == OP_PING then
            self:sendFrame(OP_PONG, payload)
        elseif opcode == OP_CLOSE then
            if #payload >= 2 then
                self.close_code = payload:byte(1) * 256 + payload:byte(2)
                self.close_reason = payload:sub(3)
            end
            self.closed = true
            pcall(function() self.conn:close() end)
            break
        elseif opcode == OP_TEXT or opcode == OP_BINARY or opcode == OP_CONT then
            if opcode ~= OP_CONT then
                self.fragments = { payload }
            elseif self.fragments then
                table.insert(self.fragments, payload)
            end
            if fin and self.fragments then
                table.insert(messages, table.concat(self.fragments))
                self.fragments = nil
            end
        end
    end
    return messages
end

return WebSocket
