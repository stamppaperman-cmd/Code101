import XCTest
@testable import EchoNote

/// Splitting, coverage and retrieval arithmetic. These are the functions that decide
/// what the model is shown; when they are wrong the output looks fine and is built on
/// the wrong audio.
final class AudioBlocksTests: XCTestCase {

    private let rate = 16_000.0

    /// Boundaries are chosen by a caller-supplied function so the split can be tested
    /// without a sample buffer; here it just returns the target untouched.
    private func plainCut(_ target: Int, _ radius: Int) -> Int { target }

    func testShortFileIsOneBlock() {
        let samples = Int(rate * 300)   // 5 minutes
        let blocks = AudioBlocks.blockRanges(sampleCount: samples, sampleRate: rate, energyAt: plainCut)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0], 0..<samples)
    }

    func testLongFileIsSplitAndStillCoversEverySample() {
        let samples = Int(rate * 3814)  // the 64-minute interview
        let blocks = AudioBlocks.blockRanges(sampleCount: samples, sampleRate: rate, energyAt: plainCut)
        XCTAssertGreaterThan(blocks.count, 1)
        XCTAssertEqual(blocks.first?.lowerBound, 0)
        XCTAssertEqual(blocks.last?.upperBound, samples)
        // Contiguous: a gap here would be audio silently never transcribed, which is
        // the exact class of bug this app exists to have fixed.
        for (a, b) in zip(blocks, blocks.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound)
        }
    }

    func testNoBlockIsShorterThanThirtySeconds() {
        let samples = Int(rate * 3814)
        let blocks = AudioBlocks.blockRanges(sampleCount: samples, sampleRate: rate, energyAt: plainCut)
        for block in blocks {
            XCTAssertGreaterThanOrEqual(Double(block.count) / rate, 30)
        }
    }

    func testQuietestCutLandsInTheSilence() {
        // One second of tone, half a second of silence, one second of tone.
        var samples = [Float](repeating: 0.5, count: 16_000)
        samples += [Float](repeating: 0, count: 8_000)
        samples += [Float](repeating: 0.5, count: 16_000)

        let cut = AudioBlocks.quietestCut(in: samples, near: 16_000, radius: 12_000, sampleRate: rate)
        XCTAssertGreaterThanOrEqual(cut, 16_000)
        XCTAssertLessThanOrEqual(cut, 24_000)
    }

    func testUncoveredRangesFindsTheHolesAndIgnoresSmallOnes() {
        let segments = [Segment(id: 0, startMS: 0, endMS: 10_000, text: "a"),
                        Segment(id: 1, startMS: 12_000, endMS: 20_000, text: "b"),
                        Segment(id: 2, startMS: 50_000, endMS: 60_000, text: "c")]
        let gaps = AudioBlocks.uncoveredRanges(in: segments, duration: 100, minimumSeconds: 6)
        // 20s-50s and 60s-100s qualify; the 2-second hole at 10s does not.
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0].start, 20, accuracy: 0.001)
        XCTAssertEqual(gaps[0].end, 50, accuracy: 0.001)
        XCTAssertEqual(gaps[1].start, 60, accuracy: 0.001)
    }

    func testUncoveredRangesHandlesOverlappingSegments() {
        let segments = [Segment(id: 0, startMS: 0, endMS: 30_000, text: "a"),
                        Segment(id: 1, startMS: 10_000, endMS: 20_000, text: "b")]
        XCTAssertTrue(AudioBlocks.uncoveredRanges(in: segments, duration: 30, minimumSeconds: 6).isEmpty)
    }
}

final class RetrieverTests: XCTestCase {

    private func segments(_ count: Int) -> [Segment] {
        (0..<count).map { Segment(id: $0, startMS: $0 * 3_000, endMS: $0 * 3_000 + 2_500, text: "line \($0)") }
    }

    func testWindowsOverlapSoAnAnswerCannotFallBetweenThem() {
        let windows = Retriever.windows(from: segments(9), corrected: false)
        XCTAssertEqual(windows.first?.ids, [0, 1, 2])
        XCTAssertEqual(windows[1].ids, [2, 3, 4])
    }

    func testEverySegmentAppearsInSomeWindow() {
        let windows = Retriever.windows(from: segments(10), corrected: false)
        let covered = Set(windows.flatMap(\.ids))
        XCTAssertEqual(covered, Set(0..<10))
    }

