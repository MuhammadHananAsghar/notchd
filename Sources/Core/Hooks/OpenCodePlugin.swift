// OpenCodePlugin.swift
// OpenCode takes plugins rather than command hooks: a JavaScript module in
// its plugin directory that exports a function returning hook handlers. The
// plugin API on this machine (@opencode-ai/plugin 1.0.25) offers
// `tool.execute.before` with `{tool, sessionID, callID}` and `{args}`, and
// `tool.execute.after` with `{title, output, metadata}`, plus an `event`
// handler that sees `session.created`. Notchd writes a small plugin that
// turns those into protocol events and sends each through `notchd-hook
// emit`, waiting for the acknowledgement so the checkpoint lands before the
// tool runs. Fidelity is official: the agent itself reports the call.

import Foundation

/// Notchd's OpenCode plugin file.
struct OpenCodePlugin: AgentIntegration {
    /// The plugin file.
    let url: URL

    /// The marker the generated file carries.
    static let marker = "notchd-hook"

    /// The generated plugin's version. Bumped whenever the source changes, so
    /// a file written by an earlier build reads as needing Install again.
    static let version = 2

    /// The line that carries the version inside the generated file.
    static var versionLine: String { "const NOTCHD_PLUGIN_VERSION = \(version);" }

    /// OpenCode's configuration directory, honouring XDG_CONFIG_HOME.
    /// - Parameter environment: The process environment.
    /// - Returns: The directory.
    static func configurationDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("opencode", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode", isDirectory: true)
    }

    /// The default plugin location.
    /// - Parameter environment: The process environment.
    /// - Returns: `<config>/plugin/notchd.js`.
    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configurationDirectory(environment: environment).appendingPathComponent("plugin", isDirectory: true).appendingPathComponent("notchd.js")
    }

    var displayName: String { "OpenCode" }
    var targetPath: String { url.path }

    var vendorPresent: Bool {
        FileManager.default.fileExists(atPath: url.deletingLastPathComponent().deletingLastPathComponent().path)
    }

    var explanation: String {
        "Writes a small plugin into OpenCode's plugin directory. It reports every tool call before and after it runs, waits for Notchd's checkpoint, and says when a turn is finished. After a Notchd update the card asks for Install again, and OpenCode picks the new file up on its next start. Fidelity: recorded by hook."
    }

    /// Whether this build's plugin is in place: the file exists, carries the
    /// marker, and is this build's version.
    /// - Returns: True when nothing needs installing.
    func isInstalled() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.contains(Self.marker) && text.contains(Self.versionLine)
    }

    /// Writes the plugin.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    func install(binaryPath: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.source(binaryPath: binaryPath).utf8).write(to: url, options: .atomic)
    }

    /// Removes the plugin file.
    func uninstall() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The plugin source, which is also what the settings window shows.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: JavaScript.
    func snippet(binaryPath: String) -> String {
        Self.source(binaryPath: binaryPath)
    }

    /// The plugin source with the hook path baked in.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: An ES module exporting `NotchdPlugin`.
    static func source(binaryPath: String) -> String {
        let escaped = binaryPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        /**
         * Notchd plugin for OpenCode. Written by Notchd; reinstall from Notchd's
         * settings window to update the hook path. It reports each tool call to
         * Notchd before and after it runs and does nothing else.
         */
        import { spawn } from "node:child_process";

        \(versionLine)
        const HOOK = "\(escaped)";
        const FILE_TOOLS = new Set(["edit", "write", "multiedit", "patch"]);
        const SHELL_TOOLS = new Set(["bash", "shell"]);
        const OUTPUT_LIMIT = 65536;

        function send(event) {
          return new Promise((resolve) => {
            try {
              const child = spawn(HOOK, ["emit"], { stdio: ["pipe", "pipe", "ignore"] });
              let out = "";
              child.stdout.on("data", (chunk) => { out += chunk; });
              child.on("error", () => resolve(null));
              child.on("exit", () => {
                try { resolve(out.trim() ? JSON.parse(out) : null); } catch (_) { resolve(null); }
              });
              child.stdin.on("error", () => {});
              child.stdin.end(JSON.stringify(event));
            } catch (_) {
              resolve(null);
            }
          });
        }

        function enforce(decision) {
          if (decision && decision.decision === "deny") {
            throw new Error("Blocked by Notchd: " + (decision.reason || "a guard rule matched"));
          }
        }

        function declaredPaths(tool, args, directory) {
          const file = args && (args.filePath || args.file_path || args.path);
          if (FILE_TOOLS.has(tool) && typeof file === "string") return [file];
          if (SHELL_TOOLS.has(tool)) return [(args && typeof args.workdir === "string" && args.workdir) || directory];
          return [];
        }

        export const NotchdPlugin = async ({ directory }) => ({
          event: async ({ event }) => {
            if (!event || !event.properties) return;
            if (event.type === "session.created" && event.properties.info) {
              const info = event.properties.info;
              await send({ kind: "session.start", vendor: "opencode", session: String(info.id), cwd: info.directory || directory });
            } else if (event.type === "session.idle" && event.properties.sessionID) {
              await send({ kind: "note", vendor: "opencode", session: String(event.properties.sessionID), cwd: directory, meta: { event: "session.idle" } });
            }
          },
          "tool.execute.before": async (input, output) => {
            enforce(await send({
              kind: "tool.before", vendor: "opencode", session: input.sessionID, cwd: directory,
              tool: input.tool, tool_use_id: input.callID, args: output.args,
              paths: declaredPaths(input.tool, output.args, directory),
            }));
          },
          "tool.execute.after": async (input, output) => {
            await send({
              kind: "tool.after", vendor: "opencode", session: input.sessionID, cwd: directory,
              tool: input.tool, tool_use_id: input.callID,
              result: { title: output.title, output: String(output.output || "").slice(0, OUTPUT_LIMIT) },
            });
          },
        });
        """
    }
}
