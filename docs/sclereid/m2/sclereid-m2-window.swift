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

private class FrameView: NSView {
    var image: CGImage

    init(image: CGImage, size: NSSize? = nil) {
        self.image = image
        let factor: CGFloat = CommandLine.arguments.contains("--retina") ? 0.5 : 4
        super.init(frame: NSRect(origin: .zero, size: size ?? NSSize(width: CGFloat(width) * factor, height: CGFloat(height) * factor)))
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

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let layer = w.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = w.backingScaleFactor
        CATransaction.commit()
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

private let popupOrigin: NSPoint? = {
    guard let raw = ProcessInfo.processInfo.environment["M2_POPUP_ORIGIN"] else { return nil }
    let fields = raw.split(separator: " ").compactMap { Int($0) }
    guard fields.count == 2 else { fail("invalid popup origin") }
    return NSPoint(x: fields[0], y: fields[1])
}()

private func openWindow(_ view: NSView, interactive: Bool = false, inputDelegate: NSWindowDelegate? = nil) -> NSWindow {
    let style: NSWindow.StyleMask = popupOrigin != nil ? [.borderless] : interactive ? [.titled, .closable, .resizable] : [.titled]
    let w = NSWindow(contentRect: view.bounds, styleMask: style, backing: .buffered, defer: false)
    if interactive && popupOrigin == nil {
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
    if let popupOrigin { w.setFrameOrigin(popupOrigin); w.level = .floating }
    else { w.center() }
    if let inputDelegate {
        w.delegate = inputDelegate
        // Ordering can synchronously deliver the first key notification.
        guard w.makeFirstResponder(view) else { fail("input view cannot receive keys") }
        w.makeKeyAndOrderFront(nil)
    } else {
        w.orderFrontRegardless()
    }
    w.display()
    return w
}

private func show(_ frame: Data) {
    let view = FrameView(image: makeImage(frame, width: width, height: height))
    let w = openWindow(view)
    view.verify()
    guard w.isVisible, onScreen(w.windowNumber) else { fail("window is not ordered on screen") }
    if CommandLine.arguments.contains("--retina") {
        if let popupOrigin {
            let rect = w.convertToScreen(view.convert(view.bounds, to: nil))
            guard rect.origin == popupOrigin else { fail("popup origin mismatch") }
            report("POPUP_ORIGIN \(Int(rect.minX)) \(Int(rect.minY))")
        }
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
    override func rightMouseDown(with event: NSEvent) { mouseMoved(with: event); input("B 1 1") }
    override func rightMouseUp(with event: NSEvent) { input("B 0 1") }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func scrollWheel(with event: NSEvent) {
        for (axis,delta) in [event.scrollingDeltaY,event.scrollingDeltaX].enumerated() where delta != 0 {
            input("W \(axis) \(Int(delta > 0 ? -max(1,min(120,delta * 10)) : max(1,min(120,-delta * 10))))")
        }
    }
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

private func setFrame(_ image: CGImage, on layer: CALayer, backingScale: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contentsScale = backingScale
    layer.contentsGravity = .resize
    layer.minificationFilter = .nearest
    layer.magnificationFilter = .nearest
    layer.contents = image
    CATransaction.commit()
}

private func verifyOffscreen2x(_ frame: Data, image: CGImage, bounds: CGRect, scale: Int) {
    let layer = CALayer()
    layer.bounds = bounds
    setFrame(image, on: layer, backingScale: 2)
    let w = Int(bounds.width * 2), h = Int(bounds.height * 2)
    let format = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
    guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: image.colorSpace!, bitmapInfo: format.rawValue),
          let output = context.data else { fail("no offscreen bitmap") }
    context.interpolationQuality = .none
    context.scaleBy(x: 2, y: 2)
    layer.render(in: context)
    let actual = UnsafeRawBufferPointer(start: output, count: w * h * 4)
    let repeatCount = 2 / scale
    frame.withUnsafeBytes { (expected: UnsafeRawBufferPointer) in
        for y in 0..<h {
            for x in 0..<w {
                let dst = (y * w + x) * 4
                let src = ((y / repeatCount) * image.width + x / repeatCount) * 4
                guard actual[dst..<(dst + 4)].elementsEqual(expected[src..<(src + 4)]) else {
                    fail("offscreen 2x mismatch at (\(x), \(y)): \(Array(actual[dst..<(dst + 4)])) != \(Array(expected[src..<(src + 4)]))")
                }
            }
        }
    }
    report("OFFSCREEN_2X_OK \(w)x\(h) exact_pixels=\(w * h) repeat=\(repeatCount)")
}

private let verifyPixels = ProcessInfo.processInfo.environment["M2_VERIFY_PIXELS"] == "1"

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
    setFrame(image, on: layer, backingScale: w.backingScaleFactor)
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
        if let popupOrigin {
            let rect = w.convertToScreen(view.convert(view.bounds, to: nil))
            guard rect.origin == popupOrigin else { fail("popup origin mismatch") }
            report("POPUP_ORIGIN \(Int(rect.minX)) \(Int(rect.minY))")
        }
        let backing = view.convertToBacking(view.bounds)
        report("GEOMETRY \(Int(view.bounds.width)) \(Int(view.bounds.height)) backing \(Int(backing.width)) \(Int(backing.height))")
        if verifyPixels {
            guard layer.bounds.size == view.bounds.size, layer.contentsScale == w.backingScaleFactor,
                  layer.minificationFilter == .nearest, layer.magnificationFilter == .nearest else {
                fail("unexpected live layer configuration")
            }
            report("LAYER_OK contents_scale=\(Int(layer.contentsScale)) buffer_scale=\(scale) filter=nearest")
            verifyOffscreen2x(frame, image: image, bounds: layer.bounds, scale: scale)
        }
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
            // SeatView command 6 injects input without reading a payload.
            DispatchQueue.main.sync {
                guard let window, let events = windowEvents else { fail("window command before first frame") }
                if h == 1 { window.setContentSize(NSSize(width: 320, height: 280)) }
                else if h == 2 { window.performClose(nil) }
                else if (h == 3 || h == 6), let seat = window.contentView as? SeatView {
                    for type: NSEvent.EventType in (h == 6 ? [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]) {
                        window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: 11, y: window.contentView!.bounds.height - 8), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
                    }
                    if h == 6 {
                        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)!
                        seat.scrollWheel(with: NSEvent(cgEvent: wheel)!)
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
                } else if h == 7, window.contentView is SeatView {
                    for (width, height) in [(170, 130), (180, 140), (192, 144)] {
                        window.setContentSize(NSSize(width: width, height: height))
                    }
                } else if h == 8, let view = window.contentView {
                    let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
                    report("CONTENT_ORIGIN \(Int(rect.minX)) \(Int(rect.maxY))")
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

// --popup-host: ASCII commands terminated by LF. PARENT w h and POPUP x y w h
// each consume exactly w*h*4 opaque sRGB BGRA bytes, top row first, no padding
// or trailing delimiter. One texel per logical point. x/y and MOVE dx dy use
// right/down-positive points relative to parent content and current origin respectively.
// CLOSE removes only the popup; EOF closes any remaining windows.
private func popupHeader() -> [Substring]? {
    var bytes = Data()
    while let byte = readBytes(1)?.first {
        if byte == 10 { return String(decoding: bytes, as: UTF8.self).split(separator: " ") }
        guard (32...126).contains(byte), bytes.count < 128 else { fail("invalid popup header") }
        bytes.append(byte)
    }
    guard bytes.isEmpty else { fail("EOF in popup header") }
    return nil
}

// --menu-host uses the same frame format, with premultiplied alpha and repeatable
// PARENT/POPUP submissions. CLICK coordinates are local to the target content,
// right/down-positive; the event is sent at the center of the addressed pixel.
// EDGE (requires PARENT and no open POPUP) places the parent at the bottom right
// of its screen and replies WORKAREA x y w h, an inward-rounded rectangle in
// parent-content coordinates (right/down-positive). CHECK_EDGE requires a popup
// fully inside that visibleFrame and replies EDGE_OK. After EDGE, CLICK POPUP_EDGE
// LEFT x y allows a nontransparent popup pixel over the parent and replies
// CLICK_OK POPUP_EDGE LEFT x y.
private enum MenuClickTarget: String {
    case parent = "PARENT", popup = "POPUP", popupEdge = "POPUP_EDGE"
}

private enum MenuButton: String {
    case left = "LEFT", right = "RIGHT"

    var events: [NSEvent.EventType] {
        self == .left ? [.leftMouseDown, .leftMouseUp] : [.rightMouseDown, .rightMouseUp]
    }
}

private class MenuFrameView: FrameView {
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { fail("no menu drawing context") }
        context.saveGState()
        context.setBlendMode(.copy)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        super.draw(dirtyRect)
        context.restoreGState()
    }

    private var hits: [NSEvent.EventType] = []
    private var expectedPoint: NSPoint?
    func hit(_ event: NSEvent) {
        guard let expectedPoint, event.window === window,
              convert(event.locationInWindow, from: nil) == expectedPoint else { return }
        hits.append(event.type)
    }
    override func mouseDown(with event: NSEvent) { hit(event) }
    override func mouseUp(with event: NSEvent) { hit(event) }
    override func rightMouseDown(with event: NSEvent) { hit(event) }
    override func rightMouseUp(with event: NSEvent) { hit(event) }

    override func mouseMoved(with event: NSEvent) { hit(event) }

    func send(_ events: [NSEvent.EventType], at point: NSPoint, in target: NSWindow) {
        hits.removeAll()
        expectedPoint = point
        let location = convert(point, to: nil)
        for type in events {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: target.windowNumber, context: nil,
                                                 eventNumber: 1, clickCount: 1, pressure: 0) else { fail("cannot create menu event") }
            if type == .mouseMoved {
                // Window-level hover routing depends on tracking state and the real cursor.
                // For a SID-addressed synthetic move, route by the supplied location instead.
                guard hitTest(superview?.convert(location, from: nil) ?? location) === self else { fail("menu move missed target") }
                mouseMoved(with: event)
            } else {
                target.sendEvent(event)
            }
        }
        expectedPoint = nil
        guard hits == events else { fail("menu view did not receive \(events) at \(point): \(hits)") }
    }
}

private final class PopupHost {
    let menu: Bool
    var child: NSWindow?

    init(menu: Bool) { self.menu = menu }
    var pixels = Data()
    var offset = NSPoint.zero
    private var edgeWorkArea: CGRect? // WindowServer coordinates at EDGE time.

    func edge() {
        guard let p = window, child == nil, let screen = p.screen,
              let desktopTop = NSScreen.screens.first?.frame.maxY else { fail("EDGE requires a parent on screen without popup") }
        let visible = screen.visibleFrame
        var content = p.contentRect(forFrameRect: p.frame)
        content.origin = NSPoint(x: visible.maxX - 8 - content.width, y: visible.minY + 8)
        p.setFrame(p.frameRect(forContentRect: content), display: true)
        content = p.contentRect(forFrameRect: p.frame)
        guard abs(visible.maxX - content.maxX - 8) <= 1,
              abs(content.minY - visible.minY - 8) <= 1 else { fail("parent did not reach screen edge") }

        let x = Int(ceil(visible.minX - content.minX)), y = Int(ceil(content.maxY - visible.maxY))
        let right = Int(floor(visible.maxX - content.minX)), bottom = Int(floor(content.maxY - visible.minY))
        edgeWorkArea = CGRect(x: visible.minX, y: desktopTop - visible.maxY, width: visible.width, height: visible.height)
        report("WORKAREA \(x) \(y) \(right - x) \(bottom - y)")
    }

    func checkEdge() {
        guard let edgeWorkArea else { fail("CHECK_EDGE requires EDGE") }
        let (_, popup, _) = popupGeometry()
        guard edgeWorkArea.contains(popup) else { fail("popup bounds \(popup) outside visibleFrame \(edgeWorkArea)") }
        report("EDGE_OK")
    }

    func submit(parent: Bool, data: Data, x: Int, y: Int, w: Int, h: Int) {
        let image = makeImage(data, width: w, height: h), size = NSSize(width: w, height: h)
        let view = menu ? MenuFrameView(image: image, size: size) : FrameView(image: image, size: size)
        if parent {
            let p: NSWindow
            if let existing = window {
                guard menu else { fail("duplicate PARENT") }
                p = existing
                let old = p.contentRect(forFrameRect: p.frame)
                let rect = NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
                if rect != old { p.setFrame(p.frameRect(forContentRect: rect), display: false) }
                p.contentView = view
                p.display()
            } else {
                p = openWindow(view)
            }
            guard view.bounds.size == size, onScreen(p.windowNumber) else { fail("parent geometry or visibility") }
            report("PARENT_OK")
            return
        }
        guard let p = window, menu || child == nil else { fail("POPUP requires parent without child") }
        let content = p.contentRect(forFrameRect: p.frame)
        let rect = NSRect(x: content.minX + CGFloat(x), y: content.maxY - CGFloat(y + h), width: CGFloat(w), height: CGFloat(h))
        let c: NSWindow
        if let child {
            c = child
            if c.frame != rect { c.setFrame(rect, display: false) }
            c.contentView = view
        } else {
            c = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            c.isReleasedWhenClosed = false
            c.hasShadow = false
            c.colorSpace = .sRGB
            if menu {
                c.isOpaque = false
                c.backgroundColor = .clear
                c.ignoresMouseEvents = false
            }
            c.contentView = view
            p.addChildWindow(c, ordered: .above)
        }
        c.display()
        child = c
        pixels = data
        offset = NSPoint(x: x, y: y)
        report("POPUP_OK outside=\(verify())")
    }

    // No desktop capture or screen-recording permission is needed for geometry.
    private func popupGeometry() -> (parent: CGRect, popup: CGRect, view: NSView) {
        CATransaction.flush()
        guard let p = window, let c = child, c.parent === p, let view = c.contentView,
              let desktopTop = NSScreen.screens.first?.frame.maxY,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { fail("missing popup windows") }
        func entry(_ win: NSWindow) -> (Int, CGRect) {
            guard let index = list.firstIndex(where: { $0[kCGWindowNumber as String] as? Int == win.windowNumber }),
                  let bounds = list[index][kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { fail("missing WindowServer bounds") }
            return (index, rect)
        }
        let (pi, pr) = entry(p), (ci, cr) = entry(c)
        let content = p.contentRect(forFrameRect: p.frame)
        guard ci < pi, cr.minX == content.minX + offset.x, cr.minY == desktopTop - content.maxY + offset.y,
              cr.size == view.bounds.size else { fail("incorrect popup position or order: \(cr)") }
        return (pr, cr, view)
    }

    func verify() -> Int {
        let (pr, cr, view) = popupGeometry()
        let w = Int(cr.width), h = Int(cr.height)
        if menu {
            // Count nontransparent source pixels beyond the full parent frame,
            // using the child position and stacking verified by WindowServer.
            var outside = 0
            for y in 0..<h {
                for x in 0..<w where pixels[(y*w+x)*4+3] != 0 &&
                    !pr.contains(CGPoint(x: cr.minX + CGFloat(x) + 0.5, y: cr.minY + CGFloat(y) + 0.5)) {
                    outside += 1
                }
            }
            return outside
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)?.retagging(with: .sRGB),
              rep.bitsPerSample == 8, rep.samplesPerPixel == 4 else { fail("unsupported popup bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        var pixel = [Int](repeating: 0, count: 4), outside = 0
        for y in 0..<h {
            for x in 0..<w where !pr.contains(CGPoint(x: cr.minX + CGFloat(x) + 0.5, y: cr.minY + CGFloat(y) + 0.5)) {
                rep.getPixel(&pixel, atX: (2*x+1)*rep.pixelsWide/(2*w), y: (2*y+1)*rep.pixelsHigh/(2*h))
                let i = (y*w+x)*4
                guard pixel == [Int(pixels[i+2]), Int(pixels[i+1]), Int(pixels[i]), 255] else { fail("popup pixel mismatch at \(x),\(y): \(pixel)") }
                outside += 1
            }
        }
        guard outside > 0 else { fail("no pixels outside parent frame") }
        return outside
    }

    func click(_ kind: MenuClickTarget, button: MenuButton, x: Int, y: Int) {
        guard let p = window, let target = kind == .parent ? p : child, let view = target.contentView as? MenuFrameView,
              target.isVisible else { fail("CLICK requires a visible target") }
        let point = NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
        guard view.bounds.contains(point) else { fail("CLICK outside target content") }
        if kind == .popup {
            let screenPoint = target.convertPoint(toScreen: view.convert(point, to: nil))
            guard !p.frame.contains(screenPoint) else { fail("POPUP click must be outside parent frame") }
        } else if kind == .popupEdge {
            guard edgeWorkArea != nil else { fail("POPUP_EDGE requires EDGE") }
            _ = popupGeometry()
        }
        if kind != .parent {
            guard pixels[(y * Int(view.bounds.width) + x) * 4 + 3] != 0 else { fail("CLICK on transparent popup pixel") }
        }
        view.send(button.events, at: point, in: target)
        report("CLICK_OK \(kind.rawValue) \(button.rawValue) \(x) \(y)")
    }

    func move(dx: Int, dy: Int) {
        guard let p = window, child != nil, dx != 0 || dy != 0 else { fail("MOVE requires popup and nonzero displacement") }
        let dest = NSPoint(x: p.frame.minX + CGFloat(dx), y: p.frame.minY - CGFloat(dy))
        p.setFrameOrigin(dest) // Only AppKit moves the attached child.
        guard p.frame.origin == dest else { fail("parent did not move as requested") }
        report("MOVE_OK outside=\(verify())")
    }

    func close() {
        guard let c = child, let p = window else { fail("no popup to close") }
        let id = c.windowNumber
        p.removeChildWindow(c)
        c.close()
        guard c.parent == nil, !c.isVisible, !onScreen(id), onScreen(p.windowNumber) else { fail("popup close failed") }
        c.contentView = nil
        child = nil
        pixels = Data()
    }
}

private func receivePopup(menu: Bool) {
    let host = PopupHost(menu: menu)
    while let fields = popupHeader() {
        if menu && fields.first == "CLICK" {
            guard fields.count == 5, let target = MenuClickTarget(rawValue: String(fields[1])),
                  let button = MenuButton(rawValue: String(fields[2])), target != .popupEdge || button == .left,
                  let x = Int(fields[3]), let y = Int(fields[4]), (0..<2048).contains(x), (0..<2048).contains(y) else {
                fail("invalid CLICK arguments")
            }
            DispatchQueue.main.sync { host.click(target, button: button, x: x, y: y) }
            continue
        }
        let args = fields.dropFirst().compactMap { Int($0) }
        guard args.count == fields.count - 1, args.allSatisfy({ (-8192...8192).contains($0) }) else { fail("invalid popup arguments") }
        switch (fields.first, args.count) {
        case ("PARENT", 2), ("POPUP", 4):
            let parent = fields.first == "PARENT", w = args[args.count-2], h = args[args.count-1]
            guard (1...2048).contains(w), (1...2048).contains(h), let data = readFrame(width: w, height: h, opaque: !menu) else { fail("invalid popup-host frame") }
            DispatchQueue.main.sync { autoreleasepool { host.submit(parent: parent, data: data, x: parent ? 0 : args[0], y: parent ? 0 : args[1], w: w, h: h) } }
        case ("EDGE", 0) where menu: DispatchQueue.main.sync { host.edge() }
        case ("CHECK_EDGE", 0) where menu: DispatchQueue.main.sync { host.checkEdge() }
        case ("MOVE", 2): DispatchQueue.main.sync { host.move(dx: args[0], dy: args[1]) }
        case ("CLOSE", 0): DispatchQueue.main.sync { host.close(); report("CLOSE_OK") }
        default: fail("unknown popup command or wrong argument count")
        }
    }
    DispatchQueue.main.sync {
        if host.child != nil { host.close() }
        if window != nil { cleanup() }
        report("CLEANUP_OK")
        exit(0)
    }
}

// --menu-tree-host: create-only PARENT and TREE_POPUP frames (menu-host encoding).
// SID 0 is the root. A close removes the named subtree, never the root.
private final class MenuInputView: MenuFrameView {
    var pointer: ((String, Int, Int) -> Void)?
    var keyboard: ((String, Int, Int) -> Void)? // root only
    override var acceptsFirstResponder: Bool { keyboard != nil }
    private var tracking: NSTrackingArea?
    private var pressID = 0
    private var leftPress: (start: NSPoint, origin: NSPoint, latest: NSPoint, moving: Bool)?

    func cancelMove() { leftPress = nil }

    func beginMove(_ id: Int) {
        guard id == pressID, leftPress != nil, window?.isKeyWindow == true else { return }
        leftPress?.moving = true
        moveWindow()
    }

    private func moveWindow() {
        guard let press = leftPress, press.moving else { return }
        window?.setFrameOrigin(NSPoint(x: press.origin.x + press.latest.x - press.start.x,
                                      y: press.origin.y + press.latest.y - press.start.y))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseMoved, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func hit(_ event: NSEvent) {
        super.hit(event)
        let p = convert(event.locationInWindow, from: nil)
        let x = Int(floor(p.x)), y = Int(floor(p.y))
        switch event.type {
        case .leftMouseUp:
            cancelMove()
            pointer?("B", 0, 0) // release even after dragging outside
        case .rightMouseUp: pointer?("U", x, y)
        case .leftMouseDown:
            if keyboard != nil, let window {
                pressID = pressID == Int(Int32.max) ? 1 : pressID + 1
                let point = window.convertPoint(toScreen: event.locationInWindow)
                leftPress = (point, window.frame.origin, point, false)
            }
            pointer?("M", x, y)
            pointer?("B", 1, keyboard == nil ? 0 : pressID)
        case .rightMouseDown: pointer?("D", x, y)
        case .otherMouseDown, .otherMouseUp:
            // AppKit numbers 2...7 match BTN_MIDDLE through BTN_TASK.
            guard (2...7).contains(event.buttonNumber) else { return }
            pointer?("P", 272 + event.buttonNumber, event.type == .otherMouseDown ? 1 : 0)
        default: if bounds.contains(p) { pointer?("M", x, y) }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if leftPress != nil, let window {
            leftPress?.latest = window.convertPoint(toScreen: event.locationInWindow)
            if leftPress?.moving == true { moveWindow(); return }
        }
        hit(event)
    }
    override func rightMouseDragged(with event: NSEvent) { hit(event) }

    override func otherMouseDown(with event: NSEvent) { hit(event) }
    override func otherMouseUp(with event: NSEvent) { hit(event) }
    override func otherMouseDragged(with event: NSEvent) { hit(event) }
    override func scrollWheel(with event: NSEvent) {
        // AppKit supplies points for precise devices and lines otherwise. Keep the
        // user's macOS scroll preference; flip AppKit's axis signs for the wire.
        let units: CGFloat = event.hasPreciseScrollingDeltas ? 120 : 120 * 10
        func fixed(_ delta: CGFloat) -> Int {
            guard delta.isFinite else { return 0 }
            let value = (-delta * units).rounded()
            return Int(min(CGFloat(Int32.max), max(CGFloat(Int32.min), value)))
        }
        let x = fixed(event.scrollingDeltaX), y = fixed(event.scrollingDeltaY)
        if x != 0 || y != 0 { pointer?("S", x, y) }
    }

    // AppKit virtual key position -> Linux evdev, independent of layout/text.
    // Unlisted codes pass to AppKit. This does not see system shortcuts eaten by
    // macOS, consumer/media keys delivered as systemDefined, or raw HID usages.
    static let codes: [UInt16: Int] = [
        // ANSI letters, digits and punctuation, plus ISO Section (0x0a).
        0x00:30, 0x01:31, 0x02:32, 0x03:33, 0x04:35, 0x05:34, 0x06:44, 0x07:45,
        0x08:46, 0x09:47, 0x0a:86, 0x0b:48, 0x0c:16, 0x0d:17, 0x0e:18, 0x0f:19,
        0x10:21, 0x11:20, 0x12:2, 0x13:3, 0x14:4, 0x15:5, 0x16:7, 0x17:6,
        0x18:13, 0x19:10, 0x1a:8, 0x1b:12, 0x1c:9, 0x1d:11, 0x1e:27, 0x1f:24,
        0x20:22, 0x21:26, 0x22:23, 0x23:25, 0x25:38, 0x26:36, 0x27:40, 0x28:37,
        0x29:39, 0x2a:43, 0x2b:51, 0x2c:53, 0x2d:49, 0x2e:50, 0x2f:52, 0x32:41,
        // Editing, navigation, arrows. Apple Help shares the PC Insert position.
        0x24:28, 0x30:15, 0x31:57, 0x33:14, 0x35:1, 0x6e:127, 0x72:110,
        0x73:102, 0x74:104, 0x75:111, 0x77:107, 0x79:109, 0x7b:105, 0x7c:106, 0x7d:108, 0x7e:103,
        // Keypad (Clear maps to NumLock); JIS Yen, Ro, keypad comma, Eisu, Kana.
        0x41:83, 0x43:55, 0x45:78, 0x47:69, 0x4b:98, 0x4c:96, 0x4e:74, 0x51:117,
        0x52:82, 0x53:79, 0x54:80, 0x55:81, 0x56:75, 0x57:76, 0x58:77, 0x59:71, 0x5b:72, 0x5c:73,
        0x5d:124, 0x5e:89, 0x5f:95, 0x66:94, 0x68:93,
        // F1–F20, plus volume keys if delivered as ordinary key events.
        0x7a:59, 0x78:60, 0x63:61, 0x76:62, 0x60:63, 0x61:64, 0x62:65, 0x64:66,
        0x65:67, 0x6d:68, 0x67:87, 0x6f:88, 0x69:183, 0x6b:184, 0x71:185, 0x6a:186,
        0x40:187, 0x4f:188, 0x50:189, 0x5a:190, 0x48:115, 0x49:114, 0x4a:113
    ]
    // Low side bits are NX_DEVICE*KEYMASK (IOKit hidsystem/IOLLEvent.h).
    static let modifiers: [UInt16: (code: Int, flag: NSEvent.ModifierFlags, side: UInt)] = [
        0x36:(126, .command, 0x10), 0x37:(125, .command, 0x08),
        0x38:(42, .shift, 0x02), 0x3c:(54, .shift, 0x04),
        0x3a:(56, .option, 0x20), 0x3d:(100, .option, 0x40),
        0x3b:(29, .control, 0x01), 0x3e:(97, .control, 0x2000),
        0x39:(58, .capsLock, 0), 0x3f:(464, .function, 0)
    ]
    private var heldModifiers: Set<UInt16> = []
    func resetModifiers() { heldModifiers.removeAll() }
    override func keyDown(with event: NSEvent) {
        guard let code = Self.codes[event.keyCode] else { super.keyDown(with: event); return }
        if !event.isARepeat { keyboard?("K", code, 1) }
    }
    override func keyUp(with event: NSEvent) {
        if let code = Self.codes[event.keyCode] { keyboard?("K", code, 0) }
        else { super.keyUp(with: event) }
    }
    override func flagsChanged(with event: NSEvent) {
        let key = event.keyCode
        guard let modifier = Self.modifiers[key] else { super.flagsChanged(with: event); return }
        let flags = event.modifierFlags
        let wasDown = heldModifiers.contains(key)
        let down: Bool
        if !flags.contains(modifier.flag) { down = false }
        else if modifier.side == 0 { down = true } // Caps Lock reports its latch state.
        else {
            let pair = Self.modifiers.values.filter { $0.flag == modifier.flag }.reduce(UInt(0)) { $0 | $1.side }
            // An event without device-side bits can only tell us that at least
            // one side is down. Use the changed key's prior state in that case.
            down = flags.rawValue & pair != 0 ? flags.rawValue & modifier.side != 0 : !wasDown
        }
        guard down != wasDown else { return }
        if down { heldModifiers.insert(key) } else { heldModifiers.remove(key) }
        keyboard?("K", modifier.code, down ? 1 : 0)
    }
}

private final class MenuInputPopup: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MenuTree: NSObject, NSWindowDelegate {
    let input: Bool
    init(input: Bool) { self.input = input }
    private var keyUpMonitor: Any?

    func stopMonitoringKeyUp() {
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        keyUpMonitor = nil
    }

    // Newest live popup owns menu navigation, without becoming macOS key.
    private var targets = [Int]()
    private func forward(_ op: String, _ x: Int, _ y: Int) {
        if let sid = targets.last { report("INPUT \(sid) \(op) \(x) \(y)") }
    }
    func windowDidBecomeKey(_ notification: Notification) { report("INPUT 0 F 0 0") }
    func windowDidResignKey(_ notification: Notification) {
        if let view = (notification.object as? NSWindow)?.contentView as? MenuInputView {
            view.resetModifiers()
            view.cancelMove()
        }
        syntheticModifiers.removeAll()
        forward("L", 0, 0)
    }

    private var syntheticModifiers: Set<UInt16> = []
    func syntheticKey(code: UInt16, down: Bool) {
        guard let root = nodes[0]?.win, let view = root.contentView as? MenuInputView,
              root.firstResponder === view else { fail("missing menu first responder") }
        let modifier = MenuInputView.modifiers[code]
        if modifier != nil {
            if down { syntheticModifiers.insert(code) } else { syntheticModifiers.remove(code) }
        }
        let flags = syntheticModifiers.compactMap { MenuInputView.modifiers[$0] }
            .reduce(UInt(0)) { $0 | $1.flag.rawValue | $1.side }
        guard modifier != nil || MenuInputView.codes[code] != nil,
              let event = NSEvent.keyEvent(with: modifier != nil ? .flagsChanged : (down ? .keyDown : .keyUp), location: .zero,
                  modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: root.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                  isARepeat: false, keyCode: code) else { fail("invalid TREE_KEY code") }
        root.sendEvent(event)
    }
    func beginMove(_ id: Int) {
        (nodes[0]?.win.contentView as? MenuInputView)?.beginMove(id)
    }

    func syntheticBlur() {
        guard let root = nodes[0]?.win else { fail("missing root") }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: root)
    }
    struct Node {
        let win: NSWindow, parent: Int?, depth: Int, offset: NSPoint
        var pixels: Data
    }
    private var nodes: [Int: Node] = [:]

    // Check every live link against the same front-to-back WindowServer snapshot.
    private func verify() {
        CATransaction.flush()
        guard let top = NSScreen.screens.first?.frame.maxY,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { fail("missing tree window list") }
        for (sid, node) in nodes {
            let w = node.win
            guard w.isVisible, let i = list.firstIndex(where: { $0[kCGWindowNumber as String] as? Int == w.windowNumber }),
                  let bounds = list[i][kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { fail("missing tree window \(sid)") }
            guard let parent = node.parent else { continue }
            guard let p = nodes[parent]?.win, w.parent === p,
                  let pi = list.firstIndex(where: { $0[kCGWindowNumber as String] as? Int == p.windowNumber }), i < pi else { fail("incorrect tree stacking for \(sid)") }
            let content = p.contentRect(forFrameRect: p.frame)
            guard rect.minX == content.minX + node.offset.x, rect.minY == top - content.maxY + node.offset.y,
                  rect.size == w.contentView?.bounds.size else { fail("incorrect tree bounds for \(sid): \(rect)") }
        }
    }

    func submit(_ sid: Int, parent: Int?, x: Int, y: Int, w: Int, h: Int, data: Data) {
        guard nodes[sid] == nil else { fail("duplicate tree SID") }
        let size = NSSize(width: w, height: h)
        let image = makeImage(data, width: w, height: h)
        let view: MenuFrameView
        if input {
            let v = MenuInputView(image: image, size: size)
            v.pointer = { op, x, y in report("INPUT \(sid) \(op) \(x) \(y)") }
            if parent == nil { v.keyboard = { [weak self] in self?.forward($0, $1, $2) } }
            view = v
            targets.append(sid)
        } else { view = MenuFrameView(image: image, size: size) }
        let win: NSWindow, depth: Int
        if let parent {
            guard sid > 0, let p = nodes[parent] else { fail("invalid tree parent or SID") }
            let content = p.win.contentRect(forFrameRect: p.win.frame)
            let rect = NSRect(x: content.minX + CGFloat(x), y: content.maxY - CGFloat(y+h), width: size.width, height: size.height)
            let windowType: NSWindow.Type = input ? MenuInputPopup.self : NSWindow.self
            win = windowType.init(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.hasShadow = false
            win.colorSpace = .sRGB
            win.isOpaque = false
            win.backgroundColor = .clear
            win.contentView = view

            p.win.addChildWindow(win, ordered: .above)
            win.display()
            depth = p.depth + 1
        } else {
            win = openWindow(view, inputDelegate: input ? self : nil)
            if let inputView = view as? MenuInputView {
                // AppKit can consume Command chord releases before NSResponder.keyUp.
                keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak win, weak inputView] event in
                    guard let win, let inputView, win.isKeyWindow, win.firstResponder === inputView,
                          event.window == nil || event.window === win,
                          MenuInputView.codes[event.keyCode] != nil else { return event }
                    inputView.keyUp(with: event)
                    return nil
                }
            }
            depth = 0
        }
        win.acceptsMouseMovedEvents = true
        guard view.bounds.size == size else { fail("incorrect tree content size") }
        nodes[sid] = Node(win: win, parent: parent, depth: depth, offset: NSPoint(x: x, y: y), pixels: data)
        verify()
        report(parent == nil ? "PARENT_OK" : "TREE_POPUP_OK \(sid)")
    }

    func update(_ sid: Int, w: Int, h: Int, data: Data) {
        guard let node = nodes[sid], let view = node.win.contentView as? MenuInputView,
              view.bounds.size == NSSize(width: w, height: h) else { fail("invalid TREE_FRAME geometry") }
        // Keep the same view so repainting does not disturb AppKit first responder.
        view.image = makeImage(data, width: w, height: h)
        nodes[sid]?.pixels = data
        view.needsDisplay = true
        view.displayIfNeeded()
        CATransaction.flush()
        report("TREE_FRAME_OK \(sid)")
    }

    func click(_ sid: Int, action: String, x: Int, y: Int) {
        verify()
        guard let node = nodes[sid], let view = node.win.contentView as? MenuFrameView else { fail("unknown TREE_CLICK target") }
        let point = NSPoint(x: CGFloat(x)+0.5, y: CGFloat(y)+0.5)
        guard view.bounds.contains(point), sid == 0 || node.pixels[(y*Int(view.bounds.width)+x)*4+3] != 0 else { fail("TREE_CLICK outside visible content") }
        let events: [NSEvent.EventType]
        if action == "MOVE" { events = [.mouseMoved] }
        else if let button = MenuButton(rawValue: action) { events = button.events }
        else { fail("invalid TREE_CLICK action") }
        view.send(events, at: point, in: node.win)
        report("TREE_CLICK_OK \(sid) \(action) \(x) \(y)")
    }

    // nil selects every popup for EOF cleanup. Sort by depth even across siblings.
    func close(_ sid: Int?) {
        if let sid, sid <= 0 || nodes[sid] == nil { fail("unknown TREE_CLOSE target or root") }
        let ordered = nodes.keys.filter { id in
            guard id != 0 else { return false }
            guard let sid else { return true }
            var cursor: Int? = id
            while let current = cursor {
                if current == sid { return true }
                cursor = nodes[current]?.parent
            }
            return false
        }.sorted { (-nodes[$0]!.depth, $0) < (-nodes[$1]!.depth, $1) }
        for id in ordered {
            let w = nodes[id]!.win, number = w.windowNumber
            w.parent?.removeChildWindow(w)
            w.close()
            guard w.parent == nil, !w.isVisible, !onScreen(number) else { fail("failed to close tree window \(id)") }
            w.contentView = nil
            targets.removeAll { $0 == id }
            nodes.removeValue(forKey: id)
            verify()
        }
        if let sid {
            let closed = ordered.map(String.init).joined(separator: ",")
            let alive = nodes.keys.sorted().map(String.init).joined(separator: ",")
            report("TREE_CLOSE_OK \(sid) closed=\(closed) alive=\(alive)")
        }
    }
}

private func receiveMenuTree(input: Bool = false) {
    let host = MenuTree(input: input)
    while let f = popupHeader() {
        func number(_ i: Int, _ range: ClosedRange<Int>) -> Int {
            guard let v = Int(f[i]), range.contains(v) else { fail("invalid tree argument \(f[i])") }
            return v
        }
        switch (f.first, f.count) {
        case ("PARENT", 3), ("TREE_POPUP", 7):
            let root = f.first == "PARENT", w = number(f.count-2, 1...2048), h = number(f.count-1, 1...2048)
            let sid = root ? 0 : number(1, 1...Int.max), parent = root ? nil : number(2, 0...Int.max)
            let x = root ? 0 : number(3, -8192...8192), y = root ? 0 : number(4, -8192...8192)
            guard let data = readFrame(width: w, height: h, opaque: false) else { fail("missing tree frame") }
            DispatchQueue.main.sync { autoreleasepool { host.submit(sid, parent: parent, x: x, y: y, w: w, h: h, data: data) } }
        case ("TREE_FRAME", 4) where input:
            let sid = number(1, 0...Int.max), w = number(2, 1...2048), h = number(3, 1...2048)
            guard let data = readFrame(width: w, height: h, opaque: false) else { fail("missing tree repaint") }
            DispatchQueue.main.sync { autoreleasepool { host.update(sid, w: w, h: h, data: data) } }
        case ("TREE_CLICK", 5):
            let sid = number(1, 0...Int.max), x = number(3, 0...2047), y = number(4, 0...2047)
            DispatchQueue.main.sync { host.click(sid, action: String(f[2]), x: x, y: y) }
        case ("TREE_KEY", 3) where input:
            let code = UInt16(number(1, 0...65535)), down = number(2, 0...1)
            DispatchQueue.main.sync { host.syntheticKey(code: code, down: down == 1); report("TREE_KEY_OK \(code) \(down)") }
        case ("TREE_BEGIN_MOVE", 2) where input:
            let id = number(1, 1...Int(Int32.max))
            DispatchQueue.main.sync { host.beginMove(id); report("TREE_BEGIN_MOVE_OK \(id)") }
        case ("TREE_BLUR", 1) where input:
            DispatchQueue.main.sync { host.syntheticBlur(); report("TREE_BLUR_OK") }
        case ("TREE_CLOSE", 2):
            let sid = number(1, 1...Int.max)
            DispatchQueue.main.sync { host.close(sid) }
        default: fail("unknown tree command or wrong argument count")
        }
    }
    DispatchQueue.main.sync {
        host.stopMonitoringKeyUp()
        host.close(nil)
        if window != nil { cleanup() }
        report("CLEANUP_OK")
        exit(0)
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
case ["--weston"], ["--popup-host"], ["--menu-host"], ["--menu-tree-host"], ["--menu-input-host"]: streamSize = nil
case [], ["--retina"]: streamSize = nil
default: fail("unexpected window mode")
}
DispatchQueue.global().async {
    if CommandLine.arguments.last == "--popup-host" { receivePopup(menu: false) }
    else if CommandLine.arguments.last == "--menu-host" { receivePopup(menu: true) }
    else if CommandLine.arguments.last == "--menu-input-host" { receiveMenuTree(input: true) }
    else if CommandLine.arguments.last == "--menu-tree-host" { receiveMenuTree() }
    else { receive(streamSize: streamSize, xdg: xdg) }
}
app.run()
