import XCTest
@testable import EchoNote

/// Every function here stands between a language model and the user's data, and each
/// one fails silently when it breaks: a bad correction reads like a good one, a
/// citation pointing at the wrong line looks exactly like a citation pointing at the
/// right one. That is what makes them worth testing and everything else less so.
///
/// The cases are not invented. Each is either output measured from the real 64-minute
/// Thai interview this app was built against, or the exact shape of a bug that
/// reached the user.
final class TextCorrectorTests: XCTestCase {

    // MARK: - accept

    func testAcceptRejectsDeletedWord() {
        // Measured: the model turned this into the second string and the old 0.7
        // length floor let it through.
        XCTAssertFalse(TextCorrector.accept(raw: "เรียนเป็นเด็กศิลปศาสตร์",
                                            corrected: "เรียนเด็กศิลปศาสตร์"))
    }

    func testAcceptRejectsChangedNumber() {
        // Measured: transcript said 31, the summary said 38.
        XCTAssertFalse(TextCorrector.accept(raw: "ตอนนี้อายุ 31 ปี",
                                            corrected: "ตอนนี้อายุ 38 ปี"))
    }

    func testAcceptAllowsRealSpellingFix() {
        XCTAssertTrue(TextCorrector.accept(raw: "ทำแคมเป็นนี้", corrected: "ทำแคมเปญนี้"))
    }

    func testAcceptRejectsEmpty() {
        XCTAssertFalse(TextCorrector.accept(raw: "อะไรสักอย่าง", corrected: ""))
    }

    // MARK: - mask / unmask

    func testMaskHidesNumbersAndRestoresThemVerbatim() {
        let masked = TextCorrector.mask("ประชุมวันศุกร์ 14 คน")
        XCTAssertFalse(masked.text.contains("14"))
        XCTAssertEqual(TextCorrector.unmask(masked.text, spans: masked.spans), "ประชุมวันศุกร์ 14 คน")
    }

    func testUnmaskRefusesWhenModelDroppedAPlaceholder() {
        let masked = TextCorrector.mask("ส่งภายในวันศุกร์นี้ 3 ชิ้น")
        XCTAssertFalse(masked.spans.isEmpty)
        // The model returning the line without §1§ means it ate a protected span.
        XCTAssertNil(TextCorrector.unmask("ส่งภายใน", spans: masked.spans))
    }

    func testUnmaskRefusesWhenAPlaceholderSurvivesUnfilled() {
        XCTAssertNil(TextCorrector.unmask("ส่ง §2§ ชิ้น", spans: ["3"]))
    }

    // MARK: - parse

    func testParseRequiresEveryLineBack() {
        XCTAssertNil(TextCorrector.parse("1. หนึ่ง\n2. สอง", expecting: 3))
    }

    func testParseAcceptsExactMatchAndKeepsOrder() {
        let parsed = TextCorrector.parse("2. สอง\n1. หนึ่ง", expecting: 2)
        XCTAssertEqual(parsed, ["หนึ่ง", "สอง"])
    }

    func testParseIgnoresChatterAroundTheList() {
        let parsed = TextCorrector.parse("นี่คือผลลัพธ์:\n1. หนึ่ง\n2. สอง\nหวังว่าจะช่วยได้",
                                         expecting: 2)
        XCTAssertEqual(parsed, ["หนึ่ง", "สอง"])
    }

    // MARK: - knownFixes

    func testKnownFixesAlwaysLand() {
        XCTAssertEqual(TextCorrector.applyKnownFixes("ส่งภายในวันสุขนี"), "ส่งภายในวันศุกร์นี้")
        XCTAssertEqual(TextCorrector.applyKnownFixes("ประชุมวันจันหน้า"), "ประชุมวันจันทร์หน้า")
    }

    // MARK: - doubtful

    private func segment(_ id: Int, _ confidence: Double?) -> Segment {
        Segment(id: id, startMS: id * 1000, endMS: id * 1000 + 900, text: "line \(id)",
                confidence: confidence)
    }

