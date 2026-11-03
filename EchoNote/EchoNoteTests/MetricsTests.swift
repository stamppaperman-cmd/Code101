import XCTest
@testable import EchoNote

/// The arithmetic that will be used to decide whether `.vad` replaces `.none`.
///
/// These tests exist because an unmeasured measurement is worse than none: a wrong
/// coverage figure or a mis-scaled error rate does not look wrong, it looks like a
/// result, and it would be acted on. Every case below is hand-computable — if one
/// fails, the number is wrong, not the expectation.
final class MetricsDistanceTests: XCTestCase {

    func testEditDistanceCountsEachOperationOnce() {
        XCTAssertEqual(Metrics.editDistance(Array("abc"), Array("abc")), 0)
        XCTAssertEqual(Metrics.editDistance(Array("abc"), Array("abd")), 1)   // substitute
        XCTAssertEqual(Metrics.editDistance(Array("abc"), Array("ab")), 1)    // delete
        XCTAssertEqual(Metrics.editDistance(Array("abc"), Array("abcd")), 1)  // insert
        XCTAssertEqual(Metrics.editDistance(Array("abc"), Array("")), 3)
        XCTAssertEqual(Metrics.editDistance(Array(""), Array("abc")), 3)
        XCTAssertEqual(Metrics.editDistance([Int](), [Int]()), 0)
    }

    func testCharacterErrorRateIsErrorsOverReferenceLength() {
        XCTAssertEqual(Metrics.cer(reference: "กขคง", hypothesis: "กขคง"), 0, accuracy: 0.0001)
        XCTAssertEqual(Metrics.cer(reference: "กขคง", hypothesis: "กขคจ"), 0.25, accuracy: 0.0001)
        XCTAssertEqual(Metrics.cer(reference: "กขคง", hypothesis: "กขค"), 0.25, accuracy: 0.0001)
    }

    /// Whisper decides where to put spaces in Thai on feel, and Thai has no word
    /// boundary for it to be right about. If normalisation ever stops stripping
    /// whitespace, every run's error rate jumps for a reason that has nothing to do
    /// with what was heard.
    func testSpacingAndPunctuationAreNotErrors() {
        XCTAssertEqual(Metrics.cer(reference: "สวัสดี ครับ", hypothesis: "สวัสดีครับ"), 0, accuracy: 0.0001)
        XCTAssertEqual(Metrics.cer(reference: "ไตรมาสนี้ ดีมาก!", hypothesis: "ไตรมาสนี้ดีมาก"), 0, accuracy: 0.0001)
    }

    /// The same pair, scored the usual way, reads as a total failure. This is the
    /// test that says why `wer` must never be reported for Thai.
    func testWordErrorRateIsMeaninglessForThai() {
        XCTAssertEqual(Metrics.wer(reference: "สวัสดี ครับ", hypothesis: "สวัสดีครับ"), 1.0, accuracy: 0.0001)
        XCTAssertEqual(Metrics.cer(reference: "สวัสดี ครับ", hypothesis: "สวัสดีครับ"), 0, accuracy: 0.0001)
    }

    func testWordErrorRateWorksOnSpacedText() {
        XCTAssertEqual(Metrics.wer(reference: "the quick brown fox", hypothesis: "the quick brown fox"), 0, accuracy: 0.0001)
        XCTAssertEqual(Metrics.wer(reference: "the quick brown fox", hypothesis: "the quick red fox"), 0.25, accuracy: 0.0001)
    }

    /// A hallucinating model produces more text than was spoken, and the honest score
    /// for that is above 1. Clamping it would hide the worst runs behind the ceiling.
    func testErrorRateExceedsOneWhenTheModelInventsText() {
        XCTAssertEqual(Metrics.cer(reference: "ก", hypothesis: "กขคง"), 3.0, accuracy: 0.0001)
    }

    func testEmptyReference() {
        XCTAssertEqual(Metrics.cer(reference: "", hypothesis: ""), 0, accuracy: 0.0001)
        XCTAssertEqual(Metrics.cer(reference: "", hypothesis: "อะไรก็ไม่รู้"), 1, accuracy: 0.0001)
    }
}

/// Signals that need no reference transcript. These are what make a coverage figure
/// safe to read — coverage rises when a model fills silence with invention, and only
/// these counters can tell that apart from coverage rising because it heard more.
final class MetricsSignalTests: XCTestCase {

    func testDetectsAnImmediateLoop() {
        let looped = String(repeating: "ขอบคุณครับ", count: 3)
        let found = Metrics.repetitions(in: looped)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.count, 3)
    }

    /// Saying something twice is human. The threshold is what keeps this from firing
    /// on every polite Thai conversation.
    func testTwoInARowIsNotALoop() {
        XCTAssertTrue(Metrics.repetitions(in: String(repeating: "ขอบคุณครับ", count: 2)).isEmpty)
    }

    func testOrdinaryThaiIsNotFlagged() {
        XCTAssertTrue(Metrics.repetitions(in: "วันนี้อากาศดีมากเลยครับ ไปประชุมสาขาภูเก็ตกันไหม").isEmpty)
    }

    /// `abababab…` must be reported once as the longest run it can account for, not
    /// twice as two shorter ones, or the loop count in the log double-counts.
    func testTheLongestRunWins() {
        let found = Metrics.repetitions(in: String(repeating: "กขคง", count: 6))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.count, 6)
    }

    /// The exact characters that leaked into a Thai transcript on 2026-09-06.
    func testCountsLeakedCJK() {
        XCTAssertEqual(Metrics.cjkCharacters(in: "ผมคิดว่า更多人น่าจะมา"), 3)
        XCTAssertEqual(Metrics.cjkCharacters(in: "ประโยคไทยล้วน ไม่มีอะไรแปลกปลอม"), 0)
    }
}

