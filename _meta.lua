local _ = require("gettext")
return {
    fullname = _("Discord"),
    description = _([[Lightweight Discord client for e-readers: servers, channels, threads and direct messages, in real time. No calls; images only on demand.]]),
    -- Single source of the version: read by KOReader's App Store, the built-in
    -- updater (through discord_version.lua) and the release workflow.
    version = "1.2.1",
}
