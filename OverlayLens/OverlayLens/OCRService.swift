import CoreGraphics
import Vision

/// One recognized line of text with its location in the source image.
/// `boundingBox` is Vision's normalized rect (0...1, origin bottom-left).
struct RecognizedLine: Equatable {
    let text: String
    let boundingBox: CGRect
}

enum OCRService {
    /// Synchronous OCR; call off the main thread. Recognizes both English
    /// and Thai so the pipeline can translate in either direction.
    static func recognizeLines(in image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "th-TH"]
        request.automaticallyDetectsLanguage = true

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return RecognizedLine(text: candidate.string, boundingBox: observation.boundingBox)
        }
    }
}
