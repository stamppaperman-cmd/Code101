import Foundation

/// Where the meeting tooling lives on disk.
enum MeetingPaths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OverlayLens", isDirectory: true)
    }
    static var venv: URL { support.appendingPathComponent("meeting-venv", isDirectory: true) }
    static var python: URL { venv.appendingPathComponent("bin/python") }
    static var script: URL? { Bundle.main.url(forResource: "meeting_notes", withExtension: "py") }

    /// Sessions (audio + transcript + notes) live here; change it with
    /// `defaults write com.overlaylens.OverlayLens MeetingOutputDir /some/path`
    /// (a folder outside Desktop/Documents/Downloads avoids permission prompts).
    static var outputRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: "MeetingOutputDir"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        // Not ~/Documents: that folder is TCC-protected, and the first access
        // freezes the app behind a system permission prompt.
        return support.appendingPathComponent("Meetings", isDirectory: true)
    }

    /// True once the venv has the ASR stack installed.
    static var environmentReady: Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        let lib = venv.appendingPathComponent("lib")
        guard let pythons = try? FileManager.default.contentsOfDirectory(atPath: lib.path) else { return false }
        return pythons.contains { name in
            FileManager.default.fileExists(
                atPath: lib.appendingPathComponent("\(name)/site-packages/transformers").path)
                && FileManager.default.fileExists(
                    atPath: lib.appendingPathComponent("\(name)/site-packages/torch").path)
        }
    }

    static var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        return env
    }
}

struct PipelineProgress {
    var stage: String
    var pct: Double
    var message: String
}

struct PipelineOutput {
    var notes: URL?
    var transcript: URL?
}

enum PipelineError: LocalizedError {
    case notInstalled
    case scriptMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "ยังไม่ได้ติดตั้งตัวถอดเสียง (ครั้งแรกเท่านั้น)"
        case .scriptMissing: return "ไม่พบ meeting_notes.py ในแอป — build ใหม่อีกครั้ง"
        case .failed(let message): return message
        }
    }
}

/// Runs `meeting_notes.py` for one session folder and relays its progress.
final class MeetingPipeline {
    private var process: Process?

