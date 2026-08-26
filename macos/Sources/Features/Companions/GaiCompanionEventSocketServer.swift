#if os(macOS)
import Darwin
import Foundation

/// Ordered, process-local transport for authenticated agent lifecycle events.
///
/// Clients send exactly one UTF-8 URL followed by `\n`. Once the complete frame
/// has passed a lightweight capability admission, the server replies with
/// `OK\n` and releases the hook process. The heavier handler then runs on the
/// main actor. This prevents an unauthenticated frame from being acknowledged
/// while still keeping slow event application out of the hook's critical path.
final class GaiCompanionEventSocketServer: @unchecked Sendable {
    struct Frame: Equatable, Sendable {
        let url: URL
        let responseBody: Data?
    }

    typealias Admission = @MainActor @Sendable (Frame) -> Bool
    typealias Handler = @MainActor @Sendable (Frame) -> Bool

    static let acknowledgement = Data("OK\n".utf8)
    /// An incomplete local client must not hold the ordered queue long enough
    /// to delay later provider hooks. Complete frames are only a few KiB (up to
    /// one bounded final response) and traverse a process-local Unix socket.
    static let defaultClientDeadline: TimeInterval = 0.25
    /// A Codex Stop event may carry one bounded final assistant message. The
    /// base64url envelope needs roughly 4/3 of the original UTF-8 size.
    static let maximumFrameByteCount = 96 * 1_024

    private let admission: Admission
    private let handler: Handler
    private let clientDeadline: TimeInterval
    private let queue = DispatchQueue(
        label: "com.sipiyou.teddycli.agent-event-socket",
        qos: .userInitiated)

    private var listenerFileDescriptor: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var boundSocket: BoundSocket?
    private var clients: [Int32: Client] = [:]
    private var acceptOrder: [Int32] = []
    private var queuedDeliveries: [QueuedDelivery] = []
    private var activeDeliveryID: UInt64?
    private var nextDeliveryID: UInt64 = 1

    init(
        clientDeadline: TimeInterval = GaiCompanionEventSocketServer.defaultClientDeadline,
        admission: @escaping Admission,
        handler: @escaping Handler
    ) {
        self.clientDeadline = max(0.1, clientDeadline)
        self.admission = admission
        self.handler = handler
    }

    /// The currently bound socket path, or `nil` while the server is stopped.
    var socketPath: String? {
        queue.sync { boundSocket?.path }
    }

    /// Starts the server and returns its private, unique socket path.
    /// Calling this again while running is idempotent.
    @discardableResult
    func start() throws -> String {
        try queue.sync {
            if let path = boundSocket?.path {
                return path
            }
            return try startOnQueue()
        }
    }

    /// Stops accepting events, closes all clients, and removes only the socket
    /// node created by this server. Calling this repeatedly is safe.
    func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    deinit {
        stop()
    }

    private func startOnQueue() throws -> String {
        dispatchPrecondition(condition: .onQueue(queue))

        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw GaiCompanionEventSocketServerError.posix(
                operation: "socket",
                code: errno)
        }

        do {
            try Self.makeNonBlocking(fileDescriptor)

            var lastBindError = EADDRINUSE
            for _ in 0..<8 {
                let path = Self.makeUniqueSocketPath()
                let address = try Self.socketAddress(for: path)

                let bindResult = address.withUnsafePointer { pointer, length in
                    Darwin.bind(fileDescriptor, pointer, length)
                }
                guard bindResult == 0 else {
                    lastBindError = errno
                    if lastBindError == EADDRINUSE {
                        continue
                    }
                    throw GaiCompanionEventSocketServerError.posix(
                        operation: "bind",
                        code: lastBindError)
                }

                guard Darwin.chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                    let code = errno
                    _ = Darwin.unlink(path)
                    throw GaiCompanionEventSocketServerError.posix(
                        operation: "chmod",
                        code: code)
                }

                guard Darwin.listen(fileDescriptor, 16) == 0 else {
                    let code = errno
                    _ = Darwin.unlink(path)
                    throw GaiCompanionEventSocketServerError.posix(
                        operation: "listen",
                        code: code)
                }

                guard let identity = Self.socketIdentity(at: path) else {
                    _ = Darwin.unlink(path)
                    throw GaiCompanionEventSocketServerError.invalidBoundSocket
                }

                listenerFileDescriptor = fileDescriptor
                boundSocket = BoundSocket(
                    path: path,
                    device: identity.device,
                    inode: identity.inode)
                installListenerSource(fileDescriptor: fileDescriptor)
                return path
            }

