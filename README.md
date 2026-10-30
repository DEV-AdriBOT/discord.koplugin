# discord.koplugin

A lightweight Discord client for [KOReader](https://github.com/koreader/koreader), designed for e-ink devices (tested on a Kindle Paperwhite 11).

Text only: no images, GIFs, voice or video. Just your servers, text channels and direct messages, readable on an e-reader.

## Features

**Navigation**
- Servers with text, announcement and forum channels grouped by category; channels you can't see are hidden, read-only ones are marked
- Threads under their channel, forum posts, and archived threads
- Direct messages and group DMs, sorted by latest activity
- **Unread markers** (bold + `●`) and **mention counts** (`@3`) for servers, channels and DMs, respecting muted servers and channels
- **Favorites**: long-press a channel or DM to pin it to the top of the home screen
- **Hide servers** you don't use (long-press a server)
- **Search** in any list (DMs also match usernames)
- **Server folders** from your account, in the same order as the official client
- **Mark as read** a whole server or all DMs, and **mute / unmute** servers and channels
- **Mentions inbox** with every recent message that mentions you, opened in context
- **Friends** list and incoming friend requests (accept / ignore)
- **Status**: online, idle, do not disturb or invisible

**Chat**
- **Real-time updates** through the Discord gateway (WebSocket), with polling as a fallback
- Day separators, grouped messages, replies, mentions, forwarded messages, embeds, polls and stickers as text
- **Server nicknames**
- **Typing indicator** ("X is typing…") and your own typing is sent while you write
- **Send, reply, edit, delete**, copy, and open a DM with any author
- **Reactions**: shown under each message, add or remove them
- **Quick replies** (configurable) and a **mention picker** with member search
- **Pinned messages** and **search** within a channel, with "jump to message"
- **"New" separator** at the last read position when a channel has unread messages
- **Polls** with live results, and voting
- **Drafts** kept per channel, even across restarts
- **Only messages for me**: a per-channel mode for busy channels
- **Forward** messages, and keep **private notes** on users
- **Images on demand**: download a screen-sized version and open it in KOReader's image viewer — never loaded automatically
- **Reading theme**: any font (including the Kindle's own), line spacing, margins and text size; **compact layout**
- **Page turning** like a book: swipe left/right or use page-turn keys, with a periodic full refresh for e-ink

**E-reader**
- **Notifications** for DMs and mentions while you read (optional background connection)
- **Open as document**: read a long channel as a paginated book in KOReader's reader
- **Send highlights** from a book to a chat (highlight menu → *Send to Discord*)
- **Offline chats**: the latest messages of recent chats are saved and readable without Wi-Fi
- **Links as QR codes**, to open them on your phone
- **Sleep screen summary** (optional): unread DMs and mentions shown on the sleep screen
- **Reading activity** (optional): your profile shows "Playing KOReader" with the book title, author and progress while a book is open
- **Battery saver**: pauses the background connection and slows polling below a battery level
- **Fast start**: the connection state is cached on disk, lists open at once and sessions are resumed after restarts
- Common emoji rendered as text, since e-reader fonts lack emoji glyphs
- Interface in English and Spanish (follows KOReader's language)

## Installation

1. Download `discord.koplugin.zip` from the [latest release](https://github.com/DEV-AdriBOT/discord.koplugin/releases/latest) and unzip it.
2. Copy the `discord.koplugin` folder into KOReader's `plugins` directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`
   - Other devices: the `plugins` folder inside your KOReader install
3. Restart KOReader.
4. Open **Tools → Discord**.

## Updating

*Tools → Discord → Check for updates* compares your version with the latest release, shows what changed and installs it. The plugin also checks once a day when you open Discord and lets you know (this can be turned off in Settings).

## Logging in

- **Email and password** — the simplest option. If Discord asks for a captcha (common on new devices/IPs), use a token instead.
- **Token** — type or paste your user token.
- **Token file** — put your token in `/mnt/us/discord_token.txt` (Kindle) and choose *Load token from…*. The file is deleted once the login succeeds.

The token is stored in KOReader's settings folder (`settings/discord.lua`). Anyone with access to the device files can read it, so log out if you lend your device.

## Gestures

These actions are available in KOReader's gesture manager:

- *Open Discord*
- *Discord: direct messages*
- *Discord: open last chat*

## Translations

The interface follows KOReader's language. Available: English, Spanish.

Want the plugin in your language, or spotted a wrong translation? No programming needed: see [CONTRIBUTING.md](CONTRIBUTING.md#translating-the-plugin), or open a [translation issue](../../issues/new?template=translation.yml).

## Contributing

Bug reports, ideas and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

This is an unofficial client that uses your user account through Discord's API and gateway. Using third-party clients is against Discord's Terms of Service and could, in theory, lead to your account being flagged. Use it at your own risk.

## License

[AGPL-3.0](LICENSE), same as KOReader.
