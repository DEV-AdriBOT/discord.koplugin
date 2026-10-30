#!/usr/bin/env python3
"""Keeps the translation files in sync with the code.

    python3 tools/i18n.py           regenerate l10n/discord.pot, every l10n/*.po and the README table
    python3 tools/i18n.py --check   fail if anything above is out of date (or a file is invalid)
    python3 tools/i18n.py --lint    only validate the language files (syntax, placeholders)
    python3 tools/i18n.py --stats   only print how complete each language is

Strings are collected from _("...") calls in the plugin's .lua files.
Existing translations are kept, new strings are added with an empty msgstr
(the plugin then shows them in English), and strings that are no longer
used are dropped.
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L10N = os.path.join(ROOT, "l10n")
TEMPLATE = os.path.join(L10N, "discord.pot")
README = os.path.join(ROOT, "README.md")
TABLE_START = "<!-- translations:start -->"
TABLE_END = "<!-- translations:end -->"

# Display names for the README table (KOReader language codes)
NAMES = {
    "en": "English", "es": "Español", "fr": "Français", "de": "Deutsch", "it": "Italiano",
    "pt": "Português", "pt_BR": "Português (Brasil)", "ca": "Català", "nl": "Nederlands",
    "pl": "Polski", "ru": "Русский", "uk": "Українська", "tr": "Türkçe", "ja": "日本語",
    "zh_CN": "简体中文", "zh_TW": "繁體中文", "ko": "한국어", "sv": "Svenska", "cs": "Čeština",
}

CALL = re.compile(r'_\("((?:[^"\\]|\\.)*)"\)')


def collect():
    """msgids in order of first appearance, with the files they come from."""
    found = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "*.lua"))):
        name = os.path.basename(path)
        with open(path, encoding="utf-8") as f:
            for msgid in CALL.findall(f.read()):
                found.setdefault(msgid, [])
                if name not in found[msgid]:
                    found[msgid].append(name)
    return found


def parse_po(path):
    """Returns (header comment lines, {msgid: msgstr}). Raises ValueError on syntax errors."""
    header, entries = [], {}
    msgid = msgstr = None
    current = None
    seen_entry = False
    with open(path, encoding="utf-8") as f:
        for number, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if line.startswith("#"):
                if not seen_entry and not line.startswith("#:"):
                    header.append(line)
                continue
            if not line.strip():
                continue
            m = re.match(r'^(msgid|msgstr) "((?:[^"\\]|\\.)*)"$', line)
            if m:
                seen_entry = True
                if m.group(1) == "msgid":
                    if msgid is not None and msgstr is not None:
                        entries[msgid] = msgstr
                    msgid, msgstr, current = m.group(2), None, "id"
                else:
                    if msgid is None:
                        raise ValueError(f"{path}:{number}: msgstr without msgid")
                    msgstr, current = m.group(2), "str"
                continue
            m = re.match(r'^"((?:[^"\\]|\\.)*)"$', line)
            if m and current == "id":
                msgid += m.group(1)
                continue
            if m and current == "str":
                msgstr += m.group(1)
                continue
            raise ValueError(f"{path}:{number}: cannot parse: {line}")
    if msgid is not None and msgstr is not None:
        entries[msgid] = msgstr
    entries.pop("", None)  # the PO header entry
    return header, entries


def placeholders(text):
    return sorted(re.findall(r"%\d", text))


def render(header, language, strings, translations):
    out = list(header) or [f"# {language} translation for discord.koplugin"]
    out += [
        'msgid ""',
        'msgstr ""',
        '"Content-Type: text/plain; charset=UTF-8\\n"',
        f'"Language: {language}\\n"',
        "",
    ]
    for msgid, files in strings.items():
        out.append("#: " + " ".join(files))
        out.append(f'msgid "{msgid}"')
        out.append(f'msgstr "{translations.get(msgid, "")}"')
        out.append("")
    return "\n".join(out)


def badge(percent):
    color = "brightgreen" if percent >= 100 else "green" if percent >= 80 else "yellow" if percent >= 50 else "orange"
    return f"![{percent} %](https://img.shields.io/badge/{percent}%25-{color})"


def readme_table(rows, total):
    lines = [
        TABLE_START,
        "| Language | Code | Translated | Progress |",
        "| --- | --- | --- | --- |",
        f"| English (source) | `en` | {total} / {total} | {badge(100)} |",
    ]
    for language, done, _total in sorted(rows, key=lambda r: (-r[1], NAMES.get(r[0], r[0]))):
        percent = 100 * done // max(total, 1)
        lines.append(f"| {NAMES.get(language, language)} | `{language}` | {done} / {total} | {badge(percent)} |")
    lines.append(TABLE_END)
    return "\n".join(lines)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    strings = collect()
    problems = []

    template = render(["# Template for discord.koplugin translations. Copy it to <language>.po."],
                      "", strings, {})
    current_template = open(TEMPLATE, encoding="utf-8").read() if os.path.exists(TEMPLATE) else None
    if mode == "--check" and current_template != template:
        problems.append("l10n/discord.pot is out of date: run python3 tools/i18n.py")
    elif mode == "":
        with open(TEMPLATE, "w", encoding="utf-8") as f:
            f.write(template)

    rows = []
    for path in sorted(glob.glob(os.path.join(L10N, "*.po"))):
        language = os.path.splitext(os.path.basename(path))[0]
        try:
            header, translations = parse_po(path)
        except ValueError as err:
            problems.append(str(err))
            continue
        for msgid, msgstr in translations.items():
            if msgstr and msgid in strings and placeholders(msgid) != placeholders(msgstr):
                problems.append(f"{language}: placeholders differ in \"{msgid}\" -> \"{msgstr}\"")
        done = sum(1 for msgid in strings if translations.get(msgid))
        rows.append((language, done, len(strings)))
        updated = render(header, language, strings, translations)
        if mode == "--check":
            if open(path, encoding="utf-8").read() != updated:
                problems.append(f"l10n/{language}.po is out of date: run python3 tools/i18n.py")
        elif mode == "":
            with open(path, "w", encoding="utf-8") as f:
                f.write(updated)

    if mode in ("", "--check") and os.path.exists(README):
        readme = open(README, encoding="utf-8").read()
        if TABLE_START in readme and TABLE_END in readme:
            before = readme[:readme.index(TABLE_START)]
            after = readme[readme.index(TABLE_END) + len(TABLE_END):]
            updated_readme = before + readme_table(rows, len(strings)) + after
            if mode == "--check" and updated_readme != readme:
                problems.append("the README translation table is out of date: run python3 tools/i18n.py")
            elif mode == "":
                with open(README, "w", encoding="utf-8") as f:
                    f.write(updated_readme)

    print(f"{len(strings)} strings")
    for language, done, total in rows:
        print(f"  {language}: {done}/{total} translated ({100 * done // max(total, 1)} %)")
    for problem in problems:
        print("ERROR:", problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
