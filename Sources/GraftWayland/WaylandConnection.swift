import Foundation
import GraftWaylandC

public enum WaylandError: Error, CustomStringConvertible {
    case io(String)
    case closed
    case protocolError(String)

    public var description: String {
        switch self {
        case .io(let message): return "Wayland I/O error: \(message)"
        case .closed: return "Wayland connection closed"
        case .protocolError(let message): return "Wayland protocol error: \(message)"
        }
    }
}

/// A small Unix-domain socket connection that understands Wayland's message
/// framing and SCM_RIGHTS file descriptor passing.
public final class WaylandConnection: @unchecked Sendable {
    public let fd: Int32
    private var readBuffer = Data()
    private var pendingFileDescriptors: [Int32] = []

    public init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close()
    }

    public static func connect(path: String) throws -> WaylandConnection {
        let fd = path.withCString { graft_unix_connect($0) }
        guard fd >= 0 else {
            throw WaylandError.io("connect(\(path)): \(String(cString: strerror(errno)))")
        }
        return WaylandConnection(fd: fd)
    }

    public func send(_ message: WaylandMessage, fileDescriptor: Int32 = -1) throws {
        let size = 8 + message.payload.count
        var header = Data()
        appendUInt32(UInt32(message.objectID), to: &header)
        appendUInt32((UInt32(size) << 16) | UInt32(message.opcode), to: &header)

        let result: Int32 = header.withUnsafeBytes { headerBytes in
            message.payload.withUnsafeBytes { payloadBytes in
                graft_send_message(
                    fd,
                    headerBytes.baseAddress,
                    headerBytes.count,
                    payloadBytes.baseAddress,
                    payloadBytes.count,
                    fileDescriptor
                )
            }
        }
        guard result == 0 else {
            throw WaylandError.io("send: \(String(cString: strerror(errno)))")
        }
    }

    /// Reads at least the next available batch. The server keeps received
    /// descriptors queued so the dispatcher can claim one only when a request
    /// (for example wl_shm.create_pool) expects it.
    public func readMessages() throws -> [WaylandMessage] {
        if let parsed = parseAvailableMessages(), !parsed.isEmpty {
            return parsed
        }

        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var receivedFD: Int32 = -1
        let count = chunk.withUnsafeMutableBytes { bytes in
            graft_recv_message(fd, bytes.baseAddress, bytes.count, &receivedFD)
        }
        if count < 0 {
            throw WaylandError.io("recv: \(String(cString: strerror(errno)))")
        }
        if count == 0 {
            throw WaylandError.closed
        }
        if receivedFD >= 0 {
            pendingFileDescriptors.append(receivedFD)
        }
        readBuffer.append(contentsOf: chunk[0..<count])
        return parseAvailableMessages() ?? []
    }

    public func takeFileDescriptor() -> Int32? {
        guard !pendingFileDescriptors.isEmpty else { return nil }
        return pendingFileDescriptors.removeFirst()
    }

    public func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        for descriptor in pendingFileDescriptors {
            Darwin.close(descriptor)
        }
        pendingFileDescriptors.removeAll()
    }

    private func parseAvailableMessages() -> [WaylandMessage]? {
        var messages: [WaylandMessage] = []
        while readBuffer.count >= 8 {
            let bytes = Array(readBuffer.prefix(8))
            let objectID = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            let sizeOpcode = UInt32(bytes[4])
                | (UInt32(bytes[5]) << 8)
                | (UInt32(bytes[6]) << 16)
                | (UInt32(bytes[7]) << 24)
            let size = Int(sizeOpcode >> 16)
            let opcode = UInt16(sizeOpcode & 0xffff)
            guard size >= 8 else { return nil }
            guard readBuffer.count >= size else { break }
            let payload = Data(readBuffer.dropFirst(8).prefix(size - 8))
            readBuffer.removeFirst(size)
            messages.append(WaylandMessage(objectID: objectID, opcode: opcode, payload: payload))
        }
        return messages
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
