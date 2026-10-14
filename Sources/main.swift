// SnipMac — a Snipaste-style screenshot + pin tool for macOS.
// F1 / ⌃⌥A : capture   F3 / ⌃⌥P : pin clipboard

import Cocoa
import ScreenCaptureKit
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers
import CoreImage
import Vision

func debugLog(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SnipMac.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

let accent = NSColor(red: 0.0, green: 0.6, blue: 1.0, alpha: 1)

// MARK: - Global hotkeys (Carbon, no Accessibility permission needed)

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    func register(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x534E_4950), id: id)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

// MARK: - Image helpers

enum ImageOut {
    static func pngData(_ cg: CGImage, size: CGSize) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }

    static func copy(_ cg: CGImage, size: CGSize) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let img = NSImage(cgImage: cg, size: size)
        pb.declareTypes([.png, .tiff], owner: nil)
        if let png = pngData(cg, size: size) { pb.setData(png, forType: .png) }
        if let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    static func save(_ cg: CGImage, size: CGSize) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        panel.nameFieldStringValue = "SnipMac_\(f.string(from: Date())).png"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        let ext = url.pathExtension.lowercased()
        let data = (ext == "jpg" || ext == "jpeg")
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            : rep.representation(using: .png, properties: [:])
        try? data?.write(to: url)
    }
}

// MARK: - Screen capture

enum Capture {
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func image(of screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = displayID(screen)
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw NSError(domain: "SnipMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display not found"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// On-screen window rects (front to back) in the screen's local, bottom-left-origin coordinates.
    static func windowRects(for screen: NSScreen) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let local = CGRect(origin: .zero, size: screen.frame.size)
        var out: [CGRect] = []
        for w in list {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard layer >= 0, layer < 1000, alpha > 0.01, owner != "Window Server",
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd),
                  r.width > 16, r.height > 12 else { continue }
            let cocoa = CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
            let lr = cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).intersection(local)
            guard !lr.isNull, lr.width > 16, lr.height > 12 else { continue }
            if layer != 0 && lr.size == local.size { continue }
            out.append(lr)
        }
        return out
    }
}

// MARK: - Annotations

enum Tool: Int { case none, rect, ellipse, arrow, pen, marker, mosaic, text }

final class Annotation {
    let tool: Tool
    let color: NSColor
    let width: CGFloat
    var points: [CGPoint]
    var text = ""
    var fontSize: CGFloat = 18

    init(tool: Tool, color: NSColor, width: CGFloat, points: [CGPoint]) {
        self.tool = tool; self.color = color; self.width = width; self.points = points
    }

    var cgPath: CGPath {
        let p = CGMutablePath()
        guard let f = points.first else { return p }
        p.move(to: f)
        if points.count == 1 { p.addLine(to: f) } else { p.addLines(between: points) }
        return p
    }

    func draw(in ctx: CGContext, pixelated: CGImage?, canvas: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)
        let p0 = points.first ?? .zero, p1 = points.last ?? .zero
        let r = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
        switch tool {
        case .rect:
            ctx.setLineJoin(.miter)
            ctx.stroke(r)
        case .ellipse:
            ctx.strokeEllipse(in: r)
        case .arrow:
            let len = hypot(p1.x - p0.x, p1.y - p0.y)
            guard len > 1 else { return }
            let a = atan2(p1.y - p0.y, p1.x - p0.x)
            let head = min(max(14, width * 4.5), len)
            let half = head * 0.45
            let base = CGPoint(x: p1.x - head * cos(a), y: p1.y - head * sin(a))
            ctx.move(to: p0); ctx.addLine(to: base); ctx.strokePath()
            ctx.move(to: p1)
            ctx.addLine(to: CGPoint(x: base.x + half * sin(a), y: base.y - half * cos(a)))
            ctx.addLine(to: CGPoint(x: base.x - half * sin(a), y: base.y + half * cos(a)))
            ctx.closePath(); ctx.fillPath()
        case .pen:
            ctx.addPath(cgPath); ctx.strokePath()
        case .marker:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
            ctx.setLineCap(.square)
            ctx.addPath(cgPath); ctx.strokePath()
        case .mosaic:
            guard let pix = pixelated else { return }
            ctx.addPath(cgPath)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.draw(pix, in: canvas)
        case .text:
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: color,
            ]).draw(at: p0)
            NSGraphicsContext.restoreGraphicsState()
        case .none: break
        }
    }
}

