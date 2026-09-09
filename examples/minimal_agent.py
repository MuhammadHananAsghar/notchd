"""
The smallest agent that Notchd can record and undo: it writes a file. The
three lines that matter are the `Notchd(...)`, the `before`, and the `after`.
Run it, open the notch, and the session appears with one created file that
the timeline can revert.
"""

import os
import subprocess
import sys

from notchd import Notchd

cwd = os.getcwd()
path = os.path.join(cwd, "hello-from-agent.txt")

session = Notchd(vendor="minimal-agent", cwd=cwd)
call = session.before("write", {"path": path}, paths=[path])
with open(path, "w", encoding="utf-8") as handle:
    handle.write("hello\n")
session.after("write", call, result={"bytes": 6})

call = session.before("shell", {"command": "ls"}, paths=[cwd])
output = subprocess.run(["ls"], capture_output=True, text=True, cwd=cwd)
session.after("shell", call, result={"exit": output.returncode})
session.end()
print("recorded; open the notch", file=sys.stderr)
