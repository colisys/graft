import AppKit
import QuartzCore
import Darwin

private let width = 64, height = 48

private func fail(_ message: String) -> Never {
    fputs("sclereid-m2-window: \(message)\n", stderr)
    exit(1)
}

private func report(_ line: String) {
    puts(line)
    fflush(stdout)
}

private final class FrameView: NSView {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
        let factor: CGFloat = CommandLine.arguments.contains("--retina") ? 0.5 : 4
        super.init(frame: NSMakeRect(0, 0, CGFloat(width) * factor, CGFloat(height) * factor))
    }

    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { fail("no drawing context") }
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
    }

    func verify() {
        guard let snapshot = bitmapImageRepForCachingDisplay(in: bounds)?.retagging(with: .sRGB) else { fail("no view bitmap") }
        cacheDisplay(in: bounds, to: snapshot)
        let w = snapshot.pixelsWide, h = snapshot.pixelsHigh
        guard w >= Int(bounds.width), h >= Int(bounds.height) else { fail("undersized view bitmap") }
        // Sample the center of every source pixel's rendered footprint, including on Retina.
        guard snapshot.bitsPerSample == 8, snapshot.samplesPerPixel == 4 else { fail("unexpected cache format") }
        var pixel = [Int](repeating: 0, count: 4)
        for y in 0..<height {
            for x in 0..<width {
                let sx = (2 * x + 1) * w / (2 * width), sy = (2 * y + 1) * h / (2 * height)
                snapshot.getPixel(&pixel, atX: sx, y: sy)
                let right = x >= width / 2, bottom = y >= height / 2
                let expected = [right == bottom ? 255 : 0, right ? 255 : 0, bottom ? 255 : 0, 255]
                guard pixel == expected else {
                    fail("unexpected rendered color at (\(x), \(y)): \(pixel)")
                }
            }
        }
    }
}

private var window: NSWindow?
private var windowEvents: WindowEvents?

private final class WindowEvents: NSObject, NSWindowDelegate {
    var size: NSSize?
    var closeRequested = false
    var applyingFrame = false

    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        guard !applyingFrame, let view = w.contentView else { return }
        if let seat = view as? SeatView {
            if w.isVisible { seat.input("R \(Int(view.bounds.width)) \(Int(view.bounds.height))") }
        } else {
            size = view.bounds.size
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        ((notification.object as? NSWindow)?.contentView as? SeatView)?.input("L 0")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let view = sender.contentView as? SeatView {
            view.input("C 0")
        } else {
            closeRequested = true
        }
        return false // The client owns its shutdown; EOF closes the native window.
    }

    func flush() {
        if closeRequested {
            report("CLOSE")
        } else if let size {
            report("SIZE \(Int(size.width)) \(Int(size.height))")
        }
        size = nil
    }
}

private func onScreen(_ id: Int) -> Bool {
    CATransaction.flush()
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        fail("cannot query on-screen windows")
    }
    return windows.contains { ($0[kCGWindowNumber as String] as? Int) == id }
}

private let animationWidth = 640, animationHeight = 360

