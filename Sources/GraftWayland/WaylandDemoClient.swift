import Foundation
import Darwin

/// Owns the client connection and the lifetime of the demo buffer.
public final class WaylandDemoSession {
    public let connection: WaylandConnection

    public init(connection: WaylandConnection) {
        self.connection = connection
    }

    public func close() {
        connection.close()
    }

    deinit {
        close()
    }
}

/// Sends a single ARGB shared-memory surface to a minimal compositor. This is
/// the first end-to-end use case: a local Wayland client creates a surface,
/// xdg-toplevel, shared buffer and commits it.
public enum WaylandDemoClient {
    public static func sendTestPattern(
        socketPath: String,
        width: Int = 640,
        height: Int = 480
    ) throws -> WaylandDemoSession {
        let connection = try WaylandConnection.connect(path: socketPath)
        let stride = width * 4
        let size = stride * height

        let temporaryPath = NSTemporaryDirectory()
            + "graft-wayland-\(UUID().uuidString).shm"
        let fd = open(temporaryPath, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            connection.close()
            throw WaylandError.io("cannot create shared memory file")
        }
        defer {
            unlink(temporaryPath)
            Darwin.close(fd)
        }

        guard ftruncate(fd, off_t(size)) == 0 else {
            connection.close()
            throw WaylandError.io("cannot size shared memory file")
        }
        guard let mapping = mmap(
            nil,
            size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            0
        ), mapping != MAP_FAILED else {
            connection.close()
            throw WaylandError.io("cannot map shared memory file")
        }
        defer { munmap(mapping, size) }

        let bytes = mapping.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                // Wayland ARGB8888 on little-endian: B, G, R, A.
                bytes[offset] = UInt8((x * 255) / max(1, width - 1))
                bytes[offset + 1] = UInt8((y * 255) / max(1, height - 1))
                bytes[offset + 2] = 96
                bytes[offset + 3] = 255
            }
        }

        var builder = WaylandMessageBuilder()
        builder.uint32(2) // registry
        try connection.send(builder.message(objectID: 1, opcode: 1))

        bind(connection: connection, registryID: 2, name: 1, interface: "wl_compositor", version: 4, newID: 3)
        bind(connection: connection, registryID: 2, name: 2, interface: "wl_shm", version: 1, newID: 4)
        bind(connection: connection, registryID: 2, name: 3, interface: "xdg_wm_base", version: 1, newID: 5)

        var surface = WaylandMessageBuilder()
        surface.uint32(6)
        try connection.send(surface.message(objectID: 3, opcode: 0))

        var xdgSurface = WaylandMessageBuilder()
        xdgSurface.uint32(7)
        xdgSurface.uint32(6)
        try connection.send(xdgSurface.message(objectID: 5, opcode: 2))

        var toplevel = WaylandMessageBuilder()
        toplevel.uint32(8)
        try connection.send(toplevel.message(objectID: 7, opcode: 1))

        var title = WaylandMessageBuilder()
        title.string("Graft Wayland Surface")
        try connection.send(title.message(objectID: 8, opcode: 2))

        var pool = WaylandMessageBuilder()
        pool.uint32(9)
        pool.int32(Int32(size))
        try connection.send(pool.message(objectID: 4, opcode: 0), fileDescriptor: fd)

        var buffer = WaylandMessageBuilder()
        buffer.uint32(10)
        buffer.int32(0)
        buffer.int32(Int32(width))
        buffer.int32(Int32(height))
        buffer.int32(Int32(stride))
        buffer.uint32(0) // ARGB8888
        try connection.send(buffer.message(objectID: 9, opcode: 0))

        var attach = WaylandMessageBuilder()
        attach.uint32(10)
        attach.int32(0)
        attach.int32(0)
        try connection.send(attach.message(objectID: 6, opcode: 1))

        var damage = WaylandMessageBuilder()
        damage.int32(0)
        damage.int32(0)
        damage.int32(Int32(width))
        damage.int32(Int32(height))
        try connection.send(damage.message(objectID: 6, opcode: 2))

        try connection.send(WaylandMessageBuilder().message(objectID: 6, opcode: 6))
        return WaylandDemoSession(connection: connection)
    }

    private static func bind(
        connection: WaylandConnection,
        registryID: UInt32,
        name: UInt32,
        interface: String,
        version: UInt32,
        newID: UInt32
    ) {
        var builder = WaylandMessageBuilder()
        builder.uint32(name)
        builder.string(interface)
        builder.uint32(version)
        builder.uint32(newID)
        try? connection.send(builder.message(objectID: registryID, opcode: 0))
    }
}
