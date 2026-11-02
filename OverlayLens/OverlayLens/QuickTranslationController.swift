import AppKit
import SwiftUI
import ScreenCaptureKit
import Translation
import Vision

@MainActor
final class QuickTranslationController: ObservableObject {
    /// Same frozen-screen picker, two outcomes: translate what was picked, or
    /// put it straight on the clipboard (text, or a QR code's payload).
    enum Mode { case translate, copyText }

    @Published var text = ""
    @Published var busy = false
    @Published var pinned = false
    @Published var message: String?
    let model: OverlayViewModel
    var onSaveToShelf: ((String) -> Void)?
    private var selector: QuickPanel?
    private var card: QuickPanel?
    private var task: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private let engine = CaptureEngine()
    private var screen: NSScreen?
    private var region = CGRect.zero
    private var lastSource = ""
    private var generation = UUID()
    private(set) var mode = Mode.translate
    private var capturedImage: CGImage?
    private var toast: QuickPanel?
    private var toastTask: Task<Void, Never>?

    init(model: OverlayViewModel) { self.model = model }

    func start(mode: Mode = .translate) {
        close()
        self.mode = mode
        model.setLensVisible(false)
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = "อนุญาตให้อ่านหน้าจอก่อนเริ่มแปล"
            alert.informativeText = "เปิดสิทธิ์การบันทึกหน้าจอให้ StampLab ในการตั้งค่าระบบ แล้วกดแปลจากหน้าจออีกครั้ง"
            alert.runModal()
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
        self.screen = screen
        let token = generation
        task = Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { throw CaptureError.displayNotFound }
                let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID == getpid() })
                let config = SCStreamConfiguration()
                config.width = Int(screen.frame.width * screen.backingScaleFactor)
                config.height = Int(screen.frame.height * screen.backingScaleFactor)
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard !Task.isCancelled, generation == token else { return }
                capturedImage = image
                let panel = QuickPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = .screenSaver
                panel.isOpaque = true
                panel.acceptsMouseMovedEvents = true
                panel.hidesOnDeactivate = false
                panel.onEscape = { [weak self] in self?.close() }
                // The screenshot goes on a layer; the overlay above it only ever
                // redraws the outline, so hovering never re-blits a 2x screen.
                let backdrop = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
                backdrop.wantsLayer = true
                backdrop.layer?.contents = image
                backdrop.layer?.contentsGravity = .resize
                backdrop.layer?.backgroundColor = NSColor.black.cgColor
                let view = ScreenTextSelection(frame: backdrop.bounds)
                view.readyHint = mode == .copyText
                    ? "คัดลอกข้อความจากจอ · คลิกหรือลากเลือก · ลากครอบ QR เพื่อคัดลอกลิงก์ · Esc ปิด"
                    : "ภาพหยุดชั่วคราว · คลิกหรือลากเลือก · ดับเบิลคลิกเลือกหน้าต่าง · Esc ปิด"
                view.autoresizingMask = [.width, .height]
                backdrop.addSubview(view)
                view.onSelect = { [weak self] rect, source in self?.select(rect, source: source) }
                view.onScroll = { [weak self] in self?.scrollWhilePicking() }
                let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
                view.windowRects = content.windows.filter { $0.owningApplication?.processID != getpid() && $0.windowLayer == 0 }.map {
                    CGRect(x: $0.frame.minX - screen.frame.minX, y: top - $0.frame.maxY - screen.frame.minY, width: $0.frame.width, height: $0.frame.height)
                }
                panel.contentView = backdrop
                selector = panel
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(view)
                // Language correction triples OCR time on a full 2x screen (measured
                // 1.6-2.0s vs 0.5s) for a handful of changed characters — skip it
                // here so the outlines appear while the hand is still on the mouse.
                let thaiFirst = model.ocrThaiFirst
                let lines = try await Task.detached(priority: .userInitiated) { try OCRService.recognizeLines(in: image, languageCorrection: false, thaiFirst: thaiFirst) }.value
                guard !Task.isCancelled, generation == token else { return }
                view.setLines(lines)
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                close()
                let alert = NSAlert()
                alert.messageText = "อ่านหน้าจอไม่สำเร็จ"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func select(_ localRect: CGRect, source: String) {
        guard let screen else { return }
        region = localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        if mode == .copyText {
            copy(localRect, source: source)
            return
        }
        showCard()
        translate(source)
        // Drop the frozen screenshot: the page underneath can be scrolled
        // with two fingers again while the card stays up.
        selector?.orderOut(nil)
        selector = nil
        card?.level = .floating
    }

    private var scrollMonitors: [Any] = []
    private var scrollSettle: DispatchWorkItem?

    /// Two-finger scroll on the frozen screen: get out of the way, let the
    /// page scroll, then re-capture once the scrolling stops.
    private func scrollWhilePicking() {
        guard selector != nil, scrollMonitors.isEmpty else { return }
        let pickMode = mode
        let token = generation
        selector?.orderOut(nil)
        selector = nil
        task?.cancel()
        let restartLater = { [weak self] in
            guard let self else { return }
            self.scrollSettle?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.endScrollWatch()
                if self.generation == token { self.start(mode: pickMode) }
            }
            self.scrollSettle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { _ in restartLater() }) {
            scrollMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in restartLater(); return event }) {
            scrollMonitors.append(local)
        }
        restartLater()
    }

    private func endScrollWatch() {
        scrollSettle?.cancel()
        scrollSettle = nil
        scrollMonitors.forEach(NSEvent.removeMonitor)
        scrollMonitors.removeAll()
    }

    private func showCard() {
        if card == nil {
            let panel = QuickPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.onEscape = { [weak self] in self?.close() }
            panel.contentView = NSHostingView(rootView: QuickTranslationCard(controller: self, model: model))
            card = panel
        }
        layoutCard()
        card?.makeKeyAndOrderFront(nil)
    }

    private func layoutCard() {
        guard let screen, let card else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let width = min(CGFloat(400), bounds.width)
        let font = NSFont.systemFont(ofSize: 16 * model.textScale)
        let measured = (text as NSString).boundingRect(with: CGSize(width: width - 40, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        let height = min(max(150, measured + 130), max(150, bounds.height * 0.45))
        let candidates = [
            CGRect(x: region.maxX + 12, y: region.maxY - height, width: width, height: height),
            CGRect(x: region.minX - width - 12, y: region.maxY - height, width: width, height: height),
            CGRect(x: region.minX, y: region.minY - height - 12, width: width, height: height),
            CGRect(x: region.minX, y: region.maxY + 12, width: width, height: height)
        ]
        let clamped = candidates.map { rect in
            CGRect(x: min(max(rect.minX, bounds.minX), bounds.maxX - width), y: min(max(rect.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
        }
        let frame = clamped.min { a, b in
            let ia = a.intersection(region), ib = b.intersection(region)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }!
        card.setFrame(frame, display: true)
    }

    private func translate(_ source: String) {
        task?.cancel()
        lastSource = source
        text = ""
        guard !source.isEmpty else { message = "ไม่พบข้อความ ลองเลือกพื้นที่ใหม่"; busy = false; layoutCard(); return }
        message = nil
        busy = true
        layoutCard()
        let token = generation
        task = Task {
            // Let the mounted card attach its on-device sessions before fallback.
            await Task.yield()
            guard !Task.isCancelled else { return }
            let pair = model.effectivePair(for: source)
            let result = await model.translateWithFallback(source, source: pair.source, target: pair.target)
            guard !Task.isCancelled, generation == token else { return }
            busy = false
            text = result ?? ""
            message = result == nil ? "แปลไม่สำเร็จ ตรวจการเชื่อมต่อหรือชุดภาษาแล้วลองอีกครั้ง" : nil
            layoutCard()
        }
    }

    func retry() { translate(lastSource) }

    /// Copy mode: a QR code in the picked area wins when it fills a good part
    /// of it (or there's no text at all); otherwise the recognized text.
    private func copy(_ localRect: CGRect, source: String) {
        guard let screen else { return }
        let code = capturedImage.flatMap { Self.barcodePayload(in: $0, localRect: localRect, screenSize: screen.frame.size) }
        let payload: String
        let isCode: Bool
        if let code, source.isEmpty || code.coverage >= 0.3 {
            payload = code.text
            isCode = true
        } else {
            payload = source
            isCode = false
        }
        let pickedRegion = region
        close()
        guard !payload.isEmpty else {
            showToast(title: "ไม่พบข้อความหรือ QR ในบริเวณนี้", detail: nil, link: nil, near: pickedRegion, on: screen)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = URL(string: trimmed).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        showToast(
            title: isCode ? "คัดลอกจาก QR แล้ว" : "คัดลอกแล้ว · \(payload.count) ตัวอักษร",
            detail: String(trimmed.prefix(140)),
            link: link,
            near: pickedRegion,
            on: screen
        )
    }

    /// Payload of the largest barcode inside the picked area, with how much of
    /// the area it covers. `localRect` is in view points, bottom-left origin.
    nonisolated private static func barcodePayload(in image: CGImage, localRect: CGRect, screenSize: CGSize) -> (text: String, coverage: CGFloat)? {
        let scale = CGFloat(image.width) / screenSize.width
        let crop = CGRect(
            x: localRect.minX * scale,
            y: (screenSize.height - localRect.maxY) * scale,
            width: localRect.width * scale,
            height: localRect.height * scale
        ).integral
        guard let cropped = image.cropping(to: crop) else { return nil }
        let request = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
        let best = (request.results ?? [])
            .filter { $0.payloadStringValue?.isEmpty == false }
            .max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        guard let best, let text = best.payloadStringValue else { return nil }
        return (text, best.boundingBox.width * best.boundingBox.height)
    }

    /// Small confirmation that floats beside what was copied, then fades.
    /// Stays a little longer when it carries an "open link" button.
    private func showToast(title: String, detail: String?, link: URL?, near area: CGRect, on screen: NSScreen) {
        toastTask?.cancel()
        toast?.orderOut(nil)
        let panel = QuickPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: CopyToast(title: title, detail: detail, link: link) { [weak self] in
            self?.dismissToast()
        })
        panel.contentView = hosting
        let size = hosting.fittingSize
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 10)
        if origin.y < bounds.minY { origin.y = area.maxY + 10 }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        toast = panel
        let delay: UInt64 = link == nil ? 1_800_000_000 : 4_000_000_000
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.dismissToast()
        }
    }

    private func dismissToast() {
        toastTask?.cancel()
        guard let panel = toast else { return }
        toast = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
            panel.orderOut(nil)
        }
    }

    func saveToShelf(includeOriginal: Bool = false) {
        guard !busy, !text.isEmpty, let onSaveToShelf else { return }
        let note = includeOriginal ? "ต้นฉบับ\n\(lastSource)\n\nคำแปล\n\(text)" : text
        // Dismiss the frozen selection so the shelf receives keyboard focus.
        close()
        onSaveToShelf(note)
    }

    private func stopLiveCapture() {
        let previous = captureTask
        captureTask = Task {
            await previous?.value
            await engine.stop()
        }
    }

    func togglePin() {
        if pinned {
            pinned = false
            engine.onFrame = nil
            stopLiveCapture()
            return
        }
        guard let screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        pinned = true
        selector?.orderOut(nil)
        selector = nil
        card?.level = .floating
        let token = generation
        engine.onFrame = { [weak self] image in
            let lines = try? OCRService.recognizeLines(in: image)
            let source = lines?.map(\.text).joined(separator: "\n") ?? ""
            Task { @MainActor in
                guard let self, self.generation == token, self.pinned, !self.busy, !source.isEmpty, source != self.lastSource else { return }
                self.translate(source)
            }
        }
        engine.onError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == token, self.pinned else { return }
                self.message = error
                self.pinned = false
            }
        }
        let geometry = CaptureGeometry(displayID: number.uint32Value,
            sourceRect: CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY, width: region.width, height: region.height),
            pixelWidth: Int(region.width * screen.backingScaleFactor), pixelHeight: Int(region.height * screen.backingScaleFactor))
        let previous = captureTask
        captureTask = Task {
            await previous?.value
            guard generation == token, pinned else { return }
            do {
                try await engine.start(geometry)
                if generation != token || !pinned { await engine.stop() }
            } catch { if generation == token { message = error.localizedDescription; pinned = false } }
        }
    }

    func close() {
        endScrollWatch()
        generation = UUID()
        task?.cancel()
        pinned = false
        engine.onFrame = nil
        stopLiveCapture()
        selector?.orderOut(nil)
        card?.orderOut(nil)
        selector = nil
        card = nil
        capturedImage = nil
        text = ""
        message = nil
    }
}

