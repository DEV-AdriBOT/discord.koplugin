--[[--
Several Discord accounts.

`settings.accounts` is a list of { id, token, user, data }. The active
account is mirrored in `settings.token` / `settings.user`, and its own
data (favorites, recents, …) lives in the top-level settings keys; the
others keep theirs in `data` until they are switched to. The disk caches
of each account (gateway state, offline chats, outbox) live in
`cache/discord/<user id>/`.
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Account = {
    id = nil, -- active user id
}

-- Settings that belong to one account
Account.PER_ACCOUNT = { "favorites", "recents", "saved", "hidden_guilds", "drafts", "focus_channels" }

local function root()
    return DataStorage:getDataDir() .. "/cache/discord"
end

local function mkdirs(path)
    lfs.mkdir(DataStorage:getDataDir() .. "/cache")
    lfs.mkdir(root())
    if path ~= root() then lfs.mkdir(path) end
end

--- Cache directory of the active account (created if missing).
function Account.cacheDir()
    local dir = Account.id and (root() .. "/" .. Account.id) or root()
    mkdirs(dir)
    return dir
end

--- Moves the files of the old single-account layout into the account's directory.
function Account.migrateLegacyCache(id)
    local target = root() .. "/" .. id
    if lfs.attributes(target, "mode") == "directory" then return end
    mkdirs(target)
    for __, name in ipairs({ "gateway.json", "outbox.json", "messages" }) do
        local from = root() .. "/" .. name
        if lfs.attributes(from, "mode") then
            os.rename(from, target .. "/" .. name)
        end
    end
end

--- Deletes the disk cache of an account that was logged out.
function Account.purgeCache(id)
    local dir = root() .. "/" .. id
    if lfs.attributes(dir, "mode") == "directory" then
        require("ffi/util").purgeDir(dir)
    end
end

local function find(settings, id)
    for i, acc in ipairs(settings.accounts or {}) do
        if acc.id == id then return acc, i end
    end
end

--- Call once when the settings are loaded: converts a single login into an account.
function Account.init(settings)
    settings.accounts = settings.accounts or {}
    if settings.token and settings.user and settings.user.id and not find(settings, settings.user.id) then
        table.insert(settings.accounts, {
            id = settings.user.id, token = settings.token, user = settings.user, data = {},
        })
        settings.active = settings.user.id
    end
    if settings.active and not find(settings, settings.active) then settings.active = nil end
    Account.id = settings.active
    if Account.id then Account.migrateLegacyCache(Account.id) end
end

function Account.list(settings)
    return settings.accounts or {}
end

function Account.name(acc)
    local user = acc.user or {}
    return user.global_name or user.username or acc.id
end

--- Keeps the active account's data aside, in its entry.
function Account.stash(settings)
    local acc = settings.active and find(settings, settings.active)
    if not acc then return end
    acc.data = acc.data or {}
    for __, key in ipairs(Account.PER_ACCOUNT) do
        acc.data[key] = settings[key]
    end
end

--- Makes `id` the active account. Returns the account or nil.
function Account.switch(settings, id)
    local acc = find(settings, id)
    if not acc then return nil end
    if settings.active ~= id then Account.stash(settings) end
    settings.active = id
    settings.token = acc.token
    settings.user = acc.user
    for __, key in ipairs(Account.PER_ACCOUNT) do
        settings[key] = acc.data and acc.data[key] or nil
    end
    Account.id = id
    Account.migrateLegacyCache(id)
    return acc
end

--- Adds an account (or updates its token) and switches to it.
function Account.add(settings, token, user)
    settings.accounts = settings.accounts or {}
    local acc = find(settings, user.id)
    if acc then
        acc.token, acc.user = token, user
    else
        acc = { id = user.id, token = token, user = user, data = {} }
        table.insert(settings.accounts, acc)
    end
    return Account.switch(settings, user.id)
end

--- Removes an account. If it was the active one, switches to another or logs out.
-- Returns the id of the account that is active afterwards (or nil).
function Account.remove(settings, id)
    local __, index = find(settings, id)
    if not index then return settings.active end
    local was_active = settings.active == id
    table.remove(settings.accounts, index)
    if was_active then
        local nxt = settings.accounts[1]
        if nxt then
            settings.active = nil -- do not stash the removed account's data into the next one
            Account.switch(settings, nxt.id)
        else
            settings.active, settings.token, settings.user = nil, nil, nil
            for __, key in ipairs(Account.PER_ACCOUNT) do settings[key] = nil end
            Account.id = nil
        end
    end
    return settings.active
end

return Account