// MARK: - Toolbar

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    var tipText = ""
    var onHover: ((ActionButton, Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseEntered(with e: NSEvent) { onHover?(self, true) }
    override func mouseExited(with e: NSEvent) { onHover?(self, false) }

    convenience init(symbol: String?, tip: String, size: CGSize = CGSize(width: 30, height: 28), handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        }
        imagePosition = .imageOnly
        isBordered = false
        tipText = tip
        target = self
        action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 4
        contentTintColor = NSColor(white: 0.2, alpha: 1)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    @objc private func fire() { handler?() }

    var selectedLook = false {
        didSet {
            layer?.backgroundColor = selectedLook ? accent.withAlphaComponent(0.18).cgColor : nil
            contentTintColor = selectedLook ? accent : NSColor(white: 0.2, alpha: 1)
        }
    }
}

final class Toolbar: NSView {
    weak var owner: SelectionView?
    private var toolButtons: [(Tool, ActionButton)] = []
    private var colorButtons: [(NSColor, ActionButton)] = []
    private var sizeButtons: [ActionButton] = []
    private let styleRow = NSStackView()
    private let stack = NSStackView()
    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]
    static let colorNames = ["red", "orange", "yellow", "green", "blue", "purple", "white", "black"]

    private lazy var tipLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .white
        l.drawsBackground = true
        l.backgroundColor = NSColor(white: 0.12, alpha: 0.92)
        l.wantsLayer = true
        l.layer?.cornerRadius = 4
        l.layer?.masksToBounds = true
        l.isHidden = true
        return l
    }()

    private func showTip(_ b: ActionButton, _ inside: Bool) {
        guard let host = superview else { return }
        if tipLabel.superview == nil { host.addSubview(tipLabel) }
        guard inside, !isHidden else { tipLabel.isHidden = true; return }
        tipLabel.stringValue = "  " + b.tipText + "  "
        tipLabel.sizeToFit()
        let sz = CGSize(width: tipLabel.frame.width, height: tipLabel.frame.height + 4)
        let r = b.convert(b.bounds, to: host)
        let x = min(max(0, r.midX - sz.width / 2), host.bounds.width - sz.width)
        var y = frame.maxY + 4
        if y + sz.height > host.bounds.maxY { y = frame.minY - sz.height - 4 }
        tipLabel.frame = CGRect(origin: CGPoint(x: x, y: y), size: sz)
        tipLabel.isHidden = false
    }

    func hideTip() { tipLabel.isHidden = true }

    override var isHidden: Bool { didSet { if isHidden { hideTip() } } }

    private func allButtons(in v: NSView) -> [ActionButton] {
        v.subviews.flatMap { ($0 as? ActionButton).map { [$0] } ?? allButtons(in: $0) }
    }

    init(owner: SelectionView) {
        self.owner = owner
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor(white: 0, alpha: 0.18).cgColor
        layer?.borderWidth = 0.5

        let main = NSStackView()
        main.spacing = 2
        let tools: [(Tool, String, String)] = [
            (.rect, "rectangle", "Rectangle (R) — draw a box"), (.ellipse, "circle", "Ellipse (E) — draw a circle / oval"), (.arrow, "arrow.up.right", "Arrow (A) — point at something"),
            (.pen, "scribble", "Pen (P) — freehand drawing"), (.marker, "highlighter", "Highlighter (M) — translucent marker"),
            (.mosaic, "checkerboard.rectangle", "Mosaic (B) — pixelate private info"), (.text, "textformat", "Text (T) — type text on the image"),
        ]
        for (t, s, tip) in tools {
            let b = ActionButton(symbol: s, tip: tip) { [weak owner] in owner?.toggleTool(t) }
            main.addArrangedSubview(b)
            toolButtons.append((t, b))
        }
        main.addArrangedSubview(Self.separator())
        main.addArrangedSubview(ActionButton(symbol: "arrow.uturn.backward", tip: "Undo (⌘Z) — remove last drawing") { [weak owner] in owner?.undo() })
        main.addArrangedSubview(Self.separator())
        main.addArrangedSubview(ActionButton(symbol: "text.viewfinder", tip: "OCR (O) — recognize text and copy it") { [weak owner] in owner?.controller?.finish(.ocr) })
        main.addArrangedSubview(ActionButton(symbol: "arrow.up.and.down.square", tip: "Scrolling capture (L) — scroll to capture a long page") { [weak owner] in owner?.controller?.finish(.scroll) })
        main.addArrangedSubview(ActionButton(symbol: "pin", tip: "Pin (F3) — float this screenshot on top of the screen") { [weak owner] in owner?.controller?.finish(.pin) })
        main.addArrangedSubview(ActionButton(symbol: "square.and.arrow.down", tip: "Save (⌘S) — save as PNG / JPG") { [weak owner] in owner?.controller?.finish(.save) })
        main.addArrangedSubview(ActionButton(symbol: "xmark", tip: "Cancel (Esc) — exit without saving") { [weak owner] in owner?.controller?.cancel() })
        let ok = ActionButton(symbol: "checkmark", tip: "Copy (F1 / Enter) — copy to clipboard and finish") { [weak owner] in owner?.controller?.finish(.copy) }
        ok.contentTintColor = accent
        main.addArrangedSubview(ok)

        styleRow.spacing = 2
        for i in 0..<3 {
            let b = ActionButton(symbol: nil, tip: ["Size: thin (1)", "Size: medium (2)", "Size: thick (3)"][i], size: CGSize(width: 24, height: 24)) { [weak owner] in
                owner?.strokeSize = i; owner?.toolbar.refresh()
            }
            styleRow.addArrangedSubview(b)
            sizeButtons.append(b)
        }
        styleRow.addArrangedSubview(Self.separator(height: 16))
        for c in Self.colors {
            let b = ActionButton(symbol: nil, tip: "Color: " + Self.colorNames[Self.colors.firstIndex(of: c)!], size: CGSize(width: 24, height: 24)) { [weak owner] in
                owner?.color = c; owner?.toolbar.refresh()
            }
            styleRow.addArrangedSubview(b)
            colorButtons.append((c, b))
        }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        stack.addArrangedSubview(main)
        stack.addArrangedSubview(styleRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for b in allButtons(in: stack) { b.onHover = { [weak self] b, inside in self?.showTip(b, inside) } }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.topAnchor.constraint(equalTo: topAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func separator(height: CGFloat = 20) -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    func refresh() {
        guard let o = owner else { return }
        for (t, b) in toolButtons { b.selectedLook = (t == o.tool) }
        styleRow.isHidden = (o.tool == .none)
        for (c, b) in colorButtons { b.image = Self.swatch(c, selected: c == o.color) }
        for (i, b) in sizeButtons.enumerated() { b.image = Self.dot(CGFloat([4, 7, 11][i]), selected: i == o.strokeSize) }
        stack.layoutSubtreeIfNeeded()
        setFrameSize(stack.fittingSize)
    }

    static func swatch(_ c: NSColor, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            if selected {
                accent.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)); ring.lineWidth = 2; ring.stroke()
            }
            c.setFill()
            let dot = NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: 4)); dot.fill()
            NSColor(white: 0, alpha: 0.25).setStroke(); dot.lineWidth = 0.5; dot.stroke()
            return true
        }
    }

    static func dot(_ d: CGFloat, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            (selected ? accent : NSColor(white: 0.35, alpha: 1)).setFill()
            NSBezierPath(ovalIn: CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
            return true
        }
    }
}

// MARK: - Selection / annotation overlay view

final class SelectionView: NSView, NSTextFieldDelegate {
    let baseImage: CGImage
    let scale: CGFloat
    let windowRects: [CGRect]
    weak var controller: CaptureController?
    private lazy var bitmap = NSBitmapImageRep(cgImage: baseImage)
    private lazy var pixelated: CGImage? = makePixelated()

    var selection: CGRect?
    var hoverRect: CGRect?
    var mouse: CGPoint = .zero
    var annotations: [Annotation] = []
    var tool: Tool = .none { didSet { finishText(); toolbar.refresh(); layoutToolbar() } }
    var color: NSColor = .systemRed
    var strokeSize = 1

    private enum Drag { case none, creating(CGPoint), moving(CGRect, CGPoint), resizing(Int, CGRect, CGPoint), drawing(Annotation) }
    private var drag: Drag = .none
    private var editingField: NSTextField?
    lazy var toolbar = Toolbar(owner: self)

