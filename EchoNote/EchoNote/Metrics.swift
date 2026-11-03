import Foundation

/// Measurement, kept apart from every engine so that the numbers used to decide
/// architecture are themselves testable. Nothing here imports WhisperKit, loads a
/// model or touches the disk.
///
/// The reason this file exists at all: **`coverage` alone can be gamed by the exact
/// failure it is meant to catch.** A model that invents fluent Thai for a silent
/// stretch scores 100% coverage and is wrong everywhere. So coverage is never
/// reported on its own — `signals(for:duration:)` returns it bolted to the
/// hallucination counters, and they must be read together or not at all.
enum Metrics {

    // MARK: - Normalisation

    /// Whisper's spacing in Thai is arbitrary: it emits a space where a phrase feels
    /// like it ends, not where the language puts one, and Thai has no word boundary
    /// to be right or wrong about in the first place. Comparing raw strings would
    /// therefore measure spacing noise instead of transcription error, so both sides
    /// are reduced to their characters before any distance is taken.
    ///
    /// Grapheme clusters, not scalars: a Thai tone mark is not an error of its own,
    /// it is part of the character it sits on. Counting scalars would charge two or
    /// three errors for one wrong letter.
    static func normalized(_ text: String) -> [Character] {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            scalars.append(scalar)
        }
        return Array(String(scalars))
    }

    // MARK: - Distance

    /// Levenshtein over two rows. Exact, and O(n·m) in time — which is the right
    /// trade for the fixtures this is built for (minutes of audio, a few thousand
    /// characters) and the wrong one for comparing two hour-long transcripts. For
    /// that, diff the two and adjudicate the disagreements; do not call this.
    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Character error rate — the metric for Thai, because word error rate needs word
    /// boundaries and Thai has none. This is the same reasoning that put character
    /// trigrams in `Lexical`: the unit that exists is the character.
    ///
    /// Can exceed 1.0, and that is not a bug. A model that hallucinates three times
    /// the reference length scores above 1, which is the honest description of it.
    static func cer(reference: String, hypothesis: String) -> Double {
        let reference = normalized(reference)
        let hypothesis = normalized(hypothesis)
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        return Double(editDistance(reference, hypothesis)) / Double(reference.count)
    }

    /// Word error rate, for space-delimited content only. Kept because an English or
    /// mixed fixture is still worth measuring; **do not report it for Thai** — every
    /// space Whisper guesses differently counts as two errors and the number becomes
    /// noise wearing a familiar name.
    static func wer(reference: String, hypothesis: String) -> Double {
        let reference = reference.split(whereSeparator: \.isWhitespace).map(String.init)
        let hypothesis = hypothesis.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        return Double(editDistance(reference, hypothesis)) / Double(reference.count)
    }

    // MARK: - Signals that need no reference

    struct Repetition: Equatable {
        let text: String
        let count: Int
    }

    /// Whisper loops. Handed silence, music or noise it emits the same phrase back to
    /// back until the window runs out — the failure mode that looks most like success,
    /// because every line is well-formed Thai and the timestamps march along normally.
    ///
    /// Only *immediate* repetition is reported. A phrase that recurs across an hour is
    /// a person with a verbal tic; the same phrase four times in a row is a decoder
    /// that stopped listening.
    static func repetitions(in text: String,
                            minimumLength: Int = 4,
                            minimumRepeats: Int = 3,
                            maximumPeriod: Int = 40) -> [Repetition] {
        let characters = normalized(text)
        guard characters.count >= minimumLength * minimumRepeats else { return [] }

        func repeats(at start: Int, period: Int) -> Int {
            var count = 1
            var cursor = start + period
            while cursor + period <= characters.count {
                var matched = true
                for offset in 0..<period where characters[start + offset] != characters[cursor + offset] {
                    matched = false
                    break
                }
                guard matched else { break }
                count += 1
                cursor += period
            }
            return count
        }

        var found = [Repetition]()
        var index = 0
        while index < characters.count {
            let longestPeriod = min(maximumPeriod, (characters.count - index) / minimumRepeats)
            var best: (period: Int, count: Int)?
            if longestPeriod >= minimumLength {
                for period in minimumLength...longestPeriod {
                    let count = repeats(at: index, period: period)
                    guard count >= minimumRepeats else { continue }
                    // Prefer the run that swallows the most text, so `abab abab abab`
                    // is reported once as a 4-character loop rather than twice.
                    if best == nil || period * count > best!.period * best!.count {
                        best = (period, count)
                    }
                }
            }
            if let best {
                found.append(Repetition(text: String(characters[index..<(index + best.period)]),
                                        count: best.count))
                index += best.period * best.count
            } else {
                index += 1
            }
        }
        return found
    }

    /// The cleanup model once leaked `更多人` into a Thai transcript, and Whisper
    /// itself switches script when it loses track of the language. Neither is subtle
    /// once counted, and neither needs a reference transcript to see.
    static func cjkCharacters(in text: String) -> Int {
        text.unicodeScalars.count { scalar in
            switch scalar.value {
            case 0x3040...0x30FF,   // kana
                 0x3400...0x4DBF,   // CJK extension A
                 0x4E00...0x9FFF,   // CJK unified
                 0xAC00...0xD7AF:   // hangul
                return true
            default:
                return false
            }
        }
    }

    // MARK: - One reading of a transcript

    struct QualitySignals {
        let segments: Int
        /// Union of segment spans over the file's duration. Not the same as the count
        /// below: this charges every uncovered second, including the one-second slivers
        /// between segments that no gap pass would ever act on.
        let coveredFraction: Double
        /// Stretches long enough for `fillGaps` to work on, at its own threshold.
        let recoverableStretches: Int
        let recoverableSeconds: Double
        /// `endMS <= startMS` — a segment cut mid-word by the token budget. 56 of these
        /// survived the fix that took coverage from 74.3% to 92.4%, which is why the
        /// two are counted separately.
        let zeroLengthSegments: Int
        let cjkCharacters: Int
        let repetitions: [Repetition]
        let meanConfidence: Double?

        /// Fixed field order so a log line from two runs can be diffed by eye.
        var summary: String {
            let confidence = meanConfidence.map { String(format: "%.2f", $0) } ?? "-"
            let loops = repetitions.reduce(0) { $0 + $1.count }
            return String(format: "segments=%d coverage=%.1f%% gaps=%d/%.0fs zerolen=%d cjk=%d loops=%d conf=%@",
                          segments, coveredFraction * 100, recoverableStretches,
                          recoverableSeconds, zeroLengthSegments, cjkCharacters, loops, confidence)
        }
    }

    static func signals(for segments: [Segment], duration: Double) -> QualitySignals {
        let ordered = segments.sorted { $0.startMS < $1.startMS }

        // Union of spans, walked once. Overlapping segments (diarization and fillGaps
        // both produce them) must not be counted twice or coverage climbs past 100%.
        var covered = 0.0
        var cursor = 0.0
        for segment in ordered {
            let start = Double(segment.startMS) / 1000
            let end = Double(segment.endMS) / 1000
            guard end > cursor else { continue }
            covered += end - max(start, cursor)
            cursor = end
        }

        let gaps = AudioBlocks.uncoveredRanges(in: ordered, duration: duration, minimumSeconds: 6)
        let text = ordered.map(\.text).joined(separator: " ")
        let confidences = ordered.compactMap(\.confidence)

        return QualitySignals(
            segments: ordered.count,
            coveredFraction: duration > 0 ? min(covered / duration, 1) : 0,
            recoverableStretches: gaps.count,
            recoverableSeconds: gaps.reduce(0) { $0 + ($1.end - $1.start) },
            zeroLengthSegments: ordered.count { $0.endMS <= $0.startMS },
            cjkCharacters: cjkCharacters(in: text),
            repetitions: repetitions(in: text),
            meanConfidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        )
    }
}

