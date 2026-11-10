import json
import unittest
from motion_evidence_rules import qualify, window_bounds, candidate_stats

class EvidenceRulesTests(unittest.TestCase):
    def marker(self):
        return {'name': 'timer', 'via': 'ax-press:Start focus', 'interaction_ok': True,
                'policy': dict(nsworkspace_reduce_motion=False, swiftui_reduce_motion=False,
                               resolved_reduce_motion=False, explicit_reduce_motion=False),
                'session': {'screen_locked': False}}

    def test_missing_policy_fails(self):
        m = self.marker(); del m['policy']['swiftui_reduce_motion']
        self.assertFalse(qualify(m, 'a'*40)['qualified'])

    def test_missing_control_and_old_fallback_fail(self):
        for via in ('direct:startTimer', 'FAILED:missing-control:Start focus', 'none'):
            m = self.marker(); m['via'] = via
            self.assertFalse(qualify(m, 'a'*40)['qualified'])

    def test_shared_override_and_session_required(self):
        m = self.marker(); self.assertTrue(qualify(m, 'a'*40)['qualified'])
        m['policy']['explicit_reduce_motion'] = True
        self.assertFalse(qualify(m, 'a'*40)['qualified'])
        m = self.marker(); m['session']['screen_locked'] = True
        self.assertFalse(qualify(m, 'a'*40)['qualified'])

    def test_clip_excludes_next_action_and_teardown(self):
        for next_time in (11.0, 11.2):
            low, high = window_bounds(10, next_time)
            self.assertLess(high, next_time)
            self.assertEqual(low, 9.7)
        self.assertRaises(ValueError, window_bounds, 10, 10.01)

    def test_focus_countdown_are_not_quality_metrics(self):
        # Deliberately synthetic byte fixtures, not recorded evidence.
        s = candidate_stats([0, .1, .6, 1.1], [b'\x00', b'\x20', b'\x21', b'\x22'])
        self.assertNotIn('settle_time_s', s)
        self.assertNotIn('target_intermediates', s)
        self.assertIn('unique_unclassified_intermediates', s)

    def test_unique_not_held_grid_count(self):
        s = candidate_stats([0,.1,.2,.3,.4,.5], [b'\x00',b'\x10',b'\x10',b'\x20',b'\x10',b'\x30'])
        self.assertEqual(s['unique_unclassified_intermediates'], 2)

    def test_deterministic(self):
        args = ([0,.1,.2], [b'\x00', b'\x10', b'\x20'])
        self.assertEqual(json.dumps(candidate_stats(*args)), json.dumps(candidate_stats(*args)))

if __name__ == '__main__': unittest.main()
