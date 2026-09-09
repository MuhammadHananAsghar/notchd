// main.swift
// notchd-hook: the binary every agent invokes. Usage: `notchd-hook <vendor>`,
// or `notchd-hook emit` for a payload that is already a Notchd protocol event.
// It reads the vendor's JSON from stdin, wraps it in an envelope with the
// vendor slug and the receipt time, writes the envelope to Notchd's unix
// socket, and exits 0. It exits 0 on every failure too, including Notchd not
// running, so nothing here can ever block an agent's tool call. It links only
// Darwin, which keeps its start-up well under the 20 ms budget.

import Darwin

/// Reads a descriptor to end of file.
/// - Parameter fd: The descriptor to drain.
/// - Returns: Every byte read.
func readAll(_ fd: Int32) -> [UInt8] {
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        result.append(contentsOf: buffer[0..<Int(count)])
    }
    return result
}

/// The value of an environment variable, or nil when unset or empty.
/// - Parameter name: The variable name.
/// - Returns: The value.
func environment(_ name: String) -> String? {
    guard let raw = getenv(name) else { return nil }
    let value = String(cString: raw)
    return value.isEmpty ? nil : value
}

/// The socket path, honouring the same NOTCHD_HOME override as the app.
/// - Returns: An absolute path.
func socketPath() -> String {
    let home = environment("NOTCHD_HOME") ?? ((environment("HOME") ?? "") + "/Library/Application Support/Notchd")
    return home + "/notchd.sock"
}

/// Seconds since 1970 with microsecond precision, formatted without Foundation.
/// - Returns: A decimal literal such as `1757400000.123456`.
func timestampLiteral() -> String {
    var now = timeval()
    gettimeofday(&now, nil)
    let micros = String(now.tv_usec)
    let padded = String(repeating: "0", count: max(0, 6 - micros.count)) + micros
    return "\(now.tv_sec).\(padded)"
}

/// A vendor slug safe to embed in JSON, or `unknown` when the argument is not a
/// plain slug. `emit` is the spelling for native protocol events.
/// - Parameter argument: The first command-line argument.
/// - Returns: The slug.
func vendorSlug(_ argument: String?) -> String {
    guard let argument else { return "unknown" }
    if argument == "emit" { return "notchd" }
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
    guard !argument.isEmpty, argument.count <= 32, argument.allSatisfy({ allowed.contains($0) }) else { return "unknown" }
    return argument
}

/// Builds the envelope line around a raw payload.
/// - Parameters:
///   - vendor: The slug.
///   - raw: The payload bytes, or empty.
/// - Returns: One newline-terminated JSON line.
func envelope(vendor: String, raw: [UInt8]) -> [UInt8] {
    let isSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
    let trimmed = Array(raw.drop(while: isSpace).reversed().drop(while: isSpace).reversed())
    let payload = trimmed.isEmpty ? Array("null".utf8) : trimmed
    let head = Array("{\"v\":1,\"vendor\":\"\(vendor)\",\"received_at\":\(timestampLiteral()),\"raw\":".utf8)
    return head + payload + Array("}\n".utf8)
}

/// Connects to the socket, writes the whole line, and reads the decision.
/// Failures mean allow: Notchd not running must never block a call.
/// - Parameters:
///   - path: The socket path.
///   - line: The bytes to send.
/// - Returns: The app's decision.
func send(_ line: [UInt8], to path: String) -> Decision {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .allow }
    defer { close(fd) }
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { return .allow }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
            for (index, byte) in path.utf8.enumerated() { chars[index] = CChar(bitPattern: byte) }
            chars[path.utf8.count] = 0
        }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return .allow }
    var offset = 0
    while offset < line.count {
        let written = line[offset...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        if written <= 0 { return .allow }
        offset += Int(written)
    }
    return awaitAcknowledgement(fd)
}

/// What the app decided about the call.
enum Decision {
    case allow
    case ask(String)
    case deny(String)
}

