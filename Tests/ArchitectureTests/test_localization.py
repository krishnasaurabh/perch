"""English extraction, pseudolocalization and parser-language boundaries."""
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
FORMATS = re.compile(r'%(?:\d+\$)?(?:@|lld|d|f|\.\d+f)')


class LocalizationTests(unittest.TestCase):
    def test_catalogs_are_fresh_and_identical_to_their_portable_copies(self):
        subprocess.run(['python3', 'scripts/update_localization.py', '--check'], cwd=ROOT, check=True)
        for target in ('PerchUI', 'PerchApp'):
            directory = ROOT / 'Sources' / target / 'Resources'
            self.assertEqual((directory / 'Localizable.xcstrings').read_bytes(),
                             (directory / 'Localizable.json').read_bytes())
        self.assertEqual((ROOT / 'Sources/PerchApp/Resources/Localizable.xcstrings').read_bytes(),
                         (ROOT / 'Resources/Localizable.xcstrings').read_bytes())

    def test_every_catalog_key_has_english_and_expanded_pseudolocalization(self):
        for path in (ROOT / 'Sources/PerchUI/Resources/Localizable.xcstrings',
                     ROOT / 'Sources/PerchApp/Resources/Localizable.xcstrings'):
            document = json.loads(path.read_text())
            self.assertEqual(document['sourceLanguage'], 'en')
            self.assertGreater(len(document['strings']), 50)
            for key, entry in document['strings'].items():
                localizations = entry['localizations']
                self.assertEqual(set(localizations), {'en', 'zz'}, key)
                def values(localization):
                    if 'stringUnit' in localization:
                        return [localization['stringUnit']['value']]
                    plural = localization['variations']['plural']
                    return [plural[category]['stringUnit']['value'] for category in sorted(plural)]
                english_values = values(localizations['en'])
                for language, localization in localizations.items():
                    for index, value in enumerate(values(localization)):
                        self.assertTrue(set(FORMATS.findall(value)).issubset(set(FORMATS.findall(key))), key)
                        if language == 'zz':
                            self.assertTrue(value.startswith('⟦') and value.endswith(' ·~⟧'), key)
                            self.assertGreater(len(value), len(english_values[index]), key)

    def test_dynamic_extraction_has_stable_keys_without_source_debris(self):
        ui = json.loads((ROOT / 'Sources/PerchUI/Resources/Localizable.xcstrings').read_text())['strings']
        app = json.loads((ROOT / 'Sources/PerchApp/Resources/Localizable.xcstrings').read_text())['strings']
        self.assertIn('999+ tasks', ui)
        for key in ('General', 'Workspace', 'System', 'Already completed: %@.',
                    'Removed %lld clips', '%lld more tasks below', 'A whole number from 1 to %lld',
                    'High', 'Medium', 'Low', 'Just focusing', 'Minutes focused',
                    'Focus timer (while running)', "Today's agenda (when there are events)",
                    'Perch is already connected to Claude Code.',
                    'Open a fresh Claude Code session, then ask it something like:',
                    'Quit and reopen the Claude app, then ask it something like:',
                    'Cursor loads Perch when it restarts.', 'Adding Perch to Claude Code failed. %@'):
            self.assertIn(key, app)
        for key in set(ui) | set(app):
            self.assertNotIn('\\(', key, key)
            self.assertNotIn('\n', key, key)
            self.assertFalse(key.startswith(('authorization status=', 'calendar created id=', 'windows=')), key)

    def test_dynamic_producers_and_helper_arguments_have_catalog_entries(self):
        app = json.loads((ROOT / 'Sources/PerchApp/Resources/Localizable.xcstrings').read_text())['strings']
        required = {
            'What would you like to do?', 'Previous week', 'Next week', 'Add date', 'Clear', 'Apply',
            'Upcoming', 'Projects', '⌘↩ makes a task', 'All day',
            "macOS wouldn't give up that combination. Kept %@.",
        }
        agent = (ROOT / 'Sources/PerchApp/Services/AgentConnector.swift').read_text()
        prompt_match = re.search(r'static let examplePrompts = \[(.*?)\]', agent, re.S)
        assert prompt_match is not None
        prompt_block = prompt_match.group(1)
        required.update(raw.replace(r'\"', '"') for raw in re.findall(r'"((?:\\.|[^"\\])*)"', prompt_block))
        for key in sorted(required):
            self.assertIn(key, app)
        dashboard = (ROOT / 'Sources/PerchApp/Settings/DashboardView.swift').read_text()
        self.assertIn('Text(AppL10n.text($0.rawValue))', dashboard)
        shortcut = (ROOT / 'Sources/PerchApp/Settings/ShortcutPreferenceRow.swift').read_text()
        self.assertIn('AppL10n.format("macOS wouldn\'t give up that combination. Kept %@.", shortcut.display)', shortcut)

    def test_wrapper_arguments_defaults_and_owned_reminders_are_extracted(self):
        from scripts.update_localization import key, source

        app = json.loads((ROOT / 'Sources/PerchApp/Resources/Localizable.xcstrings').read_text())['strings']
        literal = r'"((?:\\.|[^"\\])*)"'
        patterns = (
            re.compile(r'\b(?:field|label|pill|tile)\(\s*' + literal),
            re.compile(r'\bdisabledReason:\s*(?:String\s*=\s*|[^\n"]*\?\?\s*)?' + literal),
        )
        for path in (ROOT / 'Sources/PerchApp').rglob('*.swift'):
            text = source(path)
            for pattern in patterns:
                for match in pattern.finditer(text):
                    self.assertIn(key(match.group(1)), app, path.relative_to(ROOT))

        reminder_error = re.compile(r'ReminderSyncError\.stopped\(\s*' + literal)
        for directory in ('Sources/PerchApp', 'Sources/PerchReminders'):
            for path in (ROOT / directory).rglob('*.swift'):
                for match in reminder_error.finditer(source(path)):
                    raw = match.group(1)
                    if '\\(' not in raw:
                        self.assertIn(key(raw), app, path.relative_to(ROOT))

        clips = (ROOT / 'Sources/PerchApp/Services/ClipsService.swift').read_text()
        self.assertIn('AppL10n.text("Copied image", locale: locale)', clips)
        errors = (ROOT / 'Sources/PerchApp/App/AppErrors.swift').read_text()
        self.assertIn('Self.presentedDetail(detail)', errors)

    def test_owned_errors_and_mixed_dynamic_labels_use_localized_presentation(self):
        app = json.loads((ROOT / 'Sources/PerchApp/Resources/Localizable.xcstrings').read_text())['strings']
        for prefix in ('Another process is updating the planner.',
                       'Unable to read planner data at %@: %@.',
                       'Unable to load planner data at %@: %@.',
                       'Planner schema version %lld is not supported',
                       'Planner data needs recovery. Kept %lld valid record(s)',
                       'Uses the on-device model to suggest a priority', 'No plans'):
            self.assertTrue(any(key.startswith(prefix) for key in app), prefix)

        errors = (ROOT / 'Sources/PerchApp/App/AppErrors.swift').read_text()
        self.assertIn('is PlannerStorageBusy', errors)
        for type_name in ('PlannerDataError', 'PlannerSchemaError', 'PlannerRecoveryError'):
            self.assertIn(f'as? {type_name}', errors)
        store = (ROOT / 'Sources/PerchApp/App/PlannerStore.swift').read_text()
        self.assertNotIn('.planner(recovery.localizedDescription)', store)
        settings = (ROOT / 'Sources/PerchApp/Settings/SettingsView.swift').read_text()
        self.assertIn('Self.appleIntelligenceExplanation(', settings)
        clips = (ROOT / 'Sources/PerchApp/Workspace/ClipsPage.swift').read_text()
        self.assertIn('clip.displayTitle(copied: copied)', clips)

        verbatim_branches = {
            'Settings/PermissionPanel.swift': 'Button(model.requesting == feature ? "Requesting…" : "Allow")',
            'Settings/AgentsSettings.swift': 'Button(copied == "cmd" ? "Copied" : "Copy")',
            'Settings/HistoryList.swift': 'Text(query.isEmpty ? "Finished days show up here."',
            'Workspace/WeekPage.swift': 'Text(anchor == 0 ? "This week" : "Week")',
            'Workspace/TaskDetailsSheet.swift': 'Text(readOnly ? "History"',
            'Workspace/TaskRow.swift': 'Button(task.done ? "Reopen" : "Complete"',
            'Workspace/HomeCards.swift': 'Label(running ? "Pause" : "Continue"',
            'Workspace/ClipsPage.swift': 'Button(clip.pinned ? "Unpin" : "Pin")',
        }
        for relative, forbidden in verbatim_branches.items():
            self.assertNotIn(forbidden, (ROOT / 'Sources/PerchApp' / relative).read_text(), relative)
        task_row = (ROOT / 'Sources/PerchApp/Workspace/TaskRow.swift').read_text()
        self.assertNotIn('.help(task.done ? "Reopen task" : "Complete task")', task_row)

    def test_native_status_observes_and_uses_the_requested_text_environment(self):
        status = (ROOT / 'Sources/PerchApp/Workspace/Components/StatusLabel.swift').read_text()
        self.assertIn('@Environment(\\.dynamicTypeSize)', status)
        self.assertIn('@Environment(\\.layoutDirection)', status)
        self.assertIn('.font(.system(size: Self.pointSize(for: dynamicTypeSize)', status)
        self.assertRegex(status, r'\.preference\(\s*key: LayoutMetricsKey\.self')
        native = (ROOT / 'Tests/PerchAppTests/LocalizationTests.swift').read_text()
        self.assertNotIn('host.userInterfaceLayoutDirection', native)
        # The leading frame must be INSIDE the direction override, not its parent.
        self.assertEqual(native.count('.frame(width: 280, alignment: .leading)'), 2)
        for host in native.split('let host = NSHostingView(')[1:]:
            root = host.split('let window = NSWindow(', 1)[0]
            self.assertLess(root.index('.frame(width: 280, alignment: .leading)'),
                            root.index('.environment(\\.layoutDirection, direction)'))
        self.assertIn('onPreferenceChange(StatusLabel.LayoutMetricsKey.self)', native)
        self.assertIn('XCTAssertGreaterThan(enlargedLabelFrame.height, standardLabelFrame.height)', native)

    def test_runtime_catalog_lookup_never_uses_the_trapping_module_accessor(self):
        for relative in ('Sources/PerchApp/App/AppLocalization.swift',
                         'Sources/PerchUI/LocalizedStringCatalog.swift',
                         'Sources/PerchUI/LocalizationResources.swift'):
            self.assertNotIn('.module', (ROOT / relative).read_text(), relative)

    def test_native_catalog_test_selects_an_explicit_language_bundle(self):
        native = (ROOT / 'Tests/PerchAppTests/LocalizationTests.swift').read_text()
        self.assertIn('Set(generated.keys), Set(catalogStrings.keys)', native)
        self.assertIn('Bundle(path: languageDirectory.path)', native)
        self.assertIn('languageBundle.localizedString(forKey:', native)
        self.assertNotIn('String.LocalizationValue("General")', native)

    def test_week_measurement_hooks_match_production_source(self):
        from scripts import week_measurement_hooks
        source = (ROOT / 'Sources/PerchApp/Workspace/WeekPage.swift').read_text()
        instrumented = week_measurement_hooks.instrument(source)
        self.assertNotEqual(instrumented, source)
        self.assertEqual(len(week_measurement_hooks.EDITS), 5)
        for marker in ('WeekMeasure(key: "count:', 'WeekMeasure(key: "add:', 'week-overflow-'):
            self.assertIn(marker, instrumented)

    def test_all_interactive_capture_paths_validate_language_before_mutation(self):
        store = (ROOT / 'Sources/PerchApp/App/PlannerStore.swift').read_text()
        self.assertIn('guard let supported = parserLanguage() else', store)
        self.assertIn('return apply { try $0.addTasks(titles, on: day, literal: literal, language: language) }', store)
        for relative in ('Workspace/TasksCard.swift', 'Workspace/WeekPage.swift', 'Workspace/HomeCards.swift'):
            text = (ROOT / 'Sources/PerchApp' / relative).read_text()
            self.assertNotIn('try $0.addTasks', text, relative)
            self.assertIn('store.addTasks', text, relative)
        language = (ROOT / 'Sources/PlannerCore/TaskParserLanguage.swift').read_text()
        self.assertIn('case english = "en"', language)
        self.assertIn('throw UnsupportedTaskParserLanguage', language)

    def test_language_status_and_long_localized_help_wrap(self):
        settings = (ROOT / 'Sources/PerchApp/Settings/SettingsView.swift').read_text()
        self.assertIn('Section("Language")', settings)
        self.assertIn('Task entry parser', settings)
        self.assertGreaterEqual(settings.count('.fixedSize(horizontal: false, vertical: true)'), 2)


if __name__ == '__main__':
    unittest.main()
