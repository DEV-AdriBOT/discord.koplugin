# Contributing

Thanks for helping! The easiest way to contribute is a translation: no programming needed.

## Translating the plugin

The plugin shows its menus in KOReader's interface language when a translation exists, and in English otherwise. Translations are plain text files in [`l10n/`](l10n):

- `l10n/discord.pot` is the template with every English string.
- `l10n/<language>.po` is one translation, e.g. `es.po` for Spanish. Regional variants work too (`pt_BR.po` is used before `pt.po`).

### Add a new language

1. Copy `l10n/discord.pot` to `l10n/<code>.po`, using KOReader's language code (`fr`, `de`, `it`, `pt_BR`, …). You can find it in KOReader under *Settings → Language*.
2. Set the `Language:` line near the top to the same code.
3. Fill in every `msgstr` with the translation of the `msgid` above it:

   ```po
   #: discord_chatview.lua
   msgid "%1 is typing…"
   msgstr "%1 escribe…"
   ```

4. Open a pull request, or attach the file to a [translation issue](../../issues/new?template=translation.yml) if you prefer not to use Git.

You do not have to translate everything at once: empty `msgstr ""` entries simply stay in English.

### Rules for translations

- Keep placeholders exactly: `%1`, `%2` are replaced by names, numbers, etc. You may move them within the sentence.
- Keep `\n` (line breaks) and `\"` (quotes) as they are.
- Keep `…` and `→` if they appear; they are part of the interface.
- Short is better: e-reader screens are small and many strings are buttons.

### Fix an existing translation

Edit the `msgstr` in the language file and open a pull request, or describe the change in a [translation issue](../../issues/new?template=translation.yml).

### Try your translation on a device

Copy your `.po` file to `koreader/plugins/discord.koplugin/l10n/` on the e-reader, set KOReader to that language and restart KOReader.

### For maintainers: keeping files in sync

After changing interface strings in the code, run:

```sh
python3 tools/i18n.py
```

It regenerates `l10n/discord.pot`, adds new strings to every language file (empty, so they show in English until translated), removes strings that are no longer used, updates the progress table in the README and prints how complete each language is.

You don't have to do this by hand: on every push to `main` a GitHub Action runs it and commits the result. Pull requests only get a validity check (`python3 tools/i18n.py --lint`: file syntax and matching placeholders), so translators never need to run anything.

## Code contributions

Bug reports and pull requests are welcome. Please test changes on a real device (or the KOReader emulator) and keep the plugin usable on e-ink: few screen refreshes, nothing loaded automatically that could be loaded on demand.