/// Waits for the server to say the message is recorded and any checkpoint is
/// taken, so the tool does not run before its before-state is captured, and
/// reads the guard's decision from the same line. Gives up after the budget
/// so a slow or wedged server still never blocks the agent; silence is allow.
/// - Parameter fd: The connected socket, already written to.
/// - Returns: The decision.
func awaitAcknowledgement(_ fd: Int32) -> Decision {
    shutdown(fd, SHUT_WR)
    var timeout = timeval(tv_sec: 4, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var buffer = [UInt8](repeating: 0, count: 1024)
    var received: [UInt8] = []
    while received.count < 8192 {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        received.append(contentsOf: buffer[0..<Int(count)])
        if received.contains(0x0A) { break }
    }
    let line = String(decoding: received.prefix { $0 != 0x0A }, as: UTF8.self)
    if line.hasPrefix("deny ") { return .deny(String(line.dropFirst(5))) }
    if line.hasPrefix("ask ") { return .ask(String(line.dropFirst(4))) }
    return .allow
}

/// Escapes a string for a JSON literal.
/// - Parameter text: The text.
/// - Returns: The escaped text without quotes.
func jsonEscaped(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            if scalar.value < 0x20 {
                result += "\\u00" + String(scalar.value, radix: 16).leftPadded(to: 2)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    return result
}

extension String {
    /// The string padded with zeros on the left.
    /// - Parameter width: The width wanted.
    /// - Returns: The padded string.
    func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(0, width - count)) + self
    }
}

/// What to tell the vendor, in its own words. Each vendor has its own way
/// of hearing a refusal: Claude Code reads a JSON decision on stdout, Gemini
/// CLI a blocking exit status with the reason on stderr, Cursor a permission
/// object, and a native emitter a plain JSON decision. An allow is silence,
/// except for Cursor, which needs to hear it.
/// - Parameters:
///   - vendor: The slug.
///   - decision: The app's decision.
/// - Returns: Text for stdout, text for stderr, and the exit status.
func reply(for vendor: String, decision: Decision) -> (stdout: String?, stderr: String?, status: Int32) {
    switch (vendor, decision) {
    case ("cursor", .allow):
        return ("{\"permission\":\"allow\"}\n", nil, 0)
    case (_, .allow):
        return (nil, nil, 0)
    case ("claude", .deny(let reason)), ("claude", .ask(let reason)):
        let verdict = { if case .deny = decision { return "deny" } else { return "ask" } }()
        let json = "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"\(verdict)\","
            + "\"permissionDecisionReason\":\"\(jsonEscaped(reason))\"}}\n"
        return (json, nil, 0)
    case ("gemini", .deny(let reason)), ("gemini", .ask(let reason)):
        return (nil, reason + "\n", 2)
    case ("cursor", .deny(let reason)):
        return ("{\"permission\":\"deny\",\"userMessage\":\"\(jsonEscaped(reason))\",\"agentMessage\":\"\(jsonEscaped(reason))\"}\n", nil, 0)
    case ("cursor", .ask(let reason)):
        return ("{\"permission\":\"ask\",\"userMessage\":\"\(jsonEscaped(reason))\"}\n", nil, 0)
    case (_, .deny(let reason)):
        return ("{\"decision\":\"deny\",\"reason\":\"\(jsonEscaped(reason))\"}\n", nil, 0)
    case (_, .ask(let reason)):
        return ("{\"decision\":\"ask\",\"reason\":\"\(jsonEscaped(reason))\"}\n", nil, 0)
    }
}

let vendor = vendorSlug(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil)
let raw = readAll(STDIN_FILENO)
let decision = send(envelope(vendor: vendor, raw: raw), to: socketPath())
let answer = reply(for: vendor, decision: decision)
if let out = answer.stdout {
    fputs(out, stdout)
    fflush(stdout)
}
if let err = answer.stderr {
    fputs(err, stderr)
    fflush(stderr)
}
exit(answer.status)
