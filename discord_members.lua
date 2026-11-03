--[[--
Member list of a server (or the people of a group chat) with their status.
]]

local DiscordAPI = require("discord_api")
local Gateway = require("discord_gateway")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("discord_i18n")
local T = require("ffi/util").template

local cleanEmoji = DiscordAPI.cleanEmoji

local Members = {}

local STATUS_LABEL = {
    online = _("online"), idle = _("idle"), dnd = _("do not disturb"),
    offline = _("offline"), invisible = _("offline"),
}

--- Turns the gateway list into menu items. Group headers are not selectable.
function Members.buildItems(guild, list, on_pick)
    local roles = {}
    for __, role in ipairs(guild.roles or {}) do roles[role.id] = role.name end
    local items = {}
    for i = 1, Gateway.maxIndex(list.items) do
        local item = list.items[i]
        if item and item.group then
            local g = item.group
            local label = g.id == "online" and _("Online") or g.id == "offline" and _("Offline")
                or cleanEmoji(roles[g.id] or g.id)
            table.insert(items, { text = "— " .. label .. " (" .. tostring(g.count or "?") .. ") —", bold = true, select_enabled = false })
        elseif item and item.member and item.member.user then
            local m = item.member
            local status = m.presence and m.presence.status or "offline"
            local user = m.user
            table.insert(items, {
                text = cleanEmoji(m.nick or user.global_name or user.username or "?") .. (user.bot and " [bot]" or ""),
                mandatory = STATUS_LABEL[status] or status,
                callback = function() on_pick(user) end,
            })
        end
    end
    if #items == 0 then
        table.insert(items, { text = _("No members to show."), select_enabled = false })
    end
    return items
end

--- Opens the member list of the chat. `view` is the ChatView.
function Members.show(plugin, view)
    local on_pick = function(user) require("discord_profile").show(plugin, user, view.guild and view.guild.id) end
    local title = T(_("Members of %1"), cleanEmoji(view.title or ""))
    if not view.guild then
        -- Group chat: just the recipients (no presence information)
        local items = {}
        for __, user in ipairs(view.channel.recipients or {}) do
            table.insert(items, { text = cleanEmoji(user.global_name or user.username or "?"), callback = function() on_pick(user) end })
        end
        if #items == 0 then table.insert(items, { text = _("No members to show."), select_enabled = false }) end
        local menu
        menu = Menu:new{ title = title, item_table = items, is_borderless = true, is_popout = false, covers_fullscreen = true }
        menu.close_callback = function() UIManager:close(menu) end
        UIManager:show(menu)
        return
    end
    if not Gateway:isReady() then
        UIManager:show(InfoMessage:new{ text = _("The member list needs a live connection.") })
        return
    end
    plugin:withLoading(_("Loading members…"), function()
        Gateway:requestMemberList(view.guild.id, view.channel.id)
        local deadline = os.time() + 8
        local list = Gateway.member_lists[view.guild.id]
        while list.stamp == 0 and os.time() < deadline do
            Gateway:tick()
            require("socket").sleep(0.2)
        end
        if list.stamp == 0 then
            UIManager:show(InfoMessage:new{ text = _("The server did not send its member list.") })
            return
        end
        local guild = Gateway.guilds[view.guild.id] or view.guild
        local menu
        menu = Menu:new{
            title = title .. (list.online and (" · " .. T(_("%1 online"), list.online)) or ""),
            item_table = Members.buildItems(guild, list, on_pick),
            is_borderless = true, is_popout = false, covers_fullscreen = true,
        }
        menu.close_callback = function() UIManager:close(menu) end
        UIManager:show(menu)
    end)
end

return Members
