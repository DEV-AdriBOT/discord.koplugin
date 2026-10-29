--[[--
Updates the plugin from the latest GitHub release.

@module koplugin.discord.update
]]

local DataStorage = require("datastorage")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")

local REPO = "DEV-AdriBOT/discord.koplugin"
local ASSET_NAME = "discord.koplugin.zip"
local USER_AGENT = "discord.koplugin-updater"

local Update = {
    current = require("discord_version"),
    plugin_dir = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or ".",
}

--- Compares "1.2.3"-style versions. Returns true if a is older than b.
function Update.isOlder(a, b)
    local function parts(v)
        local t = {}
        for n in tostring(v):gsub("^v", ""):gmatch("%d+") do table.insert(t, tonumber(n)) end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y end
    end
    return false
end

--- GET with manual redirect handling (GitHub sends downloads to another host).
local function fetch(url, sink, accept)
    for _ = 1, 5 do
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local code, resp_headers, status = socket.skip(1, http.request{
            url = url,
            redirect = false,
            sink = sink,
            headers = {
                ["User-Agent"] = USER_AGENT,
                ["Accept"] = accept or "application/vnd.github+json",
            },
        })
        socketutil:reset_timeout()
        if not resp_headers then return false, status or code end
        if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) and resp_headers.location then
            url = resp_headers.location
        elseif code == 200 then
            return true
        else
            return false, status or tostring(code)
        end
    end
    return false, "too many redirects"
end

--- Latest release: { version, notes, url (zip) } or nil, error.
function Update.latest()
    local chunks = {}
    local ok, err = fetch("https://api.github.com/repos/" .. REPO .. "/releases/latest", ltn12.sink.table(chunks))
    if not ok then return nil, err end
    local decoded_ok, release = pcall(rapidjson.decode, table.concat(chunks))
    if not decoded_ok or type(release) ~= "table" or type(release.tag_name) ~= "string" then
        return nil, "unexpected answer from GitHub"
    end
    local zip_url
    for _, asset in ipairs(release.assets or {}) do
        if asset.name == ASSET_NAME then zip_url = asset.browser_download_url end
    end
    if not zip_url then return nil, "the release has no " .. ASSET_NAME end
    local notes = release.body
    if type(notes) ~= "string" then notes = "" end
    return {
        version = release.tag_name:gsub("^v", ""),
        notes = notes,
        url = zip_url,
    }
end

--- Downloads and installs a release. Returns true, or false and an error.
-- Every file is read from the archive before anything is written, so a broken
-- download never leaves a half-updated plugin.
function Update.install(release)
    local dir = DataStorage:getDataDir() .. "/cache"
    lfs.mkdir(dir)
    local zip_path = dir .. "/discord.koplugin-update.zip"
    local f = io.open(zip_path, "wb")
    if not f then return false, "cannot write " .. zip_path end
    local ok, err = fetch(release.url, ltn12.sink.file(f), "application/octet-stream")
    if not ok then
        os.remove(zip_path)
        return false, err
    end

    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        os.remove(zip_path)
        return false, "cannot open the downloaded archive"
    end
    local files = {}
    for entry in reader:iterate() do
        -- "discord.koplugin/main.lua" -> "main.lua"
        local rel = entry.path:match("^[^/]+/(.+)$")
        if entry.mode == "file" and rel and not rel:find("..", 1, true)
                and (rel:match("%.lua$") or rel:match("^l10n/[%w_]+%.po$")) then
            table.insert(files, { rel = rel, path = entry.path })
        end
    end
    local contents = {}
    for _, file in ipairs(files) do
        local data = reader:extractToMemory(file.path)
        if not data then
            reader:close()
            os.remove(zip_path)
            return false, "cannot read " .. file.rel
        end
        contents[file.rel] = data
    end
    reader:close()
    os.remove(zip_path)
    if not (contents["main.lua"] and contents["_meta.lua"] and contents["discord_version.lua"]) then
        return false, "the archive does not contain the plugin"
    end

    lfs.mkdir(Update.plugin_dir .. "/l10n")
    for rel, data in pairs(contents) do
        local target = Update.plugin_dir .. "/" .. rel
        local out = io.open(target .. ".new", "wb")
        if not out then return false, "cannot write " .. target end
        out:write(data)
        out:close()
        local renamed, rename_err = os.rename(target .. ".new", target)
        if not renamed then return false, rename_err end
    end
    logger.info("Discord: updated plugin to", release.version)
    return true
end

return Update
