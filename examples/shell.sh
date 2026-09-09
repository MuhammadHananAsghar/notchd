#!/bin/sh
# Report a shell step to Notchd from any script. Send tool.before with the
# paths the step may change, run the step, send tool.after. Notchd checkpoints
# the paths in between and records what changed.

HOOK=/Applications/Notchd.app/Contents/MacOS/notchd-hook
SESSION=${NOTCHD_SESSION:-$(date +%s)}
CWD=$(pwd)

emit() {
  printf '%s' "$1" | "$HOOK" emit
}

emit "{\"kind\":\"session.start\",\"vendor\":\"shell-agent\",\"session\":\"$SESSION\",\"cwd\":\"$CWD\"}"
emit "{\"kind\":\"tool.before\",\"vendor\":\"shell-agent\",\"session\":\"$SESSION\",\"cwd\":\"$CWD\",\"tool\":\"shell\",\"tool_use_id\":\"1\",\"args\":{\"command\":\"$*\"},\"paths\":[\"$CWD\"]}"
"$@"
STATUS=$?
emit "{\"kind\":\"tool.after\",\"vendor\":\"shell-agent\",\"session\":\"$SESSION\",\"cwd\":\"$CWD\",\"tool\":\"shell\",\"tool_use_id\":\"1\",\"result\":{\"exit\":$STATUS}}"
exit $STATUS