final class MetricsCoverageTests: XCTestCase {

    private func segment(_ id: Int, _ start: Int, _ end: Int, _ text: String = "ทดสอบ") -> Segment {
        Segment(id: id, startMS: start * 1000, endMS: end * 1000, text: text)
    }

    /// Diarization and `fillGaps` both produce segments that overlap the first pass.
    /// Summing their durations would put coverage above 100% and make the headline
    /// number of this whole exercise nonsense.
    func testOverlappingSegmentsAreCountedOnce() {
        let signals = Metrics.signals(for: [segment(0, 0, 50), segment(1, 40, 80)], duration: 100)
        XCTAssertEqual(signals.coveredFraction, 0.8, accuracy: 0.0001)
    }

    func testCoverageNeverExceedsOne() {
        let signals = Metrics.signals(for: [segment(0, 0, 200)], duration: 100)
        XCTAssertEqual(signals.coveredFraction, 1.0, accuracy: 0.0001)
    }

    /// Coverage charges every uncovered second; the gap count only reports the
    /// stretches long enough for `fillGaps` to act on. The two must not be confused,
    /// so this pins the fact that they disagree.
    func testShortSilenceCostsCoverageButIsNotARecoverableGap() {
        let signals = Metrics.signals(for: [segment(0, 0, 40), segment(1, 42, 100)], duration: 100)
        XCTAssertEqual(signals.coveredFraction, 0.98, accuracy: 0.0001)
        XCTAssertEqual(signals.recoverableStretches, 0)
    }

    func testLongSilenceIsAReportedGap() {
        let signals = Metrics.signals(for: [segment(0, 0, 40), segment(1, 70, 100)], duration: 100)
        XCTAssertEqual(signals.recoverableStretches, 1)
        XCTAssertEqual(signals.recoverableSeconds, 30, accuracy: 0.0001)
    }

    /// 56 of these survived the fix that took coverage from 74.3% to 92.4%. Coverage
    /// cannot see them — the segment is present, it just has no duration — which is
    /// why they are counted on their own.
    func testZeroLengthSegmentsAreCounted() {
        let cut = Segment(id: 1, startMS: 50_000, endMS: 50_000, text: "แล้วก็เห")
        let signals = Metrics.signals(for: [segment(0, 0, 40), cut], duration: 100)
        XCTAssertEqual(signals.zeroLengthSegments, 1)
    }

    func testEmptyTranscript() {
        let signals = Metrics.signals(for: [], duration: 100)
        XCTAssertEqual(signals.segments, 0)
        XCTAssertEqual(signals.coveredFraction, 0, accuracy: 0.0001)
        XCTAssertNil(signals.meanConfidence)
    }
}

/// The two clocks. If `parallelism` is ever computed from the wrong pair of fields,
/// the answer to "did `.vad` help" is wrong in the direction that looks like success.
final class RunTimingsTests: XCTestCase {

    func testSpeedFactorIsAudioOverWallClock() {
        var timings = RunTimings()
        timings.wallSeconds = 10
        timings.add(audioSeconds: 60, pipeline: 10, encoding: 4, decodingLoop: 5, logmels: 1,
                    fallbacks: 0, windows: 2)
        XCTAssertEqual(timings.speedFactor, 6.0, accuracy: 0.0001)
    }

    /// Four chunks that each took 10 s of compute but finished in 10 s of wall clock
    /// were decoded together. This is the whole measurement.
    func testParallelismReportsConcurrentWork() {
        var timings = RunTimings()
        timings.wallSeconds = 10
        for _ in 0..<4 {
            timings.add(audioSeconds: 30, pipeline: 10, encoding: 3, decodingLoop: 6, logmels: 1,
                        fallbacks: 0, windows: 1)
        }
        XCTAssertEqual(timings.computeSeconds, 40, accuracy: 0.0001)
        XCTAssertEqual(timings.parallelism, 4.0, accuracy: 0.0001)
        XCTAssertEqual(timings.audioSeconds, 120, accuracy: 0.0001)
        XCTAssertEqual(timings.calls, 4)
    }

    func testSequentialWorkReportsParallelismOfOne() {
        var timings = RunTimings()
        timings.wallSeconds = 40
        for _ in 0..<4 {
            timings.add(audioSeconds: 30, pipeline: 10, encoding: 3, decodingLoop: 6, logmels: 1,
                        fallbacks: 0, windows: 1)
        }
        XCTAssertEqual(timings.parallelism, 1.0, accuracy: 0.0001)
    }

    /// A window that fell back was decoded at least twice, which is where "slow" and
    /// "dropped audio" turn out to be one measurement rather than two.
    func testFallbacksPerWindow() {
        var timings = RunTimings()
        timings.add(audioSeconds: 600, pipeline: 300, encoding: 100, decodingLoop: 180, logmels: 20,
                    fallbacks: 25, windows: 100)
        XCTAssertEqual(timings.fallbacksPerWindow, 0.25, accuracy: 0.0001)
    }

    /// Nothing measured must read as infinitely fast.
    func testEmptyTimingsAreZeroNotInfinite() {
        let timings = RunTimings()
        XCTAssertEqual(timings.speedFactor, 0)
        XCTAssertEqual(timings.parallelism, 0)
        XCTAssertEqual(timings.fallbacksPerWindow, 0)
    }
}
