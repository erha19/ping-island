import Foundation
import IslandShared

actor SocketServer {
    private static let healthCheckRequest = #"{"type":"ping-island-health-check"}"#
    private static let healthCheckResponse = #"{"ok":true}"#

    private let socketPath: String
    private let sessionStore: SessionStore
    private let approvalCoordinator: ApprovalCoordinator
    private var listenerFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    init(socketPath: String, sessionStore: SessionStore, approvalCoordinator: ApprovalCoordinator) {
        self.socketPath = socketPath
        self.sessionStore = sessionStore
        self.approvalCoordinator = approvalCoordinator
    }

    func start() async throws {
        await stop()

        unlink(socketPath)

        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw POSIXError(.EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8 = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard utf8.count <= maxLength else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: utf8)
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(self.listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(.EADDRINUSE)
        }

        guard listen(listenerFD, 16) == 0 else {
            throw POSIXError(.EIO)
        }

        chmod(socketPath, 0o600)

        let acceptedListenerFD = self.listenerFD
        acceptTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let clientFD = accept(acceptedListenerFD, nil, nil)
                if clientFD < 0 {
                    if Task.isCancelled {
                        break
                    }
                    continue
                }
                if Task.isCancelled {
                    close(clientFD)
                    break
                }
                Task.detached {
                    await self.handle(clientFD: clientFD)
                }
            }
        }
    }

    func stop() async {
        let task = acceptTask
        acceptTask = nil
        task?.cancel()

        let fd = listenerFD
        listenerFD = -1
        if fd >= 0 {
            Self.wakeListener(socketPath: socketPath)
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        if let task {
            await task.value
        }
        unlink(socketPath)
    }

    private func handle(clientFD: Int32) async {
        defer { close(clientFD) }

        do {
            let data = try Self.readAll(from: clientFD)
            if String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == Self.healthCheckRequest {
                try Self.writeHealthCheckResponse(to: clientFD)
                return
            }

            let envelope = try BridgeCodec.decodeEnvelope(data)
            await sessionStore.ingest(envelope)

            var response = BridgeResponse(requestID: envelope.id)
            if envelope.expectsResponse, let intervention = envelope.intervention {
                let decision = await approvalCoordinator.waitForDecision(requestID: intervention.id)
                response = BridgeResponse(requestID: envelope.id, decision: decision)
            }
            let encoded = try BridgeCodec.encodeResponse(response)
            _ = encoded.withUnsafeBytes { buffer in
                write(clientFD, buffer.baseAddress, buffer.count)
            }
        } catch {
            let fallback = BridgeResponse(requestID: UUID(), errorMessage: error.localizedDescription)
            if let data = try? BridgeCodec.encodeResponse(fallback) {
                _ = data.withUnsafeBytes { buffer in
                    write(clientFD, buffer.baseAddress, buffer.count)
                }
            }
        }
    }

    private static func readAll(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = read(fd, &buffer, buffer.count)
            if readCount < 0 {
                throw POSIXError(.EIO)
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }
        return data
    }

    private static func writeHealthCheckResponse(to fd: Int32) throws {
        let data = Data(healthCheckResponse.utf8)
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            return write(fd, baseAddress, data.count) == data.count
        }
        guard wrote else {
            throw POSIXError(.EIO)
        }
    }

    private static func wakeListener(socketPath: String) {
        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8 = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard utf8.count <= maxLength else { return }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: utf8)
        }

        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
