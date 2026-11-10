import json
import unittest
from motion_evidence_rules import qualify, window_bounds, candidate_stats, provenance_errors

class EvidenceRulesTests(unittest.TestCase):
    def marker(self):
        return {'name': 'timer', 'via': 'ax-press:Start focus', 'interaction_ok': True,
                'policy': dict(nsworkspace_reduce_motion=False, swiftui_reduce_motion=False,
                               resolved_reduce_motion=False, explicit_reduce_motion=False, mode='production'),
                'session': {'screen_locked': False, 'session_available': True, 'on_console': True}, 'settled_state': {'timer_present': True}}

    def test_wrong_diagnostic_and_production_policy_fail(self):
        m = self.marker(); m['policy']['mode'] = 'diagnostic-reduced'
        self.assertFalse(qualify(m, 'a'*40)['qualified'])
        m = self.marker(); m['policy']['nsworkspace_reduce_motion'] = True
        self.assertFalse(qualify(m, 'a'*40)['qualified'])
        m = self.marker(); m['settled_state']['timer_present'] = False
        self.assertFalse(qualify(m, 'a'*40)['qualified'])

    def test_workspace_removal_keeps_explicit_layer(self):
        from pathlib import Path
        source = (Path(__file__).resolve().parents[1] / 'Sources/Perch/Notch/NotchRootView.swift').read_text()
        workspace = source.split('WorkspaceView(notchHeight: g.notchSize.height)', 1)[1].split('.transition(motionPolicy.workspaceTransition)', 1)[0]
        self.assertIn('.zIndex(1)', workspace)

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

    def test_provenance_rejects_old_binary_and_own_window(self):
        build = dict(build_verified=True, build_sha='a'*40, expected_sha='a'*40,
                     binary_sha256='b'*64, observed_binary_sha256='b'*64)
        self.assertEqual([], provenance_errors(build, 'a'*40, 'compositor-driver',
                          'screencapture -V (real compositor output)'))
        self.assertTrue(provenance_errors(build, 'c'*40, 'compositor-driver',
                        'screencapture -V (real compositor output)'))
        self.assertTrue(provenance_errors(build, 'a'*40, 'own-window-driver', 'NSView.cacheDisplay'))

    def test_deterministic(self):
        args = ([0,.1,.2], [b'\x00', b'\x10', b'\x20'])
        self.assertEqual(json.dumps(candidate_stats(*args)), json.dumps(candidate_stats(*args)))

class ClosedTimerEvidenceTests(unittest.TestCase):
    def marker(self):
        m = EvidenceRulesTests().marker()
        m.update(name='closed-timer', via='PlannerStore.apply:startTimer', t=10.0,
                 timer_start=dict(observed_epoch=10.01, expanded=False, activity_nil=True,
                                  timer_present=True, placement='right'),
                 timer_stop=dict(t=10.66, via='PlannerStore.apply:stopTimer', interaction_ok=True,
                                 expanded=False, activity_nil=True, timer_present=False),
                 settled_state=dict(expanded=False, timer_present=False))
        m['session'].update(expanded=False, activity_nil=True, timer_present=False)
        return m

    def test_closed_timer_registration_is_additive(self):
        import ast
        from pathlib import Path
        from motion_evidence_rules import CLIPS
        expected = ('open', 'close', 'page', 'tick', 'timer', 'closed-timer')
        self.assertEqual(CLIPS, expected)
        tree = ast.parse(Path(__file__).with_name('motion_evidence.py').read_text())
        registered = next(ast.literal_eval(n.value) for n in tree.body
                          if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'CLIPS' for t in n.targets))
        self.assertEqual(tuple(registered), expected)

    def test_closed_timer_qualifies_all_policies_and_sides(self):
        for mode, reduced in (('production', False), ('production', True),
                              ('diagnostic-normal', False), ('diagnostic-reduced', True)):
            for side in ('left', 'right'):
                m = self.marker(); m['timer_start']['placement'] = side
                m['policy'] = dict(nsworkspace_reduce_motion=reduced, swiftui_reduce_motion=reduced,
                                   resolved_reduce_motion=reduced, explicit_reduce_motion=reduced, mode=mode)
                self.assertEqual(qualify(m, 'a'*40), {'qualified': True, 'reasons': []})

    def test_closed_timer_rejects_missing_or_wrong_edge_state(self):
        cases = [('session', 'expanded', True), ('session', 'activity_nil', False),
                 ('session', 'timer_present', True), ('timer_start', 'expanded', True),
                 ('timer_start', 'activity_nil', False), ('timer_start', 'timer_present', False),
                 ('timer_start', 'placement', 'hidden'), ('timer_stop', 'expanded', True),
                 ('timer_stop', 'activity_nil', False), ('timer_stop', 'timer_present', True),
                 ('timer_stop', 'interaction_ok', False), ('settled_state', 'timer_present', True)]
        for section, key, value in cases:
            for missing in (False, True):
                with self.subTest(section=section, key=key, missing=missing):
                    m = self.marker()
                    if missing: del m[section][key]
                    else: m[section][key] = value
                    self.assertFalse(qualify(m, 'a'*40)['qualified'])

    def test_closed_timer_requires_real_store_edges(self):
        for section, key in ((None, 'via'), ('timer_stop', 'via')):
            for value in ('direct:view-state', 'none', 'FAILED:store'):
                m = self.marker(); (m if section is None else m[section])[key] = value
                self.assertFalse(qualify(m, 'a'*40)['qualified'])
        for field in ('timer_start', 'timer_stop'):
            m = self.marker(); del m[field]
            self.assertFalse(qualify(m, 'a'*40)['qualified'])

    def test_closed_timer_requires_ordered_edges_within_existing_window(self):
        for section, key, value in (('timer_start', 'observed_epoch', 9.9),
                                    ('timer_stop', 't', 10.0), ('timer_stop', 't', 11.25),
                                    ('timer_stop', 't', float('nan')), ('timer_stop', 't', '10.66')):
            m = self.marker(); m[section][key] = value
            self.assertFalse(qualify(m, 'a'*40)['qualified'])


if __name__ == '__main__': unittest.main()
