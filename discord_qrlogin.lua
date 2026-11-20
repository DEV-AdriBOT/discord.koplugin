--[[--
Full-screen QR code login screen. main.lua drives the remote-auth session
(discord_remoteauth) and calls setQR() / setStatus(); this widget only displays.

@module koplugin.discord.qrlogin
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("discord_i18n")
local Screen = Device.screen

local QRLogin = InputContainer:extend{
    covers_fullscreen = true,
    cancel_callback = nil,
    url = nil,
    status = nil,
}

function QRLogin:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.status = self.status or _("Connecting to Discord…")
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:_build()
end

function QRLogin:_build()
    local inner_w = self.width - 2 * Size.padding.large
    local title_bar = TitleBar:new{
        width = self.width,
        fullscreen = true,
        with_bottom_line = true,
        title = _("Log in with QR code"),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local face = Font:getFace("cfont", 18)
    local steps = TextBoxWidget:new{
        text = _("1. Open Discord on your phone.\n2. Go to Settings → Scan QR Code.\n3. Scan this code and approve the login."),
        face = face,
        width = inner_w,
    }
    local status = TextBoxWidget:new{
        text = self.status,
        face = Font:getFace("cfont", 20),
        bold = true,
        width = inner_w,
        alignment = "center",
    }
    local avail = self.height - title_bar:getHeight() - steps:getSize().h - status:getSize().h - 6 * Size.padding.large
    local qr_size = math.min(inner_w, avail)
    local qr
    if self.url then
        qr = QRWidget:new{ text = self.url, width = qr_size, height = qr_size }
    else
        qr = VerticalSpan:new{ width = qr_size }
    end
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        width = self.width, height = self.height,
        VerticalGroup:new{
            align = "center",
            title_bar,
            VerticalSpan:new{ width = Size.padding.large },
            CenterContainer:new{ dimen = Geom:new{ w = self.width, h = steps:getSize().h }, steps },
            VerticalSpan:new{ width = Size.padding.large },
            CenterContainer:new{ dimen = Geom:new{ w = self.width, h = qr_size }, qr },
            VerticalSpan:new{ width = Size.padding.large },
            CenterContainer:new{ dimen = Geom:new{ w = self.width, h = status:getSize().h }, status },
        },
    }
end

function QRLogin:onShow()
    UIManager:setDirty(self, function()
        return "full", self.dimen
    end)
    return true
end

function QRLogin:setQR(url)
    self.url = url
    self.status = _("Waiting for you to scan the code…")
    self:_build()
    UIManager:setDirty(self, "full")
end

function QRLogin:setStatus(text)
    self.status = text
    self:_build()
    UIManager:setDirty(self, "ui")
end

function QRLogin:onClose()
    UIManager:close(self)
    if self.cancel_callback then
        local cb = self.cancel_callback
        self.cancel_callback = nil
        cb()
    end
    return true
end

function QRLogin:dismiss()
    self.cancel_callback = nil
    UIManager:close(self)
end

return QRLogin
