/**
 * Report an agent's tool calls to Notchd from TypeScript or JavaScript.
 *
 * Wrap each tool call in `before` and `after`. Notchd checkpoints the declared
 * paths before the call, diffs them after it, and shows the call in the notch
 * and the timeline. Every call here swallows errors on purpose: Notchd not
 * running must never break the agent. Works under Node and Bun.
 */

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

const HOOK = "/Applications/Notchd.app/Contents/MacOS/notchd-hook";

/** Sends one event to Notchd and resolves once it has been acknowledged. */
export function emit(event: Record<string, unknown>): Promise<void> {
  return new Promise((resolve) => {
    try {
      const child = spawn(HOOK, ["emit"], { stdio: ["pipe", "ignore", "ignore"] });
      child.on("error", () => resolve());
      child.on("exit", () => resolve());
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify(event));
    } catch {
      resolve();
    }
  });
}

/** One agent session as Notchd sees it. */
export class Notchd {
  readonly session: string;

  /** Starts a session; `vendor` is your agent's slug. */
  constructor(readonly vendor: string, readonly cwd: string, session?: string) {
    this.session = session ?? randomUUID();
    void emit(this.event("session.start"));
  }

  /** Announces a tool call and returns the id to pass to `after`. Await it before running the tool. */
  async before(tool: string, args: unknown, paths: string[]): Promise<string> {
    const callId = randomUUID();
    await emit(this.event("tool.before", { tool, tool_use_id: callId, args, paths }));
    return callId;
  }

  /** Reports the call's outcome. */
  async after(tool: string, callId: string, result?: unknown, error?: string): Promise<void> {
    await emit(this.event(error ? "tool.failed" : "tool.after", { tool, tool_use_id: callId, result, error }));
  }

  /** Ends the session. */
  async end(): Promise<void> {
    await emit(this.event("session.end"));
  }

  /** Builds an event with the session's constant fields. */
  private event(kind: string, fields: Record<string, unknown> = {}): Record<string, unknown> {
    const event: Record<string, unknown> = { kind, vendor: this.vendor, session: this.session, cwd: this.cwd };
    for (const [key, value] of Object.entries(fields)) {
      if (value !== undefined && value !== null) event[key] = value;
    }
    return event;
  }
}