private final class QuickPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Overlay that sits on top of the frozen screenshot: draws the hover /
/// drag outline and the hint, and nothing else, so a mouse move costs a
/// tiny redraw instead of re-blitting a full-resolution screen.
private final class ScreenTextSelection: NSView {
    var onSelect: ((CGRect, String) -> Void)?
    var onScroll: (() -> Void)?
    var windowRects: [CGRect] = []
    var readyHint = ""
    private var pieces: [TextPiece] = []
    private var blocks: [TextBlock] = []
    private var hovered: TextBlock?
    private var selection: CGRect? { didSet { if selection != oldValue { needsDisplay = true } } }
    private var down: CGPoint?
    private var ready = false
    override var acceptsFirstResponder: Bool { true }
    override init(frame: CGRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    func setLines(_ recognized: [RecognizedLine]) {
        pieces = recognized.map { line in
            let r = line.boundingBox
            return TextPiece(rect: CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height, width: r.width * bounds.width, height: r.height * bounds.height), text: line.text)
        }
        blocks = TextLayout.blocks(from: TextLayout.rows(from: pieces), maxHeight: min(320, bounds.height * 0.45))
        ready = true
        // Outline whatever is already under the cursor instead of waiting for the next move.
        if let window { hover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        needsDisplay = true
    }
    private func hover(at p: CGPoint) {
        hovered = blocks.first { $0.rect.insetBy(dx: -6, dy: -5).contains(p) }
        selection = hovered?.rect
    }
    /// Text inside `rect`: pieces at least half covered, re-flowed into rows so
    /// a drag that clips the edge of a line still reads in order.
    private func text(in rect: CGRect) -> String {
        let inside = pieces.filter { piece in
            let overlap = rect.intersection(piece.rect)
            return !overlap.isNull && overlap.width * overlap.height >= 0.5 * piece.rect.width * piece.rect.height
        }
        return TextLayout.text(of: TextLayout.rows(from: inside))
    }
    override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseDown(with event: NSEvent) { down = convert(event.locationInWindow, from: nil) }
    override func scrollWheel(with event: NSEvent) { onScroll?() }
    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let p = convert(event.locationInWindow, from: nil)
        hovered = nil
        selection = CGRect(x: min(p.x, down.x), y: min(p.y, down.y), width: abs(p.x - down.x), height: abs(p.y - down.y)).intersection(bounds)
    }
    override func mouseUp(with event: NSEvent) {
        defer { down = nil }
        guard ready else { return }
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            hovered = nil
            selection = windowRects.first { $0.contains(p) }?.intersection(bounds)
        }
        guard let selection, selection.width > 3, selection.height > 3 else { return }
        let source = hovered.map { TextLayout.text(of: $0.rows) } ?? text(in: selection.insetBy(dx: -2, dy: -2))
        onSelect?(selection.insetBy(dx: -3, dy: -3).intersection(bounds), source)
    }
    override func draw(_ dirtyRect: NSRect) {
        if let selection {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            let path = NSBezierPath(roundedRect: selection.insetBy(dx: -4, dy: -4), xRadius: 5, yRadius: 5)
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        let hint = ready ? readyHint : "กำลังอ่านข้อความบนหน้าจอ…  Esc ปิด"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (hint as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: (bounds.width - size.width) / 2 - 16, y: 28, width: size.width + 32, height: 40)
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        (hint as NSString).draw(at: CGPoint(x: rect.minX + 16, y: rect.minY + 11), withAttributes: attributes)
    }
}

