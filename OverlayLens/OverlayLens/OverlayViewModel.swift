import AppKit
import Combine
import CoreGraphics
import os
import Translation

// Fixed language pair for the two Apple Translation fallback sessions;
// direction between them is picked per piece of text (see LanguageDirection).
let kEnglishLanguage = Locale.Language(identifier: "en")
let kThaiLanguage = Locale.Language(identifier: "th")

private let log = Logger(subsystem: "com.overlaylens.OverlayLens", category: "pipeline")

/// A translated line positioned where the original text was recognized, for
/// AR-style in-place overlay. `boundingBox` is Vision-normalized (0...1,
/// origin bottom-left); the view converts it using its own size.
struct ARSegment: Identifiable {
    let id: String
    let originalText: String
    var displayText: String
    let boundingBox: CGRect
}

/// Escape hatch for when automatic per-text language detection guesses
/// wrong on short or ambiguous text (brand names, numbers, loanwords).
enum DirectionOverride: String, CaseIterable, Identifiable {
    case auto
    case forceToThai
    case forceToEnglish

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .forceToThai: return "EN → TH"
        case .forceToEnglish: return "TH → EN"
        }
    }
}

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
    /// Prefer the free online translator (better quality); falls back to
    /// on-device Apple Translation when it fails or the network is down.
    @Published var useOnlineTranslation: Bool {
        didSet { UserDefaults.standard.set(useOnlineTranslation, forKey: Self.onlineTranslationKey) }
    }
    /// AR mode redraws each recognized line in place over the original text
    /// instead of listing translated text in a separate block.
    @Published var arModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(arModeEnabled, forKey: Self.arModeKey)
            if !arModeEnabled { arSegments = [] }
        }
    }
    @Published private(set) var arSegments: [ARSegment] = []
    /// Overrides automatic per-text language detection when it guesses wrong
    /// on short/ambiguous text. Persisted across launches.
    @Published var directionOverride: DirectionOverride {
        didSet {
            UserDefaults.standard.set(directionOverride.rawValue, forKey: Self.directionOverrideKey)
            // Cached translations were made under the old direction; drop
            // them so the next frame retranslates instead of showing stale
            // (possibly wrong-direction) results.
            lineTranslationCache.removeAll()
            lastRecognizedBlob = nil
        }
    }
    /// Non-fatal translation problem to surface in the lens without clearing
    /// the last good translation.
    @Published private(set) var translationNote: String?

    private static let glassOpacityKey = "glassOpacity"
    private static let onlineTranslationKey = "useOnlineTranslation"
    private static let arModeKey = "arModeEnabled"
    private static let directionOverrideKey = "directionOverride"
    static let lensFrameKey = "lensFrame"

    /// Supplied by AppDelegate; returns the panel's current frame in global
    /// screen coordinates.
    var panelFrameProvider: () -> NSRect = { .zero }
    /// Supplied by AppDelegate; orders the panel in or out.
    var panelVisibilityHandler: ((Bool) -> Void)?

    private let engine = CaptureEngine()
    private var restartTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?

    // MARK: Translation pipeline state

    private var thaiSession: TranslationSession?
    private var englishSession: TranslationSession?
    private var thaiSessionPrepared = false
    private var englishSessionPrepared = false

    private var lastRecognizedBlob: String?
    private var classicTranslationTask: Task<Void, Never>?
    /// Memoizes line -> translation so unchanged lines never get re-sent,
    /// and so a line's overlay updates the instant its translation resolves.
    private var lineTranslationCache: [String: String] = [:]
    private var inFlightLineTexts: Set<String> = []

    init() {
        glassOpacity = UserDefaults.standard.object(forKey: Self.glassOpacityKey) as? Double ?? 0.85
        useOnlineTranslation = UserDefaults.standard.object(forKey: Self.onlineTranslationKey) as? Bool ?? true
        arModeEnabled = UserDefaults.standard.object(forKey: Self.arModeKey) as? Bool ?? false
        directionOverride = UserDefaults.standard.string(forKey: Self.directionOverrideKey)
            .flatMap(DirectionOverride.init(rawValue:)) ?? .auto

        engine.onFrame = { [weak self] image in
            // Runs on the capture queue: keep OCR off the main thread. A nil
            // result means Vision threw for this frame — skip it and keep the
            // previous translation visible.
            let lines = try? OCRService.recognizeLines(in: image)
            Task { @MainActor in
                self?.handleRecognizedLines(lines)
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
        let granted = CGPreflightScreenCaptureAccess()
        log.info("launch permission preflight: \(granted, privacy: .public)")
        if granted {
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
        saveLensFrame()
        guard status != .needsPermission else { return }
        startCapture(after: .milliseconds(300)) // debounce before restarting
    }

    /// Remembers the lens position/size so relaunches feel seamless.
    private func saveLensFrame() {
        let frame = panelFrameProvider()
        guard frame.width > 0, frame.height > 0 else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.lensFrameKey)
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
            log.info("capture started: display=\(geometry.displayID, privacy: .public) rect=\(String(describing: geometry.sourceRect), privacy: .public)")
        } catch {
            log.error("capture start failed: \(error.localizedDescription, privacy: .public)")
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

    // MARK: - Apple Translation session lifecycle

    /// Called from the view's translationTask closures. Sessions stay valid
    /// as long as those tasks keep running, so we can use them ad hoc from
    /// the per-line/per-blob translation tasks below.
    func attachThaiSession(_ session: TranslationSession) {
        thaiSession = session
        thaiSessionPrepared = false
    }

    func attachEnglishSession(_ session: TranslationSession) {
        englishSession = session
        englishSessionPrepared = false
    }

    /// Parks for the life of the enclosing translationTask so the attached
    /// session isn't invalidated; exits promptly on cancellation.
    func keepSessionAlive() async {
        try? await Task.sleep(for: .seconds(1_000_000))
    }

    // MARK: - OCR / translation pipeline

    private func handleRecognizedLines(_ lines: [RecognizedLine]?) {
        if awaitingFirstFrame {
            awaitingFirstFrame = false
            log.info("first frame after (re)start: lines=\(lines?.count ?? -1, privacy: .public)")
        }
        guard let lines, !lines.isEmpty else { return }

        if arModeEnabled {
            updateARSegments(for: lines)
        } else {
            let blob = lines.map(\.text).joined(separator: "\n")
            guard blob != lastRecognizedBlob else { return }
            lastRecognizedBlob = blob
            log.debug("ocr text changed: chars=\(blob.count, privacy: .public)")

            classicTranslationTask?.cancel()
            classicTranslationTask = Task { [weak self] in
                guard let self else { return }
                let toThai = self.effectiveTargetIsThai(for: blob)
                let result = await self.translateWithFallback(blob, toThai: toThai)
                guard !Task.isCancelled else { return }
                if let result {
                    self.translatedText = result
                    self.translationNote = nil
                } else {
                    self.translationNote = "Translation failed — check your connection"
                }
            }
        }
    }

    /// Rebuilds the AR overlay from this frame's lines, showing cached
    /// translations instantly and the original text as a placeholder for
    /// lines still in flight; kicks off translation for any new line text.
    private func updateARSegments(for lines: [RecognizedLine]) {
        if lineTranslationCache.count > 300 {
            lineTranslationCache.removeAll()
        }

        arSegments = lines.enumerated().map { index, line in
            ARSegment(
                id: "\(index)_\(line.text.hashValue)",
                originalText: line.text,
                displayText: lineTranslationCache[line.text] ?? line.text,
                boundingBox: line.boundingBox
            )
        }

        for line in lines where lineTranslationCache[line.text] == nil && !inFlightLineTexts.contains(line.text) {
            inFlightLineTexts.insert(line.text)
            let text = line.text
            Task { [weak self] in
                guard let self else { return }
                let toThai = self.effectiveTargetIsThai(for: text)
                let result = await self.translateWithFallback(text, toThai: toThai)
                self.inFlightLineTexts.remove(text)
                guard let result else { return }
                self.lineTranslationCache[text] = result
                for i in self.arSegments.indices where self.arSegments[i].originalText == text {
                    self.arSegments[i].displayText = result
                }
            }
        }
    }

    /// Applies the user's direction override, if any; otherwise detects
    /// automatically. The override is a manual escape hatch for short or
    /// ambiguous text (brand names, numbers, loanwords) that auto-detection
    /// occasionally guesses wrong.
    private func effectiveTargetIsThai(for text: String) -> Bool {
        switch directionOverride {
        case .auto: return LanguageDirection.targetIsThai(for: text)
        case .forceToThai: return true
        case .forceToEnglish: return false
        }
    }

    /// Tries the online translator first (when enabled), then falls back to
    /// whichever on-device Apple session matches the requested direction.
    /// Returns nil if both fail or no fallback session is ready yet.
    private func translateWithFallback(_ text: String, toThai: Bool) async -> String? {
        if useOnlineTranslation {
            do {
                // Force the explicit source we already detected rather than
                // Google's own sl=auto: when Thai script appears anywhere in
                // a mostly-English line, auto-detect classifies the whole
                // string as Thai and — since that already equals a Thai
                // target — silently no-ops instead of translating the
                // English part. An explicit source avoids that and still
                // lets the model merge mixed-language text sensibly.
                let result = try await OnlineTranslator.translate(text, source: toThai ? "en" : "th", target: toThai ? "th" : "en")
                log.debug("online translation ok: chars=\(result.count, privacy: .public)")
                return result
            } catch {
                log.error("online translation failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard let session = toThai ? thaiSession : englishSession else { return nil }
        do {
            if toThai, !thaiSessionPrepared {
                try await session.prepareTranslation()
                thaiSessionPrepared = true
                log.info("apple translation prepared (to Thai)")
            } else if !toThai, !englishSessionPrepared {
                try await session.prepareTranslation()
                englishSessionPrepared = true
                log.info("apple translation prepared (to English)")
            }
            let result = try await session.translate(text).targetText
            log.debug("apple translation ok: chars=\(result.count, privacy: .public)")
            return result
        } catch {
            log.error("apple translation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
