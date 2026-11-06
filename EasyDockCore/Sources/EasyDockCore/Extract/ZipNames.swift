import Foundation

/// File names in a ZIP made by an older Windows tool, which stored them in
/// the code page of that Windows (Vietnamese, Japanese, Chinese…) without
/// saying which. 7-Zip reads every such name as DOS Latin (CP437), so
/// "Ảnh.jpg" comes out as "A╥nh.jpg". CP437 maps all 256 bytes, so encoding
/// the name back gives the bytes that were stored; the code page they read
/// best in is the one they were written in.
///
/// "Best" is scored first, since a general detector gets short names wrong
/// ("Ảnh" read as Japanese, "Café" as Russian). A reading scores for the
/// letters a language writes every day, twice for a character made of two
/// bytes, more for signs only its language has (Vietnamese tone marks that
/// combine, Japanese kana, common Korean syllables), and loses for symbols,
/// marks left on their own, words that mix alphabets and words in a jumble
/// of capitals. Only readings that tie are left to Foundation's detector,
/// which knows how common each character is. A name changes only when
/// another code page reads better than CP437.
public enum ZipNames {
    /// The code pages Windows tools wrote ZIP names in, by language.
    static let codePages: [(languages: [String], encoding: String.Encoding)] = [
        (["vi"], encoding(.windowsVietnamese)),
        (["ja"], encoding(.dosJapanese)),
        (["zh-Hans", "zh-CN", "zh-SG", "zh"], encoding(.GB_18030_2000)),
        (["ko"], encoding(.dosKorean)),
        (["zh-Hant", "zh-TW", "zh-HK"], encoding(.dosChineseTrad)),
        (["ru", "uk", "be", "bg", "sr", "mk"], encoding(.dosRussian)),
        (["ru", "uk", "be", "bg", "sr", "mk"], encoding(.windowsCyrillic)),
        (["th"], encoding(.dosThai)),
        (["cs", "sk", "pl", "hu", "sl", "hr", "ro"], encoding(.dosLatin2)),
        (["de", "fr", "es", "it", "pt", "nl", "sv", "da", "nb", "fi"], encoding(.dosLatin1)),
    ]

    static let cp437 = encoding(.dosLatinUS)

