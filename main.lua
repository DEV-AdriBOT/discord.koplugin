--[[--
Lightweight Discord client: servers, text channels, threads and direct messages.
No voice or video; images only on demand.

@module koplugin.discord
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local DiscordAPI = require("discord_api")
local ChatView = require("discord_chatview")
local Dispatcher = require("dispatcher")
local Gateway = require("discord_gateway")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("discord_i18n")
local T = require("ffi/util").template

local cleanEmoji = DiscordAPI.cleanEmoji
--- Server, channel and category names: emoji are decoration there, drop them.
local function cleanName(name)
    local cleaned = cleanEmoji(name or "", true)
    if cleaned == "" then cleaned = cleanEmoji(name or "?") end
    return cleaned
end
local idLess = DiscordAPI.idLess

local TOKEN_FILE = "/mnt/us/discord_token.txt"

local CHANNEL_TEXT = 0
local CHANNEL_DM = 1
local CHANNEL_GROUP_DM = 3
local CHANNEL_CATEGORY = 4
local CHANNEL_ANNOUNCEMENT = 5
local CHANNEL_FORUM = 15
local CHANNEL_MEDIA = 16
local THREAD_TYPES = { [10] = true, [11] = true, [12] = true }

local MAX_RECENTS = 10
local MAX_NOTIFICATIONS = 30

-- Shared by every plugin instance: KOReader creates a new one each time it
-- switches between the file manager and the reader.
local shared = {
    settings_file = nil,
    api = nil,
    lists = {},          -- open list menus
    views = {},          -- open chat views
    notifications = {},  -- recent notifications, newest first
    listeners_set = false,
    battery_warned = false,
}

local Discord = WidgetContainer:extend{
    name = "discord",
    is_doc_only = false,
    DEFAULT_QUICK_REPLIES = { "OK", "Thanks!", "On my way", "lol", "Talk later", "👍" },
}

function Discord:init()
    if not shared.settings_file then
        shared.settings_file = LuaSettings:open(DataStorage:getSettingsDir() .. "/discord.lua")
        shared.api = DiscordAPI:new{
            token = shared.settings_file.data.token,
            user = shared.settings_file.data.user,
        }
    end
    self.settings = shared.settings_file.data
    self.api = shared.api
    Gateway.status = self.settings.status
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self:addToHighlightDialog()
    end
    self:setupGatewayListeners()
    if self:wantsBackgroundConnection() and Gateway.state == "disconnected" then
        -- Not during startup: connecting and loading READY takes a few seconds
        UIManager:scheduleIn(15, function() self:updateConnection() end)
    end
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
    Dispatcher:registerAction("discord_last_chat", {
        category = "none",
        event = "OpenDiscordLastChat",
        title = _("Discord: open last chat"),
        general = true,
    })
end

function Discord:saveSettings()
    shared.settings_file:flush()
end

function Discord:isLoggedIn()
    return self.settings.token ~= nil
end

-- Battery saver

function Discord:isBatteryLow()
    local threshold = self.settings.battery_saver
    if threshold == nil then threshold = 20 end
    if threshold <= 0 or not Device:hasBattery() then return false end
    local powerd = Device:getPowerDevice()
    if powerd:isCharging() then return false end
    return powerd:getCapacity() < threshold
end

-- Real-time connection

function Discord:realtimeEnabled()
    return self:isLoggedIn() and self.settings.realtime ~= false
end

function Discord:wantsBackgroundConnection()
    return self:realtimeEnabled() and self.settings.background ~= false and not self:isBatteryLow()
end

--- Connects while Discord screens are open, and disconnects after if not wanted in background.
function Discord:updateConnection()
    if not self:realtimeEnabled() then
        Gateway:stop()
        return
    end
    local screens_open = #shared.lists > 0 or #shared.views > 0
    local sharing = shared.reading and self.settings.share_reading
    if self:wantsBackgroundConnection() or screens_open or sharing then
        Gateway:start(self.api)
    else
        Gateway:stop()
    end
end

function Discord:onNetworkConnected()
    if self:realtimeEnabled() then
        UIManager:scheduleIn(2, function() self:updateConnection() end)
    end
end

-- Reading activity

function Discord:readingActivity()
    local props = self.ui.doc_props or {}
    local title = props.display_title or props.title or _("a book")
    local activity = {
        name = "KOReader",
        type = 0,
        details = title:sub(1, 128),
        timestamps = { start = shared.reading_since * 1000 },
    }
    local parts = {}
    if props.authors and props.authors ~= "" then
        table.insert(parts, (props.authors:gsub("\n", ", ")))
    end
    local total = self.ui.document and self.ui.document:getPageCount()
    if self.current_page and total and total > 0 then
        table.insert(parts, math.floor(self.current_page / total * 100) .. " %")
    end
    if #parts > 0 then activity.state = table.concat(parts, " · "):sub(1, 128) end
    return activity
end

function Discord:updateActivity(force)
    if not (self.settings.share_reading and self:realtimeEnabled() and self.ui.document) then return end
    local activity = self:readingActivity()
    local now = os.time()
    if not force and self.last_activity_state == activity.state and now - (self.last_activity_time or 0) < 600 then
        return
    end
    -- Do not flood the gateway while turning pages
    if not force and now - (self.last_activity_time or 0) < 60 then return end
    self.last_activity_state = activity.state
    self.last_activity_time = now
    Gateway:setActivity(activity)
end

function Discord:onReaderReady()
    shared.reading = true
    shared.reading_since = os.time()
    local ok, page = pcall(function() return self.ui:getCurrentPage() end)
    if ok then self.current_page = page end
    if self.settings.share_reading then
        self:updateConnection()
        self:updateActivity(true)
    end
end

function Discord:onPageUpdate(pageno)
    self.current_page = pageno
    if self.settings.share_reading then self:updateActivity() end
end

function Discord:onCloseDocument()
    shared.reading = false
    if Gateway.activity then Gateway:setActivity(nil) end
end

function Discord:onFlushSettings()
    -- Also sent when KOReader exits or restarts: keep the session resumable
    Gateway:saveState()
end

function Discord:onSuspend()
    -- Keep the session so it can be resumed (cheaper than a new READY)
    Gateway:stop(true)
end

function Discord:onResume()
    shared.battery_warned = false
    -- Wi-Fi takes a moment to come back; NetworkConnected is not sent on every device
    for __, delay in ipairs({ 5, 20, 60 }) do
        UIManager:scheduleIn(delay, function()
            if Gateway.state == "disconnected" then self:updateConnection() end
        end)
    end
end

function Discord:checkBattery()
    if self:isBatteryLow() and self.settings.background ~= false and Gateway.want_connected
            and #shared.lists == 0 and #shared.views == 0 then
        Gateway:stop()
        if not shared.battery_warned then
            shared.battery_warned = true
            UIManager:show(Notification:new{ text = _("Discord: low battery, real-time connection paused") })
        end
    end
end

-- Notifications

function Discord:setupGatewayListeners()
    if shared.listeners_set then return end
    shared.listeners_set = true
    Gateway:on("MESSAGE_CREATE", function(d) self:maybeNotify(d) end)
    Gateway:on("auth_failed", function()
        UIManager:show(InfoMessage:new{ text = _("Discord rejected the saved session. Please log in again.") })
    end)
    local refresh = function() self:refreshLists() end
    for __, ev in ipairs({ "ready", "MESSAGE_CREATE", "MESSAGE_ACK", "CHANNEL_UNREAD_UPDATE",
            "RELATIONSHIP_ADD", "RELATIONSHIP_REMOVE", "USER_GUILD_SETTINGS_UPDATE" }) do
        Gateway:on(ev, refresh)
    end
    -- Battery check once a minute
    local function battery_tick()
        local ok, err = pcall(self.checkBattery, self)
        if not ok then logger.warn("Discord: battery check failed", err) end
        UIManager:scheduleIn(60, battery_tick)
    end
    UIManager:scheduleIn(60, battery_tick)
end

function Discord:channelLabel(channel_id)
    local ch = Gateway.channels[channel_id]
    if not ch then return "?" end
    if ch.type == CHANNEL_DM or ch.type == CHANNEL_GROUP_DM then
        return self:dmName(ch)
    end
    local guild = ch.guild_id and Gateway.guilds[ch.guild_id]
    return "#" .. cleanName(ch.name) .. (guild and (" · " .. cleanName(guild.name)) or "")
end

function Discord:maybeNotify(d)
    if not d.author or (Gateway.me and d.author.id == Gateway.me.id) then return end
    for __, view in ipairs(shared.views) do
        if view.channel.id == d.channel_id then return end
    end
    local ch = Gateway.channels[d.channel_id]
    if Gateway:isMuted(ch) then return end
    local is_dm = Gateway:isDM(d.channel_id) or not d.guild_id
    local wanted = (is_dm and self.settings.notify_dms ~= false)
        or (not is_dm and self.settings.notify_mentions ~= false and Gateway:mentionsMe(d))
    if not wanted then return end

    local author = cleanEmoji((d.member and d.member.nick) or d.author.global_name or d.author.username or "?")
    local content = d.content or ""
    if content == "" and d.attachments and #d.attachments > 0 then content = _("[file]") end
    content = cleanEmoji(content:gsub("<@!?%d+>", "@"):gsub("<@&%d+>", "@role"):gsub("<#%d+>", "#channel")
        :gsub("<a?:([%w_]+):%d+>", ":%1:"):gsub("%s+", " "))
    if #content > 120 then content = content:sub(1, 120) .. "…" end
    local where = is_dm and "" or (" — " .. self:channelLabel(d.channel_id))
    table.insert(shared.notifications, 1, {
        channel_id = d.channel_id,
        guild_id = d.guild_id,
        message_id = d.id,
        text = author .. where .. ": " .. content,
        time = os.time(),
    })
    while #shared.notifications > MAX_NOTIFICATIONS do table.remove(shared.notifications) end
    UIManager:show(Notification:new{
        text = "Discord · " .. author .. where .. ": " .. content,
        timeout = 5,
    })
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

local function radioItem(self, label, key, value, default, on_change)
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
            if on_change then on_change() end
        end,
    }
end

local function toggleItem(self, label, key, default, on_change)
    return {
        text = label,
        checked_func = function()
            local cur = self.settings[key]
            if cur == nil then cur = default end
            return cur
        end,
        callback = function()
            local cur = self.settings[key]
            if cur == nil then cur = default end
            self.settings[key] = not cur
            self:saveSettings()
            if on_change then on_change() end
        end,
    }
end

function Discord:connectionStatus()
    if not self:realtimeEnabled() then return _("off") end
    if Gateway.state == "ready" then return _("connected") end
    if Gateway.state == "connecting" then return _("connecting…") end
    return _("disconnected")
end

function Discord:getSettingsMenu()
    local update = function() self:updateConnection() end
    return {
        {
            text_func = function() return T(_("Real-time connection: %1"), self:connectionStatus()) end,
            checked_func = function() return self.settings.realtime ~= false end,
            callback = function()
                self.settings.realtime = self.settings.realtime == false
                self:saveSettings()
                update()
            end,
        },
        toggleItem(self, _("Stay connected in background (notifications)"), "background", true, update),
        toggleItem(self, _("Notify direct messages"), "notify_dms", true),
        toggleItem(self, _("Show the book I'm reading as my Discord activity"), "share_reading", false, function()
            if self.settings.share_reading then
                if shared.reading then
                    self:updateConnection()
                    self:updateActivity(true)
                end
            elseif Gateway.activity then
                Gateway:setActivity(nil)
            end
        end),
        toggleItem(self, _("Notify mentions"), "notify_mentions", true),
        {
            text = _("Battery saver"),
            help_text = _("Below this battery level the background connection is paused and polling slows down."),
            sub_item_table = {
                radioItem(self, _("Off"), "battery_saver", 0, 20, update),
                radioItem(self, "10 %", "battery_saver", 10, 20, update),
                radioItem(self, "20 %", "battery_saver", 20, 20, update),
                radioItem(self, "30 %", "battery_saver", 30, 20, update),
            },
            separator = true,
        },
        {
            text = _("Check for new messages without real-time connection"),
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
            text = _("Messages in \"Open as document\""),
            sub_item_table = {
                radioItem(self, "200", "doc_messages", 200, 300),
                radioItem(self, "300", "doc_messages", 300, 300),
                radioItem(self, "500", "doc_messages", 500, 300),
                radioItem(self, "1000", "doc_messages", 1000, 300),
            },
            separator = true,
        },
        toggleItem(self, _("Compact layout"), "compact", false),
        {
            text = _("Full screen refresh in chats"),
            help_text = _("Flash the screen every few page turns to remove e-ink ghosting."),
            sub_item_table = {
                radioItem(self, _("Never"), "full_refresh_pages", 0, 6),
                radioItem(self, _("Every 3 pages"), "full_refresh_pages", 3, 6),
                radioItem(self, _("Every 6 pages"), "full_refresh_pages", 6, 6),
                radioItem(self, _("Every 12 pages"), "full_refresh_pages", 12, 6),
            },
        },
        toggleItem(self, _("Mark channels as read when opened"), "mark_read", true),
        toggleItem(self, _("Show channels without access"), "show_hidden", false),
        {
            text = _("Quick replies"),
            sub_item_table_func = function() return self:getQuickRepliesMenu() end,
        },
        {
            text_func = function()
                return T(_("Hidden servers (%1)"), util.tableSize(self.settings.hidden_guilds or {}))
            end,
            callback = function() self:showHiddenGuilds() end,
        },
    }
end

function Discord:getQuickRepliesMenu()
    local items = {
        {
            text = _("Add quick reply…"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local dialog
                dialog = InputDialog:new{
                    title = _("New quick reply"),
                    buttons = {{
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                        {
                            text = _("Add"),
                            is_enter_default = true,
                            callback = function()
                                local text = util.trim(dialog:getInputText())
                                UIManager:close(dialog)
                                if text == "" then return end
                                self.settings.quick_replies = self.settings.quick_replies
                                    or util.tableDeepCopy(self.DEFAULT_QUICK_REPLIES)
                                table.insert(self.settings.quick_replies, text)
                                self:saveSettings()
                                touchmenu_instance.item_table = self:getQuickRepliesMenu()
                                touchmenu_instance:updateItems()
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
            separator = true,
        },
    }
    for i, reply in ipairs(self.settings.quick_replies or self.DEFAULT_QUICK_REPLIES) do
        table.insert(items, {
            text = cleanEmoji(reply),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove quick reply \"%1\"?"), cleanEmoji(reply)),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        self.settings.quick_replies = self.settings.quick_replies
                            or util.tableDeepCopy(self.DEFAULT_QUICK_REPLIES)
                        table.remove(self.settings.quick_replies, i)
                        self:saveSettings()
                        touchmenu_instance.item_table = self:getQuickRepliesMenu()
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        })
    end
    return items
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
            text = _("Open last chat"),
            enabled_func = function() return self.settings.recents and #self.settings.recents > 0 end,
            callback = function() self:onOpenDiscordLastChat() end,
        },
        {
            text_func = function() return T(_("Recent notifications (%1)"), #shared.notifications) end,
            enabled_func = function() return #shared.notifications > 0 end,
            callback = function() self:showNotifications() end,
        },
        {
            text = _("Mentions"),
            callback = function() self:showMentions() end,
        },
        {
            text = _("Friends"),
            callback = function() self:showFriends() end,
        },
        {
            text = _("Offline chats"),
            callback = function() self:showOfflineChats() end,
        },
        {
            text_func = function() return T(_("Status: %1"), self:statusLabel(self.settings.status)) end,
            sub_item_table = {
                self:statusItem("online"),
                self:statusItem("idle"),
                self:statusItem("dnd"),
                self:statusItem("invisible"),
            },
        },
        {
            text = _("Settings"),
            separator = true,
            sub_item_table_func = function() return self:getSettingsMenu() end,
        },
        {
            text = T(_("Log out (%1)"), user.global_name or user.username or "?"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new{
                    text = _("Log out of Discord on this device?"),
                    ok_text = _("Log out"),
                    ok_callback = function()
                        Gateway:stop()
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

-- Status

local STATUS_LABELS = {
    online = _("Online"),
    idle = _("Idle"),
    dnd = _("Do not disturb"),
    invisible = _("Invisible"),
}

function Discord:statusLabel(status)
    return STATUS_LABELS[status] or _("unchanged")
end

function Discord:statusItem(status)
    return {
        text = STATUS_LABELS[status],
        radio = true,
        checked_func = function() return self.settings.status == status end,
        callback = function()
            self.settings.status = status
            self:saveSettings()
            Gateway:setStatus(status)
            self:withLoading(nil, function()
                local ok, err = self.api:setStatus(status)
                if not ok then
                    UIManager:show(InfoMessage:new{ text = _("Could not change the status: ") .. tostring(err) })
                end
            end)
        end,
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

local function listSignature(items)
    local parts = {}
    for i, item in ipairs(items) do
        parts[i] = (item.text or "") .. "\0" .. tostring(item.bold) .. "\0" .. (item.mandatory or "")
    end
    return table.concat(parts, "\1")
end

local function errorText(prefix, err, code)
    if code == 401 then
        return prefix .. _("session expired or invalid token. Please log in again.")
    end
    return prefix .. tostring(err)
end

--- Waits (a few seconds at most) for the gateway to be ready, so lists can use its state.
-- Returns at once when the state cached on disk is available; lists refresh when READY lands.
function Discord:waitForGateway()
    if not self:realtimeEnabled() then return false end
    Gateway:start(self.api)
    if Gateway:hasState() then return true end
    if Gateway.state ~= "connecting" then return false end
    local deadline = os.time() + 15
    while Gateway.state == "connecting" and os.time() < deadline do
        Gateway:tick()
        if Gateway:isReady() then break end
        require("socket").sleep(0.2)
    end
    return Gateway:isReady()
end

--- Shows a list whose items come from items_func, rebuilt when unread state changes.
function Discord:showList(title, items_func, subtitle, on_hold)
    local menu
    menu = Menu:new{
        title = title,
        subtitle = subtitle,
        item_table = items_func(),
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.search",
    }
    menu.items_func = items_func
    menu.list_title = title
    menu.signature = listSignature(menu.item_table)
    menu.close_callback = function() UIManager:close(menu) end
    menu.onCloseWidget = function(this)
        Menu.onCloseWidget(this)
        for i, m in ipairs(shared.lists) do
            if m == this then table.remove(shared.lists, i) break end
        end
        UIManager:nextTick(function()
            self:refreshStaleLists()
            self:updateConnection()
        end)
    end
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
                            self:rebuildList(menu, true)
                        end,
                    },
                    {
                        text = _("Search"),
                        is_enter_default = true,
                        callback = function()
                            local query = util.trim(dialog:getInputText()):lower()
                            UIManager:close(dialog)
                            menu.search_query = query ~= "" and query or nil
                            self:rebuildList(menu, true)
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
    menu.onMenuHold = function(_menu, item)
        if item.hold_callback then
            item.hold_callback()
        elseif on_hold then
            on_hold(item)
        end
        return true
    end
    table.insert(shared.lists, menu)
    UIManager:show(menu)
    return menu
end

--- Rebuilds a list's items; unless forced, skips the repaint when nothing visible changed.
function Discord:rebuildList(menu, force)
    local items = menu.items_func()
    local signature = listSignature(items) .. (menu.search_query or "")
    if not force and signature == menu.signature then return end
    menu.signature = signature
    local title = menu.list_title
    if menu.search_query then
        local found = {}
        for __, item in ipairs(items) do
            local haystack = (item.search or item.text or ""):lower()
            if item.select_enabled ~= false and haystack:find(menu.search_query, 1, true) then
                table.insert(found, item)
            end
        end
        if #found == 0 then
            table.insert(found, { text = _("No results"), select_enabled = false })
        end
        items = found
        title = T(_("%1 — «%2»"), title, menu.search_query)
    end
    menu:switchItemTable(title, items, -1)
    if menu.page_num and menu.page > menu.page_num then
        menu:onGotoPage(math.max(1, menu.page_num))
    end
end

--- Refreshes unread markers of the visible list (others refresh when shown again).
function Discord:refreshLists()
    if self._refresh_pending then return end
    self._refresh_pending = true
    UIManager:scheduleIn(3, function()
        self._refresh_pending = false
        local top = UIManager:getTopmostVisibleWidget()
        for __, menu in ipairs(shared.lists) do
            if menu == top then
                self:rebuildList(menu)
            else
                menu.stale = true
            end
        end
    end)
end

function Discord:refreshStaleLists()
    for __, menu in ipairs(shared.lists) do
        if menu.stale then
            menu.stale = false
            self:rebuildList(menu)
        end
    end
end

--- Unread marker for list items: (bold, mandatory text).
local function unreadMarks(unread, mentions)
    if mentions and mentions > 0 then
        return true, "@" .. mentions
    elseif unread then
        return true, "●"
    end
    return false, nil
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
    self:updateConnection()
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

-- Favorites, recents and hidden servers

function Discord:isFavorite(id)
    for __, f in ipairs(self.settings.favorites or {}) do
        if f.id == id then return true end
    end
    return false
end

function Discord:toggleFavorite(entry)
    self.settings.favorites = self.settings.favorites or {}
    for i, f in ipairs(self.settings.favorites) do
        if f.id == entry.id then
            table.remove(self.settings.favorites, i)
            self:saveSettings()
            UIManager:show(Notification:new{ text = _("Removed from favorites") })
            self:refreshLists()
            return
        end
    end
    table.insert(self.settings.favorites, entry)
    self:saveSettings()
    UIManager:show(Notification:new{ text = _("Added to favorites") })
    self:refreshLists()
end

function Discord:addRecent(entry)
    local recents = self.settings.recents or {}
    for i = #recents, 1, -1 do
        if recents[i].id == entry.id then table.remove(recents, i) end
    end
    table.insert(recents, 1, entry)
    while #recents > MAX_RECENTS do table.remove(recents) end
    self.settings.recents = recents
    self:saveSettings()
end

function Discord:isHidden(guild_id)
    return self.settings.hidden_guilds and self.settings.hidden_guilds[guild_id] ~= nil
end

function Discord:setHidden(guild_id, name, hidden)
    self.settings.hidden_guilds = self.settings.hidden_guilds or {}
    self.settings.hidden_guilds[guild_id] = hidden and (name or true) or nil
    self:saveSettings()
    self:refreshLists()
end

function Discord:showHiddenGuilds()
    self:showList(_("Hidden servers"), function()
        local items = {}
        for id, name in pairs(self.settings.hidden_guilds or {}) do
            table.insert(items, {
                text = type(name) == "string" and cleanEmoji(name) or id,
                mandatory = _("tap to show"),
                callback = function() self:setHidden(id, nil, false) end,
            })
        end
        table.sort(items, function(a, b) return a.text:lower() < b.text:lower() end)
        if #items == 0 then
            table.insert(items, { text = _("No hidden servers."), select_enabled = false })
        end
        return items
    end)
end

function Discord:showNotifications()
    self:showList(_("Recent notifications"), function()
        local items = {}
        for __, n in ipairs(shared.notifications) do
            table.insert(items, {
                text = n.text,
                mandatory = os.date("%H:%M", n.time),
                callback = function() self:openEntry({ id = n.channel_id, guild_id = n.guild_id }) end,
            })
        end
        if #items == 0 then
            table.insert(items, { text = _("No notifications."), select_enabled = false })
        end
        return items
    end)
end

-- Mute and read state

function Discord:toggleMute(guild_id, channel_id)
    local muted
    if channel_id then
        muted = not Gateway.muted_channels[channel_id]
    else
        muted = not Gateway.muted_guilds[guild_id]
    end
    self:withLoading(nil, function()
        local ok, err = self.api:setMuted(guild_id, channel_id, muted)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Could not change mute: ") .. tostring(err) })
            return
        end
        if channel_id then
            Gateway.muted_channels[channel_id] = muted or nil
        else
            Gateway.muted_guilds[guild_id] = muted or nil
        end
        UIManager:show(Notification:new{ text = muted and _("Muted") or _("Unmuted") })
        self:refreshLists()
    end)
end

--- Acks every unread channel in the list. Returns the number marked.
function Discord:markChannelsRead(channels)
    local entries = {}
    for __, ch in ipairs(channels) do
        if ch.last_message_id and (Gateway:isUnread(ch) or Gateway:mentionCount(ch.id) > 0) then
            table.insert(entries, { channel_id = ch.id, message_id = ch.last_message_id })
        end
    end
    if #entries == 0 then
        UIManager:show(Notification:new{ text = _("Nothing to mark as read") })
        return
    end
    self:withLoading(_("Marking as read…"), function()
        local ok, err = self.api:ackBulk(entries)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Could not mark as read: ") .. tostring(err) })
            return
        end
        for __, e in ipairs(entries) do Gateway:markRead(e.channel_id, e.message_id) end
        UIManager:show(Notification:new{ text = T(_("Marked %1 channels as read"), #entries) })
        self:refreshLists()
    end)
end

function Discord:markGuildRead(guild_id)
    local g = Gateway.guilds[guild_id]
    if not g then return end
    local list = {}
    for __, l in ipairs({ g.channels, g.threads }) do
        for __, ch in ipairs(l) do table.insert(list, ch) end
    end
    self:markChannelsRead(list)
end

function Discord:markDMsRead()
    local list = {}
    for __, id in ipairs(Gateway.private_channels) do
        if Gateway.channels[id] then table.insert(list, Gateway.channels[id]) end
    end
    self:markChannelsRead(list)
end

-- Friends

function Discord:friendRequestDialog(rel)
    local name = cleanEmoji(rel.user.global_name or rel.user.username or "?")
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("Friend request from %1"), name),
        buttons = {{
            {
                text = _("Ignore"),
                callback = function()
                    UIManager:close(dialog)
                    self:withLoading(nil, function()
                        local ok, err = self.api:removeRelationship(rel.user.id)
                        if not ok then UIManager:show(InfoMessage:new{ text = tostring(err) }) return end
                        Gateway.relationships[rel.user.id] = nil
                        self:refreshLists()
                    end)
                end,
            },
            {
                text = _("Accept"),
                callback = function()
                    UIManager:close(dialog)
                    self:withLoading(nil, function()
                        local ok, err = self.api:acceptFriend(rel.user.id)
                        if not ok then UIManager:show(InfoMessage:new{ text = tostring(err) }) return end
                        rel.type = 1
                        UIManager:show(Notification:new{ text = _("Friend request accepted") })
                        self:refreshLists()
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function Discord:friendItems()
    local requests, friends = {}, {}
    for __, rel in pairs(Gateway.relationships) do
        local name = cleanEmoji(rel.nickname or rel.user.global_name or rel.user.username or "?")
        if rel.type == 3 then
            table.insert(requests, {
                text = name,
                search = name .. " " .. (rel.user.username or ""),
                bold = true,
                mandatory = _("request"),
                callback = function() self:friendRequestDialog(rel) end,
            })
        elseif rel.type == 1 then
            table.insert(friends, {
                text = name,
                search = name .. " " .. (rel.user.username or ""),
                mandatory = rel.user.username,
                callback = function() self:openDMWith(rel.user) end,
            })
        end
    end
    local by_name = function(a, b) return a.text:lower() < b.text:lower() end
    table.sort(requests, by_name)
    table.sort(friends, by_name)
    for __, f in ipairs(friends) do table.insert(requests, f) end
    if #requests == 0 then
        table.insert(requests, { text = _("No friends yet."), select_enabled = false })
    end
    return requests
end

function Discord:showFriends()
    if not self:requireLogin() then return end
    self:withLoading(_("Loading friends…"), function()
        if not self:waitForGateway() then
            local ok, list = self.api:getRelationships()
            if not ok then
                UIManager:show(InfoMessage:new{ text = tostring(list) })
                return
            end
            Gateway.relationships = {}
            for __, r in ipairs(list) do
                Gateway.relationships[r.id] = { type = r.type, user = r.user, nickname = r.nickname }
            end
        end
        self:showList(_("Friends"), function() return self:friendItems() end)
    end)
end

-- Mentions inbox

function Discord:showMentions()
    if not self:requireLogin() then return end
    self:withLoading(_("Loading mentions…"), function()
        local ok, list = self.api:getMentions()
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Could not load mentions: ") .. tostring(list) })
            return
        end
        self:waitForGateway()
        self:showList(_("Mentions"), function()
            local items = {}
            for __, m in ipairs(list) do
                local author = cleanEmoji(m.author and (m.author.global_name or m.author.username) or "?")
                local content = cleanEmoji((m.content or ""):gsub("<@!?%d+>", "@"):gsub("<@&%d+>", "@role")
                    :gsub("<#%d+>", "#channel"):gsub("<a?:([%w_]+):%d+>", ":%1:"):gsub("%s+", " "))
                local ts = ChatView.parseTimestamp(m.timestamp) or 0
                table.insert(items, {
                    text = author .. " — " .. self:channelLabel(m.channel_id) .. ": " .. content,
                    mandatory = os.date("%m-%d %H:%M", ts),
                    callback = function()
                        self:openEntry({ id = m.channel_id, guild_id = m.guild_id }, m.id)
                    end,
                })
            end
            if #items == 0 then
                table.insert(items, { text = _("No recent mentions."), select_enabled = false })
            end
            return items
        end)
    end)
end

-- Offline chats

function Discord:openOffline(entry)
    local channel = { id = entry.id }
    local guild = entry.guild_id and { id = entry.guild_id, name = entry.subtitle } or nil
    local view
    view = ChatView:new{
        api = self.api,
        channel = channel,
        guild = guild,
        title = entry.title or "?",
        subtitle = (entry.subtitle or "") .. " · " .. _("offline"),
        settings = self.settings,
        can_send = false,
        plugin = self,
        offline = true,
    }
    if view:load() then
        UIManager:show(view)
    end
end

function Discord:showOfflineChats()
    self:showList(_("Offline chats"), function()
        local items = {}
        for __, e in ipairs(ChatView.listCache()) do
            table.insert(items, {
                text = e.title or "?",
                mandatory = e.subtitle and cleanEmoji(e.subtitle) or nil,
                callback = function() self:openOffline(e) end,
            })
        end
        if #items == 0 then
            table.insert(items, { text = _("No chats saved yet. Open a chat while online first."), select_enabled = false })
        end
        return items
    end)
end

-- Navigation

function Discord:requireLogin()
    if self:isLoggedIn() then return true end
    UIManager:show(InfoMessage:new{
        text = _("Log in first from Tools → Discord."),
    })
    return false
end

function Discord:dmName(ch)
    if ch.name and ch.name ~= "" then return cleanEmoji(ch.name) end
    local names = {}
    for __, r in ipairs(ch.recipients or {}) do
        table.insert(names, r.global_name or r.username)
    end
    if #names == 0 then return _("(unnamed)") end
    return cleanEmoji(table.concat(names, ", "))
end

--- Guild objects as used by the chat view: from gateway state when possible.
function Discord:guildFromGateway(guild_id)
    local g = Gateway.guilds[guild_id]
    if not g then return nil end
    return { id = g.id, name = g.name, roles = g.roles, owner_id = g.owner_id }
end

function Discord:channelNames(guild_id)
    local names = {}
    local g = Gateway.guilds[guild_id]
    if g then
        for __, list in ipairs({ g.channels, g.threads }) do
            for __, ch in ipairs(list) do names[ch.id] = ch.name end
        end
    end
    return names
end

function Discord:favoriteItems()
    local items = {}
    for __, f in ipairs(self.settings.favorites or {}) do
        local ch = Gateway.channels[f.id]
        local bold, mark = unreadMarks(ch and Gateway:isUnread(ch) and not Gateway:isMuted(ch), Gateway:mentionCount(f.id))
        table.insert(items, {
            text = "★ " .. (f.title or "?"),
            search = (f.title or "") .. " " .. (f.subtitle or ""),
            bold = bold,
            mandatory = mark or (f.subtitle and cleanEmoji(f.subtitle)) or nil,
            callback = function() self:openEntry(f) end,
            hold_callback = function() self:toggleFavorite(f) end,
        })
    end
    return items
end

function Discord:homeItems(guilds)
    local items = self:favoriteItems()
    local dm_unread, dm_mentions = 0, 0
    if Gateway:hasState() then dm_unread, dm_mentions = Gateway:dmUnread() end
    local bold, mark = unreadMarks(dm_unread > 0, dm_mentions)
    if dm_unread > 0 and dm_mentions == 0 then mark = tostring(dm_unread) end
    table.insert(items, {
        text = _("Direct messages"),
        bold = true,
        mandatory = mark,
        callback = function() self:onOpenDiscordDMs() end,
        hold_callback = function()
            if Gateway:isReady() then self:markDMsRead() end
        end,
    })
    local requests = 0
    for __, rel in pairs(Gateway.relationships) do
        if rel.type == 3 then requests = requests + 1 end
    end
    table.insert(items, {
        text = _("Friends"),
        mandatory = requests > 0 and T(_("%1 requests"), requests) or nil,
        bold = requests > 0,
        callback = function() self:showFriends() end,
    })
    table.insert(items, {
        text = _("Mentions"),
        callback = function() self:showMentions() end,
    })
    if #shared.notifications > 0 then
        table.insert(items, {
            text = T(_("Recent notifications (%1)"), #shared.notifications),
            callback = function() self:showNotifications() end,
        })
    end
    local hidden_count = 0
    for __, g in ipairs(guilds) do
        if self:isHidden(g.id) then
            hidden_count = hidden_count + 1
        else
            local unread, mentions = false, 0
            if Gateway:hasState() then unread, mentions = Gateway:guildUnread(g.id) end
            local b, m = unreadMarks(unread, mentions)
            table.insert(items, {
                text = cleanName(g.name),
                bold = b,
                mandatory = m,
                guild = g,
                callback = function() self:openGuild(g) end,
            })
        end
    end
    if hidden_count > 0 then
        table.insert(items, {
            text = T(_("Hidden servers (%1)"), hidden_count),
            callback = function() self:showHiddenGuilds() end,
        })
    end
    return items
end

function Discord:guildHoldDialog(g)
    local dialog
    local ready = Gateway:isReady()
    dialog = ButtonDialog:new{
        title = cleanEmoji(g.name),
        buttons = {
            {
                {
                    text = _("Mark as read"),
                    enabled = ready,
                    callback = function()
                        UIManager:close(dialog)
                        self:markGuildRead(g.id)
                    end,
                },
                {
                    text = Gateway.muted_guilds[g.id] and _("Unmute server") or _("Mute server"),
                    enabled = ready,
                    callback = function()
                        UIManager:close(dialog)
                        self:toggleMute(g.id)
                    end,
                },
            },
            {
                {
                    text = _("Hide server"),
                    callback = function()
                        UIManager:close(dialog)
                        self:setHidden(g.id, g.name, true)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Discord:onOpenDiscord()
    if not self:requireLogin() then return true end
    self:withLoading(_("Loading servers…"), function()
        local guilds
        if self:waitForGateway() then
            guilds = nil -- read live from the gateway, it may still be loading
        else
            local ok, data, code = self.api:getGuilds()
            if not ok then
                UIManager:show(InfoMessage:new{ text = errorText(_("Could not load servers: "), data, code) })
                return
            end
            guilds = data
        end
        local by_name = function(a, b) return a.name:lower() < b.name:lower() end
        if guilds then table.sort(guilds, by_name) end
        local user = self.settings.user or {}
        self:showList(_("Discord"), function()
            local list = guilds
            if not list then
                list = {}
                for __, id in ipairs(Gateway.guild_order) do
                    local g = Gateway.guilds[id]
                    if g then table.insert(list, { id = g.id, name = g.name }) end
                end
                table.sort(list, by_name)
            end
            return self:homeItems(list)
        end,
            user.global_name or user.username, function(item)
                if item.guild then self:guildHoldDialog(item.guild) end
            end)
    end)
    return true
end

function Discord:onOpenDiscordLastChat()
    if not self:requireLogin() then return true end
    local recent = self.settings.recents and self.settings.recents[1]
    if not recent then
        UIManager:show(InfoMessage:new{ text = _("No recent chats yet.") })
        return true
    end
    self:openEntry(recent)
    return true
end

--- Opens a chat from a stored entry { id, guild_id, title, subtitle }.
function Discord:openEntry(entry, around_id)
    if not NetworkMgr:isOnline() and ChatView.readCache(entry.id) then
        self:openOffline(entry)
        return
    end
    self:withLoading(_("Loading messages…"), function()
        self:waitForGateway()
        local channel = Gateway.channels[entry.id]
        if not channel then
            local ok, ch = self.api:getChannel(entry.id)
            if not ok then
                UIManager:show(InfoMessage:new{ text = _("Could not open the chat: ") .. tostring(ch) })
                return
            end
            channel = ch
        end
        local guild_id = entry.guild_id or channel.guild_id
        local guild, can_send = nil, true
        if guild_id then
            guild = self:guildFromGateway(guild_id)
            if not guild then
                local ok, g = self.api:getGuild(guild_id)
                guild = ok and g or { id = guild_id, name = entry.subtitle or "?" }
            elseif Gateway.guilds[guild_id] then
                local perms_of = Gateway:permissionResolver(Gateway.guilds[guild_id])
                local check = THREAD_TYPES[channel.type] and Gateway.channels[channel.parent_id] or channel
                can_send = DiscordAPI.hasPerm(perms_of(check), DiscordAPI.PERM_SEND_MESSAGES)
            end
        end
        local title = entry.title
        if not title then
            if guild then
                title = "#" .. cleanName(channel.name)
            else
                title = self:dmName(channel)
            end
        end
        local subtitle = entry.subtitle or (guild and cleanName(guild.name))
            or (channel.type == CHANNEL_GROUP_DM and _("Group") or _("Direct message"))
        self:openChannelNow(channel, guild, title, subtitle, guild and self:channelNames(guild.id), can_send, around_id)
    end)
end

function Discord:openChannel(channel, guild, title, subtitle, channel_names, can_send)
    if not NetworkMgr:isOnline() and ChatView.readCache(channel.id) then
        self:openOffline({ id = channel.id, guild_id = guild and guild.id, title = title, subtitle = subtitle })
        return
    end
    self:withLoading(_("Loading messages…"), function()
        self:openChannelNow(channel, guild, title, subtitle, channel_names, can_send)
    end)
end

function Discord:openChannelNow(channel, guild, title, subtitle, channel_names, can_send, around_id)
    local view
    view = ChatView:new{
        api = self.api,
        channel = channel,
        guild = guild,
        title = title,
        subtitle = subtitle,
        channel_names = channel_names,
        settings = self.settings,
        can_send = can_send ~= false,
        plugin = self,
        around_id = around_id,
        close_callback = function()
            self:saveSettings()
            self:refreshStaleLists()
        end,
    }
    if view:load() then
        table.insert(shared.views, view)
        local orig_close = view.onCloseWidget
        view.onCloseWidget = function(this)
            orig_close(this)
            for i, vw in ipairs(shared.views) do
                if vw == this then table.remove(shared.views, i) break end
            end
            UIManager:nextTick(function() self:updateConnection() end)
        end
        UIManager:show(view)
        self:addRecent(view:favoriteEntry())
    end
end

function Discord:openDMWith(user)
    self:withLoading(nil, function()
        local ok, ch = self.api:openDM(user.id)
        if not ok then
            UIManager:show(InfoMessage:new{ text = tostring(ch) })
            return
        end
        self:openChannelNow(ch, nil, "@" .. cleanEmoji(user.global_name or user.username), _("Direct message"))
    end)
end

function Discord:dmItems(channels)
    table.sort(channels, function(a, b)
        local la, lb = a.last_message_id or a.id, b.last_message_id or b.id
        return idLess(lb, la)
    end)
    local items = {}
    for __, ch in ipairs(channels) do
        if ch.type == CHANNEL_DM or ch.type == CHANNEL_GROUP_DM then
            local name = self:dmName(ch)
            local usernames = {}
            for __, r in ipairs(ch.recipients or {}) do
                table.insert(usernames, r.username or "")
            end
            local bold, mark = false, nil
            if Gateway:hasState() then
                bold, mark = unreadMarks(Gateway:isUnread(ch) and not Gateway:isMuted(ch), Gateway:mentionCount(ch.id))
            end
            local subtitle = ch.type == CHANNEL_GROUP_DM and _("Group") or _("Direct message")
            local title = (ch.type == CHANNEL_GROUP_DM and "" or "@") .. name
            table.insert(items, {
                search = name .. " " .. table.concat(usernames, " "),
                text = title,
                bold = bold,
                mandatory = mark or (ch.type == CHANNEL_GROUP_DM and _("group") or nil),
                callback = function()
                    self:openChannel(ch, nil, name, subtitle)
                end,
                hold_callback = function()
                    self:toggleFavorite({ id = ch.id, title = title, subtitle = subtitle })
                end,
            })
        end
    end
    if #items == 0 then
        table.insert(items, { text = _("You have no direct messages."), select_enabled = false })
    end
    return items
end

function Discord:onOpenDiscordDMs()
    if not self:requireLogin() then return true end
    self:withLoading(_("Loading direct messages…"), function()
        if self:waitForGateway() then
            self:showList(_("Direct messages"), function()
                local channels = {}
                for __, id in ipairs(Gateway.private_channels) do
                    if Gateway.channels[id] then table.insert(channels, Gateway.channels[id]) end
                end
                return self:dmItems(channels)
            end)
            return
        end
        local ok, channels, code = self.api:getDMChannels()
        if not ok then
            UIManager:show(InfoMessage:new{ text = errorText(_("Could not load direct messages: "), channels, code) })
            return
        end
        self:showList(_("Direct messages"), function() return self:dmItems(channels) end)
    end)
    return true
end

function Discord:channelItems(guild, channels, threads, perms_of)
    local channel_names = {}
    local categories = {}
    for __, ch in ipairs(channels) do
        channel_names[ch.id] = ch.name
        if ch.type == CHANNEL_CATEGORY then
            categories[ch.id] = { channel = ch, children = {} }
        end
    end
    local threads_by_parent = {}
    for __, th in ipairs(threads or {}) do
        if not (th.thread_metadata and th.thread_metadata.archived) then
            channel_names[th.id] = th.name
            threads_by_parent[th.parent_id] = threads_by_parent[th.parent_id] or {}
            table.insert(threads_by_parent[th.parent_id], th)
        end
    end
    local top = { channel = { position = -1 }, children = {} }
    for __, ch in ipairs(channels) do
        if ch.type == CHANNEL_TEXT or ch.type == CHANNEL_ANNOUNCEMENT
                or ch.type == CHANNEL_FORUM or ch.type == CHANNEL_MEDIA then
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
        return idLess(a.id or "0", b.id or "0")
    end
    table.sort(groups, function(a, b) return by_position(a.channel, b.channel) end)

    local guild_name = cleanName(guild.name)
    local items = {}
    local function addChannel(ch, prefix, can_send)
        local name = cleanName(ch.name)
        local is_forum = ch.type == CHANNEL_FORUM or ch.type == CHANNEL_MEDIA
        local bold, mark = false, nil
        if Gateway:hasState() and not is_forum then
            bold, mark = unreadMarks(Gateway:isUnread(ch) and not Gateway:isMuted(ch), Gateway:mentionCount(ch.id))
        end
        local label = mark
            or (ch._hidden and _("no access"))
            or (is_forum and _("forum"))
            or (can_send == false and _("read-only"))
            or (ch.type == CHANNEL_ANNOUNCEMENT and _("announcements")) or nil
        local title = (THREAD_TYPES[ch.type] and "" or "#") .. name
        table.insert(items, {
            text = prefix .. name,
            bold = bold,
            mandatory = label,
            callback = function()
                if is_forum then
                    self:openThreadList(ch.id, guild, channel_names)
                else
                    self:openChannel(ch, guild, title, guild_name, channel_names, can_send)
                end
            end,
            hold_callback = not is_forum and function()
                self:toggleFavorite({ id = ch.id, guild_id = guild.id, title = title, subtitle = guild_name })
            end or nil,
        })
    end
    for __, group in ipairs(groups) do
        table.sort(group.children, by_position)
        if group ~= top then
            table.insert(items, {
                text = "— " .. cleanName(group.channel.name):upper() .. " —",
                bold = true,
                select_enabled = false,
            })
        end
        for __, ch in ipairs(group.children) do
            local is_forum = ch.type == CHANNEL_FORUM or ch.type == CHANNEL_MEDIA
            addChannel(ch, is_forum and "▤ " or "# ", ch._can_send)
            if not is_forum then
                for __, th in ipairs(threads_by_parent[ch.id] or {}) do
                    addChannel(th, "    └ ", ch._can_send)
                end
            end
        end
    end
    if #items == 0 then
        table.insert(items, { text = _("No visible text channels."), select_enabled = false })
    end
    return items, channel_names
end

function Discord:openGuild(guild_summary)
    self:withLoading(_("Loading channels…"), function()
        local gw_guild = Gateway:hasState() and Gateway.guilds[guild_summary.id]
        if gw_guild then
            Gateway:subscribeGuild(gw_guild.id)
            local guild = self:guildFromGateway(gw_guild.id)
            self:showList(cleanName(guild.name), function()
                local perms_of = Gateway:permissionResolver(gw_guild)
                return (self:channelItems(guild, gw_guild.channels, gw_guild.threads, perms_of))
            end)
            return
        end
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
        self:showList(cleanEmoji(guild.name), function()
            return (self:channelItems(guild, channels, nil, perms_of))
        end)
    end)
end

--- Lists the threads of a channel, or the posts of a forum.
function Discord:openThreadList(parent_id, guild, channel_names)
    self:withLoading(_("Loading threads…"), function()
        local parent = Gateway.channels[parent_id]
        local is_forum = parent and (parent.type == CHANNEL_FORUM or parent.type == CHANNEL_MEDIA)
        if not parent then
            local ok, ch = self.api:getChannel(parent_id)
            if ok then
                parent = ch
                is_forum = ch.type == CHANNEL_FORUM or ch.type == CHANNEL_MEDIA
            end
        end
        local threads, seen = {}, {}
        local gw_guild = guild and Gateway.guilds[guild.id]
        for __, th in ipairs(gw_guild and gw_guild.threads or {}) do
            if th.parent_id == parent_id and not seen[th.id] then
                seen[th.id] = true
                table.insert(threads, th)
            end
        end
        local ok, list
        if is_forum then
            ok, list = self.api:searchThreads(parent_id, false)
        else
            ok, list = self.api:getArchivedThreads(parent_id)
        end
        for __, th in ipairs(ok and list or {}) do
            if not seen[th.id] then
                seen[th.id] = true
                table.insert(threads, th)
            end
        end
        table.sort(threads, function(a, b)
            return idLess(b.last_message_id or b.id, a.last_message_id or a.id)
        end)
        local parent_name = parent and cleanName(parent.name) or "?"
        local guild_name = guild and cleanName(guild.name) or ""
        channel_names = channel_names or {}
        self:showList(T(_("Threads in #%1"), parent_name), function()
            local items = {}
            for __, th in ipairs(threads) do
                local name = cleanName(th.name)
                channel_names[th.id] = th.name
                local archived = th.thread_metadata and th.thread_metadata.archived
                local bold, mark = false, nil
                if Gateway:hasState() then
                    bold, mark = unreadMarks(Gateway:isUnread(th), Gateway:mentionCount(th.id))
                end
                table.insert(items, {
                    text = name,
                    bold = bold,
                    mandatory = mark or (archived and _("archived")) or nil,
                    callback = function()
                        self:openChannel(th, guild, name, guild_name .. " › #" .. parent_name, channel_names,
                            not archived)
                    end,
                    hold_callback = function()
                        self:toggleFavorite({ id = th.id, guild_id = guild and guild.id, title = name,
                            subtitle = guild_name .. " › #" .. parent_name })
                    end,
                })
            end
            if #items == 0 then
                table.insert(items, { text = _("No threads."), select_enabled = false })
            end
            return items
        end)
    end)
end

-- Reading mode: export a channel to an HTML document opened in the reader

local function htmlEscape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\n", "<br/>"))
end

function Discord:openAsDocument(view)
    local wanted = self.settings.doc_messages or 300
    self:withLoading(_("Preparing document…"), function()
        local messages = {}
        for __, m in ipairs(view.messages) do table.insert(messages, m) end
        while #messages < wanted do
            local oldest = messages[1]
            local ok, page = self.api:getMessages(view.channel.id, { limit = 100, before = oldest and oldest.id })
            if not ok or #page == 0 then break end
            for __, m in ipairs(page) do table.insert(messages, m) end
            table.sort(messages, function(a, b) return idLess(a.id, b.id) end)
        end
        local html = {
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<html><head><meta charset="UTF-8"/><title>' .. htmlEscape(view.title or "Discord") .. '</title>',
            '<style>p{margin:0.3em 0}h2{font-size:1em;text-align:center;margin:1em 0 0.5em}.a{font-weight:bold}.t{font-size:0.8em;color:#555}.r{margin-left:1em;font-size:0.85em;color:#444}</style>',
            '</head><body>',
            '<h1>' .. htmlEscape(view.title or "") .. '</h1>',
            '<p class="t">' .. htmlEscape(view.subtitle or "") .. '</p>',
        }
        local prev_day
        for __, m in ipairs(messages) do
            local ts = ChatView.parseTimestamp(m.timestamp) or 0
            local day = os.date("%Y-%m-%d", ts)
            if day ~= prev_day then
                table.insert(html, "<h2>" .. day .. "</h2>")
                prev_day = day
            end
            local parts = { '<p><span class="a">' .. htmlEscape(view:authorName(m.author)) .. '</span> <span class="t">'
                .. os.date("%H:%M", ts) .. '</span><br/>' }
            if m.referenced_message then
                table.insert(parts, '<span class="r">↪ ' .. htmlEscape(view:authorName(m.referenced_message.author)
                    .. ": " .. view:renderContent(m.referenced_message):sub(1, 200)) .. '</span><br/>')
            end
            table.insert(parts, htmlEscape(view:renderContent(m)) .. "</p>")
            table.insert(html, table.concat(parts))
        end
        table.insert(html, "</body></html>")

        local dir = DataStorage:getDataDir() .. "/cache/discord"
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(dir)
        local name = (view.title or "chat"):gsub("[^%w%-_]", "_")
        local path = dir .. "/" .. name .. "-" .. view.channel.id .. ".html"
        local f = io.open(path, "w")
        if not f then
            UIManager:show(InfoMessage:new{ text = _("Could not write the document.") })
            return
        end
        f:write(table.concat(html, "\n"))
        f:close()
        -- Close Discord screens, then open the document in the reader
        for i = #shared.views, 1, -1 do UIManager:close(shared.views[i]) end
        for i = #shared.lists, 1, -1 do UIManager:close(shared.lists[i]) end
        UIManager:nextTick(function()
            require("apps/reader/readerui"):showReader(path)
        end)
    end)
end

-- Sharing highlights

function Discord:addToHighlightDialog()
    self.ui.highlight:addToHighlightDialog("12_discord_share", function(this)
        return {
            text = _("Send to Discord"),
            enabled = self:isLoggedIn(),
            callback = function()
                local text = util.cleanupSelectedText(this.selected_text and this.selected_text.text or "")
                this:onClose()
                if text == "" then return end
                self:shareText(text)
            end,
        }
    end)
end

function Discord:shareText(text)
    local props = self.ui.doc_props or {}
    local book = props.display_title or props.title
    local quoted = "> " .. text:gsub("\n", "\n> ")
    if book and book ~= "" then
        quoted = quoted .. "\n— *" .. book .. "*"
    end
    self:pickDestination(_("Send highlight to…"), function(e)
        self:withLoading(_("Sending…"), function()
            local ok, err = self.api:sendMessage(e.id, quoted)
            if ok then
                UIManager:show(Notification:new{ text = T(_("Sent to %1"), e.title or "?") })
            else
                UIManager:show(InfoMessage:new{ text = _("Could not send: ") .. tostring(err) })
            end
        end)
    end)
end

--- Lets the user choose a chat among favorites and recents, then calls fn(entry).
function Discord:pickDestination(title, fn)
    local destinations, seen = {}, {}
    for __, list in ipairs({ self.settings.favorites or {}, self.settings.recents or {} }) do
        for __, e in ipairs(list) do
            if not seen[e.id] then
                seen[e.id] = true
                table.insert(destinations, e)
            end
        end
    end
    if #destinations == 0 then
        UIManager:show(InfoMessage:new{ text = _("Open a chat or add a favorite first, then you can send to it.") })
        return
    end
    local dialog
    local buttons = {}
    for __, e in ipairs(destinations) do
        table.insert(buttons, {{
            text = (e.title or "?") .. (e.subtitle and (" · " .. cleanEmoji(e.subtitle)) or ""),
            callback = function()
                UIManager:close(dialog)
                fn(e)
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dialog)
end

function Discord:forwardMessage(msg, src_channel_id, guild_id)
    self:pickDestination(_("Forward to…"), function(e)
        self:withLoading(_("Sending…"), function()
            local ok, err = self.api:forwardMessage(e.id, src_channel_id, msg.id, guild_id)
            if ok then
                UIManager:show(Notification:new{ text = T(_("Forwarded to %1"), e.title or "?") })
            else
                UIManager:show(InfoMessage:new{ text = _("Could not forward: ") .. tostring(err) })
            end
        end)
    end)
end

return Discord
