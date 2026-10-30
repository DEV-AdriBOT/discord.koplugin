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

-- Language chosen in the plugin settings ("en", "es", …), or nil to follow KOReader.
-- Read once at load: interface strings are built when modules load, so a change
-- needs a restart.
local override
do
    local ok, DataStorage = pcall(require, "datastorage")
    local ok2, LuaSettings = pcall(require, "luasettings")
    if ok and ok2 then
        local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/discord.lua")
        local lang = settings:readSetting("language")
        if type(lang) == "string" and lang ~= "auto" then override = lang end
    end
end

--- The language in use, e.g. "pt_BR".
local function currentLang()
    if override then return override end
    return (gettext.current_lang or "C"):match("^([%a_]+)") or "C"
end

--- Loads l10n/pt_BR.po if present, otherwise l10n/pt.po.
local function loadCatalog(lang)
    local base = lang:match("^(%a+)")
    return loadPo(plugin_dir .. "/l10n/" .. lang .. ".po")
        or (base ~= lang and loadPo(plugin_dir .. "/l10n/" .. base .. ".po"))
        or false
end

local catalog
local catalog_lang

local function translate(msgid)
    local lang = currentLang()
    if lang ~= catalog_lang then
        catalog_lang = lang
        catalog = loadCatalog(lang)
    end
    if catalog and catalog[msgid] then
        return catalog[msgid]
    end
    -- A forced language falls back to English, not to KOReader's language
    if override then return msgid end
    return gettext(msgid)
end

local NAMES = {
    en = "English", es = "Español", fr = "Français", de = "Deutsch", it = "Italiano",
    pt = "Português", pt_BR = "Português (Brasil)", ca = "Català", nl = "Nederlands",
    pl = "Polski", ru = "Русский", uk = "Українська", tr = "Türkçe", ja = "日本語",
    zh_CN = "简体中文", zh_TW = "繁體中文", ko = "한국어", sv = "Svenska", cs = "Čeština",
}

local I18n = {}

--- Language codes with a translation file, plus English, sorted by name.
function I18n.available()
    local codes = { "en" }
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok then
        for name in lfs.dir(plugin_dir .. "/l10n") do
            local code = name:match("^([%a_]+)%.po$")
            if code then table.insert(codes, code) end
        end
    end
    table.sort(codes, function(a, b) return I18n.name(a) < I18n.name(b) end)
    return codes
end

function I18n.name(code)
    return NAMES[code] or code
end

--- The language chosen in the settings, or nil when following KOReader.
function I18n.override()
    return override
end

return setmetatable(I18n, {
    __call = function(_self, msgid) return translate(msgid) end,
})