/// "Copied" confirmation: what landed on the clipboard, plus an open button
/// when it's a web link (the usual case for a QR code).
private struct CopyToast: View {
    let title: String
    let detail: String?
    let link: URL?
    let onDone: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: link == nil ? "doc.on.clipboard.fill" : "qrcode")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Brand.clay)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: 280, alignment: .leading)
            if let link {
                Button("เปิด") {
                    NSWorkspace.shared.open(link)
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }
}

private struct QuickTranslationCard: View {
    @ObservedObject var controller: QuickTranslationController
    @ObservedObject var model: OverlayViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.pinned ? "แปลต่อเนื่อง" : "คำแปล").font(.headline)
                if controller.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button { controller.togglePin() } label: { Image(systemName: controller.pinned ? "pin.fill" : "pin") }
                    .help(controller.pinned ? "หยุดแปลต่อเนื่อง" : "ปักหมุดแปลพื้นที่นี้ต่อเนื่อง")
                    .accessibilityLabel("ปักหมุดแปลต่อเนื่อง")
                Button { controller.close() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("ปิดคำแปล")
            }
            ScrollView {
                Text(controller.message ?? (controller.busy && controller.text.isEmpty ? "กำลังแปล…" : controller.text))
                    .font(.system(size: 16 * model.textScale))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.text, forType: .string) } label: { Label("คัดลอก", systemImage: "doc.on.doc") }
                    .disabled(controller.text.isEmpty)
                if controller.message == nil {
                Menu {
                    Button("เก็บเฉพาะคำแปล") { controller.saveToShelf() }
                    Button("เก็บต้นฉบับและคำแปล") { controller.saveToShelf(includeOriginal: true) }
                } label: {
                    Label("เก็บลง Shelf", systemImage: "tray.and.arrow.down")
                } primaryAction: {
                    controller.saveToShelf()
                }
                .disabled(controller.busy || controller.text.isEmpty)
                .help("เก็บคำแปลเป็นโน้ต หรือเปิดเมนูเพื่อแนบต้นฉบับด้วย")
                }
                Spacer()
                if controller.message != nil { Button("ลองอีกครั้ง") { controller.retry() } }
                Button("เลือกใหม่") { controller.start() }
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .translationTask(source: kEnglishLanguage, target: kThaiLanguage) { session in
            model.attachSession(session, source: "en", target: "th"); await model.keepSessionAlive()
        }
        .translationTask(source: kThaiLanguage, target: kEnglishLanguage) { session in
            model.attachSession(session, source: "th", target: "en"); await model.keepSessionAlive()
        }
        .translationTask(source: kChineseLanguage, target: kThaiLanguage) { session in
            model.attachSession(session, source: "zh", target: "th"); await model.keepSessionAlive()
        }
    }
}
