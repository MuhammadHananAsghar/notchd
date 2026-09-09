// EventSocketServerTests.swift
// The server has to accept a connection from a plain POSIX client, deliver
// each newline-terminated line once, deliver a final unterminated line at EOF,
// and clean up its socket file when stopped.

import Darwin
import XCTest
@testable import Notchd

final class EventSocketServerTests: XCTestCase {
    private var path = ""

    override func setUp() {
        path = NSTemporaryDirectory() + "notchd-test-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        unlink(path)
    }

    /// Connects, writes, and closes, the way the hook binary does.
    private func send(_ text: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = EventSocketServer.address(for: path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) } == bytes.count
    }

    /// Two lines in one connection arrive as two deliveries.
    func testDeliversEachLine() throws {
        let received = expectation(description: "two lines")
        received.expectedFulfillmentCount = 2
        var lines: [String] = []
        let lock = NSLock()
        let server = EventSocketServer(path: path) { data in
            lock.lock()
            lines.append(String(decoding: data, as: UTF8.self))
            lock.unlock()
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(send("{\"a\":1}\n{\"b\":2}\n"))
        wait(for: [received], timeout: 5)
        lock.lock()
        XCTAssertEqual(lines.sorted(), ["{\"a\":1}", "{\"b\":2}"])
        lock.unlock()
    }

    /// A line with no trailing newline is delivered when the client closes.
    func testDeliversUnterminatedLineAtEOF() throws {
        let received = expectation(description: "one line")
        var line = ""
        let server = EventSocketServer(path: path) { data in
            line = String(decoding: data, as: UTF8.self)
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(send("{\"c\":3}"))
        wait(for: [received], timeout: 5)
        XCTAssertEqual(line, "{\"c\":3}")
    }

    /// A payload with newlines inside it, as a pretty-printed emitter or a
    /// trailing newline from `echo` produces, is delivered as one message.
    func testNewlinesInsideAMessageDoNotSplitIt() throws {
        let received = expectation(description: "two messages")
        received.expectedFulfillmentCount = 2
        var messages: [String] = []
        let lock = NSLock()
        let server = EventSocketServer(path: path) { data in
            lock.lock()
            messages.append(String(decoding: data, as: UTF8.self))
            lock.unlock()
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(send("{\"v\":1,\"raw\":{\"a\":1}\n}\n{\n  \"v\": 1,\n  \"raw\": 2\n}"))
        wait(for: [received], timeout: 5)
        lock.lock()
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil }, "\(messages)")
        lock.unlock()
    }

    /// After the client half-closes, the server answers with its
    /// acknowledgement only once every message has been handled.
    func testAcknowledgesAfterHandling() throws {
        var handled = false
        let server = EventSocketServer(path: path) { _ in
            Thread.sleep(forTimeInterval: 0.1)
            handled = true
        }
        try server.start()
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = EventSocketServer.address(for: path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        let bytes = Array("{\"v\":1}\n".utf8)
        XCTAssertEqual(bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }, bytes.count)
        shutdown(fd, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = read(fd, &buffer, buffer.count)
        XCTAssertEqual(Data(buffer[0..<max(0, Int(count))]), EventSocketServer.acknowledgement)
        XCTAssertTrue(handled, "the acknowledgement arrived before the handler finished")
    }

    /// Separate connections are each served.
    func testServesSeveralConnections() throws {
        let received = expectation(description: "three connections")
        received.expectedFulfillmentCount = 3
        let server = EventSocketServer(path: path) { _ in received.fulfill() }
        try server.start()
        defer { server.stop() }
        for index in 0..<3 { XCTAssertTrue(send("{\"n\":\(index)}\n")) }
        wait(for: [received], timeout: 5)
    }

    /// The socket file exists while listening and is gone after stop, and a
    /// stale file from a previous run does not prevent starting.
    func testSocketFileLifecycle() throws {
        FileManager.default.createFile(atPath: path, contents: Data())
        let server = EventSocketServer(path: path) { _ in }
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// A path longer than sockaddr_un allows is refused up front.
    func testRefusesOverlongPath() {
        let long = "/tmp/" + String(repeating: "x", count: 200)
        let server = EventSocketServer(path: long) { _ in }
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? SocketServerError, .pathTooLong(long))
        }
    }
}
