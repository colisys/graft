import Foundation

public struct WaylandMessage: Sendable, Equatable {
    public let objectID: UInt32
    public let opcode: UInt16
    public let payload: Data

    public init(objectID: UInt32, opcode: UInt16, payload: Data = Data()) {
        self.objectID = objectID
        self.opcode = opcode
        self.payload = payload
    }
}

public struct WaylandMessageBuilder {
    private var payload = Data()

    public init() {}

    public mutating func uint32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { payload.append(contentsOf: $0) }
    }

    public mutating func int32(_ value: Int32) {
        uint32(UInt32(bitPattern: value))
    }

    public mutating func string(_ value: String?) {
        guard let value else {
            uint32(0)
            return
        }
        var bytes = Array(value.utf8)
        bytes.append(0)
        uint32(UInt32(bytes.count))
        payload.append(contentsOf: bytes)
        pad()
    }

    public mutating func array(_ value: Data) {
        uint32(UInt32(value.count))
        payload.append(value)
        pad()
    }

    public func message(objectID: UInt32, opcode: UInt16) -> WaylandMessage {
        WaylandMessage(objectID: objectID, opcode: opcode, payload: payload)
    }

    private mutating func pad() {
        while payload.count % 4 != 0 {
            payload.append(0)
        }
    }
}

public struct WaylandArgumentReader {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ data: Data) {
        self.bytes = Array(data)
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func uint32() -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        offset += 4
        return value
    }

    public mutating func int32() -> Int32? {
        guard let value = uint32() else { return nil }
        return Int32(bitPattern: value)
    }

    public mutating func string() -> String? {
        guard let length = uint32() else { return nil }
        guard length > 0 else { return nil }
        let count = Int(length)
        guard offset + count <= bytes.count else { return nil }
        var slice = Array(bytes[offset..<(offset + count)])
        offset += count
        if let nul = slice.firstIndex(of: 0) {
            slice.removeSubrange(nul...)
        }
        while offset % 4 != 0 && offset < bytes.count {
            offset += 1
        }
        return String(decoding: slice, as: UTF8.self)
    }

    public mutating func array() -> Data? {
        guard let length = uint32() else { return nil }
        let count = Int(length)
        guard offset + count <= bytes.count else { return nil }
        let value = Data(bytes[offset..<(offset + count)])
        offset += count
        while offset % 4 != 0 && offset < bytes.count {
            offset += 1
        }
        return value
    }

    public mutating func skip(_ count: Int) {
        offset = min(bytes.count, offset + count)
    }
}
