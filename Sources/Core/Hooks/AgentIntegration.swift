// AgentIntegration.swift
// What every agent integration offers the settings window: a name, the file
// it writes, whether the agent is present, the exact text it will write,
// and install and remove. Hook vendors, the OpenCode plugin, and Cursor's
// hooks file all conform, so the window shows one card per integration
// without knowing how each one works.

import Foundation

/// One way of connecting an agent to Notchd.
protocol AgentIntegration {
    /// The agent's name.
    var displayName: String { get }
    /// The file Install writes.
    var targetPath: String { get }
    /// Whether the agent appears to be installed for this user.
    var vendorPresent: Bool { get }
    /// One sentence on what installing does and at what fidelity.
    var explanation: String { get }
    /// Whether this build's integration is in place.
    func isInstalled() throws -> Bool
    /// Writes the integration.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    func install(binaryPath: String) throws
    /// Removes the integration, leaving the file as it was otherwise.
    func uninstall() throws
    /// The exact text Install will write or merge.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: Text for the settings window.
    func snippet(binaryPath: String) -> String
}

extension HookSettingsFile: AgentIntegration {
    var displayName: String { vendor.displayName }
    var targetPath: String { url.path }

    var explanation: String {
        "Adds one command hook per event to \(vendor.displayName)'s settings. Every tool call and session boundary is recorded, and a checkpoint is taken before each call runs. Fidelity: recorded by hook."
    }

    /// The `hooks` object as it would appear in settings.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: Pretty-printed JSON.
    func snippet(binaryPath: String) -> String {
        HookSettings.renderedSnippet(vendor: vendor, binaryPath: binaryPath)
    }
}