    /// The encoding `names`, as 7-Zip gave them, were written in, or nil
    /// when they read right already. One ZIP is written in one code page, so
    /// every name counts towards it. `preferredLanguages` goes first.
    public static func encoding(of names: [String], preferredLanguages: [String]) -> String.Encoding? {
        let stored = names.compactMap(storedBytes)
        guard !stored.isEmpty else { return nil }
        let raw = Data(stored.joined(separator: [0x0A]))
        if String(data: raw, encoding: .utf8) != nil { return .utf8 }
        guard let asRead = String(data: raw, encoding: cp437) else { return nil }
        let scored = ordered(by: preferredLanguages).compactMap { encoding in
            read(raw, as: encoding).map { (encoding: encoding, score: score($0, in: encoding)) }
        }
        guard let top = scored.map(\.score).max(), top > score(asRead, in: cp437) else { return nil }
        let tied = scored.filter { $0.score == top }.map(\.encoding)
        guard tied.count > 1 else { return tied[0] }
        // Readings that look equally like words (Cyrillic bytes also make
        // valid Chinese): Foundation's detector knows which characters are
        // common, which shapes alone can't tell.
        var converted: NSString?
        var lossy = ObjCBool(false)
        let detected = NSString.stringEncoding(for: raw, encodingOptions: [
            .suggestedEncodingsKey: tied.map { NSNumber(value: $0.rawValue) },
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        return tied.first { $0.rawValue == detected } ?? tied[0]
    }

    /// `name` as it was meant in `encoding`, or nil to leave it: a name that
    /// was never read as CP437 (it had the UTF-8 flag) reads worse.
    public static func recovered(_ name: String, in encoding: String.Encoding) -> String? {
        guard let bytes = storedBytes(name), let text = read(Data(bytes), as: encoding) else { return nil }
        let meant = text.precomposedStringWithCanonicalMapping
        guard !meant.contains("/"), meant != name.precomposedStringWithCanonicalMapping else { return nil }
        return encoding == .utf8 || score(text, in: encoding) > score(name, in: cp437) ? meant : nil
    }

    /// The bytes the ZIP stored, when the name could have been read as
    /// CP437 and has something beyond ASCII.
    private static func storedBytes(_ name: String) -> [UInt8]? {
        guard let data = name.precomposedStringWithCanonicalMapping.data(using: cp437), data.contains(where: { $0 >= 0x80 }) else { return nil }
        return [UInt8](data)
    }

    private static func read(_ data: Data, as encoding: String.Encoding) -> String? {
        guard let text = String(data: data, encoding: encoding), !text.contains("\u{FFFD}") else { return nil }
        return text
    }

    private static func ordered(by languages: [String]) -> [String.Encoding] {
        var result: [String.Encoding] = []
        for language in languages {
            for page in codePages where page.languages.contains(where: { language == $0 || language.hasPrefix($0 + "-") }) {
                if !result.contains(page.encoding) { result.append(page.encoding) }
            }
        }
        for page in codePages where !result.contains(page.encoding) { result.append(page.encoding) }
        return result
    }

    // MARK: - Scoring

    enum Script { case latin, greek, cyrillic, thai, hangul, kana, halfwidthKana, han, other }

    /// Punctuation file names do use beyond ASCII.
    private static let namePunctuation = Set("–—·•“”‘’…（）【】「」『』、。・　，！？：；《》〈〉～")

    static func score(_ text: String, in encoding: String.Encoding) -> Int {
        let composed = text.precomposedStringWithCanonicalMapping
        let isCombining = { (scalar: Unicode.Scalar) in (0x0300...0x036F).contains(scalar.value) }
        // Each mark that joined its letter, as CP1258's tone marks do.
        var score = text.unicodeScalars.filter(isCombining).count - composed.unicodeScalars.filter(isCombining).count
        var scripts: Set<Script> = []
        var cases: [Bool] = []
        var beyondASCII = false
        func endWord() {
            // Japanese mixes kanji and kana; anything else in one word is two
            // misread alphabets.
            if scripts.count > 1 && scripts != [.han, .kana] { score -= 2 }
            // A real word is lower case, upper case or Capitalized.
            let upper = cases.filter { $0 }.count
            if beyondASCII, upper > 0, upper < cases.count, !(upper == 1 && cases.first == true) { score -= 2 }
            scripts = []
            cases = []
            beyondASCII = false
        }
        for scalar in composed.unicodeScalars {
            let properties = scalar.properties
            guard properties.isAlphabetic || (scalar.value < 0x80 && properties.numericType != nil) else {
                endWord()
                if scalar.value >= 0x80, properties.numericType == nil, !namePunctuation.contains(Character(scalar)) {
                    score -= 2
                }
                continue
            }
            if properties.isUppercase || properties.isLowercase { cases.append(properties.isUppercase) }
            guard scalar.value >= 0x80 else {
                if properties.isAlphabetic { scripts.insert(.latin) }
                continue
            }
            if isCombining(scalar) {
                score -= 3
                continue
            }
            beyondASCII = true
            let script = self.script(of: scalar)
            scripts.insert(script)
            score += points(scalar, script, in: encoding)
        }
        endWord()
        return score
    }

    /// A character from two bytes counts twice. Only the letters a language
    /// writes every day count at all: misread bytes land on rare ones.
    private static func points(_ scalar: Unicode.Scalar, _ script: Script, in encoding: String.Encoding) -> Int {
        switch script {
        case .han: 2
        // Kana is only ever Japanese: Chinese and Korean code pages hold it
        // too, but their names don't use it.
        case .kana: encoding == shiftJIS ? 3 : 0
        case .hangul:
            // A syllable from the 2,350 of everyday Korean (the ones EUC-KR
            // holds); lone jamo and rare syllables are misread bytes.
            (0xAC00...0xD7A3).contains(scalar.value) && String(Character(scalar)).data(using: euckr) != nil ? 3 : 0
        case .cyrillic:
            // Russian, Ukrainian and Belarusian letters.
            (0x410...0x44F).contains(scalar.value) || [0x401, 0x451, 0x404, 0x454, 0x406, 0x456, 0x407, 0x457, 0x490, 0x491, 0x40E, 0x45E].contains(scalar.value) ? 1 : 0
        case .halfwidthKana, .other: 0
        case .latin, .greek, .thai: 1
        }
    }

    private static let euckr = encoding(.EUC_KR)
    private static let shiftJIS = encoding(.dosJapanese)

    static func script(of scalar: Unicode.Scalar) -> Script {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: .latin
        case 0x370...0x3FF: .greek
        case 0x400...0x4FF: .cyrillic
        // Thai vowels and tone marks are marks, but belong to their letter.
        case 0xE00...0xE7F: .thai
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: .hangul
        case 0x3040...0x30FF, 0x31F0...0x31FF: .kana
        case 0xFF61...0xFF9F: .halfwidthKana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF10...0xFF5A, 0x20000...0x2FFFF: .han
        default: .other
        }
    }

    private static func encoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}
