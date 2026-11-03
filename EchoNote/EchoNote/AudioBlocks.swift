import Foundation

/// Splitting decisions about the sample buffer, kept apart from `TranscriptionEngine`
/// so they can be tested without loading a 2.9 GB CoreML model. Nothing here imports
/// WhisperKit; everything is a pure function over sample indices.
enum AudioBlocks {
    /// Roughly ten minutes of audio per block. Short enough that one CoreML fault is
    /// cheap, long enough that the cuts stay rare.
    static let blockSeconds = 600.0

    /// A block boundary lands in a pause rather than through the middle of a word,
    /// so it is nudged to the quietest frame near the target.
    static let searchRadiusSeconds = 20.0

    /// Never leave a final block shorter than this — a two-second tail is its own
    /// decode with its own overhead and nothing useful in it.
    static let minimumTailSeconds = 60.0

    /// Boundaries for the whole file. One range for anything short enough that
    /// splitting buys nothing.
    static func blockRanges(sampleCount: Int,
                            sampleRate: Double,
                            energyAt: (Int, Int) -> Int) -> [Range<Int>] {
        let rate = Int(sampleRate)
        let block = Int(blockSeconds * sampleRate)
        let tail = Int(minimumTailSeconds * sampleRate)
        guard sampleCount > block + tail else { return [0..<sampleCount] }

        var bounds = [0]
        var target = block
        while target < sampleCount - tail {
            let cut = energyAt(target, Int(searchRadiusSeconds * sampleRate))
            // A boundary that lands too close to the previous one would create a
            // block too short to be worth its own decode.
            if cut > bounds[bounds.count - 1] + 30 * rate { bounds.append(cut) }
            target += block
        }
        bounds.append(sampleCount)
        return zip(bounds, bounds.dropFirst()).map { $0..<$1 }
    }

    /// Index of the quietest 20 ms frame within `radius` of `target`.
    static func quietestCut(in samples: [Float], near target: Int, radius: Int, sampleRate: Double) -> Int {
        let low = max(target - radius, 0)
        let high = min(target + radius, samples.count)
        let frame = max(Int(sampleRate) / 50, 1)
        guard high - low > frame else { return min(max(target, 0), samples.count) }

        var bestIndex = target
        var bestEnergy = Double.greatestFiniteMagnitude
        var cursor = low
        while cursor + frame <= high {
            var energy = 0.0
            for index in cursor..<(cursor + frame) {
                energy += Double(samples[index]) * Double(samples[index])
            }
            if energy < bestEnergy {
                bestEnergy = energy
                bestIndex = cursor + frame / 2
            }
            cursor += frame
        }
        return bestIndex
    }

    /// Stretches of audio that no segment covers. Whisper skips audio without saying
    /// so, so this is what `fillGaps` walks and what the coverage figure is built on.
    static func uncoveredRanges(in segments: [Segment],
                                duration: Double,
                                minimumSeconds: Double) -> [(start: Double, end: Double)] {
        var ranges = [(start: Double, end: Double)]()
        var cursor = 0.0
        for segment in segments.sorted(by: { $0.startMS < $1.startMS }) {
            let start = Double(segment.startMS) / 1000
            if start - cursor >= minimumSeconds {
                ranges.append((cursor, start))
            }
            cursor = max(cursor, Double(segment.endMS) / 1000)
        }
        if duration - cursor >= minimumSeconds {
            ranges.append((cursor, duration))
        }
        return ranges
    }
}
