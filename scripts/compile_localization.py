#!/usr/bin/env python3
"""Compile the authored catalog into native English and pseudo-locale resources."""
import json
import plistlib
from pathlib import Path
import sys


def quoted(value):
    return json.dumps(value, ensure_ascii=False)


def values(localization):
    if "stringUnit" in localization:
        return None, localization["stringUnit"]["value"]
    plural = localization["variations"]["plural"]
    return plural, plural["other"]["stringUnit"]["value"]


def compile_catalog(source, destination):
    document = json.loads(source.read_text())
    if document.get("sourceLanguage") != "en":
        raise ValueError("catalog source language must be English")
    for language in ("en", "zz"):
        strings = []
        stringsdict = {}
        for key, entry in sorted(document["strings"].items()):
            localization = entry["localizations"][language]
            plural, fallback = values(localization)
            strings.append(f"{quoted(key)} = {quoted(fallback)};\n")
            if plural is not None:
                variable = {
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                }
                for category, variation in plural.items():
                    variable[category] = variation["stringUnit"]["value"]
                stringsdict[key] = {
                    "NSStringLocalizedFormatKey": "%#@count@",
                    "count": variable,
                }
        directory = destination / f"{language}.lproj"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "Localizable.strings").write_text("".join(strings))
        with (directory / "Localizable.stringsdict").open("wb") as stream:
            plistlib.dump(stringsdict, stream, sort_keys=True)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: compile_localization.py CATALOG OUTPUT_DIRECTORY")
    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    compile_catalog(source, destination)


if __name__ == "__main__":
    main()
