-- Run from the plugin directory: lua tools/test_thread_membership.lua
package.loaded.discord_net = {}
package.loaded.rapidjson = { null = {} }
package.loaded["socket.http"] = {}
package.loaded.logger = {}
package.loaded.ltn12 = {}
package.loaded.socket = {}
package.loaded.socketutil = {}
package.loaded.bit = { band = function() return 0 end }
package.loaded.discord_i18n = function(s) return s end

local API = require("discord_api")
local api = API:new{}
local paths = {}
function api:get(path)
    paths[#paths + 1] = path
    if path == "/channels/joined" then return true, { member = { id = "me" } } end
    if path == "/channels/not-joined" then return true, { id = "not-joined" } end
    return false, "network error", 503
end

assert(api:isThreadMember("joined") == true)
assert(api:isThreadMember("not-joined") == false)
assert(api:isThreadMember("unavailable") == nil)
for _, path in ipairs(paths) do
    assert(not path:find("thread-members/@me", 1, true), "the bot-only endpoint must not be used")
end
print("Thread membership lookup tests passed")