            throw GaiCompanionEventSocketServerError.posix(
                operation: "bind",
                code: lastBindError)
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    private func installListenerSource(fileDescriptor: Int32) {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableClients()
        }
        listenerSource = source
        source.resume()
    }

    private func acceptAvailableClients() {
        dispatchPrecondition(condition: .onQueue(queue))

        while listenerFileDescriptor >= 0 {
            let clientFileDescriptor = Darwin.accept(listenerFileDescriptor, nil, nil)
            if clientFileDescriptor < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }

            do {
                try Self.makeNonBlocking(clientFileDescriptor)
                try Self.disableBrokenPipeSignal(clientFileDescriptor)
            } catch {
                Darwin.close(clientFileDescriptor)
                continue
            }

            let client = Client(fileDescriptor: clientFileDescriptor)
            clients[clientFileDescriptor] = client
            acceptOrder.append(clientFileDescriptor)
            installReadSource(for: client)
            installDeadline(for: client, phase: .receiving)
        }
    }

    private func installReadSource(for client: Client) {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: client.fileDescriptor,
            queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailableBytes(from: client.fileDescriptor)
        }
        client.readSource = source
        source.resume()
    }

    private func readAvailableBytes(from fileDescriptor: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let client = clients[fileDescriptor], client.phase == .receiving else {
            return
        }

        var reachedEndOfStream = false
        var scratch = [UInt8](repeating: 0, count: 2_048)

        readLoop: while true {
            let count = scratch.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }

            switch count {
            case let count where count > 0:
                client.buffer.append(contentsOf: scratch.prefix(count))
                if client.buffer.count > Self.maximumFrameByteCount + 1 {
                    rejectAndAdvance(fileDescriptor)
                    return
                }

            case 0:
                reachedEndOfStream = true
                break readLoop

            default:
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break readLoop
                }
                rejectAndAdvance(fileDescriptor)
                return
            }
        }

        if let newlineOffset = client.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let header = client.buffer[..<newlineOffset]
            guard header.count <= Self.maximumFrameByteCount,
                  let rawURL = String(data: header, encoding: .utf8),
                  let url = Self.strictURL(from: rawURL),
                  let expectedResponseByteCount = Self.responseByteCount(from: url) else {
                rejectAndAdvance(fileDescriptor)
                return
            }

            let bodyStart = client.buffer.index(after: newlineOffset)
            let body = client.buffer[bodyStart...]
            if let expectedResponseByteCount {
                guard body.count <= expectedResponseByteCount else {
                    rejectAndAdvance(fileDescriptor)
                    return
                }
                if body.count < expectedResponseByteCount {
                    if reachedEndOfStream {
                        rejectAndAdvance(fileDescriptor)
                    }
                    return
                }
            } else {
                guard body.isEmpty else {
                    rejectAndAdvance(fileDescriptor)
                    return
                }
            }

            client.cancelReadAndDeadline()
            client.phase = .ready(Frame(
                url: url,
                responseBody: expectedResponseByteCount == nil ? nil : Data(body)))
            drainAcceptedClients()
            return
        }

        if reachedEndOfStream || client.buffer.count > Self.maximumFrameByteCount {
            rejectAndAdvance(fileDescriptor)
        }
    }

    private func drainAcceptedClients() {
        dispatchPrecondition(condition: .onQueue(queue))

        while let firstFileDescriptor = acceptOrder.first,
              clients[firstFileDescriptor] == nil {
            acceptOrder.removeFirst()
        }

        guard let fileDescriptor = acceptOrder.first,
              let client = clients[fileDescriptor],
              case let .ready(frame) = client.phase else {
            return
        }

        client.phase = .admitting(frame)
        let admission = admission
        let clientID = client.id

        Task { @MainActor [weak self] in
            let admitted = admission(frame)
            self?.queue.async { [weak self] in
                self?.admissionCompleted(
                    for: fileDescriptor,
                    clientID: clientID,
                    admitted: admitted)
            }
        }
    }

    private func admissionCompleted(
        for fileDescriptor: Int32,
        clientID: UUID,
        admitted: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let client = clients[fileDescriptor],
              client.id == clientID,
              case let .admitting(frame) = client.phase else {
            return
        }

        guard admitted else {
            rejectAndAdvance(fileDescriptor)
            return
        }

        client.phase = .responding(frame: frame, offset: 0)
        installDeadline(for: client, phase: .responding)
        writeAcknowledgement(to: fileDescriptor)
    }

    private func writeAcknowledgement(to fileDescriptor: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let client = clients[fileDescriptor],
              case let .responding(frame, offset) = client.phase else {
            return
        }

        let remainingCount = Self.acknowledgement.count - offset
        let sent = Self.acknowledgement.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(
                fileDescriptor,
                baseAddress.advanced(by: offset),
                remainingCount)
        }

        if sent > 0 {
            let nextOffset = offset + sent
            if nextOffset == Self.acknowledgement.count {
                enqueue(frame)
                closeClient(fileDescriptor)
                dispatchNextDeliveryIfNeeded()
                drainAcceptedClients()
            } else {
                client.phase = .responding(frame: frame, offset: nextOffset)
                installWriteSourceIfNeeded(for: client)
            }
            return
        }

        if sent < 0 && errno == EINTR {
            writeAcknowledgement(to: fileDescriptor)
            return
        }
        if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            installWriteSourceIfNeeded(for: client)
            return
        }

        closeClient(fileDescriptor)
        drainAcceptedClients()
    }

    private func enqueue(_ frame: Frame) {
        dispatchPrecondition(condition: .onQueue(queue))
        let deliveryID = nextDeliveryID
        nextDeliveryID &+= 1
        if nextDeliveryID == 0 {
            nextDeliveryID = 1
        }
        queuedDeliveries.append(QueuedDelivery(id: deliveryID, frame: frame))
    }

    private func dispatchNextDeliveryIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard activeDeliveryID == nil, !queuedDeliveries.isEmpty else { return }

        let delivery = queuedDeliveries.removeFirst()
        activeDeliveryID = delivery.id
        let handler = handler

        Task { @MainActor [weak self] in
            let accepted = handler(delivery.frame)
            self?.queue.async { [weak self] in
                self?.handlerCompleted(
                    deliveryID: delivery.id,
                    accepted: accepted)
            }
        }
    }

    private func handlerCompleted(deliveryID: UInt64, accepted _: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard activeDeliveryID == deliveryID else { return }
        activeDeliveryID = nil
        dispatchNextDeliveryIfNeeded()
    }

    private func installWriteSourceIfNeeded(for client: Client) {
        guard client.writeSource == nil else { return }

        let source = DispatchSource.makeWriteSource(
            fileDescriptor: client.fileDescriptor,
            queue: queue)
        source.setEventHandler { [weak self] in
            self?.writeAcknowledgement(to: client.fileDescriptor)
        }
        client.writeSource = source
        source.resume()
    }

    private func installDeadline(for client: Client, phase: Client.DeadlinePhase) {
        client.deadlineSource?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + clientDeadline,
            leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            guard let self,
                  let current = self.clients[client.fileDescriptor],
                  current.deadlinePhase == phase else {
                return
            }
            self.rejectAndAdvance(client.fileDescriptor)
        }
        client.deadlinePhase = phase
        client.deadlineSource = timer
        timer.resume()
    }

    private func rejectAndAdvance(_ fileDescriptor: Int32) {
        closeClient(fileDescriptor)
        drainAcceptedClients()
    }

    private func closeClient(_ fileDescriptor: Int32) {
        guard let client = clients.removeValue(forKey: fileDescriptor) else {
            return
        }

        client.cancelAllSources()
        Darwin.close(fileDescriptor)
        acceptOrder.removeAll { $0 == fileDescriptor }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))

        listenerSource?.cancel()
        listenerSource = nil
        if listenerFileDescriptor >= 0 {
            Darwin.close(listenerFileDescriptor)
            listenerFileDescriptor = -1
        }

        for fileDescriptor in Array(clients.keys) {
            closeClient(fileDescriptor)
        }
        acceptOrder.removeAll(keepingCapacity: false)
        queuedDeliveries.removeAll(keepingCapacity: false)
        activeDeliveryID = nil

        if let socket = boundSocket,
           let current = Self.socketIdentity(at: socket.path),
           current.device == socket.device,
           current.inode == socket.inode {
            _ = Darwin.unlink(socket.path)
        }
        boundSocket = nil
    }

    private static func strictURL(from value: String) -> URL? {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
              let components = URLComponents(string: value),
              components.scheme != nil,
              let url = components.url,
              url.absoluteString == value else {
            return nil
        }
        return url
    }

    /// `nil` means a legacy one-line URL frame. A non-nil outer optional with
    /// a nil value means the header is malformed and must be rejected.
    private static func responseByteCount(from url: URL) -> Int?? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let values = (components.queryItems ?? [])
            .filter { $0.name == "response_bytes" }
        guard values.count <= 1 else { return nil }
        guard let raw = values.first?.value else { return .some(nil) }
        guard let count = Int(raw),
              count > 0,
              count <= GaiCompanionEventEnvelope.maximumResponseByteCount,
              String(count) == raw else { return nil }
        return .some(count)
    }

    private static func makeUniqueSocketPath() -> String {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        return "/tmp/gaiterm-agent-events-\(getuid())-\(getpid())-\(nonce).sock"
    }

    private static func socketAddress(for path: String) throws -> SocketAddress {
        var value = sockaddr_un()
        let pathBytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: value.sun_path)
        guard pathBytes.count < pathCapacity else {
            throw GaiCompanionEventSocketServerError.socketPathTooLong
        }

        value.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &value.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: pathBytes)
        }

        let prefixLength = MemoryLayout<sockaddr_un>.size - pathCapacity
        let length = prefixLength + pathBytes.count + 1
        value.sun_len = UInt8(length)
        return SocketAddress(value: value, length: socklen_t(length))
    }

    private static func makeNonBlocking(_ fileDescriptor: Int32) throws {
        let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw GaiCompanionEventSocketServerError.posix(
                operation: "fcntl",
                code: errno)
        }
    }

    private static func disableBrokenPipeSignal(_ fileDescriptor: Int32) throws {
        var enabled: Int32 = 1
        let result = withUnsafePointer(to: &enabled) { pointer in
            Darwin.setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size))
        }
        guard result == 0 else {
            throw GaiCompanionEventSocketServerError.posix(
                operation: "setsockopt",
                code: errno)
        }
    }

    private static func socketIdentity(at path: String) -> FileIdentity? {
        var status = stat()
        guard Darwin.lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFSOCK else {
            return nil
        }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }
}

