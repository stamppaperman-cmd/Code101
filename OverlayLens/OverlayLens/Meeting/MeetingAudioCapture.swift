import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Records everything the Mac plays (Zoom, Teams, Discord, LINE, browser tabs…)
/// plus the microphone, as two 16 kHz mono files that the speech recogniser can
/// read directly.
///
/// ScreenCaptureKit taps the system mix *before* it reaches the output device,
/// so it doesn't matter whether the sound goes to AirPods Max or the speakers.
final class MeetingAudioCapture: NSObject {
    enum CaptureError: LocalizedError {
        case noScreenPermission
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .noScreenPermission:
                return "ยังไม่ได้อนุญาต Screen & System Audio Recording — เปิดที่ System Settings › Privacy & Security แล้วลองใหม่"
            case .noDisplay:
                return "ไม่พบจอภาพสำหรับจับเสียงระบบ"
            }
        }
    }

    struct Result {
        var systemSeconds: Double
        var micSeconds: Double
        var systemPeak: Float
        var micPeak: Float
        var hasMic: Bool
    }

    /// 0…1 meter values, delivered on the main queue ~10×/s.
    var onLevels: ((Float, Float) -> Void)?
    /// The stream died on its own (display sleep, permission revoked…).
    var onUnexpectedStop: ((String) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "OverlayLens.meeting.audio", qos: .userInitiated)
    private var system: AudioSink?
    private var mic: AudioSink?
    private var origin: Double?          // seconds; first timestamp seen on either stream
    private var stopping = false
    private var lastLevelPush = Date.distantPast
    private(set) var hasMic = false

    // MARK: - Devices

    /// The MacBook's own microphone. Using it (instead of AirPods' mic) keeps
    /// AirPods in the high-quality playback profile during the call.
    static func builtInMicrophoneID() -> String? {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        return session.devices.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn })?.uniqueID
    }

    // MARK: - Lifecycle

    /// Returns `true` when the microphone is part of the recording.
    @discardableResult
    func start(directory: URL, includeMic: Bool, micDeviceID: String?) async throws -> Bool {
        await stop()

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw CaptureError.noScreenPermission
        }

        var micAllowed = includeMic
        if includeMic {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined: micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            default: micAllowed = false
            }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.noScreenPermission
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        // Audio only: keep the (unavoidable) video side as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 3
        if micAllowed {
            config.captureMicrophone = true
            if let micDeviceID { config.microphoneCaptureDeviceID = micDeviceID }
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        system = AudioSink(url: directory.appendingPathComponent("เสียงประชุม.caf"))
        mic = micAllowed ? AudioSink(url: directory.appendingPathComponent("เสียงไมค์.caf")) : nil
        origin = nil

        do {
            try await begin(filter: filter, config: config, withMic: micAllowed)
            hasMic = micAllowed
        } catch {
            // The microphone is a bonus: if it can't start, still record the call.
            guard micAllowed else { throw error }
            config.captureMicrophone = false
            mic = nil
            try await begin(filter: filter, config: config, withMic: false)
            hasMic = false
        }
        return hasMic
    }

    private func begin(filter: SCContentFilter, config: SCStreamConfiguration, withMic: Bool) async throws {
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if withMic {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        // Frames are discarded, but registering an output stops the framework
        // from logging a "dropping frame" line every second.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        stopping = true
        try? await stream.stopCapture()
        stopping = false
    }

    /// Flushes both files and reports what was captured. Call after `stop()`.
    func finish() -> Result {
        queue.sync {
            system?.close()
            mic?.close()
        }
        let result = Result(
            systemSeconds: system?.seconds ?? 0,
            micSeconds: mic?.seconds ?? 0,
            systemPeak: system?.peak ?? 0,
            micPeak: mic?.peak ?? 0,
            hasMic: hasMic
        )
        system = nil
        mic = nil
        return result
    }

    // MARK: - Levels

    private func pushLevels() {
        let now = Date()
        guard now.timeIntervalSince(lastLevelPush) > 0.1 else { return }
        lastLevelPush = now
        let s = Self.meter(system?.lastRMS ?? 0)
        let m = Self.speechMeter(mic?.lastRMS ?? 0)
        DispatchQueue.main.async { [weak self] in self?.onLevels?(s, m) }
    }

    /// Mic meter: stays at 0 for room noise, moves only when actually speaking
    /// (gate at −42 dB, full scale at −12 dB). Display only; recording is unchanged.
    static func speechMeter(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 42) / 30))
    }

    /// RMS → 0…1 on a −60…0 dB scale.
    static func meter(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return max(0, min(1, (20 * log10(rms) + 60) / 60))
    }
}

// MARK: - SCStream

extension MeetingAudioCapture: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio:
            let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if origin == nil, t.isFinite { origin = t }
            system?.append(sampleBuffer, origin: origin)
        case .microphone:
            let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if origin == nil, t.isFinite { origin = t }
            mic?.append(sampleBuffer, origin: origin)
        default:
            return
        }
        pushLevels()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopping else { return }
        self.stream = nil
        DispatchQueue.main.async { [weak self] in
            self?.onUnexpectedStop?(error.localizedDescription)
        }
    }
}

// MARK: - File writer

/// Appends sample buffers to a 16-bit mono CAF (crash-tolerant container).
/// Keeps the file on the wall clock: if the source goes quiet and stops
/// delivering buffers, the gap is filled with silence so timestamps in the
/// transcript still match the real meeting time.
private final class AudioSink {
    let url: URL
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private(set) var lastRMS: Float = 0
    private(set) var peak: Float = 0

    var seconds: Double { Double(framesWritten) / 16000 }

    init(url: URL) { self.url = url }

    func append(_ sampleBuffer: CMSampleBuffer, origin: Double?) {
        guard let input = Self.pcmBuffer(from: sampleBuffer),
              let converted = convert(input), converted.frameLength > 0 else { return }

        // Keep the timeline honest (only for plausible gaps: 0.2 s … 30 s).
        if let origin {
            let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if t.isFinite {
                let expected = Int64((t - origin) * 16000)
                let gap = expected - framesWritten
                if gap > 3200 && gap < 16000 * 30 {
                    writeSilence(frames: AVAudioFrameCount(gap))
                }
            }
        }

        let rms = Self.rms(converted)
        lastRMS = rms
        peak = max(peak, rms)
        write(converted)
    }

    func close() { file = nil }

    private func writeSilence(frames: AVAudioFrameCount) {
        let chunk: AVAudioFrameCount = 16000
        var left = frames
        while left > 0 {
            let n = min(left, chunk)
            guard let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: n) else { return }
            buf.frameLength = n            // freshly allocated buffers are zero-filled
            write(buf)
            left -= n
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        do {
            if file == nil {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 16000.0,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                    ],
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            }
            try file?.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            NSLog("OverlayLens meeting: write failed: \(error.localizedDescription)")
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let f = input.format
        if f.sampleRate == 16000, f.channelCount == 1, f.commonFormat == .pcmFormatFloat32, !f.isInterleaved {
            return input
        }
        if converter == nil || converterInput != f {
            converter = AVAudioConverter(from: f, to: outFormat)
            converterInput = f
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * outFormat.sampleRate / f.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        return status == .error ? nil : out
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}
