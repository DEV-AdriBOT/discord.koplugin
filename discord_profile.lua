--[[--
User profile: name, bio, roles in a server and mutual servers.
]]

local DiscordAPI = require("discord_api")
local Gateway = require("discord_gateway")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("discord_i18n")
local T = require("ffi/util").template

local cleanEmoji = DiscordAPI.cleanEmoji

local Profile = {}

local DISCORD_EPOCH = 1420070400000

--- Creation date of an account (or anything) from its snowflake id.
function Profile.snowflakeTime(id)
    local n = tonumber(id)
    if not n then return nil end
    return math.floor((math.floor(n / 4194304) + DISCORD_EPOCH) / 1000)
end

local function date(ts)
    return ts and os.date("%Y-%m-%d", ts) or "?"
end

--- Builds the profile text. `data` is the API answer, `guild_id` optional.
function Profile.format(user, data, guild_id)
    local lines = {}
    local u = data and data.user or user
    local name = cleanEmoji(u.global_name or u.username or "?")
    table.insert(lines, name)
    if u.username then
        table.insert(lines, "@" .. u.username .. (u.bot and "  [bot]" or ""))
    end
    local profile = data and data.user_profile or {}
    if profile.pronouns and profile.pronouns ~= "" then
        table.insert(lines, cleanEmoji(profile.pronouns))
    end
    table.insert(lines, T(_("Account created: %1"), date(Profile.snowflakeTime(u.id))))
    local bio = profile.bio or u.bio
    if bio and bio ~= "" then
        table.insert(lines, "")
        table.insert(lines, _("About me"))
        table.insert(lines, cleanEmoji(bio))
    end
    local member = data and data.guild_member
    local guild = guild_id and Gateway.guilds[guild_id]
    if member and guild then
        table.insert(lines, "")
        table.insert(lines, T(_("In %1"), cleanEmoji(guild.name)))
        if member.nick and member.nick ~= "" then
            table.insert(lines, T(_("Nickname: %1"), cleanEmoji(member.nick)))
        end
        if member.joined_at then
            local ChatView = require("discord_chatview")
            table.insert(lines, T(_("Joined: %1"), date(ChatView.parseTimestamp(member.joined_at))))
        end
        local names = {}
        local by_id = {}
        for __, role in ipairs(guild.roles or {}) do by_id[role.id] = role.name end
        for __, rid in ipairs(member.roles or {}) do
            if by_id[rid] then table.insert(names, cleanEmoji(by_id[rid])) end
        end
        if #names > 0 then
            table.insert(lines, T(_("Roles: %1"), table.concat(names, ", ")))
        end
    end
    local mutual = data and data.mutual_guilds or {}
    if #mutual > 0 then
        local names = {}
        for __, mg in ipairs(mutual) do
            local g = Gateway.guilds[mg.id]
            table.insert(names, cleanEmoji(g and g.name or mg.id))
        end
        table.insert(lines, "")
        table.insert(lines, T(_("Servers in common (%1)"), #mutual))
        table.insert(lines, table.concat(names, ", "))
    end
    return table.concat(lines, "\n")
end

--- Shows the profile of `user` ({ id, username, … }). guild_id adds server details.
function Profile.show(plugin, user, guild_id)
    plugin:withLoading(_("Loading profile…"), function()
        local ok, data = plugin.api:getProfile(user.id, guild_id)
        if not ok then
            -- Still show what we know locally
            UIManager:show(InfoMessage:new{ text = _("Could not load the full profile: ") .. tostring(data), timeout = 2 })
        end
        local TextViewer = require("ui/widget/textviewer")
        local viewer
        local me = Gateway.me and Gateway.me.id
        viewer = TextViewer:new{
            title = _("Profile"),
            text = Profile.format(user, ok and data or nil, guild_id),
            buttons_table = {{
                {
                    text = _("Direct message"),
                    enabled = user.id ~= me,
                    callback = function()
                        UIManager:close(viewer)
                        plugin:openDMWith(user)
                    end,
                },
                { text = _("Close"), callback = function() UIManager:close(viewer) end },
            }},
        }
        UIManager:show(viewer)
    end)
end

return Profile
