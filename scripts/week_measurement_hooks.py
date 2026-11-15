#!/usr/bin/env python3
"""Add native measurement markers to an isolated copy of WeekPage."""
from pathlib import Path
import sys

EDITS = {
    '.layoutPriority(1)': '.layoutPriority(1)\n                .background(WeekMeasure(key: "title:\\(task.id)"))',
    '.coordinateSpace(.named(Self.space))': '.coordinateSpace(.named(Self.space))\n            .background(WeekMeasure(key: "list:\\(ref.key?.raw ?? "inbox")"))',
    '.accessibilityLabel(\n                    AppL10n.format("%lld of %lld tasks complete", tasks.filter(\\.done).count, tasks.count))':
        '.accessibilityLabel(\n                    AppL10n.format("%lld of %lld tasks complete", tasks.filter(\\.done).count, tasks.count))\n                    .background(WeekMeasure(key: "count:\\(key)"))',
    '.accessibilityLabel(AppL10n.format("%lld more tasks below", hidden))':
        '.accessibilityLabel(AppL10n.format("%lld more tasks below", hidden))\n                    .accessibilityIdentifier("week-overflow-\\(ref.key?.raw ?? "inbox")")',
    '            .onSubmit {': '            .background(WeekMeasure(key: "add:\\(ref.key?.raw ?? "inbox")"))\n            .onSubmit {',
}


BOARD_EDITS = {
    '.frame(width: layout.width(for: day))': '.frame(width: layout.width(for: day))\n                                .background(WeekMeasure(key: "board-column:\\(day.raw)"))',
    '.frame(width: layout.parkingWidth)': '.frame(width: layout.parkingWidth)\n                            .background(WeekMeasure(key: "board-parking"))',
    # The visible title now sizes the row outside AppKit's flattened Menu label.
    # Measure that live SwiftUI subtree, not the transparent popup overlay.
    '.accessibilityHidden(true)\n                    .overlay {': '.accessibilityHidden(true)\n                    .background(WeekMeasure(key: "board-title:\\(task.id)"))\n                    .overlay {',
}


def instrument(week):
    """Return instrumented source, requiring every production hook exactly once."""
    # The legacy direct host keeps its long-title/scroll regression probe. The
    # workspace board has the separate two-line title contract.
    prefix, marker, legacy = week.partition('struct LegacyWeekPage: View {')
    assert marker, 'Missing compatibility Week host'
    for old, new in EDITS.items():
        assert legacy.count(old) == 1, f'Week measurement hook changed: {old}'
        legacy = legacy.replace(old, new)
    assert '.font(Theme.body)' in legacy
    assert '.lineLimit(2)' not in legacy
    assert 'minimumScaleFactor' not in week and 'titleFit(' not in week
    for old, new in BOARD_EDITS.items():
        assert prefix.count(old) == 1, f'Week board measurement hook changed: {old}'
        prefix = prefix.replace(old, new)
    return prefix + marker + legacy


def main():
    path = Path(sys.argv[1])
    path.write_text(instrument(path.read_text()))


if __name__ == '__main__':
    main()
