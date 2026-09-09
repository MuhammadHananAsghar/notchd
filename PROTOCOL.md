# The Notchd protocol

Any agent can report to Notchd. One JSON object per event, written to the
standard input of `notchd-hook emit`, which lives inside the app bundle:

```
/Applications/Notchd.app/Contents/MacOS/notchd-hook emit
```

The hook forwards the event to the running app, waits for the app to say the
event is recorded and any checkpoint is taken, and exits 0. It exits 0 on
every failure too, including Notchd not running, so it can never block your
agent. A call takes a few milliseconds plus the checkpoint, which costs one
`lstat` per unchanged file under the paths you declare.

## Events

| Field | Type | Required | Meaning |
|---|---|---|---|
| `kind` | string | yes | One of `session.start`, `session.end`, `tool.before`, `tool.after`, `tool.failed`, `note` |
| `vendor` | string | yes | A short slug for your agent, such as `my-agent`. Lower case letters, digits, `-`, `_` |
| `session` | string | yes | Your session id. Every event with the same vendor and session is one lane |
| `cwd` | string | yes | The absolute working directory the agent is operating in |
| `tool` | string | no | The tool name, for tool events |
| `tool_use_id` | string | no | Your id for the call. Pairs a `tool.before` with its `tool.after`. Without it, Notchd pairs by order within the session |
| `args` | any JSON | no | The tool's input, verbatim |
| `result` | any JSON | no | The tool's output. Strings over 64 KB are truncated and marked |
| `error` | string | no | Why the call failed, for `tool.failed` |
| `paths` | array of strings | no | The absolute paths the call may change. This is what gets checkpointed before the call and diffed after it. A file for an edit tool, the working directory for a shell tool. Read-only tools declare nothing |
| `meta` | object | no | Anything else you want kept, such as a `prompt` |
| `ts` | string | no | ISO 8601. Defaults to the moment the hook received the event |
| `fidelity` | string | no | `official` by default. Say `derived` if you are reconstructing events after the fact |
| `pid` | number | no | Your process id |

Send `tool.before` with `paths` **before** the tool runs, and do not run the
tool until `notchd-hook` has exited: that is the checkpoint. Send `tool.after`
with the same `tool_use_id` when it is done and Notchd records every created,
modified, and deleted path under the declared paths as that call's work.

## What Notchd does with them

- A `session.start` warms a baseline of `cwd`, so the first checkpoint is fast
  and changes made outside any tool call still have an earlier copy.
- A `tool.before` with paths takes a checkpoint of those paths. A `tool.after`
  or `tool.failed` snapshots them again and records the difference.
- A `tool.after` with paths but no matching `tool.before` compares each
  declared file with the last copy Notchd holds. Use this for tools that can
  only report after the fact.
- Everything else is kept as a note on the session's page.

## Examples

Shell:

```sh
HOOK=/Applications/Notchd.app/Contents/MacOS/notchd-hook
echo '{"kind":"tool.before","vendor":"my-agent","session":"abc","cwd":"/Users/me/proj",
       "tool":"shell","tool_use_id":"1","args":{"command":"make build"},"paths":["/Users/me/proj"]}' | "$HOOK" emit
make build
echo '{"kind":"tool.after","vendor":"my-agent","session":"abc","cwd":"/Users/me/proj",
       "tool":"shell","tool_use_id":"1","result":{"exit":0}}' | "$HOOK" emit
```

Python, TypeScript, and a minimal agent are in [examples/](examples/).

## Decisions

When guard mode is on, a `tool.before` may be refused. `notchd-hook emit`
prints one JSON line on stdout and still exits 0:

```json
{"decision":"deny","reason":"Notchd guard rule: path matches \"~/.ssh/**\". SSH keys stay untouched."}
```

or `{"decision":"ask", ...}` when the rule asks you to put the call to the
user. Silence on stdout is allow. Honour a deny by not running the tool and
telling the model the reason. Vendors with their own refusal formats get
those instead: Claude Code a `hookSpecificOutput` permission decision, Gemini
CLI exit status 2 with the reason on stderr, Cursor a `permission` object.

## The envelope

`notchd-hook <vendor>` is the same binary used for vendors whose hooks send
their own payloads. It wraps whatever it reads in an envelope and lets the app
normalise it:

```json
{"v":1,"vendor":"claude","received_at":1757400000.123456,"raw":{...the vendor's payload...}}
```

`emit` is the spelling for a payload that is already a Notchd event. You can
also write envelopes straight to the socket at
`~/Library/Application Support/Notchd/notchd.sock`, one JSON object per
line, and read the `ok` line back.
