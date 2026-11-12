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

    info_path = destination / "Info.plist"
    if info_path.exists():
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    else:
        info = {}
    info.setdefault("CFBundleInfoDictionaryVersion", "6.0")
    info.setdefault("CFBundleIdentifier", "app.perch.mac.localization")
    info["CFBundlePackageType"] = "BNDL"
    info["CFBundleDevelopmentRegion"] = "en"
    info["CFBundleLocalizations"] = ["en", "zz"]
    destination.mkdir(parents=True, exist_ok=True)
    with info_path.open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=True)


def runtime_resource_directory(bundle):
    """Locate the one runtime catalog, independent of SwiftPM's bundle layout."""
    if not bundle.is_dir():
        raise ValueError(f"Missing localization resource bundle: {bundle}")
    entries = sorted(bundle.rglob("*"))
    print(f"Localization resource bundle: {bundle}", file=sys.stderr)
    for path in entries:
        suffix = "/" if path.is_dir() else ""
        print(f"  {path.relative_to(bundle)}{suffix}", file=sys.stderr)
    catalogs = [path for path in entries if path.name == "Localizable.json" and path.is_file()]
    if len(catalogs) != 1:
        raise ValueError(f"Expected exactly one runtime catalog in {bundle}; found {len(catalogs)}")
    print(f"Runtime catalog: {catalogs[0]}", file=sys.stderr)
    return catalogs[0].parent


def main():
    arguments = sys.argv[1:]
    is_bundle = len(arguments) == 3 and arguments[-1] == "--resource-bundle"
    if len(arguments) != 2 and not is_bundle:
        raise SystemExit("usage: compile_localization.py CATALOG OUTPUT_DIRECTORY [--resource-bundle]")
    source = Path(arguments[0])
    destination = Path(arguments[1])
    if is_bundle:
        try:
            destination = runtime_resource_directory(destination)
        except ValueError as error:
            raise SystemExit(str(error)) from error
    compile_catalog(source, destination)


if __name__ == "__main__":
    main()
