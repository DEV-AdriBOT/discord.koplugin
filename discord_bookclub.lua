--[[--
Book club: per book and only when enabled, sends your reading progress
(every X percent and/or at the end of each chapter) and your highlights to
a channel of your choice.
]]

local DiscordAPI = require("discord_api")
local Outbox = require("discord_outbox")
local logger = require("logger")
local _ = require("discord_i18n")

local Club = {}

Club.DEFAULTS = {
    enabled = false,
    channel = nil,      -- { id, guild_id, title, subtitle }
    progress = true,    -- send progress every `step` percent
    step = 10,
    chapters = false,   -- send when a chapter is finished
    highlights = true,
    last_pct = 0,
    last_chapter = nil,
    finished = false,
}

--- The settings of the open book (defaults filled in). Change it and call Club.save.
function Club.get(ui)
    local data = ui.doc_settings and ui.doc_settings:readSetting("discord_club") or {}
    for k, v in pairs(Club.DEFAULTS) do
        if data[k] == nil then data[k] = v end
    end
    return data
end

function Club.save(ui, data)
    if ui.doc_settings then ui.doc_settings:saveSetting("discord_club", data) end
end

local function title(ui)
    local props = ui.doc_props or {}
    return DiscordAPI.cleanEmoji(props.display_title or props.title or _("a book"), true)
end

--- Sends text to the club channel; keeps it in the outbox if there is no network.
function Club.send(plugin, club, text)
    if not club.channel then return end
    local ok, err, code = plugin.api:sendMessage(club.channel.id, text)
    if not ok and (code == nil or code == 429 or code >= 500) then
        Outbox.add(club.channel.id, text)
    elseif not ok then
        logger.warn("Discord: book club message failed", tostring(err))
    end
    return ok
end

local function percent(ui, pageno)
    local total = ui.document and ui.document:getPageCount()
    if not total or total <= 0 or not pageno then return nil end
    return math.floor(pageno * 100 / total)
end

local function chapterIndex(ui, pageno)
    local toc = ui.toc
    if not toc or not toc.getTocIndexByPage then return nil end
    local ok, index = pcall(toc.getTocIndexByPage, toc, pageno)
    return ok and index or nil
end

--- Called on every page turn.
function Club.onPage(plugin, pageno)
    local ui = plugin.ui
    local club = Club.get(ui)
    if not club.enabled or not club.channel then return end
    local changed = false
    local pct = percent(ui, pageno)
    if club.progress and pct then
        if pct >= 100 then
            if not club.finished then
                club.finished = true
                changed = true
                Club.send(plugin, club, string.format(_("I finished **%s**!"), title(ui)))
            end
        else
            club.finished = false
            local bucket = math.floor(pct / club.step) * club.step
            if bucket >= club.step and bucket > (club.last_pct or 0) then
                club.last_pct = bucket
                changed = true
                Club.send(plugin, club, string.format(_("Reading **%s**: %d%%"), title(ui), pct))
            end -- going back never repeats what was already said
        end
    end
    if club.chapters then
        local index = chapterIndex(ui, pageno)
        if index then
            if club.last_chapter and index > club.last_chapter then
                local entry = ui.toc.toc and ui.toc.toc[club.last_chapter]
                if entry and entry.title and entry.title ~= "" then
                    Club.send(plugin, club, string.format(_("Finished chapter «%s» of **%s**"),
                        DiscordAPI.cleanEmoji(entry.title, true), title(ui)))
                end
            end
            if index ~= club.last_chapter then
                club.last_chapter = index
                changed = true
            end
        end
    end
    if changed then Club.save(ui, club) end
end

--- Called when annotations change: sends new highlights.
function Club.onAnnotation(plugin, items)
    local ui = plugin.ui
    local club = Club.get(ui)
    if not club.enabled or not club.highlights or not club.channel then return end
    if not (items and items.nb_highlights_added and items[1]) then return end
    local item = items[1]
    local text = item.text and item.text:gsub("%s+", " ")
    if not text or text == "" then return end
    local quote = "> " .. DiscordAPI.cleanEmoji(text, true)
    local page = item.pageref or item.pageno
    local head = string.format("**%s**%s", title(ui), page and (" (p. " .. tostring(page) .. ")") or "")
    local msg = head .. "\n" .. quote
    if item.note and item.note ~= "" then msg = msg .. "\n" .. DiscordAPI.cleanEmoji(item.note, true) end
    Club.send(plugin, club, msg:sub(1, 1900))
end

--- Sends the current progress right now.
function Club.sendNow(plugin)
    local ui = plugin.ui
    local club = Club.get(ui)
    if not club.channel then return false end
    local pct = percent(ui, plugin.current_page or ui:getCurrentPage())
    Club.send(plugin, club, string.format(_("Reading **%s**: %d%%"), title(ui), pct or 0))
    return true
end

return Club
