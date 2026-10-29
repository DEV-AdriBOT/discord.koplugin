--[[--
Plugin-local translations.

KOReader only loads translations for its own strings, so this reads
`l10n/<lang>.po` next to the plugin and falls back to KOReader's gettext.

@module koplugin.discord.i18n
]]

local gettext = require("gettext")

local plugin_dir = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."

local function unescape(s)
    return (s:gsub("\\(.)", { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" }))
end

local function loadPo(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local catalog = {}
    local msgid, msgstr, current
    local function commit()
        if msgid and msgstr and msgid ~= "" and msgstr ~= "" then
            catalog[msgid] = msgstr
        end
        msgid, msgstr, current = nil, nil, nil
    end
    for line in f:lines() do
        local id = line:match('^msgid "(.*)"$')
        local str = line:match('^msgstr "(.*)"$')
        local cont = line:match('^"(.*)"$')
        if id then
            commit()
            msgid, current = unescape(id), "id"
        elseif str then
            msgstr, current = unescape(str), "str"
        elseif cont and current == "id" then
            msgid = msgid .. unescape(cont)
        elseif cont and current == "str" then
            msgstr = msgstr .. unescape(cont)
        end
    end
    commit()
    f:close()
    return catalog
end

local function currentLang()
    -- Follow the language KOReader actually uses, not the system locale
    local lang = gettext.current_lang or "C"
    return lang:match("^(%a+)") or "C"
end

local catalog
local catalog_lang

local function translate(msgid)
    local lang = currentLang()
    if lang ~= catalog_lang then
        catalog_lang = lang
        catalog = loadPo(plugin_dir .. "/l10n/" .. lang .. ".po") or false
    end
    if catalog and catalog[msgid] then
        return catalog[msgid]
    end
    return gettext(msgid)
end

return setmetatable({}, {
    __call = function(_self, msgid) return translate(msgid) end,
})
