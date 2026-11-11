"""Conservative evidence qualification, independent of codecs and presentation frames."""
import math
import re

CLIPS = ('open', 'close', 'page', 'tick', 'timer')
EXPECTED = {'page': 'ax-press:Week', 'tick': 'ax-press:task-complete-', 'timer': 'ax-press:Start focus'}

def qualify(marker, sha):
    reasons = []
    policy = marker.get('policy', {})
    for key in ('nsworkspace_reduce_motion', 'swiftui_reduce_motion', 'resolved_reduce_motion', 'explicit_reduce_motion'):
        if not isinstance(policy.get(key), bool):
            reasons.append('missing-policy:' + key)
    if policy.get('resolved_reduce_motion') != policy.get('explicit_reduce_motion'):
        reasons.append('inconsistent-policy')
    mode = policy.get('mode')
    if mode == 'production':
        if policy.get('resolved_reduce_motion') != policy.get('swiftui_reduce_motion') or policy.get('explicit_reduce_motion') != policy.get('nsworkspace_reduce_motion'):
            reasons.append('production-policy-disagreement')
    elif mode in ('diagnostic-normal', 'diagnostic-reduced'):
        expected = mode == 'diagnostic-reduced'
        if policy.get('resolved_reduce_motion') != expected or policy.get('explicit_reduce_motion') != expected:
            reasons.append('incorrect-diagnostic-policy')
    else:
        reasons.append('missing-policy-mode')
    after = marker.get('settled_state', {})
    name = marker.get('name')
    if name == 'open' and after.get('expanded') is not True:
        reasons.append('open-not-observed')
    if name == 'close' and after.get('expanded') is not False:
        reasons.append('close-not-observed')
    if name == 'page' and after.get('page') != 'week':
        reasons.append('page-not-observed')
    if name == 'tick' and after.get('completed_tasks', -1) <= marker.get('session', {}).get('completed_tasks', -1):
        reasons.append('tick-not-observed')
    if name == 'timer' and after.get('timer_present') is not True:
        reasons.append('timer-not-observed')
    expected_control = EXPECTED.get(name)
    if name == 'tick':
        task_id = marker.get('task_id')
        valid_id = isinstance(task_id, str) and re.fullmatch(
            r'[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}', task_id)
        expected_control = EXPECTED['tick'] + task_id if valid_id else None
        if after.get('completed_target') is not True:
            reasons.append('tick-target-not-observed')
    if name in EXPECTED and (expected_control is None or marker.get('via') != expected_control):
        reasons.append('missing-real-control')
    if marker.get('interaction_ok') is False:
        reasons.append('failed-interaction')
    session = marker.get('session', {})
    if session.get('screen_locked') is not False or session.get('session_available') is not True or session.get('on_console') is not True:
        reasons.append('locked-or-unknown-session')
    if len(sha or '') != 40 or any(c not in '0123456789abcdef' for c in sha or ''):
        reasons.append('missing-exact-sha')
    return {'qualified': not reasons, 'reasons': reasons}

def window_bounds(marker_time, next_time=None, pre=.3, post=1.25):
    # Stay before BOTH the observed next transition and its predicted action time.
    end = min(marker_time + post, next_time - .10) if next_time is not None else marker_time + post
    if end <= marker_time:
        raise ValueError('overlapping action windows')
    return marker_time - pre, end

def candidate_stats(times, samples, threshold=.25):
    """Unclassified pixel changes, never a geometry/opacity or settling claim."""
    def delta(a, b):
        return sum(abs(x-y) for x, y in zip(a, b)) / len(a)
    changed = [i for i in range(1, len(samples)) if delta(samples[i-1], samples[i]) > threshold]
    if not changed:
        return dict(changed_source_indices=[], unique_unclassified_intermediates=0,
                    unclassified_intermediate_source_indices=[], whole_window_change_span_s=0)
    first, last = changed[0], changed[-1]
    candidates = []
    for i in changed[:-1]:
        if delta(samples[i], samples[first-1]) > threshold and delta(samples[i], samples[last]) > threshold:
            if all(delta(samples[i], samples[j]) > threshold for j in candidates):
                candidates.append(i)
    return dict(changed_source_indices=changed, unique_unclassified_intermediates=len(candidates),
                unclassified_intermediate_source_indices=candidates,
                whole_window_change_span_s=round(times[last]-times[first-1], 4))


def provenance_errors(build, candidate_sha, source_kind, recorder):
    errors = []
    if (not build.get('build_verified') or build.get('build_sha') != candidate_sha
            or build.get('expected_sha') != candidate_sha
            or build.get('binary_sha256') != build.get('observed_binary_sha256')):
        errors.append('missing-or-mismatched-build-provenance')
    if source_kind != 'compositor-driver' or recorder not in (
            'screencapture -V (real compositor output)', 'ffmpeg avfoundation (real compositor output)'):
        errors.append('missing-compositor-source-provenance')
    return errors
