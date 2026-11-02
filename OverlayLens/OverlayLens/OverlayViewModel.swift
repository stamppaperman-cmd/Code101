import AppKit
import Combine
import CoreGraphics
import os
import Translation

// Fixed language pairs for the Apple Translation fallback sessions; the
// actual pair used per piece of text is picked automatically (see
// DetectedSourceLanguage) or via the user's DirectionOverride.
let kEnglishLanguage = Locale.Language(identifier: "en")
let kThaiLanguage = Locale.Language(identifier: "th")
let kChineseLanguage = Locale.Language(identifier: "zh-Hans")

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
    case forceEnToThai
    case forceThaiToEn
    case forceZhToThai

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .forceEnToThai: return "EN → TH"
        case .forceThaiToEn: return "TH → EN"
        case .forceZhToThai: return "ZH → TH"
        }
    }

    /// Explicit (source, target) language codes, or nil to detect automatically.
    var pair: (source: String, target: String)? {
        switch self {
        case .auto: return nil
        case .forceEnToThai: return ("en", "th")
        case .forceThaiToEn: return ("th", "en")
        case .forceZhToThai: return ("zh", "th")
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
    // Lens starts OFF: no capture until the user explicitly enables it
    // (menu toggle or hotkey) — never auto-start on launch/login.
    @Published private(set) var isLensVisible = false
    /// Mouse is over the lens (tracked by DragContainerView); reveals the
    /// hover-only controls.
    @Published private(set) var isHovering = false
    /// Same, for the separate reader window.
    @Published private(set) var isReaderHovering = false
    /// Alpha of the glass background (0 = fully see-through, 1 = full HUD
    /// material). Persisted across launches.
    @Published var glassOpacity: Double {
        didSet { UserDefaults.standard.set(glassOpacity, forKey: Self.glassOpacityKey) }
    }
    /// Multiplier applied to the translated text's font size, in both
    /// classic and AR mode. Persisted across launches.
    @Published var textScale: Double {
        didSet { UserDefaults.standard.set(textScale, forKey: Self.textScaleKey) }
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
    /// Lines found in the most recent frame; drives the lens header readout.
    @Published private(set) var recognizedLineCount = 0

    /// What the lens border and header report at a glance, so a see-through
    /// frame doesn't leave the user guessing whether anything is happening.
    enum LensSignal {
        case translating
        case idle
        case noText
        case warning
    }

    var lensSignal: LensSignal {
        switch status {
        case .needsPermission, .failed:
            return .warning
        case .paused:
            return .idle
        case .starting:
            return awaitingFirstFrame ? .idle : .translating
        case .running:
            if translationNote != nil { return .warning }
            return recognizedLineCount > 0 ? .translating : .noText
        }
    }

    /// Opens the shared controls popover next to the lens — the menu bar icon
    /// can be buried under the notch, so the lens carries its own way in.
    var openSettingsHandler: (() -> Void)?

    private static let glassOpacityKey = "glassOpacity"
    private static let textScaleKey = "textScale"
    private static let onlineTranslationKey = "useOnlineTranslation"

    /// Thai-first OCR is only safe when Chinese can't be on screen.
    var ocrThaiFirst: Bool { directionOverride == .forceEnToThai || directionOverride == .forceThaiToEn }
    private static let arModeKey = "arModeEnabled"
    private static let directionOverrideKey = "directionOverride"
    static let lensFrameKey = "lensFrame"
    static let readerFrameKey = "readerFrame"
    private static let readerVisibleKey = "readerVisible"

    /// The reader is the second window: the clear lens marks *what* to
    /// translate, this one shows the translated text somewhere out of the way.
    @Published private(set) var isReaderVisible: Bool {
        didSet { UserDefaults.standard.set(isReaderVisible, forKey: Self.readerVisibleKey) }
    }

    /// Supplied by AppDelegate; returns the capture frame's rect in global
    /// screen coordinates. This is the region that gets captured.
    var panelFrameProvider: () -> NSRect = { .zero }
    /// Supplied by AppDelegate; orders the panel in or out.
    var panelVisibilityHandler: ((Bool) -> Void)?
    /// Same pair for the reader window.
    var readerFrameProvider: () -> NSRect = { .zero }
    var readerVisibilityHandler: ((Bool) -> Void)?

    private let engine = CaptureEngine()
    private var restartTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?

    // MARK: Translation pipeline state

    /// On-device fallback sessions keyed by "source-target" (e.g. "en-th").
    private var translationSessions: [String: TranslationSession] = [:]
    private var preparedSessionKeys: Set<String> = []

    private var lastRecognizedBlob: String?
    private var classicTranslationTask: Task<Void, Never>?
    /// Memoizes line -> translation so unchanged lines never get re-sent,
    /// and so a line's overlay updates the instant its translation resolves.
    private var lineTranslationCache: [String: String] = [:]
    private var inFlightLineTexts: Set<String> = []

    init() {
        glassOpacity = UserDefaults.standard.object(forKey: Self.glassOpacityKey) as? Double ?? 0.85
        textScale = UserDefaults.standard.object(forKey: Self.textScaleKey) as? Double ?? 1.0
        useOnlineTranslation = UserDefaults.standard.object(forKey: Self.onlineTranslationKey) as? Bool ?? true
        arModeEnabled = UserDefaults.standard.object(forKey: Self.arModeKey) as? Bool ?? false
        directionOverride = UserDefaults.standard.string(forKey: Self.directionOverrideKey)
            .flatMap(DirectionOverride.init(rawValue:)) ?? .auto
        isReaderVisible = UserDefaults.standard.object(forKey: Self.readerVisibleKey) as? Bool ?? true

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

    func setReaderHovering(_ hovering: Bool) {
        if isReaderHovering != hovering {
            isReaderHovering = hovering
        }
    }

    /// Shows/hides the reader window on its own. The lens keeps capturing
    /// either way — in AR mode the translation is drawn in the clear lens, so
    /// the reader is optional.
    func setReaderVisible(_ visible: Bool) {
        guard visible != isReaderVisible else { return }
        isReaderVisible = visible
        readerVisibilityHandler?(visible && isLensVisible)
    }

    func setLensVisible(_ visible: Bool) {
        guard visible != isLensVisible else { return }
        isLensVisible = visible
        panelVisibilityHandler?(visible)
        readerVisibilityHandler?(visible && isReaderVisible)
        if visible {
            // Permission preflight happens here (first enable) rather than at
            // launch, since the lens no longer auto-starts.
            checkPermissionAndStart()
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

    /// Moving the reader doesn't touch the capture region, so it only needs
    /// its frame remembered — no capture restart.
    func readerMoved() {
        let frame = readerFrameProvider()
        guard frame.width > 0, frame.height > 0 else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.readerFrameKey)
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

    /// Called from the view's translationTask closures, one per (source,
    /// target) pair. Sessions stay valid as long as those tasks keep
    /// running, so we can use them ad hoc from the per-line/per-blob
    /// translation tasks below.
    func attachSession(_ session: TranslationSession, source: String, target: String) {
        let key = "\(source)-\(target)"
        translationSessions[key] = session
        preparedSessionKeys.remove(key)
    }

    /// The view's translationTask sessions only exist once the lens has been
    /// shown, and the screen picker (⌥⌘T) usually runs with it hidden — so
    /// without this the fallback had nothing to fall back to. From macOS 26 a
    /// session for already-installed languages can be made directly.
    private func installedSession(source: String, target: String) -> TranslationSession? {
        guard #available(macOS 26.0, *) else { return nil }
        let key = "\(source)-\(target)"
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
        translationSessions[key] = session
        // Installed languages need no download prompt.
        preparedSessionKeys.insert(key)
        return session
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
        recognizedLineCount = lines?.count ?? 0
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
                let pair = self.effectivePair(for: blob)
                let result = await self.translateWithFallback(blob, source: pair.source, target: pair.target)
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
        // The reader window reads from translatedText, so AR mode has to feed
        // it too — otherwise lens 2 sits empty whenever AR mode is on.
        syncReaderTextFromSegments()

        for line in lines where lineTranslationCache[line.text] == nil && !inFlightLineTexts.contains(line.text) {
            inFlightLineTexts.insert(line.text)
            let text = line.text
            Task { [weak self] in
                guard let self else { return }
                let pair = self.effectivePair(for: text)
                let result = await self.translateWithFallback(text, source: pair.source, target: pair.target)
                self.inFlightLineTexts.remove(text)
                guard let result else { return }
                self.lineTranslationCache[text] = result
                for i in self.arSegments.indices where self.arSegments[i].originalText == text {
                    self.arSegments[i].displayText = result
                }
                self.syncReaderTextFromSegments()
            }
        }
    }

    /// AR segments are already translated line by line; joining them keeps the
    /// reader window (and the copy button) useful in AR mode.
    private func syncReaderTextFromSegments() {
        guard arModeEnabled else { return }
        let joined = arSegments
            .map(\.displayText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        if joined != translatedText {
            translatedText = joined
        }
    }

    /// Applies the user's direction override, if any; otherwise detects the
    /// source language automatically and picks its translation target:
    /// Thai -> English, Chinese -> Thai, anything else -> Thai. The override
    /// is a manual escape hatch for short or ambiguous text (brand names,
    /// numbers, loanwords) that auto-detection occasionally guesses wrong.
    func effectivePair(for text: String) -> (source: String, target: String) {
        if let pair = directionOverride.pair { return pair }
        switch DetectedSourceLanguage.detect(for: text) {
        case .thai: return ("th", "en")
        case .chinese: return ("zh", "th")
        case .other: return ("en", "th")
        }
    }

    /// Tries the online translator first (when enabled), then falls back to
    /// whichever on-device Apple session matches the requested pair.
    /// Returns nil if both fail or no fallback session is ready yet.
    func translateWithFallback(_ text: String, source: String, target: String) async -> String? {
        if useOnlineTranslation {
            do {
                // Force the explicit source we already detected rather than
                // Google's own sl=auto: when Thai script appears anywhere in
                // a mostly-English line, auto-detect classifies the whole
                // string as Thai and — since that already equals a Thai
                // target — silently no-ops instead of translating the
                // English part. An explicit source avoids that and still
                // lets the model merge mixed-language text sensibly.
                let result = try await OnlineTranslator.translate(text, source: source, target: target)
                log.debug("online translation ok: chars=\(result.count, privacy: .public)")
                return result
            } catch {
                log.error("online translation failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let key = "\(source)-\(target)"
        guard let session = translationSessions[key] ?? installedSession(source: source, target: target) else { return nil }
        do {
            if !preparedSessionKeys.contains(key) {
                try await session.prepareTranslation()
                preparedSessionKeys.insert(key)
                log.info("apple translation prepared (\(key, privacy: .public))")
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