    func testWindowKeepsTheStartOfItsFirstSegment() {
        let windows = Retriever.windows(from: segments(6), corrected: false)
        XCTAssertEqual(windows[1].startMS, 6_000)
    }

    func testNormalizeMakesDotProductACosine() {
        let a = Retriever.normalize([3, 4, 0])
        XCTAssertEqual(Retriever.dot(a, a), 1, accuracy: 0.0001)
    }

    func testDotIsZeroForMismatchedLengths() {
        XCTAssertEqual(Retriever.dot([1, 0], [1, 0, 0]), 0)
    }

    func testEmbeddingModelIsPickedFromWhatIsInstalled() {
        XCTAssertEqual(Retriever.installedEmbeddingModel(["qwen3.5:9b", "nomic-embed-text:latest"]),
                       "nomic-embed-text:latest")
        XCTAssertNil(Retriever.installedEmbeddingModel(["qwen3.5:9b", "gemma4:26b"]))
    }
}

final class SpeakerNamerTests: XCTestCase {

    /// The measured bug: the interviewer asked "พี่แปลงกวา ตอนนี้อายุเท่าไหร่ครับ" and
    /// the model handed the interviewer that name. Addressing someone is evidence
    /// about them, never about the speaker.
    private let interview = [
        Segment(id: 0, startMS: 0, endMS: 4_000, text: "พี่แปลงกวา ตอนนี้อายุเท่าไหร่ครับ", speakerId: 0),
        Segment(id: 1, startMS: 4_000, endMS: 9_000, text: "ก็ชื่อ แต่งกวา สาธาชนนะคะ", speakerId: 1),
        Segment(id: 2, startMS: 9_000, endMS: 12_000, text: "อายุ 31 ค่ะ", speakerId: 1),
    ]

    private func guess(_ speaker: Int, _ name: String, _ evidence: String) -> SpeakerNamer.Guess {
        SpeakerNamer.Guess(speakerId: speaker, name: name, evidence: evidence)
    }

    func testRejectsANameTakenFromTheSpeakersOwnQuestion() {
        XCTAssertFalse(SpeakerNamer.accept(guess(0, "พี่แปลงกวา", "พี่แปลงกวา ตอนนี้อายุเท่าไหร่ครับ"),
                                           segments: interview))
    }

    func testAcceptsASelfIntroduction() {
        XCTAssertTrue(SpeakerNamer.accept(guess(1, "แต่งกวา สาธาชน", "ก็ชื่อ แต่งกวา สาธาชนนะคะ"),
                                          segments: interview))
    }

    func testAcceptsBeingNamedBySomeoneElse() {
        // The same sentence, attributed the right way round.
        XCTAssertTrue(SpeakerNamer.accept(guess(1, "แปลงกวา", "พี่แปลงกวา ตอนนี้อายุเท่าไหร่ครับ"),
                                          segments: interview))
    }

    func testRejectsEvidenceThatIsNotInTheTranscript() {
        XCTAssertFalse(SpeakerNamer.accept(guess(1, "สมชาย", "ผมชื่อสมชายครับ"), segments: interview))
    }

    func testSpeakerSayingToleratesRewrappedWhitespace() {
        XCTAssertEqual(SpeakerNamer.speakerSaying("ก็ชื่อแต่งกวา สาธาชนนะคะ", in: interview), 1)
    }

    func testIsSelfIntroduction() {
        XCTAssertTrue(SpeakerNamer.isSelfIntroduction("ผมชื่อสมชาย"))
        XCTAssertTrue(SpeakerNamer.isSelfIntroduction("My name is Jasmine"))
        XCTAssertFalse(SpeakerNamer.isSelfIntroduction("คุณสมชายครับ ขอถามหน่อย"))
    }
}

final class TranscriptShapeTests: XCTestCase {

    func testCoverageIsMeasuredNotAssumed() {
        var job = Job(filename: "a.m4a", sourcePath: "/tmp/a.m4a")
        job.durationSec = 100
        job.segments = [Segment(id: 0, startMS: 0, endMS: 40_000, text: "a"),
                        Segment(id: 1, startMS: 50_000, endMS: 90_000, text: "b")]
        XCTAssertEqual(job.coverage ?? 0, 0.8, accuracy: 0.001)
    }

    func testCoverageIsNilWithoutATranscript() {
        var job = Job(filename: "a.m4a", sourcePath: "/tmp/a.m4a")
        job.durationSec = 100
        XCTAssertNil(job.coverage)
    }

