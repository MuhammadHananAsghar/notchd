// EventSocketServer.swift
// Listens on a unix domain socket for lines written by `notchd-hook`. Each
// connection carries one or more newline-terminated envelopes and then closes.
// POSIX sockets and GCD rather than Network.framework: the protocol is a few
// hundred bytes per connection and the code is easier to reason about when a
// hook is on the other end waiting to exit.

import Darwin
import Foundation

/// A failure starting the listener.
enum SocketServerError: Error, Equatable {
    case pathTooLong(String)
    case systemCall(String, Int32)
}

/// Accepts envelopes on a unix socket and hands each line to a handler.
final class EventSocketServer {
    typealias LineHandler = (Data) -> Void
    typealias LineDecider = (Data) -> HookDecision

    private let path: String
    private let decider: LineDecider
    private let acceptQueue = DispatchQueue(label: "com.muhammad.notchd.socket.accept")
    private let readQueue = DispatchQueue(label: "com.muhammad.notchd.socket.read", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    /// Longest path a `sockaddr_un` can hold, including the terminator.
    static let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// Creates a server that will listen at a path once started.
    /// - Parameters:
    ///   - path: The socket path. Any stale file there is removed on start.
    ///   - handler: Called on a background queue with each complete line.
    init(path: String, handler: @escaping LineHandler) {
        self.path = path
        decider = { line in
            handler(line)
            return .allow
        }
    }

    /// Creates a server whose handler also decides what the hook is told.
    private init(path: String, deciding decider: @escaping LineDecider) {
        self.path = path
        self.decider = decider
    }

    /// A server whose handler also decides what the hook is told: allow,
    /// ask, or deny. The decision for a connection is the one for its last
    /// message. A factory rather than a second initialiser so a trailing
    /// closure is never ambiguous with the recording-only form.
    /// - Parameters:
    ///   - path: The socket path.
    ///   - decider: Called on a background queue with each complete message.
    /// - Returns: The server, not yet started.
    static func deciding(path: String, _ decider: @escaping LineDecider) -> EventSocketServer {
        EventSocketServer(path: path, deciding: decider)
    }

    deinit {
        stop()
    }

    /// Binds, listens, and begins accepting. Also stops SIGPIPE from killing
    /// the process: a hook may close its end before the acknowledgement is
    /// written, and a write to a closed peer must be an error, not a death.
    func start() throws {
        guard path.utf8.count <= Self.maximumPathLength else { throw SocketServerError.pathTooLong(path) }
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketServerError.systemCall("socket", errno) }
        unlink(path)
        var address = Self.address(for: path)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketServerError.systemCall("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw SocketServerError.systemCall("listen", code)
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        self.source = source
    }

    /// Stops accepting and removes the socket file.
    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
            unlink(path)
        }
    }

    /// Accepts every connection currently waiting and reads each on its own.
    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            readQueue.async { [weak self] in self?.drain(client) }
        }
    }

    /// Reads a connection to EOF and delivers each complete message.
    /// - Parameter fd: The connected descriptor; closed before returning.
    private func drain(_ fd: Int32) {
        defer { close(fd) }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = Data()
        var decision = HookDecision.allow
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            pending.append(buffer, count: Int(count))
            pending = deliverCompleteMessages(in: pending, decision: &decision)
        }
        let rest = Self.trimmed(pending)
        if !rest.isEmpty { decision = decider(rest) }
        acknowledge(fd, decision)
    }

    /// The bytes written back when every message on a connection has been
    /// handled and allowed. The hook waits for this before letting the tool
    /// run; a deny or ask line takes its place when a guard rule fires.
    static let acknowledgement = Data(HookDecision.allow.line.utf8)

    /// Tells the client its messages are recorded and checkpointed, and what
    /// the guard decided.
    private func acknowledge(_ fd: Int32, _ decision: HookDecision) {
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        Data(decision.line.utf8).withUnsafeBytes { bytes in
            _ = write(fd, bytes.baseAddress, bytes.count)
        }
    }

    /// Delivers every complete message and returns the remainder.
    ///
    /// The protocol is one JSON object per line, but a payload forwarded
    /// verbatim by the hook may carry newlines of its own, so a newline alone
    /// is not trusted as a boundary. Text up to a newline is delivered only once
    /// it parses as JSON; otherwise it is kept and joined with what follows.
    private func deliverCompleteMessages(in data: Data, decision: inout HookDecision) -> Data {
        var rest = data
        var candidateEnd = rest.startIndex
        while let newline = rest[candidateEnd...].firstIndex(of: UInt8(ascii: "\n")) {
            let candidate = Self.trimmed(rest[rest.startIndex..<newline])
            if candidate.isEmpty {
                rest = Data(rest[(newline + 1)...])
                candidateEnd = rest.startIndex
            } else if Self.isCompleteJSON(candidate) {
                decision = decider(candidate)
                rest = Data(rest[(newline + 1)...])
                candidateEnd = rest.startIndex
            } else {
                candidateEnd = newline + 1
            }
        }
        return rest
    }

    /// Whether bytes form one whole JSON document.
    private static func isCompleteJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    /// Bytes without leading and trailing ASCII whitespace.
    private static func trimmed(_ data: Data) -> Data {
        let whitespace: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]
        guard let first = data.firstIndex(where: { !whitespace.contains($0) }),
              let last = data.lastIndex(where: { !whitespace.contains($0) }) else { return Data() }
        return Data(data[first...last])
    }

    /// A `sockaddr_un` for a path.
    /// - Parameter path: The socket path, already checked for length.
    /// - Returns: The address structure.
    static func address(for path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                for (index, byte) in path.utf8.enumerated() { chars[index] = CChar(bitPattern: byte) }
                chars[path.utf8.count] = 0
            }
        }
        return address
    }
}
