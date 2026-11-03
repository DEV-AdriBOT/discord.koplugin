--[[--
Optional counter of unread mentions and DMs in the reader's status bar.
]]

local Event = require("ui/event")
local Gateway = require("discord_gateway")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local StatusBar = {
    footer = nil, -- footer we registered in
    fn = nil,
}

--- Text for the status bar, or nil when there is nothing unread.
function StatusBar.text()
    if not Gateway:hasState() then return nil end
    local mentions = 0
    for __, gid in ipairs(Gateway.guild_order) do
        local __, m = Gateway:guildUnread(gid)
        mentions = mentions + (m or 0)
    end
    local dms, dm_mentions = Gateway:dmUnread()
    mentions = mentions + dm_mentions
    local parts = {}
    if mentions > 0 then table.insert(parts, "@" .. mentions) end
    if dms > 0 then table.insert(parts, "DM " .. dms) end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

--- Adds the counter to the footer of the reader `ui`.
function StatusBar.attach(ui)
    StatusBar.detach()
    local footer = ui and ui.view and ui.view.footer
    if not footer or not footer.addAdditionalFooterContent then return false end
    StatusBar.footer = footer
    StatusBar.fn = function() return StatusBar.text() end
    -- Adding content renumbers the footer's modes: keep showing the one the reader had
    local mode_name = footer.mode_index and footer.mode_index[footer.mode]
    footer:addAdditionalFooterContent(StatusBar.fn)
    if mode_name and footer.mode_list and footer.mode_list[mode_name] and footer.applyFooterMode then
        pcall(footer.applyFooterMode, footer, footer.mode_list[mode_name])
    end
    StatusBar.refresh()
    return true
end

function StatusBar.detach()
    if StatusBar.footer and StatusBar.fn then
        pcall(StatusBar.footer.removeAdditionalFooterContent, StatusBar.footer, StatusBar.fn)
    end
    StatusBar.footer, StatusBar.fn = nil, nil
end

--- Redraws the footer (at most once a second, so bursts of messages do not flash the screen).
function StatusBar.refresh()
    if not StatusBar.fn then return end
    StatusBar._refresh = StatusBar._refresh or function()
        local ok, err = pcall(function() UIManager:broadcastEvent(Event:new("RefreshAdditionalContent")) end)
        if not ok then logger.warn("Discord: status bar refresh failed", err) end
    end
    UIManager:unschedule(StatusBar._refresh)
    UIManager:scheduleIn(1, StatusBar._refresh)
end

return StatusBar
