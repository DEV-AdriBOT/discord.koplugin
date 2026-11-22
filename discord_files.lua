--[[--
Downloading the files attached to messages: where they are saved, what they are
called, and the metadata (title, author, tags) that makes them show up properly in
KOReader's file browser and book information.
]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("discord_i18n")
local T = require("ffi/util").template

local Files = {}

-- File type reported by Discord -> extension, used when the name has none.
local EXTENSIONS = {
    ["application/pdf"] = "pdf",
    ["application/epub+zip"] = "epub",
    ["application/zip"] = "zip",
    ["application/x-zip-compressed"] = "zip",
    ["application/x-cbz"] = "cbz",
    ["application/vnd.comicbook+zip"] = "cbz",
    ["application/x-mobipocket-ebook"] = "mobi",
    ["application/json"] = "json",
    ["application/xml"] = "xml",
    ["text/plain"] = "txt",
    ["text/markdown"] = "md",
    ["text/html"] = "html",
    ["text/csv"] = "csv",
    ["image/jpeg"] = "jpg",
    ["image/png"] = "png",
    ["image/gif"] = "gif",
    ["image/webp"] = "webp",
    ["audio/mpeg"] = "mp3",
    ["audio/ogg"] = "ogg",
    ["video/mp4"] = "mp4",
}

-- Extensions KOReader can read.
local READABLE = {
    pdf = true, epub = true, mobi = true, azw3 = true, azw = true, fb2 = true, djvu = true,
    cbz = true, cbr = true, txt = true, md = true, html = true, htm = true, rtf = true,
}

--- Every file attached to a message (including forwarded ones), images too.
function Files.of(msg)
    local list = {}
    for __, a in ipairs(msg.attachments or {}) do
        if a.url then table.insert(list, a) end
    end
    for __, snap in ipairs(msg.message_snapshots or {}) do
        if snap.message then
            for __, a in ipairs(Files.of(snap.message)) do table.insert(list, a) end
        end
    end
    return list
end

local function extensionOf(name)
    return name and name:match("%.(%w+)$")
end

--- Extension of an attachment: from its name, or from the file type Discord reports.
function Files.extension(a)
    local ext = extensionOf(a.filename)
    if ext then return ext:lower() end
    local ctype = (a.content_type or ""):match("^([^;]+)")
    return ctype and EXTENSIONS[ctype:lower()] or nil
end

function Files.kind(a)
    local ctype = a.content_type or ""
    if ctype:match("^image/") then return _("image") end
    if ctype:match("^audio/") then return _("audio") end
    if ctype:match("^video/") then return _("video") end
    local ext = Files.extension(a)
    if ext and READABLE[ext] then return _("document") end
    return _("file")
end

--- "report.pdf · 1.2 MB", for the lists and the placeholder in the chat.
function Files.describe(a)
    local parts = { a.filename or "?" }
    if a.size then table.insert(parts, util.getFriendlySize(a.size)) end
    return table.concat(parts, " · ")
end

function Files.isReadable(path)
    local ext = extensionOf(path)
    return ext ~= nil and READABLE[ext:lower()] == true
end

--- Folder where downloads go: the one chosen in the settings, else "Discord" inside
-- KOReader's home folder (or its data folder when there is none).
function Files.downloadDir(settings)
    local dir = settings and settings.download_dir
    if not dir or dir == "" then
        local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
        dir = (home or (DataStorage:getDataDir() .. "/downloads")) .. "/Discord"
    end
    return dir
end

--- A file name that is safe on every file system and always has an extension.
function Files.safeName(a)
    local name = (a.filename or "file"):gsub("[/\\:%*%?\"<>|%c]", "_"):gsub("^%.+", "")
    if name == "" then name = "file" end
    if not extensionOf(name) then
        local ext = Files.extension(a)
        if ext then name = name .. "." .. ext end
    end
    return name
end

--- Path that does not exist yet: "name.pdf", then "name (1).pdf", "name (2).pdf"…
function Files.uniquePath(dir, name)
    local base, ext = name:match("^(.*)%.(%w+)$")
    if not base then base, ext = name, nil end
    local path = dir .. "/" .. name
    local n = 0
    while lfs.attributes(path, "mode") do
        n = n + 1
        path = dir .. "/" .. base .. " (" .. n .. ")" .. (ext and ("." .. ext) or "")
    end
    return path
end

--- Writes KOReader custom metadata next to the file: the title, the author (who posted
-- it), tags (keywords) and a description saying where it came from. info:
-- { author, server, channel, date, text }.
function Files.tag(path, a, info)
    local base = (a.filename or path:match("([^/]+)$") or "file"):gsub("%.%w+$", "")
    local keywords = { "Discord" }
    local function add(word)
        if word and word ~= "" then table.insert(keywords, word) end
    end
    add(info.server)
    add(info.channel)
    add(Files.kind(a))
    add(Files.extension(a))
    local lines = {}
    if info.server and info.channel then
        table.insert(lines, T(_("From %1, %2"), info.server, info.channel))
    elseif info.channel then
        table.insert(lines, T(_("From %1"), info.channel))
    end
    if info.author then table.insert(lines, T(_("Sent by %1"), info.author)) end
    if info.date then table.insert(lines, info.date) end
    if info.text and info.text ~= "" then
        table.insert(lines, "")
        table.insert(lines, info.text)
    end
    local settings = DocSettings.openSettingsFile()
    settings:saveSetting("doc_props", {})
    settings:saveSetting("custom_props", {
        title = base,
        authors = info.author,
        keywords = table.concat(keywords, "\n"),
        description = table.concat(lines, "\n"),
    })
    return settings:flushCustomMetadata(path)
end

return Files
