--[[--
"Report a problem": prepares a report without private data and shows it as
a QR code with the URL of a pre-filled GitHub issue (e-readers have no
browser). A full copy is saved to a file in KOReader's folder.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Update = require("discord_update")
local _ = require("discord_i18n")
local T = require("ffi/util").template

local Report = {}

local ISSUES_URL = "https://github.com/DEV-AdriBOT/discord.koplugin/issues/new"
local LOG_LINES = 30
local MAX_LINE = 300
local MAX_QR_BODY = 900 -- characters of the body that go in the QR code

--- Removes what must not leave the device from a log line.
function Report.redact(line)
    -- Discord tokens: three dot-separated base64url parts, or one long opaque string
    line = line:gsub("[%w_%-]+%.[%w_%-]+%.[%w_%-]+", function(s)
        return #s >= 40 and "<token>" or s
    end)
    line = line:gsub("[%w_%-%.]+", function(s)
        return #s >= 50 and "<redacted>" or s
    end)
    -- Ids (snowflakes), e-mail addresses and links
    line = line:gsub("%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+", "<id>")
    line = line:gsub("[%w%.%-_%+]+@[%w%.%-]+%.%a+", "<email>")
    line = line:gsub("[Aa]uthorization[:=]%s*%S+", "Authorization: <redacted>")
    line = line:gsub("[Tt]oken[\"']?%s*[:=]%s*[\"']?[^%s\"',]+", "token=<redacted>")
    if #line > MAX_LINE then line = line:sub(1, MAX_LINE) .. "…" end
    return line
end

--- Last lines of crash.log that mention Discord or a traceback, redacted.
function Report.logLines(path)
    path = path or (DataStorage:getDataDir() .. "/crash.log")
    local f = io.open(path, "r")
    if not f then return {} end
    local keep = {}
    local after_traceback = 0
    for line in f:lines() do
        if line:find("Discord", 1, true) or line:find("discord", 1, true) or line:find("traceback", 1, true) then
            table.insert(keep, Report.redact(line))
            after_traceback = line:find("traceback", 1, true) and 8 or 0
        elseif after_traceback > 0 then
            table.insert(keep, Report.redact(line))
            after_traceback = after_traceback - 1
        end
        if #keep > LOG_LINES * 3 then table.remove(keep, 1) end
    end
    f:close()
    while #keep > LOG_LINES do table.remove(keep, 1) end
    return keep
end

local function koreaderVersion()
    local ok, version = pcall(function() return require("version"):getCurrentRevision() end)
    return ok and version or "?"
end

--- The report text (Markdown).
function Report.build(lines)
    local screen = Device.screen
    local parts = {
        "**" .. _("What happened?") .. "**",
        "",
        "",
        "---",
        "- Discord plugin: " .. tostring(Update.current),
        "- KOReader: " .. tostring(koreaderVersion()),
        "- Device: " .. tostring(Device.model or "?"),
        "- Screen: " .. (screen and (screen:getWidth() .. "x" .. screen:getHeight()) or "?"),
        "",
        "```",
    }
    for __, line in ipairs(lines or Report.logLines()) do table.insert(parts, line) end
    table.insert(parts, "```")
    return table.concat(parts, "\n")
end

local function urlEncode(s)
    return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

--- URL of a new issue with the report in its body, short enough for a QR code.
function Report.issueUrl(body)
    if #body > MAX_QR_BODY then
        body = body:sub(1, MAX_QR_BODY)
        body = body:gsub("[\192-\255][\128-\191]*$", "") .. "\n…\n```\n(" .. _("full report in the file saved on the device") .. ")"
    end
    return ISSUES_URL .. "?title=" .. urlEncode("Problem report") .. "&body=" .. urlEncode(body)
end

--- Saves the full report where it can be taken out over USB. Returns the path.
function Report.save(body)
    local path = DataStorage:getDataDir() .. "/discord-report.txt"
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(body, "\n")
    f:close()
    return require("ffi/util").realpath(path) or path
end

function Report.show()
    local body = Report.build()
    local path = Report.save(body)
    local QRMessage = require("ui/widget/qrmessage")
    UIManager:show(QRMessage:new{
        text = Report.issueUrl(body),
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
    })
    UIManager:show(InfoMessage:new{
        text = path and T(_("Scan the code to open a pre-filled issue on GitHub. A full copy was saved to %1"), path)
            or _("Scan the code to open a pre-filled issue on GitHub."),
        timeout = 6,
    })
end

return Report
