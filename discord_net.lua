--[[--
Secure connections for the plugin: TLS that checks the server certificate and
host name, and an optional HTTP proxy (CONNECT). Shared by the REST client,
the gateway WebSocket, QR code login and the updater.

KOReader's LuaSec defaults to `verify = "none"`, which would let anyone on the
same Wi-Fi read the account token or serve a fake plugin update.

@module koplugin.discord.net
]]

local logger = require("logger")
local socket = require("socket")
local ssl = require("ssl")

local Net = {
    verify = true,  -- check the certificate chain and host name
    proxy = nil,    -- "host:port" of an HTTP proxy, or nil for a direct connection
    cafile = nil,   -- CA bundle override (nil: autodetect)
}

local CA_FILES = {
    "data/ca-bundle.crt", -- shipped with KOReader (its working directory is the install dir)
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/ssl/certs/ca-bundle.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
}

--- Applies the plugin settings (`verify_tls`, `proxy`).
function Net.configure(settings)
    Net.verify = settings.verify_tls ~= false
    local proxy = settings.proxy
    Net.proxy = (type(proxy) == "string" and proxy:match("%S")) and proxy or nil
end

local found_ca
function Net.caFile()
    if Net.cafile then return Net.cafile end
    if found_ca == nil then
        found_ca = false
        for _, path in ipairs(CA_FILES) do
            local f = io.open(path, "r")
            if f then
                f:close()
                found_ca = path
                break
            end
        end
    end
    return found_ca or nil
end

local function hostMatches(pattern, host)
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then return true end
    if pattern:sub(1, 2) == "*." then
        local dot = host:find(".", 1, true)
        return dot ~= nil and host:sub(dot) == pattern:sub(2)
    end
    return false
end

--- Checks that the peer certificate was issued for `host`.
function Net.checkHost(conn, host)
    local cert = conn:getpeercertificate()
    if not cert then return false, "no server certificate" end
    local ok, ext = pcall(cert.extensions, cert)
    local san = ok and ext and ext["2.5.29.17"]
    if san and san.dNSName then
        for _, name in ipairs(san.dNSName) do
            if hostMatches(name, host) then return true end
        end
    else
        local ok2, subject = pcall(cert.subject, cert)
        for _, e in ipairs(ok2 and subject or {}) do
            if (e.name == "commonName" or e.oid == "2.5.4.3") and hostMatches(e.value, host) then
                return true
            end
        end
    end
    return false, "certificate does not match " .. host
end

function Net.tlsParams()
    local params = {
        mode = "client",
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
        verify = "none",
    }
    if Net.verify then
        local ca = Net.caFile()
        if not ca then
            logger.warn("Discord: no CA bundle found, refusing secure connection")
            return nil, "server certificate verification unavailable: no CA bundle found"
        end
        params.verify = { "peer" }
        params.cafile = ca
    end
    return params
end

--- True if an error message comes from a failed certificate check.
function Net.isCertError(err)
    err = tostring(err or ""):lower()
    return err:find("certificate", 1, true) ~= nil
end

--- Opens a TCP connection to host:port, through the proxy if one is set.
function Net.tcp(host, port, timeout)
    local sock = socket.tcp()
    sock:settimeout(timeout or 15)
    local chost, cport = host, port
    if Net.proxy then
        local ph, pp = Net.proxy:gsub("^%a+://", ""):match("^([^:/]+):(%d+)")
        if not ph then return nil, "invalid proxy: " .. Net.proxy end
        chost, cport = ph, tonumber(pp)
    end
    local ok, err = sock:connect(chost, cport)
    if not ok then
        sock:close()
        return nil, err
    end
    if Net.proxy then
        sock:send(string.format("CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n", host, port, host, port))
        local line, rerr = sock:receive("*l")
        if not line or not line:match("^HTTP/%d%.%d 2%d%d") then
            sock:close()
            return nil, "proxy refused the connection: " .. tostring(line or rerr)
        end
        repeat line = sock:receive("*l") until not line or line == ""
    end
    return sock
end

--- Opens a TLS connection to host:port (SNI, certificate and host name checks).
function Net.connect(host, port, timeout)
    local params, perr = Net.tlsParams()
    if not params then return nil, perr end
    local sock, err = Net.tcp(host, port, timeout)
    if not sock then return nil, err end
    local conn, werr = ssl.wrap(sock, params)
    if not conn then
        sock:close()
        return nil, werr
    end
    conn:sni(host)
    conn:settimeout(timeout or 15)
    local ok, herr = conn:dohandshake()
    if not ok then
        conn:close()
        return nil, herr
    end
    if params.verify ~= "none" then
        local vok, verr = Net.checkHost(conn, host)
        if not vok then
            conn:close()
            return nil, verr
        end
    end
    return conn
end

--- A `create` function for LuaSocket's http.request on https:// URLs,
-- so REST calls and downloads use Net.connect().
function Net.create()
    return function()
        local timeout = 15
        local c = {}
        function c:settimeout(t)
            timeout = t or timeout
            local sock = rawget(self, "sock")
            if sock then sock:settimeout(timeout) end
            return 1
        end
        function c:connect(host, port)
            local sock, err = Net.connect(host, port, timeout)
            if not sock then return nil, err end
            rawset(self, "sock", sock)
            return 1
        end
        function c:close()
            local sock = rawget(self, "sock")
            if sock then sock:close() end
            return 1
        end
        -- everything else (send, receive, ...) goes to the TLS socket
        return setmetatable(c, {
            __index = function(_, key)
                return function(self, ...)
                    local sock = rawget(self, "sock")
                    if not sock then return nil, "closed" end
                    return sock[key](sock, ...)
                end
            end,
        })
    end
end

--- Adds the secure `create` function to an http.request table for https:// URLs.
function Net.prepare(reqt)
    if not reqt.create and type(reqt.url) == "string" and reqt.url:match("^https://") then
        reqt.create = Net.create()
    end
    return reqt
end

return Net
