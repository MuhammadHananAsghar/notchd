"""
Report an agent's tool calls to Notchd from Python.

Wrap each tool call in `before` and `after`. Notchd checkpoints the declared
paths before the call, diffs them after it, and shows the call in the notch
and the timeline. Every function here swallows errors on purpose: Notchd not
running must never break the agent.
"""

import json
import subprocess
import uuid

HOOK = "/Applications/Notchd.app/Contents/MacOS/notchd-hook"


def emit(event: dict) -> None:
    """Sends one event to Notchd and waits for its acknowledgement."""
    try:
        subprocess.run([HOOK, "emit"], input=json.dumps(event).encode(), timeout=6, check=False)
    except Exception:
        pass


class Notchd:
    """One agent session as Notchd sees it."""

    def __init__(self, vendor: str, cwd: str, session: str | None = None) -> None:
        """Starts a session; `vendor` is your agent's slug."""
        self.vendor = vendor
        self.cwd = cwd
        self.session = session or uuid.uuid4().hex
        emit(self._event("session.start"))

    def before(self, tool: str, args: dict, paths: list[str]) -> str:
        """Announces a tool call and returns the id to pass to `after`."""
        call_id = uuid.uuid4().hex
        emit(self._event("tool.before", tool=tool, tool_use_id=call_id, args=args, paths=paths))
        return call_id

    def after(self, tool: str, call_id: str, result=None, error: str | None = None) -> None:
        """Reports the call's outcome."""
        kind = "tool.failed" if error else "tool.after"
        emit(self._event(kind, tool=tool, tool_use_id=call_id, result=result, error=error))

    def end(self) -> None:
        """Ends the session."""
        emit(self._event("session.end"))

    def _event(self, kind: str, **fields) -> dict:
        """Builds an event with the session's constant fields."""
        event = {"kind": kind, "vendor": self.vendor, "session": self.session, "cwd": self.cwd}
        event.update({key: value for key, value in fields.items() if value is not None})
        return event