    func run(
        sessionDir: URL,
        title: String,
        context: String,
        summarize: Bool = true,
        summarizeOnly: Bool = false,
        onProgress: @escaping (PipelineProgress) -> Void,
        completion: @escaping (Swift.Result<PipelineOutput, Error>) -> Void
    ) {
        guard MeetingPaths.environmentReady else { return completion(.failure(PipelineError.notInstalled)) }
        guard let script = MeetingPaths.script else { return completion(.failure(PipelineError.scriptMissing)) }

        var args = [script.path, sessionDir.path, "--title", title]
        if !context.isEmpty { args += ["--context", context] }
        if !summarize { args.append("--skip-summary") }
        if summarizeOnly { args.append("--summarize-only") }

        let process = Process()
        process.executableURL = MeetingPaths.python
        process.arguments = args
        process.environment = MeetingPaths.processEnvironment
        process.qualityOfService = .userInitiated

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let logURL = sessionDir.appendingPathComponent("บันทึกระบบ.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        let lock = NSLock()
        var buffer = Data()
        var output = PipelineOutput()
        var errorMessage: String?

        func handleLine(_ line: String) {
            try? log?.write(contentsOf: Data((line + "\n").utf8))
            guard line.hasPrefix("@@") else { return }
            let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let data = parts[1].data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            switch parts[0] {
            case "STATUS":
                let progress = PipelineProgress(
                    stage: json["stage"] as? String ?? "",
                    pct: (json["pct"] as? NSNumber)?.doubleValue ?? 0,
                    message: json["msg"] as? String ?? "")
                DispatchQueue.main.async { onProgress(progress) }
            case "DONE":
                if let notes = json["notes"] as? String, !notes.isEmpty { output.notes = URL(fileURLWithPath: notes) }
                if let transcript = json["transcript"] as? String, !transcript.isEmpty { output.transcript = URL(fileURLWithPath: transcript) }
            case "ERROR":
                errorMessage = json["msg"] as? String
            default: break
            }
        }

        out.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) { handleLine(line) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            try? log?.write(contentsOf: chunk)
        }

        process.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            if !buffer.isEmpty, let rest = String(data: buffer, encoding: .utf8) { handleLine(rest) }
            lock.unlock()
            try? log?.close()
            DispatchQueue.main.async {
                if proc.terminationStatus == 0, output.transcript != nil {
                    completion(.success(output))
                } else if proc.terminationReason == .uncaughtSignal && proc.terminationStatus == SIGTERM {
                    completion(.failure(PipelineError.failed("ยกเลิกแล้ว")))
                } else {
                    let tail = (try? String(contentsOf: logURL, encoding: .utf8))?
                        .split(separator: "\n").suffix(3).joined(separator: " · ") ?? ""
                    completion(.failure(PipelineError.failed(errorMessage ?? "pipeline ล้มเหลว (\(proc.terminationStatus)) \(tail)")))
                }
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            completion(.failure(error))
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
    }
}

/// Transcribes finished stretches of audio in the background while a meeting is still being recorded,
/// so the final pass only has the tail left. Opt-in: `defaults write com.overlaylens.OverlayLens MeetingLiveEnabled -bool YES`.
/// Killing it at any time is safe — the final pass redoes whatever it had not checkpointed.
final class MeetingLiveWorker {
    static let enabledKey = "MeetingLiveEnabled"
    private var process: Process?

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    func start(sessionDir: URL) {
        guard Self.enabled, MeetingPaths.environmentReady, let script = MeetingPaths.script else { return }
        stop()
        let process = Process()
        process.executableURL = MeetingPaths.python
        process.arguments = [script.path, sessionDir.path, "--live"]
        process.environment = MeetingPaths.processEnvironment
        process.qualityOfService = .background
        let logURL = sessionDir.appendingPathComponent("บันทึกระหว่างอัด.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
        }
    }

    func stop() {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        self.process = nil
    }
}

/// First-run installer: Python venv + torch/transformers + the Thai Whisper model.
/// Uses Homebrew's Python (3.11–3.13); everything stays under Application Support.
final class MeetingInstaller {
    private var process: Process?

    static let script = """
    set -e
    APP="$HOME/Library/Application Support/OverlayLens"
    mkdir -p "$APP"
    PYBIN=""
    for c in python3.12 python3.13 python3.11; do
      for d in /opt/homebrew/bin /usr/local/bin; do
        if [ -x "$d/$c" ]; then PYBIN="$d/$c"; break 2; fi
      done
    done
    if [ -z "$PYBIN" ]; then echo "ERROR: ไม่พบ Python 3.11–3.13 (brew install python@3.12)"; exit 2; fi
    echo "ใช้ $PYBIN"
    [ -x "$APP/meeting-venv/bin/python" ] || "$PYBIN" -m venv "$APP/meeting-venv"
    PY="$APP/meeting-venv/bin/python"
    "$PY" -m pip install -q -U pip
    echo "กำลังติดตั้ง torch / transformers …"
    "$PY" -m pip install -q torch transformers accelerate soundfile numpy requests
    echo "กำลังดาวน์โหลดโมเดล Typhoon Whisper (~1.6GB) …"
    "$PY" -c "from huggingface_hub import snapshot_download; print(snapshot_download('typhoon-ai/typhoon-whisper-turbo'))"
    echo "เสร็จแล้ว"
    """

    func run(onLine: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", Self.script]
        process.environment = MeetingPaths.processEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                DispatchQueue.main.async { onLine(String(line)) }
            }
        }
        process.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { completion(proc.terminationStatus == 0) }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            onLine("ERROR: \(error.localizedDescription)")
            completion(false)
        }
    }
}
