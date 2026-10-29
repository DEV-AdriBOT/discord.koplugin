--[[--
Lightweight Discord client: login, servers, text channels and direct messages.
No images, voice or video.

@module koplugin.discord
]]

local DataStorage = require("datastorage")
local DiscordAPI = require("discord_api")
local ChatView = require("discord_chatview")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local cleanEmoji = DiscordAPI.cleanEmoji

local TOKEN_FILE = "/mnt/us/discord_token.txt"

local CHANNEL_TEXT = 0
local CHANNEL_DM = 1
local CHANNEL_GROUP_DM = 3
local CHANNEL_CATEGORY = 4
local CHANNEL_ANNOUNCEMENT = 5

local Discord = WidgetContainer:extend{
    name = "discord",
    is_doc_only = false,
}

function Discord:init()
    self.settings_file = LuaSettings:open(DataStorage:getSettingsDir() .. "/discord.lua")
    self.settings = self.settings_file.data
    self.api = DiscordAPI:new{
        token = self.settings.token,
        user = self.settings.user,
    }
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Discord:onDispatcherRegisterActions()
    Dispatcher:registerAction("discord_open", {
        category = "none",
        event = "OpenDiscord",
        title = _("Open Discord"),
        general = true,
    })
    Dispatcher:registerAction("discord_dms", {
        category = "none",
        event = "OpenDiscordDMs",
        title = _("Discord: direct messages"),
        general = true,
    })
end

function Discord:saveSettings()
    self.settings_file:flush()
end

function Discord:isLoggedIn()
    return self.settings.token ~= nil
end

-- Main menu

