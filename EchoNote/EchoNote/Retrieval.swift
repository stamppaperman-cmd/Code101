import Foundation

/// One retrievable piece of the transcript. Segments alone are too short to carry
/// meaning — a Whisper segment is a few seconds of speech — so they are grouped, and
/// the group keeps the ids of everything in it so an answer built on it can cite the
/// exact lines rather than the window.
struct RetrievalWindow: Codable, Hashable {
    var segmentIds: [Int]
    var startMS: Int
    var text: String
    /// Optional because the embedding model is optional — and because on Thai the one
    /// installed here was measured returning the same vector for every query, so
    /// ranking has to work without it.
    var vector: [Float]?

    var startLabel: String { Segment.clock(startMS) }
}

/// Vectors for one transcript, stored beside it. Rebuilt when the transcript changes.
struct RetrievalIndex: Codable {
    var model: String
    var segmentCount: Int
    var corrected: Bool
    var windows: [RetrievalWindow]

    var hasVectors: Bool { windows.contains { !($0.vector ?? []).isEmpty } }
}

/// Retrieval over a single recording, using the embedding model already on this
/// machine. Nothing here reaches past 127.0.0.1.
///
/// This is the piece that turns a summary into something you can interrogate: ask a
/// question, get back the handful of moments that could answer it, and answer only
/// from those. A model that cannot see the rest of the transcript cannot invent
/// something from it.
struct Retriever: Sendable {
    var client = OllamaClient()
    var model: String

    /// Three segments per window with one segment of overlap — enough context for a
    /// sentence to make sense, enough overlap that an answer straddling a boundary
    /// still lands inside some window.
    static let windowSegments = 3
    static let stride = 2

    /// nomic-embed-text is trained with these prefixes and is measurably worse
    /// without them; they are part of the model's interface, not decoration.
    private static let documentPrefix = "search_document: "
    private static let queryPrefix = "search_query: "

    /// The embedding model to use, picked from what Ollama already has.
    static func installedEmbeddingModel(_ models: [String]) -> String? {
        models.first { $0.contains("nomic-embed") }
            ?? models.first { $0.contains("embed") }
    }

    static func windows(from segments: [Segment], corrected: Bool) -> [(ids: [Int], startMS: Int, text: String)] {
        var result = [(ids: [Int], startMS: Int, text: String)]()
        var index = 0
        while index < segments.count {
            let slice = segments[index..<min(index + windowSegments, segments.count)]
            let text = slice.map { $0.display(corrected: corrected) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append((slice.map(\.id), slice.first?.startMS ?? 0, text))
            }
            index += stride
        }
        return result
    }

    func build(segments: [Segment],
               corrected: Bool,
               onProgress: @escaping @Sendable (Double) -> Void) async throws -> RetrievalIndex {
        let pieces = Self.windows(from: segments, corrected: corrected)
        guard !pieces.isEmpty else {
            return RetrievalIndex(model: model, segmentCount: segments.count, corrected: corrected, windows: [])
        }

        // Batched because one HTTP round trip per window would dominate the cost.
        let batchSize = 32
        let batches = Swift.stride(from: 0, to: pieces.count, by: batchSize).map { start in
            Array(start..<min(start + batchSize, pieces.count))
        }

        var windows = [RetrievalWindow]()
        windows.reserveCapacity(pieces.count)
        var embedded = true

        for (number, batch) in batches.enumerated() {
            // Vectors are a bonus, not a requirement: lexical retrieval alone ranks this
            // transcript, so a missing or unhappy embedding model must not fail the stage.
            var vectors: [[Float]] = []
            if embedded {
                do {
                    vectors = try await client.embed(model: model,
                                                     inputs: batch.map { Self.documentPrefix + pieces[$0].text })
                    if vectors.count != batch.count { embedded = false }
                } catch {
                    log("retrieval: embedding failed (\(error.localizedDescription)) — lexical only")
                    embedded = false
                }
            }
            for (offset, position) in batch.enumerated() {
                windows.append(RetrievalWindow(segmentIds: pieces[position].ids,
                                               startMS: pieces[position].startMS,
                                               text: pieces[position].text,
                                               vector: embedded ? Self.normalize(vectors[offset]) : nil))
            }
            onProgress(Double(number + 1) / Double(batches.count))
        }

        // An embedding model that does not handle this language returns near-identical
        // vectors for everything. Keeping those would replace a working lexical ranking
        // with a constant, so they are measured here and dropped if they say nothing.
        if embedded, !Self.vectorsAreInformative(windows) {
            log("retrieval: \(model) returns near-identical vectors for unrelated text — dropping them")
            embedded = false
            for index in windows.indices { windows[index].vector = nil }
        }

        log("retrieval: \(windows.count) windows, vectors=\(embedded) (\(model))")
        return RetrievalIndex(model: model, segmentCount: segments.count, corrected: corrected, windows: windows)
    }