private func makeImage(_ frame: Data, width: Int, height: Int) -> CGImage {
    let format = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
    guard let provider = CGDataProvider(data: frame as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: space, bitmapInfo: format, provider: provider,
                              decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { fail("invalid frame") }
    return image
}

private func openWindow(_ view: NSView, interactive: Bool = false) -> NSWindow {
    let style: NSWindow.StyleMask = interactive ? [.titled, .closable, .resizable] : [.titled]
    let w = NSWindow(contentRect: view.bounds, styleMask: style, backing: .buffered, defer: false)
    if interactive {
        let events = WindowEvents()
        windowEvents = events
        w.delegate = events
        w.contentMinSize = NSSize(width: 64, height: 64)
        w.contentMaxSize = NSSize(width: 640, height: 480)
    }
    w.colorSpace = .sRGB
    w.isReleasedWhenClosed = false
    w.title = "Sclereid M2"
    w.contentView = view
    window = w
    w.center()
    w.orderFrontRegardless()
    w.display()
    return w
}

private func show(_ frame: Data) {
    let view = FrameView(image: makeImage(frame, width: width, height: height))
    let w = openWindow(view)
    view.verify()
    guard w.isVisible, onScreen(w.windowNumber) else { fail("window is not ordered on screen") }
    if CommandLine.arguments.contains("--retina") {
        let backing = view.convertToBacking(view.bounds).size
        guard view.bounds.size == NSSize(width: 32, height: 24), backing.width == 32 * w.backingScaleFactor, backing.height == 24 * w.backingScaleFactor else { fail("unexpected Retina geometry: \(view.bounds.size), \(backing)") }
        report("RETINA_OK logical=32x24 backing=\(Int(backing.width))x\(Int(backing.height)) buffer=64x48")
    }
    report("WINDOW_OK")
}

private final class SeatView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    func input(_ text: String) {
        guard let value = ProcessInfo.processInfo.environment["M2_INPUT_FD"], let fd = Int32(value) else { return }
        let line = text + "\n"
        if line.withCString({ write(fd, $0, line.utf8.count) }) != line.utf8.count { fail("input channel") }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { input("M \(Int(p.x)) \(Int(p.y))") }
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseDown(with event: NSEvent) { mouseMoved(with: event); input("B 1") }
    override func mouseUp(with event: NSEvent) { input("B 0") }
    private let codes: [UInt16: Int] = [0:30,1:31,2:32,3:33,4:35,5:34,6:44,7:45,8:46,9:47,
        11:48,12:16,13:17,14:18,15:19,16:21,17:20,31:24,32:22,34:23,35:25,36:28,
        37:38,38:36,40:37,45:49,46:50,48:15,49:57,51:14,53:1,123:105,124:106,125:108,126:103]
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 56 { input("K 42 \(event.modifierFlags.contains(.shift) ? 1 : 0)") }
    }
    override func keyDown(with event: NSEvent) {
        if let code = codes[event.keyCode], !event.isARepeat { input("K \(code) 1") }
    }
    override func keyUp(with event: NSEvent) {
        if let code = codes[event.keyCode] { input("K \(code) 0") }
    }
}

private func animate(_ frame: Data, width: Int, height: Int, interactive: Bool = false, scale: Int = 1) {
    let first = window == nil
    if first {
        let rect = NSMakeRect(0, 0, CGFloat(width / scale), CGFloat(height / scale))
        let view = ProcessInfo.processInfo.environment["M2_INPUT_FD"] == nil ? NSView(frame: rect) : SeatView(frame: rect)
        // Install a layer-hosting view so AppKit doesn't redraw over its contents.
        view.layer = CALayer()
        view.wantsLayer = true
        let w = openWindow(view, interactive: interactive)
        if view is SeatView { w.acceptsMouseMovedEvents = true; w.makeFirstResponder(view) }
    }
    guard let w = window, let layer = w.contentView?.layer else { fail("missing animation layer") }
    if let view = w.contentView as? SeatView {
        let target = NSSize(width: width / scale, height: height / scale)
        if view.bounds.size != target {
            windowEvents?.applyingFrame = true
            w.setContentSize(target)
            windowEvents?.applyingFrame = false
        }
    }
    let start = CACurrentMediaTime()
    let image = makeImage(frame, width: width, height: height)
    let constructed = CACurrentMediaTime()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contentsScale = CGFloat(scale)
    layer.contents = image
    CATransaction.commit()
    // This measures submission, not when the frame reaches the display.
    CATransaction.flush()
    let applied = CACurrentMediaTime()
    if first && !(w.isVisible && onScreen(w.windowNumber)) { fail("window is not ordered on screen") }
    if let view = w.contentView as? SeatView {
        if !w.isVisible {
            w.orderFrontRegardless()
            w.display()
            guard w.isVisible, onScreen(w.windowNumber) else { fail("remapped window is not on screen") }
            report("REMAPPED")
        }
        let backing = view.convertToBacking(view.bounds)
        report("GEOMETRY \(Int(view.bounds.width)) \(Int(view.bounds.height)) backing \(Int(backing.width)) \(Int(backing.height))")
    }
    windowEvents?.flush()
    report(String(format: "FRAME_OK %.6f %.6f", (constructed - start) * 1000, (applied - constructed) * 1000))
}

private func cleanup() {
    guard let w = window else { fail("no window to close") }
    let id = w.windowNumber
    w.close()
    guard !w.isVisible, !onScreen(id) else { fail("window still visible after close") }
    w.contentView = nil
    window = nil
}

private func readBytes(_ count: Int) -> Data? {
    // Use fresh storage: the image provider may retain these bytes after submission.
    var frame = Data(count: count)
    let complete = frame.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
        var offset = 0
        while offset < bytes.count {
            let n = read(STDIN_FILENO, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { fail("stdin: \(String(cString: strerror(errno)))") }
            if n == 0 && offset == 0 { return false }
            guard n > 0 else { fail("EOF after \(offset) frame bytes") }
            offset += n
        }
        return true
    }
    return complete ? frame : nil
}