function Discord:addToMainMenu(menu_items)
    menu_items.discord = {
        text = _("Discord"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            if self:isLoggedIn() then
                return self:getLoggedInMenu()
            end
            return self:getLoginMenu()
        end,
    }
end

function Discord:getLoginMenu()
    return {
        {
            text = _("Log in with email and password"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:loginWithPassword(touchmenu_instance)
            end,
        },
        {
            text = _("Log in with token"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:loginWithTokenDialog(touchmenu_instance)
            end,
        },
        {
            text = T(_("Load token from %1"), TOKEN_FILE),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:loginWithTokenFile(touchmenu_instance)
            end,
        },
    }
end

local function radioItem(self, label, key, value, default)
    return {
        text = label,
        radio = true,
        checked_func = function()
            local cur = self.settings[key]
            if cur == nil then cur = default end
            return cur == value
        end,
        callback = function()
            self.settings[key] = value
            self:saveSettings()
        end,
    }
end

function Discord:getLoggedInMenu()
    local user = self.settings.user or {}
    return {
        {
            text = _("Open Discord"),
            callback = function() self:onOpenDiscord() end,
        },
        {
            text = _("Direct messages"),
            callback = function() self:onOpenDiscordDMs() end,
        },
        {
            text = _("Settings"),
            separator = true,
            sub_item_table = {
                {
                    text = _("Check for new messages"),
                    sub_item_table = {
                        radioItem(self, _("Off"), "poll_interval", 0, 15),
                        radioItem(self, _("Every 10 seconds"), "poll_interval", 10, 15),
                        radioItem(self, _("Every 15 seconds"), "poll_interval", 15, 15),
                        radioItem(self, _("Every 30 seconds"), "poll_interval", 30, 15),
                        radioItem(self, _("Every minute"), "poll_interval", 60, 15),
                    },
                },
                {
                    text = _("Messages per load"),
                    sub_item_table = {
                        radioItem(self, "25", "page_size", 25, 50),
                        radioItem(self, "50", "page_size", 50, 50),
                        radioItem(self, "100", "page_size", 100, 50),
                    },
                },
                {
                    text = _("Mark channels as read when opened"),
                    checked_func = function() return self.settings.mark_read ~= false end,
                    callback = function()
                        self.settings.mark_read = self.settings.mark_read == false
                        self:saveSettings()
                    end,
                },
                {
                    text = _("Show channels without access"),
                    checked_func = function() return self.settings.show_hidden == true end,
                    callback = function()
                        self.settings.show_hidden = not self.settings.show_hidden
                        self:saveSettings()
                    end,
                },
            },
        },
        {
            text = T(_("Log out (%1)"), user.global_name or user.username or "?"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Log out of Discord on this device?"),
                    ok_text = _("Log out"),
                    ok_callback = function()
                        self.settings.token = nil
                        self.settings.user = nil
                        self.api.token = nil
                        self.api.user = nil
                        self:saveSettings()
                        touchmenu_instance.item_table = self:getLoginMenu()
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
    }
end

-- Helpers

--- Runs fn once online, with a "loading" message shown while it blocks.
function Discord:withLoading(text, fn)
    NetworkMgr:runWhenOnline(function()
        local msg = InfoMessage:new{ text = text or _("Loading…") }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local ok, err = pcall(fn)
        UIManager:close(msg)
        if not ok then
            logger.err("Discord: error", err)
            UIManager:show(InfoMessage:new{ text = _("Error: ") .. tostring(err) })
        end
    end)
end

local function errorText(prefix, err, code)
    if code == 401 then
        return prefix .. _("session expired or invalid token. Please log in again.")
    end
    return prefix .. tostring(err)
end

function Discord:showList(title, items, subtitle)
    local menu
    menu = Menu:new{
        title = title,
        subtitle = subtitle,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.search",
    }
    menu.close_callback = function() UIManager:close(menu) end
    menu.onLeftButtonTap = function()
        local dialog
        dialog = InputDialog:new{
            title = _("Search"),
            input = menu.search_query or "",
            buttons = {
                {
                    {
                        text = _("Show all"),
                        callback = function()
                            UIManager:close(dialog)
                            menu.search_query = nil
                            menu:switchItemTable(title, items)
                        end,
                    },
                    {
                        text = _("Search"),
                        is_enter_default = true,
                        callback = function()
                            local query = util.trim(dialog:getInputText()):lower()
                            UIManager:close(dialog)
                            menu.search_query = query
                            local found = {}
                            for __, item in ipairs(items) do
                                local haystack = (item.search or item.text or ""):lower()
                                if item.select_enabled ~= false and haystack:find(query, 1, true) then
                                    table.insert(found, item)
                                end
                            end
                            if #found == 0 then
                                table.insert(found, { text = _("No results"), select_enabled = false })
                            end
                            menu:switchItemTable(T(_("%1 — «%2»"), title, query), found)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end
    -- Keep the menu open when an item is chosen, so closing a chat returns here
    menu.onMenuSelect = function(_menu, item)
        if item.select_enabled == false then return true end
        if item.callback then item.callback() end
        return true
    end
    UIManager:show(menu)
    return menu
end

-- Login

function Discord:finishLogin(token, touchmenu_instance)
    self.api.token = token
    local ok, me, code = self.api:fetchMe()
    if not ok then
        self.api.token = self.settings.token
        UIManager:show(InfoMessage:new{ text = errorText(_("Login failed: "), me, code) })
        return
    end
    self.settings.token = token
    self.settings.user = { id = me.id, username = me.username, global_name = me.global_name }
    self.api.user = self.settings.user
    self:saveSettings()
    UIManager:show(InfoMessage:new{
        text = T(_("Logged in as %1"), me.global_name or me.username),
        timeout = 3,
    })
    if touchmenu_instance then
        touchmenu_instance.item_table = self:getLoggedInMenu()
        touchmenu_instance:updateItems()
    end
end

function Discord:loginWithTokenDialog(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Discord token"),
        description = _("Paste or type your user token."),
        input = "",
        text_type = "password",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Log in"),
                    is_enter_default = true,
                    callback = function()
                        local token = util.trim(dialog:getInputText()):gsub('^"(.*)"$', "%1")
                        UIManager:close(dialog)
                        if token == "" then return end
                        self:withLoading(_("Checking token…"), function()
                            self:finishLogin(token, touchmenu_instance)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Discord:loginWithTokenFile(touchmenu_instance)
    local f = io.open(TOKEN_FILE, "r")
    if not f then
        UIManager:show(InfoMessage:new{
            text = T(_("%1 not found.\n\nCreate that file containing your token (over USB or SSH) and try again."), TOKEN_FILE),
        })
        return
    end
    local token = util.trim(f:read("*a") or ""):gsub('^"(.*)"$', "%1")
    f:close()
    if token == "" then
        UIManager:show(InfoMessage:new{ text = _("The token file is empty.") })
        return
    end
    self:withLoading(_("Checking token…"), function()
        self:finishLogin(token, touchmenu_instance)
        if self.settings.token == token then
            os.remove(TOKEN_FILE)
        end
    end)
end

function Discord:askMFA(ticket, touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Two-factor authentication"),
        description = _("Enter the 6-digit code from your authenticator app."),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Verify"),
                    is_enter_default = true,
                    callback = function()
                        local code = util.trim(dialog:getInputText()):gsub("%s", "")
                        UIManager:close(dialog)
                        self:withLoading(_("Verifying…"), function()
                            local ok, token = self.api:loginMFA(ticket, code)
                            if ok then
                                self:finishLogin(token, touchmenu_instance)
                            else
                                UIManager:show(InfoMessage:new{ text = _("Error: ") .. tostring(token) })
                            end
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Discord:loginWithPassword(touchmenu_instance)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Log in to Discord"),
        fields = {
            { text = self.settings.last_email or "", hint = _("Email or phone") },
            { text = "", hint = _("Password"), text_type = "password" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Log in"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local email, password = util.trim(fields[1]), fields[2]
                        if email == "" or password == "" then return end
                        UIManager:close(dialog)
                        self.settings.last_email = email
                        self:saveSettings()
                        self:withLoading(_("Logging in…"), function()
                            local ok, token, ticket = self.api:login(email, password)
                            if not ok then
                                UIManager:show(InfoMessage:new{ text = _("Login failed: ") .. tostring(token) })
                            elseif ticket then
                                self:askMFA(ticket, touchmenu_instance)
                            else
                                self:finishLogin(token, touchmenu_instance)
                            end
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Navigation

function Discord:requireLogin()
    if self:isLoggedIn() then return true end
    UIManager:show(InfoMessage:new{
        text = _("Log in first from Tools → Discord."),
    })
    return false
end

function Discord:onOpenDiscord()
    if not self:requireLogin() then return true end
    self:withLoading(_("Loading servers…"), function()
        local ok, guilds, code = self.api:getGuilds()
        if not ok then
            UIManager:show(InfoMessage:new{ text = errorText(_("Could not load servers: "), guilds, code) })
            return
        end
        table.sort(guilds, function(a, b) return a.name:lower() < b.name:lower() end)
        local items = {
            {
                text = _("Direct messages"),
                bold = true,
                callback = function() self:onOpenDiscordDMs() end,
            },
        }
        for __, g in ipairs(guilds) do
            table.insert(items, {
                text = cleanEmoji(g.name),
                callback = function() self:openGuild(g) end,
            })
        end
        local user = self.settings.user or {}
        self:showList(_("Discord"), items, user.global_name or user.username)
    end)
    return true
end

local function dmName(ch)
    if ch.name and ch.name ~= "" then return cleanEmoji(ch.name) end
    local names = {}
    for __, r in ipairs(ch.recipients or {}) do
        table.insert(names, r.global_name or r.username)
    end
    if #names == 0 then return _("(unnamed)") end
    return cleanEmoji(table.concat(names, ", "))
end

function Discord:openChannel(channel, guild, title, subtitle, channel_names, can_send)
    local view = ChatView:new{
        api = self.api,
        channel = channel,
        guild = guild,
        title = title,
        subtitle = subtitle,
        channel_names = channel_names,
        settings = self.settings,
        can_send = can_send ~= false,
        close_callback = function() self:saveSettings() end,
        open_dm_callback = function(user) self:openDMWith(user) end,
    }
    self:withLoading(_("Loading messages…"), function()
        if view:load() then
            UIManager:show(view)
        end
    end)
end

function Discord:openDMWith(user)
    self:withLoading(nil, function()
        local ok, ch = self.api:openDM(user.id)
        if not ok then
            UIManager:show(InfoMessage:new{ text = tostring(ch) })
            return
        end
        self:openChannel(ch, nil, "@" .. cleanEmoji(user.global_name or user.username), _("Direct message"))
    end)
end

function Discord:onOpenDiscordDMs()
    if not self:requireLogin() then return true end
    self:withLoading(_("Loading direct messages…"), function()
        local ok, channels, code = self.api:getDMChannels()
        if not ok then
            UIManager:show(InfoMessage:new{ text = errorText(_("Could not load direct messages: "), channels, code) })
            return
        end
        table.sort(channels, function(a, b)
            local la, lb = a.last_message_id or a.id, b.last_message_id or b.id
            return DiscordAPI.idLess(lb, la)
        end)
        local items = {}
        for __, ch in ipairs(channels) do
            if ch.type == CHANNEL_DM or ch.type == CHANNEL_GROUP_DM then
                local name = dmName(ch)
                local usernames = {}
                for __, r in ipairs(ch.recipients or {}) do
                    table.insert(usernames, r.username or "")
                end
                table.insert(items, {
                    search = name .. " " .. table.concat(usernames, " "),
                    text = (ch.type == CHANNEL_GROUP_DM and "" or "@") .. name,
                    mandatory = ch.type == CHANNEL_GROUP_DM and _("group") or nil,
                    callback = function()
                        self:openChannel(ch, nil, name,
                            ch.type == CHANNEL_GROUP_DM and _("Group") or _("Direct message"))
                    end,
                })
            end
        end
        if #items == 0 then
            table.insert(items, { text = _("You have no direct messages."), select_enabled = false })
        end
        self:showList(_("Direct messages"), items)
    end)
    return true
end

function Discord:openGuild(guild_summary)
    self:withLoading(_("Loading channels…"), function()
        local ok, channels, code = self.api:getGuildChannels(guild_summary.id)
        if not ok then
            UIManager:show(InfoMessage:new{ text = errorText(_("Could not load channels: "), channels, code) })
            return
        end
        -- Full guild (roles) and our member entry, to hide channels we cannot see
        local guild = guild_summary
        local perms_of
        local ok_g, full = self.api:getGuild(guild_summary.id)
        if ok_g then guild = full end
        local ok_m, member = self.api:getMyMember(guild_summary.id)
        if ok_g and ok_m then
            perms_of = self.api:permissionResolver(guild, member)
        end

        local channel_names = {}
        local categories = {}
        for __, ch in ipairs(channels) do
            channel_names[ch.id] = ch.name
            if ch.type == CHANNEL_CATEGORY then
                categories[ch.id] = { channel = ch, children = {} }
            end
        end
        local top = { channel = { position = -1 }, children = {} }
        for __, ch in ipairs(channels) do
            if ch.type == CHANNEL_TEXT or ch.type == CHANNEL_ANNOUNCEMENT then
                local perms = perms_of and perms_of(ch)
                local visible = not perms or DiscordAPI.hasPerm(perms, DiscordAPI.PERM_VIEW_CHANNEL)
                if visible or self.settings.show_hidden then
                    ch._can_send = not perms or DiscordAPI.hasPerm(perms, DiscordAPI.PERM_SEND_MESSAGES)
                    ch._hidden = not visible
                    local parent = ch.parent_id and categories[ch.parent_id] or top
                    table.insert(parent.children, ch)
                end
            end
        end
        local groups = { top }
        for __, cat in pairs(categories) do
            if #cat.children > 0 then table.insert(groups, cat) end
        end
        local by_position = function(a, b)
            local pa, pb = a.position or 0, b.position or 0
            if pa ~= pb then return pa < pb end
            return DiscordAPI.idLess(a.id or "0", b.id or "0")
        end
        table.sort(groups, function(a, b) return by_position(a.channel, b.channel) end)

        local items = {}
        for __, group in ipairs(groups) do
            table.sort(group.children, by_position)
            if group ~= top then
                table.insert(items, {
                    text = "— " .. util.trim(cleanEmoji(group.channel.name)):upper() .. " —",
                    bold = true,
                    select_enabled = false,
                })
            end
            for __, ch in ipairs(group.children) do
                local name = util.trim(cleanEmoji(ch.name))
                table.insert(items, {
                    text = "# " .. name,
                    mandatory = ch._hidden and _("no access") or (not ch._can_send and _("read-only"))
                        or (ch.type == CHANNEL_ANNOUNCEMENT and _("announcements")) or nil,
                    callback = function()
                        self:openChannel(ch, guild, "#" .. name, cleanEmoji(guild.name), channel_names, ch._can_send)
                    end,
                })
            end
        end
        if #items == 0 then
            table.insert(items, { text = _("No visible text channels."), select_enabled = false })
        end
        self:showList(cleanEmoji(guild.name), items)
    end)
end

return Discord