    init(frame: CGRect, image: CGImage, scale: CGFloat, windowRects: [CGRect]) {
        self.baseImage = image
        self.scale = scale
        self.windowRects = windowRects
        super.init(frame: frame)
        addSubview(toolbar)
        toolbar.isHidden = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func makePixelated() -> CGImage? {
        let ci = CIImage(cgImage: baseImage)
        guard let f = CIFilter(name: "CIPixellate") else { return nil }
        f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(10 * scale, forKey: kCIInputScaleKey)
        f.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let out = f.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }

    var widths: [CGFloat] {
        switch tool {
        case .marker: return [10, 16, 26]
        case .mosaic: return [14, 24, 40]
        default: return [2, 4, 7]
        }
    }

    // MARK: Actions

    func hotkeyCopy() {
        if selection == nil { selection = hoverRect ?? bounds }
        controller?.finish(.copy)
    }

    func toggleTool(_ t: Tool) { tool = (tool == t) ? .none : t }

    func undo() {
        if editingField != nil { cancelText(); return }
        if !annotations.isEmpty { annotations.removeLast(); needsDisplay = true }
    }

    func update(hoverAt p: CGPoint) {
        mouse = p
        if selection == nil {
            hoverRect = windowRects.first(where: { $0.contains(p) }) ?? bounds
        }
    }

    // MARK: Text editing

    private func beginText(at p: CGPoint) {
        let fs: CGFloat = [16, 22, 32][strokeSize]
        let h = ceil(fs * 1.35)
        let f = NSTextField(frame: CGRect(x: p.x, y: p.y - h / 2, width: max(60, (selection?.maxX ?? bounds.maxX) - p.x), height: h))
        f.isBordered = false
        f.drawsBackground = false
        f.font = .systemFont(ofSize: fs, weight: .medium)
        f.textColor = color
        f.focusRingType = .none
        f.delegate = self
        f.wantsLayer = true
        f.layer?.borderColor = NSColor(white: 1, alpha: 0.7).cgColor
        f.layer?.borderWidth = 1
        f.cell?.isScrollable = true
        addSubview(f)
        window?.makeFirstResponder(f)
        editingField = f
    }

    func finishText() {
        guard let f = editingField else { return }
        editingField = nil
        let s = f.stringValue
        if !s.isEmpty, let font = f.font {
            let sz = NSAttributedString(string: s, attributes: [.font: font]).size()
            let a = Annotation(tool: .text, color: f.textColor ?? color, width: 0,
                               points: [CGPoint(x: f.frame.minX + 2, y: f.frame.midY - sz.height / 2)])
            a.text = s
            a.fontSize = font.pointSize
            annotations.append(a)
        }
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func cancelText() {
        editingField?.stringValue = ""
        finishText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) || sel == #selector(NSResponder.insertNewline(_:)) {
            finishText()
            return true
        }
        return false
    }

    // MARK: Geometry

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func handle(at p: CGPoint) -> Int? {
        guard let s = selection else { return nil }
        return handlePoints(s).firstIndex { hypot($0.x - p.x, $0.y - p.y) < 8 }
    }

