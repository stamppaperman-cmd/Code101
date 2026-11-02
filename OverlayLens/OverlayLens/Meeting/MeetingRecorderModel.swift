import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// Meeting / call apps we recognise, only to label the session (audio is
/// captured from the whole system, so unknown apps and browser tabs work too).
enum MeetingApps {
    private static let known: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.hnc.Discord": "Discord",
        "jp.naver.line.mac": "LINE",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.google.Chrome": "Meet",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
    ]

    /// The frontmost known meeting app when recording starts; otherwise nil
    /// (a background Zoom/LINE process says nothing about where the call is).
    static func detect() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let id = front.bundleIdentifier else { return nil }
        return known[id]
    }
}

struct MeetingSession: Identifiable, Equatable {
    var id: String { url.lastPathComponent }
    let url: URL
    let date: Date
    var title: String
    var hasNotes: Bool
    var hasTranscript: Bool
    var hasAudio: Bool

    var notesURL: URL { MeetingSession.pick(url, "สรุป.md", "notes.md") }
    var transcriptURL: URL { MeetingSession.pick(url, "ข้อความถอดเสียง.md", "transcript.md") }

    /// Thai file name, or the legacy English one for sessions recorded earlier.
    nonisolated static func pick(_ dir: URL, _ thai: String, _ legacy: String) -> URL {
        let t = dir.appendingPathComponent(thai)
        return FileManager.default.fileExists(atPath: t.path) ? t : dir.appendingPathComponent(legacy)
    }
}