/// What WhisperKit measured about its own decode.
///
/// `TranscriptionResult.timings` carries all of this on every single call and this app
/// threw it away, leaving a stopwatch around the whole pipeline as the only instrument.
/// A stopwatch cannot tell a slow model apart from a model decoding the same window
/// three times at rising temperatures, and it cannot see parallelism at all.
///
/// The two clocks are the point. `compute` is the sum of what WhisperKit says it spent;
/// `wall` is time that actually passed. Sequentially they are equal. With
/// `concurrentWorkerCount: 4` the compute figure stays put while wall time falls, so
/// `parallelism` reports the speedup directly instead of leaving it to be inferred
/// from two runs on different days.
struct RunTimings: Codable, Sendable {
    var audioSeconds: Double = 0
    var computeSeconds: Double = 0
    var wallSeconds: Double = 0
    var encoding: Double = 0
    var decodingLoop: Double = 0
    var logmels: Double = 0
    var fallbacks: Double = 0
    var windows: Double = 0
    var calls: Int = 0

    /// Seconds of audio per second of waiting — the number the user feels.
    var speedFactor: Double { wallSeconds > 0 ? audioSeconds / wallSeconds : 0 }

    /// ~1.0 sequential, approaching `concurrentWorkerCount` when chunks decode
    /// together. This is the figure that answers whether `.vad` is doing anything.
    var parallelism: Double { wallSeconds > 0 ? computeSeconds / wallSeconds : 0 }

    /// Temperature retries per decode window. A window that falls back has been
    /// decoded twice or more, so this is where "slow" and "dropped audio" turn out
    /// to be the same measurement.
    var fallbacksPerWindow: Double { windows > 0 ? fallbacks / windows : 0 }

    mutating func add(audioSeconds: Double,
                      pipeline: Double,
                      encoding: Double,
                      decodingLoop: Double,
                      logmels: Double,
                      fallbacks: Double,
                      windows: Double) {
        self.audioSeconds += audioSeconds
        self.computeSeconds += pipeline
        self.encoding += encoding
        self.decodingLoop += decodingLoop
        self.logmels += logmels
        self.fallbacks += fallbacks
        self.windows += windows
        calls += 1
    }

    var summary: String {
        String(format: "audio=%.0fs wall=%.0fs speed=%.2fx parallel=%.2fx enc=%.0fs dec=%.0fs mel=%.0fs windows=%.0f fallbacks=%.0f (%.2f/window) calls=%d",
               audioSeconds, wallSeconds, speedFactor, parallelism,
               encoding, decodingLoop, logmels, windows, fallbacks, fallbacksPerWindow, calls)
    }
}
