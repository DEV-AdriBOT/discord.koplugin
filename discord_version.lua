-- Installed plugin version, read from _meta.lua (its single source).
-- This file stays because updaters from 1.1.1 and 1.2.0 check that it exists.
local dir = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
local f = io.open(dir .. "/_meta.lua", "r")
local version = f and f:read("*a"):match('version%s*=%s*"([^"]+)"')
if f then f:close() end
return version or "0"