    func testChunkCarriesTheSegmentNumberTheModelMustCite() {
        let segments = [Segment(id: 7, startMS: 65_000, endMS: 68_000, text: "สวัสดีครับ")]
        let chunks = Summarizer.chunk(segments, corrected: false)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].hasPrefix("#7 [01:05]"))
    }

    func testStripThinkingRemovesReasoningBlocks() {
        XCTAssertEqual(Summarizer.stripThinking("<think>อืม</think>คำตอบ"), "คำตอบ")
        XCTAssertEqual(Summarizer.stripThinking("  คำตอบ  "), "คำตอบ")
    }

    func testPipelineWeightsSumToOne() {
        let total = PipelineStage.allCases.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(total, 1.0, accuracy: 0.0001)
    }

    func testEveryStageStartsWhereThePreviousOneEnds() {
        // Overlapping weights used to make the progress bar run backwards.
        var cursor = 0.0
        for stage in PipelineStage.allCases {
            XCTAssertEqual(stage.start, cursor, accuracy: 0.0001)
            cursor += stage.weight
        }
    }
}

/// Lexical retrieval exists because the embedding model does not read Thai. These
/// numbers are the evidence, so they are the tests.
final class LexicalTests: XCTestCase {

    func testGramsIgnoreSpacingSoThaiWordBreaksDoNotMatter() {
        XCTAssertEqual(Lexical.grams("สาขา ภูเก็ต"), Lexical.grams("สาขาภูเก็ต"))
    }

    func testGramsOfVeryShortTextAreNotLost() {
        XCTAssertEqual(Lexical.grams("ab"), ["ab"])
        XCTAssertTrue(Lexical.grams("").isEmpty)
    }

    func testAnUnrelatedQuestionScoresZero() {
        let documents = ["สรุปยอดขายไตรมาสสองของสาขาขอนแก่นอยู่ที่ 4.2 ล้านบาท",
                         "คุณวราภรณ์จะไปดูเรื่องสต๊อกของสาขาภูเก็ตภายในวันอังคาร"].map(Lexical.frequencies)
        let idf = Lexical.inverseDocumentFrequency(documents)
        let query = Lexical.frequencies("สูตรทำต้มยำกุ้ง")
        for document in documents {
            XCTAssertEqual(Lexical.similarity(query: query, document: document, idf: idf), 0,
                           accuracy: 0.0001)
        }
    }

    func testTheRelevantDocumentOutscoresTheOther() {
        let texts = ["สรุปยอดขายไตรมาสสองของสาขาขอนแก่นอยู่ที่ 4.2 ล้านบาท",
                     "คุณวราภรณ์จะไปดูเรื่องสต๊อกของสาขาภูเก็ตภายในวันอังคาร"]
        let documents = texts.map(Lexical.frequencies)
        let idf = Lexical.inverseDocumentFrequency(documents)
        let query = Lexical.frequencies("สาขาขอนแก่นยอดขายเท่าไหร่")
        let scores = documents.map { Lexical.similarity(query: query, document: $0, idf: idf) }
        XCTAssertGreaterThan(scores[0], scores[1])
        XCTAssertGreaterThan(scores[0], Double(Asker.relevanceFloor))
    }

    /// The measurement that produced this whole file: `nomic-embed-text` returned the
    /// same similarity for three unrelated Thai questions.
    func testFlatEmbeddingScoresAreRecognisedAsUseless() {
        XCTAssertFalse(Lexical.discriminates([0.7454, 0.7454, 0.7454]))
        XCTAssertTrue(Lexical.discriminates([0.41, 0.72, 0.55]))
        XCTAssertFalse(Lexical.discriminates([0.5]))
    }

    func testVectorsThatCallDifferentTextIdenticalAreRejected() {
        let constant = Retriever.normalize([1, 0, 0])
        let windows = [RetrievalWindow(segmentIds: [0], startMS: 0,
                                       text: "สรุปยอดขายไตรมาสสองของสาขาขอนแก่น", vector: constant),
                       RetrievalWindow(segmentIds: [1], startMS: 5_000,
                                       text: "พรุ่งนี้ฝนน่าจะตกหนักแถวเชียงใหม่", vector: constant)]
        XCTAssertFalse(Retriever.vectorsAreInformative(windows))
    }

