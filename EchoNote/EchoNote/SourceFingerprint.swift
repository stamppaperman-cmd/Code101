import Foundation
import CryptoKit

/// Dropping the same recording in twice costs a full hour of compute and produces a
/// second copy of an answer you already have. It happened once during development.
///
/// Hashing a whole video to prevent that would itself be slow, so this reads the
/// size and the two ends of the file. Two different recordings sharing a byte count
/// *and* both four-megabyte ends is not a case worth engineering for; two drops of
/// the same file always match.
enum SourceFingerprint {
    private static let edgeBytes = 4 * 1_024 * 1_024

    static func of(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        guard let size, size > 0 else { return nil }

        var hasher = SHA256()
        withUnsafeBytes(of: Int64(size).littleEndian) { hasher.update(bufferPointer: $0) }

        guard let head = try? handle.read(upToCount: min(edgeBytes, size)) else { return nil }
        hasher.update(data: head)

        if size > edgeBytes {
            let tailStart = UInt64(max(size - edgeBytes, edgeBytes))
            try? handle.seek(toOffset: tailStart)
            if let tail = try? handle.readToEnd() { hasher.update(data: tail) }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
