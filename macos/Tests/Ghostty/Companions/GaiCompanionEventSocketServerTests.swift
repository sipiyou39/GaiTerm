#if DEBUG
import Darwin
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct GaiCompanionEventSocketServerTests {
    @Test func deliversOneFrameOnMainActorBeforeAcknowledging() async throws {
        let recorder = EventRecorder()
        let server = GaiCompanionEventSocketServer { url in
            recorder.wasOnMainThread = Thread.isMainThread
            recorder.urls.append(url)
            return true
        }
        let path = try server.start()
        defer { server.stop() }

        let url = try #require(URL(string: socketTestFirstURL))
        let response = try await runSocketClient {
            try socketExchange(path: path, payload: Data("\(url.absoluteString)\n".utf8))
        }

        #expect(response == GaiCompanionEventSocketServer.acknowledgement)
        #expect(recorder.wasOnMainThread)
        #expect(recorder.urls == [url])
    }

    @Test func serializesHandlerAndAcknowledgementInAcceptOrder() async throws {
        let recorder = EventRecorder()
        let server = GaiCompanionEventSocketServer { url in
            recorder.urls.append(url)
            return true
        }
        let path = try server.start()
        defer { server.stop() }

        let responses = try await runSocketClient {
            try orderedSocketExchange(
                path: path,
                firstPayload: Data("\(socketTestFirstURL)\n".utf8),
                secondPayload: Data("\(socketTestSecondURL)\n".utf8))
        }

        #expect(responses.first == GaiCompanionEventSocketServer.acknowledgement)
        #expect(responses.second == GaiCompanionEventSocketServer.acknowledgement)
        #expect(recorder.urls.map(\.absoluteString) == [socketTestFirstURL, socketTestSecondURL])
    }

    @Test func rejectsOversizedAndMultipleFramesWithoutCallingHandler() async throws {
        let recorder = EventRecorder()
        let server = GaiCompanionEventSocketServer { url in
            recorder.urls.append(url)
            return true
        }
        let path = try server.start()
        defer { server.stop() }

        let oversizedResponse = try await runSocketClient {
            let payload = Data(
                (String(repeating: "a", count: 8_193) + "\n").utf8)
            return try socketExchange(path: path, payload: payload)
        }
        let multipleResponse = try await runSocketClient {
            let payload = Data("\(socketTestFirstURL)\n\(socketTestSecondURL)\n".utf8)
            return try socketExchange(path: path, payload: payload)
        }

        #expect(oversizedResponse.isEmpty)
        #expect(multipleResponse.isEmpty)
        #expect(recorder.urls.isEmpty)
    }

    @Test func rejectsUnauthenticatedHandlerResultWithoutAcknowledging() async throws {
        let recorder = EventRecorder()
        let server = GaiCompanionEventSocketServer { url in
            recorder.urls.append(url)
            return false
        }
        let path = try server.start()
        defer { server.stop() }

        let response = try await runSocketClient {
            try socketExchange(
                path: path,
                payload: Data("\(socketTestFirstURL)\n".utf8))
        }

        #expect(response.isEmpty)
        #expect(recorder.urls.map(\.absoluteString) == [socketTestFirstURL])
    }

    @Test func socketIsPrivateUniqueAndRemovedSafely() throws {
        let server = GaiCompanionEventSocketServer { _ in true }
        let path = try server.start()

        #expect(path.hasPrefix("/tmp/gaiterm-agent-events-"))
        #expect(path.utf8.count < unixSocketPathCapacity())
        #expect(server.socketPath == path)
        #expect(try server.start() == path)

        var status = stat()
        #expect(Darwin.lstat(path, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFSOCK)
        #expect(status.st_mode & 0o777 == 0o600)

        server.stop()
        server.stop()
        #expect(server.socketPath == nil)
        #expect(Darwin.lstat(path, &status) == -1)
        #expect(errno == ENOENT)
    }

    @Test func incompleteClientIsClosedAtDeadline() async throws {
        let recorder = EventRecorder()
        let server = GaiCompanionEventSocketServer(clientDeadline: 0.1) { url in
            recorder.urls.append(url)
            return true
        }
        let path = try server.start()
        defer { server.stop() }

        let response = try await runSocketClient {
            try socketExchange(
                path: path,
                payload: Data(socketTestFirstURL.utf8),
                receiveTimeout: 1)
        }

        #expect(response.isEmpty)
        #expect(recorder.urls.isEmpty)
    }

}