private func readFrame(width: Int, height: Int, opaque: Bool = true) -> Data? {
    guard let frame = readBytes(width * height * 4) else { return nil }
    if opaque && !stride(from: 3, to: frame.count, by: 4).allSatisfy({ frame[$0] == 255 }) {
        fail("non-opaque frame")
    }
    return frame
}

private func receiveXDG() {
    while let header = readBytes(4) {
        let w = Int(header[0]) | Int(header[1]) << 8
        let h = Int(header[2]) | Int(header[3]) << 8
        if w == 0 {
            DispatchQueue.main.sync {
                guard let window, let events = windowEvents else { fail("window command before first frame") }
                if h == 1 { window.setContentSize(NSSize(width: 320, height: 280)) }
                else if h == 2 { window.performClose(nil) }
                else if h == 3, window.contentView is SeatView {
                    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                        window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: 11, y: window.contentView!.bounds.height - 8), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
                    }
                    func shift(_ flags: NSEvent.ModifierFlags) {
                        window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
                    }
                    shift(.shift)
                    for type: NSEvent.EventType in [.keyDown, .keyUp] {
                        window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!)
                    }
                    shift([])
                } else if h == 4, let view = window.contentView as? SeatView {
                    let id = window.windowNumber
                    view.layer?.contents = nil
                    window.orderOut(nil)
                    guard !window.isVisible, !onScreen(id) else { fail("unmapped window is still on screen") }
                } else if h == 5, window.contentView is SeatView {
                    window.setContentSize(NSSize(width: 160, height: 120))
                } else { fail("unknown window command") }
                events.flush()
                report("COMMAND_OK")
            }
            continue
        }
        var scale = 1
        if ProcessInfo.processInfo.environment["M2_INPUT_FD"] != nil {
            guard let field = readBytes(2), (1...2).contains(Int(field[0])), field[1] == 0 else { fail("scale field") }
            scale = Int(field[0])
        }
        guard (1...640).contains(w), (1...480).contains(h),
              let frame = readFrame(width: w, height: h, opaque: false) else { fail("invalid XDG frame") }
        DispatchQueue.main.sync {
            autoreleasepool { animate(frame, width: w, height: h, interactive: true, scale: scale) }
        }
    }
}

private func receiveSingle() {
    guard let frame = readFrame(width: width, height: height) else { fail("EOF after 0 frame bytes") }
    DispatchQueue.main.sync { show(frame) }
    var extra: UInt8 = 0
    while true {
        let n = read(STDIN_FILENO, &extra, 1)
        if n < 0 && errno == EINTR { continue }
        guard n >= 0 else { fail("stdin: \(String(cString: strerror(errno)))") }
        guard n == 0 else { fail("unexpected data after frame") }
        break
    }
}

private func receive(streamSize: (Int, Int)?, xdg: Bool) {
    if xdg {
        receiveXDG()
    } else if let (width, height) = streamSize {
        while let frame = readFrame(width: width, height: height) {
            DispatchQueue.main.sync { autoreleasepool { animate(frame, width: width, height: height) } }
        }
    } else {
        receiveSingle()
    }
    DispatchQueue.main.async {
        autoreleasepool {
            if streamSize != nil, let w = window, !(w.isVisible && onScreen(w.windowNumber)) {
                fail("window is not ordered on screen at EOF")
            }
            if window != nil { cleanup() }
        }
        report("CLEANUP_OK")
        exit(0)
    }
}

let app = NSApplication.shared
if CommandLine.arguments.dropFirst().elementsEqual(["--backing-scale"]) {
    guard let factor = NSScreen.main?.backingScaleFactor, factor == 1 || factor == 2 else {
        fail("expected a main screen with 1x or 2x backing")
    }
    report(String(Int(factor)))
    exit(0)
}
app.setActivationPolicy(.accessory)
let streamSize: (Int, Int)?
let xdg = CommandLine.arguments.dropFirst().elementsEqual(["--weston"])
switch Array(CommandLine.arguments.dropFirst()) {
case ["--animate"]: streamSize = (animationWidth, animationHeight)
case ["--weston"]: streamSize = nil
case [], ["--retina"]: streamSize = nil
default: fail("expected --animate or --weston")
}
DispatchQueue.global().async { receive(streamSize: streamSize, xdg: xdg) }
app.run()