    /// Ranks the windows for a question.
    ///
    /// Lexical similarity is the ranker; embeddings are folded in only when they are
    /// actually telling the windows apart. On Thai with `nomic-embed-text` they are not,
    /// and a blend would have quietly replaced a working signal with a constant.
    func search(_ question: String, in index: RetrievalIndex, topK: Int) async throws -> [(window: RetrievalWindow, score: Float)] {
        guard !index.windows.isEmpty else { return [] }

        let documents = index.windows.map { Lexical.frequencies($0.text) }
        let idf = Lexical.inverseDocumentFrequency(documents)
        let queryGrams = Lexical.frequencies(question)
        var scores = documents.map {
            Float(Lexical.similarity(query: queryGrams, document: $0, idf: idf))
        }

        if index.hasVectors,
           let raw = try? await client.embed(model: index.model, inputs: [Self.queryPrefix + question]),
           let query = raw.first.map(Self.normalize) {
            let similarities = index.windows.map { window -> Float in
                guard let vector = window.vector else { return 0 }
                return Self.dot(query, vector)
            }
            if Lexical.discriminates(similarities) {
                scores = zip(scores, similarities).map { $0 * 0.6 + $1 * 0.4 }
            } else {
                log("retrieval: embedding scores are flat for this query — lexical only")
            }
        }

        return zip(index.windows, scores)
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { (window: $0.0, score: $0.1) }
    }

    /// Whether the vectors carry any information about this transcript.
    ///
    /// Measured on Thai with `nomic-embed-text`: three unrelated questions produced
    /// byte-identical similarity scores, because the model returns essentially the same
    /// vector for any Thai input. The tell is visible without a question — take the
    /// windows that share the fewest words and ask the model whether they are different.
    /// A model that calls them the same is not reading them.
    static func vectorsAreInformative(_ windows: [RetrievalWindow], threshold: Float = 0.95) -> Bool {
        let vectors = windows.compactMap(\.vector)
        guard vectors.count >= 2, windows.count == vectors.count else { return false }

        let frequencies = windows.map { Lexical.frequencies($0.text) }
        let idf = Lexical.inverseDocumentFrequency(frequencies)

        // Up to a few of the least-overlapping pairs, so the check stays cheap on a
        // transcript with hundreds of windows.
        var pairs = [(lexical: Double, cosine: Float)]()
        let step = max(windows.count / 8, 1)
        for first in Swift.stride(from: 0, to: windows.count, by: step) {
            for second in Swift.stride(from: first + 1, to: windows.count, by: step) {
                let overlap = Lexical.similarity(query: frequencies[first],
                                                 document: frequencies[second],
                                                 idf: idf)
                pairs.append((overlap, dot(vectors[first], vectors[second])))
            }
        }
        // Only pairs that really are about different things can testify.
        let distinct = pairs.filter { $0.lexical < 0.15 }
        // No evidence means unproven, and unproven means unused. Lexical ranking is
        // measured to work on its own; blending in a signal that might be a constant
        // can only make a working ranking worse.
        guard !distinct.isEmpty else { return false }

        let averageCosine = distinct.reduce(Float(0)) { $0 + $1.cosine } / Float(distinct.count)
        return averageCosine < threshold
    }

    // MARK: - Vector math

    /// Vectors are stored normalized so similarity is a plain dot product.
    static func normalize(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var total: Float = 0
        for index in a.indices { total += a[index] * b[index] }
        return total
    }
}
