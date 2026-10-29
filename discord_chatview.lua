--[[--
Full screen chat view for one Discord channel.

@module koplugin.discord.chatview
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local DiscordAPI = require("discord_api")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Gateway = require("discord_gateway")
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
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local logger = require("logger")
local util = require("util")
local _ = require("discord_i18n")
local T = require("ffi/util").template
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

local function oneLine(text, max)
    text = (text or ""):gsub("%s+", " ")
    if #text > max then
        local chars = util.splitToChars(text)
        if #chars > max then
            text = table.concat(chars, "", 1, max) .. "…"
        end
    end
    return text
end

--- Inserts text, adding a space if it would stick to the previous word.
local function insertText(input_dialog, text)
    local current = input_dialog:getInputText()
    if current ~= "" and not current:match("%s$") then
        text = " " .. text
    end
    input_dialog:addTextToInput(text)
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
    [46] = _("ended a poll"),
}

-- Reactions offered in the "React" dialog
local QUICK_REACTIONS = { "👍", "❤️", "😂", "😮", "😢", "🙏", "🔥", "✅" }

local THREAD_TYPES = { [10] = true, [11] = true, [12] = true }

local ChatView = InputContainer:extend{
    NEW_MARKER = "──────── " .. _("New") .. " ────────",
    api = nil,
    channel = nil,       -- channel object
    guild = nil,         -- guild object (nil for DMs)
    channel_names = nil, -- id -> name, used for <#id> mentions
    title = nil,
    subtitle = nil,
    settings = nil,      -- plugin settings table
    can_send = true,
    plugin = nil,        -- main plugin, for favorites, documents and navigation
    around_id = nil,     -- open centered on this message instead of the latest ones
    offline = false,     -- showing cached messages without network
}

local CACHE_KEEP = 30 -- channels kept in the offline cache

local function cacheDir()
    local dir = DataStorage:getDataDir() .. "/cache/discord/messages"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(DataStorage:getDataDir() .. "/cache/discord")
        lfs.mkdir(dir)
    end
    return dir
end

--- Reads cached messages of a channel, or nil.
function ChatView.readCache(channel_id)
    local f = io.open(cacheDir() .. "/" .. channel_id .. ".json", "r")
    if not f then return nil end
    local ok, data = pcall(rapidjson.decode, f:read("*a"))
    f:close()
    if not ok or type(data) ~= "table" then return nil end
    return DiscordAPI.stripNulls(data)
end

--- Lists cached chats, newest first: { id, title, subtitle, guild_id, time }.
function ChatView.listCache()
    local list = {}
    local dir = cacheDir()
    for name in lfs.dir(dir) do
        local id = name:match("^(%d+)%.json$")
        if id then
            local data = ChatView.readCache(id)
            if data and data.meta then
                data.meta.time = lfs.attributes(dir .. "/" .. name, "modification") or 0
                table.insert(list, data.meta)
            end
        end
    end
    table.sort(list, function(a, b) return a.time > b.time end)
    return list
end

function ChatView:init()
    self.messages = {}
    self.by_id = {}
    self.reply_to = nil
    self.typing = {}
    self.mention_map = {}
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.font_size = self.settings.font_size or 20
    if self.guild then
        self.roles = {}
        for __, role in ipairs(self.guild.roles or {}) do
            self.roles[role.id] = role.name
        end
    end

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.PageNext = { { Device.input.group.PgFwd }, event = "TurnPage", args = 1 }
        self.key_events.PagePrev = { { Device.input.group.PgBack }, event = "TurnPage", args = -1 }
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
        subtitle = self.subtitle or "",
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:showMenu() end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    self.button_table = ButtonTable:new{
        width = self.width - 2 * Size.padding.default,
        buttons = {
            {
                { text = _("Older"), enabled = not self.offline, callback = function() self:loadOlder() end },
                { text = _("Refresh"), enabled = not self.offline, callback = function() self:refresh(true) end },
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

function ChatView:buildLayout(text, position)
    local padding = Size.padding.large
    local top_line_num
    if type(position) == "number" then top_line_num = position end
    self.scroll_widget = ScrollTextWidget:new{
        text = text,
        face = Font:getFace("x_smallinfofont", self.font_size),
        width = self.width - 2 * padding,
        height = self.text_height - 2 * padding,
        dialog = self,
        alignment = "left",
        justified = false,
        auto_para_direction = true,
        top_line_num = top_line_num,
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
    -- Count page turns (taps, swipes and keys all end up here) for the e-ink full refresh
    local scroll_text = self.scroll_widget.scrollText
    self.scroll_widget.scrollText = function(widget, direction)
        scroll_text(widget, direction)
        self:countPageTurn()
    end
    if position == "top" then
        self.scroll_widget:scrollToTop()
    elseif position == "middle" then
        self.scroll_widget:scrollToRatio(0.5)
    elseif position == nil or position == "bottom" then
        self.scroll_widget:scrollToBottom()
    end
end

function ChatView:isAtBottom()
    local tw = self.scroll_widget and self.scroll_widget.text_widget
    if not tw then return true end
    return tw.virtual_line_num + tw:getVisLineCount() > #tw.vertical_string_list
end

-- Message rendering

function ChatView:authorName(user)
    if not user then return "?" end
    local nick = self.guild and Gateway:nick(self.guild.id, user.id)
    return cleanEmoji(nick or user.global_name or user.username or "?")
end

function ChatView:renderContent(msg)
    local text = msg.content or ""
    local mentions = {}
    for __, u in ipairs(msg.mentions or {}) do
        mentions[u.id] = self:authorName(u)
    end
    text = text:gsub("<@!?(%d+)>", function(id)
        return "@" .. (mentions[id] or "user")
    end)
    text = text:gsub("<@&(%d+)>", function(id)
        local role = self.roles and self.roles[id]
        return "@" .. (role or "role")
    end)
    text = text:gsub("<#(%d+)>", function(id)
        local name = self.channel_names and self.channel_names[id]
        if not name and Gateway.channels[id] then name = Gateway.channels[id].name end
        return "#" .. cleanEmoji(name or "channel")
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
    -- Markdown headings and subtext
    text = ("\n" .. text):gsub("\n%-?#+ ", "\n"):sub(2)

    local extras = {}
    for __, snap in ipairs(msg.message_snapshots or {}) do
        if snap.message then
            local fwd = self:renderContent(snap.message)
            table.insert(extras, "» " .. _("forwarded:") .. " " .. fwd:gsub("\n", "\n   "))
        end
    end
    for __, a in ipairs(msg.attachments or {}) do
        local kind = (a.content_type or ""):match("^image/") and _("image") or _("file")
        table.insert(extras, "[" .. kind .. ": " .. (a.filename or "?") .. "]")
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
        table.insert(extras, self:renderPoll(msg.poll))
    end
    if #extras > 0 then
        text = (text ~= "" and (text .. "\n") or "") .. table.concat(extras, "\n")
    end
    if msg.edited_timestamp then
        text = text .. " " .. _("(edited)")
    end
    return cleanEmoji(text)
end

function ChatView:renderPoll(poll)
    local counts, mine = {}, {}
    for __, r in ipairs(poll.results and poll.results.answer_counts or {}) do
        counts[r.id] = r.count
        mine[r.id] = r.me_voted
    end
    local lines = { "[" .. _("poll") .. "] " .. (poll.question.text or "") }
    for i, a in ipairs(poll.answers or {}) do
        local label = a.poll_media and a.poll_media.text or "?"
        local n = counts[a.answer_id] or 0
        table.insert(lines, "   " .. i .. ". " .. label .. " — " .. (n == 1 and _("1 vote") or T(_("%1 votes"), n)) .. (mine[a.answer_id] and " *" or ""))
    end
    if poll.results and poll.results.is_finalized then
        table.insert(lines, "   " .. _("(closed)"))
    end
    return table.concat(lines, "\n")
end

function ChatView:votePoll(msg)
    local poll = msg.poll
    local dialog
    local buttons = {}
    local mine = {}
    for __, r in ipairs(poll.results and poll.results.answer_counts or {}) do
        if r.me_voted then mine[r.id] = true end
    end
    for i, a in ipairs(poll.answers or {}) do
        table.insert(buttons, {{
            text = i .. ". " .. cleanEmoji(a.poll_media and a.poll_media.text or "?") .. (mine[a.answer_id] and " *" or ""),
            callback = function()
                UIManager:close(dialog)
                local ok, err = self.api:votePoll(self.channel.id, msg.id, { a.answer_id })
                if not ok then
                    UIManager:show(InfoMessage:new{ text = _("Could not vote: ") .. tostring(err) })
                else
                    UIManager:show(Notification:new{ text = _("Vote sent") })
                end
            end,
        }})
    end
    if next(mine) then
        table.insert(buttons, {{
            text = _("Remove my vote"),
            callback = function()
                UIManager:close(dialog)
                local ok, err = self.api:votePoll(self.channel.id, msg.id, {})
                if not ok then UIManager:show(InfoMessage:new{ text = tostring(err) }) end
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = cleanEmoji(poll.question.text or _("Poll")), buttons = buttons }
    UIManager:show(dialog)
end

function ChatView:applyPollVote(d, delta)
    local m = self.by_id[d.message_id]
    if not (m and m.poll) then return end
    m.poll.results = m.poll.results or { answer_counts = {} }
    local counts = m.poll.results.answer_counts
    local is_me = Gateway.me and d.user_id == Gateway.me.id
    for __, r in ipairs(counts) do
        if r.id == d.answer_id then
            r.count = math.max(0, (r.count or 0) + delta)
            if is_me then r.me_voted = delta > 0 end
            self:redraw()
            return
        end
    end
    if delta > 0 then
        table.insert(counts, { id = d.answer_id, count = 1, me_voted = is_me })
        self:redraw()
    end
end

function ChatView:renderReactions(msg)
    if not msg.reactions or #msg.reactions == 0 then return nil end
    local parts = {}
    for __, r in ipairs(msg.reactions) do
        local e = r.emoji or {}
        local label = e.id and (":" .. (e.name or "?") .. ":") or cleanEmoji(e.name or "?")
        if label == "" then label = "?" end
        table.insert(parts, "[" .. label .. " " .. (r.count or 1) .. (r.me and "*" or "") .. "]")
    end
    return "   " .. table.concat(parts, " ")
end

function ChatView:buildText()
    local compact = self.settings.compact
    local out = {}
    local prev, prev_day
    local first_new = self:firstNewId()
    for __, msg in ipairs(self.messages) do
        local ts = parseTimestamp(msg.timestamp) or 0
        local day = os.date("%Y-%m-%d", ts)
        if day ~= prev_day then
            if not compact then table.insert(out, "") end
            table.insert(out, "═══════ " .. day .. " ═══════")
            prev_day = day
            prev = nil
        end
        if msg.id == first_new then
            if not compact then table.insert(out, "") end
            table.insert(out, self.NEW_MARKER)
            prev = nil
        end
        local author = self:authorName(msg.author)
        local system = SYSTEM_TYPES[msg.type]
        if system then
            if not compact then table.insert(out, "") end
            table.insert(out, "→ " .. author .. " " .. system .. "  " .. os.date("%H:%M", ts))
            prev = nil
        else
            local reply_line
            if msg.referenced_message then
                local ref = msg.referenced_message
                reply_line = "   ↪ " .. self:authorName(ref.author) .. ": " .. oneLine(self:renderContent(ref), 60)
            elseif msg.message_reference and msg.type == 19 then
                reply_line = "   ↪ " .. _("(deleted message)")
            end
            local content = self:renderContent(msg)
            if compact then
                if reply_line then table.insert(out, reply_line) end
                table.insert(out, os.date("%H:%M", ts) .. " " .. author .. ": " .. content)
            else
                local grouped = prev and not reply_line
                    and prev.author and msg.author and prev.author.id == msg.author.id
                    and ts - (parseTimestamp(prev.timestamp) or 0) < 420
                if not grouped then
                    table.insert(out, "")
                    table.insert(out, "▌" .. author .. " · " .. os.date("%H:%M", ts))
                end
                if reply_line then table.insert(out, reply_line) end
                if content ~= "" then table.insert(out, content) end
            end
            local reactions = self:renderReactions(msg)
            if reactions then table.insert(out, reactions) end
            prev = msg
        end
    end
    if #self.messages == 0 then
        table.insert(out, _("No messages yet."))
    end
    return table.concat(out, "\n")
end

--- Rebuilds the text. Keeps the reading position unless asked otherwise.
function ChatView:redraw(position)
    if position == nil and self.scroll_widget and not self:isAtBottom() then
        position = self.scroll_widget.text_widget.virtual_line_num
    end
    self:buildLayout(self:buildText(), position)
    if self.shown then
        UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    end
end

function ChatView:updateSubtitle()
    local names = {}
    local now = os.time()
    for uid, info in pairs(self.typing) do
        if info.until_time > now then
            table.insert(names, info.name)
        else
            self.typing[uid] = nil
        end
    end
    local subtitle = self.subtitle or ""
    if #names == 1 then
        subtitle = T(_("%1 is typing…"), names[1])
    elseif #names > 1 then
        subtitle = _("Several people are typing…")
    end
    if subtitle ~= self.shown_subtitle then
        self.shown_subtitle = subtitle
        self.titlebar:setSubTitle(subtitle)
    end
end

-- Data loading

function ChatView:addMessages(list)
    local added = 0
    for __, m in ipairs(list or {}) do
        if self.by_id[m.id] then
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

function ChatView:removeMessage(id)
    if not self.by_id[id] then return false end
    for i, m in ipairs(self.messages) do
        if m.id == id then table.remove(self.messages, i) break end
    end
    self.by_id[id] = nil
    return true
end

function ChatView:requestNicknames()
    if not self.guild then return end
    local ids, seen = {}, {}
    for __, m in ipairs(self.messages) do
        for __, u in ipairs({ m.author, m.referenced_message and m.referenced_message.author }) do
            if u and not seen[u.id] then
                seen[u.id] = true
                table.insert(ids, u.id)
            end
        end
    end
    Gateway:requestMembers(self.guild.id, ids)
end

function ChatView:load()
    if self.offline then
        local cached = ChatView.readCache(self.channel.id)
        if not cached then
            UIManager:show(InfoMessage:new{ text = _("This chat is not available offline.") })
            return false
        end
        self.messages, self.by_id = {}, {}
        self:addMessages(cached.messages)
        self:redraw("bottom")
        return true
    end
    local opts = { limit = self.settings.page_size or 50, around = self.around_id }
    local ok, data = self.api:getMessages(self.channel.id, opts)
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Could not load messages: ") .. tostring(data) })
        return false
    end
    -- Remember where we stopped reading, for the "New" separator
    if not self.around_id and self.new_after == nil then
        local rs = Gateway.read_states[self.channel.id]
        self.new_after = rs and rs.last_message_id or false
    end
    self.messages, self.by_id = {}, {}
    self:addMessages(data)
    if self.around_id then
        self:redraw("middle")
    else
        self:redraw("bottom")
        self:scrollToNew()
        self:markRead()
        self:saveCache()
    end
    self:requestNicknames()
    return true
end

--- Id of the first unread message not written by us, if it is loaded.
function ChatView:firstNewId()
    if not self.new_after then return nil end
    local me = Gateway.me and Gateway.me.id
    for __, m in ipairs(self.messages) do
        if idLess(self.new_after, m.id) and not (m.author and m.author.id == me) then
            return m.id
        end
    end
end

function ChatView:scrollToNew()
    local text = self.scroll_widget.text_widget.text or ""
    local pos = text:find(self.NEW_MARKER, 1, true)
    if not pos then return end
    -- TextBoxWidget positions count characters, not bytes
    local charpos = #util.splitToChars(text:sub(1, pos - 1)) + 1
    local line = self.scroll_widget:getCharPosLineNum(charpos)
    if line then
        self:buildLayout(text, math.max(1, line - 1))
    end
end

function ChatView:saveCache()
    if self.offline or #self.messages == 0 then return end
    local keep = {}
    for i = math.max(1, #self.messages - 49), #self.messages do
        table.insert(keep, self.messages[i])
    end
    local ok, json = pcall(rapidjson.encode, {
        meta = self:favoriteEntry(),
        messages = keep,
    })
    if not ok then return end
    local dir = cacheDir()
    local f = io.open(dir .. "/" .. self.channel.id .. ".json", "w")
    if not f then return end
    f:write(json)
    f:close()
    -- Drop the oldest cached chats
    local files = {}
    for name in lfs.dir(dir) do
        if name:match("%.json$") then
            table.insert(files, { name = name, time = lfs.attributes(dir .. "/" .. name, "modification") or 0 })
        end
    end
    table.sort(files, function(a, b) return a.time > b.time end)
    for i = CACHE_KEEP + 1, #files do
        os.remove(dir .. "/" .. files[i].name)
    end
end

function ChatView:markRead()
    local last = self.messages[#self.messages]
    if not last or last.id == self.acked_id then return end
    self.acked_id = last.id
    Gateway:markRead(self.channel.id, last.id)
    if self.settings.mark_read ~= false then
        self.api:ackMessage(self.channel.id, last.id)
    end
end

--- Fetches messages newer than the last one we have. Returns the number added.
function ChatView:catchUp()
    local last = self.messages[#self.messages]
    if not last then return 0 end
    local ok, data, complete = self.api:getMessagesAfter(self.channel.id, last.id, 5)
    if not ok then return 0 end
    if not complete then
        -- Too far behind: start again from the latest messages
        self.messages, self.by_id = {}, {}
        local ok2, latest = self.api:getMessages(self.channel.id, { limit = self.settings.page_size or 50 })
        if ok2 then self:addMessages(latest) end
        return #self.messages
    end
    return self:addMessages(data)
end

function ChatView:refresh(manual)
    if manual then
        -- Full reload, also picks up edits and deletions
        UIManager:show(Notification:new{ text = _("Refreshing…") })
        UIManager:nextTick(function()
            self.around_id = nil
            self:load()
        end)
        return
    end
    if self.around_id then return end
    if self:catchUp() > 0 then
        local at_bottom = self:isAtBottom()
        self:redraw(at_bottom and "bottom" or nil)
        self:markRead()
        self:requestNicknames()
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
    self:requestNicknames()
end

-- Live updates: gateway events, with polling as a fallback

function ChatView:pollInterval()
    local interval = self.settings.poll_interval or 15
    if interval > 0 and self.plugin and self.plugin:isBatteryLow() then
        interval = interval * 4
    end
    return interval
end

function ChatView:schedulePoll()
    local interval = self:pollInterval()
    if interval <= 0 then return end
    self._poll = self._poll or function()
        if self.closed then return end
        if not Gateway:isReady() and NetworkMgr:isOnline() then
            local ok, err = pcall(self.refresh, self)
            if not ok then logger.warn("Discord: poll failed", err) end
        end
        self:updateSubtitle()
        self:schedulePoll()
    end
    UIManager:unschedule(self._poll)
    UIManager:scheduleIn(Gateway:isReady() and 5 or interval, self._poll)
end

function ChatView:subscribe()
    local cid = self.channel.id
    local function mine(d) return d and d.channel_id == cid end
    self.handlers = {
        MESSAGE_CREATE = function(d)
            if not mine(d) or self.around_id then return end
            local at_bottom = self:isAtBottom()
            if self:addMessages({ d }) > 0 then
                if d.author then self.typing[d.author.id] = nil end
                self:updateSubtitle()
                self:redraw(at_bottom and "bottom" or nil)
                self:markRead()
                self:requestNicknames()
            end
        end,
        MESSAGE_UPDATE = function(d)
            if not mine(d) then return end
            local m = self.by_id[d.id]
            if not m then return end
            for k, val in pairs(d) do m[k] = val end
            self:redraw()
        end,
        MESSAGE_DELETE = function(d)
            if mine(d) and self:removeMessage(d.id) then self:redraw() end
        end,
        MESSAGE_REACTION_ADD = function(d)
            if not mine(d) then return end
            local m = self.by_id[d.message_id]
            if not m then return end
            m.reactions = m.reactions or {}
            local is_me = Gateway.me and d.user_id == Gateway.me.id
            for __, r in ipairs(m.reactions) do
                if r.emoji and r.emoji.name == d.emoji.name and r.emoji.id == d.emoji.id then
                    if not (is_me and r.me) then r.count = (r.count or 0) + 1 end
                    if is_me then r.me = true end
                    self:redraw()
                    return
                end
            end
            table.insert(m.reactions, { emoji = d.emoji, count = 1, me = is_me })
            self:redraw()
        end,
        MESSAGE_REACTION_REMOVE = function(d)
            if not mine(d) then return end
            local m = self.by_id[d.message_id]
            if not m or not m.reactions then return end
            local is_me = Gateway.me and d.user_id == Gateway.me.id
            for i, r in ipairs(m.reactions) do
                if r.emoji and r.emoji.name == d.emoji.name and r.emoji.id == d.emoji.id then
                    if is_me and not r.me then return end
                    r.count = (r.count or 1) - 1
                    if is_me then r.me = false end
                    if r.count <= 0 then table.remove(m.reactions, i) end
                    self:redraw()
                    return
                end
            end
        end,
        TYPING_START = function(d)
            if not mine(d) or (Gateway.me and d.user_id == Gateway.me.id) then return end
            local user = (d.member and d.member.user) or Gateway.users[d.user_id] or { id = d.user_id }
            local name = (d.member and d.member.nick) or self:authorName(user)
            self.typing[d.user_id] = { name = cleanEmoji(name), until_time = os.time() + 10 }
            self:updateSubtitle()
        end,
        MESSAGE_POLL_VOTE_ADD = function(d)
            if mine(d) then self:applyPollVote(d, 1) end
        end,
        MESSAGE_POLL_VOTE_REMOVE = function(d)
            if mine(d) then self:applyPollVote(d, -1) end
        end,
        GUILD_MEMBERS_CHUNK = function(d)
            if self.guild and d.guild_id == self.guild.id and not d.nonce then
                self:redraw()
            end
        end,
        ready = function()
            -- Fresh session (not a resume): fetch whatever we missed
            if self.around_id then return end
            if self:catchUp() > 0 then
                self:redraw("bottom")
                self:markRead()
            end
        end,
    }
    for name, fn in pairs(self.handlers) do Gateway:on(name, fn) end
    Gateway:setForeground(true)
    if self.guild then Gateway:subscribeGuild(self.guild.id) end
end

function ChatView:unsubscribe()
    if not self.handlers then return end
    for name, fn in pairs(self.handlers) do Gateway:off(name, fn) end
    self.handlers = nil
    Gateway:setForeground(false)
end

function ChatView:onShow()
    self.shown = true
    UIManager:setDirty(self, function() return "full", self.frame.dimen end)
    if self.offline then return end
    self:subscribe()
    self:schedulePoll()
end

function ChatView:onResume()
    if not self.closed then self:schedulePoll() end
end

function ChatView:onSuspend()
    if self._poll then UIManager:unschedule(self._poll) end
end

function ChatView:onClose()
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

function ChatView:onCloseWidget()
    self.closed = true
    self:saveCache()
    if self._poll then UIManager:unschedule(self._poll) end
    self:unsubscribe()
    UIManager:setDirty(nil, "full")
end

function ChatView:onSwipe(arg, ges)
    -- Like in a book: swipe left for the next page, right for the previous one
    if ges.direction == "west" then
        return self:onTurnPage(1)
    elseif ges.direction == "east" then
        return self:onTurnPage(-1)
    end
end

function ChatView:onTurnPage(direction)
    if direction > 0 then
        self.scroll_widget:onScrollDown()
    else
        self.scroll_widget:onScrollUp()
    end
    return true
end

--- Every N page turns, flash the screen to clean e-ink ghosting (0 = never).
function ChatView:countPageTurn()
    local every = self.settings.full_refresh_pages or 6
    if every <= 0 then return end
    self.page_turns = (self.page_turns or 0) + 1
    if self.page_turns >= every then
        self.page_turns = 0
        UIManager:setDirty(self, "full")
    end
end

-- Sending

function ChatView:sendTyping()
    local now = os.time()
    if self.last_typing and now - self.last_typing < 8 then return end
    self.last_typing = now
    pcall(self.api.sendTyping, self.api, self.channel.id)
end

function ChatView:compose(prefill, edit_msg)
    local title
    if edit_msg then
        title = _("Edit message")
    elseif self.reply_to then
        title = _("Reply to ") .. self:authorName(self.reply_to.author)
    else
        title = self.title
    end
    local dialog
    local row = {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                if not edit_msg then
                    self:setDraft(dialog:getInputText())
                    self.reply_to = nil
                end
                UIManager:close(dialog)
            end,
        },
    }
    if not edit_msg then
        table.insert(row, {
            text = _("Quick"),
            callback = function() self:pickQuickReply(dialog) end,
        })
        table.insert(row, {
            text = "@",
            callback = function() self:pickMention(dialog) end,
        })
    end
    table.insert(row, {
        text = edit_msg and _("Save") or _("Send"),
        is_enter_default = true,
        callback = function()
            local text = dialog:getInputText()
            if text:match("^%s*$") then return end
            UIManager:close(dialog)
            self:send(text, edit_msg)
        end,
    })
    dialog = InputDialog:new{
        title = title,
        description = self.reply_to and not edit_msg and oneLine(self:renderContent(self.reply_to), 80) or nil,
        input = prefill or self:getDraft() or "",
        allow_newline = true,
        text_height = Screen:scaleBySize(120),
        buttons = { row },
        edited_callback = not edit_msg and function() self:sendTyping() end or nil,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ChatView:getDraft()
    local drafts = self.settings.drafts
    return drafts and drafts[self.channel.id]
end

--- Stores unsent text for this channel (saved with the plugin settings).
function ChatView:setDraft(text)
    if text and text:match("^%s*$") then text = nil end
    self.settings.drafts = self.settings.drafts or {}
    self.settings.drafts[self.channel.id] = text
end

--- Turns "@Name" written with the mention picker into real mentions.
function ChatView:applyMentions(text)
    for name, id in pairs(self.mention_map) do
        text = text:gsub("@" .. name:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"), "<@" .. id .. ">")
    end
    return text
end

function ChatView:send(text, edit_msg)
    local ok, data
    if edit_msg then
        ok, data = self.api:editMessage(self.channel.id, edit_msg.id, self:applyMentions(text))
    else
        local reply = self.reply_to
        if reply then reply.guild_id = self.guild and self.guild.id end
        ok, data = self.api:sendMessage(self.channel.id, self:applyMentions(text), reply)
    end
    if not ok then
        if not edit_msg then self:setDraft(text) end
        UIManager:show(InfoMessage:new{ text = _("Could not send: ") .. tostring(data) })
        return
    end
    if not edit_msg then self:setDraft(nil) end
    self.reply_to = nil
    self.last_typing = nil
    self:addMessages({ data })
    self:redraw("bottom")
    self:markRead()
end

function ChatView:pickQuickReply(input_dialog)
    input_dialog:onCloseKeyboard()
    local replies = self.settings.quick_replies or self.plugin.DEFAULT_QUICK_REPLIES
    local dialog
    local buttons = {}
    for __, reply in ipairs(replies) do
        table.insert(buttons, {{
            text = cleanEmoji(reply) ~= "" and cleanEmoji(reply) or reply,
            callback = function()
                UIManager:close(dialog)
                insertText(input_dialog, reply)
            end,
        }})
    end
    if #buttons == 0 then
        table.insert(buttons, {{ text = _("No quick replies. Add some in Settings."), enabled = false }})
    end
    dialog = ButtonDialog:new{ title = _("Quick replies"), buttons = buttons }
    UIManager:show(dialog)
end

function ChatView:insertMention(input_dialog, user)
    local name = (self:authorName(user)):gsub("%s", "_")
    self.mention_map[name] = user.id
    insertText(input_dialog, "@" .. name .. " ")
end

function ChatView:pickMention(input_dialog)
    input_dialog:onCloseKeyboard()
    local people, seen = {}, {}
    local me = Gateway.me and Gateway.me.id or (self.api.user and self.api.user.id)
    for i = #self.messages, 1, -1 do
        local u = self.messages[i].author
        if u and not seen[u.id] and u.id ~= me then
            seen[u.id] = true
            table.insert(people, u)
        end
    end
    for __, u in ipairs(self.channel.recipients or {}) do
        if not seen[u.id] then
            seen[u.id] = true
            table.insert(people, u)
        end
    end
    local dialog
    local buttons = {}
    for i = 1, math.min(#people, 8) do
        local u = people[i]
        table.insert(buttons, {{
            text = self:authorName(u),
            callback = function()
                UIManager:close(dialog)
                self:insertMention(input_dialog, u)
            end,
        }})
    end
    if self.guild then
        table.insert(buttons, {{
            text = _("Search members…"),
            callback = function()
                UIManager:close(dialog)
                self:searchMembers(input_dialog)
            end,
        }})
    end
    if #buttons == 0 then
        table.insert(buttons, {{ text = _("No one to mention yet."), enabled = false }})
    end
    dialog = ButtonDialog:new{ title = _("Mention"), buttons = buttons }
    UIManager:show(dialog)
end

function ChatView:searchMembers(input_dialog)
    local query_dialog
    query_dialog = InputDialog:new{
        title = _("Search members"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(query_dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = util.trim(query_dialog:getInputText())
                    UIManager:close(query_dialog)
                    if query == "" then return end
                    local nonce = tostring(os.time()) .. tostring(math.random(1000, 9999))
                    local handler
                    handler = Gateway:on("GUILD_MEMBERS_CHUNK", function(d)
                        if d.nonce ~= nonce then return end
                        Gateway:off("GUILD_MEMBERS_CHUNK", handler)
                        local dialog
                        local buttons = {}
                        for __, m in ipairs(d.members or {}) do
                            local u = m.user
                            local label = cleanEmoji(m.nick or u.global_name or u.username) .. " (" .. u.username .. ")"
                            table.insert(buttons, {{
                                text = label,
                                callback = function()
                                    UIManager:close(dialog)
                                    self:insertMention(input_dialog, u)
                                end,
                            }})
                        end
                        if #buttons == 0 then
                            table.insert(buttons, {{ text = _("No results"), enabled = false }})
                        end
                        dialog = ButtonDialog:new{ title = _("Mention"), buttons = buttons }
                        UIManager:show(dialog)
                    end)
                    if not Gateway:searchMembers(self.guild.id, query, nonce) then
                        Gateway:off("GUILD_MEMBERS_CHUNK", handler)
                        UIManager:show(InfoMessage:new{ text = _("Member search needs the real-time connection.") })
                    end
                end,
            },
        }},
    }
    UIManager:show(query_dialog)
    query_dialog:onShowKeyboard()
end

-- Message lists (picker, pins, search results)

function ChatView:showMessageList(title, list, on_choose)
    local items = {}
    for __, m in ipairs(list) do
        local ts = parseTimestamp(m.timestamp) or 0
        table.insert(items, {
            text = self:authorName(m.author) .. ": " .. oneLine(self:renderContent(m), 120),
            mandatory = os.date("%m-%d %H:%M", ts),
            msg = m,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("No messages"), select_enabled = false })
    end
    local menu
    menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        items_max_lines = 3,
        onMenuSelect = function(_menu, item)
            if item.msg then on_choose(item.msg, menu) end
            return true
        end,
    }
    menu.close_callback = function() UIManager:close(menu) end
    UIManager:show(menu)
    return menu
end

function ChatView:pickMessage()
    local list = {}
    for i = #self.messages, 1, -1 do table.insert(list, self.messages[i]) end
    self:showMessageList(_("Choose a message"), list, function(msg, menu)
        UIManager:close(menu)
        self:messageActions(msg)
    end)
end

function ChatView:showPins()
    self.plugin:withLoading(_("Loading pinned messages…"), function()
        local ok, list = self.api:getPins(self.channel.id)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Could not load pinned messages: ") .. tostring(list) })
            return
        end
        self:showMessageList(_("Pinned messages"), list, function(msg, menu)
            self:resultActions(msg, menu)
        end)
    end)
end

function ChatView:search()
    local dialog
    dialog = InputDialog:new{
        title = _("Search in this channel"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = util.trim(dialog:getInputText())
                    UIManager:close(dialog)
                    if query == "" then return end
                    self.plugin:withLoading(_("Searching…"), function()
                        local ok, list, total = self.api:searchMessages(self.channel.id, self.guild and self.guild.id, query)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = tostring(list) })
                            return
                        end
                        self:showMessageList(T(_("Results for «%1» (%2)"), query, total or #list), list, function(msg, menu)
                            self:resultActions(msg, menu)
                        end)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Actions for a message found in pins or search results.
function ChatView:resultActions(msg, list_menu)
    local dialog
    dialog = ButtonDialog:new{
        title = self:authorName(msg.author) .. ": " .. oneLine(self:renderContent(msg), 100),
        buttons = {
            {
                {
                    text = _("View full"),
                    callback = function()
                        UIManager:close(dialog)
                        self:viewFull(msg)
                    end,
                },
                {
                    text = _("Jump to message"),
                    callback = function()
                        UIManager:close(dialog)
                        if list_menu then UIManager:close(list_menu) end
                        self:jumpTo(msg.id)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ChatView:jumpTo(message_id)
    self.plugin:withLoading(_("Loading messages…"), function()
        self.around_id = message_id
        if not self:load() then self.around_id = nil end
        UIManager:show(Notification:new{ text = _("Showing older messages. Use Refresh to go back to the latest.") })
    end)
end

function ChatView:viewFull(msg)
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = self:authorName(msg.author),
        text = self:renderContent(msg),
    })
end

-- Images

function ChatView:imagesOf(msg)
    local images = {}
    local function add(url, name, w, h)
        if url then table.insert(images, { url = url, name = name or "image", width = w, height = h }) end
    end
    for __, a in ipairs(msg.attachments or {}) do
        if (a.content_type or ""):match("^image/") or a.width then
            add(a.proxy_url or a.url, a.filename, a.width, a.height)
        end
    end
    for __, e in ipairs(msg.embeds or {}) do
        if e.image then add(e.image.proxy_url or e.image.url, e.title or "embed", e.image.width, e.image.height) end
        if e.thumbnail and not e.image then
            add(e.thumbnail.proxy_url or e.thumbnail.url, e.title or "embed", e.thumbnail.width, e.thumbnail.height)
        end
    end
    for __, s in ipairs(msg.sticker_items or {}) do
        if s.format_type == 1 or s.format_type == 2 then
            add("https://media.discordapp.net/stickers/" .. s.id .. ".png?size=320", s.name)
        end
    end
    for __, snap in ipairs(msg.message_snapshots or {}) do
        if snap.message then
            for __, img in ipairs(self:imagesOf(snap.message)) do table.insert(images, img) end
        end
    end
    return images
end

function ChatView:showImage(img)
    local dir = DataStorage:getDataDir() .. "/cache/discord"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(dir)
    end
    -- Ask the media proxy for a small grayscale-friendly JPEG that fits the screen
    local url = img.url
    if url:match("^https://media%.discordapp%.net/") or url:match("^https://images%-ext%-%d%.discordapp%.net/") then
        local sep = url:find("?", 1, true) and "&" or "?"
        url = url .. sep .. "format=jpeg&width=" .. Screen:getWidth() .. "&height=" .. Screen:getHeight()
    end
    local path = dir .. "/" .. (url:gsub("[^%w]", ""):sub(-60)) .. ".jpg"
    self.plugin:withLoading(_("Downloading image…"), function()
        if lfs.attributes(path, "mode") ~= "file" then
            local ok, err = self.api:download(url, path)
            if not ok then
                UIManager:show(InfoMessage:new{ text = _("Could not download the image: ") .. tostring(err) })
                return
            end
        end
        local ImageViewer = require("ui/widget/imageviewer")
        UIManager:show(ImageViewer:new{
            file = path,
            fullscreen = true,
            with_title_bar = true,
            title_text = img.name,
        })
    end)
end

function ChatView:showImages(images)
    if #images == 1 then
        self:showImage(images[1])
        return
    end
    local dialog
    local buttons = {}
    for i, img in ipairs(images) do
        table.insert(buttons, {{
            text = i .. ". " .. img.name,
            callback = function()
                UIManager:close(dialog)
                self:showImage(img)
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = _("Images"), buttons = buttons }
    UIManager:show(dialog)
end

-- Reactions

function ChatView:toggleReaction(msg, emoji, remove)
    local ok, err
    if remove then
        ok, err = self.api:removeReaction(self.channel.id, msg.id, emoji)
    else
        ok, err = self.api:addReaction(self.channel.id, msg.id, emoji)
    end
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Could not react: ") .. tostring(err) })
        return
    end
    if Gateway:isReady() then return end -- the gateway event updates the view
    msg.reactions = msg.reactions or {}
    for i, r in ipairs(msg.reactions) do
        if r.emoji.name == emoji.name and r.emoji.id == emoji.id then
            r.count = (r.count or 1) + (remove and -1 or 1)
            r.me = not remove
            if r.count <= 0 then table.remove(msg.reactions, i) end
            self:redraw()
            return
        end
    end
    if not remove then
        table.insert(msg.reactions, { emoji = emoji, count = 1, me = true })
        self:redraw()
    end
end

function ChatView:reactDialog(msg)
    local dialog
    local buttons = {}
    local row = {}
    for __, e in ipairs(QUICK_REACTIONS) do
        table.insert(row, {
            text = cleanEmoji(e),
            callback = function()
                UIManager:close(dialog)
                self:toggleReaction(msg, { name = e })
            end,
        })
        if #row == 4 then
            table.insert(buttons, row)
            row = {}
        end
    end
    if #row > 0 then table.insert(buttons, row) end
    for __, r in ipairs(msg.reactions or {}) do
        local e = r.emoji or {}
        local label = e.id and (":" .. (e.name or "?") .. ":") or cleanEmoji(e.name or "?")
        table.insert(buttons, {{
            text = (r.me and _("Remove") or _("Add")) .. " " .. label .. " (" .. (r.count or 1) .. ")",
            callback = function()
                UIManager:close(dialog)
                self:toggleReaction(msg, { name = e.name, id = e.id }, r.me)
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = _("React"), buttons = buttons }
    UIManager:show(dialog)
end

-- Per-message actions

function ChatView:linksOf(msg)
    local links, seen = {}, {}
    local function add(url)
        if url and not seen[url] then
            seen[url] = true
            table.insert(links, url)
        end
    end
    for url in (msg.content or ""):gmatch("https?://[^%s<>%)]+") do add(url) end
    for __, e in ipairs(msg.embeds or {}) do add(e.url) end
    for __, a in ipairs(msg.attachments or {}) do
        if not (a.content_type or ""):match("^image/") then add(a.url) end
    end
    return links
end

function ChatView:showLinks(links)
    local QRMessage = require("ui/widget/qrmessage")
    local function show(url)
        UIManager:show(QRMessage:new{
            text = url,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
        })
    end
    if #links == 1 then
        show(links[1])
        return
    end
    local dialog
    local buttons = {}
    for __, url in ipairs(links) do
        table.insert(buttons, {{
            text = oneLine(url, 60),
            callback = function()
                UIManager:close(dialog)
                show(url)
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = _("Show link as QR code"), buttons = buttons }
    UIManager:show(dialog)
end

function ChatView:messageActions(msg)
    local me = Gateway.me and Gateway.me.id or (self.api.user and self.api.user.id)
    local mine = msg.author and msg.author.id == me
    local images = self:imagesOf(msg)
    local links = self:linksOf(msg)
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
                text = _("React"),
                callback = function()
                    UIManager:close(dialog)
                    self:reactDialog(msg)
                end,
            },
        },
        {
            {
                text = _("View full"),
                callback = function()
                    UIManager:close(dialog)
                    self:viewFull(msg)
                end,
            },
            {
                text = #images > 0 and T(_("View images (%1)"), #images) or _("No images"),
                enabled = #images > 0,
                callback = function()
                    UIManager:close(dialog)
                    self:showImages(images)
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
                enabled = not mine and self.guild ~= nil,
                callback = function()
                    UIManager:close(dialog)
                    self.plugin:openDMWith(msg.author)
                end,
            },
        },
        {
            {
                text = #links > 0 and T(_("Links as QR (%1)"), #links) or _("No links"),
                enabled = #links > 0,
                callback = function()
                    UIManager:close(dialog)
                    self:showLinks(links)
                end,
            },
            {
                text = _("Vote"),
                enabled = msg.poll ~= nil and not (msg.poll.results and msg.poll.results.is_finalized),
                callback = function()
                    UIManager:close(dialog)
                    self:votePoll(msg)
                end,
            },
        },
    }
    if self.offline then
        -- Only reading actions make sense without network
        buttons = { buttons[2], { buttons[3][1] }, { buttons[4][1] } }
    end
    if mine and not self.offline then
        table.insert(buttons, {
            {
                text = _("Edit"),
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
                                self:removeMessage(msg.id)
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
        title = self:authorName(msg.author) .. ": " .. oneLine(self:renderContent(msg), 100),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Threads

function ChatView:showThreads()
    local parent_id = THREAD_TYPES[self.channel.type] and self.channel.parent_id or self.channel.id
    self.plugin:openThreadList(parent_id, self.guild, self.channel_names)
end

function ChatView:showMenu()
    local is_fav = self.plugin:isFavorite(self.channel.id)
    local dialog
    local function close() UIManager:close(dialog) end
    dialog = ButtonDialog:new{
        buttons = {
            {
                {
                    text = _("Go to bottom"),
                    callback = function()
                        close()
                        self.scroll_widget:scrollToBottom()
                        UIManager:setDirty(self, "ui")
                    end,
                },
                {
                    text = _("Go to top"),
                    callback = function()
                        close()
                        self.scroll_widget:scrollToTop()
                        UIManager:setDirty(self, "ui")
                    end,
                },
            },
            {
                {
                    text = _("Pinned messages"),
                    callback = function() close() self:showPins() end,
                },
                {
                    text = _("Search"),
                    callback = function() close() self:search() end,
                },
            },
            {
                {
                    text = _("Threads"),
                    enabled = self.guild ~= nil,
                    callback = function() close() self:showThreads() end,
                },
                {
                    text = is_fav and _("Remove favorite") or _("Add to favorites"),
                    callback = function()
                        close()
                        self.plugin:toggleFavorite(self:favoriteEntry())
                    end,
                },
            },
            {
                {
                    text = Gateway:isMuted(Gateway.channels[self.channel.id]) and _("Unmute channel") or _("Mute channel"),
                    enabled = not self.offline,
                    callback = function()
                        close()
                        self.plugin:toggleMute(self.guild and self.guild.id, self.channel.id)
                    end,
                },
                {
                    text = _("Jump to new messages"),
                    enabled = self:firstNewId() ~= nil,
                    callback = function()
                        close()
                        self:redraw("bottom")
                        self:scrollToNew()
                        UIManager:setDirty(self, "ui")
                    end,
                },
            },
            {
                {
                    text = _("Open as document"),
                    callback = function()
                        close()
                        self.plugin:openAsDocument(self)
                    end,
                },
                {
                    text = self.settings.compact and _("Normal layout") or _("Compact layout"),
                    callback = function()
                        close()
                        self.settings.compact = not self.settings.compact
                        self:redraw()
                    end,
                },
            },
            {
                {
                    text = _("Smaller text"),
                    callback = function()
                        close()
                        self.font_size = math.max(12, self.font_size - 2)
                        self.settings.font_size = self.font_size
                        self:redraw()
                    end,
                },
                {
                    text = _("Larger text"),
                    callback = function()
                        close()
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

--- What to store in favorites and recents to reopen this chat later.
function ChatView:favoriteEntry()
    return {
        id = self.channel.id,
        guild_id = self.guild and self.guild.id,
        title = self.title,
        subtitle = self.subtitle,
    }
end

ChatView.parseTimestamp = parseTimestamp

return ChatView
