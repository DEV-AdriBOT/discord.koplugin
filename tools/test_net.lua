-- Run from the plugin directory: lua tools/test_net.lua
local calls = { tcp = 0, wrap = 0 }
local socket = {}
function socket.tcp()
    calls.tcp = calls.tcp + 1
    return {
        settimeout = function() end,
        connect = function() return true end,
        close = function() end,
    }
end

local ssl = {}
calls.newcontext = 0
function ssl.newcontext(params)
    calls.newcontext = calls.newcontext + 1
    return { params = params }
end
function ssl.wrap(_, ctx)
    assert(type(ctx) == "table" and ctx.params, "connections must use a prebuilt context")
    calls.wrap = calls.wrap + 1
    calls.params = ctx.params
    calls.ctx = ctx
    return {
        sni = function() end,
        settimeout = function() end,
        dohandshake = function() return true end,
        getpeercertificate = function()
            return { extensions = function() return { ["2.5.29.17"] = { dNSName = { "discord.com" } } } end }
        end,
        close = function() end,
    }
end

package.loaded.logger = { warn = function() end }
package.loaded.socket = socket
package.loaded.ssl = ssl
local Net = require("discord_net")

Net.caFile = function() return nil end
Net.verify = true
local conn, err = Net.connect("discord.com", 443)
assert(conn == nil and err:find("certificate", 1, true), "missing CA must fail with a certificate error")
assert(calls.tcp == 0 and calls.wrap == 0, "missing CA must fail before opening a connection")
assert(Net.isCertError(err), "the API must recognize the error")

Net.caFile = function() return "test-ca-bundle.crt" end
conn, err = Net.connect("discord.com", 443)
assert(conn and not err, "a CA bundle must permit a verified connection")
assert(calls.params.cafile == "test-ca-bundle.crt" and calls.params.verify[1] == "peer")

-- The context (and its parsed CA bundle) is built once and shared
local first_ctx = calls.ctx
local contexts = calls.newcontext
for _ = 1, 5 do assert(Net.connect("discord.com", 443)) end
assert(calls.newcontext == contexts and calls.ctx == first_ctx, "connections must share one TLS context")

-- A different CA bundle builds a new one
Net.caFile = function() return "other-ca-bundle.crt" end
assert(Net.connect("discord.com", 443))
assert(calls.newcontext == contexts + 1 and calls.params.cafile == "other-ca-bundle.crt", "a new CA bundle needs a new context")

Net.verify = false
Net.caFile = function() return nil end
conn, err = Net.connect("discord.com", 443)
assert(conn and not err and calls.params.verify == "none", "explicitly disabled verification must still work")
assert(calls.ctx ~= first_ctx, "turning verification off must not reuse the verifying context")

print("TLS certificate fail-closed tests passed")
