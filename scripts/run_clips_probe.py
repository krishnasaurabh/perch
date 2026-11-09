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
subprocess.run([binary], env=dict(os.environ, PERCH_DATA=str(data), CLIPS_OUTPUT=str(out)),
               check=True, timeout=60)
