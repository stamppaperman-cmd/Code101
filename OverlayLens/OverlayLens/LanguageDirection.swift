import NaturalLanguage

/// Detected source language, used to pick a translation direction per piece
/// of text so the lens works without a language picker.
enum DetectedSourceLanguage {
    case thai
    case chinese
    case other // treated as English-like; anything not Thai or Chinese

    static func detect(for text: String) -> DetectedSourceLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .thai: return .thai
        case .simplifiedChinese, .traditionalChinese: return .chinese
        default: return .other
        }
    }
}
