import XCTest
@testable import EchoNote

/// The one path that cannot be tested with fixtures alone: whether a 9B model, handed
/// only the retrieved lines and told to cite them, actually stays inside the file.
///
/// It talks to the Ollama daemon on this machine and skips itself when that daemon or
/// the models are not there, so a checkout without them still runs a green suite. The
/// assertions are about the guarantees, never about wording — a language model's
/// phrasing is not a contract, but "it cited a real line" and "it refused" are.
final class GroundedAnswerTests: XCTestCase {

    /// A meeting nobody had, so no model can answer from memory instead of the text.
    private let segments = [
        Segment(id: 0, startMS: 0, endMS: 5_000,
                text: "สรุปยอดขายไตรมาสสองของสาขาขอนแก่นอยู่ที่ 4.2 ล้านบาท", speakerId: 0),
        Segment(id: 1, startMS: 5_000, endMS: 11_000,
                text: "สาขาภูเก็ตทำได้ 2.8 ล้านบาท ต่ำกว่าเป้าอยู่เล็กน้อย", speakerId: 0),
        Segment(id: 2, startMS: 11_000, endMS: 17_000,
                text: "คุณวราภรณ์จะไปดูเรื่องสต๊อกของสาขาภูเก็ตภายในวันอังคาร", speakerId: 1),
        Segment(id: 3, startMS: 17_000, endMS: 23_000,
                text: "ส่วนงบการตลาดปีหน้ายังไม่ได้ข้อสรุป ขอยกไปคุยรอบหน้า", speakerId: 1),
    ]

    private var chatModel: String?
    private var index: RetrievalIndex?

    override func setUp() async throws {
        try await super.setUp()
        let client = OllamaClient()
        guard let installed = try? await client.installedModels(), !installed.isEmpty else {
            throw XCTSkip("Ollama ไม่ได้เปิดอยู่ — ข้ามการทดสอบที่ต้องใช้โมเดลจริง")
        }
        guard let embedModel = Retriever.installedEmbeddingModel(installed) else {
            throw XCTSkip("ยังไม่มีโมเดล embedding ในเครื่อง")
        }
        guard let chat = installed.first(where: { !$0.contains("embed") }) else {
            throw XCTSkip("ยังไม่มีโมเดลสำหรับตอบคำถาม")
        }
        chatModel = chat
        index = try await Retriever(model: embedModel)
            .build(segments: segments, corrected: false) { _ in }
    }

    /// The contract is that the answer reaches the model, not that it ranks first.
    /// Measured on this fixture: two windows mention ภูเก็ต and the shorter, denser one
    /// scores higher (0.75 vs 0.60) even though the number lives in the other — normal
    /// length bias in cosine similarity. `Asker` retrieves eight windows, so the line
    /// still arrives; asserting rank one would be asserting something the design does
    /// not promise.
    func testRetrievalSurfacesTheAnsweringLine() async throws {
        let index = try XCTUnwrap(index)
        let hits = try await Retriever(model: index.model)
            .search("สาขาภูเก็ตทำยอดได้เท่าไหร่", in: index, topK: Asker.topK)
        let reached = Set(hits.flatMap(\.window.segmentIds))
        XCTAssertTrue(reached.contains(1), "บรรทัดที่มีตัวเลขของภูเก็ตต้องถูกดึงมาด้วย")
        XCTAssertGreaterThanOrEqual(hits.first?.score ?? 0, Asker.relevanceFloor)
    }

    func testAnUnrelatedQuestionScoresBelowTheFloor() async throws {
        let index = try XCTUnwrap(index)
        let hits = try await Retriever(model: index.model)
            .search("วิธีเปลี่ยนยางรถยนต์", in: index, topK: 3)
        XCTAssertLessThan(hits.first?.score ?? 1, Asker.relevanceFloor,
                          "คำถามที่ไม่เกี่ยวกับไฟล์ควรตกต่ำกว่าเกณฑ์ก่อนถึงโมเดล")
    }

    /// The contract is "nothing reaches the reader without a real line behind it", not
    /// "the model always answers". A refusal satisfies that contract, so asserting an
    /// answer would make this test fail on the model's mood rather than on a defect.
    func testNothingIsShownWithoutARealLineBehindIt() async throws {
        let answer = try await Asker(model: try XCTUnwrap(chatModel))
            .answer("สาขาขอนแก่นยอดขายเท่าไหร่", index: try XCTUnwrap(index), segments: segments)

        if answer.refused {
            XCTAssertTrue(answer.claims.isEmpty, "คำตอบที่ปฏิเสธแล้วต้องไม่มีข้อความหลงเหลือ")
            XCTAssertEqual(answer.text, Asker.refusal)
            return
        }

        XCTAssertTrue(answer.isGrounded)
        for claim in answer.claims {
            XCTAssertFalse(claim.segmentIds.isEmpty)
            XCTAssertFalse(claim.hasHallucinatedCitation)
            for id in claim.segmentIds {
                XCTAssertTrue(segments.contains { $0.id == id })
            }
        }
    }

    /// The property that matters more than any answer: a question the recording never
    /// touches gets a refusal, not a plausible paragraph.
    func testRefusesWhatTheRecordingNeverSays() async throws {
        let answer = try await Asker(model: try XCTUnwrap(chatModel))
            .answer("บริษัทนี้ก่อตั้งปีไหน และใครเป็นผู้ถือหุ้นใหญ่",
                    index: try XCTUnwrap(index), segments: segments)
        XCTAssertTrue(answer.refused, "ไฟล์ไม่ได้พูดถึงเรื่องนี้เลย ต้องตอบว่าไม่พบ")
        XCTAssertEqual(answer.text, Asker.refusal)
    }

    func testAnEmptyQuestionIsRejectedBeforeAnyModelIsCalled() async throws {
        let asker = Asker(model: try XCTUnwrap(chatModel))
        do {
            _ = try await asker.answer("   ", index: try XCTUnwrap(index), segments: segments)
            XCTFail("คำถามว่างเปล่าไม่ควรผ่าน")
        } catch {
            XCTAssertTrue(error is OllamaError)
        }
    }
}
