import AVFoundation
import Foundation

struct DecodedAudio {
    let samples: [Float]
    let duration: Double
}

enum AudioDecoderError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "ไฟล์นี้ไม่มีเสียงอยู่ข้างใน ลองไฟล์อื่นที่มีเสียงพูด"
        case .readerFailed(let reason): return "เปิดไฟล์เสียงไม่ได้ (\(reason)) — ถ้าเปิดใน QuickTime ได้ ลองแปลงเป็น .m4a ก่อน"
        }
    }
}

/// Decodes any AVFoundation-readable container (m4a, mp3, wav, caf, mp4, mov, …)
/// straight to the 16 kHz mono float samples Whisper expects — no ffmpeg needed.
enum AudioDecoder {
    static let sampleRate = 16_000.0

    static func decode(url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioDecoderError.noAudioTrack
        }
        let assetDuration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioDecoderError.readerFailed("รูปแบบเสียงนี้แปลงไม่ได้")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioDecoderError.readerFailed(reader.error?.localizedDescription ?? "ไม่ทราบสาเหตุ")
        }

        var samples = [Float]()
        if assetDuration.isFinite, assetDuration > 0 {
            samples.reserveCapacity(Int(assetDuration * sampleRate))
        }
        var lastReported = 0.0

        while let buffer = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                         totalLengthOut: &length, dataPointerOut: &pointer)
                if status == kCMBlockBufferNoErr, let pointer {
                    let count = length / MemoryLayout<Float>.size
                    pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                        samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
                    }
                }
            }
            CMSampleBufferInvalidate(buffer)

            if assetDuration > 0 {
                let fraction = Double(samples.count) / sampleRate / assetDuration
                if fraction - lastReported > 0.02 {
                    lastReported = fraction
                    onProgress(min(fraction, 1))
                }
            }
        }

        if reader.status == .failed {
            throw AudioDecoderError.readerFailed(reader.error?.localizedDescription ?? "ไม่ทราบสาเหตุ")
        }
        onProgress(1)

        let duration = assetDuration.isFinite && assetDuration > 0
            ? assetDuration
            : Double(samples.count) / sampleRate
        return DecodedAudio(samples: samples, duration: duration)
    }
}
