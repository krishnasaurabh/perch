#!/usr/bin/env python3
"""Refresh English and pseudolocalization string catalogs from product source."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources/PerchUI"
APP = ROOT / "Sources/PerchApp"
CORE = ROOT / "Sources/PlannerCore"
MCP = ROOT / "Sources/PerchMCP"
REMINDERS = ROOT / "Sources/PerchReminders"
UI_CATALOG = UI / "Resources/Localizable.xcstrings"
APP_CATALOG = APP / "Resources/Localizable.xcstrings"
BUNDLED_CATALOG = ROOT / "Resources/Localizable.xcstrings"

L10N = re.compile(r'(?:PerchL10n|AppL10n)\.(?:text|format)\(\s*"((?:\\.|[^"\\])*)"')
STATIC_UI = re.compile(
    r'(?:Text|Button|Label|Toggle|Section|Picker|LabeledContent|TextField|CardHeading|EmptyStateView|Menu|Tab|alert|confirmationDialog|accessibilityLabel|accessibilityHint|help|navigationTitle|prompt)\s*\(\s*"((?:\\.|[^"\\])*)"',
    re.S,
)
HELPER_ARGUMENT = re.compile(
    r'\b(?:help|placeholder|title|subtitle|disabledReason|prompt):\s*"((?:\\.|[^"\\])*)"'
)
PRESENTATION_HELPER = re.compile(r'\b(?:field|label|pill|tile)\(\s*"((?:\\.|[^"\\])*)"')
DISABLED_REASON = re.compile(
    r'\bdisabledReason:\s*(?:String\s*=\s*|[^\n"]*\?\?\s*)?"((?:\\.|[^"\\])*)"'
)
ERROR = re.compile(r'PlannerError\(\s*"((?:\\.|[^"\\])*)"')
REMINDER_ERROR = re.compile(r'ReminderSyncError\.stopped\(\s*"((?:\\.|[^"\\])*)"')
LOCAL_HELPER = re.compile(r'(?<![A-Za-z])(?:text|format)\(\s*"((?:\\.|[^"\\])*)"')
ENUM_RAW = re.compile(r'(?:\bcase\s+|,\s*)[A-Za-z_]\w*\s*=\s*"((?:\\.|[^"\\])*)"')
TERNARY = re.compile(r'\?\s*"((?:\\.|[^"\\])*)"\s*:\s*"((?:\\.|[^"\\])*)"', re.S)
EXAMPLE_PROMPTS = re.compile(r'\bstatic\s+let\s+examplePrompts\s*=\s*\[(.*?)\]', re.S)
EMPTY_STATE = re.compile(r'\bEmptyStateView\(\s*(.*?),\s*symbol\s*:', re.S)
QUOTED = re.compile(r'"((?:\\.|[^"\\])*)"')
PRESENTATION = re.compile(
    r'AppL10n|PerchL10n|Text\(|Label\(|Button\(|Toggle\(|Picker\(|Menu\(|Section\(|'
    r'CardHeading\(|EmptyStateView\(|accessibilityLabel|accessibilityHint|\.help\(')
INTERPOLATION = re.compile(r'\\\((?:[^()]|\([^()]*\))*\)')


def source(path):
    """Remove line comments without treating comment markers inside strings as code."""
    output = []
    for line in path.read_text().splitlines():
        quoted = False
        escaped = False
        end = len(line)
        for index, character in enumerate(line):
            if escaped:
                escaped = False
            elif character == '\\' and quoted:
                escaped = True
            elif character == '"':
                quoted = not quoted
            elif character == '/' and not quoted and index + 1 < len(line) and line[index + 1] == '/':
                end = index
                break
        output.append(line[:end])
    return '\n'.join(output)


def key(raw):
    return INTERPOLATION.sub('%@', raw).replace(r'\"', '"').replace(r'\n', '\n')


def collect(pattern, paths):
    found = set()
    for path in paths:
        for match in pattern.finditer(source(path)):
            value = key(match.group(1))
            if value and any(character.isalpha() for character in value):
                found.add(value)
    return found


def human_app_strings():
    paths = list(APP.rglob('*.swift'))
    found = collect(L10N, paths)
    found |= collect(STATIC_UI, paths)
    found |= collect(HELPER_ARGUMENT, paths)
    found |= collect(PRESENTATION_HELPER, paths)
    found |= collect(DISABLED_REASON, paths)
    # PlannerError carries a stable presentation key and arguments. Its fully
    # rendered English transport text is deliberately not an extraction input.
    for directory in (APP, CORE, MCP):
        found |= collect(ERROR, directory.rglob('*.swift'))
    # Static Perch-authored sync failures are looked up at the app boundary.
    # Interpolated details and system errors are not stable catalog keys.
    for directory in (APP, REMINDERS):
        for path in directory.rglob('*.swift'):
            for match in REMINDER_ERROR.finditer(source(path)):
                raw = match.group(1)
                value = key(raw)
                if '\\(' not in raw and value and any(character.isalpha() for character in value):
                    found.add(value)
    for path in paths:
        text = source(path)
        # Enum raw values become visible only through an explicit AppL10n call.
        if re.search(r'AppL10n\.text\(\s*(?:\$0\.)?rawValue\b', text):
            found |= collect(ENUM_RAW, [path])
        # Prompts are displayed through AppL10n but copied in their original
        # English form, so extract their stable array entries separately.
        for match in EXAMPLE_PROMPTS.finditer(text):
            for raw in QUOTED.findall(match.group(1)):
                value = key(raw)
                if value and any(character.isalpha() for character in value):
                    found.add(value)
        # EmptyStateView performs the lookup internally, so every literal in its
        # message expression is a catalog key, including nested fallback branches.
        for match in EMPTY_STATE.finditer(text):
            for raw in QUOTED.findall(match.group(1)):
                value = key(raw)
                if value and any(character.isalpha() for character in value):
                    found.add(value)
        # Static ternary labels need both branches. Restrict this pass to actual
        # presentation expressions so logs, predicates and identifiers stay out.
        for match in TERNARY.finditer(text):
            context = text[max(0, match.start() - 160):match.end() + 80]
            if not PRESENTATION.search(context):
                continue
            for raw in match.groups():
                value = key(raw)
                if value and any(character.isalpha() for character in value):
                    found.add(value)
    return found


PLURALS = {
    '%lld tasks': ('%lld task', '%lld tasks'),
    '%lld days': ('%lld day', '%lld days'),
    '%lld unfinished tasks today. Open Today': (
        '%lld unfinished task today. Open Today',
        '%lld unfinished tasks today. Open Today',
    ),
    '%lld day repeat': ('Every day', 'Every %lld days'),
    '%lld week repeat': ('Every week', 'Every %lld weeks'),
    '%lld month repeat': ('Every month', 'Every %lld months'),
    '+%lld more': ('+%lld more', '+%lld more'),
    'Removed %lld clips': ('Removed %lld clip', 'Removed %lld clips'),
    '%lld more tasks below': ('%lld more task below', '%lld more tasks below'),
    '%lld tasks done this week.': ('%lld task done this week.', '%lld tasks done this week.'),
    '%lld tasks done, up from %lld the week before.': (
        '%lld task done, up from %lld the week before.',
        '%lld tasks done, up from %lld the week before.',
    ),
    '%lld tasks done, against %lld the week before.': (
        '%lld task done, against %lld the week before.',
        '%lld tasks done, against %lld the week before.',
    ),
}


def pseudo(value):
    accents = str.maketrans({
        'a': 'à', 'e': 'ë', 'i': 'ï', 'o': 'ö', 'u': 'ü',
        'A': 'Å', 'E': 'Ë', 'I': 'Î', 'O': 'Ö', 'U': 'Ü',
    })
    pieces = []
    index = 0
    for match in re.finditer(r'%(?:\d+\$)?(?:@|lld|d|f|\.\d+f)', value):
        pieces.append(value[index:match.start()].translate(accents))
        pieces.append(match.group(0))
        index = match.end()
    pieces.append(value[index:].translate(accents))
    return '⟦' + ''.join(pieces) + ' ·~⟧'


def unit(value):
    return {'stringUnit': {'state': 'translated', 'value': value}}


def localization(key, language):
    if key in PLURALS:
        one, other = PLURALS[key]
        if language == 'zz':
            one, other = pseudo(one), pseudo(other)
        return {'variations': {'plural': {'one': unit(one), 'other': unit(other)}}}
    return unit(key if language == 'en' else pseudo(key))


def catalog(keys):
    return {
        'sourceLanguage': 'en',
        'strings': {
            key: {
                'extractionState': 'manual',
                'localizations': {language: localization(key, language) for language in ('en', 'zz')},
            }
            for key in sorted(keys | PLURALS.keys())
        },
        'version': '1.0',
    }


def rendered(document):
    return json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + '\n'


def write_or_check(path, document, check):
    expected = rendered(document)
    if check:
        if not path.exists() or path.read_text() != expected:
            raise SystemExit(f'Localization catalog is stale: {path.relative_to(ROOT)}; run scripts/update_localization.py')
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(expected)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    ui_keys = collect(L10N, UI.rglob('*.swift'))
    ui_keys |= collect(LOCAL_HELPER, [UI / 'PerchLocalization.swift'])
    app_keys = human_app_strings() | set(json.loads(APP_CATALOG.read_text())["strings"])
    ui_document = catalog(ui_keys)
    write_or_check(UI_CATALOG, ui_document, args.check)
    write_or_check(UI_CATALOG.with_suffix('.json'), ui_document, args.check)
    app_document = catalog(app_keys)
    write_or_check(APP_CATALOG, app_document, args.check)
    write_or_check(APP_CATALOG.with_suffix('.json'), app_document, args.check)
    write_or_check(BUNDLED_CATALOG, app_document, args.check)
    print(f'UI strings: {len(ui_keys | PLURALS.keys())}; app strings: {len(app_keys | PLURALS.keys())}; pseudo locale: zz')


if __name__ == '__main__':
    main()