private let socketTestFirstURL =
    "gaiterm-debug://agent-event?v=1&surface=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" +
    "&token=0123456789abcdef0123456789abcdef&provider=codex&kind=started&event=one"
private let socketTestSecondURL =
    "gaiterm-debug://agent-event?v=1&surface=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" +
    "&token=0123456789abcdef0123456789abcdef&provider=codex&kind=stop&event=two"

@MainActor
private final class EventRecorder {
    var urls: [URL] = []
    var wasOnMainThread = false
}

private enum SocketClientTestError: Error {
    case posix(operation: String, code: Int32)
    case pathTooLong
}

private func runSocketClient<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try operation())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func socketExchange(
    path: String,
    payload: Data,
    receiveTimeout: TimeInterval = 1
) throws -> Data {
    let fileDescriptor = try connectedSocket(path: path, receiveTimeout: receiveTimeout)
    defer { Darwin.close(fileDescriptor) }

    try writeAll(payload, to: fileDescriptor)
    return try readResponse(from: fileDescriptor)
}

private func orderedSocketExchange(
    path: String,
    firstPayload: Data,
    secondPayload: Data
) throws -> (first: Data, second: Data) {
    let first = try connectedSocket(path: path, receiveTimeout: 1)
    defer { Darwin.close(first) }
    let second = try connectedSocket(path: path, receiveTimeout: 1)
    defer { Darwin.close(second) }

    // Make the later connection readable first. The server must still wait for
    // the earlier accepted connection before applying either event.
    try writeAll(secondPayload, to: second)
    usleep(20_000)
    try writeAll(firstPayload, to: first)

    return (
        first: try readResponse(from: first),
        second: try readResponse(from: second))
}

private func connectedSocket(
    path: String,
    receiveTimeout: TimeInterval
) throws -> Int32 {
    let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
        throw SocketClientTestError.posix(operation: "socket", code: errno)
    }

    do {
        var noSignal: Int32 = 1
        guard Darwin.setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketClientTestError.posix(operation: "setsockopt", code: errno)
        }

        let seconds = floor(receiveTimeout)
        var timeout = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((receiveTimeout - seconds) * 1_000_000))
        guard Darwin.setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw SocketClientTestError.posix(operation: "setsockopt", code: errno)
        }

        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw SocketClientTestError.pathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.initializeMemory(as: UInt8.self, repeating: 0)
            storage.copyBytes(from: bytes)
        }
        let length = MemoryLayout<sockaddr_un>.size - capacity + bytes.count + 1
        address.sun_len = UInt8(length)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, socklen_t(length))
            }
        }
        guard result == 0 else {
            throw SocketClientTestError.posix(operation: "connect", code: errno)
        }

        return fileDescriptor
    } catch {
        Darwin.close(fileDescriptor)
        throw error
    }
}

private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
        let count = data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(
                fileDescriptor,
                baseAddress.advanced(by: offset),
                data.count - offset)
        }
        if count > 0 {
            offset += count
            continue
        }
        if count < 0 && errno == EINTR {
            continue
        }
        throw SocketClientTestError.posix(operation: "write", code: errno)
    }
}

private func readResponse(from fileDescriptor: Int32) throws -> Data {
    var response = Data()
    var scratch = [UInt8](repeating: 0, count: 32)

    while true {
        let count = scratch.withUnsafeMutableBytes { bytes in
            Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            response.append(contentsOf: scratch.prefix(count))
            if response.contains(UInt8(ascii: "\n")) {
                return response
            }
            continue
        }
        if count == 0 {
            return response
        }
        if errno == EINTR {
            continue
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return response
        }
        throw SocketClientTestError.posix(operation: "read", code: errno)
    }
}

private func unixSocketPathCapacity() -> Int {
    let address = sockaddr_un()
    return MemoryLayout.size(ofValue: address.sun_path)
}
#endif
