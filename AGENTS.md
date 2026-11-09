# Publication hygiene

Do not commit internal research, reverse-engineering output, third-party reference materials, transcripts, audit reports, or pipeline logs. Describe verified Perch functionality without provenance or legal assurances.

Keep technical evidence outside git and put work reports in kanban, not in the product repository. Do not add product comparisons.

Enable local hooks with `git config core.hooksPath .githooks`. Check staged files with `python3 scripts/check_repository.py --staged`; CI checks reachable history automatically.
