"""Schedule integration stays on the existing calendar and command boundaries."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
CARD = ROOT / 'Sources/PerchApp/Workspace/YourDayCard.swift'


class YourDayContractTests(unittest.TestCase):
    def test_shared_capture_and_edit_state_are_consumed(self):
        source = CARD.read_text()
        for required in ('@Environment(TodayHomeState.self)', 'home.captureDraft',
                         'home.editingTaskID', 'home.selectedTaskID'):
            self.assertIn(required, source)

    def test_calendar_remains_read_only_and_honors_preferences(self):
        source = CARD.read_text()
        for required in ('@ObservedObject var calendar: CalendarService', 'calendar.$events',
                         'showCalendarMeetings', 'hiddenCalendarIDs', 'calendar.yourDayMeetings(',
                         'calendar.requestAccess()', 'setCalendarEventCompleted'):
            self.assertIn(required, source)
        self.assertNotIn('EKEventStore()', source)
        self.assertNotIn('AgendaCard', (ROOT / 'Sources/PerchApp/Workspace/HomeCards.swift').read_text())

    def test_drop_identity_and_keyboard_moves_share_gateway(self):
        source = CARD.read_text()
        self.assertIn('.dropDestination(for: TaskDragItem.self)', source)
        self.assertIn('.draggable(TaskDragItem(taskID: id))', source)
        self.assertRegex(source, r'timeline\.dropTime\(\s*in: item')
        self.assertIn('timeline.snapped(', source)
        self.assertIn('key.modifiers.contains(.option)', source)
        self.assertIn('commands.updateTask(id) { $0.startAt = start }', source)
        self.assertIn('task.day == store.today', source)
        self.assertNotIn('ViewThatFits', source)

    def test_paint_and_type_use_design_tokens(self):
        source = CARD.read_text()
        self.assertIn('Card(.mint)', source)
        self.assertIn('Theme.paper', source)
        self.assertIn('Theme.butter', source)
        self.assertIn('Theme.carried', source)
        self.assertIn('FocusRing(', source)
        self.assertIn('.strikethrough(item.done)', source)
        self.assertNotRegex(source, r'\.system\(size:|Color\(hex:|\.animation\(')
        self.assertNotRegex(source, r'\.(?:padding|cornerRadius)\(\s*\d')

    def test_each_schedule_state_has_a_registered_snapshot(self):
        shots = (ROOT / 'scripts/redesign_shots.list').read_text()
        targets = (ROOT / 'Sources/PerchApp/App/AppDelegate+Preview.swift').read_text()
        for name in ('running', 'before', 'editing', 'capture', 'open', 'overlap'):
            match = re.search(rf'^your-day-{name} .*--open (\S+)$', shots, re.M)
            self.assertIsNotNone(match, name)
            assert match is not None
            self.assertIn(f'"{match.group(1)}": .window(', targets)


if __name__ == '__main__':
    unittest.main()
