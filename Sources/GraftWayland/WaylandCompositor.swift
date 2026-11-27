import Foundation
import Darwin
import GraftWaylandC

public protocol WaylandCompositorDelegate: AnyObject {
    func compositor(
        _ compositor: WaylandCompositor,
        didUpdateSurface surfaceID: UInt32,
        pixels: Data,
        width: Int,
        height: Int,
        stride: Int,
        title: String?
    )
}

/// A deliberately small Wayland compositor core. It currently supports the
/// core `wl_compositor` / `wl_shm` subset and the xdg-shell toplevel path
/// needed to display one shared-memory surface. Input, multiple clients,
/// subsurfaces and GPU buffers are intentionally out of scope for this first
/// milestone.
public final class WaylandCompositor: @unchecked Sendable {
    public let socketPath: String
    public weak var delegate: WaylandCompositorDelegate?

    private var listenFD: Int32 = -1
    private var running = false
    private let connectionLock = NSLock()
    private var activeConnection: WaylandConnection?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard !running else { return }
        let fd = socketPath.withCString { graft_unix_listen($0) }
        guard fd >= 0 else {
            throw WaylandError.io("listen(\(socketPath)): \(String(cString: strerror(errno)))")
        }
        listenFD = fd
        running = true
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "GraftWaylandCompositor"
        thread.start()
    }

    public func stop() {
        guard running else { return }
        running = false
        if listenFD >= 0 {
            Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }
        connectionLock.lock()
        activeConnection?.close()
        activeConnection = nil
        connectionLock.unlock()
        unlink(socketPath)
    }

    private func acceptLoop() {
        while running {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if running {
                    continue
                }
                break
            }
            let connection = WaylandConnection(fd: fd)
            connectionLock.lock()
            activeConnection = connection
            connectionLock.unlock()
            serve(connection: connection)
            connection.close()
            connectionLock.lock()
            if activeConnection === connection {
                activeConnection = nil
            }
            connectionLock.unlock()
        }
    }

    private func serve(connection: WaylandConnection) {
        let state = ClientState()
        while running {
            do {
                let messages = try connection.readMessages()
                for message in messages {
                    process(message, connection: connection, state: state)
                }
            } catch {
                break
            }
        }
    }

    private func process(_ message: WaylandMessage, connection: WaylandConnection, state: ClientState) {
        guard let object = state.objects[message.objectID] else { return }
        var reader = WaylandArgumentReader(message.payload)

        switch object {
        case .display:
            switch message.opcode {
            case 0: // sync(new_id)
                guard let newID = reader.uint32() else { return }
                state.objects[newID] = .callback
                var builder = WaylandMessageBuilder()
                builder.uint32(state.nextSerial())
                try? connection.send(builder.message(objectID: newID, opcode: 0))
            case 1: // get_registry(new_id)
                guard let newID = reader.uint32() else { return }
                state.objects[newID] = .registry
                sendGlobals(to: newID, connection: connection)
            default:
                break
            }

        case .registry:
            guard message.opcode == 0,
                  reader.uint32() != nil, // global name
                  let interface = reader.string(),
                  reader.uint32() != nil, // version
                  let newID = reader.uint32() else { return }
            switch interface {
            case "wl_compositor": state.objects[newID] = .compositor
            case "wl_shm": state.objects[newID] = .shm
            case "xdg_wm_base": state.objects[newID] = .xdgWmBase
            default: break
            }

        case .compositor:
            guard message.opcode == 0, let newID = reader.uint32() else { return }
            state.objects[newID] = .surface(newID)
            state.surfaces[newID] = SurfaceState()

        case .shm:
            guard message.opcode == 0,
                  let newID = reader.uint32(),
                  let size = reader.int32(),
                  let fd = connection.takeFileDescriptor() else { return }
            guard let pool = SharedMemoryPool(fd: fd, size: Int(size)) else { return }
            state.pools[newID] = pool
            state.objects[newID] = .shmPool(newID)

        case .shmPool(let poolID):
            guard message.opcode == 0,
                  let newID = reader.uint32(),
                  let offset = reader.int32(),
                  let width = reader.int32(),
                  let height = reader.int32(),
                  let stride = reader.int32(),
                  let format = reader.uint32() else { return }
            guard width > 0, height > 0, stride >= width * 4 else { return }
            state.buffers[newID] = BufferInfo(
                poolID: poolID,
                offset: Int(offset),
                width: Int(width),
                height: Int(height),
                stride: Int(stride),
                format: format
            )
            state.objects[newID] = .buffer(newID)

        case .buffer:
            if message.opcode == 0 {
                state.buffers.removeValue(forKey: message.objectID)
                state.objects.removeValue(forKey: message.objectID)
            }

        case .surface(let surfaceID):
            let surface = state.surfaces[surfaceID] ?? SurfaceState()
            state.surfaces[surfaceID] = surface
            switch message.opcode {
            case 1: // attach(buffer, x, y)
                let buffer = reader.uint32() ?? 0
                surface.pendingBufferID = buffer == 0 ? nil : buffer
            case 2, 9: // damage / damage_buffer
                break
            case 6: // commit
                commitSurface(surfaceID, surface: surface, state: state, connection: connection)
            default:
                break
            }

        case .xdgWmBase:
            guard message.opcode == 2,
                  let newID = reader.uint32(),
                  let surfaceID = reader.uint32() else { return }
            let xdgSurface = XdgSurfaceState(surfaceID: surfaceID)
            state.xdgSurfaces[newID] = xdgSurface
            state.objects[newID] = .xdgSurface(newID)
            if state.surfaces[surfaceID] == nil {
                state.surfaces[surfaceID] = SurfaceState()
            }
            state.surfaces[surfaceID]?.xdgSurfaceID = newID

        case .xdgSurface(let xdgSurfaceID):
            switch message.opcode {
            case 1: // get_toplevel(new_id)
                guard let newID = reader.uint32() else { return }
                let toplevel = XdgToplevelState(xdgSurfaceID: xdgSurfaceID)
                state.xdgToplevels[newID] = toplevel
                state.objects[newID] = .xdgToplevel(newID)
                state.xdgSurfaces[xdgSurfaceID]?.toplevelID = newID
            case 4: // ack_configure
                break
            default:
                break
            }

        case .xdgToplevel(let toplevelID):
            if message.opcode == 2 { // set_title
                state.xdgToplevels[toplevelID]?.title = reader.string()
            }

        case .callback, .region:
            break
        }
    }

    private func commitSurface(
        _ surfaceID: UInt32,
        surface: SurfaceState,
        state: ClientState,
        connection: WaylandConnection
    ) {
        if let bufferID = surface.pendingBufferID,
           let buffer = state.buffers[bufferID],
           let pool = state.pools[buffer.poolID],
           let pixels = pool.pixels(for: buffer) {
            let title = surface.xdgSurfaceID
                .flatMap { state.xdgSurfaces[$0]?.toplevelID }
                .flatMap { state.xdgToplevels[$0]?.title }
            delegate?.compositor(
                self,
                didUpdateSurface: surfaceID,
                pixels: pixels,
                width: buffer.width,
                height: buffer.height,
                stride: buffer.stride,
                title: title
            )
            try? connection.send(WaylandMessageBuilder().message(objectID: bufferID, opcode: 0))
            return
        }

        guard let xdgSurfaceID = surface.xdgSurfaceID,
              let toplevelID = state.xdgSurfaces[xdgSurfaceID]?.toplevelID,
              !surface.configured else { return }
        var toplevel = WaylandMessageBuilder()
        toplevel.int32(640)
        toplevel.int32(480)
        toplevel.array(Data())
        try? connection.send(toplevel.message(objectID: toplevelID, opcode: 0))

        var xdg = WaylandMessageBuilder()
        xdg.uint32(state.nextSerial())
        try? connection.send(xdg.message(objectID: xdgSurfaceID, opcode: 0))
        surface.configured = true
    }

    private func sendGlobals(to registryID: UInt32, connection: WaylandConnection) {
        let globals: [(UInt32, String, UInt32)] = [
            (1, "wl_compositor", 4),
            (2, "wl_shm", 1),
            (3, "xdg_wm_base", 1)
        ]
        for (name, interface, version) in globals {
            var builder = WaylandMessageBuilder()
            builder.uint32(name)
            builder.string(interface)
            builder.uint32(version)
            try? connection.send(builder.message(objectID: registryID, opcode: 0))
        }
    }
}