    func testDoubtfulPicksTheLeastConfidentShare() {
        let segments = (0..<100).map { segment($0, -Double($0) / 100) }
        let picked = TextCorrector.doubtful(segments, share: 0.25)
        XCTAssertEqual(picked.count, 25)
        // Lowest avgLogprob is the *last* segment here, so the worst quarter is the tail.
        XCTAssertEqual(picked, Array(75..<100))
    }

    func testDoubtfulFallsBackToEverythingWhenNothingWasScored() {
        let segments = (0..<10).map { segment($0, nil) }
        XCTAssertEqual(TextCorrector.doubtful(segments, share: 0.25), Array(0..<10))
    }

    func testDoubtfulAlwaysIncludesUnscoredSegments() {
        var segments = (0..<10).map { segment($0, -0.1) }
        segments[3].confidence = nil
        let picked = TextCorrector.doubtful(segments, share: 0.1)
        XCTAssertTrue(picked.contains(3))
    }
}

final class CitationsTests: XCTestCase {

    func testParsePullsIdsAndLeavesTheSentenceClean() {
        let (text, ids) = Citations.parse("ค่าสมัครประมาณ 6,000 บาท [#42, #43]")
        XCTAssertEqual(text, "ค่าสมัครประมาณ 6,000 บาท")
        XCTAssertEqual(ids, [42, 43])
    }

    func testParseToleratesTheSeparatorsModelsActuallyUse() {
        XCTAssertEqual(Citations.parse("ก [#1 #2]").ids, [1, 2])
        XCTAssertEqual(Citations.parse("ก [#1,2]").ids, [1, 2])
        XCTAssertEqual(Citations.parse("ก [1]").ids, [1])
    }

    func testParseReturnsNoIdsWhenTheModelIgnoredTheRule() {
        let (text, ids) = Citations.parse("ข้อความที่ไม่มีที่มา")
        XCTAssertEqual(text, "ข้อความที่ไม่มีที่มา")
        XCTAssertTrue(ids.isEmpty)
    }

    func testClaimSeparatesRealCitationsFromInventedOnes() {
        let claim = Citations.claim(from: "ข้อความ [#1, #999]", validIds: [1, 2, 3])
        XCTAssertEqual(claim?.segmentIds, [1])
        XCTAssertEqual(claim?.invalidIds, [999])
        XCTAssertTrue(claim?.hasHallucinatedCitation == true)
    }

    func testClaimIsDroppedWhenNothingButACitationIsLeft() {
        XCTAssertNil(Citations.claim(from: "[#1]", validIds: [1]))
    }

    /// Measured on the first real run: told to write `[#42]`, the model copied the
    /// transcript's own `#42` prefix to the front of the sentence instead. Every claim
    /// was cited and the parser scored 0%.
    func testParseAcceptsTheLeadingFormModelsActuallyProduce() {
        let (text, ids) = Citations.parse("#0, #1, #2, #3 ผลแคมเปญเดือนที่แล้ว ยอดขายเพิ่มขึ้น 8%")
        XCTAssertEqual(text, "ผลแคมเปญเดือนที่แล้ว ยอดขายเพิ่มขึ้น 8%")
        XCTAssertEqual(ids, [0, 1, 2, 3])
    }

    func testParseAcceptsABareTrailingRun() {
        let (text, ids) = Citations.parse("คุณสมชายส่งแผนภายในวันศุกร์ #8, #9")
        XCTAssertEqual(text, "คุณสมชายส่งแผนภายในวันศุกร์")
        XCTAssertEqual(ids, [8, 9])
    }

    func testParseLeavesPercentagesAndPlainNumbersAlone() {
        let (text, ids) = Citations.parse("ยอดผู้เข้าชมเพิ่มขึ้น 32% แต่ยอดขาย 8%")
        XCTAssertEqual(text, "ยอดผู้เข้าชมเพิ่มขึ้น 32% แต่ยอดขาย 8%")
        XCTAssertTrue(ids.isEmpty)
    }

