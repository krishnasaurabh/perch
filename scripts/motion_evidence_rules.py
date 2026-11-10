"""Conservative evidence qualification, independent of codecs and presentation frames."""
import math

CLIPS = ('open', 'close', 'page', 'tick', 'timer', 'closed-timer')
EXPECTED = {'page': 'ax-press:Week', 'tick': 'ax-press:Check off task', 'timer': 'ax-press:Start focus'}

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
    if name == 'closed-timer':
        before = marker.get('session', {})
        started = marker.get('timer_start', {})
        stopped = marker.get('timer_stop', {})
        if (marker.get('via') != 'PlannerStore.apply:startTimer'
                or marker.get('interaction_ok') is not True
                or before.get('expanded') is not False or before.get('activity_nil') is not True
                or before.get('timer_present') is not False
                or started.get('expanded') is not False or started.get('activity_nil') is not True
                or started.get('timer_present') is not True
                or started.get('placement') not in ('left', 'right')):
            reasons.append('closed-timer-start-not-observed')
        if (stopped.get('via') != 'PlannerStore.apply:stopTimer'
                or stopped.get('interaction_ok') is not True
                or stopped.get('expanded') is not False or stopped.get('activity_nil') is not True
                or stopped.get('timer_present') is not False
                or after.get('expanded') is not False or after.get('timer_present') is not False):
            reasons.append('closed-timer-stop-not-observed')
        times = (marker.get('t'), started.get('observed_epoch'), stopped.get('t'))
        if (not all(isinstance(t, (float, int)) and math.isfinite(t) for t in times)
                or not times[0] <= times[1] < times[2] < times[0] + 1.25):
            reasons.append('closed-timer-edges-outside-window')
    if marker.get('name') in EXPECTED and marker.get('via') != EXPECTED[marker['name']]:
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
