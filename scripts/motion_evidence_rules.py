"""Conservative evidence qualification, independent of codecs and presentation frames."""
import math

CLIPS = ('open', 'close', 'page', 'tick', 'timer')
EXPECTED = {'page': 'ax-press:Week', 'tick': 'ax-press:Check off task', 'timer': 'ax-press:Start focus'}

def qualify(marker, sha):
    reasons = []
    policy = marker.get('policy', {})
    for key in ('nsworkspace_reduce_motion', 'swiftui_reduce_motion', 'resolved_reduce_motion', 'explicit_reduce_motion'):
        if not isinstance(policy.get(key), bool):
            reasons.append('missing-policy:' + key)
    if policy.get('resolved_reduce_motion') != policy.get('explicit_reduce_motion'):
        reasons.append('inconsistent-policy')
    if marker.get('name') in EXPECTED and marker.get('via') != EXPECTED[marker['name']]:
        reasons.append('missing-real-control')
    if marker.get('interaction_ok') is False:
        reasons.append('failed-interaction')
    session = marker.get('session', {})
    if session.get('screen_locked') is not False:
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
