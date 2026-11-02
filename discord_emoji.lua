--[[--
Emoji by name: a search picker for writing and reacting, and the
resolution of `:name:` into real emoji when a message is sent.

The e-ink fonts cannot draw emoji, so everything is shown by its name.
]]

local Gateway = require("discord_gateway")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("discord_i18n")

local Emoji = {}

Emoji.unicode = require("discord_emoji_data")

local RECENT_MAX = 12
local RESULTS_MAX = 80

local sorted_names -- sorted names of the Unicode table, built on first use

local function unicodeNames()
    if not sorted_names then
        sorted_names = {}
        for name in pairs(Emoji.unicode) do table.insert(sorted_names, name) end
        table.sort(sorted_names)
    end
    return sorted_names
end

--- Custom emoji usable here: those of `guild_id` first, then those of every other server.
function Emoji.customList(guild_id)
    local list = {}
    local function add(guild)
        for __, e in ipairs(guild.emojis or {}) do
            table.insert(list, {
                name = e.name, id = e.id, animated = e.animated, source = guild.name,
                here = guild.id == guild_id,
            })
        end
    end
    if guild_id and Gateway.guilds[guild_id] then add(Gateway.guilds[guild_id]) end
    for __, gid in ipairs(Gateway.guild_order) do
        local guild = Gateway.guilds[gid]
        if guild and gid ~= guild_id then add(guild) end
    end
    return list
end

--- Text that goes into the message for an emoji item.
function Emoji.markup(item)
    if item.id then
        return "<" .. (item.animated and "a" or "") .. ":" .. item.name .. ":" .. item.id .. ">"
    end
    return Emoji.unicode[item.name] or (":" .. item.name .. ":")
end

--- Emoji table for the reactions API.
function Emoji.reactionOf(item)
    if item.id then return { name = item.name, id = item.id } end
    return { name = Emoji.unicode[item.name] }
end

--- Finds an emoji by exact name. `map` has explicit choices (name -> item).
function Emoji.find(name, guild_id, map)
    if map and map[name] then return map[name] end
    local custom = Emoji.customList(guild_id)
    for __, e in ipairs(custom) do
        if e.name == name then return e end
    end
    local lower = name:lower()
    for __, e in ipairs(custom) do
        if e.name:lower() == lower then return e end
    end
    if Emoji.unicode[lower] then return { name = lower } end
    return nil
end

--- Replaces `:name:` with the real emoji; unknown names and existing <:name:id> stay as written.
function Emoji.resolve(text, guild_id, map)
    if not text:find(":", 1, true) then return text end
    return (text:gsub("()(:[%w_][%w_]*:)", function(pos, token)
        if text:sub(pos - 1, pos - 1) == "<" or text:sub(pos - 2, pos - 1) == "<a" then return nil end
        local item = Emoji.find(token:sub(2, -2), guild_id, map)
        return item and Emoji.markup(item) or nil
    end))
end

--- Items matching a query: { name, id?, animated?, source? }.
function Emoji.search(query, guild_id, recent)
    query = (query or ""):lower():gsub("^:", ""):gsub(":$", ""):gsub("%s+", "_")
    local out = {}
    if query == "" then
        for __, item in ipairs(recent or {}) do table.insert(out, item) end
        for __, e in ipairs(Emoji.customList(guild_id)) do
            if e.here then table.insert(out, e) end
        end
        for __, name in ipairs({ "fire", "thumbsup", "heart", "joy", "pray", "tada", "eyes", "100", "thinking", "sob" }) do
            table.insert(out, { name = name })
        end
        return out
    end
    local ranked = {}
    local function consider(item)
        local name = item.name:lower()
        local rank
        if name == query then rank = 1
        elseif name:sub(1, #query) == query then rank = 2
        elseif name:find(query, 1, true) then rank = 3 end
        if rank then
            if item.id and not item.here then rank = rank + 0.5 end
            table.insert(ranked, { item = item, rank = rank, name = name })
        end
    end
    for __, e in ipairs(Emoji.customList(guild_id)) do consider(e) end
    for __, name in ipairs(unicodeNames()) do consider({ name = name }) end
    table.sort(ranked, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if #a.name ~= #b.name then return #a.name < #b.name end
        return a.name < b.name
    end)
    for i = 1, math.min(#ranked, RESULTS_MAX) do table.insert(out, ranked[i].item) end
    return out
end

local function rememberRecent(settings, item)
    if not settings then return end
    local list = settings.recent_emojis or {}
    for i = #list, 1, -1 do
        if list[i].name == item.name and list[i].id == item.id then table.remove(list, i) end
    end
    table.insert(list, 1, { name = item.name, id = item.id, animated = item.animated, source = item.source })
    while #list > RECENT_MAX do table.remove(list) end
    settings.recent_emojis = list
end

--- Shows the picker. opts: { guild_id, settings, on_pick = function(item), title }
function Emoji.pick(opts)
    local function showResults(query)
        local items = {}
        for __, item in ipairs(Emoji.search(query, opts.guild_id, opts.settings and opts.settings.recent_emojis)) do
            table.insert(items, {
                text = ":" .. item.name .. ":",
                mandatory = item.id and (item.source or "") or nil,
                item = item,
            })
        end
        table.insert(items, 1, { text = _("Search emoji…"), search = true })
        if #items == 1 then
            table.insert(items, { text = _("No emoji found"), select_enabled = false })
        end
        local menu
        menu = Menu:new{
            title = opts.title or _("Emoji"),
            item_table = items,
            is_borderless = true,
            is_popout = false,
            covers_fullscreen = true,
            onMenuSelect = function(_menu, entry)
                if entry.search then
                    UIManager:close(menu)
                    Emoji.pick(opts)
                elseif entry.item then
                    UIManager:close(menu)
                    rememberRecent(opts.settings, entry.item)
                    opts.on_pick(entry.item)
                end
                return true
            end,
        }
        menu.close_callback = function() UIManager:close(menu) end
        UIManager:show(menu)
    end
    local dialog
    dialog = InputDialog:new{
        title = opts.title or _("Emoji"),
        description = _("Part of the name, for example: fire"),
        input = "",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)
                    showResults(query)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Emoji
