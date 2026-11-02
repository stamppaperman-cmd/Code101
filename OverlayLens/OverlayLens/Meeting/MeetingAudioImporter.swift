import AVFoundation
import Foundation

/// Puts a dropped file into a session folder as `เสียงประชุม.m4a`, the name
/// `meeting_notes.py` looks for. Kept apart from the view model so the logic
/// tests can run a real file through it.
enum MeetingAudioImporter {
    /// - Returns: the audio file inside `dir`, ready for the pipeline.
    @discardableResult
    static func prepare(source: URL, in dir: URL) async throws -> URL {
        let dest = dir.appendingPathComponent("เสียงประชุม.m4a")
        let done = try await Task.detached(priority: .userInitiated) { () -> Bool in
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            if !MeetingImport.needsTranscode(source) {
                try fm.copyItem(at: source, to: dest)
                return looksUsable(dest)
            }
            return runAfconvert(source, dest)
        }.value
        if done { return dest }
        try await exportAudioTrack(from: source, to: dest)
        return dest
    }

    /// `afconvert` reads everything Core Audio understands (mp3, wav, caf,
    /// aiff, flac…). 16 kHz mono is what the recogniser works at anyway, and
    /// AAC refuses a bitrate that high for one narrow-band channel, so the
    /// output is pinned to the same 32 kbps the recorder's own files get.
    static func runAfconvert(_ source: URL, _ dest: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [source.path, dest.path, "-f", "m4af", "-d", "aac@16000", "-b", "32000", "-c", "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        let ok = process.terminationStatus == 0 && looksUsable(dest)
        if !ok { try? FileManager.default.removeItem(at: dest) }
        return ok
    }

    /// Fallback for what afconvert cannot open (a .mov screen recording, say):
    /// pull the audio track out with AVFoundation.
    static func exportAudioTrack(from source: URL, to dest: URL) async throws {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !tracks.isEmpty else { throw MeetingImportError.noAudioTrack(name) }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingImportError.decodeFailed(name)
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try await session.export(to: dest, as: .m4a)
        } catch {
            throw MeetingImportError.decodeFailed(name)
        }
        guard looksUsable(dest) else { throw MeetingImportError.decodeFailed(name) }
    }

    /// Enough bytes to be audio rather than an empty container: a few
    /// seconds of 32 kbps AAC is already several kilobytes.
    static func looksUsable(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 1024
    }
}