    private func resized(_ r: CGRect, handle h: Int, dx: CGFloat, dy: CGFloat) -> CGRect {
        var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        if [0, 6, 7].contains(h) { x0 += dx }
        if [2, 3, 4].contains(h) { x1 += dx }
        if [0, 1, 2].contains(h) { y0 += dy }
        if [4, 5, 6].contains(h) { y1 += dy }
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)).intersection(bounds)
    }

    private func clampMove(_ r: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
        r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
        return r
    }

    func layoutToolbar() {
        guard let s = selection, !toolbar.isHidden else { return }
        let tb = toolbar.frame.size
        let x = min(max(0, s.maxX - tb.width), bounds.width - tb.width)
        var y = s.minY - tb.height - 6
        if y < 0 { y = s.maxY + 6 }
        if y + tb.height > bounds.height { y = s.minY + 6 }
        toolbar.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func showToolbar() {
        toolbar.isHidden = false
        toolbar.refresh()
        layoutToolbar()
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if editingField != nil { finishText(); if tool == .text { return } }
        guard let sel = selection else { drag = .creating(p); return }

        if e.clickCount == 2 && sel.contains(p) && tool == .none { controller?.finish(.copy); return }
        if let h = handle(at: p) { drag = .resizing(h, sel, p); toolbar.isHidden = true; return }
        if tool != .none {
            guard sel.contains(p) else { return }
            if tool == .text { beginText(at: p); return }
            let w = widths[strokeSize]
            let pts = [.rect, .ellipse, .arrow].contains(tool) ? [p, p] : [p]
            let a = Annotation(tool: tool, color: color, width: w, points: pts)
            annotations.append(a)
            drag = .drawing(a)
            needsDisplay = true
            return
        }
        if sel.contains(p) { drag = .moving(sel, p) }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        mouse = p
        switch drag {
        case .creating(let s):
            if hypot(p.x - s.x, p.y - s.y) > 3 {
                selection = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
                    .intersection(bounds)
                hoverRect = nil
            }
        case .moving(let r, let s):
            selection = clampMove(r.offsetBy(dx: p.x - s.x, dy: p.y - s.y))
            layoutToolbar()
        case .resizing(let h, let r, let s):
            selection = resized(r, handle: h, dx: p.x - s.x, dy: p.y - s.y)
        case .drawing(let a):
            var q = p
            if e.modifierFlags.contains(.shift), let f = a.points.first {
                if a.tool == .rect || a.tool == .ellipse {
                    let d = max(abs(p.x - f.x), abs(p.y - f.y))
                    q = CGPoint(x: f.x + (p.x >= f.x ? d : -d), y: f.y + (p.y >= f.y ? d : -d))
                } else if a.tool == .marker || a.tool == .arrow {
                    q = abs(p.x - f.x) > abs(p.y - f.y) ? CGPoint(x: p.x, y: f.y) : CGPoint(x: f.x, y: p.y)
                }
            }
            if a.points.count == 2 && [.rect, .ellipse, .arrow].contains(a.tool) {
                a.points[1] = q
            } else if a.tool == .marker && e.modifierFlags.contains(.shift) {
                a.points = [a.points[0], q]
            } else {
                a.points.append(q)
            }
        case .none: break
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        switch drag {
        case .creating:
            if selection == nil || selection!.width < 4 || selection!.height < 4 {
                selection = hoverRect ?? bounds
            }
            hoverRect = nil
            showToolbar()
        case .resizing:
            if let s = selection, s.width < 2 || s.height < 2 { selection = nil; update(hoverAt: mouse) } else { showToolbar() }
        case .drawing(let a):
            if [.rect, .ellipse, .arrow].contains(a.tool), let f = a.points.first, let l = a.points.last,
               hypot(l.x - f.x, l.y - f.y) < 2 {
                annotations.removeAll { $0 === a }
            }
        default: break
        }
        drag = .none
        needsDisplay = true
    }

    override func rightMouseDown(with e: NSEvent) {
        if editingField != nil { cancelText() }
        if selection != nil {
            selection = nil
            annotations.removeAll()
            tool = .none
            toolbar.isHidden = true
            update(hoverAt: convert(e.locationInWindow, from: nil))
            needsDisplay = true
        } else {
            controller?.cancel()
        }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        update(hoverAt: p)
        if !toolbar.isHidden && toolbar.frame.contains(p) {
            NSCursor.arrow.set()
        } else if let s = selection {
            if handle(at: p) != nil { NSCursor.crosshair.set() }
            else if tool == .text && s.contains(p) { NSCursor.iBeam.set() }
            else if tool == .none && s.contains(p) { NSCursor.openHand.set() }
            else { NSCursor.crosshair.set() }
        } else {
            NSCursor.crosshair.set()
        }
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch Int(e.keyCode) {
        case kVK_Escape: controller?.cancel(); return
        case kVK_Return, kVK_ANSI_KeypadEnter: if selection != nil { controller?.finish(.copy) }; return
        case kVK_F3: if selection != nil { controller?.finish(.pin) }; return
        case kVK_F1:
            if selection == nil { selection = hoverRect ?? bounds }
            controller?.finish(.copy); return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1 / scale
            let d: CGPoint = [kVK_LeftArrow: CGPoint(x: -step, y: 0), kVK_RightArrow: CGPoint(x: step, y: 0),
                              kVK_UpArrow: CGPoint(x: 0, y: step), kVK_DownArrow: CGPoint(x: 0, y: -step)][Int(e.keyCode)]!
            if let s = selection {
                selection = clampMove(s.offsetBy(dx: d.x, dy: d.y)); layoutToolbar()
            } else {
                // nudge the mouse for pixel-precise picking
                let g = CGPoint(x: (window?.frame.minX ?? 0) + mouse.x + d.x,
                                y: (NSScreen.screens.first?.frame.height ?? 0) - ((window?.frame.minY ?? 0) + mouse.y + d.y))
                CGWarpMouseCursorPosition(g)
                update(hoverAt: CGPoint(x: mouse.x + d.x, y: mouse.y + d.y))
            }
            needsDisplay = true
            return
        default: break
        }
        if cmd {
            switch ch {
            case "c": if selection != nil { controller?.finish(.copy) }
            case "s": if selection != nil { controller?.finish(.save) }
            case "t": if selection != nil { controller?.finish(.pin) }
            case "z": undo()
            case "a": selection = bounds; hoverRect = nil; showToolbar(); needsDisplay = true
            default: break
            }
            return
        }
        if selection == nil {
            if ch == "c" { copyColor() }
            return
        }
        if ch == "o" { controller?.finish(.ocr); return }
        if ch == "l" { controller?.finish(.scroll); return }
        let map: [String: Tool] = ["r": .rect, "e": .ellipse, "a": .arrow, "p": .pen, "m": .marker, "b": .mosaic, "t": .text]
        if let t = map[ch] { toggleTool(t) }
        if ch == "1" || ch == "2" || ch == "3" { strokeSize = Int(ch)! - 1; toolbar.refresh() }
    }

    private func pixelColor(at p: CGPoint) -> NSColor? {
        let x = min(max(0, Int(p.x * scale)), bitmap.pixelsWide - 1)
        let y = min(max(0, Int((bounds.height - p.y) * scale)), bitmap.pixelsHigh - 1)
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private func copyColor() {
        guard let c = pixelColor(at: mouse) else { return }
        let hex = String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                         Int(round(c.blueComponent * 255)))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        controller?.cancel()
    }

    // MARK: Rendering

    func render() -> (CGImage, CGRect)? {
        guard let sel0 = selection else { return nil }
        let px = CGRect(x: round(sel0.minX * scale), y: round(sel0.minY * scale),
                        width: round(sel0.width * scale), height: round(sel0.height * scale))
        guard px.width >= 1, px.height >= 1 else { return nil }
        let sel = CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale)
        let cs = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        ctx.interpolationQuality = .none
        ctx.draw(baseImage, in: bounds)
        ctx.interpolationQuality = .high
        for a in annotations { a.draw(in: ctx, pixelated: pixelated, canvas: bounds) }
        guard let img = ctx.makeImage() else { return nil }
        return (img, sel)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.draw(baseImage, in: bounds)
        ctx.interpolationQuality = .high

        let focus = selection ?? hoverRect
        ctx.saveGState()
        ctx.setFillColor(NSColor(white: 0, alpha: 0.4).cgColor)
        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let f = focus { dim.addRect(f) }
        ctx.addPath(dim)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        if let sel = selection {
            ctx.saveGState()
            ctx.clip(to: sel)
            for a in annotations { a.draw(in: ctx, pixelated: pixelated, canvas: bounds) }
            ctx.restoreGState()

            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(sel.insetBy(dx: -0.5, dy: -0.5))
            for hp in handlePoints(sel) {
                let r = CGRect(x: hp.x - 3, y: hp.y - 3, width: 6, height: 6)
                ctx.setFillColor(accent.cgColor); ctx.fill(r)
                ctx.setStrokeColor(NSColor.white.cgColor); ctx.stroke(r)
            }
            drawSizeLabel(sel)
        } else if let h = hoverRect {
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(h.insetBy(dx: 1.5, dy: 1.5))
        }

        var magnify = selection == nil
        switch drag {
        case .creating, .resizing: magnify = true
        default: break
        }
        if magnify { drawMagnifier(ctx) }
    }

    private func drawSizeLabel(_ sel: CGRect) {
        let s = NSAttributedString(string: "\(Int(round(sel.width * scale))) × \(Int(round(sel.height * scale)))",
                                   attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                .foregroundColor: NSColor.white])
        let sz = s.size()
        var r = CGRect(x: sel.minX, y: sel.maxY + 4, width: sz.width + 10, height: sz.height + 4)
        if r.maxY > bounds.maxY { r.origin.y = sel.maxY - r.height - 4; r.origin.x += 4 }
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        s.draw(at: CGPoint(x: r.minX + 5, y: r.minY + 2))
    }

    private func drawMagnifier(_ ctx: CGContext) {
        let n = 15, cell: CGFloat = 8
        let box = CGFloat(n) * cell, infoH: CGFloat = 50
        let W = baseImage.width, H = baseImage.height
        let cx = min(max(0, Int(mouse.x * scale)), W - 1)
        let cy = min(max(0, Int((bounds.height - mouse.y) * scale)), H - 1)
        let sx = min(max(0, cx - n / 2), W - n), sy = min(max(0, cy - n / 2), H - n)
        guard let crop = baseImage.cropping(to: CGRect(x: sx, y: sy, width: n, height: n)) else { return }

        var o = CGPoint(x: mouse.x + 20, y: mouse.y - 20 - box - infoH)
        if o.x + box > bounds.maxX { o.x = mouse.x - 20 - box }
        if o.y < 0 { o.y = mouse.y + 20 }
        let boxRect = CGRect(x: o.x, y: o.y + infoH, width: box, height: box)

        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: boxRect)
        // crosshair on the cursor pixel
        let col = CGFloat(cx - sx), row = CGFloat(cy - sy)
        ctx.setFillColor(accent.withAlphaComponent(0.3).cgColor)
        ctx.fill(CGRect(x: boxRect.minX, y: boxRect.maxY - (row + 1) * cell, width: box, height: cell))
        ctx.fill(CGRect(x: boxRect.minX + col * cell, y: boxRect.minY, width: cell, height: box))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: boxRect.minX + col * cell, y: boxRect.maxY - (row + 1) * cell, width: cell, height: cell))
        ctx.stroke(boxRect)
        ctx.restoreGState()

        let info = CGRect(x: o.x, y: o.y, width: box, height: infoH)
        NSColor(white: 0, alpha: 0.8).setFill()
        NSBezierPath(rect: info).fill()
        var lines = ["(\(cx), \(cy))"]
        if let c = pixelColor(at: mouse) {
            let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
            lines.append(String(format: "RGB %d,%d,%d  #%02X%02X%02X", r, g, b, r, g, b))
        }
        lines.append("C copy color · Right-click/Esc quit")
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor.white]
        for (i, l) in lines.enumerated() {
            NSAttributedString(string: l, attributes: attrs).draw(at: CGPoint(x: info.minX + 5, y: info.maxY - 15 - CGFloat(i) * 14))
        }
    }
}