@MainActor
final class MeetingRecorderModel: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, recording, processing, done
        case failed(String)
    }

    @Published var phase: Phase = .idle { didSet { dumpStatus() } }
    @Published var elapsed: TimeInterval = 0
    @Published var systemLevel: Float = 0
    @Published var micLevel: Float = 0
    @Published var stageText = ""
    @Published var progress: Double = 0
    @Published var detectedApp: String?
    @Published var warning: String?
    @Published var environmentReady = MeetingPaths.environmentReady
    @Published var isInstalling = false
    @Published var installLog: [String] = []
    @Published var currentSession: MeetingSession?
    @Published var summaryPreview = ""
    @Published var recent: [MeetingSession] = []
    @Published var includeMic: Bool {
        didSet { UserDefaults.standard.set(includeMic, forKey: Keys.includeMic) }
    }
    @Published var context: String {
        didSet { UserDefaults.standard.set(context, forKey: Keys.context) }
    }

    private enum Keys {
        static let includeMic = "MeetingIncludeMic"
        static let context = "MeetingContext"
    }

    private let capture = MeetingAudioCapture()
    private let pipeline = MeetingPipeline()
    private let liveWorker = MeetingLiveWorker()
    private let installer = MeetingInstaller()
    private var timer: Timer?
    private var startDate: Date?
    private var activity: NSObjectProtocol?
    private var lastSound = Date()
    private var silenceNotified = false
    private var sessionDir: URL?
    private var sessionTitle = ""

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool {
        switch phase {
        case .starting, .processing: return true
        default: return false
        }
    }

    init() {
        let defaults = UserDefaults.standard
        includeMic = defaults.object(forKey: Keys.includeMic) as? Bool ?? true
        context = defaults.string(forKey: Keys.context) ?? ""
        capture.onLevels = { [weak self] system, mic in
            Task { @MainActor in self?.updateLevels(system, mic) }
        }
        capture.onUnexpectedStop = { [weak self] message in
            Task { @MainActor in self?.recordingDied(message) }
        }
        refreshRecent()
    }

    // MARK: - Record

    func toggleRecording() {
        switch phase {
        case .recording: stopRecording()
        case .starting, .processing: break
        default: startRecording()
        }
    }

    func startRecording() {
        guard !isBusy, !isRecording else { return }
        guard environmentReady else {
            warning = "ต้องติดตั้งตัวถอดเสียงก่อน (ครั้งแรกเท่านั้น)"
            return
        }
        phase = .starting
        warning = nil
        summaryPreview = ""
        currentSession = nil

        let app = MeetingApps.detect()
        detectedApp = app
        let now = Date()
        let folderFormat = DateFormatter()
        folderFormat.locale = Locale(identifier: "en_US_POSIX")
        folderFormat.dateFormat = "yyyy-MM-dd_HHmm"
        let prettyFormat = DateFormatter()
        prettyFormat.locale = Locale(identifier: "en_US_POSIX")
        prettyFormat.dateFormat = "yyyy-MM-dd HH:mm"

        let folder = folderFormat.string(from: now) + (app.map { "_" + $0 } ?? "")
        let dir = MeetingPaths.outputRoot.appendingPathComponent(folder, isDirectory: true)
        let title = "\(app ?? "ประชุม") · \(prettyFormat.string(from: now))"
        let started = prettyFormat.string(from: now)
        let wantMic = includeMic

        Task {
            do {
                let micID = wantMic ? MeetingAudioCapture.builtInMicrophoneID() : nil
                let hasMic = try await capture.start(directory: dir, includeMic: wantMic, micDeviceID: micID)
                sessionDir = dir
                sessionTitle = title
                writeMeta(dir, [
                    "title": title, "startedAt": started, "app": app ?? "",
                    "context": context, "hasMic": hasMic,
                ])
                if wantMic && !hasMic {
                    warning = "ยังไม่ได้อนุญาตไมค์ — จะบันทึกเฉพาะเสียงจากประชุม (เปิดได้ที่ System Settings › Microphone)"
                }
                startDate = Date()
                elapsed = 0
                lastSound = Date()
                silenceNotified = false
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "StampLab is recording a meeting")
                startTimer()
                requestNotificationPermission()
                phase = .recording
                liveWorker.start(sessionDir: dir)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func stopRecording() {
        guard phase == .recording, let dir = sessionDir else { return }
        phase = .processing
        stageText = "กำลังบันทึกไฟล์เสียง…"
        progress = 0.02
        stopTimer()
        let duration = elapsed
        liveWorker.stop()
        Task {
            await capture.stop()
            let result = capture.finish()
            endActivity()
            updateMeta(dir, ["duration": duration, "systemPeak": Double(result.systemPeak), "micPeak": Double(result.micPeak)])
            if result.systemSeconds < 3 && result.micSeconds < 3 {
                phase = .failed("บันทึกสั้นเกินไป (น้อยกว่า 3 วินาที)")
                return
            }
            if result.systemPeak < 0.0008 {
                warning = result.micPeak > 0.0008
                    ? "ไม่ได้ยินเสียงจากแอปประชุมเลย — โน้ตจะมาจากไมค์อย่างเดียว (เช็คว่าเสียงประชุมออกจากเครื่องนี้จริง)"
                    : "ไม่ได้ยินเสียงเลย — เช็คสิทธิ์ Screen & System Audio Recording"
            }
            runPipeline(dir: dir)
        }
    }

    private func recordingDied(_ message: String) {
        guard phase == .recording, let dir = sessionDir else { return }
        stopTimer()
        endActivity()
        liveWorker.stop()
        phase = .processing
        warning = "การบันทึกหยุดกะทันหัน (\(message)) — ประมวลผลเท่าที่บันทึกไว้"
        Task {
            let result = capture.finish()
            updateMeta(dir, ["duration": elapsed])
            if result.systemSeconds < 3 && result.micSeconds < 3 {
                phase = .failed("การบันทึกหยุดก่อนมีเสียง: \(message)")
            } else {
                runPipeline(dir: dir)
            }
        }
    }

    // MARK: - Process

    /// Transcribe + summarise an existing session folder (also used to retry).
    func runPipeline(dir: URL, summarizeOnly: Bool = false) {
        phase = .processing
        progress = max(progress, 0.03)
        stageText = "กำลังเตรียมถอดเสียง…"
        sessionDir = dir
        let meta = readMeta(dir)
        let title = (meta["title"] as? String) ?? dir.lastPathComponent
        let ctx = (meta["context"] as? String) ?? context
        pipeline.run(
            sessionDir: dir, title: title, context: ctx, summarizeOnly: summarizeOnly,
            onProgress: { [weak self] p in
                Task { @MainActor in
                    self?.stageText = p.message
                    self?.progress = max(self?.progress ?? 0, p.pct / 100)
                    self?.dumpStatus()
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in self?.pipelineFinished(dir: dir, title: title, result: result) }
            })
    }

    private func pipelineFinished(dir: URL, title: String, result: Swift.Result<PipelineOutput, Error>) {
        refreshRecent()
        switch result {
        case .success(let output):
            let session = Self.session(at: dir)
                ?? MeetingSession(url: dir, date: Date(), title: title, hasNotes: output.notes != nil,
                                  hasTranscript: true, hasAudio: true)
            currentSession = session
            summaryPreview = Self.previewOfNotes(at: session.notesURL)
            progress = 1
            stageText = "เสร็จแล้ว"
            phase = .done
            notify(title: "โน้ตประชุมพร้อมแล้ว",
                   body: summaryPreview.isEmpty ? title : String(summaryPreview.prefix(120)),
                   path: (output.notes ?? output.transcript)?.path)
        case .failure(let error):
            currentSession = Self.session(at: dir)
            phase = .failed(error.localizedDescription)
            notify(title: "ประมวลผลประชุมไม่สำเร็จ", body: "ไฟล์เสียงยังอยู่ กด ลองใหม่ ในหน้าต่าง Meeting", path: dir.path)
        }
    }

    func cancelProcessing() {
        pipeline.cancel()
    }

    func reset() {
        if case .processing = phase { return }
        if phase == .recording { return }
        phase = .idle
        warning = nil
    }

    // MARK: - Outputs

    func openNotes() {
        guard let s = currentSession else { return }
        NSWorkspace.shared.open(s.hasNotes ? s.notesURL : s.transcriptURL)
    }

    func copyNotes() {
        guard let s = currentSession,
              let text = try? String(contentsOf: s.hasNotes ? s.notesURL : s.transcriptURL, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reveal(_ session: MeetingSession? = nil) {
        guard let url = (session ?? currentSession)?.url ?? sessionDir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ session: MeetingSession) {
        NSWorkspace.shared.open(session.hasNotes ? session.notesURL : session.transcriptURL)
    }

    func reprocess(_ session: MeetingSession) {
        guard !isBusy, !isRecording else { return }
        currentSession = session
        progress = 0
        runPipeline(dir: session.url, summarizeOnly: session.hasTranscript && !session.hasAudio)
    }

    // MARK: - Import an existing recording

    /// Files dropped on the card (or picked with "เลือกไฟล์…"): the audio is
    /// copied into a new session folder and run through the normal pipeline,
    /// so an old recording ends up with the same transcript + notes.
    func importFiles(_ urls: [URL]) {
        guard !isRecording else {
            warning = "กำลังบันทึกประชุมอยู่ — หยุดก่อนแล้วค่อยวางไฟล์"
            return
        }
        guard !isBusy else {
            warning = "กำลังประมวลผลอยู่ รอให้เสร็จก่อนแล้วค่อยวางไฟล์ถัดไป"
            return
        }
        guard environmentReady else {
            warning = "ต้องติดตั้งตัวถอดเสียงก่อน (ครั้งแรกเท่านั้น)"
            return
        }
        let usable = urls.filter { MeetingImport.isSupported($0) }
        guard let source = usable.first else {
            warning = MeetingImport.rejectionMessage(for: urls)
            return
        }

        warning = usable.count > 1
            ? "วางมาหลายไฟล์ — ถอดไฟล์แรกก่อน (\(source.lastPathComponent)) แล้วค่อยวางไฟล์ถัดไป"
            : nil
        summaryPreview = ""
        currentSession = nil
        detectedApp = nil
        phase = .processing
        progress = 0.01
        stageText = "กำลังเตรียมไฟล์เสียง…"

        let now = Date()
        let dir = MeetingImport.uniqueFolder(
            in: MeetingPaths.outputRoot,
            named: MeetingImport.folderName(for: source, date: now),
            exists: { FileManager.default.fileExists(atPath: $0.path) })
        let title = MeetingImport.title(for: source, date: now)
        let prettyFormat = DateFormatter()
        prettyFormat.locale = Locale(identifier: "en_US_POSIX")
        prettyFormat.dateFormat = "yyyy-MM-dd HH:mm"
        let started = prettyFormat.string(from: now)
        let ctx = context

        Task {
            do {
                try await MeetingAudioImporter.prepare(source: source, in: dir)
                writeMeta(dir, [
                    "title": title, "startedAt": started, "app": "",
                    "context": ctx, "hasMic": false, "importedFrom": source.path,
                ])
                refreshRecent()
                runPipeline(dir: dir)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The same import, for people who would rather click than drag.
    func chooseFileToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = Array(MeetingImport.supportedExtensions)
        panel.prompt = "ถอดเสียง"
        panel.message = "เลือกไฟล์เสียงหรือวิดีโอที่ต้องการถอดเสียงและสรุป"
        panel.level = .popUpMenu  // above the floating panel
        if panel.runModal() == .OK, let url = panel.url {
            importFiles([url])
        }
    }

    // MARK: - Install

    func install() {
        guard !isInstalling else { return }
        isInstalling = true
        installLog = ["เริ่มติดตั้ง — ครั้งแรกใช้เวลา ~5–10 นาที (ดาวน์โหลด ~2.5GB)"]
        installer.run(
            onLine: { [weak self] line in
                Task { @MainActor in
                    guard let self else { return }
                    self.installLog.append(line)
                    if self.installLog.count > 60 { self.installLog.removeFirst(self.installLog.count - 60) }
                }
            },
            completion: { [weak self] ok in
                Task { @MainActor in
                    guard let self else { return }
                    self.isInstalling = false
                    self.environmentReady = MeetingPaths.environmentReady
                    if !ok || !self.environmentReady {
                        self.warning = "ติดตั้งไม่สำเร็จ — ดูบรรทัดสุดท้ายของ log แล้วลองใหม่"
                    } else {
                        self.warning = nil
                    }
                }
            })
    }

    // MARK: - Recent sessions

    func refreshRecent() {
        environmentReady = MeetingPaths.environmentReady
        let root = MeetingPaths.outputRoot
        // Directory scans happen off the main thread: a protected folder can
        // stall on a system permission prompt.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sessions = Self.scan(root: root)
            Task { @MainActor in self?.recent = sessions }
        }
    }

    nonisolated private static func scan(root: URL) -> [MeetingSession] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let sessions = items.compactMap { session(at: $0) }
        return Array(sessions.sorted { $0.date > $1.date }.prefix(5))
    }

    nonisolated static func session(at url: URL) -> MeetingSession? {
        let fm = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd_HHmm"
        let name = url.lastPathComponent
        guard name.count >= 15, let date = format.date(from: String(name.prefix(15))) else { return nil }
        var title = name
        if let data = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = json["title"] as? String { title = t }
        return MeetingSession(
            url: url, date: date, title: title,
            hasNotes: fm.fileExists(atPath: MeetingSession.pick(url, "สรุป.md", "notes.md").path),
            hasTranscript: fm.fileExists(atPath: MeetingSession.pick(url, "ข้อความถอดเสียง.md", "transcript.md").path),
            hasAudio: fm.fileExists(atPath: MeetingSession.pick(url, "เสียงประชุม.caf", "system.caf").path)
                || fm.fileExists(atPath: url.appendingPathComponent("เสียงประชุม.m4a").path)
                || fm.fileExists(atPath: url.appendingPathComponent("เสียงไมค์.m4a").path)
                || fm.fileExists(atPath: MeetingSession.pick(url, "เสียงไมค์.caf", "mic.caf").path))
    }

    // MARK: - Timer / levels

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        systemLevel = 0
        micLevel = 0
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func tick() {
        guard phase == .recording, let startDate else { return }
        elapsed = Date().timeIntervalSince(startDate)
        if Date().timeIntervalSince(lastSound) > 600, !silenceNotified {
            silenceNotified = true
            notify(title: "เงียบมา 10 นาทีแล้ว",
                   body: "ประชุมจบแล้วหรือยัง? กด ⌃⌥⌘R เพื่อหยุดและสรุป", path: nil)
        }
    }

    private func updateLevels(_ system: Float, _ mic: Float) {
        guard phase == .recording else { return }
        systemLevel = system
        micLevel = mic
        if system > 0.12 || mic > 0.12 {
            lastSound = Date()
            silenceNotified = false
        }
    }

    // MARK: - Meta + notifications

    /// Mirrors the state to a small JSON file so scripts (and I, when testing)
    /// can see what the recorder is doing without looking at the UI.
    private func dumpStatus() {
        let dict: [String: Any] = [
            "phase": String(describing: phase), "stage": stageText, "progress": progress,
            "warning": warning ?? "", "session": sessionDir?.path ?? "",
            "updated": ISO8601DateFormatter().string(from: Date()),
        ]
        try? FileManager.default.createDirectory(at: MeetingPaths.support, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: MeetingPaths.support.appendingPathComponent("meeting-status.json"))
        }
    }

    private func readMeta(_ dir: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private func writeMeta(_ dir: URL, _ meta: [String: Any]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }

    private func updateMeta(_ dir: URL, _ extra: [String: Any]) {
        var meta = readMeta(dir)
        for (k, v) in extra { meta[k] = v }
        writeMeta(dir, meta)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String, path: String?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let path { content.userInfo = ["path": path] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// First lines of the "สรุปสั้น" section, for the done card.
    static func previewOfNotes(at url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## สรุปสั้น") }) else {
            return String(text.prefix(300))
        }
        var out: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { out.append(line) }
        }
        return out.joined(separator: "\n")
    }
}
