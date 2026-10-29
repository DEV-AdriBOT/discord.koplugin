--[[--
Full screen chat view for one Discord channel.

@module koplugin.discord.chatview
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local DiscordAPI = require("discord_api")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

local idLess = DiscordAPI.idLess
local cleanEmoji = DiscordAPI.cleanEmoji

-- Formatting helpers

local tz_offset
local function parseTimestamp(iso)
    local y, mo, d, h, mi, s = (iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    if not tz_offset then
        local now = os.time()
        tz_offset = os.difftime(now, os.time(os.date("!*t", now)))
    end
    return os.time{ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false } + tz_offset
end

local function displayName(user)
    if not user then return "?" end
    return cleanEmoji(user.global_name or user.username or "?")
end

local function oneLine(text, max)
    text = (text or ""):gsub("%s+", " ")
    if util.splitToChars and #text > max then
        local chars = util.splitToChars(text)
        if #chars > max then
            text = table.concat(chars, "", 1, max) .. "…"
        end
    end
    return text
end

local SYSTEM_TYPES = {
    [1] = _("added someone to the group"),
    [2] = _("removed someone from the group"),
    [3] = _("started a call"),
    [4] = _("changed the channel name"),
    [5] = _("changed the channel icon"),
    [6] = _("pinned a message"),
    [7] = _("joined the server"),
    [8] = _("boosted the server"),
    [18] = _("started a thread"),
}

local ChatView = InputContainer:extend{
    api = nil,
    channel = nil,     -- channel object
    guild = nil,       -- guild object (nil for DMs)
    channel_names = nil, -- id -> name, used for <#id> mentions
    title = nil,
    subtitle = nil,
    settings = nil,    -- plugin settings table
    can_send = true,
}

function ChatView:init()
    self.messages = {}
    self.by_id = {}
    self.reply_to = nil
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.font_size = self.settings.font_size or 20
    self.poll_interval = self.settings.poll_interval or 15
    if self.guild then
        self.roles = {}
        for __, role in ipairs(self.guild.roles or {}) do
            self.roles[role.id] = role.name
        end
    end

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
    end

    self.titlebar = TitleBar:new{
        width = self.width,
        fullscreen = true,
        align = "left",
        with_bottom_line = true,
        title = self.title,
        subtitle = self.subtitle,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:showMenu() end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    self.button_table = ButtonTable:new{
        width = self.width - 2 * Size.padding.default,
        buttons = {
            {
                { text = _("Older"), callback = function() self:loadOlder() end },
                { text = _("Refresh"), callback = function() self:refresh(true) end },
                { text = _("Messages"), callback = function() self:pickMessage() end },
                { text = _("Write"), enabled = self.can_send, callback = function() self:compose() end },
            },
        },
        zero_sep = true,
        show_parent = self,
    }

    self.text_height = self.height - self.titlebar:getHeight() - self.button_table:getSize().h
        - 2 * Size.padding.default - Size.line.thick
    self:buildLayout("")
end

function ChatView:buildLayout(text, keep_ratio)
    local padding = Size.padding.large
    self.scroll_widget = ScrollTextWidget:new{
        text = text,
        face = Font:getFace("x_smallinfofont", self.font_size),
        width = self.width - 2 * padding,
        height = self.text_height - 2 * padding,
        dialog = self,
        alignment = "left",
        justified = false,
        auto_para_direction = true,
    }
    self.frame = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            self.titlebar,
            FrameContainer:new{
                padding = padding,
                margin = 0,
                bordersize = 0,
                self.scroll_widget,
            },
            FrameContainer:new{
                padding = Size.padding.default,
                margin = 0,
                bordersize = 0,
                self.button_table,
            },
        },
    }
    self[1] = self.frame
    if keep_ratio == "top" then
        self.scroll_widget:scrollToTop()
    else
        self.scroll_widget:scrollToBottom()
    end
end

-- Message rendering

function ChatView:renderContent(msg)
    local text = msg.content or ""
    local mentions = {}
    for __, u in ipairs(msg.mentions or {}) do
        mentions[u.id] = displayName(u)
    end
    text = text:gsub("<@!?(%d+)>", function(id)
        return "@" .. (mentions[id] or "user")
    end)
    text = text:gsub("<@&(%d+)>", function(id)
        local role = self.roles and self.roles[id]
        return "@" .. (role or "role")
    end)
    text = text:gsub("<#(%d+)>", function(id)
        return "#" .. cleanEmoji((self.channel_names and self.channel_names[id]) or "channel")
    end)
    text = text:gsub("<a?:([%w_~%-]+):%d+>", ":%1:")
    text = text:gsub("<t:(%-?%d+):?(%a?)>", function(ts, fmt)
        ts = tonumber(ts)
        if fmt == "R" or fmt == "D" or fmt == "d" then
            return os.date("%Y-%m-%d", ts)
        end
        return os.date("%Y-%m-%d %H:%M", ts)
    end)
    text = text:gsub("||(.-)||", "[spoiler: %1]")
    text = text:gsub("%*%*(.-)%*%*", "%1")
    text = text:gsub("__(.-)__", "%1")
    text = text:gsub("~~(.-)~~", "%1")
    text = text:gsub("```%w*\n?", "")

    local extras = {}
    for __, snap in ipairs(msg.message_snapshots or {}) do
        if snap.message then
            local fwd = self:renderContent(snap.message)
            table.insert(extras, "» " .. _("forwarded:") .. " " .. fwd:gsub("\n", "\n   "))
        end
    end
    for __, a in ipairs(msg.attachments or {}) do
        table.insert(extras, "[file: " .. (a.filename or "?") .. "]")
    end
    for __, s in ipairs(msg.sticker_items or {}) do
        table.insert(extras, "[sticker: " .. (s.name or "?") .. "]")
    end
    for __, e in ipairs(msg.embeds or {}) do
        local parts = {}
        if e.author and e.author.name then table.insert(parts, e.author.name) end
        if e.title then table.insert(parts, e.title) end
        if e.description then table.insert(parts, oneLine(e.description, 200)) end
        if #parts > 0 then
            table.insert(extras, "[embed: " .. table.concat(parts, " — ") .. "]")
        elseif e.type == "image" or e.type == "gifv" or e.type == "video" then
            table.insert(extras, "[" .. e.type .. "]")
        end
    end
    if msg.poll and msg.poll.question then
        table.insert(extras, "[poll: " .. (msg.poll.question.text or "") .. "]")
    end
    if #extras > 0 then
        text = (text ~= "" and (text .. "\n") or "") .. table.concat(extras, "\n")
    end
    if msg.edited_timestamp then
        text = text .. " (edited)"
    end
    return cleanEmoji(text)
end

function ChatView:buildText()
    local out = {}
    local prev, prev_day
    for __, msg in ipairs(self.messages) do
        local ts = parseTimestamp(msg.timestamp) or 0
        local day = os.date("%Y-%m-%d", ts)
        if day ~= prev_day then
            table.insert(out, "")
            table.insert(out, "═══════ " .. day .. " ═══════")
            prev_day = day
            prev = nil
        end
        local author = displayName(msg.author)
        local system = SYSTEM_TYPES[msg.type]
        if system then
            table.insert(out, "")
            table.insert(out, "→ " .. author .. " " .. system .. "  " .. os.date("%H:%M", ts))
            prev = nil
        else
            local grouped = prev and not msg.referenced_message
                and prev.author and msg.author and prev.author.id == msg.author.id
                and ts - (parseTimestamp(prev.timestamp) or 0) < 420
            if not grouped then
                table.insert(out, "")
                table.insert(out, "▌" .. author .. " · " .. os.date("%H:%M", ts))
            end
            if msg.referenced_message then
                local ref = msg.referenced_message
                table.insert(out, "   ↪ " .. displayName(ref.author) .. ": " .. oneLine(self:renderContent(ref), 60))
            elseif msg.message_reference and msg.type == 19 then
                table.insert(out, "   ↪ " .. _("(deleted message)"))
            end
            local content = self:renderContent(msg)
            if content ~= "" then
                table.insert(out, content)
            end
            prev = msg
        end
    end
    if #self.messages == 0 then
        table.insert(out, _("No messages yet."))
    end
    return table.concat(out, "\n")
end

function ChatView:redraw(scroll_pos)
    self:buildLayout(self:buildText(), scroll_pos)
    if self.shown then
        UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    end
end

-- Data loading

function ChatView:addMessages(list)
    local added = 0
    for __, m in ipairs(list or {}) do
        if self.by_id[m.id] then
            -- Replace with the fresher copy
            for i, old in ipairs(self.messages) do
                if old.id == m.id then self.messages[i] = m break end
            end
        else
            table.insert(self.messages, m)
            added = added + 1
        end
        self.by_id[m.id] = m
    end
    table.sort(self.messages, function(a, b) return idLess(a.id, b.id) end)
    return added
end

function ChatView:load()
    local ok, data = self.api:getMessages(self.channel.id, { limit = self.settings.page_size or 50 })
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Could not load messages: ") .. tostring(data) })
        return false
    end
    self.messages, self.by_id = {}, {}
    self:addMessages(data)
    self:redraw()
    self:markRead()
    return true
end

function ChatView:markRead()
    local last = self.messages[#self.messages]
    if last and self.settings.mark_read ~= false and last.id ~= self.acked_id then
        self.acked_id = last.id
        self.api:ackMessage(self.channel.id, last.id)
    end
end

function ChatView:refresh(manual)
    if manual then
        -- Full reload, also picks up edits and deletions
        UIManager:show(Notification:new{ text = _("Refreshing…") })
        UIManager:nextTick(function() self:load() end)
        return
    end
    local last = self.messages[#self.messages]
    local ok, data = self.api:getMessages(self.channel.id, { limit = 50, after = last and last.id })
    if ok and self:addMessages(data) > 0 then
        self:redraw()
        self:markRead()
    end
end

function ChatView:loadOlder()
    local first = self.messages[1]
    if not first then return end
    local ok, data = self.api:getMessages(self.channel.id, { limit = self.settings.page_size or 50, before = first.id })
    if not ok then
        UIManager:show(InfoMessage:new{ text = tostring(data) })
        return
    end
    if #data == 0 then
        UIManager:show(Notification:new{ text = _("No older messages") })
        return
    end
    self:addMessages(data)
    self:redraw("top")
end

-- Polling

function ChatView:schedulePoll()
    if not self.poll_interval or self.poll_interval <= 0 then return end
    self._poll = self._poll or function()
        if self.closed then return end
        if NetworkMgr:isOnline() then
            local ok, err = pcall(self.refresh, self)
            if not ok then logger.warn("Discord: poll failed", err) end
        end
        self:schedulePoll()
    end
    UIManager:unschedule(self._poll)
    UIManager:scheduleIn(self.poll_interval, self._poll)
end

function ChatView:onShow()
    self.shown = true
    UIManager:setDirty(self, function() return "full", self.frame.dimen end)
    self:schedulePoll()
end

function ChatView:onResume()
    if not self.closed then self:schedulePoll() end
end

function ChatView:onSuspend()
    if self._poll then UIManager:unschedule(self._poll) end
end

function ChatView:onClose()
    self.closed = true
    if self._poll then UIManager:unschedule(self._poll) end
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

function ChatView:onCloseWidget()
    self.closed = true
    if self._poll then UIManager:unschedule(self._poll) end
    UIManager:setDirty(nil, "full")
end

function ChatView:onSwipe(arg, ges)
    if ges.direction == "west" or ges.direction == "east" then
        return true
    end
end

-- Sending

function ChatView:compose(prefill, edit_msg)
    local title
    if edit_msg then
        title = _("Edit message")
    elseif self.reply_to then
        title = _("Reply to ") .. displayName(self.reply_to.author)
    else
        title = self.title
    end
    local dialog
    dialog = InputDialog:new{
        title = title,
        description = self.reply_to and not edit_msg and oneLine(self:renderContent(self.reply_to), 80) or nil,
        input = prefill or self.draft or "",
        allow_newline = true,
        text_height = Screen:scaleBySize(120),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        if not edit_msg then
                            self.draft = dialog:getInputText()
                            self.reply_to = nil
                        end
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = edit_msg and _("Save") or _("Send"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        if text:match("^%s*$") then return end
                        UIManager:close(dialog)
                        self:send(text, edit_msg)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ChatView:send(text, edit_msg)
    local ok, data
    if edit_msg then
        ok, data = self.api:editMessage(self.channel.id, edit_msg.id, text)
    else
        local reply = self.reply_to
        if reply then reply.guild_id = self.guild and self.guild.id end
        ok, data = self.api:sendMessage(self.channel.id, text, reply)
    end
    if not ok then
        if not edit_msg then self.draft = text end
        UIManager:show(InfoMessage:new{ text = _("Could not send: ") .. tostring(data) })
        return
    end
    self.draft = nil
    self.reply_to = nil
    self:addMessages({ data })
    self:redraw()
end

-- Per-message actions

function ChatView:pickMessage()
    local items = {}
    for i = #self.messages, 1, -1 do
        local m = self.messages[i]
        local ts = parseTimestamp(m.timestamp) or 0
        table.insert(items, {
            text = displayName(m.author) .. ": " .. oneLine(self:renderContent(m), 120),
            mandatory = os.date("%H:%M", ts),
            msg = m,
        })
    end
    local menu
    menu = Menu:new{
        title = _("Choose a message"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        items_max_lines = 3,
        onMenuChoice = function(_menu, item)
            self:messageActions(item.msg)
        end,
    }
    menu.close_callback = function() UIManager:close(menu) end
    UIManager:show(menu)
end

function ChatView:messageActions(msg)
    local me = self.api.user and self.api.user.id
    local mine = msg.author and msg.author.id == me
    local dialog
    local buttons = {
        {
            {
                text = _("Reply"),
                enabled = self.can_send,
                callback = function()
                    UIManager:close(dialog)
                    self.reply_to = msg
                    self:compose()
                end,
            },
            {
                text = _("View full"),
                callback = function()
                    UIManager:close(dialog)
                    local TextViewer = require("ui/widget/textviewer")
                    UIManager:show(TextViewer:new{
                        title = displayName(msg.author),
                        text = self:renderContent(msg),
                    })
                end,
            },
        },
        {
            {
                text = _("Copy"),
                enabled = Device:hasClipboard(),
                callback = function()
                    UIManager:close(dialog)
                    Device.input.setClipboardText(msg.content or "")
                    UIManager:show(Notification:new{ text = _("Copied") })
                end,
            },
            {
                text = _("Direct message"),
                enabled = not mine and self.guild ~= nil and self.open_dm_callback ~= nil,
                callback = function()
                    UIManager:close(dialog)
                    self.open_dm_callback(msg.author)
                end,
            },
        },
    }
    if mine then
        table.insert(buttons, {
            {
                text = _("Editar"),
                callback = function()
                    UIManager:close(dialog)
                    self:compose(msg.content, msg)
                end,
            },
            {
                text = _("Delete"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete this message?"),
                        cancel_text = _("Cancel"),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            local ok, err = self.api:deleteMessage(self.channel.id, msg.id)
                            if ok then
                                for i, m in ipairs(self.messages) do
                                    if m.id == msg.id then table.remove(self.messages, i) break end
                                end
                                self.by_id[msg.id] = nil
                                self:redraw()
                            else
                                UIManager:show(InfoMessage:new{ text = tostring(err) })
                            end
                        end,
                    })
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = displayName(msg.author) .. ": " .. oneLine(self:renderContent(msg), 100),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function ChatView:showMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {
                {
                    text = _("Go to bottom"),
                    callback = function()
                        UIManager:close(dialog)
                        self.scroll_widget:scrollToBottom()
                        UIManager:setDirty(self, "ui")
                    end,
                },
                {
                    text = _("Go to top"),
                    callback = function()
                        UIManager:close(dialog)
                        self.scroll_widget:scrollToTop()
                        UIManager:setDirty(self, "ui")
                    end,
                },
            },
            {
                {
                    text = _("Smaller text"),
                    callback = function()
                        UIManager:close(dialog)
                        self.font_size = math.max(12, self.font_size - 2)
                        self.settings.font_size = self.font_size
                        self:redraw()
                    end,
                },
                {
                    text = _("Larger text"),
                    callback = function()
                        UIManager:close(dialog)
                        self.font_size = math.min(36, self.font_size + 2)
                        self.settings.font_size = self.font_size
                        self:redraw()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

return ChatView
