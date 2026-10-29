# discord.koplugin

A lightweight Discord client for [KOReader](https://github.com/koreader/koreader), designed for e-ink devices (tested on a Kindle Paperwhite 11).

Text only: no images, GIFs, voice or video. Just your servers, text channels and direct messages, readable on an e-reader.

## Features

- **Login** with email + password (with 2FA/TOTP support), a pasted token, or a token file
- **Servers** with text and announcement channels grouped by category; channels you can't see are hidden and read-only ones are marked
- **Direct messages** and group DMs, sorted by latest activity
- **Search** in any list (servers, channels, DMs — DMs also match usernames)
- **Chat view** with day separators, grouped messages, replies, mentions, forwarded messages, embeds, attachments and stickers shown as text
- **Send, reply, edit and delete** your messages; copy message text; open a DM with a message author
- **Auto refresh** while a chat is open (configurable, pauses on suspend)
- **Mark as read** when opening a channel (optional)
- Common emoji rendered as text, since e-reader fonts lack emoji glyphs
- Adjustable text size

## Installation

1. Download or clone this repository.
2. Copy the `discord.koplugin` folder into KOReader's `plugins` directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`
   - Other devices: the `plugins` folder inside your KOReader install
3. Restart KOReader.
4. Open **Tools → Discord**.

## Logging in

- **Email and password** — the simplest option. If Discord asks for a captcha (common on new devices/IPs), use a token instead.
- **Token** — type or paste your user token.
- **Token file** — put your token in `/mnt/us/discord_token.txt` (Kindle) and choose *Load token from…*. The file is deleted once the login succeeds.

The token is stored in KOReader's settings folder (`settings/discord.lua`). Anyone with access to the device files can read it, so log out if you lend your device.

## Gestures

Two actions are available in KOReader's gesture manager:

- *Open Discord*
- *Discord: direct messages*

## Disclaimer

This is an unofficial client that uses your user account through Discord's REST API. Using third-party clients is against Discord's Terms of Service and could, in theory, lead to your account being flagged. Use it at your own risk.

## License

[AGPL-3.0](LICENSE), same as KOReader.
