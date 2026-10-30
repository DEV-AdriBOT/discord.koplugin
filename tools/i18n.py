#!/usr/bin/env python3
"""Keeps the translation files in sync with the code.

    python3 tools/i18n.py           regenerate l10n/discord.pot and update every l10n/*.po
    python3 tools/i18n.py --check   fail if the template or a language file is out of date
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

    print(f"{len(strings)} strings")
    for language, done, total in rows:
        print(f"  {language}: {done}/{total} translated ({100 * done // max(total, 1)} %)")
    for problem in problems:
        print("ERROR:", problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