    func testParseDoesNotStripAMarkerFromTheMiddleOfASentence() {
        let (text, _) = Citations.parse("ช่อง #1 คือช่องหลัก [#5]")
        XCTAssertEqual(text, "ช่อง #1 คือช่องหลัก")
    }

    func testGroundedShare() {
        let claims = [Claim(text: "a", segmentIds: [1]),
                      Claim(text: "b", segmentIds: []),
                      Claim(text: "c", segmentIds: [2]),
                      Claim(text: "d", segmentIds: [3])]
        XCTAssertEqual(Citations.groundedShare(claims) ?? 0, 0.75, accuracy: 0.001)
        XCTAssertNil(Citations.groundedShare([]))
    }
}

final class SummaryAuditTests: XCTestCase {

    private func segments() -> [Segment] {
        [Segment(id: 0, startMS: 0, endMS: 4_000, text: "ตอนนี้อายุ 31 ปีค่ะ"),
         Segment(id: 1, startMS: 4_000, endMS: 9_000, text: "จะไปแข่งที่ฮ่องกงปีหน้า"),
         Segment(id: 2, startMS: 9_000, endMS: 14_000, text: "รอบเดือนตุลาคมค่อยกลับมาซ้อม")]
    }

    func testUnsupportedCatchesAFabricatedMonth() {
        // Measured: the summary said มกราคม; nobody said มกราคม.
        let missing = SummaryAudit.unsupported(in: "จะไปแข่งฮ่องกงเดือนมกราคมปีหน้า",
                                               source: "จะไปแข่งที่ฮ่องกงปีหน้า")
        XCTAssertEqual(missing, ["มกราคม"])
    }

    func testUnsupportedCatchesAChangedNumber() {
        XCTAssertEqual(SummaryAudit.unsupported(in: "อายุ 38 ปี", source: "ตอนนี้อายุ 31 ปีค่ะ"), ["38"])
    }

    func testUnsupportedIsSilentWhenTheFactIsReallyThere() {
        XCTAssertTrue(SummaryAudit.unsupported(in: "อายุ 31 ปี", source: "ตอนนี้อายุ 31 ปีค่ะ").isEmpty)
    }

    func testHasCJKCatchesLeakedChinese() {
        // Measured: the model leaked 更多人 into Thai output.
        XCTAssertTrue(SummaryAudit.hasCJK("อยากให้ 更多人 มาเล่น"))
        XCTAssertFalse(SummaryAudit.hasCJK("อยากให้คนมาเล่นมากขึ้น"))
    }

    func testLocatedReportsMissingFactsWithTheLinesTheClaimCited() {
        let claim = Claim(text: "จะไปแข่งฮ่องกงเดือนมกราคม", segmentIds: [1])
        let found = SummaryAudit.located(claims: [claim], segments: segments(), corrected: false)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].missing, ["มกราคม"])
        XCTAssertEqual(found[0].segmentIds, [1])
        XCTAssertEqual(found[0].quotes, ["จะไปแข่งที่ฮ่องกงปีหน้า"])
    }

    /// The check that has no text-only equivalent: the fact is real, the citation
    /// points somewhere else. Without citations this claim looks perfect.
    func testLocatedCatchesARealFactBoltedToTheWrongMoment() {
        let claim = Claim(text: "รอบเดือนตุลาคมค่อยกลับมาซ้อม", segmentIds: [0])
        let found = SummaryAudit.located(claims: [claim], segments: segments(), corrected: false)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].missing.isEmpty)
        XCTAssertEqual(found[0].misplaced, ["ตุลาคม"])
        XCTAssertEqual(found[0].severity, "อ้างผิดที่")
    }

    func testLocatedStaysQuietWhenTheCitationSupportsTheClaim() {
        let claim = Claim(text: "อายุ 31 ปี", segmentIds: [0])
        XCTAssertTrue(SummaryAudit.located(claims: [claim], segments: segments(), corrected: false).isEmpty)
    }
}
