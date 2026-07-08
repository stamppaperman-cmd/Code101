import NaturalLanguage

/// Picks a translation direction per piece of text so the lens works both
/// English -> Thai and Thai -> English without a language picker: whatever
/// isn't Thai is treated as the source and translated to Thai; Thai text is
/// translated to English.
enum LanguageDirection {
    static func targetIsThai(for text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage != .thai
    }
}
