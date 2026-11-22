--[[--
Local slash shortcuts. Discord's own slash commands do not work for user
accounts, so the plugin expands a few of them before sending: they save
typing on an e-reader's on-screen keyboard.
]]

local _ = require("discord_i18n")

local Shortcuts = {}

-- Command -> text added after what you wrote.
local TAILS = {
    shrug = [[¯\_(ツ)_/¯]],
    tableflip = "(╯°□°)╯︵ ┻━┻",
    unflip = "┬─┬ ノ( ゜-゜ノ)",
    lenny = "( ͡° ͜ʖ ͡°)",
}

-- Command -> function receiving what you wrote after it.
local WRAPS = {
    me = function(rest) return "_" .. rest .. "_" end,
    spoiler = function(rest) return "||" .. rest .. "||" end,
    bold = function(rest) return "**" .. rest .. "**" end,
}

--- Names and descriptions, for the help list.
function Shortcuts.list()
    return {
        { "/shrug", _("adds ¯\\_(ツ)_/¯ after your text") },
        { "/tableflip", _("adds (╯°□°)╯︵ ┻━┻ after your text") },
        { "/unflip", _("adds ┬─┬ ノ( ゜-゜ノ) after your text") },
        { "/lenny", _("adds ( ͡° ͜ʖ ͡°) after your text") },
        { "/me text", _("italic text, as an action") },
        { "/spoiler text", _("hides the text behind a spoiler") },
        { "/bold text", _("bold text") },
    }
end

--- Expands a shortcut at the start of the message. Unknown commands, and text
-- that merely starts with a slash (a path, a URL), are left alone.
function Shortcuts.expand(text)
    local cmd, rest = text:match("^/(%a+)[ \t]*(.*)$")
    if not cmd then return text end
    cmd = cmd:lower()
    if TAILS[cmd] then
        return rest ~= "" and (rest .. " " .. TAILS[cmd]) or TAILS[cmd]
    end
    if WRAPS[cmd] and rest ~= "" then
        return WRAPS[cmd](rest)
    end
    return text
end

return Shortcuts
