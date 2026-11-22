--[[--
Moderation basics for people who run servers: delete other people's messages,
time out or kick a member, and read the audit log. Everything is shown only when
the account has the permission in that server.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DiscordAPI = require("discord_api")
local Gateway = require("discord_gateway")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local _ = require("discord_i18n")
local T = require("ffi/util").template

local Mod = {}

local BIT_KICK, BIT_AUDIT, BIT_MANAGE_MESSAGES, BIT_MODERATE = 1, 7, 13, 40

local function myRoles(guild)
    local gw = Gateway.guilds[guild.id]
    return gw and gw.my_roles or guild.my_roles or {}
end

--- What the account may do in the chat's server: { delete, timeout, kick, audit }.
function Mod.can(view)
    local guild = view.guild
    if not guild then return {} end
    local api, roles = view.api, myRoles(guild)
    local function perm(bit) return api:hasGuildPerm(guild, roles, bit) end
    return {
        delete = perm(BIT_MANAGE_MESSAGES),
        timeout = perm(BIT_MODERATE),
        kick = perm(BIT_KICK),
        audit = perm(BIT_AUDIT),
    }
end

local DURATIONS = {
    { _("60 seconds"), 60 },
    { _("5 minutes"), 300 },
    { _("1 hour"), 3600 },
    { _("1 day"), 86400 },
    { _("1 week"), 604800 },
}

local function timeoutDialog(view, user)
    local dialog
    local buttons = {}
    for __, d in ipairs(DURATIONS) do
        table.insert(buttons, {{
            text = d[1],
            callback = function()
                UIManager:close(dialog)
                local ok, err = view.api:timeoutMember(view.guild.id, user.id, os.time() + d[2])
                UIManager:show(ok and Notification:new{ text = T(_("%1 timed out for %2"), view:authorName(user), d[1]) }
                    or InfoMessage:new{ text = _("Could not time out: ") .. tostring(err) })
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Remove timeout"),
        callback = function()
            UIManager:close(dialog)
            local ok, err = view.api:timeoutMember(view.guild.id, user.id, nil)
            UIManager:show(ok and Notification:new{ text = _("Timeout removed") }
                or InfoMessage:new{ text = tostring(err) })
        end,
    }})
    dialog = ButtonDialog:new{ title = T(_("Time out %1"), view:authorName(user)), buttons = buttons }
    UIManager:show(dialog)
end

--- Moderation actions on a message and its author.
function Mod.messageDialog(view, msg)
    local can = Mod.can(view)
    local me = Gateway.me and Gateway.me.id
    local author = msg.author
    local own = author and author.id == me
    local dialog
    local buttons = {}
    if can.delete and not own then
        table.insert(buttons, {{
            text = _("Delete this message"),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this message as a moderator?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        local ok, err = view.api:deleteMessage(view.channel.id, msg.id)
                        if ok then
                            view:removeMessage(msg.id)
                            view:redraw()
                        else
                            UIManager:show(InfoMessage:new{ text = tostring(err) })
                        end
                    end,
                })
            end,
        }})
    end
    if author and not own then
        if can.timeout then
            table.insert(buttons, {{
                text = T(_("Time out %1…"), view:authorName(author)),
                callback = function() UIManager:close(dialog) timeoutDialog(view, author) end,
            }})
        end
        if can.kick then
            table.insert(buttons, {{
                text = T(_("Kick %1"), view:authorName(author)),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Kick %1 from the server?"), view:authorName(author)),
                        ok_text = _("Kick"),
                        ok_callback = function()
                            local ok, err = view.api:kickMember(view.guild.id, author.id)
                            UIManager:show(ok and Notification:new{ text = _("Member kicked") }
                                or InfoMessage:new{ text = _("Could not kick: ") .. tostring(err) })
                        end,
                    })
                end,
            }})
        end
    end
    table.insert(buttons, {{ text = _("Close"), callback = function() UIManager:close(dialog) end }})
    dialog = ButtonDialog:new{ title = _("Moderation"), buttons = buttons }
    UIManager:show(dialog)
end

--- True if anything can be done to this message (used to show the button).
function Mod.available(view, msg)
    local can = Mod.can(view)
    local me = Gateway.me and Gateway.me.id
    if not msg.author or msg.author.id == me then return false end
    return can.delete or can.timeout or can.kick
end

local ACTIONS = {
    [1] = _("updated the server"),
    [11] = _("created a channel"), [12] = _("edited a channel"), [13] = _("deleted a channel"),
    [20] = _("kicked"), [21] = _("pruned members"), [22] = _("banned"), [23] = _("unbanned"),
    [24] = _("updated a member"), [25] = _("changed roles of"),
    [30] = _("created a role"), [31] = _("edited a role"), [32] = _("deleted a role"),
    [40] = _("created an invite"), [42] = _("deleted an invite"),
    [72] = _("deleted a message of"), [73] = _("deleted messages of"),
    [74] = _("pinned a message"), [75] = _("unpinned a message"),
}

--- Time of a snowflake id, as "dd/mm HH:MM".
local function snowflakeTime(id)
    local ms = (tonumber(id) or 0) / 4194304 + 1420070400000
    return os.date("%d/%m %H:%M", math.floor(ms / 1000))
end

--- Read-only list of the latest audit log entries.
function Mod.auditLog(view)
    view.plugin:withLoading(_("Loading audit log…"), function()
        local ok, data = view.api:getAuditLog(view.guild.id, 50)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Could not load the audit log: ") .. tostring(data) })
            return
        end
        local names = {}
        for __, u in ipairs(data.users or {}) do
            names[u.id] = u.global_name or u.username or "?"
        end
        local items = {}
        for __, e in ipairs(data.audit_log_entries or {}) do
            local who = names[e.user_id] or "?"
            local what = ACTIONS[e.action_type] or T(_("action %1"), e.action_type)
            local target = e.target_id and names[e.target_id]
            local text = who .. " " .. what .. (target and (" " .. target) or "")
            if e.reason and e.reason ~= "" then text = text .. " (" .. e.reason .. ")" end
            table.insert(items, { text = DiscordAPI.cleanEmoji(text), mandatory = snowflakeTime(e.id) })
        end
        if #items == 0 then
            table.insert(items, { text = _("The audit log is empty."), select_enabled = false })
        end
        local menu
        menu = Menu:new{
            title = _("Audit log"),
            item_table = items,
            is_borderless = true,
            is_popout = false,
            covers_fullscreen = true,
            items_max_lines = 3,
            close_callback = function() UIManager:close(menu) end,
        }
        UIManager:show(menu)
    end)
end

return Mod
