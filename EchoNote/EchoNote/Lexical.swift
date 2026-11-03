import Foundation

/// Word-level retrieval for Thai, without a word segmenter.
///
/// Measured 2026-09-06, and the reason this file exists: `nomic-embed-text` returns
/// **byte-identical** similarity scores for three completely different Thai questions —
/// "สาขาภูเก็ตทำยอดได้เท่าไหร่", "วิธีเปลี่ยนยางรถยนต์" and "สูตรทำต้มยำกุ้ง" all scored
/// (0.5957, 0.7454) against the same two windows. An English question moved the numbers.
/// The model does not embed Thai; it returns a near-constant vector for it, so ranking
/// by cosine was ranking by nothing.
///
/// Thai has no spaces between words, which rules out ordinary tokenisation. Character
/// trigrams work anyway: they cost nothing, they need no model and no download, and two
/// pieces of Thai about the same subject share a great many of them. Scores are honest —
/// a question sharing no trigrams with a window scores exactly zero, which is what makes
/// a relevance floor mean something.
enum Lexical {
    static let gramLength = 3

    /// Overlapping character n-grams, with whitespace and punctuation removed so that
    /// "สาขา ภูเก็ต" and "สาขาภูเก็ต" produce the same grams.
    static func grams(_ text: String, length: Int = gramLength) -> [String] {
        let cleaned = text.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
        guard cleaned.count >= length else {
            return cleaned.isEmpty ? [] : [String(cleaned)]
        }
        return (0...(cleaned.count - length)).map { String(cleaned[$0..<($0 + length)]) }
    }

    /// Term frequencies, normalized so a long window does not outrank a short one purely
    /// by having more of everything.
    static func frequencies(_ text: String) -> [String: Double] {
        var counts = [String: Double]()
        for gram in grams(text) { counts[gram, default: 0] += 1 }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return counts.mapValues { $0 / total }
    }

    /// Inverse document frequency over the whole recording. A trigram that appears in
    /// every window says nothing about which window to read.
    static func inverseDocumentFrequency(_ documents: [[String: Double]]) -> [String: Double] {
        guard !documents.isEmpty else { return [:] }
        var appearances = [String: Int]()
        for document in documents {
            for gram in document.keys { appearances[gram, default: 0] += 1 }
        }
        let count = Double(documents.count)
        return appearances.mapValues { log(1 + count / Double($0)) }
    }

    /// Cosine similarity over tf-idf weights. Zero when nothing is shared.
    static func similarity(query: [String: Double],
                           document: [String: Double],
                           idf: [String: Double]) -> Double {
        var dot = 0.0, queryMagnitude = 0.0, documentMagnitude = 0.0
        for (gram, frequency) in query {
            let weight = frequency * (idf[gram] ?? 1)
            queryMagnitude += weight * weight
            if let other = document[gram] {
                dot += weight * other * (idf[gram] ?? 1)
            }
        }
        for (gram, frequency) in document {
            let weight = frequency * (idf[gram] ?? 1)
            documentMagnitude += weight * weight
        }
        guard queryMagnitude > 0, documentMagnitude > 0 else { return 0 }
        return dot / (sqrt(queryMagnitude) * sqrt(documentMagnitude))
    }

    /// Whether a set of embedding scores actually distinguishes anything. A model that
    /// returns the same number for every window is not ranking, and blending it in would
    /// only add noise to a signal that works.
    static func discriminates(_ scores: [Float], epsilon: Float = 0.02) -> Bool {
        guard let low = scores.min(), let high = scores.max(), scores.count > 1 else { return false }
        return high - low > epsilon
    }
}