enum GaiCompanionEventSocketServerError: Error, Equatable {
    case socketPathTooLong
    case invalidBoundSocket
    case posix(operation: String, code: Int32)
}

private extension GaiCompanionEventSocketServer {
    struct SocketAddress {
        var value: sockaddr_un
        let length: socklen_t
    }

    struct BoundSocket {
        let path: String
        let device: dev_t
        let inode: ino_t
    }

    struct FileIdentity {
        let device: dev_t
        let inode: ino_t
    }

    struct QueuedDelivery {
        let id: UInt64
        let frame: Frame
    }

    final class Client {
        enum Phase: Equatable {
            case receiving
            case ready(Frame)
            case admitting(Frame)
            case responding(frame: Frame, offset: Int)
        }

        enum DeadlinePhase: Equatable {
            case receiving
            case responding
        }

        let id = UUID()
        let fileDescriptor: Int32
        var phase: Phase = .receiving
        var deadlinePhase: DeadlinePhase?
        var buffer = Data()
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var deadlineSource: DispatchSourceTimer?

        init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }

        func cancelReadAndDeadline() {
            readSource?.cancel()
            readSource = nil
            deadlineSource?.cancel()
            deadlineSource = nil
            deadlinePhase = nil
        }

        func cancelAllSources() {
            readSource?.cancel()
            readSource = nil
            writeSource?.cancel()
            writeSource = nil
            deadlineSource?.cancel()
            deadlineSource = nil
            deadlinePhase = nil
        }
    }
}

private extension GaiCompanionEventSocketServer.SocketAddress {
    func withUnsafePointer<Result>(
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) rethrows -> Result {
        var address = value
        return try Swift.withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, length)
            }
        }
    }
}
#endif