// MARK: - Capture session

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class CaptureController {
    enum Finish { case copy, save, pin, ocr, scroll }
    static var current: CaptureController?
    private static var starting = false

    let screen: NSScreen
    let window: OverlayWindow
    let view: SelectionView
    let previousApp: NSRunningApplication?

    static func start() {
        debugLog("capture requested (current=\(current != nil), starting=\(starting), preflight=\(CGPreflightScreenCaptureAccess()))")
        if let c = current { c.view.hotkeyCopy(); return }
        guard !starting, ScrollCaptureController.current == nil else { return }
        starting = true
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main!
        let prev = NSWorkspace.shared.frontmostApplication
        let rects = Capture.windowRects(for: screen)
        Task { @MainActor in
            defer { starting = false }
            do {
                let img = try await Capture.image(of: screen)
                let c = CaptureController(screen: screen, image: img, rects: rects, previousApp: prev)
                current = c
                c.show()
                debugLog("overlay shown \(img.width)x\(img.height)")
            } catch {
                debugLog("capture failed: \(error)")
                AppDelegate.showPermissionAlert(error)
            }
        }
    }

    init(screen: NSScreen, image: CGImage, rects: [CGRect], previousApp: NSRunningApplication?) {
        self.screen = screen
        self.previousApp = previousApp
        window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image,
                             scale: CGFloat(image.width) / screen.frame.width, windowRects: rects)
        view.controller = self
        window.contentView = view
    }

    func show() {
        let m = NSEvent.mouseLocation
        view.update(hoverAt: CGPoint(x: m.x - screen.frame.minX, y: m.y - screen.frame.minY))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSCursor.crosshair.set()
    }

    func cancel() {
        close()
        previousApp?.activate()
    }

    private func close() {
        window.orderOut(nil)
        NSCursor.arrow.set()
        CaptureController.current = nil
    }

    func finish(_ action: Finish) {
        view.finishText()
        if action == .scroll {
            guard let sel = view.selection, sel.width >= 20, sel.height >= 20 else { NSSound.beep(); return }
            close()
            previousApp?.activate()
            let sc = ScrollCaptureController(screen: screen, region: sel, scale: view.scale)
            ScrollCaptureController.current = sc
            sc.start()
            return
        }
        guard let (img, sel) = view.render() else { return }
        close()
        switch action {
        case .copy:
            ImageOut.copy(img, size: sel.size)
            previousApp?.activate()
        case .save:
            ImageOut.copy(img, size: sel.size)
            ImageOut.save(img, size: sel.size)
            previousApp?.activate()
        case .pin:
            ImageOut.copy(img, size: sel.size)
            PinManager.shared.pin(img, frame: sel.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
            previousApp?.activate()
        case .ocr:
            OCRWindow.show(img)
        case .scroll: break
        }
    }
}

// MARK: - Pinned images

final class PinManager {
    static let shared = PinManager()
    var pins: [PinWindow] = []

    func pin(_ img: CGImage, frame: CGRect) {
        let w = PinWindow(image: img, frame: frame)
        pins.append(w)
        w.orderFrontRegardless()
        w.makeKey()
    }

    func remove(_ w: PinWindow) { pins.removeAll { $0 === w } }

    func closeAll() { for p in pins { p.close() } }

