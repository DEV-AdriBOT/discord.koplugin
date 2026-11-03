--[[--
Share the page being read, as an image, in a chat.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("discord_i18n")
local T = require("ffi/util").template

local Share = {}

local function shotPath()
    local dir = DataStorage:getDataDir() .. "/cache/discord"
    lfs.mkdir(DataStorage:getDataDir() .. "/cache")
    lfs.mkdir(dir)
    return dir .. "/page.png"
end

--- Takes a screenshot of the page (after the menu has closed), then asks where to send it.
function Share.page(plugin)
    local path = shotPath()
    UIManager:scheduleIn(1.5, function()
        local ok = pcall(function() Device.screen:shot(path) end)
        if not ok or lfs.attributes(path, "mode") ~= "file" then
            UIManager:show(InfoMessage:new{ text = _("Could not take the screenshot.") })
            return
        end
        plugin:pickDestination(_("Send the page to…"), function(entry)
            plugin:withLoading(_("Sending…"), function()
                local title = plugin.ui and plugin.ui.doc_props and plugin.ui.doc_props.display_title
                local ok_send, err = plugin.api:uploadFile(entry.id, path, "page.png", title, "image/png")
                os.remove(path)
                if ok_send then
                    UIManager:show(Notification:new{ text = T(_("Sent to %1"), entry.title or "?") })
                else
                    UIManager:show(InfoMessage:new{ text = _("Could not send: ") .. tostring(err) })
                end
            end)
        end)
    end)
end

return Share
