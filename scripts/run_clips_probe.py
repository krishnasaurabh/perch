"""Launch the macOS Clips fixture with all automatic integrations disabled."""
import json
import os
from pathlib import Path
import subprocess
import sys

binary, output = sys.argv[1:]
out = Path(output)
out.mkdir(parents=True, exist_ok=True)
data = out / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
                                          'catchCopies': False,
                                          'catchScreenshots': False,
                                          'remindersSync': False}}))
# The probe runs the full Clips matrix (16 state captures), the preview gates,
# the native row-menu Pin/Unpin/Remove/Undo actions and eight capture-toggle
# interactions; their combined observed runtime is close to 90s, so the harness
# allows headroom without turning a hang into a silent pass.
TIMEOUT_SECONDS = 150
subprocess.run([binary], env=dict(os.environ, PERCH_DATA=str(data), CLIPS_OUTPUT=str(out)),
               check=True, timeout=TIMEOUT_SECONDS)