    func pinClipboard() {
        if let c = CaptureController.current {
            if c.view.selection != nil { c.finish(.pin) }
            return
        }
        let pb = NSPasteboard.general
        var cg: CGImage?
        var size = CGSize.zero
        if let img = NSImage(pasteboard: pb), let c = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cg = c
            size = img.size
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            (cg, size) = renderText(s)
        }
        guard let img = cg else { NSSound.beep(); return }
        let m = NSEvent.mouseLocation
        pin(img, frame: CGRect(x: m.x - size.width / 2, y: m.y - size.height / 2, width: size.width, height: size.height))
    }

    private func renderText(_ s: String) -> (CGImage?, CGSize) {
        let text = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 14),
                                                               .foregroundColor: NSColor.black])
        let bound = text.boundingRect(with: CGSize(width: 600, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: ceil(bound.width) + 20, height: ceil(min(bound.height, 4000)) + 20)
        let sc: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width * sc), height: Int(size.height * sc), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, .zero) }
        ctx.scaleBy(x: sc, y: sc)
        ctx.setFillColor(NSColor(white: 0.99, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(with: CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return (ctx.makeImage(), size)
    }
}

final class PinWindow: NSPanel {
    let image: CGImage
    let baseSize: CGSize
    var zoom: CGFloat = 1

    init(image: CGImage, frame: CGRect) {
        self.image = image
        self.baseSize = frame.size
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinView(frame: CGRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        PinManager.shared.remove(self)
    }

    func setZoom(_ z: CGFloat, anchor: CGPoint) {
        let nz = min(max(z, 0.1), 8)
        let newSize = CGSize(width: max(10, baseSize.width * nz), height: max(10, baseSize.height * nz))
        let f = frame
        let rx = (anchor.x - f.minX) / f.width, ry = (anchor.y - f.minY) / f.height
        zoom = nz
        setFrame(CGRect(x: anchor.x - rx * newSize.width, y: anchor.y - ry * newSize.height,
                        width: newSize.width, height: newSize.height), display: true)
    }

    @objc func copyImage() { ImageOut.copy(image, size: baseSize) }
    @objc func saveImage() { ImageOut.save(image, size: baseSize) }
    @objc func ocr() { OCRWindow.show(image) }
    @objc func resetZoom() { setZoom(1, anchor: CGPoint(x: frame.midX, y: frame.midY)) }
    @objc func closePin() { close() }
    @objc func closeAllPins() { PinManager.shared.closeAll() }
    @objc func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
}

final class PinView: NSView {
    private var dragStart: CGPoint?
    private var originStart: CGPoint = .zero
    private var pin: PinWindow? { window as? PinWindow }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let pin, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = pin.zoom >= 1 ? .none : .high
        ctx.draw(pin.image, in: bounds)
        let key = pin.isKeyWindow
        ctx.setStrokeColor((key ? accent : NSColor(white: 0.5, alpha: 0.6)).cgColor)
        ctx.setLineWidth(key ? 2 : 1)
        ctx.stroke(bounds.insetBy(dx: key ? 1 : 0.5, dy: key ? 1 : 0.5))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in self?.needsDisplay = true }
        }
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { pin?.close(); return }
        window?.makeKey()
        dragStart = NSEvent.mouseLocation
        originStart = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = dragStart else { return }
        let m = NSEvent.mouseLocation
        window?.setFrameOrigin(CGPoint(x: originStart.x + m.x - s.x, y: originStart.y + m.y - s.y))
    }

    override func mouseUp(with e: NSEvent) { dragStart = nil }

    override func scrollWheel(with e: NSEvent) {
        guard let pin else { return }
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
        if e.modifierFlags.contains(.control) || e.modifierFlags.contains(.option) {
            pin.alphaValue = min(1, max(0.1, pin.alphaValue + dy))
        } else {
            pin.setZoom(pin.zoom * (1 + dy), anchor: NSEvent.mouseLocation)
        }
    }

    override func keyDown(with e: NSEvent) {
        guard let pin else { return }
        let cmd = e.modifierFlags.contains(.command)
        switch (Int(e.keyCode), cmd) {
        case (kVK_Escape, _), (kVK_ANSI_W, true): pin.close()
        case (kVK_ANSI_C, true): pin.copyImage()
        case (kVK_ANSI_S, true): pin.saveImage()
        case (kVK_ANSI_0, true): pin.resetZoom()
        case (kVK_ANSI_O, _): pin.ocr()
        case (kVK_ANSI_Equal, true): pin.setZoom(pin.zoom * 1.1, anchor: CGPoint(x: pin.frame.midX, y: pin.frame.midY))
        case (kVK_ANSI_Minus, true): pin.setZoom(pin.zoom / 1.1, anchor: CGPoint(x: pin.frame.midX, y: pin.frame.midY))
        default: super.keyDown(with: e)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let pin else { return nil }
        let m = NSMenu()
        func add(_ t: String, _ s: Selector, _ key: String = "") {
            let i = NSMenuItem(title: t, action: s, keyEquivalent: key); i.target = pin; m.addItem(i)
        }
        add("Copy", #selector(PinWindow.copyImage), "c")
        add("Save As…", #selector(PinWindow.saveImage), "s")
        m.addItem(.separator())
        add("Recognize Text (OCR)", #selector(PinWindow.ocr), "o")
        add("Actual Size", #selector(PinWindow.resetZoom), "0")
        let op = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [100, 80, 60, 40, 20] {
            let i = NSMenuItem(title: "\(v)%", action: #selector(PinWindow.setOpacity(_:)), keyEquivalent: "")
            i.tag = v; i.target = pin
            i.state = abs(pin.alphaValue * 100 - CGFloat(v)) < 1 ? .on : .off
            sub.addItem(i)
        }
        op.submenu = sub
        m.addItem(op)
        m.addItem(.separator())
        add("Close", #selector(PinWindow.closePin), "w")
        add("Close All Pins", #selector(PinWindow.closeAllPins))
        return m
    }
}

// MARK: - OCR

enum OCR {
    static func recognize(_ cg: CGImage) async -> String {
        // Vision downsamples very tall images, so recognize them in horizontal bands.
        let band = max(cg.width * 2, 1600)
        var lines: [String] = []
        var y = 0
        while y < cg.height {
            let h = min(band, cg.height - y)
            if let tile = cg.cropping(to: CGRect(x: 0, y: y, width: cg.width, height: h)) {
                lines += await recognizeTile(tile)
            }
            y += h
        }
        return lines.joined(separator: "\n")
    }

    private static func recognizeTile(_ cg: CGImage) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
                let obs = (req.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                // group observations sharing a baseline into one line
                var rows: [[VNRecognizedTextObservation]] = []
                for o in obs {
                    if let first = rows.last?.first,
                       abs(first.boundingBox.midY - o.boundingBox.midY) < min(first.boundingBox.height, o.boundingBox.height) * 0.5 {
                        rows[rows.count - 1].append(o)
                    } else {
                        rows.append([o])
                    }
                }
                cont.resume(returning: rows.map { row in
                    row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: " ")
                })
            }
        }
    }
}

/// Keeps utility windows alive until they are closed.
enum WindowKeeper {
    static var windows: [NSWindow] = []
    static func keep(_ w: NSWindow) {
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { n in
            windows.removeAll { $0 === (n.object as? NSWindow) }
        }
    }

    /// A titled window with `content` filling it and a bottom bar holding a status label and buttons.
    static func make(title: String, size: CGSize, content: NSView,
                     buttons: [(String, () -> Void)]) -> (NSWindow, NSTextField) {
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.level = .floating
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        content.frame = CGRect(x: 0, y: 44, width: size.width, height: size.height - 44)
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)
        let status = NSTextField(labelWithString: "")
        status.frame = CGRect(x: 12, y: 13, width: size.width - 24 - CGFloat(buttons.count) * 96, height: 18)
        status.autoresizingMask = [.width]
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        root.addSubview(status)
        var x = size.width - 12
        for (t, h) in buttons.reversed() {
            let b = ActionButton(symbol: nil, tip: t, size: CGSize(width: 88, height: 28), handler: h)
            b.title = t
            b.imagePosition = .noImage
            b.isBordered = true
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = true
            NSLayoutConstraint.deactivate(b.constraints)
            x -= 88
            b.frame = CGRect(x: x, y: 8, width: 88, height: 28)
            b.autoresizingMask = [.minXMargin]
            root.addSubview(b)
            x -= 8
        }
        w.contentView = root
        if let s = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let f = s.visibleFrame
            w.setFrameOrigin(CGPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
        }
        keep(w)
        return (w, status)
    }
}

enum OCRWindow {
    static func show(_ img: CGImage) {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.font = .systemFont(ofSize: 14)
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.string = ""
        let (w, status) = WindowKeeper.make(title: "Recognized Text", size: CGSize(width: 520, height: 400), content: scroll,
                                            buttons: [("Copy", {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(tv.string, forType: .string)
                                            })])
        status.stringValue = "Recognizing…"
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            let text = await OCR.recognize(img)
            tv.string = text
            if text.isEmpty {
                status.stringValue = "No text found"
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                status.stringValue = "Copied to clipboard · \(text.count) characters"
            }
            w.makeFirstResponder(tv)
        }
    }
}

// MARK: - Scrolling capture

/// Stitches successive captures of the same screen region while the content scrolls down.
final class Stitcher {
    let width: Int, frameH: Int, bpr: Int
    let space: CGColorSpace
    private(set) var buffer: [UInt8]
    private(set) var rows: Int
    private var prevHash: [UInt64]
    static let maxRows = 50_000

    init?(_ img: CGImage) {
        width = img.width; frameH = img.height; bpr = img.width * 4
        space = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let px = Stitcher.pixels(img, width, frameH, space) else { return nil }
        buffer = px
        rows = frameH
        prevHash = Stitcher.hashes(px, width, frameH).0
    }

    static func pixels(_ img: CGImage, _ w: Int, _ h: Int, _ space: CGColorSpace) -> [UInt8]? {
        guard img.width == w, img.height == h else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    /// Per-row fingerprint (slightly quantized to tolerate noise) and whether the row has any detail.
    static func hashes(_ px: [UInt8], _ w: Int, _ h: Int) -> ([UInt64], [Bool]) {
        var hs = [UInt64](repeating: 0, count: h)
        var info = [Bool](repeating: false, count: h)
        px.withUnsafeBufferPointer { p in
            for y in 0..<h {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                var lo = 255 * 3, hi = 0
                var x = 0
                let base = y * w * 4
                while x < w {
                    let i = base + x * 4
                    let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                    hash = (hash ^ UInt64((r >> 2) << 16 | (g >> 2) << 8 | (b >> 2))) &* 0x100_0000_01b3
                    let l = r + g + b
                    lo = min(lo, l); hi = max(hi, l)
                    x += 2
                }
                hs[y] = hash
                info[y] = hi - lo > 24
            }
        }
        return (hs, info)
    }

    enum Result { case unchanged, appended(Int), lost, full }

    func add(_ img: CGImage) -> Result {
        guard rows < Stitcher.maxRows else { return .full }
        guard let px = Stitcher.pixels(img, width, frameH, space) else { return .lost }
        let (h, info) = Stitcher.hashes(px, width, frameH)
        let H = frameH

        // rows that did not move (sticky headers / footers)
        var ft = 0
        while ft < H && h[ft] == prevHash[ft] { ft += 1 }
        if ft == H { return .unchanged }
        var fb = 0
        while fb < H - ft && h[H - 1 - fb] == prevHash[H - 1 - fb] { fb += 1 }
        ft = min(ft, H * 35 / 100)
        fb = min(fb, H * 35 / 100)
        let lo = ft, hi = H - fb

        // find the scroll distance dy where new[i] == prev[i + dy]
        var bestDy = 0, bestRatio = 0.0, bestMatch = 0
        let maxDy = (hi - lo) - 12
        if maxDy >= 1 {
            for dy in 1...maxDy {
                var match = 0, cmp = 0
                for i in lo..<(hi - dy) where info[i] {
                    cmp += 1
                    if h[i] == prevHash[i + dy] { match += 1 }
                }
                guard cmp >= 8 else { continue }
                let ratio = Double(match) / Double(cmp)
                if ratio > bestRatio + 1e-9 || (abs(ratio - bestRatio) < 1e-9 && match > bestMatch) {
                    bestRatio = ratio; bestMatch = match; bestDy = dy
                }
            }
        }
        guard bestDy > 0, bestRatio >= 0.9 else { return .lost }

        // insert the newly revealed rows [hi - dy, hi) just above the fixed footer
        let dy = min(bestDy, Stitcher.maxRows - rows)
        let footerStart = buffer.count - fb * bpr
        let newRows = Array(px[(hi - dy) * bpr ..< hi * bpr])
        buffer.insert(contentsOf: newRows, at: footerStart)
        rows += dy
        prevHash = h
        return .appended(dy)
    }

    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

final class ScrollCaptureController {
    static var current: ScrollCaptureController?
    let screen: NSScreen
    let region: CGRect   // screen-local points, bottom-left origin
    let scale: CGFloat
    private var border: NSWindow!
    private var hud: NSPanel!
    private var label: NSTextField!
    private var stitcher: Stitcher?
    private var running = true

    init(screen: NSScreen, region: CGRect, scale: CGFloat) {
        self.screen = screen; self.region = region; self.scale = scale
    }

    func start() {
        let g = region.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        border = NSWindow(contentRect: g.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.ignoresMouseEvents = true
        border.level = .statusBar
        border.hasShadow = false
        border.isReleasedWhenClosed = false
        let bv = NSView()
        bv.wantsLayer = true
        bv.layer?.borderColor = accent.cgColor
        bv.layer?.borderWidth = 3
        border.contentView = bv
        border.orderFrontRegardless()

        let hudSize = CGSize(width: 380, height: 40)
        var hy = g.minY - hudSize.height - 8
        if hy < screen.frame.minY { hy = g.maxY + 8 }
        if hy + hudSize.height > screen.frame.maxY { hy = g.minY + 8 }
        let hx = min(max(screen.frame.minX, g.maxX - hudSize.width), screen.frame.maxX - hudSize.width)
        hud = NSPanel(contentRect: CGRect(x: hx, y: hy, width: hudSize.width, height: hudSize.height),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .statusBar
        hud.isReleasedWhenClosed = false
        hud.hasShadow = true
        hud.becomesKeyOnlyIfNeeded = true
        hud.appearance = NSAppearance(named: .aqua)
        let hv = NSView(frame: CGRect(origin: .zero, size: hudSize))
        hv.wantsLayer = true
        hv.layer?.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        hv.layer?.cornerRadius = 8
        label = NSTextField(labelWithString: "Scroll the page slowly…")
        label.frame = CGRect(x: 12, y: 11, width: 210, height: 18)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        hv.addSubview(label)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCapture))
        cancel.bezelStyle = .rounded
        cancel.frame = CGRect(x: 228, y: 6, width: 72, height: 28)
        hv.addSubview(cancel)
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = CGRect(x: 300, y: 6, width: 72, height: 28)
        hv.addSubview(done)
        hud.contentView = hv
        hud.orderFrontRegardless()

        Task { @MainActor in await self.loop() }
    }

    private func loop() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let id = Capture.displayID(screen)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return }
            let mine = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x: region.minX, y: screen.frame.height - region.maxY, width: region.width, height: region.height)
            cfg.width = Int(round(region.width * scale))
            cfg.height = Int(round(region.height * scale))
            cfg.showsCursor = false
            cfg.captureResolution = .best
            while running {
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                guard running else { break }
                if let st = stitcher {
                    switch st.add(img) {
                    case .appended, .unchanged: label.stringValue = "Scroll slowly · \(st.width) × \(st.rows) px"
                    case .lost: label.stringValue = "⚠︎ Too fast – scroll back up a bit"
                    case .full: label.stringValue = "Maximum length reached – click Done"
                    }
                } else {
                    stitcher = Stitcher(img)
                }
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        } catch {
            debugLog("scroll capture failed: \(error)")
            teardown()
            AppDelegate.showPermissionAlert(error)
        }
    }

    private func teardown() {
        running = false
        border?.orderOut(nil)
        hud?.orderOut(nil)
        ScrollCaptureController.current = nil
    }

    @objc func cancelCapture() { teardown() }

    @objc func done() {
        teardown()
        guard let st = stitcher, let img = st.makeImage() else { NSSound.beep(); return }
        let size = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
        ImageOut.copy(img, size: size)
        LongShotWindow.show(img, size: size)
    }
}

enum LongShotWindow {
    static func show(_ img: CGImage, size: CGSize) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        let iv = NSImageView(frame: CGRect(origin: .zero, size: size))
        iv.image = NSImage(cgImage: img, size: size)
        iv.imageScaling = .scaleNone
        scroll.documentView = iv
        let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let winSize = CGSize(width: min(size.width + 20, vis.width * 0.8), height: min(size.height + 44, vis.height * 0.85))
        let (w, status) = WindowKeeper.make(title: "Scrolling Capture", size: winSize, content: scroll, buttons: [
            ("OCR", { OCRWindow.show(img) }),
            ("Save…", { ImageOut.save(img, size: size) }),
            ("Copy", { ImageOut.copy(img, size: size) }),
        ])
        status.stringValue = "\(img.width) × \(img.height) px · copied to clipboard"
        // start at the top of the image
        iv.scroll(CGPoint(x: 0, y: size.height))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "scissors", accessibilityDescription: "SnipMac")
        img?.isTemplate = true
        statusItem.button?.image = img

        let menu = NSMenu()
        menu.delegate = self
        func add(_ t: String, _ s: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = self; menu.addItem(i); return i
        }
        _ = add("Capture          F1 / ⌃⌥A", #selector(capture))
        _ = add("Pin Clipboard    F3 / ⌃⌥P", #selector(pinClipboard))
        _ = add("Close All Pins", #selector(closePins))
        menu.addItem(.separator())
        loginItem = add("Launch at Login", #selector(toggleLogin))
        _ = add("Screen Recording Permission…", #selector(openPrivacy))
        _ = add("Help", #selector(showHelp))
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit SnipMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
        statusItem.menu = menu

        let hk = HotKeyCenter.shared
        hk.register(keyCode: kVK_F1, modifiers: 0, id: 1) { CaptureController.start() }
        hk.register(keyCode: kVK_ANSI_A, modifiers: controlKey | optionKey, id: 2) { CaptureController.start() }
        hk.register(keyCode: kVK_F3, modifiers: 0, id: 3) { PinManager.shared.pinClipboard() }
        hk.register(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey, id: 4) { PinManager.shared.pinClipboard() }

        debugLog("launched, preflight=\(CGPreflightScreenCaptureAccess())")
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            try? SMAppService.mainApp.register()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func capture() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CaptureController.start() }
    }
    @objc func pinClipboard() { PinManager.shared.pinClipboard() }
    @objc func closePins() { PinManager.shared.closeAll() }
    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        if s.status == .enabled { try? s.unregister() } else { try? s.register() }
    }

    @objc func showHelp() {
        let a = NSAlert()
        a.messageText = "SnipMac Help"
        a.informativeText = """
        F1 or ⌃⌥A: Capture (press F1 again to copy to clipboard)
        F3 or ⌃⌥P: Pin clipboard image/text to screen

        While capturing:
        • Hover to detect windows, click to select; drag for a custom area
        • Drag selection to move, drag handles to resize, arrow keys to nudge
        • O OCR · L scrolling capture (then scroll the page slowly, click Done)
        • R Rect · E Ellipse · A Arrow · P Pen · M Highlighter · B Mosaic · T Text; 1/2/3 size; Shift constrains
        • F1 / Enter / double-click / ⌘C copy · ⌘S save · F3 / ⌘T pin · ⌘Z undo
        • No selection: C copies the color under the cursor; right-click clears selection; Esc quits

        Pins: drag to move, scroll to zoom, ⌃/⌥+scroll for opacity, double-click or Esc to close, right-click for more
        """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    static func showPermissionAlert(_ error: Error) {
        let a = NSAlert()
        a.messageText = "Cannot Capture Screen"
        a.informativeText = "Allow SnipMac in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch SnipMac.\n\n(\(error.localizedDescription))"
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
