import AppKit
import Combine
import CoreGraphics
import Translation

// Fixed translation direction for this milestone.
let kSourceLanguage = Locale.Language(identifier: "en")
let kTargetLanguage = Locale.Language(identifier: "th")

@MainActor
final class OverlayViewModel: ObservableObject {

    enum Status: Equatable {
        case needsPermission
        case starting
        case running
        case paused // while the user drags the lens
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var translatedText: String = ""
    /// True until the first frame after a (re)start arrives; drives the
    /// one-shot loading indicator so the live overlay doesn't flicker.
    @Published private(set) var awaitingFirstFrame = true
    @Published private(set) var isLensVisible = true
    /// Mouse is over the lens (tracked by DragContainerView); reveals the
    /// hover-only controls.
    @Published private(set) var isHovering = false
    /// Alpha of the glass background (0 = fully see-through, 1 = full HUD
    /// material). Persisted across launches.
    @Published var glassOpacity: Double {
        didSet { UserDefaults.standard.set(glassOpacity, forKey: Self.glassOpacityKey) }
    }

    private static let glassOpacityKey = "glassOpacity"

    /// Supplied by AppDelegate; returns the panel's current frame in global
    /// screen coordinates.
    var panelFrameProvider: () -> NSRect = { .zero }
    /// Supplied by AppDelegate; orders the panel in or out.
    var panelVisibilityHandler: ((Bool) -> Void)?

    private let engine = CaptureEngine()
    private var lastRecognizedText: String?
    private var restartTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?

    /// OCR results waiting to be translated. Buffering keeps only the newest
    /// text so translation never lags behind the screen.
    private let textStream: AsyncStream<String>
    private let textContinuation: AsyncStream<String>.Continuation

    init() {
        glassOpacity = UserDefaults.standard.object(forKey: Self.glassOpacityKey) as? Double ?? 0.85

        var continuation: AsyncStream<String>.Continuation!
        textStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        textContinuation = continuation

        engine.onFrame = { [weak self] image in
            // Runs on the capture queue: keep OCR off the main thread. A nil
            // result means Vision threw for this frame — skip it and keep the
            // previous translation visible.
            let text = try? OCRService.recognizeText(in: image)
            Task { @MainActor in
                self?.handleRecognizedText(text)
            }
        }
        engine.onError = { [weak self] message in
            Task { @MainActor in
                self?.status = .failed("Live translation paused — \(message)")
            }
        }
    }

    // MARK: - Permission

    func checkPermissionAndStart() {
        if CGPreflightScreenCaptureAccess() {
            startCapture(after: .zero)
        } else {
            status = .needsPermission
            CGRequestScreenCaptureAccess()
            beginPermissionPolling()
        }
    }

    func appDidBecomeActive() {
        if status == .needsPermission, CGPreflightScreenCaptureAccess() {
            startCapture(after: .zero)
        }
    }

    /// The panel is non-activating, so the app may never regain focus after
    /// the user grants permission in System Settings — poll instead and start
    /// automatically once the grant appears.
    private func beginPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if CGPreflightScreenCaptureAccess() {
                    if self.isLensVisible {
                        self.startCapture(after: .zero)
                    }
                    return
                }
            }
        }
    }

    // MARK: - Visibility

    func toggleLens() {
        setLensVisible(!isLensVisible)
    }

    func setHovering(_ hovering: Bool) {
        if isHovering != hovering {
            isHovering = hovering
        }
    }

    func setLensVisible(_ visible: Bool) {
        guard visible != isLensVisible else { return }
        isLensVisible = visible
        panelVisibilityHandler?(visible)
        if visible {
            if status == .needsPermission {
                checkPermissionAndStart()
            } else {
                startCapture(after: .zero)
            }
        } else {
            restartTask?.cancel()
            if status != .needsPermission {
                status = .paused
            }
            let engine = engine
            Task {
                await engine.stop()
            }
        }
    }

    // MARK: - Dragging

    func dragBegan() {
        restartTask?.cancel()
        guard status != .needsPermission else { return }
        status = .paused
        let engine = engine
        Task {
            await engine.stop()
        }
    }

    func dragEnded() {
        guard status != .needsPermission else { return }
        startCapture(after: .milliseconds(300)) // debounce before restarting
    }

    // MARK: - Capture lifecycle

    private func startCapture(after delay: Duration) {
        permissionPollTask?.cancel()
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            await self.performStart()
        }
    }

    private func performStart() async {
        status = .starting
        awaitingFirstFrame = true
        do {
            let geometry = try captureGeometry()
            try await engine.start(geometry)
            status = .running
        } catch {
            // The grant may have been revoked (e.g. the app was rebuilt);
            // fall back to the permission flow instead of a dead error state.
            if !CGPreflightScreenCaptureAccess() {
                status = .needsPermission
                beginPermissionPolling()
            } else {
                status = .failed("Live translation paused — \(error.localizedDescription)")
            }
        }
    }

    /// Maps the panel's global frame to the SCStream source rect of the
    /// display it sits on (points, top-left origin).
    private func captureGeometry() throws -> CaptureGeometry {
        let panelFrame = panelFrameProvider()
        guard panelFrame.width > 0, panelFrame.height > 0 else {
            throw CaptureError.panelFrameUnavailable
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(panelFrame) }) ?? NSScreen.main,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            throw CaptureError.displayNotFound
        }

        let screenFrame = screen.frame
        let sourceRect = CGRect(
            x: panelFrame.minX - screenFrame.minX,
            y: screenFrame.maxY - panelFrame.maxY, // flip: global bottom-left -> display top-left
            width: panelFrame.width,
            height: panelFrame.height
        )
        let scale = screen.backingScaleFactor
        return CaptureGeometry(
            displayID: CGDirectDisplayID(screenNumber.uint32Value),
            sourceRect: sourceRect,
            pixelWidth: Int(panelFrame.width * scale),
            pixelHeight: Int(panelFrame.height * scale)
        )
    }

    // MARK: - OCR / translation pipeline

    private func handleRecognizedText(_ text: String?) {
        if awaitingFirstFrame {
            awaitingFirstFrame = false
        }
        guard let text, !text.isEmpty else { return }
        // Nothing on screen changed — skip the redundant translation call.
        guard text != lastRecognizedText else { return }
        lastRecognizedText = text
        textContinuation.yield(text)
    }

    /// Consumes OCR results for the lifetime of the translation session.
    /// Called from OverlayContentView's translationTask.
    func runTranslationLoop(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
        } catch {
            status = .failed("Translation unavailable — \(error.localizedDescription)")
            return
        }
        for await text in textStream {
            do {
                let response = try await session.translate(text)
                translatedText = response.targetText
            } catch {
                // Skip this frame; keep the previous translation visible.
            }
        }
    }
}
