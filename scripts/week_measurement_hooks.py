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


def instrument(week):
    """Return instrumented source, requiring every production hook exactly once."""
    for old, new in EDITS.items():
        assert week.count(old) == 1, f'Week measurement hook changed: {old}'
        week = week.replace(old, new)
    assert '.font(Theme.body)' in week
    assert '.lineLimit(2)' not in week
    assert 'minimumScaleFactor' not in week and 'titleFit(' not in week
    return week


def main():
    path = Path(sys.argv[1])
    path.write_text(instrument(path.read_text()))


if __name__ == '__main__':
    main()