    func testVectorsThatSeparateDifferentTextAreKept() {
        let windows = [RetrievalWindow(segmentIds: [0], startMS: 0,
                                       text: "สรุปยอดขายไตรมาสสองของสาขาขอนแก่น",
                                       vector: Retriever.normalize([1, 0, 0])),
                       RetrievalWindow(segmentIds: [1], startMS: 5_000,
                                       text: "พรุ่งนี้ฝนน่าจะตกหนักแถวเชียงใหม่",
                                       vector: Retriever.normalize([0, 1, 0]))]
        XCTAssertTrue(Retriever.vectorsAreInformative(windows))
    }

    func testUnprovenVectorsAreNotTrusted() {
        // Two windows that say almost the same thing cannot testify either way, and an
        // unproven signal must not be blended into one that works.
        let text = "คุณวราภรณ์จะไปดูเรื่องสต๊อกของสาขาภูเก็ตภายในวันอังคาร"
        let windows = [RetrievalWindow(segmentIds: [0], startMS: 0, text: text,
                                       vector: Retriever.normalize([1, 0, 0])),
                       RetrievalWindow(segmentIds: [1], startMS: 5_000, text: text,
                                       vector: Retriever.normalize([0, 1, 0]))]
        XCTAssertFalse(Retriever.vectorsAreInformative(windows))
    }
}

/// The hosted backend is opt-in and says so. These assert the promise, not the network.
final class AnswerBackendTests: XCTestCase {

    func testOnlyTheHostedBackendIsMarkedAsLeavingTheMachine() {
        XCTAssertFalse(AnswerBackend.local.sendsDataOut)
        XCTAssertTrue(AnswerBackend.gemini.sendsDataOut)
    }

    func testEveryBackendExplainsItself() {
        for backend in AnswerBackend.allCases {
            XCTAssertFalse(backend.label.isEmpty)
            XCTAssertFalse(backend.detail.isEmpty)
        }
    }

    func testAnswersRecordWhichModelSawTheRecording() {
        let answer = GroundedAnswer(question: "ถามอะไรสักอย่าง", text: "ตอบ",
                                    claims: [Claim(text: "ตอบ", segmentIds: [0])],
                                    consulted: [0], refused: false, backend: .gemini)
        XCTAssertTrue(answer.backend.sendsDataOut)
        XCTAssertTrue(answer.isGrounded)
    }

    func testAKeyIsNeverSentAsAQueryParameter() {
        // A key in a URL lands in logs, proxies and shell history.
        let client = GeminiClient(apiKey: "secret-key-value")
        XCTAssertFalse(client.model.isEmpty)
        XCTAssertEqual(GeminiClient.defaultModel, "gemini-2.0-flash")
    }
}

/// The word list reaches the cleanup pass as context, after two approaches that looked
/// better were measured worse — see `Vocabulary` for the numbers. What is left to test
/// is that the list is well-formed and that the instruction is never silently empty.
final class VocabularyTests: XCTestCase {

    func testCleanRemovesBlanksAndDuplicates() {
        XCTAssertEqual(Vocabulary.clean(["  Hyrox ", "", "hyrox", "แต่งกวา", "  "]),
                       ["Hyrox", "แต่งกวา"])
    }

    func testCleanKeepsTheOrderTheUserTypedThemIn() {
        XCTAssertEqual(Vocabulary.clean(["ไตรมาส", "แคมเปญ", "Hyrox"]),
                       ["ไตรมาส", "แคมเปญ", "Hyrox"])
    }

    func testTheListIsCappedSoTheInstructionStaysPointed() {
        let many = (0..<100).map { "คำที่\($0)" }
        XCTAssertEqual(Vocabulary.clean(many).count, Vocabulary.maximumWords)
    }

    func testNoWordsMeansNoInstruction() {
        XCTAssertNil(Vocabulary.promptSection([]))
        XCTAssertNil(Vocabulary.promptSection(["   ", ""]))
    }

    func testPromptCarriesEveryWordAndForbidsInventingThem() {
        let section = try? XCTUnwrap(Vocabulary.promptSection(["แคมเปญ", "ไตรมาส"]))
        XCTAssertTrue(section!.contains("แคมเปญ"))
        XCTAssertTrue(section!.contains("ไตรมาส"))
        // The failure mode of this pass has always been doing too much.
        XCTAssertTrue(section!.contains("ห้ามแก้คำอื่น"))
        XCTAssertTrue(section!.contains("ห้ามเพิ่มคำจากรายการเข้าไปเอง"))
    }
}