private enum ServerObject {
    case display
    case registry
    case compositor
    case shm
    case shmPool(UInt32)
    case buffer(UInt32)
    case surface(UInt32)
    case xdgWmBase
    case xdgSurface(UInt32)
    case xdgToplevel(UInt32)
    case callback
    case region
}

private final class ClientState {
    var objects: [UInt32: ServerObject] = [1: .display]
    var pools: [UInt32: SharedMemoryPool] = [:]
    var buffers: [UInt32: BufferInfo] = [:]
    var surfaces: [UInt32: SurfaceState] = [:]
    var xdgSurfaces: [UInt32: XdgSurfaceState] = [:]
    var xdgToplevels: [UInt32: XdgToplevelState] = [:]
    private var serial: UInt32 = 1

    func nextSerial() -> UInt32 {
        defer { serial &+= 1 }
        return serial
    }
}

private final class SurfaceState {
    var pendingBufferID: UInt32?
    var xdgSurfaceID: UInt32?
    var configured = false
}

private final class XdgSurfaceState {
    let surfaceID: UInt32
    var toplevelID: UInt32?

    init(surfaceID: UInt32) {
        self.surfaceID = surfaceID
    }
}

private final class XdgToplevelState {
    let xdgSurfaceID: UInt32
    var title: String?

    init(xdgSurfaceID: UInt32) {
        self.xdgSurfaceID = xdgSurfaceID
    }
}

private struct BufferInfo {
    let poolID: UInt32
    let offset: Int
    let width: Int
    let height: Int
    let stride: Int
    let format: UInt32
}

private final class SharedMemoryPool {
    let pointer: UnsafeMutableRawPointer
    let size: Int
    private let fd: Int32

    init?(fd: Int32, size: Int) {
        guard size > 0 else {
            Darwin.close(fd)
            return nil
        }
        let pointer = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard pointer != MAP_FAILED else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
        self.pointer = pointer!
        self.size = size
    }

    deinit {
        munmap(pointer, size)
        Darwin.close(fd)
    }

    func pixels(for buffer: BufferInfo) -> Data? {
        let required = buffer.offset + buffer.stride * buffer.height
        guard required > 0, required <= size else { return nil }
        return Data(bytes: pointer.advanced(by: buffer.offset), count: buffer.stride * buffer.height)
    }
}
