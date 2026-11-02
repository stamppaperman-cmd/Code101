import AVFoundation
import Foundation
import Testing
@testable import StampLabLogic

/// Runs real files through the importer the app uses, so a broken conversion
/// shows up here instead of after a 20-minute meeting.
@Suite("แปลงไฟล์ที่ลากมาวางให้พร้อมถอดเสียง", .serialized)
struct MeetingAudioImporterTests {
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meeting-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A couple of seconds of a sine tone as a 16 kHz mono PCM .wav, written
    /// byte by byte so the test depends on nothing but Foundation.
    private func makeTone(at url: URL, seconds: Double = 2) throws {
        let rate = 16_000
        let count = Int(Double(rate) * seconds)
        var samples = Data(capacity: count * 2)
        for i in 0..<count {
            let value = Int16(12_000 * sin(2 * .pi * 440 * Double(i) / Double(rate)))
            samples.append(UInt8(truncatingIfNeeded: value))
            samples.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func le32(_ v: Int) -> Data { Data([0, 8, 16, 24].map { UInt8(truncatingIfNeeded: v >> $0) }) }
        func le16(_ v: Int) -> Data { Data([0, 8].map { UInt8(truncatingIfNeeded: v >> $0) }) }

        var wav = Data("RIFF".utf8)
        wav += le32(36 + samples.count)
        wav += Data("WAVEfmt ".utf8)
        wav += le32(16) + le16(1) + le16(1)          // PCM, mono
        wav += le32(rate) + le32(rate * 2)           // sample rate, byte rate
        wav += le16(2) + le16(16)                    // block align, bits
        wav += Data("data".utf8) + le32(samples.count) + samples
        try wav.write(to: url)
    }

    private func duration(of url: URL) async throws -> Double {
        let value = try await AVURLAsset(url: url).load(.duration)
        return CMTimeGetSeconds(value)
    }

    @Test("ไฟล์ wav แปลงเป็น เสียงประชุม.m4a ที่เล่นได้และยาวเท่าเดิม")
    func convertsWav() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tone.wav")
        try makeTone(at: source)

        let dest = try await MeetingAudioImporter.prepare(source: source, in: dir.appendingPathComponent("session"))

        #expect(dest.lastPathComponent == "เสียงประชุม.m4a")
        #expect(FileManager.default.fileExists(atPath: dest.path))
        let seconds = try await duration(of: dest)
        #expect(abs(seconds - 2) < 0.3)

        // 16 kHz mono = afconvert did the work; the AVFoundation fallback
        // would have written 44.1 kHz, so this also catches a silent swap
        // to the slow path.
        let track = try #require(try await AVURLAsset(url: dest).loadTracks(withMediaType: .audio).first)
        let description = try await track.load(.formatDescriptions).first
        let basic = CMAudioFormatDescriptionGetStreamBasicDescription(try #require(description))
        #expect(basic?.pointee.mSampleRate == 16_000)
        #expect(basic?.pointee.mChannelsPerFrame == 1)
    }

    @Test("ไฟล์ m4a คัดลอกตรง ๆ ไม่แปลงซ้ำ")
    func copiesM4A() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("tone.wav")
        try makeTone(at: wav)
        let m4a = dir.appendingPathComponent("tone.m4a")
        #expect(MeetingAudioImporter.runAfconvert(wav, m4a))

        let session = dir.appendingPathComponent("session")
        let dest = try await MeetingAudioImporter.prepare(source: m4a, in: session)

        let a = try Data(contentsOf: m4a), b = try Data(contentsOf: dest)
        #expect(a == b)  // byte-for-byte: no second lossy pass
    }

    @Test("วางไฟล์เดิมซ้ำลงโฟลเดอร์เดิม ทับของเก่าได้ ไม่ error")
    func overwrites() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tone.wav")
        try makeTone(at: source)
        let session = dir.appendingPathComponent("session")
        _ = try await MeetingAudioImporter.prepare(source: source, in: session)
        let dest = try await MeetingAudioImporter.prepare(source: source, in: session)
        #expect(MeetingAudioImporter.looksUsable(dest))
    }

    @Test("ไฟล์ที่ไม่ใช่เสียง ได้ error ภาษาคน ไม่ทิ้งไฟล์เสียงปลอมไว้")
    func rejectsGarbage() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("notes.wav")
        try Data(repeating: 0x41, count: 50_000).write(to: fake)
        let session = dir.appendingPathComponent("session")

        await #expect(throws: MeetingImportError.self) {
            try await MeetingAudioImporter.prepare(source: fake, in: session)
        }
        #expect(!FileManager.default.fileExists(
            atPath: session.appendingPathComponent("เสียงประชุม.m4a").path))
    }
}
